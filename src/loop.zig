const std = @import("std");
const ipc = @import("ipc.zig");
const log = @import("log.zig");
const util = @import("util.zig");
const cross = @import("cross");
const socket = @import("socket.zig");
const label = @import("label.zig");
const lib_posix = @import("posix.zig");
const Cfg = @import("cfg.zig");
const signal = @import("signal.zig");
const assert = std.debug.assert;
const daemonize = @import("daemonize.zig");
const builtin = @import("builtin");
const terminal = @import("terminal.zig");
const ghostty_vt = terminal.ghostty_vt;
const attachment = @import("attachment.zig");

/// clientLoop sends ipc commands to its corresponding daemon.  It uses poll() as its non-blocking
/// mechanism. It will send stdin to the daemon and receive stdout from the daemon.
pub fn clientLoop(alloc: std.mem.Allocator, client_sock_fd: i32, env_str: []const u8) !ClientResult {
    std.log.info("client loop fd={d}", .{client_sock_fd});

    try signal.openSignalPipe();
    var old_winch: lib_posix.Sigaction = undefined;
    var old_term: lib_posix.Sigaction = undefined;
    var old_hup: lib_posix.Sigaction = undefined;
    var old_int: lib_posix.Sigaction = undefined;
    lib_posix.sigaction(lib_posix.SIG.WINCH, null, &old_winch);
    lib_posix.sigaction(lib_posix.SIG.TERM, null, &old_term);
    lib_posix.sigaction(lib_posix.SIG.HUP, null, &old_hup);
    lib_posix.sigaction(lib_posix.SIG.INT, null, &old_int);
    signal.installWakeHandler(@backingInt(lib_posix.SIG.WINCH));
    signal.installWakeHandler(@backingInt(lib_posix.SIG.TERM));
    signal.installWakeHandler(@backingInt(lib_posix.SIG.HUP));
    signal.installWakeHandler(@backingInt(lib_posix.SIG.INT));
    defer {
        lib_posix.sigaction(lib_posix.SIG.WINCH, &old_winch, null);
        lib_posix.sigaction(lib_posix.SIG.TERM, &old_term, null);
        lib_posix.sigaction(lib_posix.SIG.HUP, &old_hup, null);
        lib_posix.sigaction(lib_posix.SIG.INT, &old_int, null);
        signal.closeSignalPipe();
    }

    // Make socket non-blocking to avoid blocking on writes
    var sock_flags = try lib_posix.fcntl(client_sock_fd, lib_posix.F.GETFL, 0);
    sock_flags |= lib_posix.O_NONBLOCK;
    _ = try lib_posix.fcntl(client_sock_fd, lib_posix.F.SETFL, sock_flags);

    // Buffer for outgoing socket writes
    var sock_write_buf = try std.ArrayList(u8).initCapacity(alloc, 4096);
    defer sock_write_buf.deinit(alloc);

    if (env_str.len > 0) {
        try ipc.appendMessage(alloc, &sock_write_buf, .EnvSet, env_str);
    }

    // Send negotiated attachment request (Attach + Init + Info). Info is also
    // supported by older daemons and ordered after Init on this connection so
    // its response distinguishes attachment from an early EOF.
    const size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);
    try attachment.request(alloc, &sock_write_buf, size);
    var restoration: attachment.Receiver = .{};
    var socket_eof = false;
    var socket_write_open = true;

    var poll_fds = try std.ArrayList(lib_posix.pollfd).initCapacity(alloc, 4);
    defer poll_fds.deinit(alloc);

    var read_buf = try ipc.SocketBuffer.init(alloc);
    defer read_buf.deinit();

    var stdout_buf = try std.ArrayList(u8).initCapacity(alloc, 4096);
    defer stdout_buf.deinit(alloc);

    const stdin_fd = lib_posix.STDIN_FILENO;

    // Make stdin non-blocking. O_NONBLOCK is set on the open file description,
    // which is shared with the parent shell; restore on exit to avoid
    // corrupting the parent's stdin.
    const stdin_orig_flags = try lib_posix.fcntl(stdin_fd, lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(stdin_fd, lib_posix.F.SETFL, stdin_orig_flags | lib_posix.O_NONBLOCK);
    defer _ = lib_posix.fcntl(stdin_fd, lib_posix.F.SETFL, stdin_orig_flags) catch {};

    // stdout may be a separate pipe rather than the same terminal description
    // as stdin. Keep partial-output draining responsive in either case.
    const stdout_orig_flags = try lib_posix.fcntl(lib_posix.STDOUT_FILENO, lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(lib_posix.STDOUT_FILENO, lib_posix.F.SETFL, stdout_orig_flags | lib_posix.O_NONBLOCK);
    defer _ = lib_posix.fcntl(lib_posix.STDOUT_FILENO, lib_posix.F.SETFL, stdout_orig_flags) catch {};

    const detach_key_disabled = util.isDetachKeyDisabled();

    while (true) {
        if (socket_eof and stdout_buf.items.len == 0) {
            return ClientResult{ .kind = if (restoration.ready) .detach else .unavailable, .session_name = null };
        }
        poll_fds.clearRetainingCapacity();

        try poll_fds.append(alloc, .{
            .fd = if (socket_eof or !socket_write_open) -1 else stdin_fd,
            .events = lib_posix.POLL.IN,
            .revents = 0,
        });

        // Poll socket for read, and also for write if we have pending data
        var sock_events: i16 = lib_posix.POLL.IN;
        if (socket_write_open and sock_write_buf.items.len > 0) {
            sock_events |= lib_posix.POLL.OUT;
        }
        try poll_fds.append(alloc, .{
            .fd = if (socket_eof) -1 else client_sock_fd,
            .events = sock_events,
            .revents = 0,
        });

        try poll_fds.append(alloc, .{ .fd = signal.sig_pipe[0], .events = lib_posix.POLL.IN, .revents = 0 });

        if (stdout_buf.items.len > 0 and restoration.canFlush(socket_eof)) {
            try poll_fds.append(alloc, .{
                .fd = lib_posix.STDOUT_FILENO,
                .events = lib_posix.POLL.OUT,
                .revents = 0,
            });
        }

        _ = try lib_posix.poll(poll_fds.items, -1);

        const socket_events = poll_fds.items[1].revents;
        if (socket_events & lib_posix.POLL.NVAL != 0) return error.InvalidSocket;
        if (socket_events & (lib_posix.POLL.HUP | lib_posix.POLL.ERR) != 0) {
            socket_write_open = false;
        }

        if (poll_fds.items[2].revents & lib_posix.POLL.IN != 0) {
            try signal.drainSignalPipe();
            if (socket_write_open and !socket_eof) {
                const next_size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);
                try ipc.appendMessage(
                    alloc,
                    &sock_write_buf,
                    .Resize,
                    std.mem.asBytes(&next_size),
                );
            }
        }

        // Handle stdin -> socket (Input)
        const inp_flags = (lib_posix.POLL.IN | lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL);
        if (socket_write_open and poll_fds.items[0].revents & inp_flags != 0) {
            var buf: [4096]u8 = undefined;
            const n_opt: ?usize = lib_posix.read(stdin_fd, &buf) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                return err;
            };

            if (n_opt) |n| {
                if (n > 0) {
                    // Check for detach sequences (ctrl+\ as first byte or Kitty escape sequence)
                    if (!detach_key_disabled and util.isCtrlBackslash(buf[0..n])) {
                        std.log.info("detach key detected", .{});
                        try ipc.appendMessage(alloc, &sock_write_buf, .Detach, "");
                    } else {
                        try ipc.appendMessage(alloc, &sock_write_buf, .Input, buf[0..n]);
                    }
                } else {
                    std.log.info("eof stdin", .{});
                    // EOF on stdin
                    return ClientResult{ .kind = if (restoration.ready) .detach else .unavailable, .session_name = null };
                }
            }
        }

        // HUP can accompany more than one read's worth of restoration/Info.
        // Read at most one chunk per poll iteration, but only finish at EOF.
        if (socket_events & (lib_posix.POLL.IN | lib_posix.POLL.HUP | lib_posix.POLL.ERR) != 0) {
            const n: ?usize = read_buf.read(client_sock_fd) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                    break :blk 0;
                }
                std.log.err("daemon read err={s}", .{@errorName(err)});
                return err;
            };
            if (n == 0) {
                std.log.info("server closed connection", .{});
                socket_eof = true;
                socket_write_open = false;
            }

            while (read_buf.next()) |msg| {
                switch (msg.header.tag) {
                    .Attach, .Info, .Output => try restoration.receive(alloc, &stdout_buf, msg),
                    .Resize => {
                        if (!socket_write_open) continue;
                        // daemon is asking for the client's window size usually in response
                        // to this client being set as leader.
                        const next_size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);
                        try ipc.appendMessage(
                            alloc,
                            &sock_write_buf,
                            .Resize,
                            std.mem.asBytes(&next_size),
                        );
                    },
                    .Switch => {
                        std.log.info("switch session", .{});
                        // Payload format: "session_name\ncwd" from the daemon
                        const newline_idx = std.mem.indexOfScalar(u8, msg.payload, '\n') orelse {
                            // No cwd provided (backward compat or old daemon)
                            return ClientResult{ .kind = .switch_session, .session_name = try alloc.dupe(u8, msg.payload) };
                        };
                        return ClientResult{
                            .kind = .switch_session,
                            .session_name = try alloc.dupe(u8, msg.payload[0..newline_idx]),
                            .cwd = if (newline_idx + 1 < msg.payload.len) try alloc.dupe(u8, msg.payload[newline_idx + 1 ..]) else null,
                        };
                    },
                    else => {},
                }
            }
        }

        // Handle socket write (flush buffered messages to daemon)
        if (socket_write_open and socket_events & lib_posix.POLL.OUT != 0) {
            if (sock_write_buf.items.len > 0) {
                const n: usize = lib_posix.write(client_sock_fd, sock_write_buf.items) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                        std.log.info("connection reset or broken pipe", .{});
                        // The peer may still have buffered Output/Info to read.
                        socket_write_open = false;
                        break :blk 0;
                    }
                    return err;
                };
                if (n > 0) {
                    try sock_write_buf.replaceRange(alloc, 0, n, &[_]u8{});
                }
            }
        }

        if (stdout_buf.items.len > 0 and restoration.canFlush(socket_eof)) {
            const n = lib_posix.write(lib_posix.STDOUT_FILENO, stdout_buf.items) catch |err| blk: {
                if (err == error.WouldBlock) break :blk 0;
                return err;
            };
            if (n > 0) {
                try stdout_buf.replaceRange(alloc, 0, n, &[_]u8{});
            }
        }
    }
}

fn initTerminal(gpa: std.mem.Allocator, io: std.Io, size: ipc.Resize, cfg: *const Cfg) !ghostty_vt.Terminal {
    return ghostty_vt.Terminal.init(io, gpa, .{
        .cols = size.cols,
        .rows = size.rows,
        .max_scrollback_lines = cfg.max_scrollback_lines,
        .max_scrollback_bytes = null, // Let the line limit control scrollback.
    });
}

