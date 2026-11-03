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
  export FACTORY_NEG_CACHE=$T/negative FAKE_STATE=$T/state FAKE_SCENARIO=$T/scenario.sh FAKE_SKILL=$SKILL
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

t_uncommitted_then_commit() {
  cat > "$T/scenario.sh" <<'EOF'
builder_1() { mkdir -p src; echo half > src/feature.txt; return 142; }
builder_2() { echo done > src/feature.txt; git add src; git commit -qm "DEMO-1: Finished the feature"; write_handback; }
EOF
  loop
  expect_end '^ready for the judge'
  expect_event 'build-1 outcome=time box .* verify=red: uncommitted changes'
  expect_file "$FAKE_STATE/builder-2.prompt" 'uncommitted changes left in the worktree'
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
builder_1() { commit_code done; mkdir -p "$(hb_dir)"; echo "Broken.Tests SomeFilter" > "$(hb_dir)/tests.txt"; write_handback; }
builder_2() { : > "$(hb_dir)/tests.txt"; git add handback; git commit -qm "handback: dropped the broken test"; }
EOF
  loop
  expect_end '^ready for the judge'
  expect_event 'build-1 .*verify=red: tests fail in the guest Broken.Tests SomeFilter'
  grep -q 'test --no-build Broken.Tests SomeFilter' "$FAKE_STATE/guest.log" || fail "the listed test did not run with its filter"
  [ "$(grep -c 'test --no-build Broken.Tests' "$FAKE_STATE/guest.log")" = 3 ] || fail "a failing test runs 1 + FLAKY_RERUNS times"
}

t_accept_passes_on_base() {
  touch "$FAKE_STATE/accept-always-passes"
  loop
  expect_end '^harness error in verify: the acceptance test passes on the base'
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

t_pause_resume() {
  echo 'builder_1() { commit_code done; write_handback; touch "$(run_dir)PAUSE"; }' > "$T/scenario.sh"
  loop
  expect_end '^paused before review 1 \(verified\): factory.sh resume demo-1-'
  [ -f "$RUN/state.sh" ] || fail "no state.sh"
  (cd "$R" && bash "$SKILL/scripts/factory.sh" resume "$(basename "$RUN")" > "$T/out2" 2>&1)
  expect_event 'run resumed before review'
  expect_end '^ready for the judge'
  expect_calls builder 1; expect_calls reviewer 1
  [ "$(ls -d "$FAKE_RUNS"/demo-1-* | wc -l | tr -d ' ')" = 1 ] || fail "resume made a new run folder"
}

t_stop_then_resume() {
  echo 'qa_1() { touch "$(run_dir)STOP"; printf "Verdict: FAIL\nSummary: broken\nHuman: none\n"; }
builder_2() { commit_code "done 2"; write_handback; }' > "$T/scenario.sh"
  loop
  expect_end '^stopped: STOP file$'
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

ALL="happy timebox_after_commit uncommitted_then_commit qa_fail_then_fix re_review_names_changes qa_defects vm_on_demand vm_idle stall same_binaries iteration_cap flaky
  failing_listed_test accept_passes_on_base build_fails restore_flake_on_clean pause_resume stop_then_resume stale_lock busy_lock no_build_misses explore_blocker recheck_cant_tell"
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
