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
#   run-loop.sh <TICKET> --assess-only                               the assessor alone: size and test needs, written to
#                                                                    <TICKET>.assessment.md next to the spec
#   run-loop.sh <TICKET> --limits-only                               the limits a run would use, and where each comes from
# Limits (any mode): --size <class> picks a size class, --set NAME=VALUE (repeatable) sets one limit, for this run only;
# both beat the ticket .sh and the assessment, and may go above SIZE_CEILING (lib/sizing.sh).
# Any time: touch <run dir>/STOP (stops before the next station), <run dir>/PAUSE (the same, resumable: factory.sh pause),
# touch <run dir>/HUMAN (a human judges the next QA).
# Config (lib/config.sh): the project (config.sh, profiles/<profile>/), in the skill's projects/ or the repo's .factory/;
# the ticket's spec <TICKET>.md + .sh in ~/.factory/tickets/<repo>/ (TICKETS_DIR), copied into the run at its start.
# bash 3.2 compatible (macOS default): no associative arrays, no ${x,,}.
set -u
# One block: bash parses it whole before running it, so editing this file during a run can't break that run.
{

usage() { sed -n '9,31p' "$0" >&2; exit 2; }
TICKET=${1:-}
[ -n "$TICKET" ] && [ "${TICKET#-}" = "$TICKET" ] || usage
shift
OPEN_PR=no QA=auto KEEP_VM=no QA_ONLY="" TEST_ONLY="" RESUME="" JUDGE_REASON="" CONTINUE=no EXPLORE_CLI="" QA_BASE="" RESUME_RUN=""
ASSESS_ONLY="" LIMITS_ONLY="" CLI_SIZE="" CLI_SETS=""
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
    --assess-only) ASSESS_ONLY=yes ;;
    --limits-only) LIMITS_ONLY=yes ;;
    --size) CLI_SIZE=${2:-}; [ -n "$CLI_SIZE" ] || usage; shift ;;
    --set) [ -n "${2:-}" ] || usage; CLI_SETS="$CLI_SETS $2"; shift ;;
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
. "$X/lib/sizing.sh"
. "$X/lib/needs.sh"
TICKET_FILE=$TICKETS_DIR/$TICKET.md
[ -f "$TICKET_FILE" ] || { echo "no ticket file $TICKETS_DIR/$TICKET.md" >&2; exit 2; }
[ -n "$PROFILE" ] || { echo "no ticket inputs $TICKETS_DIR/$TICKET.sh (PROFILE, ACCEPT_TEST, ORACLE_PATHS, SCOPE_REGEX)" >&2; exit 2; }

ASSESSMENT=$TICKETS_DIR/$TICKET.assessment.md
if [ -n "$LIMITS_ONLY" ]; then
  resolve_limits "$([ -f "$ASSESSMENT" ] && echo "$ASSESSMENT")" "$CLI_SIZE" "$CLI_SETS" || exit 2
  echo "size $SIZE, from $SIZE_FROM${SIZE_NOTE:+ ($SIZE_NOTE)}"
  printf '%s' "$LIMITS_LOG"
  exit 0
fi

for c in claude git jq perl python3; do
  command -v "$c" > /dev/null || { echo "run-loop.sh needs $c on the PATH" >&2; exit 2; }
done
if [ -n "$(git -C "$REPO" status --porcelain -- "$FACTORY_DIR_REL" $SKILL_IN_REPO $ORACLE_PATHS)" ]; then
  echo "commit the acceptance tests (and the project, when it is in the repo) first: the worktree is cut from HEAD" >&2; exit 2
fi

# Every build and test runs in the guest, so every mode but the assessor's needs the target's image and scripts.
[ -n "$ASSESS_ONLY" ] || [ -f "$FACTORY_VM_HOME/$GOLDEN_IMAGE" ] && command -v qemu-system-aarch64 > /dev/null \
  || { echo "no $GOLDEN_IMAGE in $FACTORY_VM_HOME (or no QEMU): see $SKILL_REL/references/vm-setup.md" >&2; exit 2; }
[ -n "${GUEST_BUILD:-}" ] && [ -n "${GUEST_TEST:-}" ] || { echo "profile $PROFILE, target '$PLATFORM': no GUEST_BUILD/GUEST_TEST" >&2; exit 2; }
[ -n "${ACCEPT_TEST:-}" ] || { echo "no ACCEPT_TEST in $TICKETS_DIR/$TICKET.sh" >&2; exit 2; }
# Optional: most tickets run their whole accept project. Read bare in the negative run's cache key, so set here.
ACCEPT_FILTER=${ACCEPT_FILTER:-}
grep -q '^## Runtime check' "$TICKET_FILE" && HAS_RC=yes || HAS_RC=no
[ "$QA" = auto ] && QA=$HAS_RC
[ -n "$QA_ONLY" ] && QA=yes
[ -n "$TEST_ONLY" ] && QA=no
[ -n "$ASSESS_ONLY" ] && QA=no
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
  [ -n "$ASSESS_ONLY" ] && ID=$T-assess-$STAMP
  # mkdir is atomic: two runs started in the same second get distinct ids (-2, -3, …).
  mkdir -p "$FACTORY_RUNS"
  i=1; base_id=$ID
  until mkdir "$FACTORY_RUNS/$ID" 2> /dev/null; do i=$((i + 1)); ID=$base_id-$i; STAMP=${STAMP%%-*}-$i; done
  RUN=$FACTORY_RUNS/$ID
fi
# The run's own copy of the spec: what its agents read (a later edit of the ticket doesn't change a run in flight, and a
# --resume takes the updated one), in a folder of its own so they get it and nothing else of the run.
SPEC_DIR=$RUN/spec
[ -n "$RESUME_RUN" ] || { mkdir -p "$SPEC_DIR" && cp "$TICKET_FILE" "$TICKETS_DIR/$TICKET.sh" "$SPEC_DIR/"
  [ -f "$ASSESSMENT" ] && [ -z "$ASSESS_ONLY" ] && cp "$ASSESSMENT" "$SPEC_DIR/"; }
