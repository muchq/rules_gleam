#!/bin/bash
# End-to-end test for the web_service example: starts the real gleam_release binary as a
# subprocess, makes a real HTTP request against it, and checks the response -- as opposed
# to web_service_test.gleam, which only unit-tests a pure helper function.
#
# Demonstrates the "wrap a gleam_release/gleam_binary executable in a native Bazel test
# rule" pattern for black-box acceptance testing: no custom Gleam or Erlang test code is
# needed here, just the compiled binary (as a `data` dependency) plus a normal shell test.
set -euo pipefail

PORT=34817
URL="http://localhost:${PORT}/"

# web_service_bin is itself runfiles-aware (see gleam_release's docstring): it looks for
# RUNFILES_DIR first, before falling back to locating its own ".runfiles" directory. Since
# this test's own runfiles tree (set up by Bazel's test-setup.sh, rooted at
# $TEST_SRCDIR/$TEST_WORKSPACE) already contains web_service_bin's compiled dependencies
# merged in as a `data` dependency, we can just point it there directly.
export RUNFILES_DIR="$TEST_SRCDIR"

./web_service_bin &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true' EXIT

READY=""
for _ in $(seq 1 40); do
  if RESPONSE="$(curl -sf --max-time 1 "$URL")"; then
    READY=1
    break
  fi
  sleep 0.25
done

if [[ -z "$READY" ]]; then
  echo "FAIL: server never became ready on $URL" >&2
  exit 1
fi

EXPECTED="Hello from web_service!"
if [[ "$RESPONSE" != "$EXPECTED" ]]; then
  echo "FAIL: expected response body '$EXPECTED', got '$RESPONSE'" >&2
  exit 1
fi

echo "PASS: got expected response body: $RESPONSE"
