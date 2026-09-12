"""Finite memory-only checks selected by producer_diagnostics.bats.

Imports only the pure encoder and Python standard library. Never import the
runtime fixture. No files, environment, processes, PTYs, sockets, or signals
are accessed by these checks; -B prevents source bytecode-cache writes.
"""

import json
import sys

import producer_diagnostics as diagnostic


def unknown_metrics():
    return dict.fromkeys(diagnostic.NUMBERS + diagnostic.FLAGS)


def encode(metrics, role="healthy", error="assertion"):
    return diagnostic.encode_failure(
        "healthy_complete", "before_terminal_cleanup", error, role, "wait", metrics,
    )


def record(metrics, role="healthy"):
    return json.loads(encode(metrics, role))


def feed(metrics, size):
    metrics.checks += 1
    metrics.received(size)


def expect_rejection(*args):
    try:
        diagnostic.encode_failure(*args)
    except ValueError as error:
        if str(error) not in {
            "invalid producer diagnostic enum type",
            "invalid producer diagnostic enum",
            "invalid producer diagnostic fields",
        }:
            raise AssertionError("encoder rejection exposed an unexpected message") from None
        return
    raise AssertionError("invalid diagnostic input was accepted")


def unobserved_versus_empty():
    unobserved = record(unknown_metrics(), role=None)
    assert unobserved["terminal_role"] is None
    assert unobserved["client_status_source"] is None
    assert all(unobserved[name] is None for name in diagnostic.NUMBERS + diagnostic.FLAGS)
    assert unobserved["invalid_metrics"] is False

    metrics = unknown_metrics()
    metrics.update(diagnostic.ReadMetrics().scalars())
    metrics.update(diagnostic.ReadMetrics().scalars("phase_"))
    metrics.update(captured_bytes=0, rows_observed=0)
    metrics.update({name: False for name in diagnostic.FLAGS})
    observed = record(metrics)
    for name in ("read_checks", "nonempty_reads", "received_bytes", "captured_bytes", "rows_observed"):
        assert observed[name] == 0
    for name in ("min_read_bytes", "max_read_bytes", "client_returncode_cached"):
        assert observed[name] is None
    assert all(observed[name] is False for name in diagnostic.FLAGS)
    assert observed["client_status_source"] == "popen_returncode_cache"
    assert observed["invalid_metrics"] is False


def short_read_metrics():
    reads = diagnostic.ReadMetrics()
    for size in (0, 1024, 2048, 0):
        feed(reads, size)
    assert reads.scalars() == {
        "read_checks": 4, "nonempty_reads": 2, "received_bytes": 3072,
        "min_read_bytes": 1024, "max_read_bytes": 2048,
    }
    metrics = unknown_metrics()
    metrics.update(reads.scalars())
    encoded = record(metrics)
    assert all(encoded[name] == value for name, value in reads.scalars().items())


def phase_reset():
    total = diagnostic.ReadMetrics()
    phase = diagnostic.ReadMetrics()
    feed(total, 1024)
    feed(phase, 1024)
    before = total.scalars()
    phase = diagnostic.ReadMetrics()
    assert total.scalars() == before
    assert phase.scalars() == {
        "read_checks": 0, "nonempty_reads": 0, "received_bytes": 0,
        "min_read_bytes": None, "max_read_bytes": None,
    }
    feed(total, 2048)
    feed(phase, 2048)
    metrics = unknown_metrics()
    metrics.update(total.scalars())
    metrics.update(phase.scalars("phase_"))
    encoded = record(metrics)
    assert encoded["read_checks"] == 2 and encoded["phase_read_checks"] == 1
    assert encoded["received_bytes"] == 3072 and encoded["phase_received_bytes"] == 2048
    assert encoded["min_read_bytes"] == 1024 and encoded["phase_min_read_bytes"] == 2048


def cached_returncode():
    for status in (None, 0, 7, -15):
        metrics = unknown_metrics()
        metrics["client_returncode_cached"] = status
        encoded = record(metrics)
        assert encoded["client_returncode_cached"] == status
        assert encoded["client_status_source"] == "popen_returncode_cache"
        assert encoded["invalid_metrics"] is False
        assert "running" not in encoded


