const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const ipc = @import("ipc.zig");
const util = @import("util.zig");

pub fn trackedStream(alloc: std.mem.Allocator, term: *ghostty_vt.Terminal, limit: usize) ghostty_vt.TerminalStream {
    return .init(.{
        .allocator = alloc,
        .handler = term.vtHandler(),
        .continuation_max_bytes = limit,
    });
}

/// A connection is a legacy stream until it explicitly requests a snapshot
/// boundary. In particular, a silent `tail` connection must keep streaming.
pub const Admission = struct {
    state: enum { streaming, pending, terminal } = .streaming,

    pub fn begin(self: *Admission) void {
        if (self.state == .streaming) self.state = .pending;
    }

    pub fn output(
        self: Admission,
        alloc: std.mem.Allocator,
        queue: *std.ArrayList(u8),
        data: []const u8,
    ) !bool {
        // The daemon still feeds these bytes to its terminal. Init will capture
        // their state, so they must not also follow the snapshot as live output.
        if (self.state == .pending) return false;
        try ipc.appendMessage(alloc, queue, .Output, data);
        return true;
    }

    /// Called before the PTY/emulator resize. No descriptors or OS operations.
    pub fn prepareInit(
        self: *Admission,
        alloc: std.mem.Allocator,
        queue: *std.ArrayList(u8),
        term: *ghostty_vt.Terminal,
        stream: *const ghostty_vt.TerminalStream,
        has_output: bool,
        has_had_client: bool,
        client_rows: u16,
    ) !bool {
        const negotiated = self.state == .pending;
        if (self.state == .terminal) return false;
        if (!negotiated and !(has_output and has_had_client)) return false;

        // The visual snapshot excludes incremental VT/UTF-8 decoding state.
        // Ghostty exports only a bounded suffix that replays no committed work.
        var continuation: std.Io.Writer.Allocating = .init(alloc);
        defer continuation.deinit();
        if (negotiated and !stream.ground()) {
            try stream.writeContinuation(&continuation.writer);
            try ghostty_vt.snapshot.continuation.validate(.{ .bytes = continuation.written() });
        }
        const suffix = continuation.written();

        const snapshot = if (has_output)
            util.serializeTerminalStateForClient(alloc, term, client_rows) orelse return error.TerminalRestoreFailed
        else
            null;
        defer if (snapshot) |data| alloc.free(data);
        const rewritten = if (snapshot) |data| util.rewritePromptRedraw(alloc, data) else null;
        defer if (rewritten) |data| alloc.free(data);
        const restore = rewritten orelse snapshot;

        // Do not remove earlier frames: a prefix may already be on the socket.
        // Reserve the complete boundary + snapshot before publishing either.
        const required = @as(usize, if (negotiated) @sizeOf(ipc.Header) else 0) +
            (if (restore) |data| @sizeOf(ipc.Header) + data.len else 0) +
            (if (suffix.len > 0) @sizeOf(ipc.Header) + suffix.len else 0);
        try queue.ensureUnusedCapacity(alloc, required);
        if (negotiated) try ipc.appendMessage(alloc, queue, .Attach, "");
        if (restore) |data| try ipc.appendMessage(alloc, queue, .Output, data);
        if (suffix.len > 0) try ipc.appendMessage(alloc, queue, .Output, suffix);
        if (negotiated) self.state = .terminal;
        return true;
    }
};

/// Attach is optional for older daemons, which ignore unknown tags. Init and
/// Info keep their existing wire shapes and order on this same connection.
pub fn request(alloc: std.mem.Allocator, queue: *std.ArrayList(u8), size: ipc.Resize) !void {
    try ipc.appendMessage(alloc, queue, .Attach, "");
    try ipc.appendMessage(alloc, queue, .Init, std.mem.asBytes(&size));
    try ipc.appendMessage(alloc, queue, .Info, "");
}