TICKET_FILE=$SPEC_DIR/$TICKET.md
# The run's copy of the ticket's fixtures (<KEY>.fixtures/), taken with the spec and for the same reason; outside spec/,
# which the agents read.
FIXTURES_DIR=$RUN/fixtures
[ -n "$RESUME_RUN" ] || [ ! -d "$TICKETS_DIR/$TICKET.fixtures" ] || cp -R "$TICKETS_DIR/$TICKET.fixtures" "$FIXTURES_DIR"
# The run's assessment: its copy of the ticket's, or the one its assessor writes (assess_stage).
RUN_ASSESSMENT=$SPEC_DIR/$TICKET.assessment.md
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
  local sha touched outside rc i line proj filt what flaky="" fails="" rv="" acc=yes isacc red=""
  : > "$out"; : > "$out.rows"; : > "$out.ex"; : > "$RUN/verify-$n.accept-fails"
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
    # The clean rebuild overwrites the guest's build.log: keep the first build's, whose errors may be the real ones.
    cp "$BUILD_VM/build.log" "$RUN/verify-$n-build-first.log" 2> /dev/null
    "$GUEST" build --clean > "$out.last" 2>&1
    rc=$?
    # A restore racing the share right after the clean (obj/ just deleted) is the harness, not the change: one more
    # plain build decides, so the builder is never sent to fix a restore error.
    if [ $rc -eq 3 ]; then
      cat "$out.last" >> "$out"; echo "== harness error on the clean rebuild: one more build" >> "$out"
      "$GUEST" build > "$out.last" 2>&1
      rc=$?
    fi
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
    # The whole build just compiled every test project it covers: each test runs on it without rebuilding its project
    # alone, which recompiled the project's graph (10 to 16 min a test on RDM).
    T_NOBUILD=--no-build
    # The acceptance test, then the tests the builder asks for ($HANDBACK/tests.txt: "<test project> [<filter>]" a line).
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      proj=${line%% *} filt=""
      [ "$proj" != "$line" ] && filt=${line#* }
      if [ -n "$filt" ]; then guest_test "$out" "$proj" "$filt"; else guest_test "$out" "$proj"; fi
      i=$((i + 1)); rec_row $i "$T_CMD" $T_RC "$T_WHAT" "" "$out"
      # The accept test's failing tests, for the loop (verify runs in a subshell): the same ones red round after round
      # point at the oracle, not the builder.
      [ "$acc" = yes ] && [ $T_RC -eq 1 ] && failed_tests "$out.last" > "$RUN/verify-$n.accept-fails"
      isacc=$acc acc=no
      case $T_RC in
        0) [ "$T_FAILS" -gt 0 ] && flaky="$flaky; $line: failed $T_FAILS of $T_RUNS runs" ;;
        # A listed test red on every run waits for the base check below; the accept test is red on the base by design.
        1) if [ "$isacc" = yes ]; then fails="$fails; $line: $(first_errors "$out.last")"
           else red="$red$line	$(first_errors "$out.last")
"; failed_tests "$out.last" > "$out.red-$(printf '%s' "$line" | git hash-object --stdin | cut -c1-12)"; fi ;;
        *) rv="error: guest test: $(harness_why "$out.last")"; break ;;
      esac
    done < <(echo "$ACCEPT_TEST${ACCEPT_FILTER:+ $ACCEPT_FILTER}"; grep -vE '^[[:space:]]*(#|$)' "$WT/$HANDBACK/tests.txt" 2> /dev/null)
    cp "$BUILD_VM/test.log" "$RUN/verify-$n-test.log" 2> /dev/null
    PREF=""
    if [ -z "${rv:-}" ] && [ -n "$red" ]; then
      base_check "$out" "$n" "$red"
      fails="$fails$NEWF"
    fi
    [ -z "${rv:-}" ] && [ -n "$fails" ] && rv="red: tests fail in the guest${fails#;}"
  fi
  write_record "$sha" "${rv:-green}" "${flaky#; }" "$out" "${PREF#; }"
  echo "${rv:-green}"
}

