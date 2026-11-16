"""Pure, bounded scalar encoding for the producer fixture; no runtime probes.

Read checks count single-read attempts, including readiness waits, not syscalls
or continuous readiness. Nonempty sizes are the observed buffer growth.
Progress timestamps sample completed read/capture calls, not readiness, CPU
usage, or kernel-blocked time. Only first, last, and maximum gap are retained.
Null means unobserved; an absent cached returncode does not establish liveness.
"""

import json


MAX_RECORD_BYTES = 4096
MAX_METRIC = (1 << 63) - 1
UNAVAILABLE_OUTPUT = b"producer diagnostics=unavailable\n"
PHASES = (
    "setup", "fifo_create", "producer_source", "fifo_open", "environment",
    "starter_create", "starter_ready", "starter_detach", "starter_cleanup",
    "healthy_create", "healthy_ready", "producer_emit", "healthy_complete",
    "row_count", "slow_create", "slow_options", "slow_connect", "slow_request",
    "slow_boundary", "slow_header", "snapshot_size", "producer_finish",
    "healthy_finish", "healthy_finish_time", "deadline_log", "deadline_time",
    "slow_receive", "truncated_snapshot", "expiry_assertion", "no_spawn",
    "healthy_cleanup", "fifo_close", "fifo_unlink", "producer_unlink",
)
POINTS = ("operation", "before_terminal_cleanup", "before_fifo_cleanup", "terminal_cleanup", "fifo_cleanup")
ERRORS = ("assertion", "timeout", "os_error", "keyboard_interrupt", "system_exit", "other")
ROLES = (None, "starter", "healthy")
SITES = ("producer", "wait", "terminal_init", "terminal_read", "terminal_expect", "terminal_finished", "terminal_close", "other")
NUMBERS = (
    "total_elapsed_ms", "phase_elapsed_ms",
    "read_checks", "nonempty_reads", "received_bytes", "min_read_bytes", "max_read_bytes",
    "phase_read_checks", "phase_nonempty_reads", "phase_received_bytes",
    "phase_min_read_bytes", "phase_max_read_bytes",
    "phase_first_productive_ms", "phase_last_productive_ms",
    "phase_last_productive_age_ms", "phase_max_productive_gap_ms",
    "captured_bytes", "rows_observed", "client_returncode_cached", "errno",
    "socket_send_buffer_bytes", "snapshot_bytes", "slow_received_bytes", "failure_line",
)
FLAGS = ("ready_seen", "complete_seen", "rows_12000_observed")


class ReadMetrics:
    def __init__(self):
        self.checks = 0
        self.nonempty = 0
        self.bytes = 0
        self.minimum = None
        self.maximum = None
        self.first_productive_ns = None
        self.last_productive_ns = None
        self.max_productive_gap_ns = None

    def received(self, size, *, completed_ns=None):
        if size > 0:
            self.nonempty += 1
            self.bytes += size
            self.minimum = size if self.minimum is None else min(self.minimum, size)
            self.maximum = size if self.maximum is None else max(self.maximum, size)
            if completed_ns is not None:
                if self.first_productive_ns is None:
                    self.first_productive_ns = completed_ns
                if self.last_productive_ns is not None:
                    gap = completed_ns - self.last_productive_ns
                    self.max_productive_gap_ns = gap if self.max_productive_gap_ns is None else max(self.max_productive_gap_ns, gap)
                self.last_productive_ns = completed_ns

    def scalars(self, prefix=""):
        return {
            prefix + "read_checks": self.checks,
            prefix + "nonempty_reads": self.nonempty,
            prefix + "received_bytes": self.bytes,
            prefix + "min_read_bytes": self.minimum,
            prefix + "max_read_bytes": self.maximum,
        }

    def progress_scalars(self, started_ns, observed_ns):
        measured = started_ns is not None and observed_ns is not None
        first = self.first_productive_ns if measured else None
        last = self.last_productive_ns if measured else None
        gap = self.max_productive_gap_ns if measured else None
        return {
            "phase_first_productive_ms": None if first is None else (first - started_ns) // 1_000_000,
            "phase_last_productive_ms": None if last is None else (last - started_ns) // 1_000_000,
            "phase_last_productive_age_ms": None if last is None else (observed_ns - last) // 1_000_000,
            "phase_max_productive_gap_ms": None if gap is None else gap // 1_000_000,
        }


