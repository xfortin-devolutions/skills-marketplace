#!/bin/bash
# guest.test.sh: scripts/guest.sh's app and run commands, on fake VM tools (no VM, no QMP). The real guest.sh runs from a
# copy of the scripts folder whose vm/ holds the fakes: vmctl.sh and vmssh from tests/fakes/vm, and a vm.py that logs.
#   tests/guest.test.sh
# bash 3.2 compatible.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SKILL=$(cd "$HERE/../skills/vm" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/vmt-guest-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
FAILS=0
fail() { FAILS=$((FAILS + 1)); echo "  ✗ $*"; }
ok() { echo "  ✓ $*"; }

mkdir -p "$T/scripts/vm" "$T/state" "$T/vmrun"
cp "$SKILL/scripts/guest.sh" "$T/scripts/"
cp -R "$SKILL/scripts/lib" "$T/scripts/lib"
cp "$HERE/fakes/vm/vmctl.sh" "$HERE/fakes/vm/vmssh" "$T/scripts/vm/"
cat > "$T/scripts/vm/vm.py" <<'PY'
import os, sys
open(os.path.join(os.environ["FAKE_STATE"], "vmpy.log"), "a").write("vm.py " + " ".join(sys.argv[1:]) + "\n")
if sys.argv[1] == "shot":
    open(sys.argv[2], "w").close()
    print(sys.argv[2] + " 1600x900")
PY
chmod +x "$T/scripts/vm/"*
export FAKE_STATE=$T/state
echo 'Write-Output "LAUNCH OK"' > "$T/launch.ps1"
echo '# build' > "$T/build.ps1"
"$T/scripts/vm/vmctl.sh" up "$T/vmrun" > /dev/null
printf "WORKTREE='%s'\nGUEST_BUILD='%s'\nGUEST_TEST='%s'\nGUEST_BUILD_MIN=1\nGUEST_LAUNCH='%s'\nAPP_SHOT_CAP=2\n" \
  "$T" "$T/build.ps1" "$T/build.ps1" "$T/launch.ps1" > "$T/vmrun/guest.conf"
G() { bash "$T/scripts/guest.sh" "$T/vmrun" "$@"; }

echo "app launch, then a build stops the app"
G app launch > "$T/out" 2>&1 && [ -e "$T/vmrun/app.running" ] && ok "launched" || fail "launch: $(cat "$T/out")"
: > "$FAKE_STATE/vmssh.log"
G build > /dev/null 2>&1
grep -q 'Stop-Process' "$FAKE_STATE/vmssh.log" && [ ! -e "$T/vmrun/app.running" ] && ok "build stopped the app first" \
  || fail "build did not stop the app"
G app launch > /dev/null 2>&1 && G app launch > /dev/null 2>&1 && G app launch > /dev/null 2>&1 \
  && ok "no launch cap: relaunched three more times" || fail "a relaunch failed"

echo "app input and screenshots"
G app click 10 20 double > /dev/null && grep -q '^vm.py click 10 20 double$' "$FAKE_STATE/vmpy.log" && ok "click passes through" \
  || fail "click: $(cat "$FAKE_STATE/vmpy.log")"
G app shot | grep -q "app/shot-1.png" && G app shot | grep -q "app/shot-2.png" && ok "screenshots numbered under app/" \
  || fail "shot paths"
G app shot > "$T/out" 2>&1; [ $? -eq 1 ] && grep -q 'a loop' "$T/out" && ok "screenshot cap stops a runaway loop" \
  || fail "the screenshot cap did not hold: $(cat "$T/out")"

echo "run"
: > "$FAKE_STATE/vmssh.log"
G run 'Get-Content C:\app.log' > /dev/null 2>&1 && grep -q 'Get-Content C:\\app.log' "$FAKE_STATE/vmssh.log" \
  && ok "run sends its command" || fail "run: $(cat "$FAKE_STATE/vmssh.log")"
G run > /dev/null 2>&1; [ $? -eq 2 ] && ok "run without a command is usage" || fail "run without a command"

echo "a target with no launch script"
sed -i '' "s|^GUEST_LAUNCH=.*|GUEST_LAUNCH=''|" "$T/vmrun/guest.conf"
G app launch > "$T/out" 2>&1; [ $? -eq 3 ] && grep -q 'HARNESS ERROR' "$T/out" && ok "launch is a harness error" \
  || fail "launch without a script: $(cat "$T/out")"

[ "$FAILS" -eq 0 ] && echo "guest.sh: all passed" || { echo "guest.sh: $FAILS failed"; exit 1; }