def numeric_boundaries():
    class IntSubclass(int):
        pass

    for name in diagnostic.NUMBERS:
        for value in (None, 0, diagnostic.MAX_METRIC):
            metrics = unknown_metrics()
            metrics[name] = value
            encoded = record(metrics)
            assert encoded[name] == value and encoded["invalid_metrics"] is False
        invalid = (
            diagnostic.MAX_METRIC + 1, -diagnostic.MAX_METRIC - 1,
            0.5, float("nan"), float("inf"), True, False, "not a number", [], {},
            IntSubclass(1), object(),
        )
        for value in invalid:
            metrics = unknown_metrics()
            metrics[name] = value
            encoded = record(metrics)
            assert encoded[name] is None and encoded["invalid_metrics"] is True
        metrics = unknown_metrics()
        metrics[name] = -diagnostic.MAX_METRIC if name == "client_returncode_cached" else -1
        encoded = record(metrics)
        if name == "client_returncode_cached":
            assert encoded[name] == -diagnostic.MAX_METRIC and encoded["invalid_metrics"] is False
        else:
            assert encoded[name] is None and encoded["invalid_metrics"] is True

    for name in diagnostic.FLAGS:
        for value in (None, False, True):
            metrics = unknown_metrics()
            metrics[name] = value
            encoded = record(metrics)
            assert encoded[name] is value and encoded["invalid_metrics"] is False
        for value in (0, 1, "false", []):
            metrics = unknown_metrics()
            metrics[name] = value
            encoded = record(metrics)
            assert encoded[name] is None and encoded["invalid_metrics"] is True


def enum_and_field_rejection():
    class StringSubclass(str):
        pass

    defaults = ["healthy_complete", "before_terminal_cleanup", "assertion", "healthy", "wait"]
    choices = (diagnostic.PHASES, diagnostic.POINTS, diagnostic.ERRORS, diagnostic.ROLES, diagnostic.SITES)
    fields = ("phase", "observation", "error", "terminal_role", "failure_site")
    for index, values in enumerate(choices):
        for value in values:
            args = defaults.copy()
            args[index] = value
            encoded = json.loads(diagnostic.encode_failure(*args, unknown_metrics()))
            assert encoded[fields[index]] == value
        for value in ("", "not-listed", b"bytes", True, 17, (), object(), StringSubclass(defaults[index])):
            args = defaults.copy()
            args[index] = value
            expect_rejection(*args, unknown_metrics())
        if index != 3:  # null role is a valid unobserved value
            args = defaults.copy()
            args[index] = None
            expect_rejection(*args, unknown_metrics())
    missing = unknown_metrics()
    del missing[diagnostic.NUMBERS[0]]
    expect_rejection(*defaults, missing)
    extra = unknown_metrics()
    extra["payload"] = "not allowed"
    expect_rejection(*defaults, extra)


def payload_non_disclosure():
    payload = "ENCODER_PAYLOAD_SENTINEL_" * 2048

    class Unformattable(Exception):
        def __str__(self):
            raise AssertionError("exception message must not be inspected")

    errors = (
        (AssertionError(payload.encode("ascii")), "assertion"),
        (TimeoutError(payload), "timeout"),
        (OSError(5, payload, "/example/path"), "os_error"),
        (EOFError(payload), "other"),
        (KeyboardInterrupt(payload), "keyboard_interrupt"),
        (SystemExit(payload), "system_exit"),
        (Unformattable(payload), "other"),
    )
    for error, expected_kind in errors:
        kind = diagnostic.error_kind(error)
        assert kind == expected_kind
        encoded = encode(unknown_metrics(), error=kind)
        assert b"ENCODER_PAYLOAD_SENTINEL_" not in encoded
        assert b"/example/path" not in encoded
        decoded = json.loads(encoded)
        assert not {"payload", "argv", "env", "path", "message", "traceback"} & set(decoded)

    metrics = unknown_metrics()
    metrics["received_bytes"] = payload
    encoded = encode(metrics)
    assert b"ENCODER_PAYLOAD_SENTINEL_" not in encoded
    assert json.loads(encoded)["invalid_metrics"] is True
    expect_rejection(payload, "operation", "assertion", None, "other", unknown_metrics())
    extra = unknown_metrics()
    extra[payload] = payload
    expect_rejection("setup", "operation", "assertion", None, "other", extra)


