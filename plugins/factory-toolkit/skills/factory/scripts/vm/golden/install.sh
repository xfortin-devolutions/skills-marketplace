#!/bin/sh
# Unattended Windows 11 ARM64 install into base.qcow2 (QEMU + Apple Hypervisor).
#
#   install.sh          prepare what is missing, then boot the installer in a window
#   install.sh --clean  wipe base.qcow2 / firmware vars / seed and start over
#
# Vendored from the rdm-windows-vm-test setup. Builds the golden image in FACTORY_VM_HOME (default ~/VMs/factory/windows);
# autounattend.xml and setup-guest.ps1 come from this script's folder.
# Needs: the Windows 11 ARM64 ISO (English, United States) in FACTORY_VM_HOME, or WIN_ISO=/path/to.iso.
# On the very first boot, click into the window and press a key at "Press any key to boot from CD or DVD".
# Later reboots skip that prompt on purpose and fall through to the disk. Ctrl+Opt+G releases the mouse.
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
VM_DIR="${FACTORY_VM_HOME:-$HOME/VMs/factory/windows}"
mkdir -p "$VM_DIR"
cd "$VM_DIR"

QEMU_SHARE="$(brew --prefix qemu)/share/qemu"
VIRTIO_ISO=virtio-win.iso
VIRTIO_URL=https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso

if [ "${1:-}" = "--clean" ]; then
    rm -f base.qcow2 vars.base.fd seed.iso qmp.sock
    rm -rf seed
fi

WIN_ISO="${WIN_ISO:-$(ls -1 Win11_*rm64*.iso 2>/dev/null | head -n 1 || true)}"
if [ -z "$WIN_ISO" ] || [ ! -f "$WIN_ISO" ]; then
    echo "No Windows ISO: put Win11_*_Arm64*.iso in $VM_DIR or set WIN_ISO=/path/to.iso" >&2
    exit 1
fi

if [ -f base.qcow2 ] && [ ! -w base.qcow2 ]; then
    echo "base.qcow2 is read-only (finished image). Use --clean to reinstall." >&2
    exit 1
fi

[ -f "$VIRTIO_ISO" ] || curl -fL --progress-bar -o "$VIRTIO_ISO" "$VIRTIO_URL"

# Dedicated key and password for the guest's rdmtest account; never the user's own key
[ -f id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C factory-vm -f id_ed25519
if [ ! -f password.txt ]; then
    (umask 077; LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 > password.txt)
fi

# Seed ISO: answer file with the password filled in, the SSH public key, optional extra setup script
rm -rf seed seed.iso
mkdir seed
sed "s/__PASSWORD__/$(cat password.txt)/g" "$SRC/autounattend.xml" > seed/autounattend.xml
cp id_ed25519.pub seed/
cp "$SRC/setup-guest.ps1" seed/
# Artifactory credentials for the guest's restore: local file, never committed (see references/vm-setup.md)
[ -f NuGet.Config ] && cp NuGet.Config seed/
hdiutil makehybrid -quiet -iso -joliet -default-volume-name SEED -o seed.iso seed

[ -f base.qcow2 ] || qemu-img create -q -f qcow2 base.qcow2 200G
[ -f vars.base.fd ] || cp "$QEMU_SHARE/edk2-arm-vars.fd" vars.base.fd

echo "Installing from $WIN_ISO; guest SSH will be on 127.0.0.1:2222 (user rdmtest, key ./id_ed25519)"

exec qemu-system-aarch64 \
    -name factory-golden-install \
    -machine virt -accel hvf -cpu host -smp 16 -m 32G \
    -rtc base=localtime \
    -drive if=pflash,format=raw,readonly=on,file="$QEMU_SHARE/edk2-aarch64-code.fd" \
    -drive if=pflash,format=raw,file=vars.base.fd \
    -drive if=none,id=disk0,file=base.qcow2,format=qcow2,discard=unmap \
    -device nvme,drive=disk0,serial=rdmwin0,bootindex=1 \
    -device qemu-xhci \
    -drive if=none,id=win,file="$WIN_ISO",media=cdrom,readonly=on \
    -device usb-storage,drive=win,bootindex=0 \
    -drive if=none,id=virtio,file="$VIRTIO_ISO",media=cdrom,readonly=on \
    -device usb-storage,drive=virtio \
    -drive if=none,id=seed,file=seed.iso,media=cdrom,readonly=on \
    -device usb-storage,drive=seed \
    -device usb-kbd \
    -device usb-tablet \
    -device ramfb \
    -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22 \
    -qmp unix:"$VM_DIR/qmp.sock",server=on,wait=off \
    -display cocoa
