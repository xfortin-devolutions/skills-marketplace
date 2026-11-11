#!/bin/bash
# vmctl.sh: throwaway VMs cloned from the golden image (or a layer on it) as copy-on-write overlays, one per run dir.
#   vmctl.sh up <run dir> <worktree>   boot headless with <worktree> shared as R:, return when the guest's SSH answers
#   vmctl.sh env <run dir>             export lines for vm.py / vmssh:  eval "$(vmctl.sh env <run dir>)"
#   vmctl.sh alive <run dir>           exit 0 when the VM is running (env still answers after a down: it reads a file)
#   vmctl.sh show <run dir>            open the VM's screen in TigerVNC with a shared clipboard (clipboard.sh), else in
#                                      macOS Screen Sharing (VM_VIEWER=screensharing forces it); VNC on localhost, password
#   vmctl.sh down <run dir> [--keep-disk]   power off, free the slot, delete the overlay unless kept
#   vmctl.sh list                      running VMs and their slots
#   vmctl.sh gc                        free the slots of dead VMs and delete their overlays
# The golden image (VM_HOME, or FACTORY_VM_HOME, default ~/VMs/factory/windows) is never written: base.qcow2 must be
# read-only.
# VM_IMAGE picks the image clones start from: base.qcow2, or a layer on it (golden/layer.sh) that has its own
# <layer>.vars.fd; every file in its backing chain must be read-only.
# Sizing and limits come from the environment (lib/config.sh exports them; a caller like the factory may set its own);
# VM_SHARE_CHECK, when set, is a file the shared worktree must contain (the target's sanity check); VM_TITLE names the
# VM's window.
# bash 3.2 compatible.
set -u

X=$(cd "$(dirname "$0")" && pwd)
VM_HOME=${VM_HOME:-${FACTORY_VM_HOME:-$HOME/VMs/factory/windows}}
VM_IMAGE=${VM_IMAGE:-base.qcow2}
SLOTS=$VM_HOME/slots
VM_MAX=${VM_MAX:-2}
VM_CPUS=${VM_CPUS:-8}
VM_MEM=${VM_MEM:-16G}
# virtio-gpu takes any size (ramfb tops out at 1024x768); the golden image carries its viogpudo driver
VM_XRES=${VM_XRES:-1600}
VM_YRES=${VM_YRES:-900}
VM_BOOT_MIN=${VM_BOOT_MIN:-10}
VM_SLOT_WAIT_MIN=${VM_SLOT_WAIT_MIN:-120}
TIGERVNC=${TIGERVNC:-/Applications/TigerVNC.app}

die() { echo "vmctl: $*" >&2; exit 1; }
alive() { [ -f "$1/qemu.pid" ] && kill -0 "$(cat "$1/qemu.pid")" 2> /dev/null; }
# A layer boots with its own firmware variables: its maintenance boots must not change the base's.
image_vars() { [ "$VM_IMAGE" = base.qcow2 ] && echo vars.base.fd || echo "${VM_IMAGE%.qcow2}.vars.fd"; }
# vm_title <run dir>: the VM's name, which Screen Sharing shows as its window title. The caller says what the VM is for
# (VM_TITLE, e.g. "DEVEX-514 QA round 5 - devex-514-20261104T182338Z"); without it, the run dir's last two folders.
# No commas: QEMU's -name would read one as an option separator.
vm_title() {
  echo "${VM_TITLE:-$(basename "$(dirname "$1")")/$(basename "$1")}" | tr -d ,
}
vmdir() { [ -n "${1:-}" ] || die "missing <run dir>"; echo "$(cd "$1" 2> /dev/null && pwd || echo "$1")/vm"; }

