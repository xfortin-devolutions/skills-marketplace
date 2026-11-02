#!/bin/bash
# run-loop.sh: one factory loop for one ticket, adapted from the training's long-run loop.sh.
#   builder (headless claude, own worktree) -> runner verify (its own checks) -> reviewer (fresh read-only session)
#   -> runtime QA (throwaway VM, blind QA agent) -> exploratory QA (charter from the diff, blind explorer, findings
#   re-tried on the base) -> send back with the reason, up to ITER_CAP builder runs -> hand-back. Optional --open-pr
#   pushes a draft PR.
# Nothing builds on the Mac: one build VM per run (a clone of the target's image, sharing the run's worktree) serves the
# builder's guest tool and the runner's verify; each QA round gets a fresh clone that launches the verified binaries.
# Usage (from the repo):
#   run-loop.sh <TICKET> [--open-pr] [--qa | --no-qa] [--no-explore] [--keep-vm]
#                                    the loop; QA runs when the ticket has a Runtime check, exploration after a QA PASS;
#                                    --keep-vm leaves the last QA VM running (factory.sh down)
#   run-loop.sh <TICKET> --qa-only <ref> [--explore [--base <ref>]] [--keep-vm]
#                                    the QA stage alone on <ref> (red-on-base check); --explore adds the exploratory QA,
#                                    the change being <base>..<ref> (default: the merge-base with PR_BASE, else <ref>~1)
#   run-loop.sh <TICKET> --test-only <ref>                           the acceptance test alone on <ref>, in a build VM
#   run-loop.sh <TICKET> --resume <run branch> "<judge's reason>"     a judge's send back on a finished run: merges the
#                                                                    ticket branch (the updated spec) into the run branch,
#                                                                    then the loop continues in that run's worktree
#   run-loop.sh <TICKET> --continue <run branch> "<why>"            the same after the runner stopped for a human who
#                                                                    sends it on: no Decision line, the reason goes as is
#   run-loop.sh <TICKET> --resume-run <run id>                       the same run again, from the station it was paused
#                                                                    or stopped before (factory.sh resume): its state.sh
# Any time: touch <run dir>/STOP (stops before the next station), <run dir>/PAUSE (the same, resumable: factory.sh pause),
# touch <run dir>/HUMAN (a human judges the next QA).
# Config (lib/config.sh): the project (config.sh, profiles/<profile>/), in the skill's projects/ or the repo's .factory/;
# the ticket's spec <TICKET>.md + .sh in ~/.factory/tickets/<repo>/ (TICKETS_DIR), copied into the run at its start.
# bash 3.2 compatible (macOS default): no associative arrays, no ${x,,}.
set -u
# One block: bash parses it whole before running it, so editing this file during a run can't break that run.
{

usage() { sed -n '9,25p' "$0" >&2; exit 2; }
TICKET=${1:-}
[ -n "$TICKET" ] && [ "${TICKET#-}" = "$TICKET" ] || usage
shift
OPEN_PR=no QA=auto KEEP_VM=no QA_ONLY="" TEST_ONLY="" RESUME="" JUDGE_REASON="" CONTINUE=no EXPLORE_CLI="" QA_BASE="" RESUME_RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --open-pr) OPEN_PR=yes ;;
    --qa) QA=yes ;;
    --no-qa) QA=no ;;
    --keep-vm) KEEP_VM=yes ;;
    --explore) EXPLORE_CLI=yes ;;
    --no-explore) EXPLORE_CLI=no ;;
    --base) QA_BASE=${2:-}; [ -n "$QA_BASE" ] || usage; shift ;;
    --qa-only) QA_ONLY=${2:-}; [ -n "$QA_ONLY" ] || usage; shift ;;
    --test-only) TEST_ONLY=${2:-}; [ -n "$TEST_ONLY" ] || usage; shift ;;
    --resume) RESUME=${2:-} JUDGE_REASON=${3:-}; [ -n "$RESUME" ] && [ -n "$JUDGE_REASON" ] || usage; shift 2 ;;
    --continue) RESUME=${2:-} JUDGE_REASON=${3:-} CONTINUE=yes; [ -n "$RESUME" ] && [ -n "$JUDGE_REASON" ] || usage; shift 2 ;;
    --resume-run) RESUME_RUN=${2:-}; [ -n "$RESUME_RUN" ] || usage; shift ;;
    *) usage ;;
  esac
  shift
done

