"""Real PTY/socket fixtures invoked by resume.bats; Python standard library only."""

import contextlib
import fcntl
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import socket
import struct
import subprocess
import sys
import termios
import time


ZMX = sys.argv[1]
ROOT = Path(os.environ["ZMX_DIR"])
ENV = dict(
    os.environ, TERM="xterm-256color", PS1="zmx-test> ", ZMX_SESSION="",
    SHELL="/bin/bash", HOME=str(ROOT / "home"),
)
ENV.pop("ZMX_SESSION_PREFIX", None)
ENV.pop("BASH_ENV", None)
Path(ENV["HOME"]).mkdir()
TIMEOUT = 8
# Exact bytes are also parsed and checked for history/mode effects in util.zig.
CLEANUP_KEYBOARD = b"\x1b[<999u\x1b[=0u\x1b[>4;0m"
CLEANUP = (
    b"\x18\x1b[?2026l" + CLEANUP_KEYBOARD +
    b"\x1b[?1049;1047;47l" + CLEANUP_KEYBOARD +
    b"\x1b[?1;5;6;45;66;67;69;1045l"
    b"\x1b[?9;1000;1002;1003;1004;1005;1006;1015;1016l"
    b"\x1b[?2004;2031;2033;2048l"
    b"\x1b[2;4;20l\x1b[12h\x1b[?7;25h"
    b"\x1b[0m\x1b[0 q\x1b[0\"q\x1b]8;;\x1b\\"
    b"\x1b(B\x1b)B\x1b*B\x1b+B\x0f\x1b}"
    b"\x1b[r\x1b[65535;1H\r\n"
)


def cli(*args, env=ENV):
    return subprocess.run(
        [ZMX, *args], env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=TIMEOUT,
    )


def eventually(check):
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.02)
    raise AssertionError("condition did not become true")


class Terminal:
    def __init__(self, *args, env=ENV):
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        self.original = termios.tcgetattr(self.slave)
        self.flags = fcntl.fcntl(self.slave, fcntl.F_GETFL)
        self.output = b""
        self.process = subprocess.Popen(
            [ZMX, *args], env=env, stdin=self.slave,
            stdout=self.slave, stderr=subprocess.PIPE,
        )

    def read(self):
        self._read_chunk(0.05, suppress_read_errors=True)
        return self.output

    def _read_chunk(self, timeout, *, suppress_read_errors):
        if select.select([self.master], [], [], timeout)[0]:
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                if not suppress_read_errors:
                    raise
                return None
            self.output += chunk
            return chunk
        return None

    def expect(self, text):
        eventually(lambda: text in self.read())

    def send(self, data):
        os.write(self.master, data)

    def command(self, command):
        self.output = b""
        self.send(command.encode() + b"\r")

    def finished(self, code):
        # Keep draining the PTY while the child flushes its final output.
        eventually(lambda: (self.read(), self.process.poll() is not None)[1])
        while select.select([self.master], [], [], 0.05)[0]:
            self.read()
        error = self.process.stderr.read()
        assert self.process.returncode == code, (self.process.returncode, error, self.output)
        assert termios.tcgetattr(self.slave) == self.original, "termios not restored"
        flags = fcntl.fcntl(self.slave, fcntl.F_GETFL)
        # Darwin adds a kernel bookkeeping bit after any write to a PTY.
        assert flags & os.O_NONBLOCK == self.flags & os.O_NONBLOCK, "stdin left nonblocking"
        assert self.output.endswith(CLEANUP), "history-preserving cleanup missing"
        assert b"\x1bc" not in self.output, "destructive client reset"
        return error

    def detach(self):
        self.send(b"\x1c")
        self.finished(0)

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=TIMEOUT)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=TIMEOUT)
        self.process.stderr.close()
        os.close(self.master)
        os.close(self.slave)


@contextlib.contextmanager
def terminal(*args, env=ENV):
    client = Terminal(*args, env=env)
    try:
        yield client
    finally:
        client.close()


def create(name, env=ENV):
    with terminal("attach", name, "/bin/bash", "--noprofile", "--norc", "-i", env=env) as client:
        client.expect(b"zmx-test> ")
        client.detach()


def pid(name, env=ENV):
    listing = cli("list", env=env).stdout.decode()
    for line in listing.splitlines():
        if f"name={name}\t" in line:
            return next(field for field in line.split("\t") if field.startswith("pid="))
    raise AssertionError(listing)