/// dameonLoop is what the daemon runs to send and receive ipc commands from its corresponding
/// clients.  It uses poll() as its non-blocking mechanism.
fn daemonLoop(daemon: *Daemon, gpa: std.mem.Allocator, io: std.Io, server_sock_fd: lib_posix.socket_t, pty_fd: i32) !void {
    std.log.info("daemon started session={s} pty_fd={d}", .{ daemon.session_name, pty_fd });

    try signal.openSignalPipe();
    var old_term: lib_posix.Sigaction = undefined;
    lib_posix.sigaction(lib_posix.SIG.TERM, null, &old_term);
    signal.installWakeHandler(@backingInt(lib_posix.SIG.TERM));
    defer {
        lib_posix.sigaction(lib_posix.SIG.TERM, &old_term, null);
        signal.closeSignalPipe();
    }
    var poll_fds = try std.ArrayList(lib_posix.pollfd).initCapacity(gpa, 8);
    defer poll_fds.deinit(gpa);

    const init_size = ipc.getTerminalSize(pty_fd);
    var term = try initTerminal(gpa, io, init_size, daemon.cfg);
    defer term.deinit(gpa);
    var vt_stream = attachment.trackedStream(gpa, &term, attachment.default_continuation_max_bytes);
    defer vt_stream.deinit();

    // Carries the tail of the previous PTY read so the task-exit marker
    // search below can see across a read() boundary. Sized to comfortably
    // hold "ZMX_TASK_COMPLETED:" (19 bytes) plus a u8 exit code and CRLF.
    var marker_carry: [32]u8 = undefined;
    var marker_carry_len: usize = 0;

    var had_terminal_client = daemon.hasTerminalClient();

    daemon_loop: while (daemon.running) {
        // If the program asked for focus reports (DECSET 1004), send focus-out
        // when the last attached client leaves and focus-in when one returns,
        // as a terminal would when its window loses/gains focus.
        const has_terminal_client = daemon.hasTerminalClient();
        if (has_terminal_client != had_terminal_client and term.modes.get(.focus_event)) {
            daemon.queuePtyInput(gpa, if (has_terminal_client) "\x1b[I" else "\x1b[O");
        }
        had_terminal_client = has_terminal_client;

        poll_fds.clearRetainingCapacity();

        try poll_fds.append(gpa, .{
            .fd = server_sock_fd,
            .events = lib_posix.POLL.IN,
            .revents = 0,
        });

        var pty_events: i16 = lib_posix.POLL.IN;
        if (daemon.pty_write_buf.items.len > 0) {
            pty_events |= lib_posix.POLL.OUT;
        }
        try poll_fds.append(gpa, .{
            .fd = pty_fd,
            .events = pty_events,
            .revents = 0,
        });

        try poll_fds.append(gpa, .{ .fd = signal.sig_pipe[0], .events = lib_posix.POLL.IN, .revents = 0 });

        for (daemon.clients.items) |client| {
            var events: i16 = lib_posix.POLL.IN;
            if (client.has_pending_output) {
                events |= lib_posix.POLL.OUT;
            }
            try poll_fds.append(gpa, .{
                .fd = client.socket_fd,
                .events = events,
                .revents = 0,
            });
        }

        _ = try lib_posix.poll(poll_fds.items, -1);

        if (poll_fds.items[2].revents & lib_posix.POLL.IN != 0) {
            signal.drainSignalPipe() catch {};
            std.log.info(
                "SIGTERM received, shutting down gracefully session={s}",
                .{daemon.session_name},
            );
            break :daemon_loop;
        }

        if (poll_fds.items[0].revents & (lib_posix.POLL.ERR | lib_posix.POLL.HUP | lib_posix.POLL.NVAL) != 0) {
            std.log.err("server socket error revents={d}", .{poll_fds.items[0].revents});
            break :daemon_loop;
        } else if (poll_fds.items[0].revents & lib_posix.POLL.IN != 0) {
            const client_fd = try lib_posix.accept(
                server_sock_fd,
                null,
                null,
                lib_posix.SOCK.NONBLOCK | lib_posix.SOCK.CLOEXEC,
            );
            const client = try gpa.create(Client);
            client.* = Client{
                .alloc = gpa,
                .socket_fd = client_fd,
                .read_buf = try ipc.SocketBuffer.init(gpa),
                .write_buf = undefined,
            };
            // 64KB initial capacity lets ~15 broadcast cycles (N_TTY_BUF_SIZE reads
            // * header) accumulate before the first ArrayList growth. The write
            // buffer is userspace-only: it drains via POLLOUT to the client socket,
            // which has no corresponding kernel-imposed per-write limit.
            client.write_buf = try std.ArrayList(u8).initCapacity(client.alloc, 65536);
            try daemon.clients.append(gpa, client);
            std.log.info(
                "client connected fd={d} total={d}",
                .{ client_fd, daemon.clients.items.len },
            );
        }

        const inp_flags = lib_posix.POLL.IN | lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL;
        if (poll_fds.items[1].revents & inp_flags != 0) {
            // Read from PTY. Buffer is sized to N_TTY_BUF_SIZE (4096): the hard
            // kernel limit for the N_TTY line discipline. A larger buffer doesn't
            // help: each read() from a PTY master returns at most 4096 bytes
            // regardless of the userspace buffer size.
            var buf: [4096]u8 = undefined;
            const n_opt: ?usize = lib_posix.read(pty_fd, &buf) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                // Linux reports the closed slave as EIO; other read failures
                // are errors, not an invented producer EOF.
                if (err == error.InputOutput) break :blk 0;
                return err;
            };

            if (n_opt) |n| {
                if (n == 0) {
                    const drain_io: FinalOutputIo = .{
                        .io = io,
                        .signal_fd = signal.sig_pipe[0],
                    };
                    var window: FinalOutputWindow = .{};
                    window.observeEof(drain_io.now());
                    std.log.info("shell exited pty_fd={d}", .{pty_fd});
                    return daemon.drainFinalOutput(gpa, &window, &poll_fds, drain_io);
                } else {
                    // Feed PTY output to terminal emulator for state tracking
                    vt_stream.nextSlice(buf[0..n]);
                    daemon.setPwd(&term);
                    daemon.has_pty_output = true;

                    // When no real terminal client has attached yet, respond to
                    // terminal queries (e.g. DA1/DA2) on behalf of the terminal.
                    // This prevents fish from waiting 10s for unanswered queries.
                    // Only clients that sent .Init (a real zmx attach) count,
                    // not a `zmx run` tail-only client.
                    if (!daemon.hasTerminalClient() and
                        daemon.pty_write_buf.items.len < Daemon.PTY_WRITE_BUF_MAX)
                    {
                        util.respondToDeviceAttributes(gpa, &daemon.pty_write_buf, buf[0..n]);
                    }

                    // In run mode, scan output for exit code marker. The marker
                    // can straddle two PTY reads (more likely under a throttled
                    // scheduler, e.g. containers), so prepend the tail carried
                    // over from the previous read before searching.
                    if (daemon.is_task_mode and daemon.task_exit_code == null) {
                        var scan_buf: [marker_carry.len + buf.len]u8 = undefined;
                        @memcpy(scan_buf[0..marker_carry_len], marker_carry[0..marker_carry_len]);
                        @memcpy(scan_buf[marker_carry_len..][0..n], buf[0..n]);
                        const scan_len = marker_carry_len + n;

                        if (try util.findTaskExitMarker(scan_buf[0..scan_len], daemon.task_id)) |exit_code| {
                            daemon.task_exit_code = exit_code;
                            daemon.task_ended_at = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());

                            std.log.info("task completed exit_code={d}", .{exit_code});

                            // Notify connected clients
                            for (daemon.clients.items) |c| {
                                ipc.appendMessage(gpa, &c.write_buf, .TaskComplete, &[_]u8{exit_code}) catch {};
                                c.has_pending_output = true;
                            }
                        }

                        marker_carry_len = @min(marker_carry.len, scan_len);
                        @memcpy(
                            marker_carry[0..marker_carry_len],
                            scan_buf[scan_len - marker_carry_len .. scan_len],
                        );
                    }

                    // Broadcast data to all clients.
                    // Rewrite OSC 133;A to include redraw=0 so the outer terminal
                    // does not clear prompt lines on resize (issue #111).
                    const broadcast_data = util.rewritePromptRedraw(gpa, buf[0..n]) orelse buf[0..n];
                    defer if (broadcast_data.ptr != buf[0..n].ptr) gpa.free(broadcast_data);
                    for (daemon.clients.items) |client| {
                        const queued = client.admission.output(gpa, &client.write_buf, broadcast_data) catch |err| {
                            std.log.warn(
                                "failed to buffer output for client err={s}",
                                .{@errorName(err)},
                            );
                            continue;
                        };
                        if (queued) client.has_pending_output = true;
                    }
                }
            }
        }

        if (poll_fds.items[1].revents & lib_posix.POLL.OUT != 0) {
            while (daemon.pty_write_buf.items.len > 0) {
                const n = lib_posix.write(pty_fd, daemon.pty_write_buf.items) catch |err| {
                    if (err != error.WouldBlock) {
                        std.log.warn("pty write failed: {s}", .{@errorName(err)});
                        daemon.pty_write_buf.clearRetainingCapacity();
                    }
                    break;
                };
                if (n == 0) break;
                daemon.pty_write_buf.replaceRange(gpa, 0, n, &[_]u8{}) catch unreachable;
            }
        }

        var i: usize = daemon.clients.items.len;
        // Only iterate over clients that were present when poll_fds was constructed
        // poll_fds contains [server, pty, sig_pipe, client0, client1, ...]
        // So number of clients in poll_fds is poll_fds.items.len - 3
        const num_polled_clients = poll_fds.items.len - 3;
        if (i > num_polled_clients) {
            // If we have more clients than polled (i.e. we just accepted one), start from the
            // polled ones
            i = num_polled_clients;
        }

        clients_loop: while (i > 0) {
            i -= 1;
            const client = daemon.clients.items[i];
            const revents = poll_fds.items[i + 3].revents;

            if (revents & lib_posix.POLL.IN != 0) {
                const n = client.read_buf.read(client.socket_fd) catch |err| {
                    if (err == error.WouldBlock) continue;
                    std.log.debug(
                        "client read err={s} fd={d}",
                        .{ @errorName(err), client.socket_fd },
                    );
                    const last = daemon.closeClient(gpa, client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                };

                if (n == 0) {
                    // Client closed connection
                    const last = daemon.closeClient(gpa, client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                }

                while (client.read_buf.next()) |msg| {
                    switch (msg.header.tag) {
                        .Attach => {
                            if (msg.payload.len == 0) {
                                client.admission.begin();
                            } else {
                                std.log.warn("ignoring invalid Attach payload length={d}", .{msg.payload.len});
                            }
                        },
                        .Input => try daemon.handleInput(gpa, client, &term, msg.payload),
                        .Send => daemon.handleSend(gpa, msg.payload),
                        .Output => try daemon.handleOutput(gpa, msg.payload, &term, &vt_stream),
                        .Init => {
                            if (!daemon.dispatchInit(gpa, client, &term, &vt_stream, msg.payload, ClientInitIo{
                                .pty_fd = pty_fd,
                                .index = i,
                            })) continue :clients_loop;
                        },
                        .Switch => try daemon.handleSwitch(gpa, msg.payload),
                        .Resize => try daemon.handleResize(gpa, client, pty_fd, &term, msg.payload),
                        .Detach => {
                            daemon.handleDetach(gpa, client, i);
                            break :clients_loop;
                        },
                        .DetachAll => {
                            daemon.handleDetachAll(gpa);
                            break :clients_loop;
                        },
                        .Kill => {
                            break :daemon_loop;
                        },
                        .Info => {
                            if (!daemon.dispatchInfo(gpa, client, &term, ClientInitIo{
                                .pty_fd = pty_fd,
                                .index = i,
                            })) continue :clients_loop;
                        },
                        .LabelGet => try daemon.handleLabelGet(gpa, client),
                        .LabelSet => try daemon.handleLabelSet(gpa, client, msg.payload),
                        .LabelClear => try daemon.handleLabelClear(gpa, client),
                        .EnvGet => try daemon.handleEnvGet(gpa, client),
                        .EnvSet => try daemon.handleEnvSet(gpa, client, msg.payload),
                        .History => try daemon.handleHistory(gpa, client, &term, msg.payload),
                        .Capture => try daemon.handleCapture(gpa, client, &term, msg.payload),
                        .Run => try daemon.handleRun(gpa, io, client, msg.payload),
                        .Ack, .TaskComplete, .LabelData, .EnvData, .Unsupported => {},
                        .Write => try daemon.handleWrite(gpa, client, msg.payload),
                        _ => {
                            std.log.warn(
                                "ignoring unknown IPC tag={d}",
                                .{@backingInt(msg.header.tag)},
                            );
                            ipc.appendMessage(gpa, &client.write_buf, .Unsupported, "") catch {};
                            client.has_pending_output = true;
                        },
                    }
                }
            }

            if (revents & lib_posix.POLL.OUT != 0) {
                // Flush pending output buffers
                const n = lib_posix.write(client.socket_fd, client.write_buf.items) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    // Error on write, close client
                    const last = daemon.closeClient(gpa, client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                };

                if (n > 0) {
                    client.write_buf.replaceRange(gpa, 0, n, &[_]u8{}) catch unreachable;
                }

                if (client.write_buf.items.len == 0) {
                    client.has_pending_output = false;
                }
            }

            if (revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0) {
                // A client that writes and exits (`zmx send`, `zmx run -d`) is
                // reported HUP with part of its message still unread: a pass
                // reads at most 4 KiB. Closing now drops the rest. Leave it to
                // the next pass, which reads on until EOF closes the client.
                if (revents & lib_posix.POLL.IN != 0 and
                    revents & (lib_posix.POLL.ERR | lib_posix.POLL.NVAL) == 0) continue;
                const last = daemon.closeClient(gpa, client, i, false);
                if (last) break :daemon_loop;
            }
        }
    }
}

