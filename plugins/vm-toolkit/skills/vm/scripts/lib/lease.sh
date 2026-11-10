#!/bin/bash
# lease.sh: runs one command on a run's VM, booting the VM first when it is not up, and lets it go when idle.
#   lease.sh <vmctl.sh> <vm run dir> <worktree> <event log | -> <command> [args...]
#   lease.sh --reap <vmctl.sh> <vm run dir> <worktree> <event log | ->   (started by the above, detached)
# A run's build VM is booted by its first build or test, not at the start of the run, so a builder that is still
# reading or thinking holds no VM slot. After VM_IDLE_MIN minutes with no command on it, a reaper powers it off and
# frees the slot for another run; the next command boots a fresh one (the build output lives in the worktree, on the
# Mac, so the build stays incremental). Boot waits for a free slot (vmctl.sh, VM_SLOT_WAIT_MIN). Exits with the
# command's code, or 3 (a harness error, guest.sh's convention) when the VM does not come up.
# FACTORY_VM_IDLE_S and FACTORY_REAP_POLL_S override the idle time and the reaper's poll, for the engine tests.
# bash 3.2 compatible.
set -u
REAP=no
[ "${1:-}" = --reap ] && { REAP=yes; shift; }
V=$1 D=$2 W=$3 LOG=$4
shift 4
L=$D/lease
IDLE_S=${FACTORY_VM_IDLE_S:-$(( ${VM_IDLE_MIN:-10} * 60 ))}
POLL_S=${FACTORY_REAP_POLL_S:-15}
mkdir -p "$D"

# A time box kills the builder's whole process group, a lease mid-command included: the lock and the users are pid
# files, and a dead pid's is ignored, so a killed holder never leaves the VM locked or kept up.
lock() {
  local p
  until mkdir "$L.lock" 2> /dev/null; do
    p=$(cat "$L.lock/pid" 2> /dev/null)
    [ -n "$p" ] && ! kill -0 "$p" 2> /dev/null && rm -rf "$L.lock"
    sleep 1
  done
  echo $$ > "$L.lock/pid"
}
# The reaper runs in its own session (setsid), so a time box that kills the builder's process group leaves it running.
unlock() { rm -rf "$L.lock"; }
log() { [ "$LOG" = - ] || echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"; }
users() {
  local f n=0
  for f in "$L.users"/*; do
    [ -f "$f" ] || continue
    if kill -0 "$(basename "$f")" 2> /dev/null; then n=$((n + 1)); else rm -f "$f"; fi
  done
  echo $n
}

# reap: powers the VM off once no command has used it for IDLE_S; one reaper a VM, gone with the VM.
reap() {
  while sleep "$POLL_S"; do
    "$V" alive "$D" || break
    lock
    if [ "$(users)" -le 0 ] && [ $(( $(date +%s) - $(cat "$L.last" 2> /dev/null || echo 0) )) -ge "$IDLE_S" ]; then
      "$V" down "$D" > /dev/null 2>&1
      log "build VM down: idle for $([ "$IDLE_S" -ge 60 ] && echo "$(( IDLE_S / 60 )) min" || echo "$IDLE_S s"), its slot is free"
      unlock
      break
    fi
    unlock
  done
  rm -rf "$L.reaper"
}

if [ "$REAP" = yes ]; then
  echo $$ > "$L.reaper/pid"
  reap
  exit 0
fi

lock
if ! "$V" alive "$D"; then
  log "build VM up (on demand), sharing $W"
  if ! "$V" up "$D" "$W" > "$D/lease-up.log" 2>&1; then
    unlock
    echo "HARNESS ERROR: the build VM did not come up: $(tail -1 "$D/lease-up.log")"
    exit 3
  fi
fi
mkdir -p "$L.users" && : > "$L.users/$$"
unlock

"$@"
rc=$?

lock
rm -f "$L.users/$$"
date +%s > "$L.last"
unlock
r=$(cat "$L.reaper/pid" 2> /dev/null)
[ -n "$r" ] && ! kill -0 "$r" 2> /dev/null && rm -rf "$L.reaper"
if mkdir "$L.reaper" 2> /dev/null; then
  echo $$ > "$L.reaper/pid"
  perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' bash "$0" --reap "$V" "$D" "$W" "$LOG" > /dev/null 2>&1 < /dev/null &
fi
exit "$rc"
