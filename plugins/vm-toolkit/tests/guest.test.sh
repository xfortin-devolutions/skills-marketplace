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
# The time box runs the command, or with $FAKE_STATE/time-box, stops it at once as the real one does at its limit.
echo 'timebox() { if [ -e "$FAKE_STATE/time-box" ]; then cat > /dev/null; return 142; fi; shift; "$@"; }' > "$T/scripts/lib/timebox.sh"
cat > "$T/scripts/vm/vm.py" <<'PY'
import os, sys
open(os.path.join(os.environ["FAKE_STATE"], "vmpy.log"), "a").write("vm.py " + " ".join(sys.argv[1:]) + "\n")
if sys.argv[1] == "shot":
    open(sys.argv[2], "w").close()
    print(sys.argv[2] + " 1600x900")
PY
cat > "$T/scripts/vm/highlight.py" <<'PY'
import os, sys
open(os.path.join(os.environ["FAKE_STATE"], "vmpy.log"), "a").write("highlight.py " + " ".join(sys.argv[1:]) + "\n")
open(sys.argv[2], "w").close()
print(sys.argv[2])
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
rm "$T/vmrun/app/shot-2.png"
G app shot --highlight 1,2,3,4,Save --no-dim > "$T/out" 2>&1 && grep -q "^highlighted $T/vmrun/app/highlight-2.png$" "$T/out" \
  && grep -q "^highlight.py $T/vmrun/app/shot-2.png $T/vmrun/app/highlight-2.png 1,2,3,4,Save --no-dim$" "$FAKE_STATE/vmpy.log" \
  && ok "a highlighted shot keeps the plain one and adds its highlighted copy" || fail "highlighted shot: $(cat "$T/out")"
G app shot --frame 1 > /dev/null 2>&1; [ $? -eq 2 ] && ok "an unknown shot option is a usage error" || fail "shot --frame"
G app shot > "$T/out" 2>&1; [ $? -eq 1 ] && grep -q 'a loop' "$T/out" && ok "screenshot cap stops a runaway loop" \
  || fail "the screenshot cap did not hold: $(cat "$T/out")"

echo "run"
: > "$FAKE_STATE/vmssh.log"
G run 'Get-Content C:\app.log' > /dev/null 2>&1 && grep -q 'Get-Content C:\\app.log' "$FAKE_STATE/vmssh.log" \
  && ok "run sends its command" || fail "run: $(cat "$FAKE_STATE/vmssh.log")"
: > "$FAKE_STATE/vmssh-noshare.log"
G run 'Start-Sleep 4' > /dev/null 2>&1; G run 'Get-ChildItem r:\out' > /dev/null 2>&1; G run 'Write-Error "ERROR: x"' > /dev/null 2>&1
grep -q 'Start-Sleep 4' "$FAKE_STATE/vmssh-noshare.log" && grep -q 'ERROR: x' "$FAKE_STATE/vmssh-noshare.log" \
  && ! grep -q 'r:\\out' "$FAKE_STATE/vmssh-noshare.log" && ok "run maps R: only for a command that names it" \
  || fail "share skipped for: $(cat "$FAKE_STATE/vmssh-noshare.log")"
G run > /dev/null 2>&1; [ $? -eq 2 ] && ok "run without a command is usage" || fail "run without a command"

echo "a target with no launch script"
sed -i '' "s|^GUEST_LAUNCH=.*|GUEST_LAUNCH=''|" "$T/vmrun/guest.conf"
G app launch > "$T/out" 2>&1; [ $? -eq 3 ] && grep -q 'HARNESS ERROR' "$T/out" && ok "launch is a harness error" \
  || fail "launch without a script: $(cat "$T/out")"

echo "a guest build stopped by its time box"
touch "$FAKE_STATE/time-box"; : > "$FAKE_STATE/vmssh.log"
G build > "$T/out" 2>&1 <<< "left for the caller"; rc=$?
rm "$FAKE_STATE/time-box"
[ $rc -eq 3 ] && grep -q 'Stop-Process' "$FAKE_STATE/vmssh.log" && grep -q '"dotnet", "MSBuild"' "$FAKE_STATE/vmssh.log" && grep -q 'R:' "$FAKE_STATE/vmssh.log" \
  && ok "a harness error, and the build left in the guest is stopped" || fail "time box: rc $rc, $(cat "$FAKE_STATE/vmssh.log")"
! grep -q 'left for the caller' "$FAKE_STATE/vmssh.log" && ok "and the caller's stdin is left alone (a loop reading a list)" \
  || fail "the time box's stop read the caller's stdin"

echo "a target that builds on the Mac (HOST_BUILD)"
cat > "$T/host-build.sh" <<'SH'
[ "${1:-}" = --check ] && { [ -e "$FAKE_STATE/host-declines" ] && { echo "this commit predates the fix"; exit 1; }; exit 0; }
echo "host build of '$PROJECT' in $WORKTREE" >> "$FAKE_STATE/host.log"
[ -e "$FAKE_STATE/host-red" ] && { echo "x.cs(1,1): error CS0103: nope"; echo "BUILD EXIT CODE: 1"; exit; }
[ -e "$FAKE_STATE/host-no-sdk" ] && { echo "no dotnet SDK on this Mac"; exit; }
echo "BUILD EXIT CODE: 0"
SH
printf '# test\n# FAKE-OUT: TEST EXIT CODE: 0\n' > "$T/test.ps1"
sed -i '' -e "s|^GUEST_LAUNCH=.*|GUEST_LAUNCH='$T/launch.ps1'|" -e "s|^GUEST_TEST=.*|GUEST_TEST='$T/test.ps1'|" "$T/vmrun/guest.conf"
echo "HOST_BUILD='$T/host-build.sh'" >> "$T/vmrun/guest.conf"
G on-host build && ok "a build is on the Mac" || fail "on-host build"
G on-host test x.csproj; [ $? -ne 0 ] && ok "a test is not" || fail "on-host test"
G app launch > /dev/null 2>&1
"$T/scripts/vm/vmctl.sh" down "$T/vmrun" > /dev/null
: > "$FAKE_STATE/vmssh.log"
G build App.csproj > "$T/out" 2>&1 && grep -q "host build of 'App.csproj' in $T" "$FAKE_STATE/host.log" \
  && [ ! -s "$FAKE_STATE/vmssh.log" ] && [ ! -e "$T/vmrun/app.running" ] && ok "builds on the Mac with the VM down" \
  || fail "host build: $(cat "$T/out")"
