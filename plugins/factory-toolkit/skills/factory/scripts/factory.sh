#!/bin/bash
# factory.sh: talk to factory runs started by run-loop.sh.
#   factory.sh start <KEY> [profile] [--from <ref>]   a ticket's own branch and worktree, from the latest origin/master
#                                        (or <ref>: while the factory lives on a branch, --from that branch)
#   factory.sh status [run]              runs (newest first), or one run's table, status and last events
#   factory.sh show [run]                open the run's live VM (QA's, else the build VM) in macOS Screen Sharing
#   factory.sh human [run]               a human judges the run's next (or current) QA instead of the agent alone
#   factory.sh judge [run] pass|fail <why>   answer a run that waits for a human; the loop resumes
#   factory.sh stop [run]                stop the run before its next station
#   factory.sh down [run]                power off the VMs a run kept (--keep-vm) and remove their worktrees
#   factory.sh new-profile <name>        start .factory/profiles/<name>/ from the skill's templates (and .factory/ itself)
#   factory.sh check [profile]           check a profile (default: every profile) against references/profiles.md
#   factory.sh layer <profile> --test|--build   rehearse (throwaway clone) or build and freeze the profile's VM layer
# [run] is a run id or a prefix of one (devex-528-2026…); default: the newest run.
set -u
X=$(cd "$(dirname "$0")" && pwd)
# The repo is the one the command runs from: the engine is installed apart from it (a plugin), never inside it.
REPO=$(git rev-parse --show-toplevel 2> /dev/null) || { echo "factory: run this from inside the repo (no git repo here)" >&2; exit 2; }
TICKET=""
. "$X/lib/config.sh" || exit 2
RUNS=$FACTORY_RUNS

