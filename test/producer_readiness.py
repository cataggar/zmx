"""Import-safe output wait; I/O and the monotonic clock are supplied by callers."""


def wait_for_output(matches, read, monotonic, timeout):
    """Read immediately on progress, with one deadline and no idle allowance.

    read(remaining) waits at most remaining seconds, updates the caller's
    captured output, and returns bytes, or None if no input became ready.
    Empty bytes mean EOF. Read errors propagate without retrying.
    """
    deadline = monotonic() + timeout
    while True:
        matched = matches()
        remaining = deadline - monotonic()
        if remaining <= 0:
            raise AssertionError("condition did not become true")
        if matched:
            return
        if read(remaining) == b"":
            raise EOFError("terminal closed before expected output")