X=$(cd "$(dirname "$0")" && pwd)
# The engine's own tests (tests/run-loop.test.sh) swap the VM layer and the guest tool for fakes.
VM=${FACTORY_VM_DIR:-$X/vm}
GUEST_SH=${FACTORY_GUEST_SH:-$X/guest.sh}
# The repo is the one the command runs from: the engine is installed apart from it (a plugin), never inside it.
REPO=$(git rev-parse --show-toplevel 2> /dev/null) || { echo "factory: run this from inside the repo (no git repo here)" >&2; exit 2; }
SKILL=$(cd "$X/.." && pwd)
case "$SKILL/" in "$REPO"/*) SKILL_REL=${SKILL#$REPO/} SKILL_IN_REPO=$SKILL_REL ;; *) SKILL_REL=$SKILL SKILL_IN_REPO="" ;; esac
. "$X/lib/config.sh" || exit 2
. "$X/lib/timebox.sh"
TICKET_FILE=$TICKETS_DIR/$TICKET.md
[ -f "$TICKET_FILE" ] || { echo "no ticket file $TICKETS_DIR/$TICKET.md" >&2; exit 2; }
[ -n "$PROFILE" ] || { echo "no ticket inputs $TICKETS_DIR/$TICKET.sh (PROFILE, ACCEPT_TEST, ORACLE_PATHS, SCOPE_REGEX)" >&2; exit 2; }

for c in claude git jq perl python3; do
  command -v "$c" > /dev/null || { echo "run-loop.sh needs $c on the PATH" >&2; exit 2; }
done
if [ -n "$(git -C "$REPO" status --porcelain -- "$FACTORY_DIR_REL" $SKILL_IN_REPO $ORACLE_PATHS)" ]; then
  echo "commit the acceptance tests (and the project, when it is in the repo) first: the worktree is cut from HEAD" >&2; exit 2
fi

# Every build and test runs in the guest, so every mode needs the target's image and scripts.
[ -f "$FACTORY_VM_HOME/$GOLDEN_IMAGE" ] && command -v qemu-system-aarch64 > /dev/null \
  || { echo "no $GOLDEN_IMAGE in $FACTORY_VM_HOME (or no QEMU): see $SKILL_REL/references/vm-setup.md" >&2; exit 2; }
[ -n "${GUEST_BUILD:-}" ] && [ -n "${GUEST_TEST:-}" ] || { echo "profile $PROFILE, target '$PLATFORM': no GUEST_BUILD/GUEST_TEST" >&2; exit 2; }
[ -n "${ACCEPT_TEST:-}" ] || { echo "no ACCEPT_TEST in $TICKETS_DIR/$TICKET.sh" >&2; exit 2; }
grep -q '^## Runtime check' "$TICKET_FILE" && HAS_RC=yes || HAS_RC=no
[ "$QA" = auto ] && QA=$HAS_RC
[ -n "$QA_ONLY" ] && QA=yes
[ -n "$TEST_ONLY" ] && QA=no
# Exploration follows a runtime QA PASS: on in the loop (EXPLORE), off in --qa-only unless --explore.
[ -n "$QA_ONLY" ] && EXPLORE=no
[ -n "$EXPLORE_CLI" ] && EXPLORE=$EXPLORE_CLI
[ "$QA" = yes ] || EXPLORE=no
if [ "$QA" = yes ]; then
  [ "$HAS_RC" = yes ] || { echo "the ticket has no '## Runtime check' section" >&2; exit 2; }
  [ -n "${GUEST_LAUNCH:-}" ] || { echo "profile $PROFILE, target '$PLATFORM': no GUEST_LAUNCH" >&2; exit 2; }
fi

T=$(echo "$TICKET" | tr '[:upper:]' '[:lower:]')
SKIP=""
if [ -n "$RESUME_RUN" ]; then
  # The same run again: its folder, worktree, branch, base and loop state come from its state.sh (save_state), and the
  # loop starts at the station it saved. Its spec copy stays the one it started with.
  ID=$RESUME_RUN RUN=$FACTORY_RUNS/$RESUME_RUN
  [ -f "$RUN/state.sh" ] || { echo "no $RUN/state.sh: only a loop run that reached its first station resumes" >&2; exit 2; }
  if [ -s "$RUN/runner.pid" ] && kill -0 "$(cat "$RUN/runner.pid")" 2> /dev/null; then
    echo "$ID is still running (pid $(cat "$RUN/runner.pid")): factory.sh pause it first" >&2; exit 2
  fi
  . "$RUN/state.sh"
  [ "$S_TICKET" = "$TICKET" ] || { echo "$ID is a run of $S_TICKET, not $TICKET" >&2; exit 2; }
  STAMP=$S_STAMP SKIP=$S_NEXT
  rm -f "$RUN/PAUSE" "$RUN/STOP"
else
  STAMP=$(date -u +%Y%m%dT%H%M%SZ)
  ID=$T-$STAMP
  [ -n "$QA_ONLY" ] && ID=$T-qa-$STAMP
  [ -n "$TEST_ONLY" ] && ID=$T-test-$STAMP
  # mkdir is atomic: two runs started in the same second get distinct ids (-2, -3, …).
  mkdir -p "$FACTORY_RUNS"
  i=1; base_id=$ID
  until mkdir "$FACTORY_RUNS/$ID" 2> /dev/null; do i=$((i + 1)); ID=$base_id-$i; STAMP=${STAMP%%-*}-$i; done
  RUN=$FACTORY_RUNS/$ID
fi
# The run's own copy of the spec: what its agents read (a later edit of the ticket doesn't change a run in flight, and a
# --resume takes the updated one), in a folder of its own so they get it and nothing else of the run.
SPEC_DIR=$RUN/spec
[ -n "$RESUME_RUN" ] || { mkdir -p "$SPEC_DIR" && cp "$TICKET_FILE" "$TICKETS_DIR/$TICKET.sh" "$SPEC_DIR/"; }
TICKET_FILE=$SPEC_DIR/$TICKET.md
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
if [ -n "$RESUME_RUN" ]; then
  BRANCH=$S_BRANCH WT=$S_WT QA=$S_QA EXPLORE=$S_EXPLORE KEEP_VM=$S_KEEP_VM OPEN_PR=$S_OPEN_PR
  [ -d "$WT" ] || { echo "the run's worktree $WT is gone" >&2; exit 2; }
fi
HANDBACK=handback/$(echo "$BRANCH" | tr '/' '-')
BASE=$(git -C "$REPO" rev-parse --short HEAD)
[ -n "$RESUME_RUN" ] && BASE=$S_BASE
# The run's build VM, and the tool the builder and the reviewer call to build and test in it (scripts/guest.sh).
BUILD_VM=$QA_ROOT/vm-build
GUEST=$RUN/guest
ACCEPT_CMD="$GUEST test $ACCEPT_TEST${ACCEPT_FILTER:+ $ACCEPT_FILTER}"
EV=$RUN/events.log
RUNS=$RUN/runs.md
SPENT=0
STATUS="not started"
BUILD_VM_UP=no X_STATUS="" X_FINDINGS="" X_NEW="" X_LINES="" RC_STATUS="not needed" CHARTER="" CHARTER_WHY=""
# The charter writer reads the change and builds nothing.
CHARTER_TOOLS=("${REVIEW_TOOLS[@]}")

ev() { echo "$(date -u +%FT%TZ) $*" | tee -a "$EV"; }
# The runner's PID: the dashboard tells a live run from one that died without its end line.
echo $$ > "$RUN/runner.pid"
# A host sleep freezes the VMs and every station waits on them (GAPS V43): keep the Mac awake while this runner lives.
# -s only holds on AC power; a lid closed on battery still sleeps the Mac, so say so up front.
caffeinate -ims -w $$ 2> /dev/null &
pmset -g batt 2> /dev/null | grep -q "AC Power" \
  || echo "warning: on battery: the Mac will sleep if its lid closes, and the run then stalls until it wakes" >&2
add_usd() { SPENT=$(python3 -c "print(round($SPENT + ${1:-0}, 4))"); }
over() { python3 -c "import sys; sys.exit(0 if $1 > $2 else 1)"; }
fill() { # fill <template file>: substitutes the @NAME@ placeholders
  sed -e "s|@TICKET@|$TICKET|g" -e "s|@BRANCH@|$BRANCH|g" -e "s|@BASE@|$BASE|g" -e "s|@HANDBACK@|$HANDBACK|g" \
      -e "s|@GUEST@|$GUEST|g" -e "s|@ACCEPT@|$(echo "$ACCEPT_CMD" | sed 's/[|&\\]/\\&/g')|g" -e "s|@FACTORY@|$FACTORY_DIR_REL|g" -e "s|@SPEC@|$TICKET_FILE|g" \
      -e "s|@TEMPLATES@|$SKILL_REL/templates|g" -e "s|@VM@|$VM|g" -e "s|@APP@|$APP_NAME|g" \
      -e "s|@GUEST_DESC@|${GUEST_DESC:-}|g" -e "s|@XRES@|$VM_XRES|g" -e "s|@YRES@|$VM_YRES|g" \
      -e "s|@STANDARDS@|${REVIEW_STANDARDS:-none}|g" -e "s|@DOCS@|${DOC_PATHS:-none}|g" -e "s|@BMIN@|$B_MIN|g" "$1"
}
section() { # section <file> <heading>: the body of one "## <heading>" section
  awk -v h="## $2" '$0 == h { on = 1; next } /^## / { on = 0 } on' "$1"
}

# run_claude <name> <minutes> <dir> <claude args...>: one headless run in <dir>, time-boxed; writes <name>.json.
# The session streams its steps to <name>.jsonl as it works (what the dashboard shows live); <name>.json is its final
# result line, the same object --output-format json gives, so everything that reads it is unchanged.
run_claude() {
  local name=$1 mins=$2 dir=$3; shift 3
  local t0 t1 rc a args=() prev=""
  for a in "$@"; do
    [ "$prev" = --output-format ] && a=stream-json
    args+=("$a"); prev=$a
  done
  t0=$(date +%s)
  ev "start $name (time box $mins min)"
  ( cd "$dir" && timebox $((mins * 60)) claude "${args[@]}" --verbose > "$RUN/$name.jsonl" 2> "$RUN/$name.err" < /dev/null )
  rc=$?
  jq -c 'select(.type == "result")' "$RUN/$name.jsonl" 2> /dev/null | tail -1 > "$RUN/$name.json"
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

# verify <n>: the runner's own checks and its own verification record, never the agent's word: scope, the negative run
# on the base, the build, the acceptance test and the tests the builder listed, all in the build VM. Writes and commits
# $HANDBACK/verification-record.md. Echoes "green", "red: <why>" or "error: <why>" (the harness, or the spec, failed).
verify() {
  local n=$1 out="$RUN/verify-$1.log"
  local sha touched outside rc i line proj filt what flaky="" fails="" rv=""
  : > "$out"; : > "$out.rows"; : > "$out.ex"
  [ -z "$(git -C "$WT" status --porcelain -- . ':(exclude)handback')" ] \
    || { echo "red: uncommitted changes left in the worktree (the builder stopped before committing them; they are still there)"; return; }
  [ -n "$(git -C "$WT" diff --name-only "$BASE" HEAD -- . ':(exclude)handback')" ] || { echo "red: no code change"; return; }
  touched=$(git -C "$WT" diff --name-only "$BASE" HEAD -- $PROTECTED_PATHS)
  [ -z "$touched" ] || { echo "red: protected files changed: $(echo $touched)"; return; }
  outside=$(git -C "$WT" diff --name-only "$BASE" HEAD -- . ':(exclude)handback' | grep -vE "$SCOPE_REGEX" | not_docs)
  [ -z "$outside" ] || { echo "red: files outside the ticket scope: $(echo $outside)"; return; }
  sha=$(git -C "$WT" log -1 --format=%h -- . ':(exclude)handback')
  i=0
  negative_run "$out"
  case "$NEG" in
    error*) echo "error: negative run: ${NEG#error: }"; return ;;
    passes*) echo "error: the acceptance test passes on the base $BASE, so it doesn't test the change: the spec needs a human"; return ;;
  esac
  i=$((i + 1)); rec_row $i "git switch --detach $BASE; $ACCEPT_CMD; git switch $BRANCH" 1 "$NEG" "$NEG_OUT" "$out"
  # The target's whole build. Output left from an earlier build can break an incremental one (GAPS V28): a red build
  # gets one clean rebuild before it counts against the change.
  "$GUEST" build > "$out.last" 2>&1
  rc=$?
  if [ $rc -eq 1 ]; then
    cat "$out.last" >> "$out"; echo "== red: one clean rebuild" >> "$out"
    "$GUEST" build --clean > "$out.last" 2>&1
    rc=$?
  fi
  cp "$BUILD_VM/build.log" "$RUN/verify-$n-build.log" 2> /dev/null
  # bash 3.2 misparses a case inside $(...): the result goes through a variable.
  case $rc in
    0) what=green ;;
    1) what="fails: $(first_errors "$out.last")"; rv="red: the $GUEST_DESC build fails: $(first_errors "$out.last")" ;;
    *) what="harness error"; rv="error: guest build: $(harness_why "$out.last")" ;;
  esac
  i=$((i + 1)); rec_row $i "$GUEST build" $rc "$what" "" "$out"
  if [ -z "${rv:-}" ]; then
    # The acceptance test, then the tests the builder asks for ($HANDBACK/tests.txt: "<test project> [<filter>]" a line).
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      proj=${line%% *} filt=""
      [ "$proj" != "$line" ] && filt=${line#* }
      guest_test "$out" "$proj" "$filt"
      i=$((i + 1)); rec_row $i "$GUEST test $line" $T_RC "$T_WHAT" "" "$out"
      case $T_RC in
        0) [ "$T_FAILS" -gt 0 ] && flaky="$flaky; $line: failed $T_FAILS of $T_RUNS runs" ;;
        1) fails="$fails; $line: $(first_errors "$out.last")" ;;
        *) rv="error: guest test: $(harness_why "$out.last")"; break ;;
      esac
    done < <(echo "$ACCEPT_TEST${ACCEPT_FILTER:+ $ACCEPT_FILTER}"; grep -vE '^[[:space:]]*(#|$)' "$WT/$HANDBACK/tests.txt" 2> /dev/null)
    cp "$BUILD_VM/test.log" "$RUN/verify-$n-test.log" 2> /dev/null
    [ -z "${rv:-}" ] && [ -n "$fails" ] && rv="red: tests fail in the guest${fails#;}"
  fi
  write_record "$sha" "${rv:-green}" "${flaky#; }" "$out"
  echo "${rv:-green}"
}

# guest_test <log> <project> [<filter>]: one test command in the build VM, re-run up to FLAKY_RERUNS times while it
# fails. A test that passes on a re-run is flaky: green, and listed in the record for the judge. Sets T_RC (0 pass,
# 1 fail, 3 harness), T_RUNS, T_FAILS and T_WHAT (the result for the record); the last run's output is in <log>.last.
guest_test() {
  local log=$1 rc
  shift
  T_RUNS=0 T_FAILS=0 T_RC=1
  while :; do
    T_RUNS=$((T_RUNS + 1))
    if [ -n "${2:-}" ]; then "$GUEST" test "$1" "$2" > "$log.last" 2>&1 < /dev/null; else "$GUEST" test "$1" > "$log.last" 2>&1 < /dev/null; fi
    rc=$?
    { echo "== $GUEST test $*, run $T_RUNS: exit $rc"; cat "$log.last"; } >> "$log"
    case $rc in
      0) T_RC=0; break ;;
      1) T_FAILS=$((T_FAILS + 1)) ;;
      *) T_RC=3; break ;;
    esac
    [ "$T_RUNS" -le "$FLAKY_RERUNS" ] || break
  done
  T_WHAT=$(counts "$log.last")
  [ $T_RC -eq 0 ] && [ "$T_FAILS" -gt 0 ] && T_WHAT="$T_WHAT; flaky: failed $T_FAILS of $T_RUNS runs"
  [ $T_RC -eq 1 ] && [ "$T_RUNS" -gt 1 ] && T_WHAT="$T_WHAT; failed all $T_RUNS runs"
  [ $T_RC -eq 3 ] && T_WHAT="harness error: $(harness_why "$log.last")"
  return 0
}

counts() { # counts <guest test output>: "<p> passed, <f> failed, <s> skipped", else its summary line
  local l
  l=$(grep -E 'Passed!|Failed!' "$1" | tail -1)
  if echo "$l" | grep -qE 'Failed: *[0-9]+, Passed: *[0-9]+'; then
    echo "$l" | sed -E 's/.*Failed: *([0-9]+), Passed: *([0-9]+)(, Skipped: *([0-9]+))?.*/\2 passed, \1 failed, \4 skipped/; s/, *skipped/, 0 skipped/'
  else
    grep -E 'EXIT CODE|Total tests' "$1" | tail -1
  fi
}

