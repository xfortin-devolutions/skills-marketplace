#!/bin/bash
# Fake guest tool for tests/run-loop.test.sh: "builds" and "tests" the shared worktree by looking at it.
#   build: fails when <worktree>/BROKEN exists. test Accept.Tests: passes when src/feature.txt holds "done" (or always,
#   with $FAKE_STATE/accept-always-passes). Flaky.Tests fails its first run, Broken.Tests always fails.
D=$1 CMD=$2; shift 2
. "$D/guest.conf"
echo "$CMD $*" >> "$FAKE_STATE/guest.log"
pass() { echo "Passed!  - Failed:     0, Passed:     3, Skipped:     0, Total:     3, Duration: 1 ms - $1.dll"; echo "TEST EXIT CODE: 0"; exit 0; }
fail() { echo "  Failed $1.It [1 ms]"; echo "Failed!  - Failed:     1, Passed:     2, Skipped:     0, Total:     3, Duration: 1 ms - $1.dll"; echo "TEST EXIT CODE: 1"; exit 1; }
case "$CMD" in
  build) if [ -e "$WORKTREE/BROKEN" ]; then echo "src/a.cs(1,1): error CS0001: broken"; echo "BUILD EXIT CODE: 1"; exit 1; fi
         echo "    0 Error(s)"; echo "BUILD EXIT CODE: 0"; exit 0 ;;
  test)
    k=$(($(cat "$FAKE_STATE/test-$1.n" 2> /dev/null || echo 0) + 1)); echo "$k" > "$FAKE_STATE/test-$1.n"
    case "$1" in
      Accept.Tests) { grep -q '^done' "$WORKTREE/src/feature.txt" 2> /dev/null || [ -e "$FAKE_STATE/accept-always-passes" ]; } && pass "$1" || fail "$1" ;;
      Flaky.Tests) [ "$k" -gt 1 ] && pass "$1" || fail "$1" ;;
      *) fail "$1" ;;
    esac ;;
  info) echo "guest: Fake OS 1.0 ARM64; dotnet 0.0" ;;
  *) exit 2 ;;
esac