pub const Receiver = struct {
    ready: bool = false,
    boundary_received: bool = false,

    pub fn receive(
        self: *Receiver,
        alloc: std.mem.Allocator,
        output: *std.ArrayList(u8),
        msg: ipc.SocketMsg,
    ) !void {
        switch (msg.header.tag) {
            .Attach => {
                if (msg.payload.len != 0 or self.boundary_received or self.ready)
                    return error.InvalidAttachmentBoundary;
                // Nothing before the boundary has been displayed. This also
                // handles complete/partial frames sent before the request arrived.
                output.clearRetainingCapacity();
                self.boundary_received = true;
            },
            .Output => try output.appendSlice(alloc, msg.payload),
            .Info => {
                if (msg.payload.len == @sizeOf(ipc.Info)) self.ready = true;
            },
            else => unreachable,
        }
    }

    pub fn canFlush(self: Receiver, eof: bool) bool {
        // Without a boundary, Info selects the legacy stream. Early EOF still
        // drains received output, but does not count as successful attachment.
        return self.boundary_received or self.ready or eof;
    }
};

const testing = std.testing;

// All transport operations below are ArrayList transfers through the real IPC
// decoder. No descriptor reads/writes, ioctls, environment access, or processes.
const Capture = struct {
    admission: Admission = .{},
    receiver: Receiver = .{},
    wire: std.ArrayList(u8) = .empty,
    decoder: ipc.SocketBuffer,
    output: std.ArrayList(u8) = .empty,
    displayed: std.ArrayList(u8) = .empty,

    fn init() !Capture {
        return .{ .decoder = try ipc.SocketBuffer.init(testing.allocator) };
    }

    fn deinit(self: *Capture) void {
        self.wire.deinit(testing.allocator);
        self.decoder.deinit();
        self.output.deinit(testing.allocator);
        self.displayed.deinit(testing.allocator);
    }

    fn publish(self: *Capture, stream: anytype, data: []const u8) !bool {
        stream.nextSlice(data);
        return self.admission.output(testing.allocator, &self.wire, data);
    }

    fn prepare(self: *Capture, term: *ghostty_vt.Terminal, stream: *const ghostty_vt.TerminalStream, has_output: bool, had_client: bool) !bool {
        return self.admission.prepareInit(testing.allocator, &self.wire, term, stream, has_output, had_client, term.rows);
    }

    fn info(self: *Capture) !void {
        const value = std.mem.zeroes(ipc.Info);
        try ipc.appendMessage(testing.allocator, &self.wire, .Info, std.mem.asBytes(&value));
    }

    fn transfer(self: *Capture, count: usize, write_limit: usize, eof: bool) !void {
        const n = @min(count, self.wire.items.len);
        try self.decoder.buf.appendSlice(testing.allocator, self.wire.items[0..n]);
        try self.wire.replaceRange(testing.allocator, 0, n, &.{});
        while (self.decoder.next()) |msg| {
            try self.receiver.receive(testing.allocator, &self.output, msg);
        }
        if (self.receiver.canFlush(eof)) {
            const written = @min(write_limit, self.output.items.len);
            try self.displayed.appendSlice(testing.allocator, self.output.items[0..written]);
            try self.output.replaceRange(testing.allocator, 0, written, &.{});
        }
    }

    fn drain(self: *Capture, chunk: usize, eof: bool) !void {
        while (self.wire.items.len > 0) try self.transfer(chunk, chunk, false);
        while (self.output.items.len > 0 and self.receiver.canFlush(eof))
            try self.transfer(0, chunk, eof);
    }
};

fn terminal(rows: u16) !ghostty_vt.Terminal {
    return ghostty_vt.Terminal.init(std.Options.debug_io, testing.allocator, .{
        .cols = 80,
        .rows = rows,
        .max_scrollback_bytes = 1_000_000,
    });
}

fn expectMarker(term: *ghostty_vt.Terminal, marker: []const u8, count: usize) !void {
    const text = util.serializeTerminal(testing.allocator, term, .plain) orelse "";
    defer if (text.len > 0) testing.allocator.free(text);
    if (std.mem.count(u8, text, marker) != count)
        std.debug.print("marker {s}, parsed terminal:\n{s}\n", .{ marker, text });
    try testing.expectEqual(count, std.mem.count(u8, text, marker));
}

