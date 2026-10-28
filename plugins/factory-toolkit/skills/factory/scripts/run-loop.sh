#!/bin/bash
# run-loop.sh: one factory loop for one ticket, adapted from the training's long-run loop.sh.
#   builder (headless claude, own worktree) -> runner verify (its own checks) -> reviewer (fresh read-only session)
#   -> runtime QA (throwaway VM, blind QA agent) -> send back with the reason, up to ITER_CAP builder runs
#   -> hand-back. Optional --open-pr pushes a draft PR.
# Nothing builds on the Mac: one build VM per run (a clone of the target's image, sharing the run's worktree) serves the
# builder's guest tool and the runner's verify; each QA round gets a fresh clone that launches the verified binaries.
# Usage (from the repo):
#   run-loop.sh <TICKET> [--open-pr] [--qa | --no-qa] [--keep-vm]   the loop; QA runs when the ticket has a Runtime check;
#                                                                    --keep-vm leaves the last QA VM running (factory.sh down)
#   run-loop.sh <TICKET> --qa-only <ref> [--keep-vm]                 the QA stage alone on <ref> (red-on-base check)
#   run-loop.sh <TICKET> --test-only <ref>                           the acceptance test alone on <ref>, in a build VM
#   run-loop.sh <TICKET> --resume <run branch> "<judge's reason>"     a judge's send back on a finished run: merges the
#                                                                    ticket branch (the updated spec) into the run branch,
#                                                                    then the loop continues in that run's worktree
#   run-loop.sh <TICKET> --continue <run branch> "<why>"            the same after the runner stopped for a human who
#                                                                    sends it on: no Decision line, the reason goes as is
# Any time: touch <run dir>/STOP (stops before the next station), touch <run dir>/HUMAN (a human judges the next QA).
# Config: <repo>/.factory (FACTORY_DIR): config.sh, tickets/<TICKET>.md + .sh, profiles/<profile>/ (see lib/config.sh).
# bash 3.2 compatible (macOS default): no associative arrays, no ${x,,}.
set -u
# One block: bash parses it whole before running it, so editing this file during a run can't break that run.
{

usage() { sed -n '8,18p' "$0" >&2; exit 2; }
TICKET=${1:-}
[ -n "$TICKET" ] && [ "${TICKET#-}" = "$TICKET" ] || usage
shift
OPEN_PR=no QA=auto KEEP_VM=no QA_ONLY="" TEST_ONLY="" RESUME="" JUDGE_REASON="" CONTINUE=no
while [ $# -gt 0 ]; do
  case "$1" in
    --open-pr) OPEN_PR=yes ;;
    --qa) QA=yes ;;
    --no-qa) QA=no ;;
    --keep-vm) KEEP_VM=yes ;;
    --qa-only) QA_ONLY=${2:-}; [ -n "$QA_ONLY" ] || usage; shift ;;
    --test-only) TEST_ONLY=${2:-}; [ -n "$TEST_ONLY" ] || usage; shift ;;
    --resume) RESUME=${2:-} JUDGE_REASON=${3:-}; [ -n "$RESUME" ] && [ -n "$JUDGE_REASON" ] || usage; shift 2 ;;
    --continue) RESUME=${2:-} JUDGE_REASON=${3:-} CONTINUE=yes; [ -n "$RESUME" ] && [ -n "$JUDGE_REASON" ] || usage; shift 2 ;;
    *) usage ;;
  esac
  shift
done