# negative_run <log>: the acceptance test on the base, where it must fail: the proof that it tests the change. The base
# and the test are the same for every round of a run (and for later runs on that base), so the result is kept per base
# tree and test in NEG_CACHE and runs once. Sets NEG ("expected fail: …", "passes: …" or "error: …") and NEG_OUT.
negative_run() {
  local key f rc
  key=$(git -C "$WT" rev-parse "$BASE^{tree}")-$(printf '%s' "$ACCEPT_TEST $ACCEPT_FILTER" | git hash-object --stdin | cut -c1-12)
  f=$NEG_CACHE/$key
  if [ -s "$f" ]; then
    NEG="$(sed -n 1p "$f") (kept from $(sed -n 2p "$f"))" NEG_OUT=$(tail -n +3 "$f")
    ev "negative run: kept from $(sed -n 2p "$f")" > /dev/null
    return
  fi
  ev "negative run: $ACCEPT_TEST on the base $BASE" > /dev/null
  wtgit switch -q --detach "$BASE" 2>> "$1" || { NEG="error: could not switch the worktree to the base $BASE"; return; }
  $ACCEPT_CMD > "$1.last" 2>&1
  rc=$?
  { echo "== negative run on $BASE: exit $rc"; cat "$1.last"; } >> "$1"
  wtgit switch -q "$BRANCH" 2>> "$1" || { NEG="error: could not switch the worktree back to $BRANCH"; return; }
  NEG_OUT=$(grep -E '^ *Failed |Passed!|Failed!|EXIT CODE' "$1.last" | head -12)
  case $rc in
    1) NEG="expected fail: accept fails without the change: $(counts "$1.last")"
       mkdir -p "$NEG_CACHE" && printf '%s\n%s\n%s\n' "$NEG" "run $ID" "$NEG_OUT" > "$f" ;;
    0) NEG="passes: $(counts "$1.last")" ;;
    *) NEG="error: $(harness_why "$1.last")" ;;
  esac
}

rec_row() { # rec_row <#> <command> <exit code> <result> <excerpt, or "" for the last output's summary> <log>
  local ex=$5
  [ -n "$ex" ] || ex=$(grep -E ': error |^ *Failed [^!]|Passed!|Failed!|Warning\(s\)|Error\(s\)|Time Elapsed|EXIT CODE' "$6.last" 2> /dev/null | awk '!seen[$0]++' | head -15)
  echo "| $1 | $2 | $3 | $4 |" >> "$6.rows"
  printf 'Output %s:\n```text\n%s\n```\n\n' "$1" "${ex:-<no output>}" >> "$6.ex"
}