test "attachment: requests boundary before unchanged Init and Info" {
    var queue: std.ArrayList(u8) = .empty;
    defer queue.deinit(testing.allocator);
    const size: ipc.Resize = .{ .rows = 24, .cols = 80 };
    try request(testing.allocator, &queue, size);
    try testing.expectEqual(@as(usize, 32), queue.items.len);
    var decoded = try ipc.SocketBuffer.init(testing.allocator);
    defer decoded.deinit();
    try decoded.buf.appendSlice(testing.allocator, queue.items);
    inline for (.{ ipc.Tag.Attach, ipc.Tag.Init, ipc.Tag.Info }) |tag| {
        const msg = decoded.next().?;
        try testing.expectEqual(tag, msg.header.tag);
        if (tag == .Init) {
            try testing.expectEqualSlices(u8, std.mem.asBytes(&size), msg.payload);
        } else {
            try testing.expectEqual(@as(usize, 0), msg.payload.len);
        }
    }
    try testing.expect(decoded.next() == null);
}

test "attachment: first snapshot includes output consumed before accept and Init" {
    var source = try terminal(24);
    defer source.deinit(testing.allocator);
    var stream = trackedStream(testing.allocator, &source, 1_000_000);
    defer stream.deinit();
    stream.nextSlice("BEFORE_ACCEPT\r\n");

    var capture = try Capture.init();
    defer capture.deinit();
    capture.admission.begin();
    try testing.expect(!try capture.publish(&stream, "BEFORE_INIT\r\n"));
    try testing.expect(try capture.prepare(&source, &stream, true, false));
    try capture.info();
    try testing.expect(try capture.publish(&stream, "AFTER_INIT\r\n"));
    try capture.drain(7, false);
    try testing.expect(capture.receiver.ready);

    var display = try terminal(24);
    defer display.deinit(testing.allocator);
    var display_stream = display.vtStream();
    defer display_stream.deinit();
    display_stream.nextSlice(capture.displayed.items);
    for ([_][]const u8{ "BEFORE_ACCEPT", "BEFORE_INIT", "AFTER_INIT" }) |marker|
        try expectMarker(&display, marker, 1);
}

test "attachment: partly delivered pre-Init frames are replaced without display duplication" {
    for ([_]usize{ 0, 3, 11, 4096 }) |sent| {
        var source = try terminal(24);
        defer source.deinit(testing.allocator);
        var stream = trackedStream(testing.allocator, &source, 1_000_000);
        defer stream.deinit();
        stream.nextSlice("EARLIER_PREFIX\r\n");
        var capture = try Capture.init();
        defer capture.deinit();
        try testing.expect(try capture.publish(&stream, "ACCEPTED_LIVE\r\n"));
        try capture.transfer(sent, 4096, false);
        try testing.expectEqual(@as(usize, 0), capture.displayed.items.len);

        capture.admission.begin();
        try testing.expect(!try capture.publish(&stream, "PENDING_SUFFIX\r\n"));
        try testing.expect(try capture.prepare(&source, &stream, true, false));
        try capture.info();
        try capture.drain(1, false);
        try testing.expect(capture.receiver.ready);
        var display = try terminal(24);
        defer display.deinit(testing.allocator);
        var display_stream = display.vtStream();
        defer display_stream.deinit();
        display_stream.nextSlice(capture.displayed.items);
        for ([_][]const u8{ "EARLIER_PREFIX", "ACCEPTED_LIVE", "PENDING_SUFFIX" }) |marker|
            try expectMarker(&display, marker, 1);
    }
}

