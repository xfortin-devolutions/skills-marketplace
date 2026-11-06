#!/bin/bash
# run-loop.test.sh: the factory's runner end to end, on a throwaway repo, with fakes for claude, the VM layer and the
# guest (tests/fakes/). Each scenario scripts the agents' sessions and checks how the run ends. No VM, no model, no
# money: a scenario takes seconds. Run it after any change to run-loop.sh, factory.sh or the prompts it reads.
#   tests/run-loop.test.sh [scenario...]      all scenarios, or the ones named
# bash 3.2 compatible.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SKILL=$(cd "$HERE/../skills/factory" && pwd)
FAKES=$HERE/fakes
PASSED=0 FAILED=0 FAILS=""

# setup: a fresh repo with a demo project (.factory/), a ticket and the fakes' environment.
setup() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/factory-test.XXXXXX")
  T=$(cd "$T" && pwd -P)
  R=$T/repo
  mkdir -p "$R" "$T/tickets" "$T/state" "$T/vms/windows"
  : > "$T/vms/windows/base.qcow2"
  (
    cd "$R" || exit 1
    git init -q -b master && git config user.email test@example.com && git config user.name Test
    mkdir -p .factory/profiles/demo/targets/windows src tests
    printf 'DEFAULT_PROFILE=demo\nDOC_PATHS="docs/"\n' > .factory/config.sh
    printf 'APP_NAME=Demo\nTARGETS=windows\nCODE_PATHS="src/"\nBRANCH_PREFIX=factory/\nREVIEW_STANDARDS=none\n' > .factory/profiles/demo/profile.sh
    printf 'GUEST_OS=windows\nGUEST_DESC="Fake OS"\nGUEST_BUILD=$TARGET_DIR/build.ps1\nGUEST_TEST=$TARGET_DIR/test.ps1\nGUEST_LAUNCH=$TARGET_DIR/launch.ps1\n' \
      > .factory/profiles/demo/targets/windows/target.sh
    for f in build test launch; do echo "# fake" > ".factory/profiles/demo/targets/windows/$f.ps1"; done
    echo app > src/app.txt
    echo "the oracle" > tests/accept.txt
    git add -A && git commit -qm "base with the oracle"
  )
  printf '# DEMO-1 — Demo feature\n\n## Context\nA demo.\n\n## Runtime check\nPlatform: windows\nUse the feature.\n' > "$T/tickets/DEMO-1.md"
  printf "PROFILE=demo\nACCEPT_TEST=Accept.Tests\nORACLE_PATHS=tests/\nSCOPE_REGEX='^src/'\n" > "$T/tickets/DEMO-1.sh"
  printf 'FACTORY_VM_ROOT=%s/vms\nGIT_SETTLE_S=2\n' "$T" > "$T/user.sh"
  : > "$T/scenario.sh"
  export FACTORY_TICKETS=$T/tickets FACTORY_USER_CONFIG=$T/user.sh FACTORY_VM_DIR=$FAKES/vm FACTORY_GUEST_SH=$FAKES/guest.sh
  export FACTORY_NEG_CACHE=$T/negative FACTORY_PROVIDED=$T/provided FAKE_STATE=$T/state FAKE_SCENARIO=$T/scenario.sh FAKE_SKILL=$SKILL
  export FAKE_RUNS=$R/.claude/worktrees/factory-runs
  export PATH=$FAKES/bin:$PATH
}

loop() { (cd "$R" && bash "$SKILL/scripts/run-loop.sh" DEMO-1 "$@" > "$T/out" 2>&1); RUN=$(ls -1dt "$FAKE_RUNS"/demo-1-*/ | head -1); RUN=${RUN%/}; }
teardown() { git -C "$R" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}' | tail -n +2 \
  | while read -r w; do git -C "$R" worktree remove --force "$w" 2> /dev/null; done; rm -rf "$T"; }

# Checks: each records a failure and goes on, so one scenario reports everything it got wrong.
ok=yes
fail() { ok=no; echo "    ✗ $*"; }
end_line() { grep ' end: ' "$RUN/events.log" | tail -1 | sed -e 's/^[^ ]* end: //' -e 's/ · spent .*$//'; }
expect_end() { end_line | grep -qE "$1" || fail "end: wanted /$1/, got: $(end_line)"; }
expect_event() { grep -qE "$1" "$RUN/events.log" || fail "no event /$1/"; }
expect_no_event() { ! grep -qE "$1" "$RUN/events.log" || fail "unexpected event /$1/: $(grep -m1 -E "$1" "$RUN/events.log")"; }
expect_calls() { local n; n=$(grep -c "^$1 " "$FAKE_STATE/calls.log" 2> /dev/null); [ "${n:-0}" = "$2" ] || fail "$1 sessions: wanted $2, got ${n:-0}"; }
hb() { echo "$(ls -d "$R"/.claude/worktrees/demo-1-build-*/ | head -1)handback/factory-demo-1-build-$(basename "$RUN" | sed 's/^demo-1-//')"; }
expect_file() { grep -qE "$2" "$1" 2> /dev/null || fail "$(basename "$1"): no /$2/"; }
# expect_result <station|end> <code>: the runner's last code for it in results.log (run-loop.sh: result).
expect_result() { local got; got=$(awk -v k="$1" '$1 == k { c = $2 } END { print c }' "$RUN/results.log" 2> /dev/null)
  [ "$got" = "$2" ] || fail "result $1: wanted $2, got ${got:-none}"; }