# write_record <short sha> <green | red: … | error: …> <flaky tests> <log>: the verification record, from the rows
# verify ran, committed on its own; and the Tests section's record line in the hand-back.
write_record() {
  local rec="$WT/$HANDBACK/verification-record.md" verdict=PASS ver
  [ "$2" = green ] || verdict="FAIL: ${2#*: }"
  [ -n "${GUEST_INFO:-}" ] || GUEST_INFO=$("$GUEST" info 2> /dev/null < /dev/null | tail -1)
  ver=$(jq -r '.version // "unknown"' "$SKILL/../../.claude-plugin/plugin.json" 2> /dev/null)
  mkdir -p "$(dirname "$rec")"
  {
    echo "# Verification record"
    echo "<!-- Written by the factory's runner (run-loop.sh), not by the builder: it ran each command below itself, in the run's build VM, on the Commit. Exit codes are the commands' own; the negative run is kept per base and test, so a later round may show the first one's. -->"
    echo
    echo "- Change: $TICKET, $(git -C "$WT" log -1 --format=%s -- . ':(exclude)handback')"
    echo "- Commit: $BRANCH @ $1"
    echo "- Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- Tool: factory runner, factory-toolkit $ver"
    echo "- Model: none (a script)"
    echo "- Environment: commands ran in the guest: ${GUEST_INFO:-unknown}; host: $(git --version)"
    echo
    echo "| # | Command (exactly as run) | Exit code | Result |"
    echo "|---|---|---|---|"
    cat "$4.rows"
    echo
    cat "$4.ex"
    echo "- Flaky: ${3:-none}"
    echo "- Not verified: nothing"
    echo "- Verdict: $verdict"
  } > "$rec"
  rm -f "$4.rows" "$4.ex" "$4.last"
  python3 - "$WT/$HANDBACK/hand-back.md" "$HANDBACK/verification-record.md @ $1 → ${verdict%%:*} (written by the runner)" <<'PY'
import re, sys
p, line = sys.argv[1], sys.argv[2]
try:
    hb = open(p).read()
except OSError:
    sys.exit(0)
open(p, "w").write(re.sub(r"^- Verification record: .*$", lambda m: "- Verification record: " + line, hb, count=1, flags=re.M))
PY
  wtgit add "$HANDBACK"
  wtgit commit -q -m "handback: $TICKET verification record"
}

# ensure_handback <name>: what a builder stopped early (time box, budget) left undone and the runner can do for it, so
# its code commit is still verified: commit its hand-back files, and start the hand-back from the template when there
# is none.
ensure_handback() {
  local hb="$WT/$HANDBACK/hand-back.md"
  if [ ! -f "$hb" ] && [ -n "$(git -C "$WT" diff --name-only "$BASE" HEAD -- . ':(exclude)handback')" ]; then
    mkdir -p "$(dirname "$hb")"
    python3 - "$SKILL/templates/hand-back.md" "$hb" "$TICKET" "$(head -1 "$TICKET_FILE" | sed -e 's/^# *//' -e "s/^$TICKET *[—:-] *//")" \
      "no PR: $BRANCH @ $(git -C "$WT" log -1 --format=%h -- . ':(exclude)handback')" \
      "$(git -C "$WT" log -1 --format=%s -- . ':(exclude)handback'); the builder stopped before writing this section, so the runner started it from the code commit" <<'PY'
import re, sys
src, dst, ticket, title, pr, what = sys.argv[1:7]
hb = open(src).read()
hb = hb.replace("<ticket ID> <one-line title>", ticket + " " + title, 1)
hb = re.sub(r"^- PR: .*$", lambda m: "- PR: " + pr, hb, count=1, flags=re.M)
hb = re.sub(r"^- What changed: .*$", lambda m: "- What changed: " + what, hb, count=1, flags=re.M)
open(dst, "w").write(hb)
PY
    ev "$1 wrote no hand-back: the runner started one from the template"
  fi
  if [ -n "$(git -C "$WT" status --porcelain -- "$HANDBACK")" ]; then
    wtgit add "$HANDBACK" && wtgit commit -q -m "handback: $TICKET builder sections (committed by the runner)"
  fi
  return 0
}

# progress_sig [hand-back]: what a builder round can change that counts as progress: the code (the tree outside
# handback/, committed or not), its disputes and the tests it asks the runner to run; with "hand-back", its hand-back
# too (a review finding can be about the hand-back alone).
progress_sig() {
  { git -C "$WT" ls-tree HEAD | grep -v "$(printf '\t')handback\$"
    git -C "$WT" diff HEAD -- . ':(exclude)handback'
    cat "$WT/$HANDBACK/disputes.md" "$WT/$HANDBACK/tests.txt" 2> /dev/null
    [ "${1:-}" = hand-back ] && cat "$WT/$HANDBACK/hand-back.md" 2> /dev/null
  } | git hash-object --stdin
}

# save_state <next station: build | review | qa>: what --resume-run needs to go on from that station (factory.sh resume).
save_state() {
  local v
  { for v in TICKET STAMP BRANCH WT BASE QA EXPLORE KEEP_VM OPEN_PR builds FIRST reason from xsend LAST_X last_v stall SPENT; do
      printf 'S_%s=%q\n' "$v" "${!v:-}"
    done
    printf 'S_NEXT=%q\n' "$1"
  } > "$RUN/state.sh.tmp" && mv "$RUN/state.sh.tmp" "$RUN/state.sh"
}