def install_spawn_trap():
    trap = ROOT / "spawn-trap"
    trap.write_text("#!/bin/sh\nprintf spawned > \"$ZMX_DIR/spawned\"\nexit 99\n")
    trap.chmod(0o700)
    return dict(ENV, SHELL=str(trap))


def assert_no_spawn(*names):
    assert not (ROOT / "spawned").exists(), "fallback shell ran"
    log = ROOT / "logs" / "zmx.log"
    contents = log.read_text() if log.exists() else ""
    for name in names:
        assert f"creating session={name}" not in contents, contents
        assert not (ROOT / "logs" / f"{name}.log").exists(), "fallback daemon started"


def first_attach():
    # `run` creates the daemon before rejecting an absent command. No Run or
    # Init reaches it, so has_had_client remains false. Use only fixture startup
    # files, not a login profile, and emit the marker exactly once.
    bindir = ROOT / "fixture-bin"
    bindir.mkdir()
    wrapper = bindir / "bash"
    wrapper.write_text('#!/bin/sh\nexec /bin/bash --noprofile --rcfile "$ZMX_DIR/startup.rc" -i\n')
    wrapper.chmod(0o700)
    (ROOT / "startup.rc").write_text("printf '\\r\\nSTARTUP_ONCE\\r\\n'\nPS1='zmx-test> '\n")
    trap_env = install_spawn_trap()
    env = {key: trap_env[key] for key in ("HOME", "SHELL", "TERM", "PS1", "ZMX_SESSION", "ZMX_DIR")}
    env.update(PATH=f"{bindir}:/usr/bin:/bin", INPUTRC="/dev/null")
    result = cli("run", "startup", env=env)
    assert result.returncode != 0 and b"CommandRequired" in result.stderr, result
    # History proves the daemon consumed the marker before the first terminal
    # connected. History/Info requests do not initialize a terminal client.
    eventually(lambda: b"STARTUP_ONCE" in cli("history", "startup", env=env).stdout)
    original_pid = pid("startup", env=env)
    with terminal("resume", "startup", env=env) as client:
        client.expect(b"STARTUP_ONCE")
        client.send(b"printf 'input-%s\\n' accepted\r")
        client.expect(b"input-accepted")
        client.detach()
        assert client.output.count(b"STARTUP_ONCE") == 1, client.output
    assert pid("startup", env=env) == original_pid
    assert not (ROOT / "spawned").exists(), "resume launched a fallback shell"


def interaction():
    create("work")
    original_pid = pid("work")
    # Inject a known display state without relying on shell prompt behavior.
    assert cli("print", "work", "\r\n\x1b[31mrestored-state\x1b[0m\r\n\x1b[?25l").returncode == 0
    eventually(lambda: b"restored-state" in cli("history", "work").stdout)
    with terminal("resume", "work") as first:
        first.expect(b"restored-state")
        first.expect(b"\x1b[?25l")
        assert not termios.tcgetattr(first.slave)[3] & termios.ICANON
        with terminal("resume", "work") as second:
            second.expect(b"restored-state")
            assert pid("work") == original_pid
            first.command("printf 'live-%s\\n' first")
            first.expect(b"live-first")
            second.expect(b"live-first")
            second.command("printf 'live-%s\\n' second")
            first.expect(b"live-second")
            second.expect(b"live-second")
            # Both clients must clean up a live alternate screen and input modes.
            assert cli("print", "work", "\x1b[?1049h\x1b[?1003;1004;2004h\x1b[>31u\r\nalternate-state").returncode == 0
            first.expect(b"alternate-state")
            second.expect(b"alternate-state")
            first.detach()
            second.command("printf 'still-%s\\n' attached")
            second.expect(b"still-attached")
            assert cli("detach", env=dict(ENV, ZMX_SESSION="work")).returncode == 0
            second.finished(0)
    assert pid("work") == original_pid
    assert cli("print", "work", "\x1b[?1049l").returncode == 0
    eventually(lambda: b"restored-state" in cli("history", "work").stdout)
    with terminal("attach", "work", "/definitely-not-a-command") as client:
        client.expect(b"restored-state")
        client.detach()
    assert pid("work") == original_pid, "attach stopped ignoring a command for an existing session"


