#!/usr/bin/env bats

load test_helper

# Sanitize before run captures output: its verbose/failure modes can print it.
producer_fixture() {
  local -a results
  python3 -B "$BATS_TEST_DIRNAME/resume_pty.py" "$ZMX" producer_drain 2>&1 | {
    local checked filter_status discarded
    if checked="$(python3 -I -S -B "$BATS_TEST_DIRNAME/producer_diagnostics.py" 2>/dev/null)"; then
      printf '%s\n' "$checked"
      filter_status=$?
    else
      filter_status=$?
    fi
    # Keep the pipe open even if validation fails, without retaining/printing
    # rejected bytes or causing the fixture to fail early on a broken pipe.
    while IFS= read -r -n 4096 discarded; do :; done
    exit "$filter_status"
  }
  results=("${PIPESTATUS[@]}")
  if [[ "${results[0]}" -ne 0 ]]; then
    printf 'producer fixture status=%s\n' "${results[0]}"
    if [[ "${results[1]}" -ne 0 ]]; then
      printf 'producer diagnostics=unavailable\n'
    fi
  fi
  return "${results[0]}"
} 2>/dev/null

@test "capabilities: exact response without configuration, logs, sockets, or stdin" {
  local untouched="$BATS_TEST_TMPDIR/untouched"
  run env ZMX_DIR="$untouched" HOME="$untouched" XDG_STATE_HOME="$untouched" \
    "$ZMX" capabilities
  [ "$status" -eq 0 ]
  [ "$output" = $'zmx-capabilities-v1\nresume\npreserve-scrollback' ]
  [ ! -e "$untouched" ]

  python3 - "$ZMX" "$untouched" <<'PY'
import os
import subprocess
import sys

with subprocess.Popen(
    [sys.argv[1], "capabilities"], env=dict(os.environ, ZMX_DIR=sys.argv[2]),
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
) as process:
    # Keep stdin open: discovery must exit without trying to consume it.
    assert process.wait(timeout=3) == 0
    assert process.stdout.read() == b"zmx-capabilities-v1\nresume\npreserve-scrollback\n"
    assert process.stderr.read() == b""
PY

  for arg in resume --help unknown; do
    run env ZMX_DIR="$untouched" "$ZMX" capabilities "$arg"
    [ "$status" -eq 2 ]
    [[ "$output" != *"zmx-capabilities-v1"* ]]
    [ ! -e "$untouched" ]
  done
}

@test "capabilities: unknown commands are not evidence of support" {
  run "$ZMX" unknown-command
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" != $'zmx-capabilities-v1\nresume\npreserve-scrollback' ]]
  run "$ZMX" list --short
  [ -z "$output" ]
}

@test "resume: requires exactly one name, not a shell command" {
  run "$ZMX" resume
  [ "$status" -eq 2 ]
  run "$ZMX" resume ""
  [ "$status" -eq 2 ]
  run "$ZMX" resume work sh
  [ "$status" -eq 2 ]
  run "$ZMX" resume ../work
  [ "$status" -eq 1 ]
  run "$ZMX" resume "$(printf '%200s' x)"
  [ "$status" -eq 1 ]
  run "$ZMX" list --short
  [ -z "$output" ]
}

@test "resume: help and all completion scripts describe the operation" {
  run "$ZMX" resume --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume <name>"* ]]
  [[ "$output" == *"capabilities"* ]]
  [[ "$output" == *"preserve-scrollback"* ]]
  for shell in bash zsh fish nu; do
    run "$ZMX" completions "$shell"
    [ "$status" -eq 0 ]
    [[ "$output" == *"resume"* ]]
    [[ "$output" == *"capabilities"* ]]
  done
}

@test "resume: bash completion offers the command and existing session names" {
  run bash -c '
    eval "$("$1" completions bash)"
    zmx() { if [[ "$*" == "list --short" ]]; then printf "work\nother\n"; else return 1; fi; }
    COMP_WORDS=(zmx res); COMP_CWORD=1; _zmx_completions
    [[ "${COMPREPLY[*]}" == "resume" ]] || exit 1
    COMP_WORDS=(zmx resume wo); COMP_CWORD=2; _zmx_completions
    [[ "${COMPREPLY[*]}" == "work" ]]
  ' bash "$ZMX"
  [ "$status" -eq 0 ]
}

@test "resume: first attachment restores output consumed before any terminal Init" {
  run python3 "$BATS_TEST_DIRNAME/resume_pty.py" "$ZMX" first_attach
  [ "$status" -eq 0 ]
}

@test "resume: restores terminal state, interacts, shares clients, and detaches" {
  run python3 "$BATS_TEST_DIRNAME/resume_pty.py" "$ZMX" interaction
  [ "$status" -eq 0 ]
}

@test "resume: missing, non-socket, and refused sockets never spawn or unlink" {
  run python3 "$BATS_TEST_DIRNAME/resume_pty.py" "$ZMX" absent
  [ "$status" -eq 0 ]
}

@test "resume: daemon disappearance during initialization fails on the retained socket" {
  run python3 "$BATS_TEST_DIRNAME/resume_pty.py" "$ZMX" race
  [ "$status" -eq 0 ]
}

@test "resume and attach: drain large restoration and Info through daemon EOF" {
  run python3 "$BATS_TEST_DIRNAME/resume_pty.py" "$ZMX" closing_restore
  [ "$status" -eq 0 ]
}

@test "resume: producer EOF drains healthy client and expires stalled snapshot after five seconds" {
  run producer_fixture
  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output"
    return 1
  }
}

@test "resume: switching stays non-creating; nested resume is rejected; attach still creates" {
  run python3 "$BATS_TEST_DIRNAME/resume_pty.py" "$ZMX" switching
  [ "$status" -eq 0 ]
}

@test "resume: session prefixes and socket-directory isolation are preserved" {
  run python3 "$BATS_TEST_DIRNAME/resume_pty.py" "$ZMX" directories
  [ "$status" -eq 0 ]
}