# git_settle: after a builder session, wait for the worktree's index.lock to go. A background shell the builder started
# can outlive the time box's kill and still be in a git command; a lock left after a minute is stale (a killed git).
git_settle() {
  local lock i
  lock=$(git -C "$WT" rev-parse --git-path index.lock)
  case "$lock" in /*) ;; *) lock=$WT/$lock ;; esac
  for i in $(seq $(( (GIT_SETTLE_S + 1) / 2 ))); do [ -e "$lock" ] || return 0; sleep 2; done
  rm -f "$lock" && ev "removed a stale git index.lock in ${WT#$REPO/} (left by a killed git)"
}

# wtgit <git args>: git in the worktree, waiting out another process's index.lock instead of failing on it. Builder
# sessions load the user's plugins, whose hooks can still run git in the worktree after the session exits.
wtgit() {
  local i rc err
  err=$(mktemp)
  for i in 1 2 3; do
    git -C "$WT" "$@" 2> "$err"
    rc=$?
    [ "$rc" -ne 0 ] && grep -q 'index\.lock' "$err" || break
    git_settle > /dev/null
  done
  cat "$err" >&2
  rm -f "$err"
  return "$rc"
}

dot_docs() { # dot_docs: the DOC_PATHS under .claude/, one a line: the builder stages those, the runner applies them
  local d
  for d in $DOC_PATHS; do case "$d" in .claude/*) echo "$d" ;; esac; done
}

# apply_docs: Claude Code refuses a headless session's edits under any .claude/ folder, whatever the allow rules, so the
# builder writes its new version of such a doc at $HANDBACK/docs/<path without the leading dot>. This copies the ones
# under dot_docs into place, in a commit of the runner's that the reviewer then sees; anything else there is ignored.
apply_docs() {
  local st="$WT/$HANDBACK/docs/claude" f rel d ok
  [ -d "$st" ] || return 0
  while IFS= read -r f; do
    rel=.claude/${f#$st/} ok=""
    for d in $(dot_docs); do case "$rel" in "$d"*) ok=yes ;; esac; done
    case "$rel" in *..*) ok="" ;; esac
    [ -n "$ok" ] || { ev "staged doc $rel is not under DOC_PATHS ($(echo $(dot_docs))): ignored"; continue; }
    mkdir -p "$(dirname "$WT/$rel")" && cp "$f" "$WT/$rel" && wtgit add -- "$rel"
  done < <(find "$st" -type f)
  git -C "$WT" diff --cached --quiet && return 0
  wtgit commit -q -m "$TICKET: Updated the docs the builder staged under $HANDBACK/docs" \
    && ev "applied the builder's staged docs: $(echo $(git -C "$WT" diff --name-only HEAD~1 HEAD))"
}

not_docs() { # not_docs: the paths on stdin that are under none of DOC_PATHS
  local p d keep
  while IFS= read -r p; do
    keep=yes
    for d in $DOC_PATHS; do case "$p" in "$d"*) keep=no ;; esac; done
    [ "$keep" = yes ] && echo "$p"
  done
  return 0
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
    "$GUEST_SH" "$BUILD_VM" > "$GUEST"
  chmod +x "$GUEST"
}

# write_section <heading> <body file>: the runner, not the agents, writes the Review and Runtime check sections.
write_section() {
  python3 - "$WT/$HANDBACK/hand-back.md" "$1" "$2" <<'PY'
import re, sys
hb_path, heading, body_path = sys.argv[1], sys.argv[2], sys.argv[3]
hb = open(hb_path).read()
if "## " + heading not in hb:
    j = hb.find("## Judge (human)")
    j = len(hb) if j < 0 else j
    hb = hb[:j] + "## " + heading + "\n\n" + hb[j:]
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

# app_launch <log>: (re)starts the app in the guest's desktop session; the target's launch script stops a running one.
app_launch() { "$VM/vmssh" - < "$GUEST_LAUNCH" > "$1" 2>&1 && grep -q '^LAUNCH OK' "$1"; }

# app_up <vm run dir> <share> <built: yes|no> <log dir>: boots a QA VM sharing <share>, builds it there unless <built>,
# and launches the app; the VM's environment (vm.py, vmssh) is exported. Returns 0 when the app runs, 1 when the guest
# build fails, 2 when the harness fails; APP_WHY says why.
app_up() {
  local vmrun=$1 share=$2 built=$3 log=$4 rc
  APP_WHY=""
  "$VM/vmctl.sh" up "$vmrun" "$share" > "$log/vm.log" 2>&1 || { APP_WHY="VM did not come up: $(tail -1 "$log/vm.log")"; return 2; }
  eval "$("$VM/vmctl.sh" env "$vmrun")"
  if [ "$built" = no ]; then
    ev "$(basename "$log"): guest build (time box $GUEST_BUILD_MIN min)"
    guest_conf "$vmrun" "$share"
    "$GUEST_SH" "$vmrun" build > "$log/guest-build.log" 2>&1
    rc=$?
    cp "$vmrun/build.log" "$log/guest-build-full.log" 2> /dev/null
    [ $rc -eq 1 ] && { APP_WHY="the $GUEST_DESC build fails: $(first_errors "$log/guest-build.log")"; return 1; }
    [ $rc -ne 0 ] && { APP_WHY="guest build: $(harness_why "$log/guest-build.log")"; return 2; }
  fi
  app_launch "$log/launch.log" || { APP_WHY="$APP_NAME did not start in the guest: $(tail -1 "$log/launch.log")"; return 2; }
  return 0
}

# qa_stage <n> <commit> [<built worktree>]: launch the app in a throwaway VM, let the blind QA agent check the ticket's
# Runtime check, then hand the screen to a human if asked; after a PASS, the exploratory QA runs on the same VM
# (explore_stage). With <built worktree> (the loop), the clone shares that worktree and launches what verify built there;
# without it (--qa-only), the stage cuts its own worktree and builds it in the clone first. Sets QA_VERDICT to
# "PASS: …", "FAIL: …", "NEEDS-HUMAN: …" or "ERROR: …" (ERROR = the harness failed, not the change) and copies the
# report and screenshots to $RUN/qa-<n>/.
qa_stage() {
  local n=$1 ref=$2 built=${3:-}
  local q="$QA_ROOT/qa-$n" vmrun="$QA_ROOT/vm-$n" qwt="" share v waited
  QA_VERDICT="" X_STATUS="" X_FINDINGS=""
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
  app_up "$vmrun" "$share" "$([ -n "$built" ] && echo yes || echo no)" "$RUN/qa-$n"
  case $? in
    1) QA_VERDICT="FAIL: $APP_WHY" ;;
    2) QA_VERDICT="ERROR: $APP_WHY" ;;
    *) { fill "$SKILL/prompts/qa.txt" | sed -e "s|@QA_DIR@|$q|g" -e "s|@SHA@|$ref|g"; echo; section "$TICKET_FILE" "Runtime check"
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
       row "$n" qa "qa-$n" "$QA_VERDICT" ;;
  esac

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
  ev "qa-$n: $QA_VERDICT"
  cp "$q"/*.png "$q/report.md" "$RUN/qa-$n/" 2> /dev/null
  if [ "$EXPLORE" = yes ] && [ "${QA_VERDICT#PASS}" != "$QA_VERDICT" ]; then
    if [ -e "$RUN/STOP" ]; then X_STATUS="not run: STOP file"; else explore_stage "$n" "$ref"; fi
    ev "explore-$n: $X_STATUS"
  fi
  # --keep-vm leaves the VM running whatever the verdict (a PASS is what a judge wants to look at) until factory.sh down.
  if [ "$KEEP_VM" = yes ] && "$VM/vmctl.sh" env "$vmrun" > /dev/null 2>&1; then
    printf '%s' "$qwt" > "$vmrun/factory-kept"
    ev "qa-$n: VM left running: factory.sh show $ID, then factory.sh down $ID"
  else
    "$VM/vmctl.sh" down "$vmrun" >> "$EV" 2>&1
    [ -n "$qwt" ] && git -C "$REPO" worktree remove --force "$qwt" 2>> "$EV"
  fi
}

# Exploratory QA. Kept apart from the acceptance verdict, which is fixed before any of it runs: a separate read-only
# session writes the charter from the ticket and the diff (never the builder's notes), so the builder can't steer it; the
# explorer is blind like the QA agent and gets the charter's places to try, never expected results from the code; each
# finding is re-tried on a build of the base, so only what the change brought can send it back (EXPLORE_SENDBACKS).

# Only numbered items in a user's terms reach the blind explorer: a line naming a source file or a code member is dropped.
CODE_RE='\.(cs|axaml|xaml|csproj|props|targets|ts|tsx|js|py|sh|ps1|java|kt|swift|cpp|h)\b|[A-Za-z_]+\(\)'

# charter_stage <n> <commit> <dir>: the charter for the change $BASE..<commit>, by a fresh read-only session in <dir>.
# Sets CHARTER (the file) or CHARTER_WHY.
charter_stage() {
  # Two lines: bash expands a whole `local` line before it assigns any of it, so $n is not set yet on the first.
  local n=$1 sha=$2 dir=$3 items dropped out
  local raw="$RUN/charter-$n.raw"
  CHARTER="" CHARTER_WHY=""
  if over "$SPENT + $C_USD" "$LOOP_USD"; then CHARTER_WHY="loop budget"; return; fi
  fill "$SKILL/prompts/charter.txt" | sed "s|@SHA@|$sha|g" > "$RUN/charter-$n.prompt"
  run_claude "charter-$n" "$C_MIN" "$dir" -p "$(cat "$RUN/charter-$n.prompt")" --model "$C_MODEL" \
    --append-system-prompt "$(awk 'f > 1; /^---$/ { f++ }' "$SKILL/agents/factory-charter.md")" \
    --max-budget-usd "$C_USD" --tools Read Grep Glob Bash --allowedTools "${CHARTER_TOOLS[@]}" --add-dir "$SPEC_DIR" \
    --disallowedTools Edit Write "Read(./handback/**)" --output-format json
  jq -r '.result // ""' "$RUN/charter-$n.json" > "$raw" 2> /dev/null
  grep -E '^[0-9]+\. ' "$raw" | grep -vE "$CODE_RE" > "$RUN/charter-$n.md"
  items=$(grep -c . "$RUN/charter-$n.md")
  dropped=$(grep -E '^[0-9]+\. ' "$raw" | grep -cE "$CODE_RE")
  if [ "$items" -gt 0 ]; then
    CHARTER=$RUN/charter-$n.md
    out="$items items$([ "$dropped" -gt 0 ] && echo ", $dropped dropped (code terms)")"
  else
    CHARTER_WHY="no usable charter (charter-$n.json)"; out=$CHARTER_WHY
  fi
  row "$n" charter "charter-$n" "$out"
}

# explore_stage <n> <commit>: on qa_stage's VM, the app restarted, the blind explorer tours the change led by $CHARTER.
# Sets X_STATUS and X_FINDINGS (its "- F<n> (blocker|minor): …" lines); report and screenshots in $RUN/qa-<n>/explore/.
explore_stage() {
  local n=$1 ref=$2
  local xd="$QA_ROOT/explore-$n" out="$RUN/qa-$n/explore"
  mkdir -p "$xd" "$out"
  [ -n "$CHARTER" ] || { X_STATUS="not run: no charter (${CHARTER_WHY:-none written})"; return; }
  if over "$SPENT + $X_USD" "$LOOP_USD"; then X_STATUS="not run: loop budget"; return; fi
  app_launch "$out/launch.log" || { X_STATUS="not run: $APP_NAME did not restart: $(tail -1 "$out/launch.log")"; return; }
  { fill "$SKILL/prompts/explore.txt" | sed -e "s|@QA_DIR@|$xd|g" -e "s|@SHA@|$ref|g"
    echo; echo "## Acceptance check (passed)"; section "$TICKET_FILE" "Runtime check" | awk '/^Red on base/ { exit } 1'
    echo "## Charter"; cat "$CHARTER"; } > "$RUN/explore-$n.prompt"
  run_claude "explore-$n" "$X_MIN" "$xd" -p "$(cat "$RUN/explore-$n.prompt")" --model "$X_MODEL" --max-budget-usd "$X_USD" \
    --append-system-prompt "$(awk 'f > 1; /^---$/ { f++ }' "$SKILL/agents/factory-explorer.md")" \
    --tools Read Bash --allowedTools "${QA_TOOLS[@]}" --output-format json
  jq -r '.result // ""' "$RUN/explore-$n.json" > "$xd/report.md" 2> /dev/null
  cp "$xd"/*.png "$xd/report.md" "$out/" 2> /dev/null
  if grep -q '^Findings:' "$xd/report.md"; then
    X_FINDINGS=$(grep -E '^- F[0-9]+ \((blocker|minor)\):' "$xd/report.md")
    X_STATUS="$(printf '%s' "$X_FINDINGS" | grep -c .) finding(s)"
  else
    X_STATUS="no usable report (explore-$n.json)"
  fi
  row "$n" explorer "explore-$n" "$X_STATUS"
}

# recheck_stage <n> <base commit>: the explorer's findings re-tried by the same blind agent on a build of the base, in a
# VM of their own; the build VM is powered off to free its slot (VM_MAX) and the loop boots it again if it goes on.
# Sets RC_STATUS, then recheck_classify.
recheck_stage() {
  local n=$1 base=$2 bwt rc
  local rd="$QA_ROOT/recheck-$n" out="$RUN/qa-$n/recheck" vmrun="$QA_ROOT/vm-base-$n"
  RC_STATUS="not needed"
  [ -n "$X_FINDINGS" ] || { recheck_classify ""; return; }
  if over "$SPENT + $RC_USD" "$LOOP_USD"; then RC_STATUS="could not run: loop budget"; recheck_classify ""; return; fi
  mkdir -p "$rd" "$out"
  bwt="$MAIN_REPO/.claude/worktrees/$T-base-$STAMP-$n"
  if ! git -C "$REPO" worktree add -q --detach "$bwt" "$base" 2>> "$EV"; then
    RC_STATUS="could not run: base worktree add failed"; recheck_classify ""; return
  fi
  if [ "$BUILD_VM_UP" = yes ]; then "$VM/vmctl.sh" down "$BUILD_VM" >> "$EV" 2>&1; BUILD_VM_UP=no; fi
  ev "recheck-$n: VM up, building the base ${base:0:11}"
  app_up "$vmrun" "$bwt" no "$out"
  rc=$?
  if [ $rc -ne 0 ]; then
    RC_STATUS="could not run: $APP_WHY"
  else
    { fill "$SKILL/prompts/recheck.txt" | sed -e "s|@QA_DIR@|$rd|g" -e "s|@SHA@|$base|g"
      echo; echo "## Findings"; printf '%s\n' "$X_FINDINGS" | sed 's/; evidence: .*$//'; } > "$RUN/recheck-$n.prompt"
    run_claude "recheck-$n" "$RC_MIN" "$rd" -p "$(cat "$RUN/recheck-$n.prompt")" --model "$X_MODEL" --max-budget-usd "$RC_USD" \
      --append-system-prompt "$(awk 'f > 1; /^---$/ { f++ }' "$SKILL/agents/factory-explorer.md")" \
      --tools Read Bash --allowedTools "${QA_TOOLS[@]}" --output-format json
    jq -r '.result // ""' "$RUN/recheck-$n.json" > "$rd/report.md" 2> /dev/null
    cp "$rd"/*.png "$rd/report.md" "$out/" 2> /dev/null
    RC_STATUS="build of ${base:0:11}"
    row "$n" recheck "recheck-$n" "$(grep -cE '^- F[0-9]+: same' "$rd/report.md") of $(printf '%s\n' "$X_FINDINGS" | grep -c .) on the base too"
  fi
  "$VM/vmctl.sh" down "$vmrun" >> "$EV" 2>&1
  git -C "$REPO" worktree remove --force "$bwt" 2>> "$EV"
  ev "recheck-$n: $RC_STATUS"
  recheck_classify "$([ $rc -eq 0 ] && echo "$rd/report.md")"
}

# recheck_classify <recheck report | "">: X_LINES, one "  F<n> (<blocker|minor>, <new|pre-existing|not rechecked>): …"
# per finding, and X_NEW, the blockers the base doesn't show (what may send the change back). "can't tell" on the base
# (the feature isn't there) counts as new.
recheck_classify() {
  local line id sev r tag
  X_LINES="" X_NEW=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id=$(echo "$line" | sed -E 's/^- (F[0-9]+) .*/\1/')
    sev=$(echo "$line" | sed -E 's/^- F[0-9]+ \((blocker|minor)\).*/\1/')
    r=""
    [ -n "${1:-}" ] && r=$(grep -m1 -E "^- $id: " "$1" | sed -E "s/^- $id: *(same|different|can't tell).*/\1/")
    case "$r" in
      same) tag=pre-existing ;;
      different|"can't tell") tag=new ;;
      *) tag="not rechecked" ;;
    esac
    X_LINES="$X_LINES  $id ($sev, $tag): $(echo "$line" | sed -E 's/^- F[0-9]+ \([a-z]+\): *//; s/; evidence: .*$//')
