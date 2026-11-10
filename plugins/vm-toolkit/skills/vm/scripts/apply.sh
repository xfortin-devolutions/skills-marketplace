#!/bin/bash
# apply.sh: puts a setup folder (test data, settings, a resource only a human can provide) into a running VM, before the
# app starts: copies it to <guest folder>, runs its check.ps1 if it has one (is the resource reachable?), then its
# apply.ps1 if it has one. Both scripts get $Dir (the guest folder) and stop at their first error.
#   apply.sh <local folder> <guest folder> [<log>]      e.g. apply.sh ./fixtures/two-vaults 'C:\factory\fixtures\two-vaults'
# The VM is the one whose environment is exported (eval "$(vmctl.sh env <run dir>)"). Output goes to <log> (default:
# stdout). Exit: 0 in place, 2 the copy failed, 3 apply.ps1 failed, 4 check.ps1 failed (the resource needs a human).
# VMT_VM_DIR swaps the VM tools (vmcp, vmssh), for the engine tests of a caller. bash 3.2 compatible.
set -u
X=$(cd "$(dirname "$0")" && pwd)
V=${VMT_VM_DIR:-$X/vm}
[ $# -ge 2 ] || { sed -n '5,8p' "$0" >&2; exit 2; }
src=$1 g=$2 log=${3:-/dev/stdout}

# script <file>: runs one of the folder's scripts in the guest, $Dir set
script() {
  { printf '$ErrorActionPreference = "Stop"\n$Dir = '"'"'%s'"'"'\n' "$g"; cat "$1"; } | "$V/vmssh" - >> "$log" 2>&1
}

"$V/vmcp" "$src" "$g" >> "$log" 2>&1 || exit 2
if [ -f "$src/check.ps1" ]; then script "$src/check.ps1" || exit 4; fi
if [ -f "$src/apply.ps1" ]; then script "$src/apply.ps1" || exit 3; fi
exit 0
