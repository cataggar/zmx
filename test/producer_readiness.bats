#!/usr/bin/env bats

# No session helper or runtime fixture: only an injected clock and reader.
check_readiness_case() {
  run python3 -B "$BATS_TEST_DIRNAME/producer_readiness_checks.py" "$1"
  [ "$status" -eq 0 ] || {
    printf 'pure readiness case status=%s\n%s\n' "$status" "$output"
    return 1
  }
}

@test "producer readiness: legal-short-reads" {
  check_readiness_case legal-short-reads
}

@test "producer readiness: no-output-deadline" {
  check_readiness_case no-output-deadline
}

@test "producer readiness: progress-keeps-deadline" {
  check_readiness_case progress-keeps-deadline
}

@test "producer readiness: eof-stops-reading" {
  check_readiness_case eof-stops-reading
}

@test "producer readiness: read-error-propagates" {
  check_readiness_case read-error-propagates
}