"
    [ "$sev" = blocker ] && [ "$tag" = new ] && X_NEW="$X_NEW $id"
  done <<< "$X_FINDINGS"
}

# x_summary: the exploratory QA's outcome on one line
x_summary() {
  case "$X_STATUS" in
    "") echo "exploratory QA: off" ;;
    "not run"*|"no usable"*) echo "exploratory QA: $X_STATUS" ;;
    *) echo "exploratory QA: $X_STATUS$([ -n "$X_NEW" ] && echo ", new blockers:$X_NEW")" ;;
  esac
}

# explore_section <n> <dir shown for paths>: the Exploratory QA section of the hand-back
explore_section() {
  local n=$1 p=$2
  case "$X_STATUS" in
    "not run"*|"no usable"*)
      echo "- Explorer: Claude Code, $X_MODEL, blind: $X_STATUS"
      echo "- Findings: none"; echo "- Base re-check: not needed"; echo "- Tour for the judge: none" ;;
    *)
      echo "- Explorer: Claude Code, $X_MODEL, blind; same VM, app restarted; charter by $C_MODEL from the diff: \`$p/charter.md\`"
      if [ -z "$X_FINDINGS" ]; then echo "- Findings: none"; else echo "- Findings: $X_STATUS"; printf '%s' "$X_LINES"; fi
      case "$RC_STATUS" in
        "build of"*) echo "- Base re-check: $RC_STATUS: \`$p/recheck/report.md\`" ;;
        *) echo "- Base re-check: $RC_STATUS" ;;
      esac
      echo "- Tour for the judge: \`$p/explore/report.md\`; evidence: $(cd "$RUN/qa-$n/explore" 2> /dev/null && ls *.png 2> /dev/null | tr '\n' ' ')" ;;
  esac
}

# disputes <field>: the builder's disputed expectations (handback/disputes.md), each heading with one field's lines
disputes() {
  local f="$WT/$HANDBACK/disputes.md"
  [ -s "$f" ] && awk -v k="- $1:" '/^## / { print; next } index($0, k) == 1 { print }' "$f"
}

