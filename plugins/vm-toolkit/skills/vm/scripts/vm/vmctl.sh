#!/bin/bash
# vmctl.sh: throwaway VMs cloned from the golden image (or a layer on it) as copy-on-write overlays, one per run dir.
#   vmctl.sh up <run dir> <worktree>   boot headless with <worktree> shared as R:, return when the guest's SSH answers
#   vmctl.sh env <run dir>             export lines for vm.py / vmssh:  eval "$(vmctl.sh env <run dir>)"
#   vmctl.sh alive <run dir>           exit 0 when the VM is running (env still answers after a down: it reads a file)
#   vmctl.sh show <run dir>            open the VM's screen in TigerVNC with a shared clipboard (clipboard.sh), else in
#                                      macOS Screen Sharing (VM_VIEWER=screensharing forces it); VNC on localhost, password
#   vmctl.sh down <run dir> [--keep-disk]   power off, free the slot, delete the overlay unless kept
#   vmctl.sh freeze <run dir> <image>  shut the guest down cleanly and make its disk the read-only image <image> (a path
#                                      under VM_HOME, e.g. checkpoints/devex-610.qcow2) that later clones start from;
#                                      a macOS guest whose apps hold the shutdown up stays running (VM_FREEZE_FORCE=1
#                                      powers it off anyway)
#   vmctl.sh record-stop <run dir>     end the VM's recording (guest.sh app record start) and print the video's path
#   vmctl.sh list                      running VMs and their slots
#   vmctl.sh gc                        free the slots of dead VMs and delete their overlays
# The golden image (VM_HOME, or FACTORY_VM_HOME, default ~/VMs/factory/windows) is never written: base.qcow2 must be
# read-only.
# VM_IMAGE picks the image clones start from: base.qcow2, or a layer on it (golden/layer.sh) that has its own
# <layer>.vars.fd; every file in its backing chain must be read-only.
# Sizing and limits come from the environment (lib/config.sh exports them; a caller like the factory may set its own);
# VM_SHARE_CHECK, when set, is a file the shared worktree must contain (the target's sanity check); VM_TITLE names the
# VM's window.
# A guest OS folder holding a tart/ home (macOS: golden/macos-setup.sh) is driven by tart instead of QEMU: VM_IMAGE is
# then a tart VM there (base, the golden one), each VM an APFS clone of it (instant, copy-on-write) run by tart with
# Virtualization.framework, its screen and input on that framework's VNC server (vnc.py drives it), the worktree
# mounted at /Volumes/My Shared Files/wt, SSH on the VM's own address. Apple allows two macOS VMs at once on a Mac, and
# the kernel enforces it: VM_MAX is at most 2 there. A checkpoint of one (freeze) is its clone renamed ck-<name>, with
# a marker checkpoints/<name>.tart; VM_IMAGE=checkpoints/<name>.tart clones it instead of base. Its clipboard is shared
# with this Mac's only once a person shows it (tart_clipboard).
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
BACKEND=qemu
if [ -d "$VM_HOME/tart" ]; then
  BACKEND=tart
  [ "$VM_IMAGE" = base.qcow2 ] && VM_IMAGE=base
  [ "$VM_MAX" -gt 2 ] && VM_MAX=2
  # Smaller than a Windows VM: the Mac builds, and the guest only runs the app.
  VM_CPUS=${VM_MACOS_CPUS:-4}
  VM_MEM=${VM_MACOS_MEM:-8G}
  # tart prunes its caches when the disk runs low, after a clone: never behind a run's back.
  export TART_HOME=$VM_HOME/tart TART_NO_AUTO_PRUNE=1
fi