# guest_test <log> <project> [<filter>]: one test command in the build VM, re-run up to FLAKY_RERUNS times while it
# fails. A test that passes on a re-run is flaky: green, and listed in the record for the judge. Sets T_RC (0 pass,
# 1 fail, 3 harness), T_RUNS, T_FAILS, T_WHAT (the result for the record) and T_CMD (the command as run); the last run's
# output is in <log>.last. With T_NOBUILD=--no-build it runs on what the last build left.
guest_test() {
  local log=$1 rc nob=${T_NOBUILD:-}
  shift
  T_RUNS=0 T_FAILS=0 T_RC=1
  while :; do
    T_RUNS=$((T_RUNS + 1))
    "$GUEST" test $nob "$@" > "$log.last" 2>&1 < /dev/null
    rc=$?
    { echo "== $GUEST test $nob $*, run $T_RUNS: exit $rc"; cat "$log.last"; } >> "$log"
    # A test project the whole build doesn't cover has nothing to run without a build: build it, once.
    if [ -n "$nob" ] && [ $rc -ne 0 ] && ! grep -qE 'Passed!|Failed!' "$log.last"; then
      echo "== no tests ran without a build: running it again with one" >> "$log"
      nob="" T_RUNS=$((T_RUNS - 1))
      continue
    fi
    case $rc in
      0) T_RC=0; break ;;
      1) T_FAILS=$((T_FAILS + 1)) ;;
      *) T_RC=3; break ;;
    esac
    [ "$T_RUNS" -le "$FLAKY_RERUNS" ] || break
  done
  T_CMD="$GUEST test${nob:+ $nob} $*"
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
    echo "- Pre-existing (red on the base too, so not this change's): ${5:-none}"
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
  { for v in TICKET STAMP BRANCH WT BASE QA EXPLORE KEEP_VM OPEN_PR builds FIRST reason from xsend LAST_X last_v last_af stall SPENT CLI_SIZE CLI_SETS; do
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

dot_docs() { # dot_docs: the DOC_PATHS under a .claude/ folder (the root one or a nested one), one a line
  local d
  for d in $DOC_PATHS; do case "$d" in .claude/*|*/.claude/*) echo "$d" ;; esac; done
}

# apply_docs: Claude Code refuses a headless session's edits under any .claude/ folder, whatever the allow rules, so the
# builder writes its new version of such a doc at $HANDBACK/docs/<path with the .claude folder's dot dropped>
# (DVLS/.claude/skills/x/SKILL.md at docs/DVLS/claude/skills/x/SKILL.md). This copies the ones under dot_docs into
# place, in a commit of the runner's that the reviewer then sees; anything else there is ignored.
apply_docs() {
  local st="$WT/$HANDBACK/docs" f rel d ok
  [ -d "$st" ] || return 0
  while IFS= read -r f; do
    rel=$(printf '%s' "${f#$st/}" | sed -E 's#(^|/)claude/#\1.claude/#') ok=""
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

# failed_tests <guest test output>: the failed tests' names, one a line, sorted
failed_tests() {
  grep -E '^ *Failed [^!]' "$1" | sed -E 's/^ *Failed ([^ ]+).*/\1/' | sort -u
}

# base_check <verify log> <n> <red lines>: each listed test red on the branch ("<line><TAB><errors>" a line), run on the
# base in a worktree and VM of their own, its failures kept per base tree and line like the negative run (NEG_CACHE).
# A test the base fails too (on any of its 1 + FLAKY_RERUNS runs) is pre-existing: a guest that can't run part of a
# project (no WebView, timing) must not send the builder chasing it, nor push it to narrow the list (DEVEX-514).
# Sets NEWF ("; <line>: <errors>" for each line with a failure the base doesn't show) and PREF (the pre-existing ones).
base_check() {
  local out=$1 n=$2 line errs key f bf proj filt rc k new pre bwt="" vmrun="$QA_ROOT/vm-basetest-$2" why=""
  NEWF="" PREF=""
  while IFS='	' read -r line errs; do
    [ -n "$line" ] || continue
    key=$(git -C "$WT" rev-parse "$BASE^{tree}")-$(printf '%s' "base-test $line" | git hash-object --stdin | cut -c1-12)
    f=$NEG_CACHE/$key
    bf="$out.red-$(printf '%s' "$line" | git hash-object --stdin | cut -c1-12)"
    if [ ! -f "$f" ] && [ -z "$why" ]; then
      if [ -z "$bwt" ]; then
        bwt="$MAIN_REPO/.claude/worktrees/$T-basetest-$STAMP-$n"
        ev "verify-$n: listed tests red, running them on the base ${BASE:0:11}" > /dev/null
        if ! git -C "$REPO" worktree add -q --detach "$bwt" "$BASE" 2>> "$EV"; then
          why="base worktree add failed"; bwt=""
        else
          # One VM a run at a time (V63): the build VM boots again on its next use (lib/lease.sh).
          "$VM/vmctl.sh" down "$BUILD_VM" >> "$EV" 2>&1
          if "$VM/vmctl.sh" up "$vmrun" "$bwt" >> "$out" 2>&1; then guest_conf "$vmrun" "$bwt"; else why="base VM did not come up"; fi
        fi
      fi
      if [ -z "$why" ]; then
        proj=${line%% *} filt=""
        [ "$proj" != "$line" ] && filt=${line#* }
        : > "$f.tmp"
        for k in $(seq $((FLAKY_RERUNS + 1))); do
          if [ -n "$filt" ]; then "$GUEST_SH" "$vmrun" test "$proj" "$filt" > "$out.base" 2>&1; else "$GUEST_SH" "$vmrun" test "$proj" > "$out.base" 2>&1; fi
          rc=$?
          { echo "== base check on ${BASE:0:11}: $line, run $k: exit $rc"; cat "$out.base"; } >> "$out"
          [ $rc -le 1 ] || { why="base test: $(harness_why "$out.base")"; break; }
          failed_tests "$out.base" >> "$f.tmp"
        done
        if [ -z "$why" ]; then sort -u "$f.tmp" > "$f"; fi
        rm -f "$f.tmp"
      fi
    fi
    if [ -f "$f" ] && [ -s "$bf" ]; then
      new=$(comm -23 "$bf" "$f") pre=$(comm -12 "$bf" "$f" | grep -c .)
      if [ -z "$new" ]; then
        PREF="$PREF; $line: $pre failing test(s) also fail on the base"
      else
        NEWF="$NEWF; $line: not on the base: $(echo "$new" | head -3 | tr '\n' ' ')"
        [ "$pre" -gt 0 ] && PREF="$PREF; $line: $pre other failing test(s) also fail on the base"
      fi
    else
      NEWF="$NEWF; $line: $errs${why:+ (base check could not run: $why)}"
    fi
  done <<< "$3"
  if [ -n "$bwt" ]; then
    "$VM/vmctl.sh" down "$vmrun" >> "$EV" 2>&1
    git -C "$REPO" worktree remove --force "$bwt" 2>> "$EV"
  fi
  return 0
}

harness_why() { # harness_why <guest.sh output>: its HARNESS ERROR line, else its last line
  grep -m1 'HARNESS ERROR' "$1" || grep -v '^[[:space:]]*$' "$1" | tail -1
}

first_errors() { # first_errors <guest.sh output>: three error or failed-test lines (also "Avalonia error AVLN…"), on one line
  grep -E ': ([A-Za-z]+ )?error |^ *Failed [^!]' "$1" | awk '!seen[$0]++' | head -3 | tr '\n' ' '
}

# guest_conf <vm run dir> <worktree>: what scripts/guest.sh needs to build and test in that VM
guest_conf() {
  printf "WORKTREE='%s'\nGUEST_BUILD='%s'\nGUEST_TEST='%s'\nGUEST_BUILD_MIN=%s\nGUEST_LAUNCH='%s'\nAPP_SHOT_CAP=%s\n" \
    "$2" "$GUEST_BUILD" "$GUEST_TEST" "$GUEST_BUILD_MIN" "${GUEST_LAUNCH:-}" "$APP_SHOT_CAP" > "$1/guest.conf"
}

# build_vm_up <worktree>: sets up the run's build VM and writes the guest tool. The VM itself boots on demand: the first
# build or test goes through lib/lease.sh, which boots it (waiting for a free slot), and it powers off after VM_IDLE_MIN
# minutes unused, so a builder that is reading or thinking holds no slot. It is powered off when the runner exits.
build_vm_up() {
  local v
  trap '"$VM/vmctl.sh" down "$BUILD_VM" >> "$EV" 2>&1' EXIT
  # app/: the builder's screenshots (guest app shot), readable by its sessions (--add-dir).
  mkdir -p "$BUILD_VM/app"
  guest_conf "$BUILD_VM" "$1"
  # The builder's sessions run the tool too, so it carries the VM settings rather than relying on their environment.
  {
    printf '#!/bin/bash\n# Builds, tests and runs this run'"'"'s worktree in its build VM (booted on first use): build [<project>] [--clean] | test [--no-build] <project> [<filter>] | app launch|wait|shot|click|type|key|scroll|stop | run <powershell> | info\n'
    for v in FACTORY_VM_HOME VM_IMAGE VM_SHARE_CHECK VM_CPUS VM_MEM VM_MAX VM_SLOT_WAIT_MIN VM_BOOT_MIN VM_XRES VM_YRES VM_IDLE_MIN; do
      printf 'export %s=%q\n' "$v" "${!v:-}"
    done
    printf 'exec %q %q %q %q %q %q %q "$@"\n' "$SKILL/scripts/lib/lease.sh" "$VM/vmctl.sh" "$BUILD_VM" "$1" "$EV" "$GUEST_SH" "$BUILD_VM"
  } > "$GUEST"
  chmod +x "$GUEST"
}

# write_section <heading> <body file>: the runner, not the agents, writes the Review and Runtime check sections.
write_section() {
  python3 - "$WT/$HANDBACK/hand-back.md" "$1" "$2" "$SKILL/templates/hand-back.md" <<'PY'
import re, sys
hb_path, heading, body_path, template_path = sys.argv[1:5]
hb = open(hb_path).read()
# A builder that rewrote the file may have dropped the Judge section: the judge's questions come back from the template.
if "## Judge (human)" not in hb:
    template = open(template_path).read()
    hb = hb.rstrip("\n") + "\n\n" + template[template.index("## Judge (human)"):]
if "## " + heading not in hb:
    j = hb.find("## Judge (human)")
    j = len(hb) if j < 0 else j
    hb = hb[:j] + "## " + heading + "\n\n" + hb[j:]
start = hb.index("## " + heading)
# The last section in the file runs to its end.
end = hb.find("\n## ", start + 1)
end = len(hb) if end < 0 else end + 1
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
# puts the ticket's test needs in place and launches the app; the VM's environment (vm.py, vmssh) is exported. Returns
# 0 when the app runs, 1 when the guest build fails, 2 when the harness fails, 4 when a provided resource needs a human;
# APP_WHY says why.
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
  # The ticket's fixtures and provided resources, before the app starts (it reads its data and settings at startup).
  if [ -n "$(needs_lines "$RUN_ASSESSMENT")" ]; then
    needs_apply "$RUN_ASSESSMENT" "$log/needs.log"
    rc=$?
    [ $rc -eq 0 ] || { APP_WHY=$NEEDS_WHY; return $rc; }
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
    4) QA_VERDICT="NEEDS-INPUT: $APP_WHY" ;;
    *) { fill "$SKILL/prompts/qa.txt" | sed -e "s|@QA_DIR@|$q|g" -e "s|@SHA@|$ref|g"; echo; section "$TICKET_FILE" "Runtime check"
         needs_prompt "$RUN_ASSESSMENT"
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
         NEEDS-INPUT*) QA_VERDICT="NEEDS-INPUT: $(grep -m1 '^Input:' "$q/report.md" | sed 's/^Input: *//')" ;;
         *) QA_VERDICT="ERROR: no usable QA report (qa-$n.json)" ;;
       esac
       row "$n" qa "qa-$n" "$QA_VERDICT" ;;
  esac

  # A verdict that needs input (a resource only a human provides) pauses the run instead: there is nothing to judge yet.
  if [ "${QA_VERDICT#ERROR}" = "$QA_VERDICT" ] && [ "${QA_VERDICT#NEEDS-INPUT}" = "$QA_VERDICT" ] \
     && { [ "${QA_VERDICT#NEEDS-HUMAN}" != "$QA_VERDICT" ] || [ -e "$RUN/HUMAN" ]; }; then
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
  if [ "$KEEP_VM" = yes ] && "$VM/vmctl.sh" alive "$vmrun"; then
    printf '%s' "$qwt" > "$vmrun/factory-kept"
    ev "qa-$n: VM left running: factory.sh show $ID, then factory.sh down $ID"
  else
    "$VM/vmctl.sh" down "$vmrun" >> "$EV" 2>&1
    [ -n "$qwt" ] && git -C "$REPO" worktree remove --force "$qwt" 2>> "$EV"
    provided_release
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
  { fill "$SKILL/prompts/charter.txt" | sed "s|@SHA@|$sha|g"; needs_prompt "$RUN_ASSESSMENT"; } > "$RUN/charter-$n.prompt"
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
    echo "## Charter"; cat "$CHARTER"; needs_prompt "$RUN_ASSESSMENT"; } > "$RUN/explore-$n.prompt"
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
      echo; echo "## Findings"; printf '%s\n' "$X_FINDINGS" | sed 's/; evidence: .*$//'
      # The explorer's way there, setup included (a registry value it set over vmssh unlocked the demos): without it
      # the base re-check couldn't reach the screen, and answered can't tell.
      echo; echo "## How the explorer got there (its tour, on the build with the change)"
      awk '/^Tour:/ { f = 1; next } /^Findings:/ { f = 0 } f' "$QA_ROOT/explore-$n/report.md" | sed 's/; evidence: .*$//'
      needs_prompt "$RUN_ASSESSMENT"
    } > "$RUN/recheck-$n.prompt"
    run_claude "recheck-$n" "$RC_MIN" "$rd" -p "$(cat "$RUN/recheck-$n.prompt")" --model "$X_MODEL" --max-budget-usd "$RC_USD" \
      --append-system-prompt "$(awk 'f > 1; /^---$/ { f++ }' "$SKILL/agents/factory-explorer.md")" \
      --tools Read Bash --allowedTools "${QA_TOOLS[@]}" --output-format json
    jq -r '.result // ""' "$RUN/recheck-$n.json" > "$rd/report.md" 2> /dev/null
    cp "$rd"/*.png "$rd/report.md" "$out/" 2> /dev/null
    RC_STATUS="build of ${base:0:11}"
    row "$n" recheck "recheck-$n" "$(grep -cE '^- F[0-9]+: same' "$rd/report.md") of $(printf '%s\n' "$X_FINDINGS" | grep -c .) on the base too"
  fi
  "$VM/vmctl.sh" down "$vmrun" >> "$EV" 2>&1
  provided_release
  git -C "$REPO" worktree remove --force "$bwt" 2>> "$EV"
  ev "recheck-$n: $RC_STATUS"
  recheck_classify "$([ $rc -eq 0 ] && echo "$rd/report.md")"
}

# recheck_classify <recheck report | "">: X_LINES, one "  F<n> (<blocker|minor>, <new|pre-existing|unconfirmed|not
# rechecked>): …" per finding, and X_NEW, the blockers the base doesn't show (what may send the change back). "absent"
# (the screen the repro needs is what the change adds) counts as new; "can't tell" (the re-check couldn't get there or
# couldn't tell) is unconfirmed: for the judge, never a send back.
recheck_classify() {
  local line id sev r tag
  X_LINES="" X_NEW=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id=$(echo "$line" | sed -E 's/^- (F[0-9]+) .*/\1/')
    sev=$(echo "$line" | sed -E 's/^- F[0-9]+ \((blocker|minor)\).*/\1/')
    r=""
    [ -n "${1:-}" ] && r=$(grep -m1 -E "^- $id: " "$1" | sed -E "s/^- $id: *(same|different|absent|can't tell).*/\1/")
    case "$r" in
      same) tag=pre-existing ;;
      different|absent) tag=new ;;
      "can't tell") tag=unconfirmed ;;
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

