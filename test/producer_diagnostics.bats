#!/usr/bin/env bats

# Deliberately do not load test_helper: these cases need no zmx or fixture state.
check_diagnostic_case() {
  run python3 -B "$BATS_TEST_DIRNAME/producer_diagnostics_checks.py" "$1"
  [ "$status" -eq 0 ] || {
    printf 'pure diagnostic case status=%s\n%s\n' "$status" "$output"
    return 1
  }
}

@test "producer diagnostics: unobserved-versus-empty" {
  check_diagnostic_case unobserved-versus-empty
}

@test "producer diagnostics: short-read-metrics" {
  check_diagnostic_case short-read-metrics
}

@test "producer diagnostics: phase-reset" {
  check_diagnostic_case phase-reset
}

@test "producer diagnostics: cached-returncode" {
  check_diagnostic_case cached-returncode
}

@test "producer diagnostics: numeric-boundaries" {
  check_diagnostic_case numeric-boundaries
}

@test "producer diagnostics: enum-and-field-rejection" {
  check_diagnostic_case enum-and-field-rejection
}

@test "producer diagnostics: payload-non-disclosure" {
  check_diagnostic_case payload-non-disclosure
}

@test "producer diagnostics: ascii-newline-size" {
  check_diagnostic_case ascii-newline-size
}

@test "producer diagnostics: failure-output-boundary" {
  check_diagnostic_case failure-output-boundary
}
