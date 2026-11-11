# checkpoints.sh: a VM's state frozen as an image other VMs start from, sourced by vmt (bash 3.2 compatible). Set before
# sourcing: VM_ROOT, X (the scripts folder), and die().
# A checkpoint is <VM root>/<guest os>/checkpoints/<name>.qcow2 (read-only, backed by the image its VM started from),
# with <name>.vars.fd (firmware variables), <name>.conf (what it is: CREATED, PRODUCT, PLATFORM, WORKTREE, BRANCH,
# FROM_VM, FROM_IMAGE, NOTE) and, when the clipboard agent was in it, <name>.clipboard-agent. Nothing deletes one but
# ck_rm: a person decides when a ticket's checkpoint can go (a ticket can carry on for weeks).

ck_name_ok() { echo "$1" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; }

# ck_find <name>: the checkpoint's image path, or die
ck_find() {
  local hits
  ck_name_ok "${1:-}" || die "bad checkpoint name '${1:-}': lowercase letters, digits and dashes"
  hits=$(ls "$VM_ROOT"/*/checkpoints/"$1".qcow2 2> /dev/null)
  [ -n "$hits" ] || die "no checkpoint '$1' (vmt checkpoint list)"
  [ "$(echo "$hits" | grep -c .)" = 1 ] || die "checkpoint '$1' exists for several guest OSes: $(echo $hits)"
  echo "$hits"
}

# ck_field <image> <KEY>: a field of the checkpoint's .conf, without touching the caller's variables
ck_field() { ( . "${1%.qcow2}.conf" 2> /dev/null; eval "echo \"\${$2:-}\"" ); }

ck_all() { ls "$VM_ROOT"/*/checkpoints/*.qcow2 2> /dev/null; }

# ck_blockers <image>: what must go before the checkpoint can be deleted, one per line: running VMs started from it,
# and other checkpoints built on it (a checkpoint taken in a VM that started from this one).
ck_blockers() {
  local s d c
  for s in "$VM_ROOT"/*/slots/*/vm; do
    [ -f "$s" ] || continue
    d=$(cat "$s")
    [ -f "$d/qemu.pid" ] && kill -0 "$(cat "$d/qemu.pid")" 2> /dev/null || continue
    # -U: the running QEMU holds the image's lock; reading its header is safe.
    qemu-img info -U --backing-chain "$d/disk.qcow2" 2> /dev/null | grep -qxF "image: $1" \
      && echo "VM $(basename "$(dirname "$d")") (running)"
  done
  for c in $(ck_all); do
    [ "$c" = "$1" ] && continue
    qemu-img info --backing-chain "$c" 2> /dev/null | grep -qxF "image: $1" \
      && echo "checkpoint $(basename "$c" .qcow2) (built on it)"
  done
}

# ck_idle_users <image>: VM folders of the MCP server that boot from it but are down (they can't boot once it's gone)
ck_idle_users() {
  local n c
  n=$(basename "$1" .qcow2)
  for c in "$VM_ROOT"/mcp/*/guest.conf; do
    [ -f "$c" ] && grep -qx "VM_IMAGE=checkpoints/$n.qcow2" "$c" || continue
    "$X/vm/vmctl.sh" alive "$(dirname "$c")" 2> /dev/null || echo "VM $(basename "$(dirname "$c")") (down)"
  done
}

ck_kb() { du -k "$1" | cut -f1; }
ck_human() { awk -v k="$1" 'BEGIN { if (k >= 1048576) printf "%.1f GB", k / 1048576; else printf "%d MB", k / 1024 }'; }
ck_age() {
  local s
  s=$(( $(date +%s) - ${1:-0} ))
  if [ "$s" -ge 86400 ]; then echo "$((s / 86400))d"
  elif [ "$s" -ge 3600 ]; then echo "$((s / 3600))h"
  else echo "$((s / 60))m"; fi
}

ck_list() {
  local c n kb total=0 count=0 users
  printf '%-24s %-8s %-4s %-9s %-40s %s\n' NAME SIZE AGE PRODUCT BRANCH "IN USE BY"
  for c in $(ck_all); do
    n=$(basename "$c" .qcow2)
    kb=$(ck_kb "$c"); total=$((total + kb)); count=$((count + 1))
    users=$(ck_blockers "$c" | paste -sd, - | sed 's/,/, /g')
    qemu-img info --backing-chain "$c" > /dev/null 2>&1 || users="BROKEN: an image under it is gone"
    printf '%-24s %-8s %-4s %-9s %-40s %s\n' "$n" "$(ck_human "$kb")" "$(ck_age "$(ck_field "$c" CREATED)")" \
      "$(ck_field "$c" PRODUCT)" "$(ck_field "$c" BRANCH)" "${users:--}"
  done
  echo "$count checkpoint(s), $(ck_human "$total") under $VM_ROOT/*/checkpoints (delete: vmt checkpoint rm <name>...)"
}

# ck_summary: one line for vmt list when there are checkpoints, so they don't pile up unseen
ck_summary() {
  local c total=0 count=0
  for c in $(ck_all); do total=$((total + $(ck_kb "$c"))); count=$((count + 1)); done
  [ "$count" -gt 0 ] && echo "checkpoints: $count, $(ck_human "$total") (vmt checkpoint list)"
  return 0
}

ck_show() {
  local c k
  c=$(ck_find "${1:-}") || exit 1
  echo "$c ($(ck_human "$(ck_kb "$c")"), taken $(ck_age "$(ck_field "$c" CREATED)") ago)"
  for k in PRODUCT PLATFORM WORKTREE BRANCH FROM_VM FROM_IMAGE NOTE; do
    printf '  %-11s %s\n' "$k" "$(ck_field "$c" "$k")"
  done
  ck_blockers "$c" | sed 's/^/  in use by: /'
  ck_idle_users "$c" | sed 's/^/  boots from it: /'
}

ck_rm() {
  local n c b rc=0
  [ $# -gt 0 ] || die "usage: vmt checkpoint rm <name>..."
  for n in "$@"; do
    c=$(ck_find "$n") || { rc=1; continue; }
    b=$(ck_blockers "$c")
    if [ -n "$b" ]; then
      echo "kept $n: in use by $(echo "$b" | paste -sd, - | sed 's/,/, /g')" >&2
      rc=1; continue
    fi
    ck_idle_users "$c" \
      | sed "s/^/note: /; s/\$/ started from $n: it boots again once re-inited (vmt init, or vm_up)/" >&2
    local kb; kb=$(ck_kb "$c")
    chmod u+w "$c" "${c%.qcow2}.vars.fd" 2> /dev/null
    rm -f "$c" "${c%.qcow2}.vars.fd" "${c%.qcow2}.conf" "${c%.qcow2}.clipboard-agent"
    echo "deleted $n ($(ck_human "$kb"))"
  done
  return $rc
}

# ck_take <vm dir> <name> <note> <resume: yes|no>: freeze the VM (vm_conf loaded) into checkpoint <name>, point its
# folder at it, and boot it again from it when asked.
ck_take() {
  local D=$1 N=$2 note=$3 resume=$4 img c keep=no
  ck_name_ok "$N" || die "bad checkpoint name '$N': lowercase letters, digits and dashes"
  [ -z "$(ls "$VM_ROOT"/*/checkpoints/"$N".qcow2 2> /dev/null)" ] \
    || die "checkpoint '$N' exists: another name, or vmt checkpoint rm $N"
  "$X/vm/vmctl.sh" alive "$D" || die "the VM of $D is down: a checkpoint is taken from a running VM"
  img=checkpoints/$N.qcow2 c=$VM_HOME/checkpoints/$N.qcow2
  [ -f "$D/keep" ] && keep=yes
  if [ "$keep" = yes ]; then
    "$X/vm/vmctl.sh" freeze "$D" "$img" || exit 3
  else
    # Through the lease, as a user of the VM: its idle reaper can't power it off (and delete its disk) mid-freeze.
    "$X/lib/lease.sh" "$X/vm/vmctl.sh" "$D" "$WORKTREE" - "$X/vm/vmctl.sh" freeze "$D" "$img" || exit 3
  fi
  {
    printf 'CREATED=%s\nPRODUCT=%q\nPLATFORM=%q\nWORKTREE=%q\nBRANCH=%q\n' "$(date +%s)" "$PRODUCT" "$PLATFORM" \
      "$WORKTREE" "$(git -C "$WORKTREE" branch --show-current 2> /dev/null)"
    printf 'FROM_VM=%q\nFROM_IMAGE=%q\nNOTE=%q\n' "$D" "$VM_IMAGE" "$note"
  } > "${c%.qcow2}.conf"
  # The disk this folder had is the checkpoint now: from here on the VM starts from it.
  grep -v '^VM_IMAGE=' "$D/guest.conf" > "$D/guest.conf.new" && printf 'VM_IMAGE=%q\n' "$img" >> "$D/guest.conf.new" \
    && mv "$D/guest.conf.new" "$D/guest.conf"
  echo "checkpoint $N: $c; $D starts from it from now on"
  [ "$resume" = yes ] || return 0
  if [ "$keep" = yes ]; then "$X/vmt" up "$D" --keep; else "$X/vmt" up "$D"; fi
}