test "attachment: empty session and repeated admission do not replay twice" {
    var source = try terminal(24);
    defer source.deinit(testing.allocator);
    var stream = trackedStream(testing.allocator, &source, 1_000_000);
    defer stream.deinit();
    var capture = try Capture.init();
    defer capture.deinit();
    capture.admission.begin();
    capture.admission.begin();
    try testing.expect(try capture.prepare(&source, &stream, false, false));
    try testing.expectEqual(@as(usize, @sizeOf(ipc.Header)), capture.wire.items.len);
    try capture.drain(1, false);
    try testing.expect(!capture.receiver.ready);
    capture.admission.begin();
    try testing.expect(!try capture.prepare(&source, &stream, true, true));
    try capture.info();
    try capture.drain(1, false);
    try testing.expect(capture.receiver.ready);
    try testing.expectEqual(@as(usize, 0), capture.displayed.items.len);
}

test "attachment: legacy streams and probes remain independent of terminal admission" {
    var source = try terminal(24);
    defer source.deinit(testing.allocator);
    var stream = source.vtStream();
    defer stream.deinit();
    var attaching = try Capture.init();
    defer attaching.deinit();
    attaching.admission.begin();

    // Silent tail and non-Init Run/Write/probe clients all retain streaming mode.
    for ([_]bool{ false, true }) |probe| {
        var legacy = try Capture.init();
        defer legacy.deinit();
        if (probe) try legacy.info();
        try testing.expect(try legacy.admission.output(testing.allocator, &legacy.wire, "live"));
        try testing.expect(!try attaching.publish(&stream, "live"));
        const first = blk: {
            try legacy.decoder.buf.appendSlice(testing.allocator, legacy.wire.items);
            break :blk legacy.decoder.next().?;
        };
        try testing.expectEqual(if (probe) ipc.Tag.Info else ipc.Tag.Output, first.header.tag);
        const output = if (probe) legacy.decoder.next().? else first;
        try testing.expectEqual(ipc.Tag.Output, output.header.tag);
        try testing.expectEqualStrings("live", output.payload);
        try testing.expect(legacy.decoder.next() == null);
        try testing.expectEqual(.streaming, legacy.admission.state);
    }
}

test "attachment: legacy Init keeps its original first-attach and reattach semantics" {
    var source = try terminal(24);
    defer source.deinit(testing.allocator);
    var stream = trackedStream(testing.allocator, &source, 1_000_000);
    defer stream.deinit();
    stream.nextSlice("LEGACY_STATE");
    var capture = try Capture.init();
    defer capture.deinit();
    // Regression control: the old first-attach gate omits this retained state.
    try testing.expect(!try capture.prepare(&source, &stream, true, false));
    try testing.expectEqual(@as(usize, 0), capture.wire.items.len);
    try testing.expect(try capture.prepare(&source, &stream, true, true));
    try capture.info();
    try capture.drain(7, false);
    try testing.expect(!capture.receiver.boundary_received);
    try testing.expect(capture.receiver.ready);
    try testing.expect(std.mem.indexOf(u8, capture.displayed.items, "LEGACY_STATE") != null);
}

test "attachment: a second terminal's snapshot does not interrupt the first client" {
    var source = try terminal(24);
    defer source.deinit(testing.allocator);
    var stream = trackedStream(testing.allocator, &source, 1_000_000);
    defer stream.deinit();
    stream.nextSlice("SHARED_HISTORY\r\n");
    var first = try Capture.init();
    defer first.deinit();
    first.admission.begin();
    try testing.expect(try first.prepare(&source, &stream, true, false));
    try first.info();
    try first.drain(11, false);

    var second = try Capture.init();
    defer second.deinit();
    try testing.expect(try first.publish(&stream, "DURING_ACCEPT\r\n"));
    try testing.expect(try second.admission.output(testing.allocator, &second.wire, "DURING_ACCEPT\r\n"));
    try second.drain(11, false);
    second.admission.begin();
    try testing.expect(try first.publish(&stream, "DURING_INIT\r\n"));
    try testing.expect(!try second.admission.output(testing.allocator, &second.wire, "DURING_INIT\r\n"));
    try testing.expect(try second.prepare(&source, &stream, true, true));
    try second.info();
    try first.drain(11, false);
    try second.drain(11, false);
    for ([_]*Capture{ &first, &second }) |capture| {
        var display = try terminal(24);
        defer display.deinit(testing.allocator);
        var display_stream = display.vtStream();
        defer display_stream.deinit();
        display_stream.nextSlice(capture.displayed.items);
        for ([_][]const u8{ "SHARED_HISTORY", "DURING_ACCEPT", "DURING_INIT" }) |marker|
            try expectMarker(&display, marker, 1);
    }
}