pub const ClientResult = struct {
    kind: enum {
        detach,
        unavailable,
        switch_session,
    },
    session_name: ?[]const u8,
    cwd: ?[]const u8 = null,
};

/// Client represents each terminal that has connected to a session.
///
/// Multiple Clients can connect to a single session.
pub const Client = struct {
    alloc: std.mem.Allocator,
    socket_fd: i32,
    has_pending_output: bool = false,
    is_terminal: bool = false, // sent .Init (a `zmx attach`), not a run/send/tail client
    read_buf: ipc.SocketBuffer,
    write_buf: std.ArrayList(u8),
    env_str: ?[]u8 = null,
    admission: attachment.Admission = .{},
    drain_read_closed: bool = false,

    pub fn deinit(self: *Client, gpa: std.mem.Allocator) void {
        lib_posix.close(self.socket_fd);
        self.deinitBuffers(gpa);
    }

    pub fn deinitBuffers(self: *Client, gpa: std.mem.Allocator) void {
        self.read_buf.deinit();
        self.write_buf.deinit(self.alloc);
        if (self.env_str) |s| gpa.free(s);
    }

    fn setEnv(self: *Client, gpa: std.mem.Allocator, env_str: []const u8) !void {
        if (self.env_str) |s| gpa.free(s);
        self.env_str = if (env_str.len > 0) try gpa.dupe(u8, env_str) else null;
    }
};

const ClientInitIo = struct {
    pty_fd: i32,
    index: usize,

    fn resize(self: ClientInitIo, daemon: *const Daemon, size: ipc.Resize) void {
        var ws = size.winsize();
        _ = cross.ioctl(self.pty_fd, cross.TIOCSWINSZ, &ws);

        // On re-attach, deliver SIGWINCH to the foreground process group so
        // incremental renderers (Ink, Claude Code, etc.) know to repaint.
        // If the size changed, TIOCSWINSZ above already sent SIGWINCH; if the size
        // was unchanged, the kernel suppressed it, so signal the pgrp explicitly.
        if (daemon.has_pty_output) {
            var pgrp: lib_posix.pid_t = 0;
            if (cross.ioctl(self.pty_fd, cross.TIOCGPGRP, &pgrp) == 0 and pgrp > 0) {
                lib_posix.kill(-pgrp, .WINCH) catch {};
            }
        }
    }

    fn reject(self: ClientInitIo, gpa: std.mem.Allocator, daemon: *Daemon, client: *Client, err: anyerror) void {
        std.log.warn("rejecting client setup fd={d} err={s}", .{ client.socket_fd, @errorName(err) });
        _ = daemon.closeClient(gpa, client, self.index, false);
    }
};

const FinalOutputWindow = struct {
    const duration_ns = 5 * std.time.ns_per_s;
    deadline_ns: ?i96 = null,

    fn observeEof(self: *FinalOutputWindow, now_ns: i96) void {
        if (self.deadline_ns == null) self.deadline_ns = now_ns + duration_ns;
    }

    fn remainingMs(self: FinalOutputWindow, now_ns: i96) i32 {
        const remaining = self.deadline_ns.? - now_ns;
        if (remaining <= 0) return 0;
        return @intCast(@divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms));
    }
};

const FinalOutputIo = struct {
    io: std.Io,
    signal_fd: lib_posix.fd_t,

    fn now(self: @This()) i96 {
        return std.Io.Timestamp.now(self.io, .awake).nanoseconds;
    }

    fn poll(_: @This(), fds: []lib_posix.pollfd, timeout_ms: i32) !void {
        // Unlike lib_posix.poll, return on EINTR so the owner recomputes the
        // remaining immutable deadline instead of restarting a full timeout.
        const rc = std.c.poll(fds.ptr, @intCast(fds.len), timeout_ms);
        if (rc < 0 and std.c.errno(rc) != .INTR) {
            std.log.err("final output poll failed errno={s}", .{@tagName(std.c.errno(rc))});
            return error.FinalOutputPollFailed;
        }
    }

    fn read(_: @This(), client: *Client) !usize {
        return client.read_buf.read(client.socket_fd);
    }

    fn write(_: @This(), fd: lib_posix.fd_t, bytes: []const u8) !usize {
        return lib_posix.write(fd, bytes);
    }

    fn closeClient(_: @This(), gpa: std.mem.Allocator, daemon: *Daemon, client: *Client, index: usize, reason: FinalOutputClose) void {
        std.log.info("final output client closed fd={d} reason={s} unsent={d}", .{
            client.socket_fd, @tagName(reason), client.write_buf.items.len,
        });
        _ = daemon.closeClient(gpa, client, index, false);
    }
};

const FinalOutputClose = enum { drained, deadline, peer_failure, cancelled };

// Keep the unreaped forkpty child until after the last group signal. Its PID
// reserves the original process-group identity even if it exits during drain.
const RetainedChild = struct {
    pid: ?lib_posix.pid_t = null,

    fn finish(self: *RetainedChild, io: anytype) void {
        const pid = self.pid orelse return;
        assert(pid > 0);
        io.signalGroup(pid, .HUP);
        io.grace();
        io.signalGroup(pid, .KILL);
        io.reap(pid);
        self.pid = null;
    }
};

const ChildCleanupIo = struct {
    io: std.Io,

    fn signalGroup(_: @This(), pid: lib_posix.pid_t, sig: lib_posix.SIG) void {
        lib_posix.kill(-pid, sig) catch |err| {
            std.log.warn("failed to signal pty child group pid={d} signal={s} err={s}", .{
                pid, @tagName(sig), @errorName(err),
            });
        };
    }

    fn grace(self: @This()) void {
        std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(500), .real) catch {};
    }

    fn reap(_: @This(), pid: lib_posix.pid_t) void {
        var status: c_int = undefined;
        while (true) {
            const rc = std.c.waitpid(pid, &status, 0);
            if (rc == pid) return;
            if (rc < 0 and std.c.errno(rc) == .INTR) continue;
            std.log.warn("failed to reap pty child pid={d}", .{pid});
            return;
        }
    }
};

