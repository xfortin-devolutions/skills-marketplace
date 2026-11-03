#!/bin/bash
# guest.sh: builds and tests the shared worktree inside a factory VM, through the target's scripts.
#   guest.sh <vm run dir> build [<project>] [--clean]   the target's build (default: what the target builds); --clean first
#                                                       deletes the worktree's ignored files (bin/, obj/) from the Mac
#   guest.sh <vm run dir> test [--no-build] <project> [<filter>]   the target's test script on one test project;
#                                                       --no-build runs what the last build left (no rebuild)
#   guest.sh <vm run dir> info                          the guest's OS and SDK versions (for a verification record)
# Exit: 0 green, 1 the build or tests fail, 3 the harness failed (no exit code: time box, SSH, share; restore or SDK
# errors), 2 usage. It prints the errors and the summary; the full log is <vm run dir>/build.log or test.log.
# Nothing builds on the Mac: the guest is where the product ships, so it is where the loop compiles and tests.
# <vm run dir>/guest.conf, written by run-loop.sh, names the worktree and the target: WORKTREE, GUEST_BUILD, GUEST_TEST,
# GUEST_BUILD_MIN. bash 3.2 compatible.
set -u
X=$(cd "$(dirname "$0")" && pwd)
. "$X/lib/timebox.sh"
usage() { sed -n '3,7p' "$0" >&2; exit 2; }
[ $# -ge 2 ] || usage
D=$1 CMD=$2
shift 2
[ -f "$D/guest.conf" ] || { echo "HARNESS ERROR: no $D/guest.conf (no factory VM there)" >&2; exit 3; }
. "$D/guest.conf"
env=$("$X/vm/vmctl.sh" env "$D" 2> /dev/null) || { echo "HARNESS ERROR: the VM of $D is not running" >&2; exit 3; }
eval "$env"

# ps_str <value>: the value as a PowerShell single-quoted literal
ps_str() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

# run <log> <script> <inputs>: the target script, its inputs first, time-boxed; the full output goes to <log>
run() {
  { printf '%s\n' "$3"; cat "$2"; } | timebox $((GUEST_BUILD_MIN * 60)) "$X/vm/vmssh" - > "$1" 2>&1
  echo "== vmssh exit $? (142 = time box)" >> "$1"
}

# report <log> <BUILD|TEST>: prints the errors and the summary, then exits with the verdict
report() {
  local code errs
  code=$(grep -oE "$2 EXIT CODE: -?[0-9]+" "$1" | tail -1 | grep -oE -- '-?[0-9]+$')
  errs=$(grep -E ': ([A-Za-z]+ )?error |^ *Failed [^!]' "$1" | sed -E 's/ \[[^]]*\]$//' | awk '!seen[$0]++' | head -40)
  [ -n "$errs" ] && printf '%s\n' "$errs"
  grep -E 'Warning\(s\)|Error\(s\)|Passed!|Failed!|Total tests|Time Elapsed|EXIT CODE' "$1" | tail -6
  echo "full log: $1"
  if [ -z "$code" ]; then
    echo "HARNESS ERROR: no $2 EXIT CODE (time box, SSH or share): $(grep -v '^[[:space:]]*$' "$1" | tail -1)"
    exit 3
  fi
  # NuGet's restore task can fail with no NU code (an I/O error writing obj/ over the share): still not the change.
  if [ "$code" != 0 ] && grep -qE 'error (NU[0-9]|NETSDK|MSB4236)|NuGet\.[A-Za-z]*\.?targets\([0-9,]+\): error ' "$1"; then
    echo "HARNESS ERROR: restore or SDK failure in the guest"
    exit 3
  fi
  [ "$code" = 0 ]
  exit $?
}

case "$CMD" in
  build)
    proj="" clean=no
    for a in "$@"; do
      case "$a" in --clean) clean=yes ;; -*) usage ;; *) proj=$a ;; esac
    done
    # Ignored files only: in a run's worktree those are build outputs; tracked files and the hand-back stay.
    [ "$clean" = yes ] && git -C "$WORKTREE" clean -fdXq -- . ':!handback'
    run "$D/build.log" "$GUEST_BUILD" "\$Project = $(ps_str "$proj")"
    report "$D/build.log" BUILD ;;
  test)
    nob='$false'
    [ "${1:-}" = --no-build ] && { nob='$true'; shift; }
    [ $# -ge 1 ] && [ $# -le 2 ] || usage
    run "$D/test.log" "$GUEST_TEST" "\$Project = $(ps_str "$1"); \$Filter = $(ps_str "${2:-}"); \$NoBuild = $nob"
    report "$D/test.log" TEST ;;
  info)
    "$X/vm/vmssh" '"guest: {0} {1} {2}; dotnet {3}" -f (Get-CimInstance Win32_OperatingSystem).Caption, [Environment]::OSVersion.Version, $env:PROCESSOR_ARCHITECTURE, (dotnet --version)' ;;
  *) usage ;;
esac