def absent():
    env = install_spawn_trap()
    before = cli("list", "--short").stdout
    missing = cli("resume", "missing", env=env)
    assert missing.returncode == 1, missing
    assert b"no session created" in missing.stderr
    assert missing.stdout == b"", "missing socket changed the terminal"
    assert cli("list", "--short").stdout == before
    stale = ROOT / "stale"
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(str(stale))
    inode = stale.stat().st_ino
    refused = cli("resume", "stale", env=env)
    assert refused.returncode == 1, refused
    assert stale.stat().st_ino == inode, "resume removed/replaced a stale socket"
    ordinary = ROOT / "ordinary"
    ordinary.write_text("not a socket")
    assert cli("resume", "ordinary", env=env).returncode == 1
    assert ordinary.read_text() == "not a socket"
    assert_no_spawn("missing", "stale", "ordinary")
    stale.unlink()
    ordinary.unlink()


def read_exact(connection, size):
    data = b""
    while len(data) < size:
        part = connection.recv(size - len(data))
        assert part, "peer closed before completing the frame"
        data += part
    return data


def read_message(connection):
    header = read_exact(connection, 8)
    length = int.from_bytes(header[1:5], sys.byteorder)
    return header[0], read_exact(connection, length)


def read_init(connection):
    assert read_message(connection) == (14, b"")
    tag, payload = read_message(connection)
    assert tag == 7 and len(payload) == 8, (tag, payload)
    assert read_message(connection) == (6, b"")


def race():
    env = install_spawn_trap()
    path = ROOT / "race"
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(str(path))
        server.listen(4)
        server.settimeout(TIMEOUT)
        with terminal("resume", "race", env=env) as client:
            connection, _ = server.accept()
            with connection:
                connection.settimeout(TIMEOUT)
                # Deterministic disappearance after connect, before Init is
                # answered. Keep a replacement listener to catch reconnection.
                path.unlink()
                with socket.socket(socket.AF_UNIX) as replacement:
                    replacement.bind(str(path))
                    replacement.listen(4)
                    read_init(connection)
                    connection.shutdown(socket.SHUT_RDWR)
                    error = client.finished(1)
                    assert b"SessionUnavailable" in error
                    assert not select.select([replacement], [], [], 0.1)[0], "client reconnected"
    assert_no_spawn("race")
    path.unlink()


def closing_restore():
    env = install_spawn_trap()
    restored = b"\x1b[31m" + b"restored-state-" * 357 + b"\x1b[0m"
    assert len(restored) > 4096

    def frame(tag, payload):
        return bytes([tag]) + len(payload).to_bytes(4, sys.byteorder) + b"\0" * 3 + payload

    for command, acknowledged in (
        ("resume", True), ("resume", False), ("attach", True), ("attach", False),
    ):
        name = f"{command}-{acknowledged}"
        path = ROOT / name
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(str(path))
            server.listen(4)
            server.settimeout(TIMEOUT)
            with terminal(command, name, env=env) as client:
                if command == "attach":
                    probe, _ = server.accept()
                    with probe:
                        probe.settimeout(TIMEOUT)
                        assert probe.recv(1) == b"", "attach did not close its existing-session probe"
                connection, _ = server.accept()
                with connection:
                    connection.settimeout(TIMEOUT)
                    read_init(connection)
                    # Queue the whole restoration and EOF before the next poll,
                    # deterministically exercising simultaneous POLLIN/POLLHUP.
                    os.kill(client.process.pid, signal.SIGSTOP)
                    _, status = os.waitpid(client.process.pid, os.WUNTRACED)
                    assert os.WIFSTOPPED(status)
                    try:
                        data = frame(1, restored)
                        if acknowledged:
                            data += frame(6, bytes(552))
                        connection.sendall(data)
                        connection.shutdown(socket.SHUT_RDWR)
                        connection.close()
                    finally:
                        os.kill(client.process.pid, signal.SIGCONT)
                expected_code = 1 if command == "resume" and not acknowledged else 0
                error = client.finished(expected_code)
                assert client.output == b"\x1b[2J\x1b[H" + restored + CLEANUP, client.output
                if expected_code == 1:
                    assert b"SessionUnavailable" in error
                else:
                    assert not error, error
        assert_no_spawn(name)
        path.unlink()


