#!/bin/bash
# layer-build.sh: fills a profile's VM layer, or rehearses it on a throwaway clone, by running the profile's setup script
# in the guest's desktop session, elevated (some installers fail from SSH's session 0). Called by factory.sh layer.
#
#   layer-build.sh <layer dir> --test    throwaway clone of base.qcow2, left up for inspection (vmctl.sh down <run dir>)
#   layer-build.sh <layer dir> --build   creates <LAYER>.qcow2 on base.qcow2 (layer.sh), fills it, shuts down, freezes it
#
# <layer dir>/layer.conf (bash, sourced with VM_HOME and FACTORY_VM_HOME set) sets LAYER, the image name, and optionally LAYER_FILES
# (host files copied to the guest's C:\factory\layer\) and LAYER_DIRS ("<guest folder>=<host folder>" pairs, copied to
# C:\factory\layer\<guest folder>\). <layer dir>/setup.ps1 skips the steps already done, logs to
# C:\factory\layer\setup.log and ends it with "LAYER SETUP OK" or "LAYER SETUP FAILED: <why>" (references/profiles.md).
# Windows guests only. bash 3.2 compatible.
set -euo pipefail

VM="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "layer: $*" >&2; exit 1; }
[ $# -eq 2 ] || die "usage: layer-build.sh <layer dir> --test | --build"
DIR="$(cd "$1" && pwd)"
MODE=$2
# The clone needs a folder to share as R:; setup.ps1 doesn't use it. An installed plugin's layer dir is not in a git repo.
REPO="$(git -C "$DIR" rev-parse --show-toplevel 2> /dev/null || echo "$DIR")"
# layer.conf may read either name (older ones use FACTORY_VM_HOME).
export VM_HOME="${VM_HOME:-${FACTORY_VM_HOME:-$HOME/VMs/factory/windows}}"
export FACTORY_VM_HOME=$VM_HOME
VM_USER=${VM_USER:-rdmtest}
[ -f "$DIR/layer.conf" ] && [ -f "$DIR/setup.ps1" ] || die "$DIR needs layer.conf and setup.ps1"
LAYER="" LAYER_FILES="" LAYER_DIRS=""
. "$DIR/layer.conf"
[ -n "$LAYER" ] || die "layer.conf sets no LAYER"
for f in $LAYER_FILES; do [ -f "$f" ] || die "missing $f (layer.conf LAYER_FILES)"; done

case "$MODE" in
    --test)
        RUN="$VM_HOME/runs/layer-test-$LAYER/vm-1"
        mkdir -p "$RUN"
        # A test clone still up from a failed run is reused: setup.ps1 skips the steps already done.
        if [ -f "$RUN/vm/qemu.pid" ] && kill -0 "$(cat "$RUN/vm/qemu.pid")" 2> /dev/null; then
            echo "reusing the running test clone"
        else
            VM_IMAGE=base.qcow2 "$VM/vmctl.sh" up "$RUN" "$REPO"
        fi
        eval "$("$VM/vmctl.sh" env "$RUN")"
        ;;
    --build)
        "$VM/golden/layer.sh" "$LAYER"
        "$VM/golden/start.sh" "$REPO" --headless --image "$LAYER.qcow2" > "$VM_HOME/$LAYER.qemu.log" 2>&1 &
        QEMU=$!
        export VM_SSH_PORT=2222 VM_KNOWN_HOSTS="$VM_HOME/known_hosts"
        for _ in $(seq 1 60); do "$VM/vmssh" '"up"' 2> /dev/null | grep -q up && break; sleep 5; done
        ;;
    *) die "usage: layer-build.sh <layer dir> --test | --build" ;;
esac

SCP=(scp -q -i "$VM_HOME/id_ed25519" -P "$VM_SSH_PORT" -o UserKnownHostsFile="$VM_KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new
     -o BatchMode=yes -o LogLevel=ERROR)
"$VM/vmssh" 'New-Item -ItemType Directory -Force C:\factory\layer | Out-Null'
# shellcheck disable=SC2086 # LAYER_FILES is a list of paths without spaces
"${SCP[@]}" $LAYER_FILES "$DIR/setup.ps1" "$VM_USER@127.0.0.1:C:/factory/layer/"
echo "copied setup.ps1${LAYER_FILES:+ and $(for f in $LAYER_FILES; do basename "$f"; done | paste -sd ' ' -)}"
for pair in $LAYER_DIRS; do
    name=${pair%%=*} src=${pair#*=}
    [ -d "$src" ] || die "missing folder $src (layer.conf LAYER_DIRS)"
    # COPYFILE_DISABLE and the exclude: macOS tar adds ._ metadata files, and a "._." one can't be deleted on Windows.
    COPYFILE_DISABLE=1 tar --exclude='._*' -C "$src" -czf "$VM_HOME/layer-dir.tgz" .
    "${SCP[@]}" "$VM_HOME/layer-dir.tgz" "$VM_USER@127.0.0.1:C:/factory/layer/"
    rm -f "$VM_HOME/layer-dir.tgz"
    "$VM/vmssh" "New-Item -ItemType Directory -Force C:\\factory\\layer\\$name | Out-Null; tar -xzf C:\\factory\\layer\\layer-dir.tgz -C C:\\factory\\layer\\$name; Remove-Item C:\\factory\\layer\\layer-dir.tgz"
    echo "copied $src as $name"
done

{ printf '$User = %s\n' "'$VM_USER'"; cat <<'EOF'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\factory\layer\setup.ps1'
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName FactoryLayerSetup -Action $action -Principal $principal -Force | Out-Null
Remove-Item C:\factory\layer\setup.log -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName FactoryLayerSetup
EOF
} | "$VM/vmssh" -

seen=0 RESULT=""
while :; do
    sleep 20
    log="$("$VM/vmssh" 'Get-Content C:\factory\layer\setup.log -ErrorAction SilentlyContinue' 2> /dev/null || true)"
    n=$(printf '%s\n' "$log" | grep -c . || true)
    [ "$n" -gt "$seen" ] && printf '%s\n' "$log" | tail -n "+$((seen + 1))" && seen=$n
    printf '%s\n' "$log" | grep -q 'LAYER SETUP OK' && { RESULT=ok; break; }
    printf '%s\n' "$log" | grep -q 'LAYER SETUP FAILED' && { RESULT=failed; break; }
done
"$VM/vmssh" 'Unregister-ScheduledTask FactoryLayerSetup -Confirm:$false' || true

if [ "$MODE" = --test ]; then
    echo "test clone left up: vmctl.sh show $RUN to look, vmctl.sh down $RUN to delete it"
else
    # The setup's own files (installers, copied folders) stay out of the frozen layer; its log goes with the secrets.
    "$VM/vmssh" 'New-Item -ItemType Directory -Force C:\factory\secrets\install-logs | Out-Null; Move-Item C:\factory\layer\*.log C:\factory\secrets\install-logs -Force -ErrorAction SilentlyContinue; cmd.exe /c "rd /s /q \\?\C:\factory\layer"; Optimize-Volume -DriveLetter C -ReTrim' || true
    "$VM/vmssh" 'Stop-Computer -Force' || true
    wait "$QEMU" || true
    [ "$RESULT" = ok ] && "$VM/golden/layer.sh" "$LAYER" --freeze
fi
[ "$RESULT" = ok ]