"$T/scripts/vm/vmctl.sh" up "$T/vmrun" > /dev/null
: > "$FAKE_STATE/host.log"; : > "$FAKE_STATE/vmssh.log"
G test Tests.csproj 'Name~X' > "$T/out" 2>&1 && grep -q "host build of 'Tests.csproj'" "$FAKE_STATE/host.log" \
  && grep -q '^\$Project = .Tests.csproj.; \$Filter = .Name~X.; \$NoBuild = \$true$' "$FAKE_STATE/vmssh.log" \
  && ok "test builds the project on the Mac, then the guest runs it with NoBuild" || fail "host test: $(cat "$T/out"; cat "$FAKE_STATE/vmssh.log")"
: > "$FAKE_STATE/host.log"
G test --no-build Tests.csproj > /dev/null 2>&1 && [ ! -s "$FAKE_STATE/host.log" ] && ok "test --no-build builds nothing" \
  || fail "test --no-build built on the Mac"
touch "$FAKE_STATE/host-red"; : > "$FAKE_STATE/vmssh.log"
G test Tests.csproj > "$T/out" 2>&1; rc=$?
[ $rc -eq 1 ] && grep -q CS0103 "$T/out" && [ ! -s "$FAKE_STATE/vmssh.log" ] && ok "a red Mac build fails the test, which never reaches the guest" \
  || fail "red host build before a test: rc $rc, $(cat "$T/out")"
rm "$FAKE_STATE/host-red"; touch "$FAKE_STATE/host-no-sdk"
G build > "$T/out" 2>&1; [ $? -eq 3 ] && grep -q 'HARNESS ERROR' "$T/out" && ok "no SDK on the Mac is a harness error" \
  || fail "no SDK: $(cat "$T/out")"
rm "$FAKE_STATE/host-no-sdk"
touch "$FAKE_STATE/host-declines"; : > "$FAKE_STATE/host.log"; : > "$FAKE_STATE/vmssh.log"
G on-host build; [ $? -ne 0 ] && ok "a worktree the host build declines is not on the Mac" || fail "on-host build when declined"
G build > "$T/out" 2>&1
grep -q 'building in the guest, not on the Mac: this commit predates the fix' "$T/out" && [ ! -s "$FAKE_STATE/host.log" ] \
  && grep -q '^# build' "$FAKE_STATE/vmssh.log" && ok "a declined worktree builds in the guest, and says why" \
  || fail "declined: $(cat "$T/out"; cat "$FAKE_STATE/host.log")"
G test Tests.csproj > /dev/null 2>&1
[ ! -s "$FAKE_STATE/host.log" ] && grep -q '\$NoBuild = \$false' "$FAKE_STATE/vmssh.log" && ok "and its tests build in the guest" \
  || fail "declined test: $(cat "$FAKE_STATE/vmssh.log")"
rm "$FAKE_STATE/host-declines"

echo "a target that only builds on the Mac, in a macOS guest (no guest build or test scripts, bash)"
sed -i '' -e "s|^GUEST_BUILD=.*|GUEST_BUILD=''|" -e "s|^GUEST_TEST=.*|GUEST_TEST=''|" "$T/vmrun/guest.conf"
echo "export VM_GUEST_SHELL=sh" >> "$T/vmrun/vm.env"
G build > "$T/out" 2>&1; [ $? -eq 0 ] && ok "it builds on the Mac" || fail "Mac-only build: $(cat "$T/out")"
touch "$FAKE_STATE/host-declines"
G build > "$T/out" 2>&1; [ $? -eq 3 ] && grep -q "builds on the Mac only, and this Mac can't: this commit predates the fix" "$T/out" \
  && ok "a Mac that can't build it is a harness error, and says why" || fail "Mac-only declined: $(cat "$T/out")"
rm "$FAKE_STATE/host-declines"
G test Tests.csproj > "$T/out" 2>&1; [ $? -eq 3 ] && grep -q 'runs no tests in the guest' "$T/out" \
  && ok "test without a guest test script is a harness error" || fail "no test script: $(cat "$T/out")"
G app launch > /dev/null 2>&1; : > "$FAKE_STATE/vmssh.log"
G app stop > /dev/null 2>&1
grep -q 'pkill -f "^$R/"' "$FAKE_STATE/vmssh.log" && ! grep -q 'Stop-Process' "$FAKE_STATE/vmssh.log" \
  && ok "app stop ends what runs from the share with bash" || fail "app stop in a macOS guest: $(cat "$FAKE_STATE/vmssh.log")"

[ "$FAILS" -eq 0 ] && echo "guest.sh: all passed" || { echo "guest.sh: $FAILS failed"; exit 1; }