class ProducerTerminal(Terminal):
    """Producer-only counters and a readiness-driven bulk-output wait."""

    def __init__(self, *args, **kwargs):
        from producer_diagnostics import ReadMetrics
        self.read_metrics = ReadMetrics()
        self.phase_metrics = ReadMetrics()
        super().__init__(*args, **kwargs)

    def _read_chunk(self, timeout, *, suppress_read_errors):
        self.read_metrics.checks += 1
        self.phase_metrics.checks += 1
        before = len(self.output)
        result = super()._read_chunk(timeout, suppress_read_errors=suppress_read_errors)
        size = len(self.output) - before
        completed_ns = time.monotonic_ns() if size > 0 else None
        self.read_metrics.received(size)
        self.phase_metrics.received(size, completed_ns=completed_ns)
        return result

    def expect_progress(self, text):
        from producer_readiness import wait_for_output
        wait_for_output(
            lambda: text in self.output,
            lambda remaining: self._read_chunk(remaining, suppress_read_errors=False),
            time.monotonic,
            TIMEOUT,
        )


class ProducerObservation:
    def __init__(self):
        self.started = time.monotonic_ns()
        self.phase_started = self.started
        self.phase = "setup"
        self.client = None
        self.role = None
        self.cleanup_phase = None
        self.attempted = False
        self.emitted = False
        self.socket_send_buffer_bytes = None
        self.snapshot_bytes = None
        self.slow_received_bytes = None

    def enter(self, phase):
        from producer_diagnostics import PHASES, ReadMetrics
        if phase not in PHASES:
            raise ValueError("invalid producer observation phase")
        self.phase = phase
        self.phase_started = time.monotonic_ns()
        if self.client is not None:
            self.client.phase_metrics = ReadMetrics()

    def failure(self, error, point):
        if self.attempted:
            return
        self.attempted = True
        observed = time.monotonic_ns()
        from producer_diagnostics import FLAGS, NUMBERS, encode_failure, error_kind
        from producer_readiness import wait_for_output
        metrics = dict.fromkeys(NUMBERS + FLAGS)
        # Whitelist code objects, never filenames or exception messages. The
        # innermost recognized site distinguishes a wait timeout from an assert.
        sites = {
            _producer_drain.__code__: "producer",
            eventually.__code__: "wait",
            wait_for_output.__code__: "wait",
            Terminal.__init__.__code__: "terminal_init",
            Terminal.read.__code__: "terminal_read",
            Terminal._read_chunk.__code__: "terminal_read",
            Terminal.expect.__code__: "terminal_expect",
            Terminal.finished.__code__: "terminal_finished",
            Terminal.close.__code__: "terminal_close",
        }
        site = "other"
        traceback = error.__traceback__
        while traceback is not None:
            if traceback.tb_frame.f_code in sites:
                site = sites[traceback.tb_frame.f_code]
                metrics["failure_line"] = traceback.tb_lineno
            traceback = traceback.tb_next
        metrics.update(
            total_elapsed_ms=(observed - self.started) // 1_000_000,
            phase_elapsed_ms=None if self.cleanup_phase else (observed - self.phase_started) // 1_000_000,
            errno=error.errno if isinstance(error, OSError) else None,
            socket_send_buffer_bytes=self.socket_send_buffer_bytes,
            snapshot_bytes=self.snapshot_bytes,
            slow_received_bytes=self.slow_received_bytes,
        )
        if self.client is not None:
            output = self.client.output
            rows = output.count(b"ROW_")
            metrics.update(self.client.read_metrics.scalars())
            if self.cleanup_phase is None:
                metrics.update(self.client.phase_metrics.scalars("phase_"))
                metrics.update(self.client.phase_metrics.progress_scalars(self.phase_started, observed))
            metrics.update(
                captured_bytes=len(output),
                rows_observed=rows,
                ready_seen=b"PRODUCER_READY" in output,
                complete_seen=b"PRODUCER_COMPLETE" in output,
                rows_12000_observed=rows == 12000,
                # Do not poll/wait/reap or infer liveness for diagnostics.
                client_returncode_cached=self.client.process.returncode,
            )
        record = encode_failure(self.cleanup_phase or self.phase, point, error_kind(error), self.role, site, metrics)
        sys.stderr.write(record.decode("ascii"))
        sys.stderr.flush()
        self.emitted = True


@contextlib.contextmanager
def producer_terminal(observation, role, *args, env=ENV):
    observation.enter("starter_create" if role == "starter" else "healthy_create")
    client = ProducerTerminal(*args, env=env)
    observation.client = client
    observation.role = role
    try:
        yield client
    except BaseException as error:
        observation.failure(error, "before_terminal_cleanup")
        raise
    finally:
        # Use the same source-owned close operation and ordering as terminal().
        # Cleanup timing is unobserved: breadcrumbs do not add clock probes here.
        observation.cleanup_phase = "starter_cleanup" if role == "starter" else "healthy_cleanup"
        try:
            client.close()
        except BaseException as error:
            observation.failure(error, "terminal_cleanup")
            raise
        finally:
            observation.cleanup_phase = None
            observation.client = None
            observation.role = None