/// Daemon is responsible for managing a zmx session.
///
/// It holds all the state for a running session.  Instead of a single daemon for all sessions, we
/// create a daemon for every session.  This has some benefits. The ipc communication between
/// session clients and the daemon doesn't need to be tagged with the session name.  If a daemon
/// crashes for one session won't crash all the other sessions.
///
/// Conceptually it's also much simpler to reason about.
pub const Daemon = struct {
    cfg: *Cfg,
    session_name: []const u8,
    socket_path: []const u8,
    // === opt ===
    pty_write_buf: std.ArrayList(u8) = .empty,
    clients: std.ArrayList(*Client) = .empty,
    labels: std.StringHashMapUnmanaged([]u8) = .empty,
    // This control which client is the leader.  The leader controls terminal state and
    // cols/rows of session.
    leader_client_fd: ?i32 = null,
    running: bool = true,
    pid: i32 = undefined,
    command: ?[]const []const u8 = null,
    /// The session's working directory in OSC 7 form, `file://<host><path>`.
    /// Kept as a URI rather than a path so `zmx list` shows the host, which is
    /// what tells you a session is inside SSH. Points into `cwd_buf` once set,
    /// so a Daemon must not be copied by value after that.
    cwd: []const u8 = "",
    /// The same directory as a path that can be opened: percent-decoding
    /// applied, scheme and host stripped. Empty when the cwd is on another
    /// host, since then it names no directory here and nothing should chdir
    /// into it. Points into `cwd_path_buf`.
    cwd_path: []const u8 = "",
    cwd_buf: [std.fs.max_path_bytes]u8 = undefined,
    cwd_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    has_pty_output: bool = false,
    has_had_client: bool = false,
    created_at: u64, // unix timestamp (ns)
    is_task_mode: bool = false, // flag for when session is run as a task
    task_id: [4]u8 = undefined,
    task_exit_code: ?u8 = null, // null = running or n/a, set when task completes
    task_ended_at: ?u64 = null, // timestamp when task exited
    pty_fd: i32 = -1, // set by daemonLoop so handleRun can probe the foreground process
    shell: []const u8 = "/bin/sh",
    quiet: bool = false,
    child: RetainedChild = .{},

    /// Create a Daemon. Caller is responsible for freeing all variables passed
    /// into the init fn.
    pub fn init(io: std.Io, cfg: *Cfg, sesh_name: []const u8, socket_path: []const u8) Daemon {
        return .{
            .cfg = cfg,
            .session_name = sesh_name,
            .socket_path = socket_path,
            .created_at = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        };
    }

    pub fn deinit(self: *Daemon, gpa: std.mem.Allocator) void {
        self.clients.deinit(gpa);
        var it = self.labels.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.labels.deinit(gpa);
        self.pty_write_buf.deinit(gpa);
    }

    pub fn shutdown(self: *Daemon, gpa: std.mem.Allocator) void {
        std.log.info("shutting down daemon session={s}", .{self.session_name});
        self.running = false;

        for (self.clients.items) |client| {
            client.deinit(gpa);
            gpa.destroy(client);
        }
        self.clients.clearRetainingCapacity();
    }

    /// Resize the daemon's terminal with prompt_redraw disabled. On resize the
    /// terminal would clear prompt lines expecting the shell to redraw them,
    /// but the shell's redraw goes to the PTY (forwarded to clients), not to
    /// this terminal, so the clearing only corrupts our snapshot state.
    fn resizeTerm(gpa: std.mem.Allocator, term: *ghostty_vt.Terminal, cols: u16, rows: u16) !void {
        const saved = term.flags.shell_redraws_prompt;
        term.flags.shell_redraws_prompt = .false;
        defer term.flags.shell_redraws_prompt = saved;
        try term.resize(gpa, .{ .cols = cols, .rows = rows });
    }

    /// True while a client that sent .Init (a real `zmx attach`) is connected.
    fn hasTerminalClient(self: *const Daemon) bool {
        for (self.clients.items) |c| {
            if (c.is_terminal) return true;
        }
        return false;
    }

    pub fn closeClient(self: *Daemon, gpa: std.mem.Allocator, client: *Client, i: usize, comptime shutdown_on_last: bool) bool {
        return self.closeClientUsing(gpa, client, i, shutdown_on_last, lib_posix.close);
    }

    fn closeClientUsing(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        i: usize,
        comptime shutdown_on_last: bool,
        comptime close: fn (lib_posix.fd_t) void,
    ) bool {
        const fd = client.socket_fd;
        // leader is disconnected, remove ref and let another client claim leader on input
        if (self.leader_client_fd == client.socket_fd) {
            std.log.info(
                "unsetting leader session={s} fd={d}",
                .{ self.session_name, client.socket_fd },
            );
            self.leader_client_fd = null;
        }
        close(client.socket_fd);
        client.deinitBuffers(gpa);
        gpa.destroy(client);
        _ = self.clients.orderedRemove(i);
        std.log.info("client disconnected fd={d} remaining={d}", .{ fd, self.clients.items.len });
        if (shutdown_on_last and self.clients.items.len == 0) {
            self.shutdown(gpa);
            return true;
        }
        return false;
    }

    /// ensureSession will either create or re-use the daemon used for a session.
    /// It will spin up a unix socket, double-fork the process (so it survives
    /// the terminal dying), and automatically attach the client to the ipc unix
    /// socket.
    ///
    /// The return bool value indicates if the current process is the daemon
    /// or the client since they have different behaviors post-fork.
    ///
    /// E.g. If it's the client process then we need to connect to the unix socket
    /// and run the clientLoop.  If it's the daemon then we need to bail since
    /// the daemonLoop is created inside this fn and when it returns that means
    /// the daemon stopped and needs to exit.
    pub fn ensureSession(self: *Daemon, io: std.Io) !bool {
        const sesh_name = self.session_name;
        std.log.info("ensure session session={s}", .{sesh_name});
        var dir = try std.Io.Dir.openDirAbsolute(io, self.cfg.socket_dir, .{});
        defer dir.close(io);

        const exists = try socket.sessionExists(io, dir, sesh_name);
        // if daemon is gone then we flip this to true
        var should_create = !exists;

        if (exists) {
            if (ipc.connectSession(self.socket_path)) |fd| {
                lib_posix.close(fd);
                if (self.command != null) {
                    std.log.warn(
                        "session already exists, ignoring command session={s}",
                        .{sesh_name},
                    );
                }
            } else |err| switch (err) {
                // Daemon is definitively gone: safe to replace.
                error.ConnectionRefused => {
                    socket.cleanupStaleSocket(io, dir, sesh_name);
                    should_create = true;
                },
                // Connect failed for an unusual reason. The check is only to
                // decide create-vs-attach; the socket file exists, so proceed
                // to attach rather than fail or orphan.
                else => {
                    std.log.warn(
                        "connect failed ({s}), proceeding to attach session={s}",
                        .{ @errorName(err), sesh_name },
                    );
                },
            }
        }

        if (!should_create) {
            return false;
        }

        return self.run(io, dir, sesh_name);
    }

    fn run(self: *Daemon, io: std.Io, dir: std.Io.Dir, sesh_name: []const u8) !bool {
        std.log.info("creating session={s}", .{sesh_name});
        const server_sock_fd: lib_posix.socket_t = try socket.createSocket(self.socket_path);
        const log_fd = if (log.log_system.file) |f| f.handle else -1;

        var keep_fds_open = [_]i32{ server_sock_fd, dir.handle, log_fd };
        const cmd = try daemonize.createCmdZ(self.shell, self.is_task_mode, self.command);

        // `cwd_path` is the decoded path, and is empty when the cwd is on
        // another host: OSC 7 crosses SSH boundaries, so a session that ssh'd
        // elsewhere reports a directory that does not exist on this machine.
        std.log.info("checking pwd={s} path={s}", .{ self.cwd, self.cwd_path });
        if (self.cwd_path.len > 0) {
            const pwd_dir = std.Io.Dir.openDirAbsolute(io, self.cwd_path, .{}) catch |err| blk: {
                std.log.warn("failed to open dir={s} err={s}", .{ self.cwd_path, @errorName(err) });
                break :blk null;
            };
            if (pwd_dir) |pdir| {
                defer std.Io.Dir.close(pdir, io);
                std.log.info("set directory dir={s}", .{self.cwd_path});
                try std.process.setCurrentDir(io, pdir);
            }
        }

        const pty_info = daemonize.daemonize(
            sesh_name,
            cmd,
            &keep_fds_open,
        ) catch |err| {
            switch (err) {
                error.IsClientProc => {
                    defer lib_posix.close(server_sock_fd);
                    // send a msg to the client that the session was created.
                    if (!self.quiet) {
                        var w_buf: [2048]u8 = undefined;
                        var w = std.Io.File.stdout().writerStreaming(io, &w_buf);
                        try w.interface.print("session \"{s}\" created\n", .{sesh_name});
                        try w.interface.flush();
                    }
                    return false;
                },
                else => {
                    lib_posix.close(server_sock_fd);
                    dir.deleteFile(io, self.session_name) catch {};
                    return err;
                },
            }
        };
        // =======
        // WARNING: cannot use upstream allocator or io after this point since
        // we forked the process and there's a risk of a mutex (e.g. thread-safe
        // allocator) being locked by a thread prior to fork which can cause a
        // deadlock.
        // =======

        self.pid = pty_info.pid;
        self.child = .{ .pid = pty_info.pid };

        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        const new_io = threaded.io();

        { // re-initialize logs with the session name as the filename
            log.log_system.deinit();
            var log_buf: [4096]u8 = undefined;
            const session_log_name = try std.fmt.bufPrint(
                &log_buf,
                "{s}.log",
                .{sesh_name},
            );
            var fba_buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
            const session_log_path = try std.fs.path.join(
                fba.allocator(),
                &.{ self.cfg.log_dir, session_log_name },
            );
            const log_mode = std.Io.File.Permissions.fromMode(@intCast(self.cfg.log_mode));
            log.log_system.init(new_io, session_log_path, log_mode) catch {};
        }

        const gpa: std.mem.Allocator = blk: {
            if (builtin.mode == .debug) {
                const GPA = std.heap.DebugAllocator(.{});
                const Static = struct {
                    var gpa: GPA = .{};
                };
                break :blk Static.gpa.allocator();
            }
            break :blk std.heap.c_allocator;
        };

        defer {
            // Close and unlink the listen socket BEFORE handleKill()'s
            // 500ms SIGHUP->SIGKILL grace sleep. Otherwise a `zmx run`
            // for the same name issued in that window will hang waiting
            // for a connect.
            lib_posix.close(server_sock_fd);
            std.log.info("deleting socket file session={s}", .{sesh_name});
            dir.deleteFile(new_io, sesh_name) catch |err| {
                std.log.warn("failed to delete socket file err={s}", .{@errorName(err)});
            };
            self.handleKill(gpa, new_io);
            self.deinit(gpa);
            lib_posix.close(pty_info.master_fd);
        }

        try daemonLoop(self, gpa, new_io, server_sock_fd, pty_info.master_fd);
        std.log.info("daemon loop shutdown", .{});
        return true;
    }

    fn setLeader(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        std.log.info("setting new leader client_fd={d}", .{client.socket_fd});
        // Send a resize message to the client so it can send us back their window size
        // so we can resize the pty and ghostty state.
        try ipc.appendMessage(gpa, &client.write_buf, .Resize, "");
        self.leader_client_fd = client.socket_fd;
        client.has_pending_output = true;
    }

    fn getLeaderClient(self: *Daemon) ?*Client {
        for (self.clients.items) |client| {
            if (self.leader_client_fd == client.socket_fd) {
                return client;
            }
        }
        return null;
    }

    const PTY_WRITE_BUF_MAX = 256 * 1024;

    /// Queue bytes for the PTY's stdin. Flushed by daemonLoop on POLLOUT.
    /// Drops the payload if the buffer is over cap -- same failure mode as
    /// the old direct-write ptyWrite (drop on EAGAIN), just at a 64x higher
    /// threshold. Capping avoids OOM when the shell stops reading; dropping
    /// new (not old) bytes avoids tearing a partially-accepted sequence.
    fn queuePtyInput(self: *Daemon, gpa: std.mem.Allocator, data: []const u8) void {
        if (data.len == 0) return;
        if (self.pty_write_buf.items.len + data.len > PTY_WRITE_BUF_MAX) {
            std.log.warn(
                "pty input dropped {d} bytes (buffer full, shell not reading)",
                .{data.len},
            );
            return;
        }

        // NOTE: for local dev only
        // std.log.debug("buffering pty input data={x}", .{data});

        self.pty_write_buf.appendSlice(gpa, data) catch |err| {
            std.log.warn(
                "pty input dropped {d} bytes: {s}",
                .{ data.len, @errorName(err) },
            );
        };
    }

    pub fn handleInput(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        term: *const ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        var filtered: ?[]const u8 = null;
        defer if (filtered) |buf| gpa.free(buf);

        const input = if (!util.isMouseTrackingEnabled(&term.modes)) blk: {
            const stripped = try util.stripMouseInput(gpa, payload);
            filtered = stripped;
            if (stripped.len == 0) return;
            break :blk stripped;
        } else payload;

        // client is leader, send entire payload (ansi escape codes + text)
        if (self.leader_client_fd == client.socket_fd) {
            self.queuePtyInput(gpa, input);
            return;
        }

        // check if leader needs to be updated by detecting any user input
        if (util.isUserInput(input)) {
            try self.setLeader(gpa, client);
            self.queuePtyInput(gpa, input);
        }
    }

    /// Queue input from `zmx send` without changing interactive client leadership.
    pub fn handleSend(self: *Daemon, gpa: std.mem.Allocator, payload: []const u8) void {
        self.queuePtyInput(gpa, payload);
    }

    pub fn handleSwitch(self: *Daemon, gpa: std.mem.Allocator, session_name: []const u8) !void {
        for (self.clients.items) |client| {
            if (self.leader_client_fd == client.socket_fd) {
                // Include the daemon's current cwd so the new session can start
                // in the right directory. A remote cwd is left out: it names no
                // directory here, so the new session is better off with the
                // attaching client's own cwd than with a path it cannot enter.
                if (self.cwd.len > 0 and self.cwd_path.len > 0) {
                    var payload = gpa.alloc(u8, session_name.len + 1 + self.cwd.len) catch return;
                    defer gpa.free(payload);
                    @memcpy(payload[0..session_name.len], session_name);
                    payload[session_name.len] = '\n';
                    @memcpy(payload[session_name.len + 1 ..], self.cwd);
                    ipc.appendMessage(gpa, &client.write_buf, .Switch, payload) catch |err| {
                        std.log.warn(
                            "failed to buffer terminal state for client err={s}",
                            .{@errorName(err)},
                        );
                    };
                } else {
                    ipc.appendMessage(gpa, &client.write_buf, .Switch, session_name) catch |err| {
                        std.log.warn(
                            "failed to buffer terminal state for client err={s}",
                            .{@errorName(err)},
                        );
                    };
                }
                client.has_pending_output = true;
                return;
            }
        }
    }

    /// False tells the message loop to skip the rest of this client's batch,
    /// including Info and the socket flush. Rejection never shuts down a session.
    fn dispatchInit(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        term: *ghostty_vt.Terminal,
        stream: *const ghostty_vt.TerminalStream,
        payload: []const u8,
        io: anytype,
    ) bool {
        self.handleInit(gpa, client, term, stream, payload, io) catch |err| {
            io.reject(gpa, self, client, err);
            return false;
        };
        return true;
    }

    fn dispatchInfo(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        term: *ghostty_vt.Terminal,
        io: anytype,
    ) bool {
        self.handleInfo(gpa, client, term) catch |err| {
            io.reject(gpa, self, client, err);
            return false;
        };
        return true;
    }

    fn handleInit(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        term: *ghostty_vt.Terminal,
        stream: *const ghostty_vt.TerminalStream,
        payload: []const u8,
        io: anytype,
    ) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return error.InvalidInit;
        const resize = std.mem.bytesToValue(ipc.Resize, payload);
        if (resize.rows == 0 or resize.cols == 0) return error.InvalidInit;

        const will_be_leader = self.leader_client_fd == null or self.leader_client_fd == client.socket_fd;

        // Resize our terminal (not yet the PTY) to the leader's size before
        // serializing, so the snapshot is laid out for the width the client
        // will render it at instead of being wrapped a second time on arrival.
        if (will_be_leader) {
            try resizeTerm(gpa, term, resize.cols, resize.rows);
        }

        if (try client.admission.prepareInit(
            gpa,
            &client.write_buf,
            term,
            stream,
            self.has_pty_output,
            self.has_had_client,
            resize.rows,
        )) {
            client.has_pending_output = true;
        }

        if (self.leader_client_fd == null) {
            try self.setLeader(gpa, client);
        }

        client.is_terminal = true;
        self.has_had_client = true;

        // only resize if leader
        if (self.leader_client_fd == client.socket_fd) {
            io.resize(self, resize);
            std.log.debug("init resize rows={d} cols={d}", .{ resize.rows, resize.cols });
        }
    }

    pub fn handleResize(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        pty_fd: i32,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return;
        if (self.leader_client_fd == null) {
            try self.setLeader(gpa, client);
        }
        // only leader can resize
        if (self.leader_client_fd != client.socket_fd) return;

        const resize = std.mem.bytesToValue(ipc.Resize, payload);
        var ws = resize.winsize();
        _ = cross.ioctl(pty_fd, cross.TIOCSWINSZ, &ws);
        try resizeTerm(gpa, term, resize.cols, resize.rows);
        std.log.debug("resize rows={d} cols={d}", .{ resize.rows, resize.cols });
    }

    pub fn handleDetach(self: *Daemon, gpa: std.mem.Allocator, client: *Client, i: usize) void {
        std.log.info("client detach session={s} fd={d}", .{ self.session_name, client.socket_fd });
        _ = self.closeClient(gpa, client, i, false);
    }

    pub fn handleDetachAll(self: *Daemon, gpa: std.mem.Allocator) void {
        std.log.info("detach all clients={d}", .{self.clients.items.len});
        // Go through closeClient so the leader is cleared like any other detach.
        while (self.clients.items.len > 0) {
            const last = self.clients.items.len - 1;
            _ = self.closeClient(gpa, self.clients.items[last], last, false);
        }
    }

    pub fn handleKill(self: *Daemon, gpa: std.mem.Allocator, io: std.Io) void {
        std.log.info("kill received session={s}", .{self.session_name});
        self.shutdown(gpa);
        self.child.finish(ChildCleanupIo{ .io = io });
    }

    /// Runs after the first producer EOF, never polling the dead PTY/listener.
    /// Only cancellation messages are accepted; final queues cannot be extended
    /// by new Init/Info/application work after the producer has ended.
    fn drainFinalOutput(
        self: *Daemon,
        gpa: std.mem.Allocator,
        window: *const FinalOutputWindow,
        poll_fds: *std.ArrayList(lib_posix.pollfd),
        io: anytype,
    ) !void {
        while (self.clients.items.len > 0) {
            var index = self.clients.items.len;
            while (index > 0) {
                index -= 1;
                const client = self.clients.items[index];
                if (client.write_buf.items.len == 0)
                    io.closeClient(gpa, self, client, index, .drained);
            }
            if (self.clients.items.len == 0) return;
            const timeout_ms = window.remainingMs(io.now());
            if (timeout_ms == 0) {
                self.closeFinalOutput(gpa, io, .deadline);
                return;
            }

            poll_fds.clearRetainingCapacity();
            // Reuse the live loop's capacity (listener + PTY + signal + clients).
            // The drain needs only signal + clients, including a just-accepted
            // client, so no allocation is needed after EOF.
            poll_fds.appendAssumeCapacity(.{ .fd = io.signal_fd, .events = lib_posix.POLL.IN, .revents = 0 });
            for (self.clients.items) |client| {
                poll_fds.appendAssumeCapacity(.{
                    .fd = client.socket_fd,
                    .events = lib_posix.POLL.OUT | @as(i16, if (client.drain_read_closed) 0 else lib_posix.POLL.IN),
                    .revents = 0,
                });
            }
            try io.poll(poll_fds.items, timeout_ms);
            if (poll_fds.items[0].revents & lib_posix.POLL.IN != 0) {
                self.closeFinalOutput(gpa, io, .cancelled);
                return;
            }
            if (poll_fds.items[0].revents != 0) return error.InvalidSignalPipe;
            index = self.clients.items.len;
            clients: while (index > 0) {
                if (window.remainingMs(io.now()) == 0) {
                    self.closeFinalOutput(gpa, io, .deadline);
                    return;
                }
                index -= 1;
                const client = self.clients.items[index];
                const events = poll_fds.items[index + 1].revents;
                if (events & (lib_posix.POLL.ERR | lib_posix.POLL.NVAL | lib_posix.POLL.HUP) != 0) {
                    io.closeClient(gpa, self, client, index, .peer_failure);
                    continue;
                }
                if (events & lib_posix.POLL.IN != 0) {
                    const n: ?usize = io.read(client) catch |err| blk: {
                        if (err == error.WouldBlock) break :blk null;
                        if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                            io.closeClient(gpa, self, client, index, .peer_failure);
                            continue :clients;
                        }
                        std.log.warn("final output input disabled fd={d} err={s}", .{
                            client.socket_fd, @errorName(err),
                        });
                        client.drain_read_closed = true;
                        break :blk null;
                    };
                    if (n == 0) client.drain_read_closed = true;
                    while (client.read_buf.next()) |msg| {
                        switch (msg.header.tag) {
                            .Detach => {
                                io.closeClient(gpa, self, client, index, .cancelled);
                                continue :clients;
                            },
                            .DetachAll, .Kill => {
                                self.closeFinalOutput(gpa, io, .cancelled);
                                return;
                            },
                            else => std.log.debug("ignoring IPC after producer EOF tag={d}", .{@backingInt(msg.header.tag)}),
                        }
                    }
                }
                if (events & lib_posix.POLL.OUT != 0) {
                    if (window.remainingMs(io.now()) == 0) {
                        self.closeFinalOutput(gpa, io, .deadline);
                        return;
                    }
                    const n = io.write(client.socket_fd, client.write_buf.items) catch |err| {
                        if (err == error.WouldBlock) continue;
                        io.closeClient(gpa, self, client, index, .peer_failure);
                        continue;
                    };
                    if (n == 0) {
                        io.closeClient(gpa, self, client, index, .peer_failure);
                        continue;
                    }
                    client.write_buf.replaceRange(gpa, 0, n, &.{}) catch unreachable;
                    if (client.write_buf.items.len == 0)
                        io.closeClient(gpa, self, client, index, .drained);
                }
            }
        }
    }

    fn closeFinalOutput(self: *Daemon, gpa: std.mem.Allocator, io: anytype, reason: FinalOutputClose) void {
        while (self.clients.items.len > 0) {
            const index = self.clients.items.len - 1;
            io.closeClient(gpa, self, self.clients.items[index], index, reason);
        }
    }

    pub fn handleInfo(self: *Daemon, gpa: std.mem.Allocator, client: *Client, term: *ghostty_vt.Terminal) !void {
        self.setPwd(term);

        // zeroes() so asBytes() doesn't ship struct padding + unused cmd/cwd
        // tail bytes (daemon stack contents) to clients.
        var info = std.mem.zeroes(ipc.Info);
        info.protocol_version = ipc.PROTOCOL_VERSION;
        info.clients_len = self.clients.items.len - 1;
        info.pid = self.pid;
        info.created_at = self.created_at;
        info.task_ended_at = self.task_ended_at orelse 0;
        info.task_exit_code = self.task_exit_code orelse 0;

        // Build command string from args, re-quoting args that contain
        // shell-special characters so the displayed command is copy-pasteable.
        const cur_cmd = self.command;
        if (cur_cmd) |args| {
            for (args, 0..) |arg, i| {
                const quoted = if (util.shellNeedsQuoting(arg))
                    util.shellQuote(gpa, arg) catch null
                else
                    null;
                defer if (quoted) |q| gpa.free(q);
                const src = quoted orelse arg;

                const need = src.len + @as(usize, if (i > 0) 1 else 0);
                if (info.cmd_len + need > ipc.MAX_CMD_LEN) {
                    const ellipsis = "...";
                    if (info.cmd_len + ellipsis.len <= ipc.MAX_CMD_LEN) {
                        @memcpy(info.cmd[info.cmd_len..][0..ellipsis.len], ellipsis);
                        info.cmd_len += ellipsis.len;
                    }
                    break;
                }

                if (i > 0) {
                    info.cmd[info.cmd_len] = ' ';
                    info.cmd_len += 1;
                }
                @memcpy(info.cmd[info.cmd_len..][0..src.len], src);
                info.cmd_len += @intCast(src.len);
            }
        }

        info.cwd_len = @intCast(@min(self.cwd.len, ipc.MAX_CWD_LEN));
        @memcpy(info.cwd[0..info.cwd_len], self.cwd[0..info.cwd_len]);

        try ipc.appendMessage(gpa, &client.write_buf, .Info, std.mem.asBytes(&info));
        client.has_pending_output = true;
    }

    pub fn handleHistory(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        self.setPwd(term);
        const format: util.HistoryFormat = if (payload.len > 0)
            @fromBackingInt(@intCast(payload[0]))
        else
            .plain;
        if (util.serializeTerminal(gpa, term, format)) |output| {
            defer gpa.free(output);
            try ipc.appendMessage(gpa, &client.write_buf, .History, output);
            client.has_pending_output = true;
        } else {
            try ipc.appendMessage(gpa, &client.write_buf, .History, "");
            client.has_pending_output = true;
        }
    }

    pub fn handleCapture(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Capture)) return;
        const request = std.mem.bytesToValue(ipc.Capture, payload);
        const format = std.enums.fromInt(util.HistoryFormat, request.format) orelse return;
        self.setPwd(term);
        const output = util.serializeTerminalRange(gpa, term, format, request.rows);
        defer if (output) |text| gpa.free(text);
        try ipc.appendMessage(gpa, &client.write_buf, .Capture, output orelse "");
        client.has_pending_output = true;
    }

    pub fn handleRun(self: *Daemon, gpa: std.mem.Allocator, io: std.Io, client: *Client, payload: []const u8) !void {
        // Reset task tracking so the new command's exit marker is detected.
        // Without this, a second `zmx run` on the same session is ignored
        // because task_exit_code is still set from the first run.
        self.task_exit_code = null;
        self.task_ended_at = null;
        self.is_task_mode = true;
        self.has_had_client = true;
        self.task_id = util.generateTaskId(io);

        if (payload.len == 0) return;

        const cmd = payload;

        // Chain the exit marker with `;` on the same line. `$?` captures the
        // exit code of the command (not the `;`). The sole exception is when
        // the command contains a heredoc (`<<`), the delimiter must be alone
        // on its line, so the marker goes on the next line instead.
        var buf: [1024]u8 = undefined;
        const marker = try util.getTaskExitMarker(&buf, self.task_id);
        var single_buf: [1024]u8 = undefined;
        const single_line_marker = try std.fmt.bufPrint(&single_buf, "; echo {s}$?\r", .{marker});
        var here_buf: [1024]u8 = undefined;
        const heredoc_marker = try std.fmt.bufPrint(&here_buf, "\r\necho {s}$?\r", .{marker});
        const uses_heredoc = std.mem.indexOf(u8, cmd, "<<") != null;

        if (cmd.len > 0 and cmd[cmd.len - 1] == '\r') {
            self.queuePtyInput(gpa, cmd[0 .. cmd.len - 1]);
        } else {
            self.queuePtyInput(gpa, cmd);
        }
        self.queuePtyInput(gpa, if (uses_heredoc) heredoc_marker else single_line_marker);

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
        std.log.debug("run command len={d}", .{payload.len});
    }

    /// Store the session's working directory as a plain path.
    ///
    /// Accepts either an OSC 7 value (`file://<host><path>`, percent-encoded)
    /// or a path. Decoding here rather than at each use keeps `zmx list`
    /// printing a path and lets the chdir on session create find directories
    /// whose names needed escaping.
    ///
    /// The value is copied, so callers may pass a temporary.
    pub fn setCwd(self: *Daemon, value: []const u8) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = std.posix.gethostname(&host_buf) catch "";
        const cwd = util.parseOsc7Cwd(&buf, value, hostname) orelse {
            std.log.warn("ignoring unusable cwd={s}", .{value});
            return;
        };

        // Store the URI form. A caller that handed us a plain path gets one
        // built here, so `cwd` has the same shape no matter the source. A value
        // that already was a URI is kept verbatim, so `list` shows what the
        // shell actually reported.
        self.cwd = if (std.fs.path.isAbsolute(value))
            util.toOsc7Cwd(&self.cwd_buf, value, hostname) orelse return
        else blk: {
            if (value.len > self.cwd_buf.len) return;
            @memcpy(self.cwd_buf[0..value.len], value);
            break :blk self.cwd_buf[0..value.len];
        };

        // Only keep an openable path when it names a directory on this host.
        if (cwd.is_local and cwd.path.len <= self.cwd_path_buf.len) {
            @memcpy(self.cwd_path_buf[0..cwd.path.len], cwd.path);
            self.cwd_path = self.cwd_path_buf[0..cwd.path.len];
        } else {
            self.cwd_path = "";
        }
        std.log.info("set cwd={s} path={s}", .{ self.cwd, self.cwd_path });
    }

    fn setPwd(self: *Daemon, term: *ghostty_vt.Terminal) void {
        const pwd = term.getPwd() orelse return;
        if (std.mem.eql(u8, self.cwd, pwd)) return;
        self.setCwd(pwd);
    }

    pub fn handleOutput(self: *Daemon, gpa: std.mem.Allocator, payload: []const u8, term: *ghostty_vt.Terminal, vt_stream: anytype) !void {
        vt_stream.nextSlice(payload);
        self.setPwd(term);
        self.has_pty_output = true;
        for (self.clients.items) |client| {
            if (try client.admission.output(gpa, &client.write_buf, payload)) {
                client.has_pending_output = true;
            }
        }
        if (self.clients.items.len > 0) {
            lib_posix.kill(self.pid, lib_posix.SIG.WINCH) catch |err| {
                std.log.warn("failed to send SIGWINCH err={s}", .{@errorName(err)});
            };
        }
    }

    pub fn handleWrite(self: *Daemon, gpa: std.mem.Allocator, client: *Client, payload: []const u8) !void {
        // Wire format: [u32 path len][path bytes][file content]
        if (payload.len < @sizeOf(u32)) return error.InvalidPayload;
        const path_len = std.mem.bytesToValue(u32, payload[0..@sizeOf(u32)]);
        if (payload.len < @sizeOf(u32) + path_len) return error.InvalidPayload;
        self.has_had_client = true;
        const file_path = payload[@sizeOf(u32)..][0..path_len];
        const file_content = payload[@sizeOf(u32) + path_len ..];

        // Inject file creation through the PTY so it works over SSH.
        // Base64-encode content and pipe through printf | base64 -d > file.
        // Chunk large files to stay under command-line length limits.
        // 48000 is divisible by 3 (clean base64 boundaries) and encodes
        // to ~64KB, well under typical ARG_MAX.
        // The commands skip queuePtyInput's cap: it would drop the chunks
        // past PTY_WRITE_BUF_MAX and leave the file cut short. The payload
        // is already bounded by ipc.MAX_PAYLOAD_LEN.
        const chunk_size = 48000;
        var offset: usize = 0;
        var is_first = true;

        while (offset < file_content.len or is_first) {
            const end = @min(offset + chunk_size, file_content.len);
            const chunk = file_content[offset..end];

            const encoded_len = std.base64.standard.Encoder.calcSize(chunk.len);
            const encoded = try gpa.alloc(u8, encoded_len);
            defer gpa.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, chunk);

            try self.pty_write_buf.appendSlice(gpa, "printf '%s' '");
            try self.pty_write_buf.appendSlice(gpa, encoded);
            if (is_first) {
                try self.pty_write_buf.appendSlice(gpa, "' | base64 -d > '");
            } else {
                try self.pty_write_buf.appendSlice(gpa, "' | base64 -d >> '");
            }
            try self.pty_write_buf.appendSlice(gpa, file_path);
            try self.pty_write_buf.appendSlice(gpa, "'");
            try self.pty_write_buf.appendSlice(gpa, "\r");

            offset = end;
            is_first = false;
        }

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
        std.log.debug(
            "write command len={d} file_path={s}",
            .{ file_content.len, file_path },
        );
    }

    fn handleEnvGet(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        const leader_opt = self.getLeaderClient();
        const payload = if (leader_opt) |leader| leader.env_str orelse "" else "";
        try ipc.appendMessage(gpa, &client.write_buf, .EnvData, payload);
        client.has_pending_output = true;
    }

    fn handleEnvSet(_: *Daemon, gpa: std.mem.Allocator, client: *Client, env_str: []const u8) !void {
        std.log.info("handle env set payload={s}", .{env_str});
        try client.setEnv(gpa, env_str);

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
    }

    fn handleLabelGet(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        const out = try label.labelsToU8(gpa, self.labels);
        defer gpa.free(out);
        try ipc.appendMessage(gpa, &client.write_buf, .LabelData, out);
        client.has_pending_output = true;
    }

    fn handleLabelSet(self: *Daemon, gpa: std.mem.Allocator, client: *Client, labels: []const u8) !void {
        std.log.info("handle label set payload={s}", .{labels});

        var kvs = label.LabelIterator.init(labels);
        while (kvs.next()) |kv| {
            if (kv.value.len == 0) {
                if (self.labels.fetchRemove(kv.key)) |existing| {
                    gpa.free(existing.key);
                    gpa.free(existing.value);
                }
                continue;
            }

            const owned_key = try gpa.dupe(u8, kv.key);
            errdefer gpa.free(owned_key);
            const owned_value = try gpa.dupe(u8, kv.value);
            errdefer gpa.free(owned_value);
            if (try self.labels.fetchPut(gpa, owned_key, owned_value)) |existing| {
                // fetchPut does NOT replace the key in the map, the old
                // key pointer stays. So free the new (unused) key and the
                // old value.
                gpa.free(owned_key);
                gpa.free(existing.value);
            }
        }

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
    }

    fn handleLabelClear(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        var it = self.labels.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.labels.clearRetainingCapacity();
        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
    }
};