up() {
  local run=${1:-} wt=${2:-} d n port vnc pw smbd share rt
  [ -n "$run" ] && [ -n "$wt" ] || die "usage: vmctl.sh up <run dir> <worktree>"
  command -v qemu-system-aarch64 > /dev/null || die "QEMU missing: brew install qemu"
  smbd="$(brew --prefix 2> /dev/null)/sbin/samba-dot-org-smbd"
  [ -x "$smbd" ] || die "the worktree share needs Samba: brew install samba"
  for f in "$VM_IMAGE" "$(image_vars)" id_ed25519; do
    [ -f "$VM_HOME/$f" ] || die "no $VM_HOME/$f: build the golden image first (references/vm-setup.md)"
  done
  # A writable image can be booted by mistake (golden/start.sh), which corrupts every overlay cut from it; a layer's
  # backing file the same way.
  local img
  for img in $(qemu-img info --backing-chain "$VM_HOME/$VM_IMAGE" | sed -n 's/^image: //p'); do
    [ -w "$img" ] && die "$img is writable: chmod a-w it once the image is final"
  done
  [ -z "${VM_SHARE_CHECK:-}" ] || [ -e "$wt/$VM_SHARE_CHECK" ] || die "$wt has no $VM_SHARE_CHECK"
  mkdir -p "$run" "$SLOTS"
  gc > /dev/null
  d=$(vmdir "$run")
  alive "$d" && die "a VM is already running for $run"
  share=$(cd "$wt" && pwd)

  # A busy machine is a queue, not an error: wait for a slot (another run's VM going down) up to VM_SLOT_WAIT_MIN.
  local waited=0
  while :; do
    n=1
    while [ "$n" -le "$VM_MAX" ] && ! mkdir "$SLOTS/$n" 2> /dev/null; do n=$((n + 1)); done
    [ "$n" -le "$VM_MAX" ] && break
    [ "$waited" -ge $((VM_SLOT_WAIT_MIN * 60)) ] && die "all $VM_MAX VM slots stayed busy for $VM_SLOT_WAIT_MIN min (vmctl.sh list; vmctl.sh gc frees dead ones)"
    [ "$waited" = 0 ] && echo "vmctl: all $VM_MAX VM slots are busy: waiting up to $VM_SLOT_WAIT_MIN min for one" >&2
    sleep 10; waited=$((waited + 10))
    gc > /dev/null
  done
  echo "$d" > "$SLOTS/$n/vm"
  # Until QEMU runs, the slot looks dead: the marker keeps a parallel up's gc from deleting this VM's files mid-start.
  touch "$SLOTS/$n/starting"
  port=$((2230 + n))
  vnc=$((20 + n))
  pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8)

  # Samba's runtime dirs hold Unix sockets, and macOS caps a socket path at 104 characters: under a long run dir, every
  # smbd after the first exits with "messaging_dgm_ref failed: File name too long" and the guest's share stalls.
  rt=$(smb_runtime "$n")
  rm -rf "$rt"
  mkdir -p "$d/smb" "$rt/private" "$rt/lock" "$rt/state" "$rt/cache" "$rt/ncalrpc"
  rm -f "$d/disk.qcow2" "$d/known_hosts" "$d/.screen-size" "$d/clipboard.ok"
  qemu-img create -q -f qcow2 -b "$VM_HOME/$VM_IMAGE" -F qcow2 "$d/disk.qcow2" || { release_slot "$n" "$d"; die "qemu-img failed"; }
  rm -f "$d/vars.fd"
  cp "$VM_HOME/$(image_vars)" "$d/vars.fd" && chmod u+w "$d/vars.fd"
  (umask 077; echo "$pw" > "$d/vnc.pass")
  cat > "$d/vm.env" <<EOF
export VM_RUN_DIR='$d' QMP_SOCK='$d/qmp.sock' VM_SSH_PORT=$port VM_KNOWN_HOSTS='$d/known_hosts'
export VM_VNC_PORT=$((5900 + vnc)) VM_SLOT=$n VM_SHARE='$share' VM_HOME='$VM_HOME' FACTORY_VM_HOME='$VM_HOME'
EOF

  # Same smbd settings as the original start.sh; see its comments (Samba 4.25 tmp-name mkdir, exe from the share).
  cat > "$d/smb/smb.conf" <<EOF