def producer_drain():
    observation = ProducerObservation()
    try:
        _producer_drain(observation)
    except BaseException as error:
        # Existing assertions can contain whole terminal buffers. This fixture's
        # CLI boundary emits only scalars, never an exception message/traceback.
        # Failure stays nonzero even if encoding or writing the record fails.
        try:
            observation.failure(error, "fifo_cleanup" if observation.cleanup_phase else "operation")
        finally:
            if not observation.emitted:
                raise SystemExit(2) from None  # diagnostic emission itself failed
            raise SystemExit(130 if isinstance(error, KeyboardInterrupt) else 1) from None


def _producer_drain(observation):
    # Only fixture-owned files and an explicit isolated Python producer are
    # used; the FIFO controls producer completion without terminal input.
    control_path = ROOT / "producer-control"
    producer_path = ROOT / "producer.py"
    observation.enter("fifo_create")
    os.mkfifo(control_path, 0o600)
    observation.enter("producer_source")
    producer_path.write_text(
        "import os, sys\n"
        "with open(sys.argv[1], 'rb', buffering=0) as control:\n"
        "    print('PRODUCER_READY', flush=True)\n"
        "    assert control.read(1) == b'd'\n"
        "    for row in range(12000):\n"
        "        print(f'ROW_{row:05d}_' + 'x' * 60)\n"
        "    print('PRODUCER_COMPLETE', flush=True)\n"
        "    assert control.read(1) == b'x'\n"
    )
    observation.enter("fifo_open")
    control = os.open(control_path, os.O_RDWR | os.O_NONBLOCK)
    observation.enter("environment")
    trap_env = install_spawn_trap()
    env = {key: trap_env[key] for key in ("HOME", "SHELL", "TERM", "PS1", "ZMX_SESSION", "ZMX_DIR")}
    env.update(PATH="/usr/bin:/bin", INPUTRC="/dev/null")
    name = "producer-drain"
    try:
        with producer_terminal(observation, "starter", "attach", name, sys.executable, "-I", str(producer_path), str(control_path), env=env) as starter:
            observation.enter("starter_ready")
            starter.expect(b"PRODUCER_READY")
            observation.enter("starter_detach")
            starter.detach()
        with producer_terminal(observation, "healthy", "resume", name, env=env) as healthy:
            observation.enter("healthy_ready")
            healthy.expect(b"PRODUCER_READY")
            observation.enter("producer_emit")
            os.write(control, b"d")
            observation.enter("healthy_complete")
            healthy.expect_progress(b"PRODUCER_COMPLETE")
            observation.enter("row_count")
            assert healthy.output.count(b"ROW_") == 12000
            observation.enter("slow_create")
            with socket.socket(socket.AF_UNIX) as stalled:
                observation.enter("slow_options")
                stalled.settimeout(TIMEOUT)
                send_buffer = stalled.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)
                observation.socket_send_buffer_bytes = send_buffer
                observation.enter("slow_connect")
                stalled.connect(str(ROOT / name))

                def frame(tag, payload):
                    return bytes([tag]) + len(payload).to_bytes(4, sys.byteorder) + b"\0" * 3 + payload

                observation.enter("slow_request")
                stalled.sendall(
                    frame(14, b"") + frame(7, struct.pack("=HHHH", 24, 80, 0, 0)) + frame(6, b"")
                )
                observation.enter("slow_boundary")
                assert read_message(stalled) == (14, b"")
                observation.enter("slow_header")
                header = read_exact(stalled, 8)
                assert header[0] == 1, header
                snapshot_bytes = int.from_bytes(header[1:5], sys.byteorder)
                observation.snapshot_bytes = snapshot_bytes
                # Both sockets use the kernel's default send buffer. Reject a
                # host unsuitable for this fixture instead of silently passing
                # without pressure; the expiry log additionally proves unsent
                # producer data, rather than assuming pressure from size alone.
                observation.enter("snapshot_size")
                assert snapshot_bytes > 2 * send_buffer, (snapshot_bytes, send_buffer)
                ended = time.monotonic()
                deadline = ended + TIMEOUT
                observation.enter("producer_finish")
                os.write(control, b"x")
                observation.enter("healthy_finish")
                healthy.finished(0)
                observation.enter("healthy_finish_time")
                assert time.monotonic() - ended < 5, "healthy client waited for the stalled peer"
                log_path = ROOT / "logs" / f"{name}.log"
                observation.enter("deadline_log")
                eventually(lambda: "reason=deadline" in log_path.read_text())
                observation.enter("deadline_time")
                assert time.monotonic() - ended >= 5, "stalled client expired early"
                received = b""
                observation.slow_received_bytes = 0
                observation.enter("slow_receive")
                while True:
                    remaining = deadline - time.monotonic()
                    assert remaining > 0, "producer drain exceeded fixture budget"
                    stalled.settimeout(remaining)
                    chunk = stalled.recv(65536)
                    if not chunk:
                        break
                    received += chunk
                    observation.slow_received_bytes = len(received)
                observation.enter("truncated_snapshot")
                assert len(received) < snapshot_bytes, "fixture did not retain a backpressured snapshot"
                # Info follows the whole snapshot, so this truncated frame
                # cannot constitute attachment readiness.
                observation.enter("expiry_assertion")
                expiry = [line for line in log_path.read_text().splitlines() if "reason=deadline" in line]
                assert len(expiry) == 1 and "unsent=0" not in expiry[0], expiry
                observation.enter("no_spawn")
                assert not (ROOT / "spawned").exists()
    except BaseException as error:
        observation.failure(error, "before_fifo_cleanup")
        raise
    finally:
        observation.cleanup_phase = "fifo_close"
        os.close(control)
        observation.cleanup_phase = "fifo_unlink"
        control_path.unlink()
        observation.cleanup_phase = "producer_unlink"
        producer_path.unlink()
        observation.cleanup_phase = None