# accept_disputes: the acceptance tests the builder disputes (disputes.md "## accept: <test>" headings), on one line
accept_disputes() {
  disputes "none-such" | sed -n 's/^## *accept: *//p' | paste -sd ';' -
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
    # What QA saw go wrong beyond the expectations: the judge reads these even on a PASS.
    awk '/^Defects:/ { f = 1; sub(/^Defects: */, ""); if ($0 != "") print "- Defects: " $0; else print "- Defects:"; next }
         f && /^  / { print; next } { f = 0 }' "$RUN/qa-$n/report.md" 2> /dev/null | grep . || echo "- Defects: not reported"
    d=$(disputed_ids)
    [ "$d" = none ] && echo "- Disputed by the builder: none" \
      || echo "- Disputed by the builder: $d; reasons for the judge: \`$HANDBACK/disputes.md\`"
    echo "- Report: \`$HANDBACK/qa-$n/report.md\`; evidence: $(cd "$dir" && ls *.png 2> /dev/null | tr '\n' ' ')"
  } > "$RUN/qa-$n/section.md"
  write_section "Runtime check (QA)" "$RUN/qa-$n/section.md"
  needs_section "$RUN_ASSESSMENT" > "$RUN/qa-$n/needs-section.md"
  write_section "Test needs (runner)" "$RUN/qa-$n/needs-section.md"
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