one_vm() { [ "$(cat "$FAKE_STATE/vms-max" 2> /dev/null)" = 1 ] || fail "the run held $(cat "$FAKE_STATE/vms-max" 2> /dev/null) VMs at once"; }

# The scenarios. Each writes the agents it changes into $T/scenario.sh (see fakes/agents.sh for the defaults).

t_happy() {
  loop
  expect_end '^ready for the judge \(Recommend: merge; runtime QA PASS; exploratory QA: 0 finding'
  expect_calls builder 1; expect_calls reviewer 1; expect_calls qa 1; expect_calls charter 1; expect_calls explorer 1
  expect_file "$(hb)/verification-record.md" '^- Verdict: PASS$'
  expect_file "$(hb)/verification-record.md" '^- Tool: factory runner'
  expect_file "$(hb)/verification-record.md" 'expected fail: accept fails without the change'
  expect_file "$(hb)/verification-record.md" '^\| 2 \| .*/guest build \| 0 \| green \|$'
  expect_file "$(hb)/verification-record.md" '^\| 3 \| .*/guest test --no-build Accept.Tests \| 0 \| 3 passed, 0 failed, 0 skipped \|$'
  expect_file "$(hb)/hand-back.md" '^- Verification record: .* → PASS \(written by the runner\)'
  expect_file "$(hb)/hand-back.md" '^- Defects: not reported$'
  for k in build-1 verify-1 review-1 charter-1 qa-1 explore-1 end; do expect_result $k proceed; done
  # The charter's line naming a code file never reaches the explorer.
  expect_file "$FAKE_STATE/explorer-1.prompt" 'Use the feature twice'
  ! grep -q OtherWindow "$FAKE_STATE/explorer-1.prompt" || fail "a charter line naming code reached the explorer"
  # A second run on the same base keeps the first one's negative run.
  rm -f "$FAKE_STATE"/*.n
  loop
  expect_end '^ready for the judge'
  expect_event 'negative run: kept from run demo-1-'
  one_vm
  ! grep -q 'unbound variable' "$T/out" || fail "runner: $(grep -m1 'unbound variable' "$T/out")"
}

t_timebox_after_commit() {
  echo 'builder_1() { commit_code done; return 142; }' > "$T/scenario.sh"
  loop
  expect_end '^ready for the judge'
  expect_calls builder 1
  expect_event 'build-1 wrote no hand-back: the runner started one'
  expect_event 'build-1 outcome=time box .* verify=green'
  expect_file "$(hb)/hand-back.md" '^- What changed: DEMO-1: Changed the feature \(done\); the builder stopped'
}

# A builder stopped by its time box before its commit: the runner checkpoints its work, the next round goes on from it.
t_timebox_checkpoint() {
  cat > "$T/scenario.sh" <<'EOF'
builder_1() { mkdir -p src; echo half > src/feature.txt; return 142; }
builder_2() { grep -q half src/feature.txt && touch "$FAKE_STATE/saw-half"; echo done > src/feature.txt; git add src; git commit -qm "DEMO-1: Finished the feature"; write_handback; }
EOF
  loop
  expect_end '^ready for the judge'
  expect_event 'build-1: its unfinished work checkpointed as [0-9a-f]+'
  expect_event 'build-1 outcome=time box .* verify=red: stopped by its limit before committing'
  expect_file "$FAKE_STATE/builder-2.prompt" 'checkpoint [0-9a-f]+, on the branch: go on from it'
  expect_result build-1 new-round; expect_result verify-1 new-round; expect_result build-2 proceed; expect_result end proceed
  [ -e "$FAKE_STATE/saw-half" ] || fail "the second builder did not find the first one's work"
  git -C "$(ls -d "$R"/.claude/worktrees/demo-1-build-*/ | head -1)" log --format=%s | grep -q 'Work in progress, checkpointed by the runner' \
    || fail "no checkpoint commit on the branch"
}

