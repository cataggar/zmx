"""Owned regular-file/CLI regressions, not a pure test entrypoint."""

from pathlib import Path
import subprocess
import sys


PREFIX = b"EXISTING_FILE_PREFIX\n"
CASES = ("stdout-append", "stderr-append", "stdout-offset", "stderr-offset")


def check(binary, case, path):
    stream_name, mode = case.split("-")
    arguments = [binary, "capabilities"]
    if stream_name == "stdout":
        expected = b"zmx-capabilities-v1\nresume\npreserve-scrollback\n"
        expected_status = 0
    else:
        arguments.append("extra")
        expected = b"error: usage: zmx capabilities\n"
        expected_status = 2

    with path.open("xb") as initial:
        initial.write(PREFIX)
    with path.open("ab" if mode == "append" else "r+b", buffering=0) as destination:
        # Append must override a zero seek position; ordinary writes must honor
        # the inherited nonzero position. Both must advance the shared offset.
        destination.seek(0 if mode == "append" else len(PREFIX))
        result = subprocess.run(
            arguments, stdin=subprocess.DEVNULL,
            stdout=destination if stream_name == "stdout" else subprocess.PIPE,
            stderr=destination if stream_name == "stderr" else subprocess.PIPE,
            timeout=8,
        )
        assert result.returncode == expected_status, "unexpected CLI exit status"
        other = result.stderr if stream_name == "stdout" else result.stdout
        assert other == b"", "unexpected output on the other standard stream"
        assert destination.tell() == len(PREFIX) + len(expected), "shared offset was not advanced"
    assert path.read_bytes() == PREFIX + expected, "existing regular-file output was overwritten"


if __name__ == "__main__":
    if not __debug__:
        raise SystemExit("standard stream checks require enabled assertions")
    if len(sys.argv) != 4 or sys.argv[2] not in CASES:
        raise SystemExit("expected binary, known standard stream case, and owned output path")
    check(sys.argv[1], sys.argv[2], Path(sys.argv[3]))