die() { echo "factory: $*" >&2; exit 1; }
run_dir() { # run_dir [id or prefix]: newest match
  local d
  d=$(ls -1dt "$RUNS"/"${1:-}"* 2> /dev/null | head -1)
  [ -n "$d" ] && [ -d "$d" ] || die "no run matching '${1:-}' in $RUNS"
  echo "$d"
}
live_vm() { # live_vm <run dir>: the run's running VM folder (vmctl's <run dir>), if any
  local id v
  id=$(basename "$1")
  [ -s "$1/WAITING-FOR-HUMAN" ] && { cat "$1/WAITING-FOR-HUMAN"; return; }
  for v in "$FACTORY_VM_ROOT"/*/runs/"$id"/vm-*; do
    [ -f "$v/vm/qemu.pid" ] && kill -0 "$(cat "$v/vm/qemu.pid")" 2> /dev/null && { echo "$v"; return; }
  done
}

cmd=${1:-status}
[ $# -gt 0 ] && shift
case "$cmd" in
  status)
    if [ $# -eq 0 ]; then
      for d in $(ls -1dt "$RUNS"/*/ 2> /dev/null | head -10); do
        d=${d%/}
        s=$(grep -m1 '^- Status:' "$d/loop-handback.md" 2> /dev/null | sed 's/^- Status: *//')
        [ -z "$s" ] && s=$(tail -1 "$d/events.log" 2> /dev/null | cut -c22-)
        [ -e "$d/WAITING-FOR-HUMAN" ] && s="WAITING FOR A HUMAN ($s)"
        echo "$(basename "$d"): $s"
      done
    else
      d=$(run_dir "$1") || exit 1
      cat "$d/runs.md" 2> /dev/null; echo
      [ -f "$d/loop-handback.md" ] && cat "$d/loop-handback.md"
      [ -e "$d/WAITING-FOR-HUMAN" ] && echo "WAITING FOR A HUMAN: factory.sh show $(basename "$d"), then factory.sh judge $(basename "$d") pass|fail <why>"
      echo "-- last events"; tail -5 "$d/events.log"
    fi ;;
  show)
    d=$(run_dir "${1:-}") || exit 1
    v=$(live_vm "$d")
    [ -n "$v" ] || die "no running VM for $(basename "$d") (VMs live while the run does, and after a QA stage with --keep-vm)"
    "$X/vm/vmctl.sh" show "$v" ;;
  human) d=$(run_dir "${1:-}") || exit 1; touch "$d/HUMAN"; echo "the next QA verdict of $(basename "$d") waits for you" ;;
  stop) d=$(run_dir "${1:-}") || exit 1; touch "$d/STOP"; echo "$(basename "$d") stops before its next station" ;;
  down)
    d=$(run_dir "${1:-}") || exit 1
    n=0
    for k in "$FACTORY_VM_ROOT"/*/runs/"$(basename "$d")"/vm-*/factory-kept; do
      [ -f "$k" ] || continue
      "$X/vm/vmctl.sh" down "$(dirname "$k")"
      [ -s "$k" ] && git -C "$REPO" worktree remove --force "$(cat "$k")" 2> /dev/null
      rm -f "$k"; n=$((n + 1))
    done
    echo "$(basename "$d"): $n kept VM(s) down" ;;
  judge)
    case "${1:-}" in pass|fail) d=$(run_dir "") || exit 1 ;; *) d=$(run_dir "${1:-}") || exit 1; shift ;; esac
    verdict=${1:-}; shift
    case "$verdict" in pass|fail) ;; *) die "usage: factory.sh judge [run] pass|fail <why>" ;; esac
    [ $# -gt 0 ] || die "say why: factory.sh judge [run] $verdict <why>"
    [ -e "$d/WAITING-FOR-HUMAN" ] || echo "note: $(basename "$d") is not waiting for a human; the verdict applies to its next QA wait" >&2
    echo "$verdict: $*" > "$d/HUMAN-VERDICT"
    echo "$(basename "$d"): $verdict: $*" ;;
  start)
    key="" prof=$DEFAULT_PROFILE from=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --from) from=${2:-}; [ -n "$from" ] || die "--from needs a ref"; shift ;;
        -*) die "usage: factory.sh start <KEY> [profile] [--from <ref>]" ;;
        *) if [ -z "$key" ]; then key=$1; else prof=$1; fi ;;
      esac
      shift
    done
    [ -n "$key" ] || die "usage: factory.sh start <KEY> [profile] [--from <ref>]"
    if [ -z "$from" ]; then
      git -C "$REPO" fetch -q origin "$PR_BASE" || die "could not fetch origin/$PR_BASE"
      from=origin/$PR_BASE
    fi
    [ -f "$FACTORY_DIR/profiles/$prof/profile.sh" ] || die "no profile '$prof' (factory.sh start <KEY> <profile>)"
    prefix=$(TICKET=$key; . "$FACTORY_DIR/profiles/$prof/profile.sh" > /dev/null 2>&1; echo "${BRANCH_PREFIX:-}")
    k=$(echo "$key" | tr '[:upper:]' '[:lower:]')
    branch=$prefix$k wt=$MAIN_REPO/.claude/worktrees/$k
    git -C "$REPO" worktree add -q --no-track -b "$branch" "$wt" "$from" || die "could not create $branch at ${wt#$MAIN_REPO/}"
    [ -d "$wt/$FACTORY_DIR_REL" ] || echo "note: $from has no $FACTORY_DIR_REL: the loop can't run there until the factory is in it (--from <factory branch>)"
    echo "ticket $key: branch $branch from $from @ $(git -C "$wt" rev-parse --short HEAD), worktree ${wt#$MAIN_REPO/}"
    echo "write the spec, its oracle and its prerequisites there, and run the loop from there (each run cuts its own branch from it)" ;;
  new-profile)
    name=${1:-}
    case "$name" in ''|*[!a-z0-9-]*) die "usage: factory.sh new-profile <name> (lowercase letters, digits, dashes)" ;; esac
    dest=$FACTORY_DIR/profiles/$name
    [ -e "$dest" ] && die "$FACTORY_DIR_REL/profiles/$name already exists"
    if [ ! -f "$FACTORY_DIR/config.sh" ]; then
      mkdir -p "$FACTORY_DIR/tickets"
      sed "s/@PROFILE@/$name/g" "$X/../templates/factory-config.sh" > "$FACTORY_DIR/config.sh"
      echo "created $FACTORY_DIR_REL/config.sh (team defaults; DEFAULT_PROFILE=$name)"
    fi
    mkdir -p "$dest"
    cp -R "$X/../templates/profile/" "$dest/"
    find "$dest" -type f -exec sed -i '' "s/@PROFILE@/$name/g" {} +
    echo "created $FACTORY_DIR_REL/profiles/$name: fill every TODO, then factory.sh check $name"
    find "$dest" -type f | sed "s|^$REPO/|  |" ;;
  check)
    n=0 bad=0
    for d in "$FACTORY_DIR"/profiles/${1:-*}/; do
      [ -d "$d" ] || die "no profile '${1:-}' in $FACTORY_DIR_REL/profiles"
      "$X/lib/check-profile.sh" "$REPO" "$FACTORY_DIR" "$(basename "$d")" || bad=$((bad + 1))
      n=$((n + 1))
    done
    [ "$bad" -eq 0 ] && echo "$n profile(s) OK" || { echo "$bad of $n profile(s) need work"; exit 1; } ;;
  layer)
    name=${1:-}; mode=${2:-}
    [ -n "$name" ] && [ "$mode" = --test -o "$mode" = --build ] || die "usage: factory.sh layer <profile> --test|--build"
    [ -f "$FACTORY_DIR/profiles/$name/layer/layer.conf" ] || die "profile $name has no layer/layer.conf"
    FACTORY_VM_HOME=$FACTORY_VM_ROOT/windows exec "$X/vm/golden/layer-build.sh" "$FACTORY_DIR/profiles/$name/layer" "$mode" ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