t_qa_fail_then_fix() {
  cat > "$T/scenario.sh" <<'EOF'
qa_1() { printf 'Verdict: FAIL\nSummary: the groups do not move\nHuman: none\n'; }
builder_2() { commit_code "done, groups move"; write_handback; }
EOF
  loop
  expect_end '^ready for the judge'
  expect_calls builder 2; expect_calls qa 2
  expect_file "$FAKE_STATE/builder-2.prompt" 'runtime check failed \(QA run 1\): the groups do not move'
  expect_result qa-1 new-round; expect_result qa-2 proceed; expect_result end proceed
  expect_no_event 'explore-1:'
  # The second review is a re-review from the code the first one saw; the default fake doesn't say what changed.
  expect_file "$FAKE_STATE/reviewer-2.prompt" 'This is a re-review: .* the code at [0-9a-f]+'
  expect_event "review-2: a re-review that doesn't name the changes since"
  expect_file "$(hb)/hand-back.md" '^- Reviewed code: [0-9a-f]+$'
  one_vm
}

t_re_review_names_changes() {
  cat > "$T/scenario.sh" <<'EOF'
qa_1() { printf 'Verdict: FAIL\nSummary: the groups do not move\nHuman: none\n'; }
builder_2() { commit_code "done, groups move"; write_handback; }
reviewer_2() { reviewer | sed "s/^- Design: OK: /- Design: OK: since $(git log --format=%h -- src | sed -n 2p): src\/feature.txt now moves the groups; /"; }
EOF
  loop
  expect_end '^ready for the judge'
  expect_no_event "a re-review that doesn't name"
  ! grep -q '^- Re-review:' "$(hb)/hand-back.md" || fail "a re-review that named its changes was flagged"
}

t_vm_on_demand() {
  # The builder reads and thinks first: the build VM boots with its first build, not before the session.
  cat > "$T/scenario.sh" <<'EOF'
builder_1() { grep -q '^vm up vm-build' "$FAKE_STATE/calls.log" && echo early > "$FAKE_STATE/vm-early"; "$(run_dir)guest" build > /dev/null; commit_code done; write_handback; }
EOF
  loop
  expect_end '^ready for the judge'
  [ ! -e "$FAKE_STATE/vm-early" ] || fail "the build VM was up before the builder's first build"
  expect_event 'build VM up \(on demand\)'
  one_vm
}

t_vm_idle() {
  # A builder that thinks longer than VM_IDLE_MIN after a build lets its VM go; verify boots a fresh one.
  export FACTORY_VM_IDLE_S=2 FACTORY_REAP_POLL_S=1
  cat > "$T/scenario.sh" <<'EOF'
builder_1() { "$(run_dir)guest" build > /dev/null; sleep 5; commit_code done; write_handback; }
EOF
  loop
  unset FACTORY_VM_IDLE_S FACTORY_REAP_POLL_S
  expect_end '^ready for the judge'
  expect_event 'build VM down: idle for 2 s, its slot is free'
  [ "$(grep -c '^vm up vm-build' "$FAKE_STATE/calls.log")" = 2 ] || fail "wanted 2 build VM boots: $(grep -c '^vm up vm-build' "$FAKE_STATE/calls.log")"
  one_vm
}

t_qa_defects() {
  cat > "$T/scenario.sh" <<'EOF'
qa_1() { printf 'Verdict: PASS\nSummary: works\nSteps:\n1. looked\nDefects:\n  a notification covered the grid; 1 of 2 tries; elsewhere; evidence: 04.png\nHuman: none\n'; }
EOF
  loop
  expect_end '^ready for the judge'
  expect_file "$(hb)/hand-back.md" '^- Defects:$'
  expect_file "$(hb)/hand-back.md" '^  a notification covered the grid; 1 of 2 tries; elsewhere'
}

t_stall() {
  echo 'builder() { :; }' > "$T/scenario.sh"
  loop
  expect_end '^needs a human: 2 builder runs in a row changed nothing'
  expect_calls builder 2
}

t_same_binaries() {
  # QA fails, and the builder sends the same commit back: nothing changed, so the run stops at once.
  cat > "$T/scenario.sh" <<'EOF'
qa_1() { printf 'Verdict: FAIL\nSummary: broken\nHuman: none\n'; }
builder_2() { :; }
EOF
  loop
  expect_end '^needs a human: send back 2 changed no code'
  expect_calls builder 2
}

t_iteration_cap() {
  cat > "$T/scenario.sh" <<'EOF'
REVIEW="send back"
builder() { commit_code "done $(cat "$FAKE_STATE/builder.n")"; write_handback; }
EOF
  loop
  expect_end '^reject: iteration cap \(5 builder runs\)'
  expect_calls builder 5
  expect_result review-5 new-round; expect_result end rejected
}