test "attachment: receiver drains fully delivered legacy response with bounded writes" {
    for ([_]bool{ false, true }) |acknowledged| {
        var capture = try Capture.init();
        defer capture.deinit();
        const data = "restoration\r\n" ** 500;
        try ipc.appendMessage(testing.allocator, &capture.wire, .Output, data);
        if (acknowledged) try capture.info();
        try capture.drain(17, false);
        try testing.expectEqual(acknowledged, capture.receiver.ready);
        if (!acknowledged) {
            try testing.expectEqual(@as(usize, 0), capture.displayed.items.len);
            try testing.expectEqualStrings(data, capture.output.items);
        }
        try capture.drain(11, true);
        try testing.expectEqualStrings(data, capture.displayed.items);
        try testing.expectEqual(acknowledged, capture.receiver.ready);
    }
}

test "attachment: snapshot precedes resize and preserves scrollback exactly once" {
    var source = try terminal(8);
    defer source.deinit(testing.allocator);
    var stream = trackedStream(testing.allocator, &source, 1_000_000);
    defer stream.deinit();
    var capture = try Capture.init();
    defer capture.deinit();
    stream.nextSlice("HISTORY_PREFIX\r\n");
    var buf: [32]u8 = undefined;
    for (0..50) |i| {
        _ = try capture.publish(&stream, try std.fmt.bufPrint(&buf, "ROW_{d:0>2}\r\n", .{i}));
    }
    try capture.drain(4096, false);
    try testing.expectEqual(@as(usize, 0), capture.displayed.items.len);
    capture.admission.begin();
    const before = util.serializeTerminalState(testing.allocator, &source).?;
    defer testing.allocator.free(before);
    try testing.expect(try capture.prepare(&source, &stream, true, false));
    try source.resize(testing.allocator, .{ .cols = 80, .rows = 5 });
    try capture.info();
    try capture.drain(13, false);
    try testing.expectEqualSlices(u8, before, capture.displayed.items);

    var display = try terminal(8);
    defer display.deinit(testing.allocator);
    var display_stream = display.vtStream();
    defer display_stream.deinit();
    display_stream.nextSlice(capture.displayed.items);
    try expectMarker(&display, "HISTORY_PREFIX", 1);
    for (0..50) |i| try expectMarker(&display, try std.fmt.bufPrint(&buf, "ROW_{d:0>2}", .{i}), 1);
}

test "attachment: receiver drains fully delivered negotiated restoration without inventing readiness" {
    for ([_]bool{ false, true }) |acknowledged| {
        var source = try terminal(24);
        defer source.deinit(testing.allocator);
        var stream = trackedStream(testing.allocator, &source, 1_000_000);
        defer stream.deinit();
        var buf: [80]u8 = undefined;
        for (0..200) |i| {
            stream.nextSlice(try std.fmt.bufPrint(&buf, "FRAME_{d:0>3}_abcdefghijklmnopqrstuvwxyz0123456789\r\n", .{i}));
        }
        const snapshot = util.serializeTerminalState(testing.allocator, &source).?;
        defer testing.allocator.free(snapshot);
        try testing.expect(snapshot.len > 4096);
        var capture = try Capture.init();
        defer capture.deinit();
        capture.admission.begin();
        try testing.expect(try capture.prepare(&source, &stream, true, false));
        if (acknowledged) try capture.info();
        try capture.drain(29, true);
        try testing.expect(capture.receiver.boundary_received);
        try testing.expectEqual(acknowledged, capture.receiver.ready);
        try testing.expectEqualSlices(u8, snapshot, capture.displayed.items);
    }
}

