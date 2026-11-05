#!/bin/bash
# factory.sh: talk to factory runs started by run-loop.sh.
#   factory.sh start <KEY> [profile] [--from <ref>]   a ticket's own branch and worktree, from the latest origin/master
#                                        (or <ref>: while the factory lives on a branch, --from that branch)
#   factory.sh status [run]              runs (newest first), or one run's table, status and last events
#   factory.sh show [run]                open the run's live VM (QA's, else the build VM) in macOS Screen Sharing
#   factory.sh human [run]               a human judges the run's next (or current) QA instead of the agent alone
#   factory.sh judge [run] pass|fail <why>   answer a run that waits for a human; the loop resumes
#   factory.sh stop [run]                stop the run before its next station
#   factory.sh pause [run]               stop the run before its next station, resumable: the runner saves its state and
#                                        exits, its VMs power off (a weekend, a reboot)
#   factory.sh resume [run] [--size <class>] [--set NAME=VALUE]...   go on with a paused, stopped or crashed loop run
#                                        from the station it saved, in the same run folder (runs in the foreground: start
#                                        it in the background); --size and --set raise (or lower) its limits from there
#   factory.sh assess <KEY>              the assessor alone: size class and test needs, in <KEY>.assessment.md next to the
#                                        spec (the one before is kept as .prev); runs in the foreground, a few minutes
#   factory.sh limits <KEY> [--size <class>] [--set NAME=VALUE]...   the limits a run of <KEY> would use, and why
#   factory.sh fixture <KEY> <name>      start a fixture for a ticket (<KEY>.fixtures/<name>/ next to its spec): state
#                                        QA's VMs need, applied before the app starts; deleted by clean <KEY>
#   factory.sh provide <name>            start a resource only a human can provide (~/.factory/provided/<name>/)
#   factory.sh provided                  the resources provided on this machine, and the tickets that need missing ones
#   factory.sh down [run]                power off the VMs a run kept (--keep-vm) and remove their worktrees
#   factory.sh new-profile <name> [--skill <project>]   start profiles/<name>/ from the skill's templates, in this repo's
#                                        project (its own .factory/, or the skill's projects/<project>/ that matches it);
#                                        a repo with no project gets one: .factory/ in the repo, or with --skill, in the skill
#   factory.sh check [profile]           which project this repo uses, then check a profile (default: every one)
#   factory.sh which <path>...           the profile whose CODE_PATHS own each repo path (how the spec step picks one)
#   factory.sh spec <KEY> [--open]       a ticket's spec files (and open the .md in the default app)
#   factory.sh dashboard [--port N] [--no-open]   live view of the runs in the browser, one per repo, at
#                                        http://<DASHBOARD_NAME>.factory.localhost:<DASHBOARD_PORT>/ (local; Ctrl-C stops)
#   factory.sh clean <KEY> [--dry-run]   a finished ticket: delete its spec, fixtures, run logs and VM folders; list the
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
  pause)
    d=$(run_dir "${1:-}") || exit 1
    touch "$d/PAUSE"
    echo "$(basename "$d") pauses before its next station; factory.sh resume $(basename "$d") goes on from there" ;;
  resume)
    sel=""; case "${1:-}" in ""|--*) ;; *) sel=$1; shift ;; esac
    d=$(run_dir "$sel") || exit 1
    [ -f "$d/state.sh" ] || die "$(basename "$d") has no saved state (a QA-only or test-only run, or one from before 0.5.0)"
    if [ -s "$d/runner.pid" ] && kill -0 "$(cat "$d/runner.pid")" 2> /dev/null; then
      [ -e "$d/PAUSE" ] || die "$(basename "$d") is running"
      rm -f "$d/PAUSE"; echo "$(basename "$d") had not reached its pause yet: the pause is cancelled"; exit 0
    fi
    t=$(. "$d/state.sh"; echo "$S_TICKET") wt=$(. "$d/state.sh"; echo "$S_WT")
    [ -d "$wt" ] || die "the run's worktree $wt is gone"
    cd "$wt" && exec bash "$X/run-loop.sh" "$t" --resume-run "$(basename "$d")" "$@" ;;
  assess)
    key=${1:-}; [ -n "$key" ] || die "usage: factory.sh assess <KEY>"
    [ -f "$TICKETS_DIR/$key.md" ] || die "no spec for $key in $TICKETS_DIR: write it first"
    exec bash "$X/run-loop.sh" "$key" --assess-only ;;
  limits)
    key=${1:-}; [ -n "$key" ] || die "usage: factory.sh limits <KEY> [--size <class>] [--set NAME=VALUE]..."
    shift
    exec bash "$X/run-loop.sh" "$key" --limits-only "$@" ;;
  fixture)
    key=${1:-} name=${2:-}
    [ -n "$key" ] || die "usage: factory.sh fixture <KEY> <name>"
    case "$name" in ''|*[!a-z0-9-]*) die "usage: factory.sh fixture <KEY> <name> (lowercase letters, digits, dashes)" ;; esac
    [ -f "$TICKETS_DIR/$key.md" ] || die "no spec for $key in $TICKETS_DIR: write it first"
    d=$TICKETS_DIR/$key.fixtures/$name
    if [ -f "$d/fixture.md" ]; then
      echo "$d exists:"; ls -A "$d" | sed 's/^/  /'
    else
      mkdir -p "$d"
      sed "s/@NAME@/$name/g" "$X/../templates/fixture/fixture.md" > "$d/fixture.md"
      cp "$X/../templates/fixture/apply.ps1" "$d/apply.ps1"
      echo "created $d"
    fi
    echo "1. fill $d/fixture.md: What (what it puts in place) and Use (where QA finds it), in user terms; no secrets"
    echo "2. write apply.ps1 (idempotent, throws on failure) and put its data files next to it: copied into each QA VM's"
    echo "   C:\\factory\\fixtures\\$name, run there before the app starts, \$Dir = that folder"
    echo "3. name it in $key.assessment.md: '| fixture: $name', then factory.sh check, and prove it with run-loop.sh $key --qa-only <base> --expect red" ;;
  provide)
    name=${1:-}
    case "$name" in ''|*[!a-z0-9-]*) die "usage: factory.sh provide <name> (lowercase letters, digits, dashes)" ;; esac
    d=$FACTORY_PROVIDED/$name
    if [ -f "$d/provided.md" ]; then
      echo "$d exists:"; ls -A "$d" | grep -v '^\.in-use\.d$' | sed 's/^/  /'
    else
      mkdir -p "$d" && chmod 700 "$FACTORY_PROVIDED" "$d"
      sed "s/@NAME@/$name/g" "$X/../templates/provided/provided.md" > "$d/provided.md"
      cp "$X/../templates/provided/check.ps1" "$d/check.ps1.example"
      echo "created $d"
    fi
    echo "1. fill $d/provided.md: what it is and how QA uses it, in user terms; no secrets (agents read it)"
    echo "2. put the files the guest needs next to it (a data source file, credentials): copied into each QA VM's"
    echo "   C:\\factory\\provided\\$name, never into a prompt or the repo"
    echo "3. optional: check.ps1 (fails when the resource can't be reached from the VM) and apply.ps1 (sets the app up"
    echo "   with it, then deletes what QA must not read): they run in the guest, \$Dir = that folder"
    echo "then: factory.sh resume <run>, or run the ticket again" ;;
  provided)
    for f in "$FACTORY_PROVIDED"/*/provided.md; do
      [ -f "$f" ] || continue
      n=$(basename "$(dirname "$f")")
      use=$(cat "$(dirname "$f")/.in-use.d/run" 2> /dev/null)
      echo "$n: $(sed -n 's/^What: *//p' "$f" | head -1) · $(sed -n 's/^Access: *//p' "$f" | head -1) · shared: $(sed -n 's/^Shared: *//p' "$f" | head -1)${use:+ · in use by $use}"
    done
    for a in "$TICKETS_DIR"/*.assessment.md; do
      [ -f "$a" ] || continue
      grep -E '^- N[0-9]+: .*\| *provided: ' "$a" | sed -E 's/.*\| *provided: *([a-z0-9-]+).*/\1/' | sort -u | while read -r n; do
        [ -f "$FACTORY_PROVIDED/$n/provided.md" ] || echo "missing: $n, needed by $(basename "$a" .assessment.md): factory.sh provide $n"
      done
    done ;;
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
      doc=no
      for c in $DOC_PATHS; do case "$path" in "$c"*) doc=yes ;; esac; done
      [ "$doc" = yes ] && { echo "$path: docs (any profile)"; continue; }
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
  dashboard)
    port=$DASHBOARD_PORT open_it=yes
    while [ $# -gt 0 ]; do
      case "$1" in --port) port=${2:-$DASHBOARD_PORT}; shift ;; --no-open) open_it=no ;; esac
      shift
    done
    command -v python3 > /dev/null || die "the dashboard needs python3"
    url="http://$DASHBOARD_NAME.factory.localhost:$port/"
    # One dashboard per repo: when this repo's is already up, open it rather than start another.
    who=$(curl -s -m 2 "http://127.0.0.1:$port/api/whoami" 2> /dev/null)
    if [ -n "$who" ]; then
      mine=$( (cd "$RUNS" 2> /dev/null && pwd -P) || echo "$RUNS")
      held=$(printf %s "$who" | python3 -I -c 'import json,sys
try: print(json.load(sys.stdin).get("runs") or "")
except ValueError: print("")')
      if [ "$held" = "$mine" ]; then
        echo "factory dashboard: $url (already running)"
        [ "$open_it" = yes ] && open "$url"
        exit 0
      fi
      if [ -n "$held" ]; then die "port $port is another repo's dashboard ($held): set DASHBOARD_PORT for this one"
      elif curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/runs" | grep -q 200; then
        die "port $port is an older factory dashboard: stop it (kill $(lsof -tiTCP:"$port" -sTCP:LISTEN | head -1)), then start this one"
      else die "port $port is taken by another program: free it, or set DASHBOARD_PORT"
      fi
    fi
    log=$(mktemp -t factory-dashboard)
    python3 -I "$X/dashboard/server.py" --runs "$RUNS" --vm-root "$FACTORY_VM_ROOT" --port "$port" --name "$DASHBOARD_NAME" \
      > "$log" 2>&1 &
    srv=$!
    trap 'kill $srv 2> /dev/null; rm -f "$log"' EXIT INT TERM
    for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q http "$log" && break; sleep 0.3; done
    url=$(grep -o 'http://[^ ]*' "$log" | head -1)
    [ -n "$url" ] || { cat "$log" >&2; die "the dashboard did not start"; }
    echo "factory dashboard: $url (Ctrl-C stops it)"
    [ "$open_it" = yes ] && open "$url"
    wait $srv ;;
  spec)
    key=${1:-}; [ -n "$key" ] || die "usage: factory.sh spec <KEY> [--open]"
    [ -f "$TICKETS_DIR/$key.md" ] || die "no spec for $key in $TICKETS_DIR"
    echo "$TICKETS_DIR/$key.md"
    [ -f "$TICKETS_DIR/$key.sh" ] && echo "$TICKETS_DIR/$key.sh"
    [ "${2:-}" = --open ] && open "$TICKETS_DIR/$key.md" ;;
  clean)
    key=${1:-}; [ -n "$key" ] || die "usage: factory.sh clean <KEY> [--dry-run]"
    dry=no; [ "${2:-}" = --dry-run ] && dry=yes
    k=$(echo "$key" | tr '[:upper:]' '[:lower:]')
    gone="" busy=""
    for d in "$TICKETS_DIR/$key.md" "$TICKETS_DIR/$key.sh" "$TICKETS_DIR/$key.assessment.md" "$TICKETS_DIR/$key.assessment.md.prev" "$TICKETS_DIR/$key.fixtures" "$RUNS/$k"-*; do
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
  *) sed -n '2,31p' "$0"; exit 2 ;;
esac