die() { echo "vmctl: $*" >&2; exit 1; }
alive() { [ -f "$1/qemu.pid" ] && kill -0 "$(cat "$1/qemu.pid")" 2> /dev/null; }
# tart_name <slot>: the tart VM a slot runs (one at a time: the slot is the lock)
tart_name() { echo "vmt-slot-$1"; }
# tart_image <VM_IMAGE>: the tart VM clones start from: base, or a checkpoint's (checkpoints/<name>.tart: ck-<name>)
tart_image() { case "$1" in checkpoints/*.tart) n=${1#checkpoints/}; echo "ck-${n%.tart}" ;; *) echo "$1" ;; esac; }
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
  [ "$BACKEND" = tart ] && { tart_up "$run" "$wt"; return; }
  command -v qemu-system-aarch64 > /dev/null || die "QEMU missing: brew install qemu"
  smbd="$(brew --prefix 2> /dev/null)/sbin/samba-dot-org-smbd"
  [ -x "$smbd" ] || die "the worktree share needs Samba: brew install samba"
  for f in "$VM_IMAGE" "$(image_vars)" id_ed25519; do
    [ -f "$VM_HOME/$f" ] || case "$f" in
      checkpoints/*) die "no $VM_HOME/$f: its checkpoint was deleted (vmt checkpoint list)" ;;
      *) die "no $VM_HOME/$f: build the golden image first (references/vm-setup.md)" ;;
    esac
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

  n=$(take_slot "$d") || exit 1
  port=$((2230 + n))
  vnc=$((20 + n))
  pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8)

  # Samba's runtime dirs hold Unix sockets, and macOS caps a socket path at 104 characters: under a long run dir, every
  # smbd after the first exits with "messaging_dgm_ref failed: File name too long" and the guest's share stalls.
  rt=$(smb_runtime "$n")
  rm -rf "$rt"
  mkdir -p "$d/smb" "$rt/private" "$rt/lock" "$rt/state" "$rt/cache" "$rt/ncalrpc"
  rm -f "$d/disk.qcow2" "$d/known_hosts" "$d/.screen-size" "$d/clipboard.ok"
  # A checkpoint taken after the clipboard agent went in has it already (freeze).
  [ -f "$VM_HOME/${VM_IMAGE%.qcow2}.clipboard-agent" ] && touch "$d/clipboard.ok"
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
  rm -f "$d/qemu.pid" "$d/qmp.sock" "$d/rec.sock"
  # base=localtime: Windows reads the hardware clock as local time; a UTC one puts the guest hours ahead, and MSBuild then
  # takes files edited on the host for older than its outputs on the share and skips rebuilding them (GAPS V38).
  # Plain background process rather than -daemonize: forking after Hypervisor.framework setup is unsafe on macOS.
  # The vdagent port carries the clipboard between the guest's SPICE agent and VNC clients that speak the extended
  # clipboard (TigerVNC; not Screen Sharing). mouse=off: the usb-tablet stays the pointer vm.py drives.
  # rec.sock is record.py's own QMP socket: a QMP socket serves one client at a time, and a recorder holding qmp.sock
  # would hold back every click and keystroke until it stopped.
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
    -qmp unix:"$d/rec.sock",server=on,wait=off \
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
  # vmssh sets the guest's clock: an image frozen before a DST change boots an hour off (GAPS V102)
  ( . "$d/vm.env"; VM_NO_SHARE=1 "$X/vmssh" '' ) > /dev/null 2>&1 || echo "vmctl: could not set the guest's clock" >&2
}

# take_slot <vm dir>: a free slot's number, marked starting. A busy machine is a queue, not an error: wait for a slot
# (another run's VM going down) up to VM_SLOT_WAIT_MIN.
take_slot() {
  local n waited=0
  while :; do
    n=1
    while [ "$n" -le "$VM_MAX" ] && ! mkdir "$SLOTS/$n" 2> /dev/null; do n=$((n + 1)); done
    [ "$n" -le "$VM_MAX" ] && break
    [ "$waited" -ge $((VM_SLOT_WAIT_MIN * 60)) ] && die "all $VM_MAX VM slots stayed busy for $VM_SLOT_WAIT_MIN min (vmctl.sh list; vmctl.sh gc frees dead ones)"
    [ "$waited" = 0 ] && echo "vmctl: all $VM_MAX VM slots are busy: waiting up to $VM_SLOT_WAIT_MIN min for one" >&2
    sleep 10; waited=$((waited + 10))
    gc > /dev/null
  done
  echo "$1" > "$SLOTS/$n/vm"
  # Until the VM runs, the slot looks dead: the marker keeps a parallel up's gc from deleting this VM's files mid-start.
  touch "$SLOTS/$n/starting"
  echo "$n"
}

# tart_up <run dir> <worktree>: up, for a macOS guest (see the header)
tart_up() {
  local run=$1 wt=$2 d n name share i url pw vport ip mem src
  command -v tart > /dev/null || die "tart missing: brew install openai/tools/tart"
  src=$(tart_image "$VM_IMAGE")
  if [ ! -d "$TART_HOME/vms/$src" ]; then
    case "$VM_IMAGE" in
      checkpoints/*) die "no tart VM $src: its checkpoint was deleted (vmt checkpoint list)" ;;
      *) die "no tart VM $src in $TART_HOME: build the golden image first (references/vm-setup-macos.md)" ;;
    esac
  fi
  [ -f "$VM_HOME/id_ed25519" ] || die "no $VM_HOME/id_ed25519: build the golden image first (references/vm-setup-macos.md)"
  [ -z "${VM_SHARE_CHECK:-}" ] || [ -e "$wt/$VM_SHARE_CHECK" ] || die "$wt has no $VM_SHARE_CHECK"
  mkdir -p "$run" "$SLOTS"
  gc > /dev/null
  d=$(vmdir "$run")
  alive "$d" && die "a VM is already running for $run"
  share=$(cd "$wt" && pwd)
  mkdir -p "$d"
  n=$(take_slot "$d") || exit 1
  name=$(tart_name "$n")
  rm -f "$d/known_hosts" "$d/.screen-size" "$d/qemu.pid"
  tart delete "$name" > /dev/null 2>&1
  case "$VM_MEM" in *G) mem=$((${VM_MEM%G} * 1024)) ;; *M) mem=${VM_MEM%M} ;; *) mem=$VM_MEM ;; esac
  # px: at 72 ppi, one guest point is one screenshot pixel, as in the Windows VMs.
  { tart clone "$src" "$name" && tart set "$name" --cpu "$VM_CPUS" --memory "$mem" --display "${VM_XRES}x${VM_YRES}px"; } \
    > "$d/tart.log" 2>&1 || { release_slot "$n" "$d"; die "tart clone failed: $(tail -2 "$d/tart.log")"; }
  # tart is the VM's process: its pid is the VM's (alive, down), as QEMU's is.
  nohup tart run --no-graphics --vnc-experimental --dir="wt:$share" "$name" >> "$d/tart.log" 2>&1 < /dev/null &
  echo $! > "$d/qemu.pid"
  url=""
  for i in $(seq 1 120); do
    url=$(sed -n 's|.*VNC server is running at \(vnc://[^ ]*\).*|\1|p' "$d/tart.log" | tail -1)
    [ -n "$url" ] && break
    alive "$d" || break
    sleep 0.5
  done
  [ -n "$url" ] || { tart delete "$name" > /dev/null 2>&1; release_slot "$n" "$d"; die "tart did not start: $(tail -3 "$d/tart.log")"; }
  rm -f "$SLOTS/$n/starting"
  pw=$(echo "$url" | sed -n 's|vnc://:\([^@]*\)@.*|\1|p') vport=${url##*:}
  (umask 077; echo "$pw" > "$d/vnc.pass")
  ip=$(tart ip --wait $((VM_BOOT_MIN * 60)) "$name" 2> /dev/null) || die "the guest got no address in $VM_BOOT_MIN min (VNC: vmctl.sh show $run)"
  cat > "$d/vm.env" <<EOF
export VM_RUN_DIR='$d' VM_SSH_HOST=$ip VM_SSH_PORT=22 VM_USER=admin VM_KNOWN_HOSTS='$d/known_hosts' VM_GUEST_SHELL=sh
export VM_SHARE_TAG=wt VM_VNC_PORT=$vport VM_VNC_PASS_FILE='$d/vnc.pass' VM_SLOT=$n VM_SHARE='$share' VM_HOME='$VM_HOME'
export FACTORY_VM_HOME='$VM_HOME' VM_TART_NAME=$name
EOF
  echo "slot $n: SSH admin@$ip, VNC 127.0.0.1:$vport, sharing $share at /Volumes/My Shared Files/wt"
  VM_SSH_HOST=$ip VM_SSH_PORT=22 python3 "$X/vm.py" wait-ssh $((VM_BOOT_MIN * 60)) || die "guest SSH did not answer in $VM_BOOT_MIN min (VNC: vmctl.sh show $run)"
  # SSH answers while the screen still shows the boot progress: up returns once admin's desktop runs (Dock, Finder), so
  # a launch or a screenshot right after it finds the desktop.
  # shellcheck disable=SC2016
  ( . "$d/vm.env"; "$X/vmssh" 'for i in $(seq 1 '$((VM_BOOT_MIN * 30))'); do pgrep -x Dock > /dev/null && pgrep -x Finder > /dev/null && sleep 3 && exit 0; sleep 2; done; exit 1' ) > /dev/null 2>&1 \
    || die "the guest's desktop did not start in $VM_BOOT_MIN min (VNC: vmctl.sh show $run)"
  echo "desktop up"
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
  record_end "$d"
  if [ "$BACKEND" = tart ]; then
    s=$(slot_of "$d")
    if alive "$d"; then
      pid=$(cat "$d/qemu.pid")
      # A disposable guest needs no clean shutdown.
      kill "$pid" 2> /dev/null
      for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2> /dev/null || break; sleep 1; done
      kill -9 "$pid" 2> /dev/null
    fi
    if [ -n "$s" ]; then
      if [ "$keep" = yes ]; then tart rename "$(tart_name "$s")" "vmt-kept-$(basename "$(dirname "$d")")" > /dev/null 2>&1
      else tart delete "$(tart_name "$s")" > /dev/null 2>&1; fi
      rmdir_slot "$s"
    fi
    rm -f "$d/qemu.pid"
    echo "vm down: $d (disk $([ "$keep" = yes ] && echo "kept: tart VM vmt-kept-$(basename "$(dirname "$d")")" || echo deleted))"
    return
  fi
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
  rm -f "$d/qemu.pid" "$d/qmp.sock" "$d/rec.sock"
  if [ "$keep" = no ]; then rm -f "$d/disk.qcow2" "$d/vars.fd"; fi
  echo "vm down: $d (disk $([ "$keep" = yes ] && echo kept || echo deleted))"
}

# freeze <run dir> <image>: the VM's state (sign-ins, installed tools, data: everything on its disk, not the shared
# worktree) as an image clones can start from. The guest shuts down cleanly first, so apps write their settings and
# Windows flushes its disk; then the overlay and its firmware variables move to <image> and <image>.vars.fd, read-only:
# clones cut from it would be corrupted by a change to it, like those of base.qcow2. The slot is freed; the run dir
# keeps no disk (vmt checkpoint points the VM folder at the image).
# record_stop <run dir>: end its recording; record.py then lays the captions and clicks over the video (seconds for a
# few minutes of it). A recording that ended on its own (its time limit, the VM going down) is reported the same way,
# once. Prints the video's path, or why there is none.
record_stop() {
  local d=$1
  record_end "$d"
  [ -f "$d/record.log" ] || { echo "nothing is recording"; return 1; }
  tail -3 "$d/record.log"
  mv "$d/record.log" "$d/record.last.log"
  grep -q '\.mp4 [0-9]*s, ' "$d/record.last.log"
}

# record_end <run dir>: end its recording, if one runs, and wait for its video (down and freeze, before QEMU goes)
record_end() {
  local pid i=0
  pid=$(cat "$1/record.pid" 2> /dev/null) && kill -0 "$pid" 2> /dev/null && kill -TERM "$pid"
  while [ -n "$pid" ] && kill -0 "$pid" 2> /dev/null && [ "$i" -lt 600 ]; do sleep 1; i=$((i + 1)); done
  rm -f "$1/record.pid"
}

freeze() {
  local d img n pid i
  d=$(vmdir "${1:-}"); img=${2:-}
  [ -n "$img" ] || die "usage: vmctl.sh freeze <run dir> <image>"
  alive "$d" || die "no VM running for ${1:-}"
  [ "$BACKEND" = tart ] && { tart_freeze "$d" "$img"; return; }
  [ -e "$VM_HOME/$img" ] && die "$VM_HOME/$img already exists"
  n=$(slot_of "$d"); pid=$(cat "$d/qemu.pid")
  # Once QEMU exits the slot looks dead, and any up's gc would delete the disk before it moves: mark it starting.
  [ -n "$n" ] && touch "$SLOTS/$n/starting"
  record_end "$d"
  . "$d/vm.env"
  # TRIM first: the guest's freed blocks leave the overlay (discard=unmap), so the image keeps only what it uses.
  VM_NO_SHARE=1 "$X/vmssh" 'Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue; shutdown /s /t 0' > /dev/null 2>&1
  i=0
  while kill -0 "$pid" 2> /dev/null && [ "$i" -lt 300 ]; do sleep 1; i=$((i + 1)); done
  if kill -0 "$pid" 2> /dev/null; then
    [ -n "$n" ] && rm -f "$SLOTS/$n/starting"
    die "the guest did not power off in 5 min; the VM still runs (vmctl.sh show $(dirname "$d"))"
  fi
  mkdir -p "$(dirname "$VM_HOME/$img")"
  mv "$d/disk.qcow2" "$VM_HOME/$img" && mv "$d/vars.fd" "$VM_HOME/${img%.qcow2}.vars.fd" \
    || die "could not move the disk to $VM_HOME/$img; it is still in $d"
  [ -f "$d/clipboard.ok" ] && : > "$VM_HOME/${img%.qcow2}.clipboard-agent"
  chmod a-w "$VM_HOME/$img" "$VM_HOME/${img%.qcow2}.vars.fd"
  pkill -f "$d/smb/smb.conf" 2> /dev/null
  [ -n "$n" ] && rmdir_slot "$n"
  rm -f "$d/qemu.pid" "$d/qmp.sock" "$d/rec.sock" "$d/clipboard.ok"
  echo "frozen after ${i}s: $VM_HOME/$img ($(qemu-img info "$VM_HOME/$img" | sed -n 's/^disk size: //p'))"
}

# tart_freeze <vm dir> <image>: freeze, for a macOS guest. The clone is already an independent copy (APFS): once the
# guest has shut down cleanly, it is renamed after the checkpoint and kept, with a marker file at <image>.
# Cleanly: loginwindow's shut down event (aevtshut: no confirmation dialog, unlike aevtrsdn; it needs no permission from
# SSH), so apps quit and save; `shutdown -h now` would kill them, and the app reports a crash on its next start. An app
# can hold it up (RDM asks "Do you want to quit?"): then the VM stays up, with a screenshot of what asks, for an agent
# or a person to answer before trying again. VM_FREEZE_FORCE=1 shuts down at once, apps or not.
tart_freeze() {
  local d=$1 img=$2 n pid i ck
  case "$img" in checkpoints/*.tart) ;; *) die "a macOS checkpoint is checkpoints/<name>.tart, not $img" ;; esac
  ck=$(tart_image "$img")
  [ -e "$VM_HOME/$img" ] || [ -d "$TART_HOME/vms/$ck" ] && die "$VM_HOME/$img already exists"
  n=$(slot_of "$d"); pid=$(cat "$d/qemu.pid")
  [ -n "$n" ] || die "no slot holds $d"
  # Once tart exits the slot looks dead, and any up's gc would delete the clone before it is renamed: mark it starting.
  touch "$SLOTS/$n/starting"
  record_end "$d"
  local wait=${VM_FREEZE_WAIT_S:-120} shot
  if [ -n "${VM_FREEZE_FORCE:-}" ]; then
    ( . "$d/vm.env"; "$X/vmssh" 'sudo shutdown -h now' ) > /dev/null 2>&1
    wait=300
  else
    # shellcheck disable=SC2016
    ( . "$d/vm.env"; "$X/vmssh" 'osascript -e "tell application \"loginwindow\" to «event aevtshut»"' ) > /dev/null 2>&1
  fi
  i=0
  while kill -0 "$pid" 2> /dev/null && [ "$i" -lt "$wait" ]; do sleep 1; i=$((i + 1)); done
  if kill -0 "$pid" 2> /dev/null; then
    rm -f "$SLOTS/$n/starting"
    [ -n "${VM_FREEZE_FORCE:-}" ] && die "the guest did not power off in 5 min; the VM still runs (vmctl.sh show $(dirname "$d"))"
    shot=$(dirname "$d")/app/freeze-blocked.png
    mkdir -p "$(dirname "$shot")"
    ( . "$d/vm.env"; python3 "$X/vm.py" shot "$shot" ) > /dev/null 2>&1 || shot="(no screenshot)"
    die "the guest did not shut down in ${wait}s: an app is holding it up, usually asking something before it quits (see $shot). Answer it (app shot, app click, or vmt show) and take the checkpoint again; or --force, which powers off without letting apps quit (they may report a crash on their next start). The VM still runs"
  fi
  tart rename "$(tart_name "$n")" "$ck" || die "could not rename $(tart_name "$n") to $ck; it is still there"
  mkdir -p "$(dirname "$VM_HOME/$img")"
  echo "$ck" > "$VM_HOME/$img"
  chmod a-w "$VM_HOME/$img"
  rmdir_slot "$n"
  rm -f "$d/qemu.pid"
  echo "frozen after ${i}s: $VM_HOME/$img (tart VM $ck)"
}

# tart_clipboard <vm dir>: share a macOS VM's clipboard with this Mac's, until the VM goes down. tart gives every VM the
# SPICE agent port (Virtualization.framework syncs it with this Mac's pasteboard, both ways, whatever the viewer); the
# golden image carries Cirrus's guest agent for it (golden/macos-setup.sh) but never starts it on its own: a VM only an
# agent drives must not read what the person copies on the Mac. show starts it in the desktop session, not persistently,
# so a checkpoint doesn't carry it either.
tart_clipboard() {
  local out
  out=$( . "$1/vm.env"; "$X/vmssh" 'p=/Library/vmt/tart-guest-agent.plist; [ -f "$p" ] || { echo NO-AGENT; exit; }
    u=$(id -u admin); launchctl print "gui/$u/org.cirruslabs.tart-guest-agent" > /dev/null 2>&1 && { echo RUNNING; exit; }
    sudo launchctl bootstrap "gui/$u" "$p" && echo STARTED' 2>&1 )
  case "$out" in
    *RUNNING*|*STARTED*) echo "the clipboard is shared with this Mac's (both ways) while this VM runs" ;;
    *NO-AGENT*) echo "vmctl: no shared clipboard: this macOS image predates its guest agent (golden/macos-setup.sh --update)" >&2; return 1 ;;
    *) echo "vmctl: no shared clipboard: the guest agent did not start (${out##*$'\n'})" >&2; return 1 ;;
  esac
}

show() {
  local d
  d=$(vmdir "${1:-}")
  alive "$d" || die "no VM running for ${1:-}"
  . "$d/vm.env"
  # The guest's clock stops while the Mac sleeps: a person back at a VM left up overnight gets it on time (GAPS V102).
  [ "$BACKEND" = tart ] || VM_NO_SHARE=1 "$X/vmssh" '' > /dev/null 2>&1 || echo "vmctl: could not set the guest's clock" >&2
  # A macOS VM's clipboard goes through Virtualization.framework, not the viewer: Screen Sharing gets it too.
  [ "$BACKEND" = tart ] && tart_clipboard "$d"
  # TigerVNC shares the clipboard with the guest (clipboard.sh); Screen Sharing can't: it has no extended clipboard.
  if [ "${VM_VIEWER:-}" != screensharing ] && [ -d "$TIGERVNC" ]; then
    [ "$BACKEND" = tart ] || "$X/clipboard.sh" "$d" || echo "vmctl: opening the VM without a shared clipboard" >&2
    # TigerVNC's password file is the password DES-encrypted under VNC's fixed key (bits reversed, as VNC reads keys):
    # one 8-byte block, as VNC uses only the first 8 characters (QEMU's are 8; tart's are longer), padded with NULs.
    (umask 077; printf '%s' "$(cat "$d/vnc.pass")" | head -c 8 | dd bs=8 count=1 conv=sync 2> /dev/null \
      | /usr/bin/openssl enc -des-ecb -nopad -K e84ad660c4721ae0 > "$d/vnc.tigervnc")
    echo "TigerVNC: 127.0.0.1::$VM_VNC_PORT (password in $d/vnc.pass)$([ "$BACKEND" = qemu ] && echo "; the clipboard is shared both ways")"
    open -n -a "$TIGERVNC" --args PasswordFile="$d/vnc.tigervnc" "127.0.0.1::$VM_VNC_PORT"
    return
  fi
  echo "Screen Sharing: vnc://127.0.0.1:$VM_VNC_PORT (password in $d/vnc.pass)"
  [ "${VM_VIEWER:-}" = screensharing ] \
    || [ "$BACKEND" = tart ] || echo "vmctl: no shared clipboard in Screen Sharing; for one: brew install --cask tigervnc-viewer" >&2
  open "vnc://:$(cat "$d/vnc.pass")@127.0.0.1:$VM_VNC_PORT"
}

list() {
  local s d
  for s in "$SLOTS"/*; do
    [ -f "$s/vm" ] || continue
    d=$(cat "$s/vm")
    if alive "$d"; then
      . "$d/vm.env"
      echo "slot $(basename "$s"): running  ssh ${VM_SSH_HOST:+$VM_SSH_HOST:}$VM_SSH_PORT  vnc $VM_VNC_PORT  share $VM_SHARE  ($d)"
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
  freeze) freeze "$@" ;;
  record-stop) record_stop "$(vmdir "${1:-}")" ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