t_flaky() {
  echo 'builder_1() { commit_code done; mkdir -p "$(hb_dir)"; echo "Flaky.Tests" > "$(hb_dir)/tests.txt"; write_handback; }' > "$T/scenario.sh"
  loop
  expect_end '^ready for the judge'
  expect_file "$(hb)/verification-record.md" '^- Flaky: Flaky.Tests: failed 1 of 2 runs$'
  expect_file "$(hb)/verification-record.md" '^- Verdict: PASS$'
}

t_failing_listed_test() {
  cat > "$T/scenario.sh" <<'EOF'
builder_1() { commit_code done; mkdir -p "$(hb_dir)"; echo "Regress.Tests SomeFilter" > "$(hb_dir)/tests.txt"; write_handback; }
builder_2() { : > "$(hb_dir)/tests.txt"; git add handback; git commit -qm "handback: dropped the broken test"; }
EOF
  loop
  expect_end '^ready for the judge'
  expect_event 'build-1 .*verify=red: tests fail in the guest Regress.Tests SomeFilter: not on the base: Regress.Tests.It'
  grep -q 'test --no-build Regress.Tests SomeFilter' "$FAKE_STATE/guest.log" || fail "the listed test did not run with its filter"
  [ "$(grep -c 'test --no-build Regress.Tests' "$FAKE_STATE/guest.log")" = 3 ] || fail "a failing test runs 1 + FLAKY_RERUNS times"
  [ "$(grep -c '^test Regress.Tests SomeFilter' "$FAKE_STATE/guest.log")" = 3 ] || fail "the base check runs the test 1 + FLAKY_RERUNS times, building it"
  one_vm
}

# A listed test the base fails too is pre-existing: green, listed for the judge, and checked on the base once per base.
t_listed_red_on_base_too() {
  cat > "$T/scenario.sh" <<'EOF'
REVIEW="send back"
builder_1() { commit_code done; mkdir -p "$(hb_dir)"; echo "Broken.Tests" > "$(hb_dir)/tests.txt"; write_handback; }
builder_2() { commit_code "done again"; write_handback; }
builder_3() { commit_code "done thrice"; write_handback; }
EOF
  loop
  expect_no_event 'verify=red'
  expect_file "$(hb)/verification-record.md" '^- Pre-existing \(red on the base too, so not this change.s\): Broken.Tests: 1 failing test\(s\) also fail on the base$'
  expect_file "$(hb)/verification-record.md" '^- Verdict: PASS$'
  [ "$(grep -c '^test Broken.Tests' "$FAKE_STATE/guest.log")" = 3 ] || fail "the base check ran more than once for one base: $(grep -c '^test Broken.Tests' "$FAKE_STATE/guest.log") base runs"
  one_vm
}

t_accept_passes_on_base() {
  touch "$FAKE_STATE/accept-always-passes"
  loop
  expect_end '^harness error in verify: the acceptance test passes on the base'
  expect_result verify-1 rerun; expect_result end rerun
}

t_build_fails() {
  echo 'builder_1() { commit_code done; touch BROKEN; git add BROKEN 2>/dev/null; write_handback; }' > "$T/scenario.sh"
  printf "PROFILE=demo\nACCEPT_TEST=Accept.Tests\nORACLE_PATHS=tests/\nSCOPE_REGEX='^(src/|BROKEN)'\n" > "$T/tickets/DEMO-1.sh"
  cat >> "$T/scenario.sh" <<'EOF'
builder_2() { git rm -q BROKEN; git commit -qm "DEMO-1: Fixed the build"; }
EOF
  loop
  expect_end '^ready for the judge'
  expect_event 'build-1 .*verify=red: the Fake OS build fails: src/a.cs'
}

# A red build whose clean rebuild hits a restore failure gets one more build: the builder never sees a harness error.
t_restore_flake_on_clean() {
  touch "$FAKE_STATE/restore-flake"
  loop
  expect_end '^ready for the judge'
  expect_calls builder 1
  expect_file "$RUN/verify-1.log" 'harness error on the clean rebuild: one more build'
}

# A builder that disputes the acceptance test stops the run for a human instead of being sent back to the cap.
t_accept_dispute() {
  cat > "$T/scenario.sh" <<'EOF'
builder() {
  commit_code "half $(cat "$FAKE_STATE/builder.n")"; d=$(hb_dir); mkdir -p "$d"
  printf '## accept: Accept.Tests.It\n- Contradiction: it expects the opposite of the ticket\n- Why: spec line 3\n' > "$d/disputes.md"
  write_handback
}
EOF
  loop
  expect_result end human
  expect_end '^needs a human: the builder disputes the acceptance test \(Accept.Tests.It'
  expect_calls builder 1
  expect_event 'notify: the builder disputes the acceptance test'
}