X=$(cd "$(dirname "$0")" && pwd)
VM=$X/vm
# The repo is the one the command runs from: the engine is installed apart from it (a plugin), never inside it.
REPO=$(git rev-parse --show-toplevel 2> /dev/null) || { echo "factory: run this from inside the repo (no git repo here)" >&2; exit 2; }
SKILL=$(cd "$X/.." && pwd)
case "$SKILL/" in "$REPO"/*) SKILL_REL=${SKILL#$REPO/} SKILL_IN_REPO=$SKILL_REL ;; *) SKILL_REL=$SKILL SKILL_IN_REPO="" ;; esac
. "$X/lib/config.sh" || exit 2
. "$X/lib/timebox.sh"
TICKET_FILE=$FACTORY_DIR/tickets/$TICKET.md
[ -f "$TICKET_FILE" ] || { echo "no ticket file $FACTORY_DIR_REL/tickets/$TICKET.md" >&2; exit 2; }
[ -n "$PROFILE" ] || { echo "no ticket inputs $FACTORY_DIR_REL/tickets/$TICKET.sh (PROFILE, ACCEPT_TEST, ORACLE_PATHS, SCOPE_REGEX)" >&2; exit 2; }

for c in claude git jq perl python3; do
  command -v "$c" > /dev/null || { echo "run-loop.sh needs $c on the PATH" >&2; exit 2; }
done
if [ -n "$(git -C "$REPO" status --porcelain -- "$FACTORY_DIR_REL" $SKILL_IN_REPO $ORACLE_PATHS)" ]; then
  echo "commit the loop kit, the ticket and the acceptance tests first: the worktree is cut from HEAD" >&2; exit 2
fi

# Every build and test runs in the guest, so every mode needs the target's image and scripts.
[ -f "$FACTORY_VM_HOME/$GOLDEN_IMAGE" ] && command -v qemu-system-aarch64 > /dev/null \
  || { echo "no $GOLDEN_IMAGE in $FACTORY_VM_HOME (or no QEMU): see $SKILL_REL/references/vm-setup.md" >&2; exit 2; }
[ -n "${GUEST_BUILD:-}" ] && [ -n "${GUEST_TEST:-}" ] || { echo "profile $PROFILE, target '$PLATFORM': no GUEST_BUILD/GUEST_TEST" >&2; exit 2; }
[ -n "${ACCEPT_TEST:-}" ] || { echo "no ACCEPT_TEST in $FACTORY_DIR_REL/tickets/$TICKET.sh" >&2; exit 2; }
grep -q '^## Runtime check' "$TICKET_FILE" && HAS_RC=yes || HAS_RC=no
[ "$QA" = auto ] && QA=$HAS_RC
[ -n "$QA_ONLY" ] && QA=yes
[ -n "$TEST_ONLY" ] && QA=no
if [ "$QA" = yes ]; then
  [ "$HAS_RC" = yes ] || { echo "the ticket has no '## Runtime check' section" >&2; exit 2; }
  [ -n "${GUEST_LAUNCH:-}" ] || { echo "profile $PROFILE, target '$PLATFORM': no GUEST_LAUNCH" >&2; exit 2; }
fi

T=$(echo "$TICKET" | tr '[:upper:]' '[:lower:]')
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
ID=$T-$STAMP
[ -n "$QA_ONLY" ] && ID=$T-qa-$STAMP
[ -n "$TEST_ONLY" ] && ID=$T-test-$STAMP
# mkdir is atomic: two runs started in the same second get distinct ids (-2, -3, …).
mkdir -p "$FACTORY_RUNS"
i=1; base_id=$ID
until mkdir "$FACTORY_RUNS/$ID" 2> /dev/null; do i=$((i + 1)); ID=$base_id-$i; STAMP=${STAMP%%-*}-$i; done
RUN=$FACTORY_RUNS/$ID
# VM disks and the QA agent's folder live outside the repo: the QA agent must not find CLAUDE.md or the source above it.
QA_ROOT=$FACTORY_VM_HOME/runs/$ID
BRANCH=$BRANCH_PREFIX$T-build-$STAMP
WT=$MAIN_REPO/.claude/worktrees/$T-build-$STAMP
if [ -n "$RESUME" ]; then
  BRANCH=$RESUME
  WT=$(git -C "$REPO" worktree list --porcelain | awk -v b="branch refs/heads/$RESUME" '/^worktree /{w=substr($0,10)} $0==b{print w}')
  [ -n "$WT" ] || { echo "no worktree has branch $RESUME checked out" >&2; rmdir "$RUN"; exit 2; }
  [ -z "$(git -C "$WT" status --porcelain)" ] || { echo "$WT has uncommitted changes" >&2; rmdir "$RUN"; exit 2; }
fi
HANDBACK=handback/$(echo "$BRANCH" | tr '/' '-')
BASE=$(git -C "$REPO" rev-parse --short HEAD)
# The run's build VM, and the tool the builder and the reviewer call to build and test in it (scripts/guest.sh).
BUILD_VM=$QA_ROOT/vm-build
GUEST=$RUN/guest
ACCEPT_CMD="$GUEST test $ACCEPT_TEST${ACCEPT_FILTER:+ $ACCEPT_FILTER}"
EV=$RUN/events.log
RUNS=$RUN/runs.md
SPENT=0
STATUS="not started"

ev() { echo "$(date -u +%FT%TZ) $*" | tee -a "$EV"; }
# A host sleep freezes the VMs and every station waits on them (GAPS V43): keep the Mac awake while this runner lives.
# -s only holds on AC power; a lid closed on battery still sleeps the Mac, so say so up front.
caffeinate -ims -w $$ 2> /dev/null &
pmset -g batt 2> /dev/null | grep -q "AC Power" \
  || echo "warning: on battery: the Mac will sleep if its lid closes, and the run then stalls until it wakes" >&2
add_usd() { SPENT=$(python3 -c "print(round($SPENT + ${1:-0}, 4))"); }
over() { python3 -c "import sys; sys.exit(0 if $1 > $2 else 1)"; }
fill() { # fill <template file>: substitutes the @NAME@ placeholders
  sed -e "s|@TICKET@|$TICKET|g" -e "s|@BRANCH@|$BRANCH|g" -e "s|@BASE@|$BASE|g" -e "s|@HANDBACK@|$HANDBACK|g" \
      -e "s|@GUEST@|$GUEST|g" -e "s|@ACCEPT@|$(echo "$ACCEPT_CMD" | sed 's/[|&\\]/\\&/g')|g" -e "s|@FACTORY@|$FACTORY_DIR_REL|g" \
      -e "s|@TEMPLATES@|$SKILL_REL/templates|g" -e "s|@VM@|$VM|g" -e "s|@APP@|$APP_NAME|g" \
      -e "s|@GUEST_DESC@|${GUEST_DESC:-}|g" -e "s|@XRES@|$VM_XRES|g" -e "s|@YRES@|$VM_YRES|g" \
      -e "s|@STANDARDS@|${REVIEW_STANDARDS:-none}|g" "$1"
}
section() { # section <file> <heading>: the body of one "## <heading>" section
  awk -v h="## $2" '$0 == h { on = 1; next } /^## / { on = 0 } on' "$1"
}

# run_claude <name> <minutes> <dir> <claude args...>: one headless run in <dir>, time-boxed; writes <name>.json.
run_claude() {
  local name=$1 mins=$2 dir=$3; shift 3
  local t0 t1 rc
  t0=$(date +%s)
  ev "start $name (time box $mins min)"
  ( cd "$dir" && timebox $((mins * 60)) claude "$@" > "$RUN/$name.json" 2> "$RUN/$name.err" < /dev/null )
  rc=$?
  t1=$(date +%s)
  echo "$t0 $t1 $rc" > "$RUN/$name.time"
  ev "end $name exit=$rc after $((t1 - t0)) s"
}

# fields <json>: subtype turns cost denials
fields() {
  if [ -s "$1" ] && jq -e . "$1" > /dev/null 2>&1; then
    jq -r '[.subtype // "unknown", (.num_turns // "unknown"|tostring), (.total_cost_usd // 0|tostring), ((.permission_denials // [])|length|tostring)] | join(" ")' "$1"
  else
    echo "unknown unknown 0 unknown"
  fi
}

row() { # row <run> <role> <name> <outcome>
  local t0 t1 rc st tu co de
  read -r t0 t1 rc < "$RUN/$3.time"
  read -r st tu co de <<< "$(fields "$RUN/$3.json")"
  echo "| $1 | $2 | $(python3 -c "print(round(($t1-$t0)/60,1))") | $st | $tu | $co | $de | $4 |" >> "$RUNS"
  add_usd "$co"
}

# verify <n>: the runner's own checks, never the agent's word. Echoes "green" or "red: <why>".
verify() {
  local out="$RUN/verify-$1.log" rec="$WT/$HANDBACK/verification-record.md" hb="$WT/$HANDBACK/hand-back.md"
  local sha later touched outside c rc
  : > "$out"
  [ -f "$rec" ] || { echo "red: no verification record"; return; }
  [ -f "$hb" ] || { echo "red: no hand-back"; return; }
  sha=$(grep -m1 '^- Commit:' "$rec" | grep -oE '@ *[0-9a-f]{7,40}' | grep -oE '[0-9a-f]{7,40}')
  [ -n "$sha" ] || { echo "red: record has no Commit SHA"; return; }
  # Not merges, nor what the base brought (a --resume merges the ticket branch in after the record): the builder's only.
  later=$(git -C "$WT" log --oneline --no-merges "$sha..HEAD" "^$BASE" -- . ':(exclude)handback' 2>> "$out")
  [ -z "$later" ] || { echo "red: code commit after the record's Commit line"; return; }
  grep -qE '^- Verdict: *PASS' "$rec" || { echo "red: record Verdict is not PASS"; return; }
  touched=$(git -C "$WT" diff --name-only "$BASE" HEAD -- $PROTECTED_PATHS)
  [ -z "$touched" ] || { echo "red: protected files changed: $(echo $touched)"; return; }
  outside=$(git -C "$WT" diff --name-only "$BASE" HEAD -- . ':(exclude)handback' | grep -vE "$SCOPE_REGEX")
  [ -z "$outside" ] || { echo "red: files outside the ticket scope: $(echo $outside)"; return; }
  [ -n "$(git -C "$WT" diff --name-only "$BASE" HEAD -- . ':(exclude)handback')" ] || { echo "red: no code change"; return; }
  [ -z "$(git -C "$WT" status --porcelain)" ] || { echo "red: uncommitted changes left in the worktree"; return; }
  # The target's whole build, in the build VM. Output left from an earlier build can break an incremental one (GAPS
  # V28): a red build gets one clean rebuild before it counts against the change.
  "$GUEST" build >> "$out" 2>&1
  rc=$?
  if [ $rc -eq 1 ]; then
    echo "== red: one clean rebuild" >> "$out"
    "$GUEST" build --clean >> "$out" 2>&1
    rc=$?
  fi
  cp "$BUILD_VM/build.log" "$RUN/verify-$1-build.log" 2> /dev/null
  case $rc in
    0) ;;
    1) echo "red: the $GUEST_DESC build fails: $(first_errors "$out")"; return ;;
    *) echo "error: guest build: $(harness_why "$out")"; return ;;
  esac
  : > "$out.test"
  $ACCEPT_CMD >> "$out.test" 2>&1
  rc=$?
  cat "$out.test" >> "$out"
  cp "$BUILD_VM/test.log" "$RUN/verify-$1-test.log" 2> /dev/null
  case $rc in
    0) echo green ;;
    1) echo "red: the acceptance test fails in the guest: $(first_errors "$out.test")" ;;
    *) echo "error: guest test: $(harness_why "$out.test")" ;;
  esac
  rm -f "$out.test"
}

harness_why() { # harness_why <guest.sh output>: its HARNESS ERROR line, else its last line
  grep -m1 'HARNESS ERROR' "$1" || grep -v '^[[:space:]]*$' "$1" | tail -1
}

first_errors() { # first_errors <guest.sh output>: three error or failed-test lines, on one line
  grep -E ': error |^ *Failed [^!]' "$1" | awk '!seen[$0]++' | head -3 | tr '\n' ' '
}

# guest_conf <vm run dir> <worktree>: what scripts/guest.sh needs to build and test in that VM
guest_conf() {
  printf "WORKTREE='%s'\nGUEST_BUILD='%s'\nGUEST_TEST='%s'\nGUEST_BUILD_MIN=%s\n" \
    "$2" "$GUEST_BUILD" "$GUEST_TEST" "$GUEST_BUILD_MIN" > "$1/guest.conf"
}

# build_vm_up <worktree>: boots the run's build VM sharing <worktree> and writes the guest tool; on failure the reason is
# the last line of $RUN/build-vm.log. The VM is powered off when the runner exits.
build_vm_up() {
  ev "build VM up from $GOLDEN_IMAGE, sharing ${1#$MAIN_REPO/}"
  trap '"$VM/vmctl.sh" down "$BUILD_VM" >> "$EV" 2>&1' EXIT
  "$VM/vmctl.sh" up "$BUILD_VM" "$1" > "$RUN/build-vm.log" 2>&1 || return 1
  guest_conf "$BUILD_VM" "$1"
  printf '#!/bin/bash\n# Builds and tests this run'"'"'s worktree in its build VM: build [<project>] [--clean] | test <project> [<filter>] | info\nexec "%s" "%s" "$@"\n' \
    "$X/guest.sh" "$BUILD_VM" > "$GUEST"
  chmod +x "$GUEST"
}

# write_section <heading> <body file>: the runner, not the agents, writes the Review and Runtime check sections.
write_section() {
  python3 - "$WT/$HANDBACK/hand-back.md" "$1" "$2" <<'PY'
import re, sys
hb_path, heading, body_path = sys.argv[1], sys.argv[2], sys.argv[3]
hb = open(hb_path).read()
start = hb.index("## " + heading)
end = hb.index("\n## ", start + 1) + 1
section = hb[start:end]
comment = re.search(r"<!--.*?-->", section, re.S)
body = "## " + heading + "\n" + (comment.group(0) + "\n" if comment else "")
body += open(body_path).read().rstrip("\n") + "\n\n"
open(hb_path, "w").write(hb[:start] + body + hb[end:])
PY
}

notify() { osascript -e "display notification \"$1\" with title \"Factory $TICKET\"" > /dev/null 2>&1; printf '\a'; ev "notify: $1"; }

# release_kept_vms: power off the VMs an earlier QA round of this run kept (--keep-vm), and remove the worktrees they
# had of their own. A kept VM running the app holds its files on the share, so the next build must not start before.
release_kept_vms() {
  local k
  for k in "$QA_ROOT"/vm-*/factory-kept; do
    [ -f "$k" ] || continue
    "$VM/vmctl.sh" down "$(dirname "$k")" >> "$EV" 2>&1
    [ -s "$k" ] && git -C "$REPO" worktree remove --force "$(cat "$k")" 2>> "$EV"
    rm -f "$k"
  done
}