# calibrate: one line a finished loop run in $FACTORY_RUNS/.calibration.tsv, what its size bought against what it used,
# to tune the size table on (the dashboard shows it).
calibrate() {
  local f=$FACTORY_RUNS/.calibration.tsv longest=0 t0 t1 x mins
  for x in "$RUN"/build-*.time; do
    [ -f "$x" ] || continue
    read -r t0 t1 _ < "$x"; [ $((t1 - t0)) -gt "$longest" ] && longest=$((t1 - t0))
  done
  mins=$(python3 - "$EV" <<'PY'
import sys, datetime
ts = [l.split(" ", 1)[0] for l in open(sys.argv[1]) if l[:2] == "20"]
p = lambda t: datetime.datetime.strptime(t, "%Y-%m-%dT%H:%M:%SZ")
print(round((p(ts[-1]) - p(ts[0])).total_seconds() / 60) if ts else 0)
PY
)
  [ -f "$f" ] || printf 'ended\tticket\trun\tsize\tsize_from\tlimits_set\trounds\tspent\tloop_usd\tminutes\tlongest_builder_min\tstatus\n' > "$f"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$TICKET" "$ID" "$SIZE" "$SIZE_FROM" \
    "$(limits_changed)" "$((builds - FIRST))" "$SPENT" "$LOOP_USD" "$mins" "$((longest / 60))" "$(echo "$STATUS" | cut -c1-120)" >> "$f"
}

