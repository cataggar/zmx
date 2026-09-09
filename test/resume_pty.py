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
        if select.select([self.master], [], [], 0.05)[0]:
            try:
                self.output += os.read(self.master, 65536)
            except OSError:
                pass
        return self.output

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


def pid(name):
    listing = cli("list").stdout.decode()
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


def read_message(connection):
    def read_exact(size):
        data = b""
        while len(data) < size:
            part = connection.recv(size - len(data))
            assert part, "client closed a probe socket instead of retaining it"
            data += part
        return data

    header = read_exact(8)
    length = int.from_bytes(header[1:5], sys.byteorder)
    return header[0], read_exact(length)


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
                    tag, payload = read_message(connection)
                    assert tag == 7 and len(payload) == 8, (tag, payload)
                    tag, payload = read_message(connection)
                    assert tag == 6 and payload == b"", (tag, payload)
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
                    assert read_message(connection)[0] == 7
                    assert read_message(connection) == (6, b"")
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