# qa_stage <n> <commit> [<built worktree>]: launch the app in a throwaway VM, let the blind QA agent check the ticket's
# Runtime check, then hand the screen to a human if asked. With <built worktree> (the loop), the clone shares that
# worktree and launches what verify built there; without it (--qa-only), the stage cuts its own worktree and builds it in
# the clone first. Sets QA_VERDICT to "PASS: …", "FAIL: …", "NEEDS-HUMAN: …" or "ERROR: …" (ERROR = the harness
# failed, not the change) and copies the report and screenshots to $RUN/qa-<n>/.
qa_stage() {
  local n=$1 ref=$2 built=${3:-}
  local q="$QA_ROOT/qa-$n" vmrun="$QA_ROOT/vm-$n" qwt="" share rc v waited
  QA_VERDICT=""
  release_kept_vms
  mkdir -p "$q" "$RUN/qa-$n"
  if [ -n "$built" ]; then
    share=$built
  else
    qwt="$MAIN_REPO/.claude/worktrees/$T-qa-$STAMP-$n"
    git -C "$REPO" worktree add -q --detach "$qwt" "$ref" 2>> "$EV" || { QA_VERDICT="ERROR: QA worktree add failed"; return; }
    share=$qwt
  fi
  ev "qa-$n: VM up, sharing ${share#$MAIN_REPO/} at $ref"
  if ! "$VM/vmctl.sh" up "$vmrun" "$share" > "$RUN/qa-$n/vm.log" 2>&1; then
    QA_VERDICT="ERROR: VM did not come up: $(tail -1 "$RUN/qa-$n/vm.log")"
  else
    eval "$("$VM/vmctl.sh" env "$vmrun")"
    rc=0
    if [ -z "$built" ]; then
      ev "qa-$n: guest build (time box $GUEST_BUILD_MIN min)"
      guest_conf "$vmrun" "$share"
      "$X/guest.sh" "$vmrun" build > "$RUN/qa-$n/guest-build.log" 2>&1
      rc=$?
      cp "$vmrun/build.log" "$RUN/qa-$n/guest-build-full.log" 2> /dev/null
    fi
    if [ $rc -eq 1 ]; then
      QA_VERDICT="FAIL: the $GUEST_DESC build fails: $(first_errors "$RUN/qa-$n/guest-build.log")"
    elif [ $rc -ne 0 ]; then
      QA_VERDICT="ERROR: guest build: $(harness_why "$RUN/qa-$n/guest-build.log")"
    elif ! "$VM/vmssh" - < "$GUEST_LAUNCH" > "$RUN/qa-$n/launch.log" 2>&1 || ! grep -q '^LAUNCH OK' "$RUN/qa-$n/launch.log"; then
      QA_VERDICT="ERROR: $APP_NAME did not start in the guest: $(tail -1 "$RUN/qa-$n/launch.log")"
    else
      { fill "$SKILL/prompts/qa.txt" | sed -e "s|@QA_DIR@|$q|g" -e "s|@SHA@|$ref|g"; echo; section "$TICKET_FILE" "Runtime check"
        [ -n "$built" ] && disputes_for_qa; } > "$RUN/qa-$n.prompt"
      run_claude "qa-$n" "$QA_MIN" "$q" -p "$(cat "$RUN/qa-$n.prompt")" --model "$QA_MODEL" --max-budget-usd "$QA_USD" \
        --append-system-prompt "$(awk 'f > 1; /^---$/ { f++ }' "$SKILL/agents/factory-qa.md")" \
        --tools Read Bash --allowedTools "${QA_TOOLS[@]}" --output-format json
      jq -r '.result // ""' "$RUN/qa-$n.json" > "$q/report.md" 2> /dev/null
      v=$(grep -m1 '^Verdict:' "$q/report.md" | sed -E 's/^Verdict: *//')
      case "$v" in
        PASS*) QA_VERDICT="PASS: $(grep -m1 '^Summary:' "$q/report.md" | sed 's/^Summary: *//')" ;;
        FAIL*) QA_VERDICT="FAIL: $(grep -m1 '^Summary:' "$q/report.md" | sed 's/^Summary: *//')" ;;
        NEEDS-HUMAN*) QA_VERDICT="NEEDS-HUMAN: $(grep -m1 '^Human:' "$q/report.md" | sed 's/^Human: *//')" ;;
        *) QA_VERDICT="ERROR: no usable QA report (qa-$n.json)" ;;
      esac
      row "$n" qa "qa-$n" "$QA_VERDICT"
    fi

    if [ "${QA_VERDICT#ERROR}" = "$QA_VERDICT" ] && { [ "${QA_VERDICT#NEEDS-HUMAN}" != "$QA_VERDICT" ] || [ -e "$RUN/HUMAN" ]; }; then
      rm -f "$RUN/HUMAN"
      echo "$vmrun" > "$RUN/WAITING-FOR-HUMAN"
      notify "QA needs you: ${QA_VERDICT#*: }"
      "$VM/vmctl.sh" show "$vmrun" >> "$EV" 2>&1
      ev "qa-$n: waiting up to $HUMAN_WAIT_MIN min for $RUN/HUMAN-VERDICT ('pass: <why>' or 'fail: <why>')"
      waited=0
      while [ ! -s "$RUN/HUMAN-VERDICT" ] && [ "$waited" -lt $((HUMAN_WAIT_MIN * 60)) ] && [ ! -e "$RUN/STOP" ]; do
        sleep 10; waited=$((waited + 10))
      done
      rm -f "$RUN/WAITING-FOR-HUMAN"
      v=$(head -1 "$RUN/HUMAN-VERDICT" 2> /dev/null)
      rm -f "$RUN/HUMAN-VERDICT"
      case "$v" in
        pass*) QA_VERDICT="PASS: human: ${v#*: }" ;;
        fail*) QA_VERDICT="FAIL: human: ${v#*: }" ;;
        *) QA_VERDICT="NEEDS-HUMAN: no human verdict after $HUMAN_WAIT_MIN min" ;;
      esac
      { echo; echo "Human verdict: ${v:-none}"; } >> "$q/report.md"
    fi
  fi
  ev "qa-$n: $QA_VERDICT"
  cp "$q"/*.png "$q/report.md" "$RUN/qa-$n/" 2> /dev/null
  # --keep-vm leaves the VM running whatever the verdict (a PASS is what a judge wants to look at) until factory.sh down.
  if [ "$KEEP_VM" = yes ] && "$VM/vmctl.sh" env "$vmrun" > /dev/null 2>&1; then
    printf '%s' "$qwt" > "$vmrun/factory-kept"
    ev "qa-$n: VM left running: factory.sh show $ID, then factory.sh down $ID"
  else
    "$VM/vmctl.sh" down "$vmrun" >> "$EV" 2>&1
    [ -n "$qwt" ] && git -C "$REPO" worktree remove --force "$qwt" 2>> "$EV"
  fi
}

# disputes <field>: the builder's disputed expectations (handback/disputes.md), each heading with one field's lines
disputes() {
  local f="$WT/$HANDBACK/disputes.md"
  [ -s "$f" ] && awk -v k="- $1:" '/^## / { print; next } index($0, k) == 1 { print }' "$f"
}

# disputes_for_qa: the "Disputed expectations" part of a QA prompt. Only the behaviour the builder says is intended
# reaches the blind QA agent, never its reasons or evidence (those are for the human judge).
disputes_for_qa() {
  local d
  d=$(disputes "Expected instead" | sed 's/^## /### /') || return 0
  printf '\n## Disputed expectations\nThe builder says the app is designed to behave as described below, so for these expectations the Runtime check expects the wrong thing. Check both, report each as `disputed: <what you saw for both>`; a disputed expectation alone does not make the verdict FAIL.\n%s\n' "$d"
}

# disputed_ids: the disputed expectations' headings on one line, or "none"
disputed_ids() {
  local d
  d=$(disputes "none-such" | sed 's/^## *//' | paste -sd ';' -)
  echo "${d:-none}"
}