# A builder that rewrites its hand-back without the sections after Tests still gets the review and the judge's questions,
# and a doc it stages for a nested .claude folder (sub/.claude/skills/) is copied into place.
t_handback_rewritten_nested_docs() {
  (cd "$R" && echo 'DOC_PATHS="docs/ sub/.claude/skills/"' >> .factory/config.sh && mkdir -p sub/.claude/skills/x \
    && echo old > sub/.claude/skills/x/SKILL.md && git add -A && git commit -qm "a nested skill")
  cat > "$T/scenario.sh" <<'EOF2'
builder() {
  commit_code done; d=$(hb_dir); mkdir -p "$d/docs/sub/claude/skills/x"
  echo new > "$d/docs/sub/claude/skills/x/SKILL.md"
  sed '/^## Review (reviewer)/,$d' "$FAKE_SKILL/templates/hand-back.md" > "$d/hand-back.md"
  write_handback
}
EOF2
  loop
  expect_end '^ready for the judge \(Recommend: merge'
  expect_file "$(hb)/hand-back.md" '^- Recommend: merge$'
  expect_file "$(hb)/hand-back.md" '^## Judge \(human\)$'
  expect_file "$(hb)/../../sub/.claude/skills/x/SKILL.md" '^new$'
  expect_event "applied the builder's staged docs: sub/.claude/skills/x/SKILL.md"
}

# The same accept tests red in two verifies in a row stop for a human, even with no dispute and new code each round.
t_accept_same_fails() {
  echo 'builder() { commit_code "half $(cat "$FAKE_STATE/builder.n")"; write_handback; }' > "$T/scenario.sh"
  loop
  expect_end '^needs a human: the same acceptance tests failed two verifies in a row \(Accept.Tests.It\)'
  expect_calls builder 2
}

t_pause_resume() {
  echo 'builder_1() { commit_code done; write_handback; touch "$(run_dir)PAUSE"; }' > "$T/scenario.sh"
  loop
  expect_end '^paused before review 1 \(verified\): factory.sh resume demo-1-'
  expect_result end stopped
  [ -f "$RUN/state.sh" ] || fail "no state.sh"
  (cd "$R" && bash "$SKILL/scripts/factory.sh" resume "$(basename "$RUN")" > "$T/out2" 2>&1)
  expect_event 'run resumed before review'
  expect_end '^ready for the judge'
  expect_result end proceed
  expect_calls builder 1; expect_calls reviewer 1
  [ "$(ls -d "$FAKE_RUNS"/demo-1-* | wc -l | tr -d ' ')" = 1 ] || fail "resume made a new run folder"
}

t_stop_then_resume() {
  echo 'qa_1() { touch "$(run_dir)STOP"; printf "Verdict: FAIL\nSummary: broken\nHuman: none\n"; }
builder_2() { commit_code "done 2"; write_handback; }' > "$T/scenario.sh"
  loop
  expect_end '^stopped: STOP file$'
  expect_result qa-1 new-round; expect_result end stopped
  (cd "$R" && bash "$SKILL/scripts/factory.sh" resume "$(basename "$RUN")" > "$T/out2" 2>&1)
  expect_end '^ready for the judge'
  expect_calls builder 2
}

t_stale_lock() {
  echo 'builder_1() { commit_code done; write_handback; touch "$(git rev-parse --git-path index.lock)"; }' > "$T/scenario.sh"
  loop
  expect_event 'removed a stale git index.lock'
  expect_end '^ready for the judge'
}

t_no_build_misses() {
  touch "$FAKE_STATE/no-build-misses"
  loop
  expect_end '^ready for the judge'
  # The record shows the command that ran: the one with a build.
  expect_file "$(hb)/verification-record.md" '^\| 3 \| .*/guest test Accept.Tests \| 0 \| 3 passed'
  expect_file "$FAKE_STATE/guest.log" '^test --no-build Accept.Tests'
}

t_busy_lock() {
  touch "$FAKE_STATE/lock-on-test"
  loop
  expect_end '^ready for the judge'
}

t_explore_blocker() {
  cat > "$T/scenario.sh" <<'EOF'
explorer_1() { printf 'Tour:\n1. clicked twice\nFindings:\n- F1 (blocker): the second click empties the grid; evidence: 03.png\n'; }
recheck_1() { echo "- F1: different: the base keeps its rows"; }
builder_2() { commit_code "done, second click fixed"; write_handback; }
EOF
  loop
  expect_end '^ready for the judge \(Recommend: merge; runtime QA PASS; exploratory QA: 0 finding'
  expect_calls builder 2; expect_calls recheck 1
  expect_file "$FAKE_STATE/builder-2.prompt" 'exploratory QA \(run 1\) found blockers .* F1'
  expect_result explore-1 new-round; expect_result recheck-1 new-round; expect_result qa-1 proceed
  expect_result explore-2 proceed; expect_result end proceed
  one_vm
}