# disputes_for_qa: the "Disputed expectations" part of a QA prompt. Only the behaviour the builder says is intended
# reaches the blind QA agent, never its reasons or evidence (those are for the human judge). Only the Runtime check's
# expectations (E<n>): a disputed exploratory finding (F<n>) is for the judge alone.
disputes_for_qa() {
  local d
  d=$(disputes "Expected instead" | awk '/^## / { keep = ($0 ~ /^## E/) } keep' | sed 's/^## /### /')
  [ -n "$d" ] || return 0
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
  if [ -n "$X_STATUS" ]; then
    for sub in explore recheck; do
      [ -d "$RUN/qa-$n/$sub" ] || continue
      mkdir -p "$dir/$sub"
      cp "$RUN/qa-$n/$sub"/*.png "$RUN/qa-$n/$sub/report.md" "$dir/$sub/" 2> /dev/null
    done
    [ -n "$CHARTER" ] && cp "$CHARTER" "$dir/charter.md"
    explore_section "$n" "$HANDBACK/qa-$n" > "$RUN/qa-$n/explore-section.md"
    write_section "Exploratory QA" "$RUN/qa-$n/explore-section.md"
  elif [ "$EXPLORE" = yes ]; then
    # No stale tour from an earlier round: exploration only follows a PASS.
    printf -- '- Explorer: not run in round %s: the runtime QA verdict was not PASS\n- Findings: none\n- Base re-check: not needed\n- Tour for the judge: none\n' "$n" > "$RUN/qa-$n/explore-section.md"
    write_section "Exploratory QA" "$RUN/qa-$n/explore-section.md"
  fi
  wtgit add "$HANDBACK"
  wtgit commit -q -m "handback: $TICKET runtime check $n"
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
  if [ "$EXPLORE" = yes ]; then
    if [ -n "$QA_BASE" ]; then
      XB=$(git -C "$REPO" rev-parse --verify "$QA_BASE^{commit}") || { echo "unknown ref $QA_BASE" >&2; exit 2; }
    else
      XB=$(git -C "$REPO" merge-base "$REF" "origin/$PR_BASE" 2> /dev/null || git -C "$REPO" merge-base "$REF" "$PR_BASE")
      # <ref> already on PR_BASE (a merged change): the change is its own commit.
      [ "$XB" = "$REF" ] && XB=$(git -C "$REPO" rev-parse "$REF~1")
    fi
    BASE=$(git -C "$REPO" rev-parse --short "$XB")
    ev "explore: the change is $BASE..${REF:0:11}"
    charter_stage 1 "$REF" "$REPO"
  fi
  qa_stage 1 "$REF"
  STATUS=$QA_VERDICT
  if [ -n "$X_STATUS" ]; then
    recheck_stage 1 "$XB"
    [ -n "$CHARTER" ] && cp "$CHARTER" "$RUN/qa-1/charter.md"
    explore_section 1 "$RUN/qa-1" > "$RUN/qa-1/exploratory.md"
    STATUS="$STATUS; $(x_summary)"
    echo "Exploratory QA: $RUN/qa-1/exploratory.md"
  fi
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

if [ -z "$RESUME_RUN" ]; then
cat > "$RUNS" <<EOF
# Loop runs · $TICKET · $STAMP
Base: $BASE · branch: $BRANCH · builder: $B_MODEL (\$$B_USD, $B_MIN min) · reviewer: $R_MODEL (\$$R_USD, $R_MIN min) · QA: $([ "$QA" = yes ] && echo "$QA_MODEL (\$$QA_USD, $QA_MIN min)" || echo off) · exploration: $([ "$EXPLORE" = yes ] && echo "charter $C_MODEL (\$$C_USD), explorer $X_MODEL (\$$X_USD, re-check \$$RC_USD), $EXPLORE_SENDBACKS send back(s)" || echo off) · caps: $ITER_CAP builder runs, $STALL_CAP in a row without progress · loop \$$LOOP_USD

| Run | Role | Min | subtype | Turns | Cost \$ | Denials | Outcome |
|---|---|---|---|---|---|---|---|
EOF
fi

# The builder's deny rules: every protected path (a folder denies everything under it) plus the outward-facing commands.
for p in $PROTECTED_PATHS; do
  [ -d "$REPO/$p" ] && p="$p/**"
  printf '"Edit(%s)"\n"Write(%s)"\n' "$p" "$p"
done | { cat; printf '"Edit(/%s/**)"\n"Write(/%s/**)"\n' "$SPEC_DIR" "$SPEC_DIR"; printf '"%s"\n' "${DENY_BASH[@]}"; } \
  | jq -s '{permissions: {deny: .}}' > "$RUN/builder-settings.json"

builds=0 reason="" from="" stall=0 last_v="" xsend=0 LAST_X=""
if [ -n "$RESUME_RUN" ]; then
  builds=$S_builds FIRST=$S_FIRST reason=$S_reason from=$S_from xsend=$S_xsend LAST_X=$S_LAST_X last_v=$S_last_v
  stall=$S_stall SPENT=$S_SPENT
  ev "run resumed before $SKIP (round $builds, \$$SPENT spent)"
  [ "$SKIP" = build ] && SKIP=""
elif [ -n "$RESUME" ]; then
  # The judge's send back: the ticket branch (its updated spec) merges in, the Decision goes in the Judge section, and
  # rounds go on from the last one so qa-<n> folders don't collide. The caps count this run's rounds only.
  ev "loop resume: $TICKET on $BRANCH (worktree ${WT#$REPO/}), merging $BASE; judge: $JUDGE_REASON"
  wtgit merge -q --no-edit "$BASE" || { wtgit merge --abort; echo "merging $BASE into $BRANCH conflicts" >&2; exit 1; }
  [ "$CONTINUE" = yes ] || python3 - "$WT/$HANDBACK/hand-back.md" "$JUDGE_REASON, $(git config user.name), $(date +%F)" <<'PY'
import re, sys
p, why = sys.argv[1], sys.argv[2]
hb = open(p).read()
hb = re.sub(r"^Decision: .*$", lambda m: "Decision: send back: " + why, hb, count=1, flags=re.M)
open(p, "w").write(hb)
PY
  [ "$CONTINUE" = yes ] || wtgit commit -q -am "handback: $TICKET judge sent back"
  builds=$(ls -d "$WT/$HANDBACK"/qa-* 2> /dev/null | sed 's/.*qa-//' | sort -n | tail -1)
  builds=${builds:-0}
  reason="the human judge sent it back: $JUDGE_REASON. The ticket's spec was updated for it (merged into this branch)."
  [ "$CONTINUE" = yes ] && reason="the runner stopped this run for a human, who sends it on: $JUDGE_REASON"
  FIRST=$builds
else
  ev "loop start: $TICKET base $BASE worktree ${WT#$REPO/} qa=$QA"
  git -C "$REPO" worktree add -q -b "$BRANCH" "$WT" "$BASE" || { echo "worktree add failed" >&2; exit 1; }
  FIRST=$builds
fi
BUILD_TOOLS+=("Bash($GUEST *)")
REVIEW_TOOLS+=("Bash($GUEST test *)")
# Each station starts with save_state, so a paused, stopped or crashed run goes on from there (--resume-run). A round
# that changes the code, the disputes or the tests is progress: STALL_CAP rounds in a row without any stop the run, and
# ITER_CAP rounds in all; the loop budget is the hard limit.
while :; do
  release_kept_vms
  # Up at the start, and again after a base re-check powered it off to free its slot.
  if [ "$BUILD_VM_UP" != yes ]; then
    build_vm_up "$WT" || { STATUS="harness error: the build VM did not come up: $(tail -1 "$RUN/build-vm.log")"; break; }
    BUILD_VM_UP=yes
  fi
  if [ -z "$SKIP" ]; then
    save_state build
    if [ $((builds - FIRST)) -ge "$ITER_CAP" ]; then STATUS="reject: iteration cap ($ITER_CAP builder runs); last reason: $reason"; break; fi
    if [ -e "$RUN/PAUSE" ]; then STATUS="paused before builder run $((builds + 1)): factory.sh resume $ID"; break; fi
    if [ -e "$RUN/STOP" ]; then STATUS="stopped: STOP file"; break; fi
    if over "$SPENT + $B_USD" "$LOOP_USD"; then STATUS="stopped: loop budget (\$$SPENT spent)"; break; fi
    builds=$((builds + 1))
    name=build-$builds
    fill "$SKILL/prompts/goal.txt" > "$RUN/$name.prompt"
    if [ -n "$reason" ]; then
      { fill "$SKILL/prompts/fix.txt" | sed "s|@REASON@|$(echo "$reason" | sed 's/[|&\\]/\\&/g')|"; cat "$RUN/$name.prompt"; } > "$RUN/$name.prompt.tmp"
      mv "$RUN/$name.prompt.tmp" "$RUN/$name.prompt"
    fi
    sig0=$(progress_sig "$([ "$from" = review ] && echo hand-back)")
    run_claude "$name" "$B_MIN" "$WT" -p "$(cat "$RUN/$name.prompt")" --model "$B_MODEL" --max-budget-usd "$B_USD" \
      --permission-mode acceptEdits --settings "$RUN/builder-settings.json" --add-dir "$SKILL/templates" --add-dir "$SPEC_DIR" \
      --allowedTools "${BUILD_TOOLS[@]}" --output-format json
    read -r st _ _ _ <<< "$(fields "$RUN/$name.json")"
    read -r _ _ rc < "$RUN/$name.time"
    git_settle
    # A builder stopped while it had the worktree on another commit (checking the base itself) leaves it detached: the
    # next round would see an empty branch. Going back to the branch loses nothing it committed.
    if [ "$(git -C "$WT" symbolic-ref -q --short HEAD)" != "$BRANCH" ]; then
      ev "$name left the worktree off $BRANCH ($(git -C "$WT" rev-parse --short HEAD)): switching back"
      wtgit switch -q "$BRANCH" 2>> "$EV" || ev "could not switch $WT back to $BRANCH"
    fi
    # A builder stopped by its time box after its code commit is not a failed round: the runner commits what it left
    # and verifies the commit like any other.
    ensure_handback "$name"
    apply_docs
    case "$rc/$st" in
      142/*) out="time box ($B_MIN min)" ;;
      */success) out="success" ;;
      */error_max_budget_usd) out="cap: dollars" ;;
      *) out="error: $st (exit $rc)" ;;
    esac
    v=$(verify "$builds")
    row "$builds" builder "$name" "$out; verify $v"
    ev "$name outcome=$out verify=$v spent=\$$SPENT"
    if [ "$(progress_sig "$([ "$from" = review ] && echo hand-back)")" = "$sig0" ]; then stall=$((stall + 1)); else stall=0; fi
    # After a green verify the send back came from the reviewer or QA: a run that changes nothing only sends the same
    # binaries back.
    if [ "$v" = green ] && [ "$last_v" = green ] && [ "$stall" -gt 0 ]; then
      STATUS="needs a human: send back $builds changed no code and disputed nothing (${reason})"; break
    fi
    if [ "$stall" -ge "$STALL_CAP" ]; then
      STATUS="needs a human: $stall builder runs in a row changed nothing (code, disputes or tests); last reason: $reason"; break
    fi
    last_v=$v
    case "$v" in
      green) ;;
      error*) STATUS="harness error in verify: ${v#error: }"; break ;;
      *) reason="builder run $builds: $out; runner verify $v"; from=verify; STATUS="send back: $reason"; continue ;;
    esac
  fi

  if [ -z "$SKIP" ] || [ "$SKIP" = review ]; then
    SKIP=""
    save_state review
    if [ -e "$RUN/PAUSE" ]; then STATUS="paused before review $builds (verified): factory.sh resume $ID"; break; fi
    if [ -e "$RUN/STOP" ]; then STATUS="stopped: STOP file (verified, not reviewed)"; break; fi
    if over "$SPENT + $R_USD" "$LOOP_USD"; then STATUS="verified, not reviewed (loop budget)"; break; fi
    rname=review-$builds
    fill "$SKILL/prompts/review.txt" > "$RUN/$rname.prompt"
    run_claude "$rname" "$R_MIN" "$WT" -p "$(cat "$RUN/$rname.prompt")" --model "$R_MODEL" \
      --append-system-prompt "$(awk 'f > 1; /^---$/ { f++ }' "$SKILL/agents/factory-reviewer.md")" --add-dir "$PROFILE_DIR" --add-dir "$SPEC_DIR" \
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
    wtgit add "$HANDBACK/hand-back.md"
    wtgit commit -q -m "handback: $TICKET review"
    row "$builds" reviewer "$rname" "Recommend: $rec"
    ev "$rname recommend='$rec' spent=\$$SPENT"
    case "$rec" in
      merge*) ;;
      *) reason="review recommended send back: $(grep -m1 '^- Open findings:' "$RUN/$rname.md" | sed 's/^- Open findings: *//')"
         from=review; STATUS="send back: review"; continue ;;
    esac
  fi
  SKIP=""

  save_state qa
  if [ "$QA" != yes ]; then STATUS="ready for the judge (Recommend: merge; no runtime QA)"; break; fi
  if [ -e "$RUN/PAUSE" ]; then STATUS="paused before runtime QA $builds (reviewed): factory.sh resume $ID"; break; fi
  if [ -e "$RUN/STOP" ]; then STATUS="stopped: STOP file (reviewed, no runtime QA)"; break; fi
  if over "$SPENT + $QA_USD" "$LOOP_USD"; then STATUS="reviewed, no runtime QA (loop budget)"; break; fi
  head=$(git -C "$WT" rev-parse HEAD)
  CHARTER="" CHARTER_WHY=""
  [ "$EXPLORE" = yes ] && charter_stage "$builds" "$head" "$WT"
  qa_stage "$builds" "$head" "$WT"
  case "$QA_VERDICT" in
    ERROR*) STATUS="reviewed; runtime QA could not run: ${QA_VERDICT#ERROR: }"; break ;;
  esac
  X_NEW="" X_LINES="" RC_STATUS="not needed"
  [ -n "$X_STATUS" ] && recheck_stage "$builds" "$BASE"
  [ -n "$X_STATUS" ] && LAST_X=$(x_summary)
  write_qa "$builds"
  case "$QA_VERDICT" in
    PASS*) if [ -n "$X_NEW" ] && [ "$xsend" -lt "$EXPLORE_SENDBACKS" ]; then
             xsend=$((xsend + 1))
             reason="exploratory QA (run $builds) found blockers that the base commit's build does not show:$X_NEW. Findings, repro steps and screenshots: $HANDBACK/qa-$builds/explore/report.md (the base re-check: $HANDBACK/qa-$builds/recheck/)"
             from=explore; STATUS="send back: exploratory QA"; continue
           fi
           d=$(disputed_ids)
           STATUS="ready for the judge (Recommend: merge; runtime QA PASS"
           [ -n "$X_NEW" ] && STATUS="ready for the judge (Recommend: the judge decides the new exploratory blockers$X_NEW, still there after $xsend send back(s); runtime QA PASS"
           [ -n "$X_STATUS" ] && STATUS="$STATUS; $(x_summary)"
           [ "$d" != none ] && STATUS="$STATUS; disputed by the builder: $d; the judge decides"
           STATUS="$STATUS)"
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
  echo "- Builder runs: $((builds - FIRST))$([ "$FIRST" -gt 0 ] && echo " (resumed after round $FIRST)") · spent: \$$SPENT of \$$LOOP_USD · PR: $PR_URL"
  echo "- Hand-back for the judge: \`${WT#$REPO/}/$HANDBACK/hand-back.md\`"
  [ -n "$LAST_X" ] && echo "- Last round's ${LAST_X}; tour, findings and base re-check in the hand-back's Exploratory QA section"
  [ -s "$WT/$HANDBACK/disputes.md" ] && echo "- Disputed by the builder (the judge decides): $(disputed_ids); reasons: \`${WT#$REPO/}/$HANDBACK/disputes.md\`"
  echo "- Run log: \`$RUNS\` · events: \`$EV\` · every run's JSON, stderr and prompt: \`$RUN/\`"
} > "$RUN/loop-handback.md"
cat "$RUN/loop-handback.md"
finish
}