# assess_stage <dir>: the assessor, a fresh read-only session in <dir> (the repo at the run's base): the ticket's size
# class and its test needs, written to $RUN_ASSESSMENT. It sees the ticket's fixtures and the provided catalog's descriptions, never a
# provided resource's files. Its row waits in ASSESS_ROW for runs.md's header.
assess_stage() {
  local dir=$1 raw="$RUN/assess.raw" c e out t0 t1 st tu co de
  ASSESS_ROW=""
  { fill "$SKILL/prompts/assess.txt"
    echo; echo "## Size classes"
    echo "Each class sets the limits it names; the others keep the defaults: builder \$$B_USD and $B_MIN min a round, $ITER_CAP rounds, reviewer \$$R_USD, QA \$$QA_USD, \$$LOOP_USD a run."
    for c in $SIZE_CLASSES; do eval "e=\${SIZE_$c:-}"; echo "- $c: ${e:-the defaults}"; done
    echo; echo "## This ticket's fixtures (written for it, in $TICKET.fixtures/)"
    catalog "$FIXTURES_DIR" fixture.md | grep . || echo "none yet"
    echo; echo "## Provided catalog (resources a human set up on this machine)"
    catalog "$FACTORY_PROVIDED" provided.md | grep . || echo "none yet"
  } > "$RUN/assess.prompt"
  run_claude assess "$A_MIN" "$dir" -p "$(cat "$RUN/assess.prompt")" --model "$A_MODEL" \
    --append-system-prompt "$(awk 'f > 1; /^---$/ { f++ }' "$SKILL/agents/factory-assessor.md")" \
    --max-budget-usd "$A_USD" --tools Read Grep Glob Bash --allowedTools "${REVIEW_TOOLS[@]}" --add-dir "$SPEC_DIR" \
    --disallowedTools Edit Write --output-format json
  jq -r '.result // ""' "$RUN/assess.json" > "$raw" 2> /dev/null
  if grep -qE '^Size: ' "$raw"; then
    { echo "<!-- The factory's assessment of $TICKET, by $A_MODEL on $(date -u +%F), from $BASE. Edit it to overrule the assessor: Size sets the run's limits (SIZE in $TICKET.sh, --size and --set beat it), each Needs line what QA gets. -->"
      sed -n '/^Size: /,$p' "$raw"; } > "$RUN_ASSESSMENT"
    out="size $(assessment_field "$RUN_ASSESSMENT" Size), $(needs_lines "$RUN_ASSESSMENT" | grep -c .) test need(s)"
  else
    out="no usable assessment (assess.json): size $SIZE_DEFAULT, no test needs"
  fi
  read -r t0 t1 _ < "$RUN/assess.time"
  read -r st tu co de <<< "$(fields "$RUN/assess.json")"
  ASSESS_ROW="| 0 | assessor | $(python3 -c "print(round(($t1-$t0)/60,1))") | $st | $tu | $co | $de | $out |"
  add_usd "$co"
  ev "assess: $out"
}

finish() {
  provided_release
  ev "end: $STATUS · spent \$$SPENT"
  rmdir "$QA_ROOT" 2> /dev/null
  exit 0
}

TABLE_HEAD='| Run | Role | Min | subtype | Turns | Cost $ | Denials | Outcome |
|---|---|---|---|---|---|---|---|'
if [ -n "$ASSESS_ONLY" ]; then
  printf '# Assess only · %s · %s\nRef: %s\n\n%s\n' "$TICKET" "$STAMP" "$BASE" "$TABLE_HEAD" > "$RUNS"
  assess_stage "$REPO"
  echo "$ASSESS_ROW" >> "$RUNS"
  if [ -s "$RUN_ASSESSMENT" ]; then
    # The ticket's last assessment, edits and all, stays next to it.
    [ -f "$ASSESSMENT" ] && cp "$ASSESSMENT" "$ASSESSMENT.prev"
    cp "$RUN_ASSESSMENT" "$ASSESSMENT"
    STATUS="assessed: size $(assessment_field "$ASSESSMENT" Size), $(needs_lines "$ASSESSMENT" | grep -c .) test need(s)"
    cat "$ASSESSMENT"
    echo "written: $ASSESSMENT$([ -f "$ASSESSMENT.prev" ] && echo " (the one before: $TICKET.assessment.md.prev)")"
  else
    STATUS="error: no usable assessment ($RUN/assess.json)"
    echo "$STATUS"
  fi
  finish
fi

# The run's assessment (a loop run without one gets one first, from the base), then its limits and test needs.
if [ -z "$RESUME_RUN$QA_ONLY$TEST_ONLY" ] && [ ! -s "$RUN_ASSESSMENT" ] && [ "$ASSESS" = yes ]; then
  assess_stage "$REPO"
  [ -s "$RUN_ASSESSMENT" ] && [ ! -f "$ASSESSMENT" ] && cp "$RUN_ASSESSMENT" "$ASSESSMENT"
fi
# A resumed run keeps the --size and --set it started with; the ones given to the resume win.
if [ -n "$RESUME_RUN" ]; then CLI_SIZE=${CLI_SIZE:-${S_CLI_SIZE:-}}; CLI_SETS="${S_CLI_SETS:-}$CLI_SETS"; fi
resolve_limits "$([ -s "$RUN_ASSESSMENT" ] && echo "$RUN_ASSESSMENT")" "$CLI_SIZE" "$CLI_SETS" \
  || { STATUS="error: the limits don't resolve (see above)"; finish; }