test "daemon deinit leaves the caller-owned socket path intact" {
    var cfg = Cfg{ .socket_dir = "", .log_dir = "" };
    var socket_path = "/tmp/zmx-test/socket".*;
    var daemon = Daemon.init(std.testing.io, &cfg, "test", &socket_path);

    daemon.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/tmp/zmx-test/socket", &socket_path);
}

test "terminal retains the configured scrollback without the default byte cap" {
    const alloc = std.testing.allocator;
    const cfg = Cfg{ .socket_dir = "", .log_dir = "" };
    var term = try initTerminal(alloc, std.testing.io, .{ .cols = 80, .rows = 24 }, &cfg);
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("first line\r\n");
    for (1..cfg.max_scrollback_lines) |_| stream.nextSlice("more output\r\n");

    const history = util.serializeTerminal(alloc, &term, .plain) orelse return error.TestUnexpectedNull;
    defer alloc.free(history);
    try std.testing.expect(std.mem.startsWith(u8, history, "first line\n"));

    // Exceed the limit comfortably because Ghostty prunes whole pages.
    for (0..cfg.max_scrollback_lines) |_| stream.nextSlice("more output\r\n");
    stream.nextSlice("latest line\r\n");

    const pruned_history = util.serializeTerminal(alloc, &term, .plain) orelse return error.TestUnexpectedNull;
    defer alloc.free(pruned_history);
    try std.testing.expect(std.mem.indexOf(u8, pruned_history, "first line") == null);
    try std.testing.expect(std.mem.indexOf(u8, pruned_history, "latest line") != null);
}