def error_kind(error):
    if isinstance(error, AssertionError):
        return "assertion"
    if isinstance(error, TimeoutError):
        return "timeout"
    if isinstance(error, OSError):
        return "os_error"
    if isinstance(error, KeyboardInterrupt):
        return "keyboard_interrupt"
    if isinstance(error, SystemExit):
        return "system_exit"
    return "other"


def encode_failure(phase, point, error, role, site, metrics, *, invalid_metrics=False):
    """Never accept payload, exception text, arbitrary keys, or arbitrary strings."""
    if any(type(value) is not str for value in (phase, point, error, site)) or (role is not None and type(role) is not str):
        raise ValueError("invalid producer diagnostic enum type")
    if phase not in PHASES or point not in POINTS or error not in ERRORS or role not in ROLES or site not in SITES:
        raise ValueError("invalid producer diagnostic enum")
    if set(metrics) != set(NUMBERS + FLAGS):
        raise ValueError("invalid producer diagnostic fields")
    if type(invalid_metrics) is not bool:
        raise ValueError("invalid producer diagnostic flag")
    record = {
        "schema": "zmx-producer-failure-v1",
        "phase": phase,
        "observation": point,
        "error": error,
        "failure_site": site,
        "terminal_role": role,
        # Null returncode means no cached exit observation, NOT "running".
        "client_status_source": None if role is None else "popen_returncode_cache",
    }
    # Revalidation preserves a flag set before invalid observations became null.
    invalid = invalid_metrics
    for name in NUMBERS:
        value = metrics[name]
        minimum = -MAX_METRIC if name == "client_returncode_cached" else 0
        if value is not None and (type(value) is not int or not minimum <= value <= MAX_METRIC):
            value = None
            invalid = True
        record[name] = value
    for name in FLAGS:
        value = metrics[name]
        if value is not None and type(value) is not bool:
            value = None
            invalid = True
        record[name] = value
    record["invalid_metrics"] = invalid
    # Fixed keys/enums and at most 19-digit magnitudes bound the record by
    # construction; keep an independent guard against schema changes.
    encoded = (json.dumps(record, ensure_ascii=True, separators=(",", ":")) + "\n").encode("ascii")
    if len(encoded) > MAX_RECORD_BYTES:
        raise ValueError("producer diagnostic exceeds size limit")
    return encoded


def filter_failure_output(captured):
    """Re-encode one complete canonical record; never forward captured text."""
    if type(captured) is not bytes or len(captured) > MAX_RECORD_BYTES:
        return UNAVAILABLE_OUTPUT
    try:
        record = json.loads(captured)
        if type(record) is not dict:
            return UNAVAILABLE_OUTPUT
        encoded = encode_failure(
            record["phase"], record["observation"], record["error"],
            record["terminal_role"], record["failure_site"],
            {name: record[name] for name in NUMBERS + FLAGS},
            invalid_metrics=record["invalid_metrics"],
        )
    except (ValueError, KeyError, TypeError, RecursionError):
        return UNAVAILABLE_OUTPUT
    # Exact equality also rejects extra/duplicate keys, altered metadata,
    # noncanonical values, and incomplete or multiple records.
    return encoded if encoded == captured else UNAVAILABLE_OUTPUT


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 1:
        raise SystemExit(2)
    filtered = filter_failure_output(sys.stdin.buffer.read(MAX_RECORD_BYTES + 1))
    if filtered == UNAVAILABLE_OUTPUT:
        raise SystemExit(1)
    sys.stdout.buffer.write(filtered)
    sys.stdout.buffer.flush()
