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
#   factory.sh new-profile <name> [--skill <project>]   start profiles/<name>/ from the skill's templates, in this repo's
#                                        project (its own .factory/, or the skill's projects/<project>/ that matches it);
#                                        a repo with no project gets one: .factory/ in the repo, or with --skill, in the skill
#   factory.sh check [profile]           which project this repo uses, then check a profile (default: every one)
#   factory.sh which <path>...           the profile whose CODE_PATHS own each repo path (how the spec step picks one)
#   factory.sh clean <KEY> [--dry-run]   a finished ticket: delete its spec, its run logs and its VM folders; list the
#                                        worktrees and branches left (removing those stays a human's call)
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
    [ -n "$PROJECT_DIR" ] || die "no project for this repo (factory.sh new-profile)"
    [ -f "$PROJECT_DIR/profiles/$prof/profile.sh" ] || die "no profile '$prof' in $PROJECT_FROM (factory.sh start <KEY> <profile>)"
    prefix=$(TICKET=$key PROFILE_DIR=$PROJECT_DIR/profiles/$prof; . "$PROFILE_DIR/profile.sh" > /dev/null 2>&1; echo "${BRANCH_PREFIX:-}")
    k=$(echo "$key" | tr '[:upper:]' '[:lower:]')
    branch=$prefix$k wt=$MAIN_REPO/.claude/worktrees/$k
    git -C "$REPO" worktree add -q --no-track -b "$branch" "$wt" "$from" || die "could not create $branch at ${wt#$MAIN_REPO/}"
    [ "$PROJECT_DIR" != "$FACTORY_DIR" ] || [ -d "$wt/$FACTORY_DIR_REL/profiles" ] \
      || echo "note: $from has no $FACTORY_DIR_REL/profiles: the loop can't run there until the project is in it (--from <branch that has it>)"
    echo "ticket $key: branch $branch from $from @ $(git -C "$wt" rev-parse --short HEAD), worktree ${wt#$MAIN_REPO/}"
    echo "profile: $prof$([ "$prof" = "${DEFAULT_PROFILE:-}" ] && echo " (the default: check it with factory.sh which <code paths>)")"
    echo "spec: $TICKETS_DIR/$key.md and $key.sh (this machine's, never committed)"
    echo "write the oracle and its prerequisites in the worktree, and run the loop from there (each run cuts its own branch from it)" ;;
  new-profile)
    name=${1:-} proj=""
    [ "${2:-}" = --skill ] && proj=${3:-}
    case "$name" in ''|*[!a-z0-9-]*) die "usage: factory.sh new-profile <name> [--skill <project>] (lowercase letters, digits, dashes)" ;; esac
    if [ -z "$PROJECT_DIR" ]; then
      # A new project: in the repo (.factory/), or, while the repo shouldn't carry it yet, in the skill.
      if [ -n "$proj" ]; then
        case "$proj" in *[!a-z0-9-]*) die "--skill <project>: lowercase letters, digits, dashes" ;; esac
        PROJECT_DIR=$SKILL_DIR/projects/$proj
        origin=$(git -C "$REPO" remote get-url origin 2> /dev/null) || die "the repo has no origin remote to match"
        match="[:/]$(echo "$origin" | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##')(\\.git)?\$"
      else
        PROJECT_DIR=$FACTORY_DIR
      fi
      mkdir -p "$PROJECT_DIR"
      sed "s/@PROFILE@/$name/g" "$X/../templates/factory-config.sh" > "$PROJECT_DIR/config.sh"
      [ -n "$proj" ] && printf '\n# Which repo this project is for: an ERE on its origin remote URL.\nREPO_MATCH=%s\n' "'$match'" >> "$PROJECT_DIR/config.sh"
      echo "created $PROJECT_DIR/config.sh (team defaults; DEFAULT_PROFILE=$name)"
    fi
    dest=$PROJECT_DIR/profiles/$name
    [ -e "$dest" ] && die "$dest already exists"
    mkdir -p "$dest"
    cp -R "$X/../templates/profile/" "$dest/"
    find "$dest" -type f -exec sed -i '' "s/@PROFILE@/$name/g" {} +
    echo "created $dest: fill every TODO, then factory.sh check $name"
    find "$dest" -type f | sed "s|^$PROJECT_DIR/|  |" ;;
  check)
    n=0 bad=0
    [ -n "$PROJECT_DIR" ] || die "no project for this repo: no $FACTORY_DIR_REL/profiles, and no skill projects/*/config.sh whose REPO_MATCH matches its origin (factory.sh new-profile)"
    echo "project: $PROJECT_FROM"
    for d in "$PROJECT_DIR"/profiles/${1:-*}/; do
      [ -d "$d" ] || die "no profile '${1:-}' in $PROJECT_DIR/profiles"
      "$X/lib/check-profile.sh" "$REPO" "$TICKETS_DIR" "$PROJECT_DIR" "$(basename "$d")" || bad=$((bad + 1))
      n=$((n + 1))
    done
    [ "$bad" -eq 0 ] && echo "$n profile(s) OK" || { echo "$bad of $n profile(s) need work"; exit 1; } ;;
  layer)
    name=${1:-}; mode=${2:-}
    [ -n "$name" ] && [ "$mode" = --test -o "$mode" = --build ] || die "usage: factory.sh layer <profile> --test|--build"
    [ -f "$PROJECT_DIR/profiles/$name/layer/layer.conf" ] || die "profile $name has no layer/layer.conf"
    FACTORY_VM_HOME=$FACTORY_VM_ROOT/windows exec "$X/vm/golden/layer-build.sh" "$PROJECT_DIR/profiles/$name/layer" "$mode" ;;
  which)
    [ -n "$PROJECT_DIR" ] || die "no project for this repo (factory.sh new-profile)"
    [ $# -gt 0 ] || die "usage: factory.sh which <repo path>..."
    found=""
    for path in "$@"; do
      path=${path#$REPO/} best="" blen=0
      for d in "$PROJECT_DIR"/profiles/*/; do
        cps=$(TICKET=X PROFILE_DIR=${d%/} CODE_PATHS=""; . "${d}profile.sh" > /dev/null 2>&1; echo "$CODE_PATHS")
        for c in $cps; do
          case "$path" in "$c"*) [ ${#c} -gt $blen ] && best=$(basename "$d") blen=${#c} ;; esac
        done
      done
      echo "$path: ${best:-no profile}"
      found="$found ${best:-none}"
    done
    found=$(echo $found | tr ' ' '\n' | sort -u | tr '\n' ' ')
    case "$found" in
      "none ") echo "-> no profile covers this code: set one up first (the skill's profile steps), in $PROJECT_FROM" ;;
      *none*) echo "-> part of it has no profile: the profile is the product whose app shows the change; ask if unsure" ;;
      *" "?*" ") echo "-> several products ($found): the profile is the one whose app shows the change; ask if the ticket doesn't say" ;;
      *) echo "-> profile: $found" ;;
    esac ;;
  clean)
    key=${1:-}; [ -n "$key" ] || die "usage: factory.sh clean <KEY> [--dry-run]"
    dry=no; [ "${2:-}" = --dry-run ] && dry=yes
    k=$(echo "$key" | tr '[:upper:]' '[:lower:]')
    gone="" busy=""
    for d in "$TICKETS_DIR/$key.md" "$TICKETS_DIR/$key.sh" "$RUNS/$k"-*; do
      [ -e "$d" ] || continue
      if [ -d "$d" ]; then
        [ -n "$(live_vm "$d")" ] || [ -e "$d/WAITING-FOR-HUMAN" ] && { busy="$busy $(basename "$d")"; continue; }
        for v in "$FACTORY_VM_ROOT"/*/runs/"$(basename "$d")"; do [ -d "$v" ] && gone="$gone $v"; done
      fi
      gone="$gone $d"
    done
    [ -z "$busy" ] || echo "kept (a VM is live or it waits for a human; factory.sh down / stop first):$busy"
    if [ -z "$gone" ]; then echo "nothing to delete for $key"
    else
      du -shc $gone 2> /dev/null | tail -1 | sed "s/total/to delete for $key/"
      for d in $gone; do echo "  ${d#$HOME/}"; done
      [ "$dry" = yes ] || { rm -rf $gone; echo "deleted"; }
    fi
    git -C "$REPO" worktree prune
    wts=$(git -C "$REPO" worktree list | grep -i -- "$k" | awk '{print "  " $1 "  " $3}')
    brs=$(git -C "$REPO" branch --list "*$k*" | sed 's/^[*+ ] */  /')
    [ -z "$wts$brs" ] || printf 'left for you to remove (git worktree remove / git branch -D):\n%s%s\n' "${wts:+$wts
}" "$brs" ;;
  *) sed -n '2,18p' "$0"; exit 2 ;;
esac