# write_qa <n>: Runtime check section of the hand-back + evidence under handback/, committed by the runner.
write_qa() {
  local n=$1 d
  local dir="$WT/$HANDBACK/qa-$n"
  mkdir -p "$dir"
  cp "$RUN/qa-$n"/*.png "$RUN/qa-$n/report.md" "$dir/" 2> /dev/null
  {
    echo "- QA: Claude Code, $QA_MODEL, blind; throwaway $GUEST_DESC VM; the verified Debug build of $(git -C "$WT" rev-parse --short HEAD)"
    echo "- Verdict: $QA_VERDICT"
    d=$(disputed_ids)
    [ "$d" = none ] && echo "- Disputed by the builder: none" \
      || echo "- Disputed by the builder: $d; reasons for the judge: \`$HANDBACK/disputes.md\`"
    echo "- Report: \`$HANDBACK/qa-$n/report.md\`; evidence: $(cd "$dir" && ls *.png 2> /dev/null | tr '\n' ' ')"
  } > "$RUN/qa-$n/section.md"
  write_section "Runtime check (QA)" "$RUN/qa-$n/section.md"
  git -C "$WT" add "$HANDBACK"
  git -C "$WT" commit -q -m "handback: $TICKET runtime check $n"
}

finish() {
  ev "end: $STATUS · spent \$$SPENT"
  rmdir "$QA_ROOT" 2> /dev/null
  exit 0
}

if [ -n "$QA_ONLY" ]; then
  REF=$(git -C "$REPO" rev-parse --verify "$QA_ONLY^{commit}") || { echo "unknown ref $QA_ONLY" >&2; exit 2; }
  printf '# QA only · %s · %s\nRef: %s\n\n| Run | Role | Min | subtype | Turns | Cost $ | Denials | Outcome |\n|---|---|---|---|---|---|---|---|\n' \
    "$TICKET" "$STAMP" "$REF" > "$RUNS"
  ev "qa only: $TICKET on $REF"
  qa_stage 1 "$REF"
  STATUS=$QA_VERDICT
  echo "Report: $RUN/qa-1/report.md · run log: $RUNS"
  finish
fi

# --test-only: the ticket's acceptance test on <ref> in a build VM, e.g. to prove an oracle red on the base commit.
if [ -n "$TEST_ONLY" ]; then
  REF=$(git -C "$REPO" rev-parse --verify "$TEST_ONLY^{commit}") || { echo "unknown ref $TEST_ONLY" >&2; exit 2; }
  twt=$MAIN_REPO/.claude/worktrees/$T-test-$STAMP
  printf '# Test only · %s · %s\nRef: %s\n' "$TICKET" "$STAMP" "$REF" > "$RUNS"
  git -C "$REPO" worktree add -q --detach "$twt" "$REF" || { echo "worktree add failed" >&2; exit 1; }
  if build_vm_up "$twt"; then
    ev "test only: $ACCEPT_CMD"
    $ACCEPT_CMD > "$RUN/test.out" 2>&1
    rc=$?
    cp "$BUILD_VM/test.log" "$RUN/test.log" 2> /dev/null
    case $rc in
      0) STATUS="green: the acceptance test passes on ${REF:0:11}" ;;
      1) STATUS="red: the acceptance test fails on ${REF:0:11}: $(first_errors "$RUN/test.out")" ;;
      *) STATUS="error: $(harness_why "$RUN/test.out")" ;;
    esac
    "$VM/vmctl.sh" down "$BUILD_VM" >> "$EV" 2>&1
  else
    STATUS="error: build VM did not come up: $(tail -1 "$RUN/build-vm.log")"
  fi
  git -C "$REPO" worktree remove --force "$twt" 2>> "$EV"
  echo "$STATUS"
  echo "Output: $RUN/test.out · full log: $RUN/test.log"
  finish
fi

cat > "$RUNS" <<EOF
# Loop runs · $TICKET · $STAMP
Base: $BASE · branch: $BRANCH · builder: $B_MODEL (\$$B_USD, $B_MIN min) · reviewer: $R_MODEL (\$$R_USD, $R_MIN min) · QA: $([ "$QA" = yes ] && echo "$QA_MODEL (\$$QA_USD, $QA_MIN min)" || echo off) · iteration cap $ITER_CAP · loop \$$LOOP_USD

| Run | Role | Min | subtype | Turns | Cost \$ | Denials | Outcome |
|---|---|---|---|---|---|---|---|
EOF

# The builder's deny rules: every protected path (a folder denies everything under it) plus the outward-facing commands.
for p in $PROTECTED_PATHS; do
  [ -d "$REPO/$p" ] && p="$p/**"
  printf '"Edit(%s)"\n"Write(%s)"\n' "$p" "$p"
done | { cat; printf '"%s"\n' "${DENY_BASH[@]}"; } | jq -s '{permissions: {deny: .}}' > "$RUN/builder-settings.json"

builds=0
reason=""
if [ -n "$RESUME" ]; then
  # The judge's send back: the ticket branch (its updated spec) merges in, the Decision goes in the Judge section, and
  # rounds go on from the last one so qa-<n> folders don't collide. The iteration cap counts this run's rounds only.
  ev "loop resume: $TICKET on $BRANCH (worktree ${WT#$REPO/}), merging $BASE; judge: $JUDGE_REASON"
  git -C "$WT" merge -q --no-edit "$BASE" || { git -C "$WT" merge --abort; echo "merging $BASE into $BRANCH conflicts" >&2; exit 1; }
  [ "$CONTINUE" = yes ] || python3 - "$WT/$HANDBACK/hand-back.md" "$JUDGE_REASON, $(git config user.name), $(date +%F)" <<'PY'
import re, sys
p, why = sys.argv[1], sys.argv[2]
hb = open(p).read()
hb = re.sub(r"^Decision: .*$", lambda m: "Decision: send back: " + why, hb, count=1, flags=re.M)
open(p, "w").write(hb)
PY
  [ "$CONTINUE" = yes ] || git -C "$WT" commit -q -am "handback: $TICKET judge sent back"
  builds=$(ls -d "$WT/$HANDBACK"/qa-* 2> /dev/null | sed 's/.*qa-//' | sort -n | tail -1)
  builds=${builds:-0}
  reason="the human judge sent it back: $JUDGE_REASON. The ticket's spec was updated for it (merged into this branch)."
  [ "$CONTINUE" = yes ] && reason="the runner stopped this run for a human, who sends it on: $JUDGE_REASON"
else
  ev "loop start: $TICKET base $BASE worktree ${WT#$REPO/} qa=$QA"
  git -C "$REPO" worktree add -q -b "$BRANCH" "$WT" "$BASE" || { echo "worktree add failed" >&2; exit 1; }
fi
FIRST=$builds
vm_up=yes
build_vm_up "$WT" || { vm_up=no; STATUS="harness error: the build VM did not come up: $(tail -1 "$RUN/build-vm.log")"; }
BUILD_TOOLS+=("Bash($GUEST *)")
REVIEW_TOOLS+=("Bash($GUEST test *)")
while [ "$vm_up" = yes ]; do
  release_kept_vms
  if [ $((builds - FIRST)) -ge "$ITER_CAP" ]; then STATUS="reject: iteration cap ($ITER_CAP builder runs); last reason: $reason"; break; fi
  if [ -e "$RUN/STOP" ]; then STATUS="stopped: STOP file"; break; fi
  if over "$SPENT + $B_USD" "$LOOP_USD"; then STATUS="stopped: loop budget (\$$SPENT spent)"; break; fi
  builds=$((builds + 1))
  name=build-$builds
  fill "$SKILL/prompts/goal.txt" > "$RUN/$name.prompt"
  if [ -n "$reason" ]; then
    { fill "$SKILL/prompts/fix.txt" | sed "s|@REASON@|$(echo "$reason" | sed 's/[|&\\]/\\&/g')|"; cat "$RUN/$name.prompt"; } > "$RUN/$name.prompt.tmp"
    mv "$RUN/$name.prompt.tmp" "$RUN/$name.prompt"
  fi
  run_claude "$name" "$B_MIN" "$WT" -p "$(cat "$RUN/$name.prompt")" --model "$B_MODEL" --max-budget-usd "$B_USD" \
    --permission-mode acceptEdits --settings "$RUN/builder-settings.json" --add-dir "$SKILL/templates" \
    --allowedTools "${BUILD_TOOLS[@]}" --output-format json
  read -r st _ _ _ <<< "$(fields "$RUN/$name.json")"
  read -r _ _ rc < "$RUN/$name.time"
  case "$rc/$st" in
    142/*) out="time box" ;;
    */success) out="success" ;;
    */error_max_budget_usd) out="cap: dollars" ;;
    *) out="error: $st (exit $rc)" ;;
  esac
  v=$(verify "$builds")
  row "$builds" builder "$name" "$out; verify $v"
  ev "$name outcome=$out verify=$v spent=\$$SPENT"
  code=$(git -C "$WT" log -1 --format=%H -- . ':(exclude)handback')
  dsum=$(cat "$WT/$HANDBACK/disputes.md" 2> /dev/null | git hash-object --stdin)
  # A review finding can be about the record alone (a missing negative run): there, a new record is progress too.
  [ "${from:-}" = review ] && dsum=$dsum$(cat "$WT/$HANDBACK/verification-record.md" 2> /dev/null | git hash-object --stdin)
  # After a green verify the send back came from the reviewer or QA: a run that changes no code and disputes nothing
  # only sends the same binaries back. After a red verify, fixing the record alone is progress.
  if [ "$v" = green ] && [ "${last_v:-}" = green ] && [ "$code" = "${last_code:-}" ] && [ "$dsum" = "${last_dsum:-}" ]; then
    STATUS="needs a human: send back $builds changed no code and disputed nothing (${reason})"; break
  fi
  last_code=$code last_dsum=$dsum last_v=$v
  case "$v" in
    green) ;;
    error*) STATUS="harness error in verify: ${v#error: }"; break ;;
    *) reason="builder run $builds: $out; runner verify $v"; from=verify; STATUS="send back: $reason"; continue ;;
  esac

  if [ -e "$RUN/STOP" ]; then STATUS="stopped: STOP file (verified, not reviewed)"; break; fi
  if over "$SPENT + $R_USD" "$LOOP_USD"; then STATUS="verified, not reviewed (loop budget)"; break; fi
  rname=review-$builds
  fill "$SKILL/prompts/review.txt" > "$RUN/$rname.prompt"
  run_claude "$rname" "$R_MIN" "$WT" -p "$(cat "$RUN/$rname.prompt")" --model "$R_MODEL" \
    --append-system-prompt "$(awk 'f > 1; /^---$/ { f++ }' "$SKILL/agents/factory-reviewer.md")" \
    --max-budget-usd "$R_USD" --tools Read Grep Glob Bash --allowedTools "${REVIEW_TOOLS[@]}" --disallowedTools Edit Write \
    --output-format json
  jq -r '.result // ""' "$RUN/$rname.json" > "$RUN/$rname.md" 2> /dev/null
  rec=$(grep -m1 '^- Recommend:' "$RUN/$rname.md" | sed 's/^- Recommend: *//')
  if [ -z "$rec" ]; then
    row "$builds" reviewer "$rname" "no usable review output"
    STATUS="verified, review missing"; break
  fi
  { grep '^- ' "$RUN/$rname.md"; echo "- Written back to the harness: none"; } > "$RUN/$rname.section.md"
  write_section "Review (reviewer)" "$RUN/$rname.section.md"
  git -C "$WT" add "$HANDBACK/hand-back.md"
  git -C "$WT" commit -q -m "handback: $TICKET review"
  row "$builds" reviewer "$rname" "Recommend: $rec"
  ev "$rname recommend='$rec' spent=\$$SPENT"
  case "$rec" in
    merge*) ;;
    *) reason="review recommended send back: $(grep -m1 '^- Open findings:' "$RUN/$rname.md" | sed 's/^- Open findings: *//')"
       from=review; STATUS="send back: review"; continue ;;
  esac

  if [ "$QA" != yes ]; then STATUS="ready for the judge (Recommend: merge; no runtime QA)"; break; fi
  if [ -e "$RUN/STOP" ]; then STATUS="stopped: STOP file (reviewed, no runtime QA)"; break; fi
  if over "$SPENT + $QA_USD" "$LOOP_USD"; then STATUS="reviewed, no runtime QA (loop budget)"; break; fi
  qa_stage "$builds" "$(git -C "$WT" rev-parse HEAD)" "$WT"
  case "$QA_VERDICT" in
    ERROR*) STATUS="reviewed; runtime QA could not run: ${QA_VERDICT#ERROR: }"; break ;;
  esac
  write_qa "$builds"
  case "$QA_VERDICT" in
    PASS*) d=$(disputed_ids)
           STATUS="ready for the judge (Recommend: merge; runtime QA PASS)"
           [ "$d" != none ] && STATUS="ready for the judge (Recommend: merge; runtime QA PASS, disputed by the builder: $d; the judge decides)"
           break ;;
    NEEDS-HUMAN*) STATUS="reviewed; runtime QA waiting for a human: ${QA_VERDICT#NEEDS-HUMAN: }"; break ;;
    *) reason="runtime check failed (QA run $builds): ${QA_VERDICT#FAIL: }. QA report and screenshots: $HANDBACK/qa-$builds/"
       from=qa; STATUS="send back: runtime QA" ;;
  esac