test "attachment: active screen modes and transient synchronization survive admission" {
    for ([_][]const u8{ "", "\x1b[?47h", "\x1b[?1047h", "\x1b[?1049h" }) |enter| {
        var source = try terminal(24);
        defer source.deinit(testing.allocator);
        var stream = trackedStream(testing.allocator, &source, 1_000_000);
        defer stream.deinit();
        stream.nextSlice("PRIMARY_ONLY\r\n");
        stream.nextSlice(enter);
        stream.nextSlice("\x1b[?2004;2026h\x1b[?25lACTIVE_MARKER");
        var capture = try Capture.init();
        defer capture.deinit();
        capture.admission.begin();
        try testing.expect(try capture.prepare(&source, &stream, true, false));
        try testing.expect(source.modes.get(.synchronized_output));
        try capture.info();
        try capture.drain(5, false);

        var display = try terminal(24);
        defer display.deinit(testing.allocator);
        var display_stream = display.vtStream();
        defer display_stream.deinit();
        display_stream.nextSlice(capture.displayed.items);
        try testing.expectEqual(source.screens.active_key, display.screens.active_key);
        try testing.expect(display.modes.get(.bracketed_paste));
        try testing.expect(!display.modes.get(.synchronized_output));
        try testing.expect(!display.modes.get(.cursor_visible));
        try expectMarker(&display, "ACTIVE_MARKER", 1);
        try expectMarker(&display, "PRIMARY_ONLY", if (enter.len == 0) 1 else 0);
    }
}

test "attachment: snapshot flushes retained history at different client heights" {
    for ([_]u16{ 4, 8, 16 }) |rows| {
        var source = try terminal(8);
        defer source.deinit(testing.allocator);
        var stream = trackedStream(testing.allocator, &source, 1_000_000);
        defer stream.deinit();
        var buf: [32]u8 = undefined;
        for (0..50) |i| stream.nextSlice(try std.fmt.bufPrint(&buf, "HEIGHT_{d:0>2}\r\n", .{i}));
        var capture = try Capture.init();
        defer capture.deinit();
        capture.admission.begin();
        try testing.expect(try capture.admission.prepareInit(
            testing.allocator,
            &capture.wire,
            &source,
            &stream,
            true,
            false,
            rows,
        ));
        try source.resize(testing.allocator, .{ .cols = 80, .rows = rows });
        try capture.info();
        try capture.drain(17, false);
        var display = try terminal(rows);
        defer display.deinit(testing.allocator);
        var display_stream = display.vtStream();
        defer display_stream.deinit();
        display_stream.nextSlice(capture.displayed.items);
        for (0..50) |i| try expectMarker(&display, try std.fmt.bufPrint(&buf, "HEIGHT_{d:0>2}", .{i}), 1);
    }
}

test "attachment: failed preparation leaves admission and terminal modes intact" {
    var source = try terminal(24);
    defer source.deinit(testing.allocator);
    var stream = trackedStream(testing.allocator, &source, 1_000_000);
    defer stream.deinit();
    stream.nextSlice("\x1b[?2026hRETAINED");
    var capture = try Capture.init();
    defer capture.deinit();
    capture.admission.begin();
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.TerminalRestoreFailed, capture.admission.prepareInit(
        failing.allocator(),
        &capture.wire,
        &source,
        &stream,
        true,
        false,
        24,
    ));
    try testing.expect(source.modes.get(.synchronized_output));
    try testing.expectEqual(.pending, capture.admission.state);
    try testing.expectEqual(@as(usize, 0), capture.wire.items.len);
    try testing.expectError(error.OutOfMemory, capture.admission.prepareInit(
        failing.allocator(),
        &capture.wire,
        &source,
        &stream,
        false,
        false,
        24,
    ));
    try testing.expectEqual(.pending, capture.admission.state);
    try testing.expectEqual(@as(usize, 0), capture.wire.items.len);
}