fn testDaemon() Daemon {
    return .{
        .cfg = undefined,
        .clients = .empty,
        .leader_client_fd = null,
        .session_name = "test",
        .socket_path = "",
        .running = true,
        .pid = 0,
        .created_at = 0,
    };
}

fn testClient(alloc: std.mem.Allocator, fd: i32, is_terminal: bool) !*Client {
    const c = try alloc.create(Client);
    c.* = .{ .alloc = alloc, .socket_fd = fd, .read_buf = try ipc.SocketBuffer.init(alloc), .write_buf = .empty };
    c.is_terminal = is_terminal;
    return c;
}

test "hasTerminalClient follows attach, detach and detach-all" {
    const alloc = std.testing.allocator;
    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);

    // Real fds (pipes) so Client.deinit's close() is legal.
    const a = try lib_posix.pipe2(.{});
    const b = try lib_posix.pipe2(.{});

    try std.testing.expect(!daemon.hasTerminalClient());

    // A run/send/tail client doesn't count.
    const tail_client = try testClient(alloc, a[0], false);
    try daemon.clients.append(alloc, tail_client);
    try std.testing.expect(!daemon.hasTerminalClient());

    // An attach client does, until it disconnects.
    const term_client = try testClient(alloc, a[1], true);
    try daemon.clients.append(alloc, term_client);
    try std.testing.expect(daemon.hasTerminalClient());
    _ = daemon.closeClient(alloc, tail_client, 0, false);
    try std.testing.expect(daemon.hasTerminalClient());
    _ = daemon.closeClient(alloc, term_client, 0, false);
    try std.testing.expect(!daemon.hasTerminalClient());

    try daemon.clients.append(alloc, try testClient(alloc, b[0], true));
    try daemon.clients.append(alloc, try testClient(alloc, b[1], true));
    daemon.handleDetachAll(alloc);
    try std.testing.expect(!daemon.hasTerminalClient());
    try std.testing.expectEqual(@as(?i32, null), daemon.leader_client_fd);
}

test "send queues PTY input without changing leader" {
    const alloc = std.testing.allocator;
    var daemon = testDaemon();
    daemon.leader_client_fd = 42;
    defer daemon.pty_write_buf.deinit(alloc);

    daemon.handleSend(alloc, "hello");

    try std.testing.expectEqual(@as(?i32, 42), daemon.leader_client_fd);
    try std.testing.expectEqualStrings("hello", daemon.pty_write_buf.items);
}

test "handleEnvGet returns leader client's environment variables including unsets" {
    const alloc = std.testing.allocator;
    var cfg = Cfg{
        .socket_dir = "/tmp",
        .log_dir = "/tmp",
    };

    var daemon = Daemon{
        .cfg = &cfg,
        .clients = .empty,
        .session_name = "test",
        .socket_path = try alloc.dupe(u8, ""),
        .running = true,
        .pid = 0,
        .created_at = 0,
    };
    defer daemon.deinit(alloc);

    const fds1 = try lib_posix.pipe2(.{});
    defer lib_posix.close(fds1[1]);
    var client1 = Client{
        .alloc = alloc,
        .socket_fd = fds1[0],
        .read_buf = try ipc.SocketBuffer.init(alloc),
        .write_buf = std.ArrayList(u8).empty,
    };
    defer client1.deinit(alloc);
    try client1.setEnv(alloc, "DISPLAY=:1\nSSH_AUTH_SOCK=/tmp/ssh-1\nKITTY_LISTEN_ON=unix:/tmp/kitty-1\n-WINDOWID\n");

    const fds2 = try lib_posix.pipe2(.{});
    defer lib_posix.close(fds2[1]);
    var client2 = Client{
        .alloc = alloc,
        .socket_fd = fds2[0],
        .read_buf = try ipc.SocketBuffer.init(alloc),
        .write_buf = std.ArrayList(u8).empty,
    };
    defer client2.deinit(alloc);
    try client2.setEnv(alloc, "SSH_AUTH_SOCK=/tmp/ssh-2\nWINDOWID=12345\nKITTY_LISTEN_ON=unix:/tmp/kitty-2\n-DISPLAY\n");

    const fds_req = try lib_posix.pipe2(.{});
    defer lib_posix.close(fds_req[1]);
    var client_req = Client{
        .alloc = alloc,
        .socket_fd = fds_req[0],
        .read_buf = try ipc.SocketBuffer.init(alloc),
        .write_buf = std.ArrayList(u8).empty,
    };
    defer client_req.deinit(alloc);

    try daemon.clients.append(alloc, &client1);
    try daemon.clients.append(alloc, &client2);

    // No leader yet -> handleEnvGet returns empty string payload
    try daemon.handleEnvGet(alloc, &client_req);
    try std.testing.expect(client_req.write_buf.items.len > 0);
    client_req.write_buf.clearRetainingCapacity();

    // Set client1 as leader
    try daemon.setLeader(alloc, &client1);
    try std.testing.expectEqual(@as(?i32, fds1[0]), daemon.leader_client_fd);
    try daemon.handleEnvGet(alloc, &client_req);
    // Wire message: [Header][Payload]
    const pay1 = client_req.write_buf.items[@sizeOf(ipc.Header)..];
    try std.testing.expectEqualStrings("DISPLAY=:1\nSSH_AUTH_SOCK=/tmp/ssh-1\nKITTY_LISTEN_ON=unix:/tmp/kitty-1\n-WINDOWID\n", pay1);
    client_req.write_buf.clearRetainingCapacity();

    // Switch leader to client2
    try daemon.setLeader(alloc, &client2);
    try std.testing.expectEqual(@as(?i32, fds2[0]), daemon.leader_client_fd);
    try daemon.handleEnvGet(alloc, &client_req);
    const pay2 = client_req.write_buf.items[@sizeOf(ipc.Header)..];
    try std.testing.expectEqualStrings("SSH_AUTH_SOCK=/tmp/ssh-2\nWINDOWID=12345\nKITTY_LISTEN_ON=unix:/tmp/kitty-2\n-DISPLAY\n", pay2);
    client_req.write_buf.clearRetainingCapacity();

    // Client2 updates env
    try daemon.handleEnvSet(alloc, &client2, "DISPLAY=:99\n");
    try daemon.handleEnvGet(alloc, &client_req);
    const pay3 = client_req.write_buf.items[@sizeOf(ipc.Header)..];
    try std.testing.expectEqualStrings("DISPLAY=:99\n", pay3);
}

