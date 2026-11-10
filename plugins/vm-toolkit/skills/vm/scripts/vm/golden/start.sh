#!/bin/sh
# Boots the golden image itself, WRITABLE, with a git worktree shared as \\10.0.2.4\qemu (R: in the guest).
# Maintenance only (warm the NuGet cache, update the SDK): factory runs use vmctl.sh, which never writes the image.
# Stop every factory VM first (vmctl.sh list), make base.qcow2 writable, and chmod a-w it again when done.
#
#   ./start.sh [worktree] [--headless] [--image <layer>.qcow2]
#
# --image boots a layer (golden/layer.sh) instead of base.qcow2: make only the layer writable, base.qcow2 stays read-only
# (QEMU opens a backing file read-only), and the layer uses its own <layer>.vars.fd.
#
# worktree defaults to the git worktree containing the current directory. To share another one, shut the VM
# down and start it again with that path.
# SSH: ssh -i ~/VMs/factory/windows/id_ed25519 -p 2222 -o UserKnownHostsFile=~/VMs/factory/windows/known_hosts rdmtest@127.0.0.1
set -eu

VM_DIR="${VM_HOME:-${FACTORY_VM_HOME:-$HOME/VMs/factory/windows}}"
DISPLAY_OPT=cocoa
WORKTREE=""
IMAGE=base.qcow2
NEXT=""

for arg in "$@"; do
    if [ "$NEXT" = image ]; then IMAGE="$arg"; NEXT=""; continue; fi
    case "$arg" in
        --headless) DISPLAY_OPT=none ;;
        --image) NEXT=image ;;
        -*) echo "Unknown option: $arg" >&2; exit 1 ;;
        *) WORKTREE="$arg" ;;
    esac
done

if [ -z "$WORKTREE" ]; then
    WORKTREE="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        echo "Not inside a git worktree: pass the worktree path" >&2
        exit 1
    }
fi
WORKTREE="$(cd "$WORKTREE" && pwd)"


SMBD="$(brew --prefix)/sbin/samba-dot-org-smbd"
if [ ! -x "$SMBD" ]; then
    echo "The worktree share needs Samba: brew install samba" >&2
    exit 1
fi

cd "$VM_DIR"
VARS=vars.base.fd
[ "$IMAGE" = base.qcow2 ] || VARS="${IMAGE%.qcow2}.vars.fd"
if [ ! -f "$IMAGE" ] || [ ! -f "$VARS" ]; then
    echo "No VM yet: run ./install.sh first" >&2
    exit 1
fi

# Own smbd config instead of QEMU's smb= one, which can't be tuned. Samba 4.25 creates folders under a mode-0
# temp name and renames them; that rename fails on macOS and leaves d--------- folders (obj/, bin/) behind.
SMB_DIR="$VM_DIR/smb"
mkdir -p "$SMB_DIR/private" "$SMB_DIR/lock" "$SMB_DIR/state" "$SMB_DIR/cache" "$SMB_DIR/ncalrpc"
cat > "$SMB_DIR/smb.conf" <<EOF
[global]
private dir = $SMB_DIR/private
pid directory = $SMB_DIR
lock directory = $SMB_DIR/lock
state directory = $SMB_DIR/state
cache directory = $SMB_DIR/cache
ncalrpc dir = $SMB_DIR/ncalrpc
log file = $SMB_DIR/log.smbd
smb passwd file = $SMB_DIR/private/smbpasswd
interfaces = 127.0.0.1
bind interfaces only = yes
security = user
map to guest = Bad User
load printers = no
printing = bsd
disable spoolss = yes
usershare max shares = 0
strict sync = no

[qemu]
path = $WORKTREE
read only = no
guest ok = yes
force user = $(id -un)
vfs mkdir use tmp name = no
acl allow execute always = yes
nt acl support = no
create mask = 0644
force create mode = 0644
directory mask = 0755
force directory mode = 0755
EOF

QEMU_SHARE="$(brew --prefix qemu)/share/qemu"
echo "$WORKTREE" > run.worktree
printf 'Sharing %s as %s (R: in the guest); SSH on 127.0.0.1:2222\n' "$WORKTREE" '\\10.0.2.4\qemu'

exec qemu-system-aarch64 \
    -name factory-golden \
    -machine virt -accel hvf -cpu host -smp 16 -m 32G \
    -rtc base=localtime \
    -drive if=pflash,format=raw,readonly=on,file="$QEMU_SHARE/edk2-aarch64-code.fd" \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive if=none,id=disk0,file="$IMAGE",format=qcow2,discard=unmap \
    -device nvme,drive=disk0,serial=rdmwin0 \
    -device qemu-xhci \
    -device usb-kbd \
    -device usb-tablet \
    -device "virtio-gpu-pci,xres=${VM_XRES:-1600},yres=${VM_YRES:-900}" \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22,guestfwd=tcp:10.0.2.4:445-cmd:$SMBD -l $SMB_DIR -s $SMB_DIR/smb.conf" \
    -qmp unix:"$VM_DIR/qmp.sock",server=on,wait=off \
    -display "$DISPLAY_OPT"