[global]
private dir = $rt/private
pid directory = $rt
lock directory = $rt/lock
state directory = $rt/state
cache directory = $rt/cache
ncalrpc dir = $rt/ncalrpc
log file = $d/smb/log.smbd
smb passwd file = $rt/private/smbpasswd
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
path = $share
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

  local qs i
  qs="$(brew --prefix qemu)/share/qemu"
  rm -f "$d/qemu.pid" "$d/qmp.sock"
  # base=localtime: Windows reads the hardware clock as local time; a UTC one puts the guest hours ahead, and MSBuild then
  # takes files edited on the host for older than its outputs on the share and skips rebuilding them (GAPS V38).
  # Plain background process rather than -daemonize: forking after Hypervisor.framework setup is unsafe on macOS.
  # The vdagent port carries the clipboard between the guest's SPICE agent and VNC clients that speak the extended
  # clipboard (TigerVNC; not Screen Sharing). mouse=off: the usb-tablet stays the pointer vm.py drives.
  nohup qemu-system-aarch64 \
    -name "$(vm_title "$(dirname "$d")")" \
    -machine virt -accel hvf -cpu host -smp "$VM_CPUS" -m "$VM_MEM" \
    -rtc base=localtime \
    -drive if=pflash,format=raw,readonly=on,file="$qs/edk2-aarch64-code.fd" \
    -drive if=pflash,format=raw,file="$d/vars.fd" \
    -drive if=none,id=disk0,file="$d/disk.qcow2",format=qcow2,discard=unmap \
    -device nvme,drive=disk0,serial=rdmwin0 \
    -device qemu-xhci -device usb-kbd -device usb-tablet -device "virtio-gpu-pci,xres=$VM_XRES,yres=$VM_YRES" \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$port-:22,guestfwd=tcp:10.0.2.4:445-cmd:$smbd -l $d/smb -s $d/smb/smb.conf" \
    -device virtio-serial-pci -chardev qemu-vdagent,id=vdagent,clipboard=on,mouse=off \
    -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
    -qmp unix:"$d/qmp.sock",server=on,wait=off \
    -display none -vnc "127.0.0.1:$vnc,password=on" \
    -pidfile "$d/qemu.pid" > "$d/qemu.log" 2>&1 < /dev/null &
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -S "$d/qmp.sock" ] && alive "$d" && break
    sleep 0.5
  done
  alive "$d" && [ -S "$d/qmp.sock" ] || { release_slot "$n" "$d"; die "QEMU did not start: $(tail -3 "$d/qemu.log")"; }
  rm -f "$SLOTS/$n/starting"

  QMP_SOCK="$d/qmp.sock" python3 "$X/vm.py" qmp change-vnc-password "{\"password\": \"$pw\"}" > /dev/null \
    || echo "vmctl: could not set the VNC password; show will not connect" >&2
  echo "slot $n: SSH 127.0.0.1:$port, VNC 127.0.0.1:$((5900 + vnc)), sharing $share as R:"
  VM_SSH_PORT=$port python3 "$X/vm.py" wait-ssh $((VM_BOOT_MIN * 60)) || die "guest SSH did not answer in $VM_BOOT_MIN min (VNC: vmctl.sh show $run)"
}

rmdir_slot() { rm -rf "${SLOTS:?}/$1" "$(smb_runtime "$1")"; }
# smb_runtime <slot>: a short per-slot folder for Samba's sockets (see up).
smb_runtime() { echo "/tmp/vmt-smb-$(id -u)-$1"; }
# release_slot <n> <vm dir>: free slot <n> only if it still records <vm dir> (another up may have taken it meanwhile).
release_slot() { [ "$(cat "$SLOTS/$1/vm" 2> /dev/null)" = "$2" ] && rmdir_slot "$1"; }

