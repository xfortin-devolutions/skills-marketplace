#!/bin/bash
# Shrinks the golden image: cleans the guest up, trims, then rewrites base.qcow2 compressed (zstd) and read-only.
#
#   compact.sh               guest cleanup + trim + compressed rewrite (a few minutes to half an hour, mostly DISM)
#   compact.sh --no-guest    rewrite only (the guest was cleaned up by hand)
#   compact.sh --keep-old    keep the previous image as base.old.qcow2 instead of deleting it
#
# First run on the Windows image (2026-10-23): 42 GB to 18.3 GB, clones boot and build as fast as before.
# Clones read through the decompression; their own writes go to uncompressed overlays.
# Refuses while factory VMs run or while a layer is backed by base.qcow2: a layer stores block differences against the
# exact file under it, so rewriting that file would corrupt the layer.
# bash 3.2 compatible.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VM_HOME="${FACTORY_VM_HOME:-$HOME/VMs/factory/windows}"
GUEST=1 KEEP_OLD=0
for arg in "$@"; do
    case "$arg" in
        --no-guest) GUEST=0 ;;
        --keep-old) KEEP_OLD=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done
die() { echo "compact: $*" >&2; exit 1; }

cd "$VM_HOME"
[ -f base.qcow2 ] || die "no $VM_HOME/base.qcow2"
pgrep -f "qemu-system-aarch64.*$VM_HOME" >/dev/null && die "a VM is running on this image: stop it first (vmctl.sh list)"
for f in *.qcow2; do
    [ "$f" = base.qcow2 ] && continue
    if qemu-img info "$f" 2>/dev/null | grep -q '^backing file: .*base\.qcow2'; then
        die "$f is a layer on base.qcow2: merge it (qemu-img commit) or delete it first"
    fi
done
echo "before: $(qemu-img info base.qcow2 | sed -n 's/^disk size: //p')"

if [ "$GUEST" = 1 ]; then
    chmod u+w base.qcow2 vars.base.fd
    WT="$(git -C "$HERE" rev-parse --show-toplevel)"
    "$HERE/start.sh" "$WT" --headless > "$VM_HOME/compact.qemu.log" 2>&1 &
    QEMU=$!
    wait_ssh() {
        for _ in $(seq 1 60); do "$HERE/../vmssh" '"up"' 2>/dev/null | grep -q up && return 0; sleep 5; done
        die "the guest's SSH did not answer (see $VM_HOME/compact.qemu.log)"
    }
    wait_ssh
    "$HERE/../vmssh" - < "$HERE/compact-guest.ps1"
    # The page file and hibernation changes only free their space after a restart.
    "$HERE/../vmssh" 'Restart-Computer -Force' || true
    sleep 30
    wait_ssh
    "$HERE/../vmssh" 'Optimize-Volume -DriveLetter C -ReTrim -Verbose 4>&1 | ForEach-Object { "$_" } | Select-String "trimmed"'
    "$HERE/../vmssh" 'Stop-Computer -Force' || true
    wait "$QEMU" || true
    chmod a-w base.qcow2 vars.base.fd
fi

echo "rewriting compressed..."
qemu-img convert -O qcow2 -c -o compression_type=zstd base.qcow2 base.new.qcow2
qemu-img check -q base.new.qcow2 || { rm -f base.new.qcow2; die "the new image failed qemu-img check; base.qcow2 is unchanged"; }
if [ "$KEEP_OLD" = 1 ]; then
    mv -f base.qcow2 base.old.qcow2
else
    rm -f base.qcow2
fi
mv base.new.qcow2 base.qcow2
chmod a-w base.qcow2
echo "after: $(qemu-img info base.qcow2 | sed -n 's/^disk size: //p')"
echo "Check one clone before relying on it, e.g. run-loop.sh <KEY> --qa-only <ref> on a known commit."
