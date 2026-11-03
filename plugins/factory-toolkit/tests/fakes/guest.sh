#!/bin/bash
# Fake guest tool for tests/run-loop.test.sh: "builds" and "tests" the shared worktree by looking at it.
#   build: fails when <worktree>/BROKEN exists. test Accept.Tests: passes when src/feature.txt holds "done" (or always,
#   with $FAKE_STATE/accept-always-passes). Flaky.Tests fails its first run, Broken.Tests always fails.
#   test --no-build fails with no tests run when $FAKE_STATE/no-build-misses exists.
#   With $FAKE_STATE/restore-flake, the build is red, then its clean rebuild a harness error, then green.
#   With $FAKE_STATE/lock-on-test, the first test run holds the worktree's index.lock for 4 s.
D=$1 CMD=$2; shift 2
. "$D/guest.conf"
echo "$CMD $*" >> "$FAKE_STATE/guest.log"
pass() { echo "Passed!  - Failed:     0, Passed:     3, Skipped:     0, Total:     3, Duration: 1 ms - $1.dll"; echo "TEST EXIT CODE: 0"; exit 0; }
fail() { echo "  Failed $1.It [1 ms]"; echo "Failed!  - Failed:     1, Passed:     2, Skipped:     0, Total:     3, Duration: 1 ms - $1.dll"; echo "TEST EXIT CODE: 1"; exit 1; }
case "$CMD" in
  build) # $FAKE_STATE/restore-flake: the first build is red, the clean rebuild after it fails its restore (the harness).
         if [ -e "$FAKE_STATE/restore-flake" ]; then
           b=$(($(cat "$FAKE_STATE/build.n" 2> /dev/null || echo 0) + 1)); echo "$b" > "$FAKE_STATE/build.n"
           [ "$b" = 1 ] && { echo "    1 Error(s)"; echo "BUILD EXIT CODE: 1"; exit 1; }
           [ "$b" = 2 ] && { echo "NuGet.RestoreEx.targets(19,5): error : Could not find a part of the path"; echo "HARNESS ERROR: restore or SDK failure in the guest"; exit 3; }
         fi
         if [ -e "$WORKTREE/BROKEN" ]; then echo "src/a.cs(1,1): error CS0001: broken"; echo "BUILD EXIT CODE: 1"; exit 1; fi
         echo "    0 Error(s)"; echo "BUILD EXIT CODE: 0"; exit 0 ;;
  test)
    if [ "${1:-}" = --no-build ]; then
      shift
      # A test project the whole build doesn't cover: nothing to run without building it.
      [ -e "$FAKE_STATE/no-build-misses" ] && { echo "error: The test source file was not found."; echo "TEST EXIT CODE: 1"; exit 1; }
    fi
    k=$(($(cat "$FAKE_STATE/test-$1.n" 2> /dev/null || echo 0) + 1)); echo "$k" > "$FAKE_STATE/test-$1.n"
    # Another process (a plugin hook) holding the worktree's index.lock for a few seconds, on the first test run.
    if [ -e "$FAKE_STATE/lock-on-test" ] && [ "$k" = 1 ]; then
      l=$(git -C "$WORKTREE" rev-parse --path-format=absolute --git-path index.lock)
      touch "$l"; ( sleep 4; rm -f "$l" ) > /dev/null 2>&1 &
    fi
    case "$1" in
      Accept.Tests) { grep -q '^done' "$WORKTREE/src/feature.txt" 2> /dev/null || [ -e "$FAKE_STATE/accept-always-passes" ]; } && pass "$1" || fail "$1" ;;
      Flaky.Tests) [ "$k" -gt 1 ] && pass "$1" || fail "$1" ;;
      *) fail "$1" ;;
    esac ;;
  info) echo "guest: Fake OS 1.0 ARM64; dotnet 0.0" ;;
  *) exit 2 ;;
esac