done

PR_URL="none"
if [ "$OPEN_PR" = yes ] && [ "${STATUS#ready}" != "$STATUS" ]; then
  git -C "$WT" push -q -u origin "$BRANCH" >> "$EV" 2>&1 \
    && PR_URL=$(cd "$WT" && gh pr create --draft --base "$PR_BASE" --head "$BRANCH" \
         --title "[$TICKET] $(head -1 "$TICKET_FILE" | sed -e 's/^# *//' -e "s/^$TICKET *[—-] *//")" \
         --body-file "$WT/$HANDBACK/hand-back.md" 2>> "$EV")
  ev "PR: ${PR_URL:-failed, see events.log}"
fi

{
  echo "# Loop hand-back · $TICKET · $STAMP"
  echo
  echo "- Status: $STATUS"
  echo "- Branch: \`$BRANCH\` (worktree \`${WT#$REPO/}\`) · base $BASE · last commit: $(git -C "$WT" log -1 --format='%h %s')"
  echo "- Builder runs: $((builds - FIRST))$([ -n "$RESUME" ] && echo " (resumed after round $FIRST)") · spent: \$$SPENT of \$$LOOP_USD · PR: $PR_URL"
  echo "- Hand-back for the judge: \`${WT#$REPO/}/$HANDBACK/hand-back.md\`"
  [ -s "$WT/$HANDBACK/disputes.md" ] && echo "- Disputed by the builder (the judge decides): $(disputed_ids); reasons: \`${WT#$REPO/}/$HANDBACK/disputes.md\`"
  echo "- Run log: \`$RUNS\` · events: \`$EV\` · every run's JSON, stderr and prompt: \`$RUN/\`"
} > "$RUN/loop-handback.md"
cat "$RUN/loop-handback.md"
finish
}