test "attachment: malformed or late boundaries cannot discard displayed data" {
    var receiver: Receiver = .{};
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(testing.allocator);
    try output.appendSlice(testing.allocator, "held");
    try testing.expectError(error.InvalidAttachmentBoundary, receiver.receive(
        testing.allocator,
        &output,
        .{ .header = .{ .tag = .Attach, .len = 1 }, .payload = "x" },
    ));
    try testing.expectEqualStrings("held", output.items);
    receiver.ready = true;
    try testing.expectError(error.InvalidAttachmentBoundary, receiver.receive(
        testing.allocator,
        &output,
        .{ .header = .{ .tag = .Attach, .len = 0 }, .payload = "" },
    ));
    try testing.expectEqualStrings("held", output.items);
}

test "attachment: headless device attribute replies remain queued during admission" {
    var source = try terminal(24);
    defer source.deinit(testing.allocator);
    var stream = trackedStream(testing.allocator, &source, 1_000_000);
    defer stream.deinit();
    var capture = try Capture.init();
    defer capture.deinit();
    capture.admission.begin();
    const queries = "\x1b[c\x1b[>c";
    try testing.expect(!try capture.publish(&stream, queries));
    var replies: std.ArrayList(u8) = .empty;
    defer replies.deinit(testing.allocator);
    util.respondToDeviceAttributes(testing.allocator, &replies, queries);
    try testing.expectEqualStrings("\x1b[?62;22c\x1b[>1;10;0c", replies.items);
    try testing.expect(try capture.prepare(&source, &stream, true, false));
    try capture.info();
    try capture.drain(7, false);
    try testing.expect(std.mem.indexOf(u8, capture.displayed.items, "\x1b[c") == null);
    try testing.expectEqualStrings("\x1b[?62;22c\x1b[>1;10;0c", replies.items);
}

fn expectContinuation(prefix: []const u8, suffix: []const u8) !void {
    // Cut before accept, after pre-boundary delivery, and while admission is
    // pending. The destination remains a persistent parser across the cut.
    for (0..3) |phase| {
        var source = try terminal(24);
        defer source.deinit(testing.allocator);
        var stream = trackedStream(testing.allocator, &source, 1024);
        defer stream.deinit();
        var capture = try Capture.init();
        defer capture.deinit();
        if (phase == 2) capture.admission.begin();
        if (phase == 0) {
            stream.nextSlice(prefix);
        } else {
            _ = try capture.publish(&stream, prefix);
            try capture.drain(3, false);
        }
        try testing.expect(!stream.ground());
        capture.admission.begin();
        try testing.expect(try capture.prepare(&source, &stream, true, false));
        try capture.info();
        try capture.drain(3, false);
        try testing.expect(capture.receiver.ready);

        var display = try terminal(24);
        defer display.deinit(testing.allocator);
        var display_stream = trackedStream(testing.allocator, &display, 1024);
        defer display_stream.deinit();
        for (capture.displayed.items) |byte| display_stream.next(byte);
        try testing.expect(!display_stream.ground());

        var before_buf: [1024]u8 = undefined;
        var before: std.Io.Writer = .fixed(&before_buf);
        try stream.writeContinuation(&before);
        var after_buf: [1024]u8 = undefined;
        var after: std.Io.Writer = .fixed(&after_buf);
        try display_stream.writeContinuation(&after);
        try testing.expectEqualSlices(u8, before.buffered(), after.buffered());

        const start = capture.displayed.items.len;
        try testing.expect(try capture.publish(&stream, suffix));
        try capture.drain(1, false);
        for (capture.displayed.items[start..]) |byte| display_stream.next(byte);
        try testing.expect(stream.ground());
        try testing.expect(display_stream.ground());
        const expected = try source.plainString(testing.allocator);
        defer testing.allocator.free(expected);
        const actual = try display.plainString(testing.allocator);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(expected, actual);
        try testing.expectEqualDeep(source.screens.active.cursor.style, display.screens.active.cursor.style);
        try testing.expectEqualDeep(source.modes, display.modes);
        try testing.expectEqual(source.screens.active.cursor.x, display.screens.active.cursor.x);
        try testing.expectEqual(source.screens.active.cursor.y, display.screens.active.cursor.y);
        try testing.expectEqualStrings(source.getTitle() orelse "", display.getTitle() orelse "");
    }
}