printf '%s' "$LIMITS_LOG" > "$RUN/limits.txt"
# QA's limits grow with what the Runtime check asks (steps and expectations), unless set on purpose.
QA_ITEMS=$(section "$TICKET_FILE" "Runtime check" | grep -cE '^ *([0-9]+\.|- E[0-9]+)')
f=$(scale_factor "${QA_ITEMS:-0}" "$QA_SCALE_ITEMS")
QA_MIN=$(scaled QA_MIN "$f") QA_USD=$(scaled QA_USD "$f")
[ -z "$TEST_ONLY" ] && ev "limits: size $SIZE from $SIZE_FROM${SIZE_NOTE:+ ($SIZE_NOTE)}; set: $(limits_changed)$([ "$f" -gt 1 ] && echo "; QA x$f for $QA_ITEMS steps and expectations: \$$QA_USD, $QA_MIN min")"
if [ "$QA" = yes ]; then
  needs_preflight "$RUN_ASSESSMENT"
  if [ -n "$NEEDS_MISSING" ]; then
    printf '%s' "$NEEDS_MISSING" > "$RUN/needs-missing.txt"
    STATUS="needs input before the run: $(printf '%s' "$NEEDS_MISSING" | paste -sd ';' - | sed 's/;/; /g'); then run it again"
    notify "the run needs input: $(printf '%s' "$NEEDS_MISSING" | head -1)"
    echo "$STATUS"
    finish
  fi
fi