t_recheck_cant_tell() {
  cat > "$T/scenario.sh" <<'EOF2'
explorer_1() { printf 'Tour:\n1. set the DevMode registry value over vmssh, restarted the app\n2. clicked twice\nFindings:\n- F1 (blocker): the second click empties the grid; evidence: 03.png\n'; }
recheck_1() { echo "- F1: can't tell: no Dev menu in this build"; }
EOF2
  loop
  expect_end '^ready for the judge'
  expect_calls builder 1
  expect_file "$(hb)/hand-back.md" 'F1 \(blocker, unconfirmed\)'
  expect_file "$FAKE_STATE/recheck-1.prompt" 'set the DevMode registry value over vmssh'
}

# The assessor and the run's limits.
assess() { printf '%s\n' "$@" > "$T/tickets/DEMO-1.assessment.md"; }
limit() { grep -E "^$1=" "$RUN/limits.txt" | grep -qE "^$1=$2" || fail "limits.txt: wanted $1=$2, got: $(grep -E "^$1=" "$RUN/limits.txt")"; }

t_assessor_writes() {
  loop
  expect_end '^ready for the judge'
  expect_calls assessor 1
  expect_file "$T/tickets/DEMO-1.assessment.md" '^Size: M$'
  expect_file "$RUN/runs.md" '^\| 0 \| assessor \| .* size M, 0 test need'
  expect_file "$RUN/runs.md" '^Size: M, from the assessor'
  loop
  expect_calls assessor 1
}

t_size_from_assessment() {
  assess 'Size: L' 'Why: three projects' 'Rounds: 3' 'Split: no' 'Needs: none'
  echo 'SIZE_CEILING="LOOP_USD=50"' >> "$T/user.sh"
  loop
  expect_end '^ready for the judge'
  expect_calls assessor 0
  limit B_USD '15 \(size L\)'; limit B_MIN '90 \(size L\)'
  limit LOOP_USD '50 \(size L, capped at the ceiling 50 \(was 80\)\)'
  limit R_USD '3 \(size L\)'
  expect_event 'limits: size L from the assessor \(three projects\)'
}

t_size_on_purpose() {
  assess 'Size: S' 'Why: tiny' 'Needs: none'
  printf 'SIZE=XL\nSIZE_WHY="a big one"\nB_MIN=500\n' >> "$T/tickets/DEMO-1.sh"
  echo 'SIZE_CEILING="LOOP_USD=50 B_MIN=180"; B_MIN=20' >> "$T/user.sh"
  loop --set ITER_CAP=2 --set B_USD=1.5
  expect_end '^ready for the judge'
  limit LOOP_USD '150 \(size XL, above the ceiling 50\)'
  limit B_MIN '500 \(the ticket .sh: a big one, above the ceiling 180\)'
  limit ITER_CAP '2 \(the command line'
  limit B_USD '1.5 \(the command line'
  expect_file "$RUN/runs.md" 'Size: XL, from the ticket .sh: a big one'
  # A limit that isn't a number never reaches the runner.
  loop --set B_MIN=lots
  grep -q 'B_MIN=lots: a limit is a number' "$T/out" || fail "a bad --set was not refused: $(tail -1 "$T/out")"
}

t_limits_only() {
  (cd "$R" && bash "$SKILL/scripts/run-loop.sh" DEMO-1 --limits-only --size L > "$T/out" 2>&1)
  grep -q '^size L, from the command line' "$T/out" || fail "limits-only: $(head -1 "$T/out")"
  grep -q '^B_USD=15 (size L)' "$T/out" || fail "limits-only: no B_USD=15 (size L)"
  [ ! -d "$FAKE_RUNS" ] || [ -z "$(ls "$FAKE_RUNS")" ] || fail "limits-only made a run folder"
}

t_reviewer_scaled() {
  echo 'R_SCALE_LINES=2' >> "$T/user.sh"
  echo 'builder_1() { mkdir -p src; printf "done\\nb\\nc\\nd\\n" > src/feature.txt; git add src; git commit -qm "DEMO-1: Changed it"; write_handback; }' > "$T/scenario.sh"
  loop
  expect_end '^ready for the judge'
  expect_event 'review-1: [0-9]+ changed lines: reviewer x[23], \$[0-9.]+, [0-9]+ min'
}

# Test needs: fixtures and resources a human provides.
# A fixture is the ticket's own, next to its spec: never in the repo or a profile.
fixture() {
  local d=$T/tickets/DEMO-1.fixtures/$1
  mkdir -p "$d"
  printf '# %s\nWhat: ten demo entries in the default data source\nUse: the entries are in the Demo folder of the navigation pane.\n' "$1" > "$d/fixture.md"
  printf '# apply %s\nCopy-Item "$Dir\\entries.xml" $env:APPDATA\n' "$1" > "$d/apply.ps1"
  echo '<entries/>' > "$d/entries.xml"
}
provided() { # provided <name> <Shared> [check script body]
  local d=$T/provided/$1
  mkdir -p "$d"
  printf '# %s\nWhat: the lab DVLS\nUse: open the data source "Lab" from the data source list.\nAccess: read-only\nShared: %s\n' "$1" "$2" > "$d/provided.md"
  echo 'secret' > "$d/credentials.txt"
  [ -n "${3:-}" ] && echo "$3" > "$d/check.ps1"
  return 0
}