test "attachment: CSI continuation preserves subsequent text and rendition" {
    try expectContinuation("READY\r\n\x1b[31", "mRED\r\n");
    try expectContinuation("READY\r\n\x1b[38;2;12;34", ";56mRGB\r\n");
    try expectContinuation("READY\r\n\x1b[?100", "0hLIVE\r\n");
    // The newline already committed before Init must not replay a second time.
    try expectContinuation("READY\r\n\x1b[3\r\n1", "mRED\r\n");
}

test "attachment: OSC continuation completes its title without printing payload" {
    try expectContinuation("READY\r\n\x1b]2;title ", "after cut\x1b\\TEXT\r\n");
    try expectContinuation("READY\r\n\x1b]2;title ", "after cut\x07TEXT\r\n");
}

test "attachment: UTF8 continuation preserves codepoints across Init" {
    try expectContinuation("READY\r\n\xC2", "\xA2\r\n");
    try expectContinuation("READY\r\n\xE2\x82", "\xAC\r\n");
    try expectContinuation("READY\r\n\xF0", "\x9F\x98\x84\r\n");
    try expectContinuation("READY\r\n\xF0\x9F", "\x98\x84\r\n");
    try expectContinuation("READY\r\n\xF0\x9F\x98", "\x84\r\n");
    try expectContinuation("READY\r\n\xE0\xA0\xF0", "\x9F\x98\x84\r\n");
}

test "attachment: unavailable continuation fails immediately and recovers at ground" {
    var source = try terminal(24);
    defer source.deinit(testing.allocator);
    var stream = trackedStream(testing.allocator, &source, 4);
    defer stream.deinit();
    stream.nextSlice("\x1b[123");
    try testing.expect(stream.continuation.?.broken);
    try testing.expect(stream.continuation.?.bytes.items.len <= 4);
    var capture = try Capture.init();
    defer capture.deinit();
    capture.admission.begin();
    try testing.expectError(error.ContinuationUnavailable, capture.prepare(&source, &stream, true, false));
    try testing.expectEqual(@as(usize, 0), capture.wire.items.len);
    try testing.expect(!capture.receiver.ready);

    // No waiting or automatic retry is involved. A later, separate admission
    // becomes possible once ordinary PTY processing reaches ground.
    stream.nextSlice("mALIVE\r\n");
    try testing.expect(stream.ground());
    try testing.expect(!stream.continuation.?.broken);
    var later = try Capture.init();
    defer later.deinit();
    later.admission.begin();
    try testing.expect(try later.prepare(&source, &stream, true, false));
}

test "attachment: producer truncation leaves receiver unavailable with unsent data" {
    var source = try terminal(24);
    defer source.deinit(testing.allocator);
    var stream = trackedStream(testing.allocator, &source, 1024);
    defer stream.deinit();
    var buf: [80]u8 = undefined;
    for (0..200) |i| {
        stream.nextSlice(try std.fmt.bufPrint(&buf, "ROW_{d:0>3}_abcdefghijklmnopqrstuvwxyz0123456789\r\n", .{i}));
    }
    var capture = try Capture.init();
    defer capture.deinit();
    capture.admission.begin();
    try testing.expect(try capture.prepare(&source, &stream, true, false));
    try capture.info();
    // Unlike drain(), only this prefix reaches the receiver before EOF.
    // The daemon's current one-write EOF policy can leave the rest unsent.
    try capture.transfer(4096, 4096, true);
    try testing.expect(capture.wire.items.len > 0);
    try testing.expect(capture.receiver.boundary_received);
    try testing.expect(!capture.receiver.ready);
    try testing.expectEqual(@as(usize, 0), capture.displayed.items.len);
}