test "attachment: setup failures reject only the attaching client" {
    const testing = std.testing;
    const Observed = struct {
        rejected: ?anyerror = null,
        closed_fd: ?i32 = null,
        queued_at_close: usize = 0,
        info_at_close: bool = false,
        resize_calls: usize = 0,
    };
    const MemoryIo = struct {
        observed: *Observed,
        index: usize,

        fn resize(self: @This(), _: *const Daemon, _: ipc.Resize) void {
            self.observed.resize_calls += 1;
        }

        fn closeFd(_: lib_posix.fd_t) void {}

        fn reject(self: @This(), gpa: std.mem.Allocator, daemon: *Daemon, client: *Client, err: anyerror) void {
            self.observed.rejected = err;
            self.observed.closed_fd = client.socket_fd;
            self.observed.queued_at_close = client.write_buf.items.len;
            var queued: ipc.SocketBuffer = .{
                .buf = client.write_buf,
                .alloc = client.alloc,
                .head = 0,
            };
            while (queued.next()) |msg| {
                if (msg.header.tag == .Info) self.observed.info_at_close = true;
            }
            _ = daemon.closeClientUsing(gpa, client, self.index, false, closeFd);
        }
    };
    var saw_serializer_failure = false;
    var saw_queue_failure = false;
    var saw_info_failure = false;
    var saw_continuation_failure = false;
    var saw_unavailable = false;
    var saw_success = false;
    for (0..4) |cut| {
        for (0..if (cut >= 2) @as(usize, 1) else 8) |fail_index| {
            var source = try ghostty_vt.Terminal.init(testing.io, testing.allocator, .{
                .cols = 80,
                .rows = 24,
            });
            defer source.deinit(testing.allocator);
            var stream = attachment.trackedStream(testing.allocator, &source, if (cut == 2) 4 else 1024);
            defer stream.deinit();
            stream.nextSlice("\x1b[?2026hRETAINED");
            if (cut == 1) stream.nextSlice("\x1b[31");
            if (cut == 2) stream.nextSlice("\x1b[123");
            var cfg: Cfg = .{ .socket_dir = "", .log_dir = "" };
            var daemon: Daemon = .{
                .cfg = &cfg,
                .clients = .empty,
                .leader_client_fd = 101,
                .session_name = "fixture",
                .socket_path = "",
                .running = true,
                .pid = 0,
                .has_pty_output = true,
                .has_had_client = true,
                .created_at = 0,
            };
            defer {
                for (daemon.clients.items) |client| {
                    client.deinitBuffers(testing.allocator);
                    testing.allocator.destroy(client);
                }
                daemon.clients.deinit(testing.allocator);
                daemon.pty_write_buf.deinit(testing.allocator);
            }
            for ([_]i32{ 101, 102 }) |fd| {
                const client = try testing.allocator.create(Client);
                client.* = .{
                    .alloc = testing.allocator,
                    .socket_fd = fd,
                    .is_terminal = fd == 101,
                    .read_buf = try ipc.SocketBuffer.init(testing.allocator),
                    .write_buf = .empty,
                };
                try daemon.clients.append(testing.allocator, client);
            }
            const existing = daemon.clients.items[0];
            try existing.write_buf.ensureTotalCapacity(testing.allocator, 4096);
            const attaching = daemon.clients.items[1];
            attaching.admission.begin();
            const size: ipc.Resize = .{ .cols = 80, .rows = 24 };
            // A later Info is in the same batch. The dispatcher must reject the
            // client and return false before the caller can handle or flush it.
            try ipc.appendMessage(testing.allocator, &attaching.read_buf.buf, .Info, "");
            var failing = testing.FailingAllocator.init(testing.allocator, .{
                .fail_index = if (cut == 3) std.math.maxInt(usize) else fail_index,
            });
            const daemon_alloc = failing.allocator();
            attaching.alloc = daemon_alloc;
            var observed: Observed = .{};
            const memory_io: MemoryIo = .{
                .observed = &observed,
                .index = 1,
            };
            const initialized = daemon.dispatchInit(daemon_alloc, attaching, &source, &stream, std.mem.asBytes(&size), memory_io);
            var accepted = initialized;
            if (initialized) {
                if (cut == 3) {
                    // Require Info to grow the queue regardless of ArrayList growth policy.
                    attaching.write_buf.shrinkAndFree(daemon_alloc, attaching.write_buf.items.len);
                    failing.fail_index = failing.alloc_index;
                    failing.resize_fail_index = failing.resize_index;
                }
                const next = attaching.read_buf.next().?;
                try testing.expectEqual(ipc.Tag.Info, next.header.tag);
                accepted = daemon.dispatchInfo(daemon_alloc, attaching, &source, memory_io);
            }
            if (accepted) {
                saw_success = true;
                try testing.expect(observed.rejected == null);
                continue;
            }
            const failure = observed.rejected.?;
            saw_serializer_failure = saw_serializer_failure or failure == error.TerminalRestoreFailed;
            saw_queue_failure = saw_queue_failure or (!initialized and failure == error.OutOfMemory);
            saw_info_failure = saw_info_failure or initialized;
            saw_continuation_failure = saw_continuation_failure or failure == error.WriteFailed;
            saw_unavailable = saw_unavailable or failure == error.ContinuationUnavailable;
            try testing.expectEqual(@as(?i32, 102), observed.closed_fd);
            if (!initialized) try testing.expectEqual(@as(usize, 0), observed.queued_at_close);
            try testing.expect(!observed.info_at_close);
            try testing.expectEqual(@as(usize, 0), observed.resize_calls);
            try testing.expect(daemon.running);
            try testing.expectEqual(@as(usize, 1), daemon.clients.items.len);
            try testing.expectEqual(existing, daemon.clients.items[0]);
            try testing.expectEqual(@as(?i32, 101), daemon.leader_client_fd);
            try testing.expect(daemon.hasTerminalClient() and daemon.has_had_client);
            try testing.expect(source.modes.get(.synchronized_output));
            try testing.expect(try existing.admission.output(daemon_alloc, &existing.write_buf, "still live"));
        }
    }
    try testing.expect(saw_serializer_failure);
    try testing.expect(saw_queue_failure);
    try testing.expect(saw_info_failure);
    try testing.expect(saw_continuation_failure);
    try testing.expect(saw_unavailable);
    try testing.expect(saw_success);
}

const FinalOutputFixture = struct {
    const testing = std.testing;
    const Write = union(enum) { limit: usize, again, broken };
    const Read = enum { eof, out_of_memory, detach, kill, info };
    const Step = struct {
        at_ns: i96,
        events: [2]i16 = .{ lib_posix.POLL.OUT, lib_posix.POLL.OUT },
        writes: [2]Write = .{ .{ .limit = 1_000_000 }, .{ .limit = 1_000_000 } },
        reads: [2]Read = .{ .eof, .eof },
        repeat_eof: bool = false,
        cancel: bool = false,
    };
    const Peer = struct {
        handed: std.ArrayList(u8) = .empty,
        reason: ?FinalOutputClose = null,
        unsent: usize = 0,
        closed_at: i96 = 0,
        writes: usize = 0,
        reads: usize = 0,
        input_closed: bool = false,
    };

    cfg: Cfg = .{ .socket_dir = "", .log_dir = "" },
    daemon: Daemon = undefined,
    term: ghostty_vt.Terminal = undefined,
    window: FinalOutputWindow = .{},
    polls: std.ArrayList(lib_posix.pollfd) = .empty,
    peers: [2]Peer = .{ .{}, .{} },
    signal_fd: lib_posix.fd_t = 900,
    time_ns: i96 = 0,
    steps: []const Step = &.{},
    next_step: usize = 0,
    timeouts: [16]i32 = undefined,
    half_close_observed: bool = false,

    fn init(self: *@This(), steps: []const Step) !void {
        self.* = .{ .steps = steps };
        self.term = try ghostty_vt.Terminal.init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
        self.daemon = .{
            .cfg = &self.cfg,
            .clients = .empty,
            .leader_client_fd = 101,
            .session_name = "fixture",
            .socket_path = "",
            .running = true,
            .pid = 123,
            .created_at = 0,
            .child = .{ .pid = 123 },
        };
        self.polls = try .initCapacity(testing.allocator, 8);
        for ([_]i32{ 101, 102 }) |fd| {
            const client = try testing.allocator.create(Client);
            client.* = .{
                .alloc = testing.allocator,
                .socket_fd = fd,
                .read_buf = try ipc.SocketBuffer.init(testing.allocator),
                .write_buf = .empty,
            };
            try self.daemon.clients.append(testing.allocator, client);
        }
        self.window.observeEof(0);
    }

    fn deinit(self: *@This()) void {
        self.term.deinit(testing.allocator);
        for (self.daemon.clients.items) |client| {
            client.deinitBuffers(testing.allocator);
            testing.allocator.destroy(client);
        }
        self.daemon.clients.deinit(testing.allocator);
        self.polls.deinit(testing.allocator);
        for (&self.peers) |*peer| peer.handed.deinit(testing.allocator);
    }

    fn queue(self: *@This(), peer: usize, data: []const u8, info: bool) ![]u8 {
        const client = self.daemon.clients.items[peer];
        try ipc.appendMessage(testing.allocator, &client.write_buf, .Output, data);
        if (info) try self.daemon.handleInfo(testing.allocator, client, &self.term);
        return testing.allocator.dupe(u8, client.write_buf.items);
    }

    fn run(self: *@This()) !void {
        try self.daemon.drainFinalOutput(testing.allocator, &self.window, &self.polls, self);
        try testing.expectEqual(@as(usize, 0), self.daemon.clients.items.len);
        try testing.expectEqual(@as(?lib_posix.pid_t, 123), self.daemon.child.pid);
        try testing.expectEqual(@as(?i96, FinalOutputWindow.duration_ns), self.window.deadline_ns);
    }

    fn now(self: *@This()) i96 {
        return self.time_ns;
    }

    fn poll(self: *@This(), fds: []lib_posix.pollfd, timeout_ms: i32) !void {
        try testing.expect(self.next_step < self.steps.len);
        try testing.expect(timeout_ms > 0 and timeout_ms <= 5000);
        self.timeouts[self.next_step] = timeout_ms;
        const step = self.steps[self.next_step];
        self.next_step += 1;
        self.time_ns = step.at_ns;
        if (step.repeat_eof) self.window.observeEof(self.time_ns);
        try testing.expectEqual(self.signal_fd, fds[0].fd);
        fds[0].revents = if (step.cancel) lib_posix.POLL.IN else 0;
        for (fds[1..]) |*fd| {
            try testing.expect(fd.fd == 101 or fd.fd == 102);
            const peer: usize = @intCast(fd.fd - 101);
            try testing.expect(self.peers[peer].reason == null);
            if (self.peers[peer].input_closed) {
                try testing.expect(fd.events & lib_posix.POLL.IN == 0);
                self.half_close_observed = true;
            }
            fd.revents = step.events[peer];
        }
    }

    fn read(self: *@This(), client: *Client) !usize {
        const peer: usize = @intCast(client.socket_fd - 101);
        self.peers[peer].reads += 1;
        const action = self.steps[self.next_step - 1].reads[peer];
        const tag: ipc.Tag = switch (action) {
            .eof => {
                self.peers[peer].input_closed = true;
                return 0;
            },
            .out_of_memory => {
                self.peers[peer].input_closed = true;
                return error.OutOfMemory;
            },
            .detach => .Detach,
            .kill => .Kill,
            .info => .Info,
        };
        try ipc.appendMessage(testing.allocator, &client.read_buf.buf, tag, "");
        return @sizeOf(ipc.Header);
    }

    fn write(self: *@This(), fd: lib_posix.fd_t, bytes: []const u8) !usize {
        const peer: usize = @intCast(fd - 101);
        self.peers[peer].writes += 1;
        const n = switch (self.steps[self.next_step - 1].writes[peer]) {
            .limit => |limit| @min(limit, bytes.len),
            .again => return error.WouldBlock,
            .broken => return error.BrokenPipe,
        };
        try self.peers[peer].handed.appendSlice(testing.allocator, bytes[0..n]);
        return n;
    }

    fn closeFd(_: lib_posix.fd_t) void {}

    fn closeClient(self: *@This(), gpa: std.mem.Allocator, daemon: *Daemon, client: *Client, index: usize, reason: FinalOutputClose) void {
        const peer: usize = @intCast(client.socket_fd - 101);
        assert(self.peers[peer].reason == null);
        self.peers[peer].reason = reason;
        self.peers[peer].unsent = client.write_buf.items.len;
        self.peers[peer].closed_at = self.time_ns;
        _ = daemon.closeClientUsing(gpa, client, index, false, closeFd);
    }
};

test "drain: production loop handles partial writes and EAGAIN independently" {
    const testing = std.testing;
    var fixture: FinalOutputFixture = undefined;
    try fixture.init(&.{
        .{ .at_ns = 0, .writes = .{ .{ .limit = 7 }, .again } },
        .{ .at_ns = std.time.ns_per_s, .writes = .{ .{ .limit = 10000 }, .again } },
        .{ .at_ns = 2 * std.time.ns_per_s, .writes = .{ .again, .{ .limit = 11 } } },
        .{ .at_ns = 3 * std.time.ns_per_s },
    });
    defer fixture.deinit();
    const first = try fixture.queue(0, "healthy", true);
    defer testing.allocator.free(first);
    const second = try fixture.queue(1, &@import("test_data.zig").repeat("final output ", 600), true);
    defer testing.allocator.free(second);
    try fixture.run();
    try testing.expectEqualSlices(u8, first, fixture.peers[0].handed.items);
    try testing.expectEqualSlices(u8, second, fixture.peers[1].handed.items);
    try testing.expectEqual(@as(i96, std.time.ns_per_s), fixture.peers[0].closed_at);
    try testing.expectEqual(@as(i96, 3 * std.time.ns_per_s), fixture.peers[1].closed_at);
    for (fixture.peers) |peer| {
        try testing.expectEqual(FinalOutputClose.drained, peer.reason.?);
        try testing.expectEqual(@as(usize, 0), peer.unsent);
    }
}