def switching():
    create("source")
    create("target")
    original_pid = pid("target")
    env = install_spawn_trap()
    quoted = shlex.quote(ZMX)
    with terminal("resume", "source", env=env) as client:
        client.expect(b"zmx-test> ")
        client.command(f"{quoted} resume target; printf 'nested-%s\\n' \"$?\"")
        client.expect(b"nested-2")
        assert pid("target") == original_pid
        client.command(f"{quoted} attach target")
        client.expect(CLEANUP)
        assert b"\x1bc" not in client.output, "destructive switch reset"
        client.expect(b"zmx-test> ")
        client.command("printf 'target-%s\\n' \"$ZMX_SESSION\"")
        client.expect(b"target-target")
        assert pid("target") == original_pid
        stale = ROOT / "stale-switch"
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(str(stale))
        inode = stale.stat().st_ino
        client.command(f"{quoted} attach stale-switch")
        client.finished(1)
        assert stale.stat().st_ino == inode
        assert_no_spawn("stale-switch")
        stale.unlink()
    with terminal("resume", "source", env=env) as client:
        client.expect(b"zmx-test> ")
        client.command(f"{quoted} attach missing")
        client.finished(1)
    assert not (ROOT / "missing").exists()
    assert_no_spawn("missing")
    # A normal attach-owned outer client still upserts on the same switch.
    with terminal("attach", "source") as client:
        client.expect(b"zmx-test> ")
        client.command(f"{quoted} attach created /bin/bash --noprofile --norc -i")
        eventually(lambda: (client.read(), (ROOT / "created").exists())[1])
        client.expect(CLEANUP)
        assert b"\x1bc" not in client.output, "destructive attach switch reset"
        client.command("printf 'created-%s\\n' \"$ZMX_SESSION\"")
        client.expect(b"created-created")
        client.detach()


def directories():
    prefixed = dict(ENV, ZMX_SESSION_PREFIX="p.")
    create("source", prefixed)
    create("target", prefixed)
    with terminal("resume", "source", env=prefixed) as client:
        client.expect(b"zmx-test> ")
        client.command(f"{shlex.quote(ZMX)} attach target")
        client.expect(CLEANUP)
        assert b"\x1bc" not in client.output, "destructive prefixed switch reset"
        client.expect(b"zmx-test> ")
        client.command("printf 'prefix-%s\\n' \"$ZMX_SESSION\"")
        client.expect(b"prefix-p.target")
        client.detach()
    assert b"p.p." not in cli("list", "--short").stdout
    other = ROOT / "other"
    result = cli("resume", "source", env=dict(prefixed, ZMX_DIR=str(other)))
    assert result.returncode == 1, result
    assert not (other / "p.source").exists()
    assert (ROOT / "p.source").exists()


globals()[sys.argv[2]]()
