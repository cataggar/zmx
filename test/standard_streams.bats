#!/usr/bin/env bats

load test_helper

check_standard_stream() {
  run python3 -B "$BATS_TEST_DIRNAME/standard_streams.py" "$ZMX" "$1" "$BATS_TEST_TMPDIR/stream-output"
  [ "$status" -eq 0 ] || {
    printf 'standard stream case status=%s\n%s\n' "$status" "$output"
    return 1
  }
}

@test "standard streams: stdout appends to a regular file" {
  check_standard_stream stdout-append
}

@test "standard streams: stderr appends to a regular file" {
  check_standard_stream stderr-append
}

@test "standard streams: stdout respects a nonzero file offset" {
  check_standard_stream stdout-offset
}

@test "standard streams: stderr respects a nonzero file offset" {
  check_standard_stream stderr-offset
}