if [ -n "$QA_ONLY" ]; then
  REF=$(git -C "$REPO" rev-parse --verify "$QA_ONLY^{commit}") || { echo "unknown ref $QA_ONLY" >&2; exit 2; }
  printf '# QA only · %s · %s\nRef: %s\n\n%s\n' "$TICKET" "$STAMP" "$REF" "$TABLE_HEAD" > "$RUNS"
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
Size: $SIZE, from $SIZE_FROM${SIZE_NOTE:+ ($SIZE_NOTE)} · set: $(limits_changed) · all limits: \`limits.txt\`

$TABLE_HEAD
EOF
[ -n "${ASSESS_ROW:-}" ] && echo "$ASSESS_ROW" >> "$RUNS"
fi

# The builder's deny rules: every protected path (a folder denies everything under it) plus the outward-facing commands.
for p in $PROTECTED_PATHS; do
  [ -d "$REPO/$p" ] && p="$p/**"
  printf '"Edit(%s)"\n"Write(%s)"\n' "$p" "$p"
done | { cat; printf '"Edit(/%s/**)"\n"Write(/%s/**)"\n' "$SPEC_DIR" "$SPEC_DIR"; printf '"%s"\n' "${DENY_BASH[@]}"; } \
  | jq -s '{permissions: {deny: .}}' > "$RUN/builder-settings.json"

builds=0 reason="" from="" stall=0 last_v="" last_af="" xsend=0 LAST_X=""
if [ -n "$RESUME_RUN" ]; then
  builds=$S_builds FIRST=$S_FIRST reason=$S_reason from=$S_from xsend=$S_xsend LAST_X=$S_LAST_X last_v=$S_last_v
  stall=$S_stall SPENT=$S_SPENT last_af=${S_last_af:-}
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
  # Set up at the start (the VM boots with the first build or test), and again after a stage powered it off.
  if [ "$BUILD_VM_UP" != yes ]; then
    build_vm_up "$WT"
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
      --permission-mode acceptEdits --settings "$RUN/builder-settings.json" --add-dir "$SKILL/templates" --add-dir "$SPEC_DIR" --add-dir "$BUILD_VM/app" \
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
    case "$rc/$st" in
      142/*) out="time box ($B_MIN min)" ;;
      */success) out="success" ;;
      */error_max_budget_usd) out="cap: dollars" ;;
      *) out="error: $st (exit $rc)" ;;
    esac
    # A builder stopped by its limit before its code commit leaves its work in the worktree: the runner commits it as a
    # checkpoint, and the next round goes on from there instead of starting over (the round is sent back, unverified).
    ckpt=""
    if { [ "$rc" = 142 ] || [ "$st" = error_max_budget_usd ]; } && [ -n "$(git -C "$WT" status --porcelain -- . ':(exclude)handback')" ]; then
      wtgit add -A -- . ':(exclude)handback' \
        && wtgit commit -q -m "$TICKET: Work in progress, checkpointed by the runner ($name stopped: $out)" \
        && ckpt=$(git -C "$WT" rev-parse --short HEAD) && ev "$name: its unfinished work checkpointed as $ckpt"
    fi
    # A builder stopped by its time box after its code commit is not a failed round: the runner commits what it left
    # and verifies the commit like any other.
    ensure_handback "$name"
    apply_docs
    if [ -n "$ckpt" ]; then
      : > "$RUN/verify-$builds.accept-fails"
      v="red: stopped by its limit before committing; the runner committed the unfinished work as checkpoint $ckpt, on the branch: go on from it, don't redo it (raise the limit if a round is too short: SIZE or B_MIN in the ticket .sh, --set B_MIN=<min>)"
    else
      v=$(verify "$builds")
    fi
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
    # An oracle that contradicts the spec can't be fixed by the builder, who may not edit it: a disputed acceptance
    # test, or the same accept tests red twice in a row, stops for a human instead of sending back until the cap.
    if [ "${v#red}" != "$v" ]; then
      acc_d=$(accept_disputes) acc_f=$(paste -sd ';' - < "$RUN/verify-$builds.accept-fails" 2> /dev/null)
      if [ -n "$acc_d" ]; then
        STATUS="needs a human: the builder disputes the acceptance test ($acc_d; reasons in $HANDBACK/disputes.md): fix the oracle or overrule the dispute, then --continue"
        notify "the builder disputes the acceptance test: $acc_d"; break
      fi
      if [ -n "$acc_f" ] && [ "$acc_f" = "$last_af" ]; then
        STATUS="needs a human: the same acceptance tests failed two verifies in a row ($acc_f): the oracle may contradict the spec (the builder's hand-back says why), then --continue"
        notify "the same acceptance tests failed twice: $acc_f"; break
      fi
      last_af=$acc_f
    else
      last_af=""
    fi
    case "$v" in
      green)
        # One VM per run at a time: review needs none and QA boots its own clean clone, so the build VM goes now and
        # the next builder round boots a fresh one (the build output lives in the worktree, on the Mac, not in the VM).
        if [ "$BUILD_VM_UP" = yes ]; then "$VM/vmctl.sh" down "$BUILD_VM" >> "$EV" 2>&1; BUILD_VM_UP=no; fi ;;
      error*) STATUS="harness error in verify: ${v#error: }"; break ;;
      *) reason="builder run $builds: $out; runner verify $v"; from=verify; STATUS="send back: $reason"; continue ;;
    esac
  fi

  if [ -z "$SKIP" ] || [ "$SKIP" = review ]; then
    SKIP=""
    save_state review
    if [ -e "$RUN/PAUSE" ]; then STATUS="paused before review $builds (verified): factory.sh resume $ID"; break; fi
    if [ -e "$RUN/STOP" ]; then STATUS="stopped: STOP file (verified, not reviewed)"; break; fi
    rname=review-$builds
    # The reviewer's limits grow with the diff, unless set on purpose.
    lines=$(git -C "$WT" diff --shortstat "$BASE" HEAD -- . ':(exclude)handback' \
      | awk '{ for (i = 1; i < NF; i++) if ($(i + 1) ~ /^(insertion|deletion)/) n += $i } END { print n + 0 }')
    f=$(scale_factor "$lines" "$R_SCALE_LINES")
    r_min=$(scaled R_MIN "$f") r_usd=$(scaled R_USD "$f")
    [ "$f" -gt 1 ] && ev "$rname: $lines changed lines: reviewer x$f, \$$r_usd, $r_min min"
    if over "$SPENT + $r_usd" "$LOOP_USD"; then STATUS="verified, not reviewed (loop budget)"; break; fi
    # A re-review (an earlier review is in the hand-back, from this run or the one it continues) starts from what changed
    # since the code that review saw, and says so: a re-review that only restates the last one checks nothing.
    rev_code=$(git -C "$WT" log -1 --format=%h -- . ':(exclude)handback')
    rev_prev=$(section "$WT/$HANDBACK/hand-back.md" "Review (reviewer)" 2> /dev/null | sed -n 's/^- Reviewed code: *\([0-9a-f]*\).*/\1/p' | head -1)
    { fill "$SKILL/prompts/review.txt"
      [ -n "$rev_prev" ] && sed -e "s|@PREV@|$rev_prev|g" -e "s|@CODE@|$rev_code|g" "$SKILL/prompts/re-review.txt"
    } > "$RUN/$rname.prompt"
    run_claude "$rname" "$r_min" "$WT" -p "$(cat "$RUN/$rname.prompt")" --model "$R_MODEL" \
      --append-system-prompt "$(awk 'f > 1; /^---$/ { f++ }' "$SKILL/agents/factory-reviewer.md")" --add-dir "$PROFILE_DIR" --add-dir "$SPEC_DIR" \
      --max-budget-usd "$r_usd" --tools Read Grep Glob Bash --allowedTools "${REVIEW_TOOLS[@]}" --disallowedTools Edit Write \
      --output-format json
    jq -r '.result // ""' "$RUN/$rname.json" > "$RUN/$rname.md" 2> /dev/null
    rec=$(grep -m1 '^- Recommend:' "$RUN/$rname.md" | sed 's/^- Recommend: *//')
    if [ -z "$rec" ]; then
      row "$builds" reviewer "$rname" "no usable review output"
      STATUS="verified, review missing"; break
    fi
    since=""
    if [ -n "$rev_prev" ] && ! grep -m1 '^- Design:' "$RUN/$rname.md" | grep -qi "since $rev_prev"; then
      since="- Re-review: the Design line doesn't say what changed since $rev_prev, the code the last review saw"
      ev "$rname: a re-review that doesn't name the changes since $rev_prev"
    fi
    { grep '^- ' "$RUN/$rname.md"; [ -n "$since" ] && echo "$since"
      echo "- Reviewed code: $rev_code"; echo "- Written back to the harness: none"; } > "$RUN/$rname.section.md"
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
    # A resource only a human can provide: the run pauses before QA (its state says so) and goes on once it is there.
    NEEDS-INPUT*) STATUS="needs input for runtime QA: ${QA_VERDICT#NEEDS-INPUT: }; provide it (factory.sh provide <name>), then factory.sh resume $ID"
                  notify "QA needs input: ${QA_VERDICT#NEEDS-INPUT: }"; break ;;
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
  echo "- Size: $SIZE, from $SIZE_FROM · limits set: $(limits_changed) · test needs: $(needs_lines "$RUN_ASSESSMENT" | grep -c .)"
  echo "- Hand-back for the judge: \`${WT#$REPO/}/$HANDBACK/hand-back.md\`"
  [ -n "$LAST_X" ] && echo "- Last round's ${LAST_X}; tour, findings and base re-check in the hand-back's Exploratory QA section"
  [ -s "$WT/$HANDBACK/disputes.md" ] && echo "- Disputed by the builder (the judge decides): $(disputed_ids); reasons: \`${WT#$REPO/}/$HANDBACK/disputes.md\`"
  echo "- Run log: \`$RUNS\` · events: \`$EV\` · every run's JSON, stderr and prompt: \`$RUN/\`"
} > "$RUN/loop-handback.md"
cat "$RUN/loop-handback.md"
calibrate
finish
}
