#!/bin/bash
# clipboard.sh: puts the SPICE clipboard agent in a running VM, so a VNC viewer's clipboard reaches the guest's and back.
#   clipboard.sh <vm dir>      (vmctl.sh show calls it; the VM's vm.env must be sourced: VM_SSH_PORT, VM_HOME, ...)
# QEMU carries the clipboard between the agent (over the vdagent virtio-serial port vmctl.sh up adds) and VNC clients
# that speak the extended clipboard: TigerVNC does, macOS Screen Sharing doesn't. The agent goes in each VM when it is
# first shown rather than in the golden image: a changed base.qcow2 would no longer match the layers cut from it.
# The guest needs the ARM64 virtio-serial driver (from the virtio-win ISO the golden image was installed with) and the
# agent, which has no ARM64 build: the x64 one runs under emulation. Both are staged once in $VM_HOME/installers.
# <vm dir>/clipboard.ok records the install, so later shows skip the guest (vmctl.sh up deletes it with the disk).
# Exits 0 when the agent is in place, 1 when it could not be put there (show opens the viewer anyway).
# bash 3.2 compatible.
set -u
X=$(cd "$(dirname "$0")" && pwd)
d=${1:?usage: clipboard.sh <vm dir>}
VM_HOME=${VM_HOME:-${FACTORY_VM_HOME:-$HOME/VMs/factory/windows}}
MSI=spice-vdagent-x64-0.10.0.msi
MSI_URL=https://www.spice-space.org/download/windows/vdagent/vdagent-win-0.10.0/$MSI
MSI_SHA256=77629435705bc27dd7d2525e9d2084f72dbab5fdbf310e812f91332fe18d00eb
STAGE=$VM_HOME/installers/clipboard

say() { echo "clipboard: $*" >&2; }
[ -f "$d/clipboard.ok" ] && exit 0
# Neither step uses the shared worktree: skip mapping R:, the bulk of each guest call.
export VM_NO_SHARE=1

# A VM started before vmctl.sh up added the port has nothing for the agent to talk to.
ps -o command= -p "$(cat "$d/qemu.pid")" | grep -q qemu-vdagent \
  || { say "this VM was started without the clipboard port: vmt down and up again for a shared clipboard"; exit 1; }

mkdir -p "$STAGE"
if [ ! -f "$STAGE/vioserial/vioser.inf" ]; then
  [ -f "$VM_HOME/virtio-win.iso" ] || { say "no $VM_HOME/virtio-win.iso for the guest's virtio-serial driver"; exit 1; }
  # The ISO stores w11's ARM64 files as hard links to 2k25's: extract those.
  t=$(mktemp -d) && mkdir -p "$STAGE/vioserial" \
    && bsdtar -xf "$VM_HOME/virtio-win.iso" -C "$t" 'vioserial/2k25/ARM64' \
    && cp "$t"/vioserial/2k25/ARM64/vioser.{inf,cat,sys} "$STAGE/vioserial/"
  rc=$?; chmod -R u+w "$t"; rm -rf "$t"
  [ "$rc" = 0 ] || { say "could not extract the virtio-serial driver from virtio-win.iso"; rm -rf "$STAGE/vioserial"; exit 1; }
fi
if [ ! -f "$STAGE/$MSI" ]; then
  curl -sfL "$MSI_URL" -o "$STAGE/$MSI.part" \
    && [ "$(shasum -a 256 "$STAGE/$MSI.part" | cut -d' ' -f1)" = "$MSI_SHA256" ] \
    && mv "$STAGE/$MSI.part" "$STAGE/$MSI" \
    || { say "could not download $MSI_URL (or its checksum differs)"; rm -f "$STAGE/$MSI.part"; exit 1; }
fi

say "putting the clipboard agent in the guest (once per VM)"
"$X/vmcp" "$STAGE" 'C:\factory\clipboard' || { say "could not copy the agent into the guest"; exit 1; }
"$X/vmssh" - <<EOF || { say "the agent's install failed in the guest"; exit 1; }
\$ErrorActionPreference = 'Stop'
if (Get-Service spice-agent -ErrorAction SilentlyContinue) { exit 0 }
pnputil /add-driver C:\factory\clipboard\vioserial\vioser.inf /install | Out-Null
\$p = Start-Process msiexec -ArgumentList '/i', 'C:\factory\clipboard\\$MSI', '/qn', '/norestart' -Wait -PassThru
if (\$p.ExitCode -ne 0) { throw "msiexec exit \$(\$p.ExitCode)" }
EOF
touch "$d/clipboard.ok"