t_fixture() {
  fixture demo-data
  assess 'Size: M' 'Why: x' 'Needs:' '- N1: ten entries in a folder | fixture: demo-data' '- N2: a new RDP entry | qa-setup: create one with host 127.0.0.1'
  loop
  expect_end '^ready for the judge'
  expect_file "$FAKE_STATE/calls.log" '^vmcp demo-data C:\\factory\\fixtures\\demo-data$'
  expect_file "$FAKE_STATE/vmssh.log" '^\$Dir = .C:\\factory\\fixtures\\demo-data.$'
  expect_file "$FAKE_STATE/vmssh.log" '^# apply demo-data$'
  expect_file "$FAKE_STATE/guest/C_/factory/fixtures/demo-data/entries.xml" 'entries'
  expect_file "$FAKE_STATE/qa-1.prompt" '^## Test setup$'
  expect_file "$FAKE_STATE/qa-1.prompt" 'ten entries in a folder: in place .* the Demo folder of the navigation pane'
  expect_file "$FAKE_STATE/qa-1.prompt" 'a new RDP entry: not in place: create it yourself first, as setup steps: create one with host 127.0.0.1'
  expect_file "$FAKE_STATE/explorer-1.prompt" '^## Test setup$'
  expect_file "$(hb)/hand-back.md" '^## Test needs \(runner\)$'
  expect_file "$(hb)/hand-back.md" '^  N1 ten entries in a folder: fixture demo-data$'
  expect_file "$(hb)/hand-back.md" '^  N2 a new RDP entry: set up by QA in the app$'
}

t_fixture_missing() {
  assess 'Size: M' 'Why: x' 'Needs:' '- N1: ten entries in a folder | fixture: demo-data: ten entries in a Demo folder'
  loop
  expect_end '^needs input before the run: fixture demo-data \(ten entries in a folder\): write it, factory.sh fixture DEMO-1 demo-data'
  expect_calls builder 0
}

t_provided_missing() {
  assess 'Size: M' 'Why: x' 'Needs:' '- N1: a DVLS with a Dashboard entry | provided: lab-dvls: a DVLS data source with one Dashboard entry'
  loop
  expect_end '^needs input before the run: provided lab-dvls \(a DVLS with a Dashboard entry\): factory.sh provide lab-dvls'
  expect_calls builder 0
  expect_event 'notify: the run needs input'
}