def ascii_newline_size():
    longest = lambda values: max(values, key=lambda value: len(json.dumps(value)))
    metrics = {name: diagnostic.MAX_METRIC for name in diagnostic.NUMBERS}
    metrics["client_returncode_cached"] = -diagnostic.MAX_METRIC
    metrics.update({name: False for name in diagnostic.FLAGS})
    encoded = diagnostic.encode_failure(
        longest(diagnostic.PHASES), longest(diagnostic.POINTS), longest(diagnostic.ERRORS),
        longest(diagnostic.ROLES), longest(diagnostic.SITES), metrics,
    )
    assert type(encoded) is bytes
    assert diagnostic.MAX_RECORD_BYTES == 4096
    assert len(encoded) <= diagnostic.MAX_RECORD_BYTES
    assert encoded.endswith(b"\n") and encoded.count(b"\n") == 1
    assert all(byte < 128 for byte in encoded)
    decoded = json.loads(encoded)
    assert set(decoded) == set(diagnostic.NUMBERS + diagnostic.FLAGS) | {
        "schema", "phase", "observation", "error", "failure_site",
        "terminal_role", "client_status_source", "invalid_metrics",
    }
    assert decoded["schema"] == "zmx-producer-failure-v1"
    assert decoded["invalid_metrics"] is False
    assert all(value is None or type(value) in (int, bool, str) for value in decoded.values())
    assert all(decoded[name] == value for name, value in metrics.items())


def failure_output_boundary():
    sentinel = b"INITIALIZATION_DETAIL_MUST_NOT_ESCAPE"
    initialization_error = (
        b"Traceback (most recent call last):\n"
        b"  File \"fixture.py\", line 27, in <module>\n"
        b"    Path(home).mkdir()\n"
        b"FileExistsError: [Errno 17] " + sentinel + b"\n"
    )
    valid = encode(unknown_metrics())
    assert diagnostic.filter_failure_output(valid) == valid
    invalid_metrics = unknown_metrics()
    invalid_metrics["read_checks"] = False
    flagged = encode(invalid_metrics)
    assert json.loads(flagged)["invalid_metrics"] is True
    assert diagnostic.filter_failure_output(flagged) == flagged

    malformed = [
        initialization_error, initialization_error + valid, valid + initialization_error,
        b"", b"\xff", b"null\n", b"[]\n", b"{}\n", b"{" * 2048,
        b"[" * 1024 + b"]" * 1024, valid + b"\x00",
        valid[:-1], valid + b"\n", valid + valid,
        b" " * (diagnostic.MAX_RECORD_BYTES + 1),
        valid + b"\n" * diagnostic.MAX_RECORD_BYTES,
        valid.replace(b'"schema":', b'"schema":"duplicate","schema":', 1),
    ]
    for name, value in (
        ("schema", "unknown"), ("client_status_source", "unknown"),
        ("terminal_role", "unknown"), ("phase", sentinel.decode("ascii")),
        ("read_checks", True), ("received_bytes", -1),
        ("invalid_metrics", 1), ("payload", sentinel.decode("ascii")),
    ):
        changed = json.loads(valid)
        changed[name] = value
        malformed.append((json.dumps(changed, separators=(",", ":")) + "\n").encode("ascii"))
    for captured in malformed:
        filtered = diagnostic.filter_failure_output(captured)
        assert filtered == b"producer diagnostics=unavailable\n"
        assert sentinel not in filtered and b"Traceback" not in filtered
        assert b"FileExistsError" not in filtered and b"fixture.py" not in filtered
        assert len(filtered) <= diagnostic.MAX_RECORD_BYTES


CASES = {
    "unobserved-versus-empty": unobserved_versus_empty,
    "short-read-metrics": short_read_metrics,
    "phase-reset": phase_reset,
    "cached-returncode": cached_returncode,
    "numeric-boundaries": numeric_boundaries,
    "enum-and-field-rejection": enum_and_field_rejection,
    "payload-non-disclosure": payload_non_disclosure,
    "ascii-newline-size": ascii_newline_size,
    "failure-output-boundary": failure_output_boundary,
}

if __name__ == "__main__":
    if not __debug__:
        raise SystemExit("pure diagnostic checks require enabled assertions")
    if len(sys.argv) != 2 or sys.argv[1] not in CASES:
        raise SystemExit("expected one known pure diagnostic case")
    CASES[sys.argv[1]]()
