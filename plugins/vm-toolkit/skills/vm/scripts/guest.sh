#!/bin/bash
# guest.sh: builds and tests the shared worktree inside a factory VM, through the target's scripts.
#   guest.sh <vm run dir> build [<project>] [--clean]   the target's build (default: what the target builds); --clean first
#                                                       deletes the worktree's ignored files (bin/, obj/) from the Mac
#   guest.sh <vm run dir> test [--no-build] <project> [<filter>]   the target's test script on one test project;
#                                                       --no-build runs what the last build left (no rebuild)
#   guest.sh <vm run dir> info                          the guest's OS and SDK versions (for a verification record)
#   guest.sh <vm run dir> app launch | wait <s> | shot | click <x> <y> [right|double] | type <text> | key <combo>... |
#                         scroll <x> <y> <n> | stop     the builder's app, at any point while it works (not QA): launch
#                                                       (re)starts the build in the desktop session, shot saves a
#                                                       screenshot under <vm run dir>/app/ and prints its path; build and
#                                                       test stop a launched app first (it locks bin/)
#   guest.sh <vm run dir> app record start [<min>] | stop | caption <text> [<s>]   a video of the screen (vm/record.py):
#                                                       start records <vm run dir>/app/video-N.mp4 until stop (at most
#                                                       <min>, default VM_RECORD_MAX_MIN), clicks circled; caption shows
#                                                       text on it until the next one (or for <s> seconds; "" clears)
#   guest.sh <vm run dir> run '<powershell>'            one PowerShell command in the guest (logs, settings, files), 5 min
# Exit: 0 green, 1 the build or tests fail, 3 the harness failed (no exit code: time box, SSH, share; restore or SDK
# errors), 2 usage. It prints the errors and the summary; the full log is <vm run dir>/build.log or test.log.
# Nothing builds on the Mac: the guest is where the product ships, so it is where the loop compiles and tests.
# <vm run dir>/guest.conf, written by run-loop.sh, names the worktree and the target: WORKTREE, GUEST_BUILD, GUEST_TEST,
# GUEST_BUILD_MIN. bash 3.2 compatible.
set -u
X=$(cd "$(dirname "$0")" && pwd)
. "$X/lib/timebox.sh"
usage() { sed -n '3,17p' "$0" >&2; exit 2; }
[ $# -ge 2 ] || usage
D=$1 CMD=$2
shift 2
[ -f "$D/guest.conf" ] || { echo "HARNESS ERROR: no $D/guest.conf (no factory VM there)" >&2; exit 3; }
. "$D/guest.conf"
env=$("$X/vm/vmctl.sh" env "$D" 2> /dev/null) || { echo "HARNESS ERROR: the VM of $D is not running" >&2; exit 3; }
eval "$env"

# app_stop: ends what runs from the share (the app the builder launched), which would lock the build's output
app_stop() {
  [ -e "$D/app.running" ] || return 0
  "$X/vm/vmssh" 'Get-Process | Where-Object { $_.Path -like "R:\*" } | Stop-Process -Force -ErrorAction SilentlyContinue' > /dev/null 2>&1
  rm -f "$D/app.running"
}

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
    app_stop
    # Ignored files only: in a run's worktree those are build outputs; tracked files and the hand-back stay.
    [ "$clean" = yes ] && git -C "$WORKTREE" clean -fdXq -- . ':!handback'
    run "$D/build.log" "$GUEST_BUILD" "\$Project = $(ps_str "$proj")"
    report "$D/build.log" BUILD ;;
  test)
    nob='$false'
    [ "${1:-}" = --no-build ] && { nob='$true'; shift; }
    [ $# -ge 1 ] && [ $# -le 2 ] || usage
    app_stop
    run "$D/test.log" "$GUEST_TEST" "\$Project = $(ps_str "$1"); \$Filter = $(ps_str "${2:-}"); \$NoBuild = $nob"
    report "$D/test.log" TEST ;;
  app)
    sub=${1:-}
    [ $# -gt 0 ] && shift
    mkdir -p "$D/app"
    case "$sub" in
      launch)
        [ -n "${GUEST_LAUNCH:-}" ] && [ -f "$GUEST_LAUNCH" ] || { echo "HARNESS ERROR: this target has no launch script"; exit 3; }
        # The target's launch script stops a running instance itself: a relaunch after a build picks up the new build.
        "$X/vm/vmssh" - < "$GUEST_LAUNCH" > "$D/app/launch.log" 2>&1
        tail -3 "$D/app/launch.log"
        grep -q '^LAUNCH OK' "$D/app/launch.log" || exit 1
        : > "$D/app.running"
        echo "launched; the window can take a while to show: app wait, then app shot" ;;
      wait)
        [ "${1:-}" -ge 1 ] 2> /dev/null && [ "$1" -le 120 ] || usage
        sleep "$1" ;;
      shot)
        n=$(($(ls "$D/app"/shot-*.png 2> /dev/null | wc -l) + 1))
        # Against a runaway loop only, not a budget for looking.
        [ "$n" -le "${APP_SHOT_CAP:-200}" ] || { echo "app shot: ${APP_SHOT_CAP:-200} screenshots this run: a loop? Stop and rethink"; exit 1; }
        python3 "$X/vm/vm.py" shot "$D/app/shot-$n.png" ;;
      click|type|key|scroll)
        [ $# -ge 1 ] || usage
        python3 "$X/vm/vm.py" "$sub" "$@" ;;
      stop) : > "$D/app.running"; app_stop; echo "stopped" ;;
      record)
        case "${1:-}" in
          start)
            min=${2:-${VM_RECORD_MAX_MIN:-10}}
            [ "$min" -ge 1 ] 2> /dev/null && [ "$min" -le 60 ] || usage
            pid=$(cat "$VM_RUN_DIR/record.pid" 2> /dev/null) && kill -0 "$pid" 2> /dev/null \
              && { echo "already recording: app record stop first"; exit 1; }
            command -v ffmpeg > /dev/null || { echo "HARNESS ERROR: no ffmpeg on this Mac (brew install ffmpeg)"; exit 3; }
            [ -S "$VM_RUN_DIR/rec.sock" ] \
              || { echo "HARNESS ERROR: this VM was started without the recorder's socket: vmt down and up again to record"; exit 3; }
            n=$(ls "$D/app" 2> /dev/null | sed -n 's/^video-\([0-9]*\)\.mp4$/\1/p' | sort -n | tail -1)
            n=$((${n:-0} + 1))
            rm -f "$VM_RUN_DIR/recording"
            nohup python3 "$X/vm/record.py" run "$D/app/video-$n.mp4" $((min * 60)) > "$VM_RUN_DIR/record.log" 2>&1 < /dev/null &
            echo $! > "$VM_RUN_DIR/record.pid"
            for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$VM_RUN_DIR/recording" ] && break; sleep 0.5; done
            [ -f "$VM_RUN_DIR/recording" ] || { cat "$VM_RUN_DIR/record.log"; echo "HARNESS ERROR: the recorder did not start"; exit 3; }
            echo "recording $D/app/video-$n.mp4 (stops by itself after $min min): app record stop ends it" ;;
          stop) "$X/vm/vmctl.sh" record-stop "$D" ;;
          *) usage ;;
        esac ;;
      caption)
        [ $# -ge 1 ] && [ $# -le 2 ] || usage
        python3 "$X/vm/record.py" caption "$@" && echo "captioned" ;;
      *) usage ;;
    esac ;;
  run)
    [ $# -eq 1 ] || usage
    timebox 300 "$X/vm/vmssh" "$1" ;;
  info)
    "$X/vm/vmssh" '"guest: {0} {1} {2}; dotnet {3}" -f (Get-CimInstance Win32_OperatingSystem).Caption, [Environment]::OSVersion.Version, $env:PROCESSOR_ARCHITECTURE, (dotnet --version)' ;;
  *) usage ;;
esac