test "drain: exact expiry is fixed across repeated EOF and progress" {
    const testing = std.testing;
    const end = FinalOutputWindow.duration_ns;
    var fixture: FinalOutputFixture = undefined;
    try fixture.init(&.{
        .{ .at_ns = 2 * std.time.ns_per_s, .writes = .{ .{ .limit = 1 }, .again }, .repeat_eof = true },
        .{ .at_ns = end - 1, .writes = .{ .{ .limit = 1 }, .again }, .repeat_eof = true },
        .{ .at_ns = end, .repeat_eof = true },
    });
    defer fixture.deinit();
    inline for (0..2) |index| {
        const data = try fixture.queue(index, "unfinished", true);
        testing.allocator.free(data);
    }
    try fixture.run();
    try testing.expectEqualSlices(i32, &.{ 5000, 3000, 1 }, fixture.timeouts[0..3]);
    try testing.expectEqual(@as(usize, 2), fixture.peers[0].handed.items.len);
    for (fixture.peers) |peer| {
        try testing.expectEqual(FinalOutputClose.deadline, peer.reason.?);
        try testing.expectEqual(@as(i96, end), peer.closed_at);
        try testing.expect(peer.unsent > 0);
        try testing.expectEqual(@as(usize, 2), peer.writes);
    }
}

test "drain: empty queues close without polling or waiting" {
    var fixture: FinalOutputFixture = undefined;
    try fixture.init(&.{});
    defer fixture.deinit();
    try fixture.run();
    try std.testing.expectEqual(@as(usize, 0), fixture.next_step);
    for (fixture.peers) |peer| try std.testing.expectEqual(FinalOutputClose.drained, peer.reason.?);
}

test "drain: interrupted waits keep the original deadline" {
    const testing = std.testing;
    var fixture: FinalOutputFixture = undefined;
    try fixture.init(&.{
        .{ .at_ns = 2 * std.time.ns_per_s, .events = .{ 0, 0 } },
        .{ .at_ns = FinalOutputWindow.duration_ns, .events = .{ 0, 0 } },
    });
    defer fixture.deinit();
    const data = try fixture.queue(0, "pending", true);
    defer testing.allocator.free(data);
    try fixture.run();
    try testing.expectEqualSlices(i32, &.{ 5000, 3000 }, fixture.timeouts[0..2]);
    try testing.expectEqual(@as(usize, 0), fixture.peers[0].writes);
    try testing.expectEqual(FinalOutputClose.deadline, fixture.peers[0].reason.?);
}

test "drain: an already expired window writes nothing" {
    var fixture: FinalOutputFixture = undefined;
    try fixture.init(&.{});
    defer fixture.deinit();
    const data = try fixture.queue(0, "queued", true);
    defer std.testing.allocator.free(data);
    fixture.time_ns = FinalOutputWindow.duration_ns;
    try fixture.run();
    try std.testing.expectEqual(@as(usize, 0), fixture.next_step);
    try std.testing.expectEqual(@as(usize, 0), fixture.peers[0].writes);
    try std.testing.expectEqual(FinalOutputClose.deadline, fixture.peers[0].reason.?);
    try std.testing.expectEqual(FinalOutputClose.drained, fixture.peers[1].reason.?);
}

test "drain: truncated producer snapshot at expiry never supplies Info readiness" {
    const testing = std.testing;
    var fixture: FinalOutputFixture = undefined;
    try fixture.init(&.{
        .{ .at_ns = 0, .writes = .{ .{ .limit = 4096 }, .{ .limit = 10000 } } },
        .{ .at_ns = FinalOutputWindow.duration_ns },
    });
    defer fixture.deinit();
    var term = try ghostty_vt.Terminal.init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 1_000_000,
    });
    defer term.deinit(testing.allocator);
    var stream = attachment.trackedStream(testing.allocator, &term, 1024);
    defer stream.deinit();
    stream.nextSlice(&@import("test_data.zig").repeat("retained output for final snapshot\r\n", 300));
    const client = fixture.daemon.clients.items[0];
    client.admission.begin();
    try testing.expect(try client.admission.prepareInit(
        testing.allocator,
        &client.write_buf,
        &term,
        &stream,
        true,
        false,
        24,
    ));
    try fixture.daemon.handleInfo(testing.allocator, client, &term);
    const healthy = try fixture.queue(1, "healthy", true);
    defer testing.allocator.free(healthy);
    try fixture.run();
    try testing.expect(fixture.peers[0].unsent > 0);
    try testing.expectEqualSlices(u8, healthy, fixture.peers[1].handed.items);
    var decoder = try ipc.SocketBuffer.init(testing.allocator);
    defer decoder.deinit();
    try decoder.buf.appendSlice(testing.allocator, fixture.peers[0].handed.items);
    var receiver: attachment.Receiver = .{};
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(testing.allocator);
    while (decoder.next()) |msg| try receiver.receive(testing.allocator, &output, msg);
    try testing.expect(receiver.boundary_received);
    try testing.expect(!receiver.ready);
    try testing.expectEqual(@as(usize, 0), output.items.len);
}

test "drain: peer failure and explicit cancellation preserve other clients" {
    const testing = std.testing;
    const cases = [_]FinalOutputFixture.Step{
        .{ .at_ns = 0, .writes = .{ .broken, .{ .limit = 10000 } } },
        .{ .at_ns = 0, .events = .{ lib_posix.POLL.IN, lib_posix.POLL.OUT }, .reads = .{ .detach, .eof } },
        .{ .at_ns = 0, .events = .{ lib_posix.POLL.HUP, lib_posix.POLL.OUT } },
        .{ .at_ns = 0, .cancel = true },
        .{ .at_ns = 0, .events = .{ 0, lib_posix.POLL.IN }, .reads = .{ .eof, .kill } },
    };
    for (cases, 0..) |step, case| {
        var fixture: FinalOutputFixture = undefined;
        try fixture.init(&.{step});
        defer fixture.deinit();
        inline for (0..2) |peer| {
            const data = try fixture.queue(peer, "pending", true);
            testing.allocator.free(data);
        }
        try fixture.run();
        const expected: FinalOutputClose = if (case == 0 or case == 2) .peer_failure else .cancelled;
        try testing.expectEqual(expected, fixture.peers[0].reason.?);
        try testing.expect(fixture.peers[0].unsent > 0);
        try testing.expectEqual(if (case < 3) FinalOutputClose.drained else .cancelled, fixture.peers[1].reason.?);
    }
}

test "drain: half close and post-EOF work cannot extend queues or readiness" {
    const testing = std.testing;
    for ([_]FinalOutputFixture.Read{ .eof, .out_of_memory }) |read_action| {
        var fixture: FinalOutputFixture = undefined;
        try fixture.init(&.{
            .{ .at_ns = 0, .events = .{ lib_posix.POLL.IN, lib_posix.POLL.IN }, .reads = .{ read_action, .info } },
            .{ .at_ns = std.time.ns_per_s },
        });
        defer fixture.deinit();
        inline for (0..2) |peer| {
            const data = try fixture.queue(peer, "final bytes", false);
            testing.allocator.free(data);
        }
        try fixture.run();
        try testing.expect(fixture.half_close_observed);
        for (fixture.peers) |peer| {
            try testing.expectEqual(@as(usize, 1), peer.reads);
            var decoder = try ipc.SocketBuffer.init(testing.allocator);
            defer decoder.deinit();
            try decoder.buf.appendSlice(testing.allocator, peer.handed.items);
            try testing.expectEqual(ipc.Tag.Output, decoder.next().?.header.tag);
            try testing.expect(decoder.next() == null);
        }
    }
}

test "drain: child identity is retained through final signal and reaped once" {
    const Recorder = struct {
        const Event = enum { hup, grace, kill, reap };
        events: [4]Event = undefined,
        count: usize = 0,
        child: *RetainedChild,

        fn record(self: *@This(), event: Event) void {
            assert(self.child.pid == 123);
            self.events[self.count] = event;
            self.count += 1;
        }
        fn signalGroup(self: *@This(), pid: lib_posix.pid_t, sig: lib_posix.SIG) void {
            assert(pid == 123);
            self.record(if (sig == .HUP) .hup else .kill);
        }
        fn grace(self: *@This()) void {
            self.record(.grace);
        }
        fn reap(self: *@This(), pid: lib_posix.pid_t) void {
            assert(pid == 123);
            self.record(.reap);
        }
    };
    var child: RetainedChild = .{ .pid = 123 };
    var recorder: Recorder = .{ .child = &child };
    child.finish(&recorder);
    try std.testing.expectEqualSlices(Recorder.Event, &.{ .hup, .grace, .kill, .reap }, &recorder.events);
    try std.testing.expect(child.pid == null);
    child.finish(&recorder);
    try std.testing.expectEqual(@as(usize, 4), recorder.count);
}

test "handleInput: forwards mouse input when enabled and drops late mouse reports after disable" {
    const testing = std.testing;
    var term = try ghostty_vt.Terminal.init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(testing.allocator);
    var stream = attachment.trackedStream(testing.allocator, &term, 1024);
    defer stream.deinit();

    var cfg: Cfg = .{ .socket_dir = "", .log_dir = "" };
    var daemon: Daemon = .{
        .cfg = &cfg,
        .clients = .empty,
        .leader_client_fd = 101,
        .session_name = "fixture",
        .socket_path = "",
        .running = true,
        .pid = 0,
        .created_at = 0,
    };
    defer {
        for (daemon.clients.items) |client| {
            client.deinitBuffers(testing.allocator);
            testing.allocator.destroy(client);
        }
        daemon.clients.deinit(testing.allocator);
        daemon.pty_write_buf.deinit(testing.allocator);
    }

    for ([_]i32{ 101, 102 }) |fd| {
        const client = try testing.allocator.create(Client);
        client.* = .{
            .alloc = testing.allocator,
            .socket_fd = fd,
            .read_buf = try ipc.SocketBuffer.init(testing.allocator),
            .write_buf = .empty,
        };
        try daemon.clients.append(testing.allocator, client);
    }
    const leader = daemon.clients.items[0];
    const follower = daemon.clients.items[1];

    // While TUI enables mouse tracking (?1003h + ?1006h), leader mouse reports reach the PTY.
    stream.nextSlice("\x1b[?1003h\x1b[?1006h");
    try testing.expect(util.isMouseTrackingEnabled(&term.modes));
    try daemon.handleInput(testing.allocator, leader, &term, "\x1b[<35;72;44M");
    try testing.expectEqualStrings("\x1b[<35;72;44M", daemon.pty_write_buf.items);
    daemon.pty_write_buf.clearRetainingCapacity();

    // After TUI exits and disables mouse tracking, in-flight mouse reports are dropped.
    stream.nextSlice("\x1b[?1003l\x1b[?1006l");
    try testing.expect(!util.isMouseTrackingEnabled(&term.modes));
    try daemon.handleInput(testing.allocator, leader, &term, "\x1b[<35;72;44M\x1b[<0;72;44m\x1b[M@!!");
    try testing.expectEqual(@as(usize, 0), daemon.pty_write_buf.items.len);

    // Accompanying keystrokes in the same payload are preserved without mouse garbage.
    try daemon.handleInput(testing.allocator, leader, &term, "\x1b[<35;72;44Mls -la\r");
    try testing.expectEqualStrings("ls -la\r", daemon.pty_write_buf.items);
    daemon.pty_write_buf.clearRetainingCapacity();

    // Follower sending late mouse + keyboard input claims leader and queues only the keystroke.
    try daemon.handleInput(testing.allocator, follower, &term, "\x1b[<35;72;44M");
    try testing.expectEqual(@as(?i32, 101), daemon.leader_client_fd);
    try daemon.handleInput(testing.allocator, follower, &term, "\x1b[<35;72;44Ma");
    try testing.expectEqual(@as(?i32, 102), daemon.leader_client_fd);
    try testing.expectEqualStrings("a", daemon.pty_write_buf.items);
}