t_provided_check_then_resume() {
  provided lab-dvls no '# FAKE-FAIL lab'
  touch "$FAKE_STATE/fail-lab"
  assess 'Size: M' 'Why: x' 'Needs:' '- N1: a DVLS with a Dashboard entry | provided: lab-dvls: a DVLS data source'
  loop
  expect_end '^needs input for runtime QA: provided lab-dvls: its check fails in the guest: PS ERROR: the lab server does not answer'
  expect_calls qa 0
  [ ! -d "$T/provided/lab-dvls/.in-use.d" ] || fail "the run kept its lock on lab-dvls"
  rm -f "$FAKE_STATE/fail-lab"
  (cd "$R" && bash "$SKILL/scripts/factory.sh" resume "$(basename "$RUN")" > "$T/out2" 2>&1)
  expect_end '^ready for the judge'
  expect_calls builder 1; expect_calls qa 1
  expect_file "$FAKE_STATE/qa-1.prompt" 'provided by a human .* It is read-only'
  expect_file "$(hb)/hand-back.md" '^  N1 a DVLS with a Dashboard entry: provided by a human: lab-dvls \(read-only\)$'
  ! grep -rq secret "$RUN"/*.prompt || fail "a provided resource's file reached a prompt"
  [ ! -d "$T/provided/lab-dvls/.in-use.d" ] || fail "the run kept its lock on lab-dvls"
}

t_qa_needs_input() {
  echo 'qa_1() { printf "Verdict: NEEDS-INPUT\nSummary: no server\nInput: a licensed Hyper-V host to connect to\nHuman: none\n"; }' > "$T/scenario.sh"
  loop
  expect_end '^needs input for runtime QA: a licensed Hyper-V host to connect to; provide it'
  expect_result qa-1 human; expect_result end human
  expect_calls builder 1
  (cd "$R" && bash "$SKILL/scripts/factory.sh" resume "$(basename "$RUN")" > "$T/out2" 2>&1)
  expect_end '^ready for the judge'
  expect_calls builder 1; expect_calls qa 2
}

# --test-only: the result asked for (--expect) succeeds, red as much as green; the other one needs a human; with no
# --expect, nothing says which was wanted. --expect alone, without a check to apply it to, is refused.
t_test_expect() {
  loop --test-only HEAD --expect red
  expect_end '^red, as expected: the acceptance test fails on [0-9a-f]+'
  expect_result test proceed; expect_result end proceed
  loop --test-only HEAD --expect green
  expect_end '^expected green, got red: the acceptance test fails on'
  expect_result end human
  loop --test-only HEAD
  expect_end '^red: the acceptance test fails on'
  expect_result end unknown
  (cd "$R" && bash "$SKILL/scripts/run-loop.sh" DEMO-1 --expect red > "$T/out3" 2>&1); rc=$?
  [ "$rc" = 2 ] && grep -q -- '--expect goes with --test-only or --qa-only' "$T/out3" || fail "--expect alone: rc $rc, $(head -1 "$T/out3")"
}

# open_pr: --open-pr drops handback/ from the branch, writes an ordinary description and opens the PR with it.
t_open_pr() {
  git init -q --bare "$T/origin.git" && git -C "$R" remote add origin "$T/origin.git" && git -C "$R" push -q origin master
  git -C "$R" fetch -q origin
  loop --open-pr
  expect_end '^ready for the judge'
  expect_calls pr 1
  wt=$(ls -d "$R"/.claude/worktrees/demo-1-build-*/ | head -1)
  [ -z "$(git -C "$wt" ls-files handback | head -1)" ] || fail "handback/ is still tracked on the branch"
  [ -f "$(hb)/hand-back.md" ] || fail "the hand-back left the disk"
  expect_file "$RUN/pr.md" '^- [0-9a-f]{8} - DEMO-1: Changed the feature'
  ! grep -qiE 'handback|Removed handback' "$RUN/pr.md" || fail "pr.md lists the hand-back: $(grep -m1 -iE 'handback' "$RUN/pr.md")"
  expect_file "$RUN/pr-title.txt" '^\[DEMO-1\] Fixed the demo feature$'
  expect_file "$FAKE_STATE/gh.log" 'pr create --draft --base master'
  expect_event 'PR: https://example.test/pull/1'
  git -C "$T/origin.git" rev-parse -q --verify "refs/heads/$(git -C "$wt" symbolic-ref --short HEAD)" > /dev/null || fail "the branch was not pushed"
}

# pr_leak: a description that names the factory is written for a human to fix, and nothing is pushed.
t_pr_leak() {
  git init -q --bare "$T/origin.git" && git -C "$R" remote add origin "$T/origin.git" && git -C "$R" push -q origin master
  echo 'pr() { printf "TITLE: Fixed it\n\nThe builder fixed it in round 2 for \$3.\n"; }' >> "$T/scenario.sh"
  loop
  (cd "$R" && bash "$SKILL/scripts/factory.sh" pr "$(basename "$RUN")" > "$T/pr-out" 2>&1) || fail "factory.sh pr without --open failed: $(tail -1 "$T/pr-out")"
  grep -q 'names the factory' "$T/pr-out" || fail "no leak warning: $(tail -1 "$T/pr-out")"
  (cd "$R" && bash "$SKILL/scripts/factory.sh" pr "$(basename "$RUN")" --open > "$T/pr-out2" 2>&1) && fail "--open went on with a leaking description"
  [ ! -s "$FAKE_STATE/gh.log" ] || fail "gh was called: $(cat "$FAKE_STATE/gh.log")"
}

ALL="happy timebox_after_commit timebox_checkpoint qa_fail_then_fix re_review_names_changes qa_defects vm_on_demand vm_idle stall same_binaries iteration_cap flaky
  failing_listed_test listed_red_on_base_too accept_passes_on_base build_fails restore_flake_on_clean accept_dispute handback_rewritten_nested_docs accept_same_fails pause_resume stop_then_resume stale_lock busy_lock no_build_misses explore_blocker recheck_cant_tell
  assessor_writes size_from_assessment size_on_purpose limits_only reviewer_scaled fixture fixture_missing provided_missing provided_check_then_resume
  qa_needs_input test_expect open_pr pr_leak"
for t in ${*:-$ALL}; do
  ok=yes
  setup
  t0=$(date +%s)
  "t_$t"
  if [ "$ok" = yes ]; then
    PASSED=$((PASSED + 1)); echo "✓ $t ($(($(date +%s) - t0)) s)"
  else
    FAILED=$((FAILED + 1)) FAILS="$FAILS $t"
    echo "✗ $t: runner output and events kept in $T"
    continue
  fi
  teardown
done
echo "$PASSED passed, $FAILED failed${FAILS:+:$FAILS}"
[ "$FAILED" -eq 0 ]
