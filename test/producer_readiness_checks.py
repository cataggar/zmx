"""Finite pure checks: no runtime fixture, file, process, PTY, or clock probes."""

import sys

from producer_readiness import wait_for_output


class Clock:
    def __init__(self):
        self.value = 0.0

    def now(self):
        return self.value


def expect_error(kind, operation):
    try:
        operation()
    except kind as error:
        return error
    raise AssertionError("expected failure was not raised")


def legal_short_reads():
    clock = Clock()
    marker = b"PRODUCER_COMPLETE"
    payload = b"x" * (833 * 1024 - 3) + marker
    output = bytearray()
    waits = []

    def read(remaining):
        assert len(output) < len(payload), "read past the finite input"
        waits.append(remaining)
        chunk = payload[len(output):len(output) + 1024]
        output.extend(chunk)
        clock.value += 0.001
        return chunk

    wait_for_output(lambda: marker in output, read, clock.now, 8)
    assert output == payload and output.count(marker) == 1
    assert len(waits) == 834 and clock.value < 8
    assert all(0 < remaining <= 8 for remaining in waits)
    assert all(later < earlier for earlier, later in zip(waits, waits[1:]))
    count = len(waits)
    wait_for_output(lambda: marker in output, read, clock.now, 8)
    assert len(waits) == count, "already captured output must not wait again"


def no_output_deadline():
    clock = Clock()
    waits = []

    def read(remaining):
        assert not waits, "read again after the absolute deadline"
        waits.append(remaining)
        clock.value += remaining
        return None

    error = expect_error(
        AssertionError, lambda: wait_for_output(lambda: False, read, clock.now, 8),
    )
    assert str(error) == "condition did not become true"
    assert waits == [8] and clock.value == 8


def progress_keeps_deadline():
    for marker_at_expiry in (False, True):
        clock = Clock()
        output = bytearray()
        waits = []

        def read(remaining):
            assert len(waits) < 8, "read beyond the fixed deadline"
            waits.append(remaining)
            clock.value += 1
            chunk = b"complete" if marker_at_expiry and clock.value == 8 else b"x"
            output.extend(chunk)
            return chunk

        expect_error(
            AssertionError,
            lambda: wait_for_output(lambda: b"complete" in output, read, clock.now, 8),
        )
        assert waits == list(range(8, 0, -1)) and clock.value == 8
        assert len(waits) == 8, "progress must not renew the deadline"


def eof_stops_reading():
    clock = Clock()
    waits = []

    def read(remaining):
        assert not waits, "read again after EOF"
        waits.append(remaining)
        return b""

    expect_error(EOFError, lambda: wait_for_output(lambda: False, read, clock.now, 8))
    assert waits == [8] and clock.value == 0


def read_error_propagates():
    for error in (OSError(5, "synthetic read failure"), InterruptedError("interrupted")):
        clock = Clock()
        waits = []

        def read(remaining):
            assert not waits, "retried a read error"
            waits.append(remaining)
            raise error

        caught = expect_error(
            type(error), lambda: wait_for_output(lambda: False, read, clock.now, 8),
        )
        assert caught is error, "read errors must not be replaced or swallowed"
        assert waits == [8] and clock.value == 0


CASES = {
    "legal-short-reads": legal_short_reads,
    "no-output-deadline": no_output_deadline,
    "progress-keeps-deadline": progress_keeps_deadline,
    "eof-stops-reading": eof_stops_reading,
    "read-error-propagates": read_error_propagates,
}

if __name__ == "__main__":
    if not __debug__:
        raise SystemExit("pure readiness checks require enabled assertions")
    if len(sys.argv) != 2 or sys.argv[1] not in CASES:
        raise SystemExit("expected one known pure readiness case")
    CASES[sys.argv[1]]()