slot_of() { # slot_of <vm dir>: the slot number holding it, or nothing
  local s
  for s in "$SLOTS"/*; do
    [ -f "$s/vm" ] && [ "$(cat "$s/vm")" = "$1" ] && { basename "$s"; return; }
  done
}

down() {
  local d keep=no pid s
  d=$(vmdir "${1:-}")
  [ "${2:-}" = "--keep-disk" ] && keep=yes
  if alive "$d"; then
    pid=$(cat "$d/qemu.pid")
    # A disposable guest needs no clean shutdown: quit right away.
    QMP_SOCK="$d/qmp.sock" python3 "$X/vm.py" qmp quit > /dev/null 2>&1 || kill "$pid" 2> /dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2> /dev/null || break; sleep 1; done
    kill -9 "$pid" 2> /dev/null
  fi
  # Only once QEMU is gone: its own command line embeds the smbd command, so this pattern would match QEMU too.
  pkill -f "$d/smb/smb.conf" 2> /dev/null
  s=$(slot_of "$d")
  [ -n "$s" ] && rmdir_slot "$s"
  rm -f "$d/qemu.pid" "$d/qmp.sock"
  if [ "$keep" = no ]; then rm -f "$d/disk.qcow2" "$d/vars.fd"; fi
  echo "vm down: $d (disk $([ "$keep" = yes ] && echo kept || echo deleted))"
}

show() {
  local d
  d=$(vmdir "${1:-}")
  alive "$d" || die "no VM running for ${1:-}"
  . "$d/vm.env"
  # TigerVNC shares the clipboard with the guest (clipboard.sh); Screen Sharing can't: it has no extended clipboard.
  if [ "${VM_VIEWER:-}" != screensharing ] && [ -d "$TIGERVNC" ]; then
    "$X/clipboard.sh" "$d" || echo "vmctl: opening the VM without a shared clipboard" >&2
    # TigerVNC's password file is the password DES-encrypted under VNC's fixed key (bits reversed, as VNC reads keys).
    (umask 077; printf '%s' "$(cat "$d/vnc.pass")" | /usr/bin/openssl enc -des-ecb -nopad -K e84ad660c4721ae0 > "$d/vnc.tigervnc")
    echo "TigerVNC: 127.0.0.1::$VM_VNC_PORT (password in $d/vnc.pass); the clipboard is shared both ways"
    open -n -a "$TIGERVNC" --args PasswordFile="$d/vnc.tigervnc" "127.0.0.1::$VM_VNC_PORT"
    return
  fi
  echo "Screen Sharing: vnc://127.0.0.1:$VM_VNC_PORT (password in $d/vnc.pass)"
  [ "${VM_VIEWER:-}" = screensharing ] \
    || echo "vmctl: no shared clipboard in Screen Sharing; for one: brew install --cask tigervnc-viewer" >&2
  open "vnc://:$(cat "$d/vnc.pass")@127.0.0.1:$VM_VNC_PORT"
}

list() {
  local s d
  for s in "$SLOTS"/*; do
    [ -f "$s/vm" ] || continue
    d=$(cat "$s/vm")
    if alive "$d"; then
      . "$d/vm.env"
      echo "slot $(basename "$s"): running  ssh $VM_SSH_PORT  vnc $VM_VNC_PORT  share $VM_SHARE  ($d)"
    else
      echo "slot $(basename "$s"): dead  ($d)  -> vmctl.sh gc"
    fi
  done
}

gc() {
  local s d
  for s in "$SLOTS"/*; do
    [ -f "$s/vm" ] || continue
    d=$(cat "$s/vm")
    # A slot still starting is not dead, unless its marker is older than a start can take (a crashed up).
    [ -n "$(find "$s/starting" -mmin -5 2> /dev/null)" ] && continue
    alive "$d" || { down "$(dirname "$d")" > /dev/null; echo "freed slot $(basename "$s") ($d)"; }
  done
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
  up) up "$@" ;;
  env) cat "$(vmdir "${1:-}")/vm.env" ;;
  alive) alive "$(vmdir "${1:-}")" ;;
  show) show "$@" ;;
  down) down "$@" ;;
  list) list ;;
  gc) gc ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
