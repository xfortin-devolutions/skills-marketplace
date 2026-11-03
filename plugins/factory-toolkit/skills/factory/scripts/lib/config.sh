# config.sh: the factory's layered configuration, sourced by run-loop.sh and factory.sh (bash 3.2 compatible).
# Set before sourcing: REPO (the target repo), X (the engine's scripts folder), TICKET (optional).
# Layers, later wins: engine defaults < <project>/config.sh < <tickets>/<TICKET>.sh (picks PROFILE, PLATFORM)
#   < profiles/<PROFILE>/profile.sh < profiles/<PROFILE>/targets/<PLATFORM>/target.sh < ~/.factory/config.sh.
# The project layers say what the products need (shared by the team); the user layer says what this machine has.
# The project (config.sh + profiles/) is the repo's own .factory/ when it has profiles; until then, the one bundled with
# this skill in projects/<name>/ whose REPO_MATCH matches the repo's origin remote. Tickets are working files, never
# committed: next to the runs in the main checkout's .claude/worktrees/factory-tickets/ (TICKETS_DIR); each run takes a
# copy of its spec, and `factory.sh clean <KEY>` removes a finished ticket's spec, runs and VM folders.

FACTORY_DIR=${FACTORY_DIR:-$REPO/.factory}
SKILL_DIR=$(cd "$X/.." && pwd)
# Runs and build worktrees live in the main checkout, so they are found from any worktree of the repo.
MAIN_REPO=$(cd "$(git -C "$REPO" rev-parse --git-common-dir)/.." && pwd)
FACTORY_DIR_REL=${FACTORY_DIR#$REPO/}
VM=${FACTORY_VM_DIR:-$X/vm}

# Engine defaults. Caps: per run (model, budget, time box), per loop: ITER_CAP builder runs in all, STALL_CAP in a row
# that change nothing (code, disputes, tests), LOOP_USD dollars, the STOP and PAUSE files.
B_MODEL=claude-opus-5-5     B_USD=8    B_MIN=45
R_MODEL=claude-sonnet-5-5   R_USD=2    R_MIN=20
QA_MODEL=claude-opus-5-5    QA_USD=6   QA_MIN=40
# Exploratory QA after a runtime QA PASS: charter (from the diff), explorer (same VM), re-check of findings on the base.
C_MODEL=claude-sonnet-5-5   C_USD=1    C_MIN=10
X_MODEL=claude-opus-5-5     X_USD=5    X_MIN=30    RC_USD=3   RC_MIN=20
EXPLORE=yes                 EXPLORE_SENDBACKS=1
ITER_CAP=5                  STALL_CAP=2               LOOP_USD=40
# The assessor (before the first builder run): sizes the ticket and lists what testing it needs (lib/sizing.sh, the
# ticket's <KEY>.assessment.md). ASSESS=no skips it: the run then uses SIZE_DEFAULT and no test needs.
A_MODEL=claude-sonnet-5-5   A_USD=1.5  A_MIN=15  ASSESS=yes
# Size classes: each sets the limits it names (absolute values; the ones it leaves out keep the values above). The
# assessor picks a class; SIZE in the ticket .sh or --size picks one on purpose. SIZE_CEILING caps the values of a class
# the assessor picked, never one a human or an agent set (ticket .sh, --size, --set): going above it is a decision.
SIZE_CLASSES="S M L XL"     SIZE_DEFAULT=M
SIZE_S="B_MIN=30 ITER_CAP=4 LOOP_USD=25"
SIZE_M=""
SIZE_L="B_USD=15 B_MIN=90 R_USD=3 R_MIN=30 QA_USD=8 QA_MIN=60 X_USD=7 X_MIN=45 ITER_CAP=6 LOOP_USD=80"
SIZE_XL="B_USD=25 B_MIN=150 R_USD=4 R_MIN=40 QA_USD=10 QA_MIN=75 X_USD=8 X_MIN=60 ITER_CAP=8 LOOP_USD=150"
SIZE_CEILING="LOOP_USD=150 B_USD=25 B_MIN=180"
# Measured, not guessed: the reviewer's limits grow with the diff (one more share per R_SCALE_LINES changed lines) and
# QA's with the Runtime check (per QA_SCALE_ITEMS steps and expectations), up to SCALE_MAX times, unless set on purpose.
R_SCALE_LINES=400           QA_SCALE_ITEMS=12         SCALE_MAX=3
# The limits a size class, the ticket .sh, --set or the scaling may change.
CAP_VARS="B_USD B_MIN R_USD R_MIN QA_USD QA_MIN C_USD C_MIN X_USD X_MIN RC_USD RC_MIN A_USD A_MIN ITER_CAP STALL_CAP LOOP_USD EXPLORE_SENDBACKS GUEST_BUILD_MIN"
# Resources only a human can provide (a data source, an account, a licensed server), one folder each, never in a repo:
# provided.md (what it is, no secrets) and the files the guest needs. `factory.sh provide <name>` starts one.
FACTORY_PROVIDED=${FACTORY_PROVIDED:-$HOME/.factory/provided}
# A failing test is re-run up to FLAKY_RERUNS times; passing on a re-run makes it flaky (green, listed for the judge).
FLAKY_RERUNS=2
# After a builder session, how long a git index.lock it left may take to go before the runner removes it as stale.
GIT_SETTLE_S=60
FACTORY_RUNS=${FACTORY_RUNS:-$MAIN_REPO/.claude/worktrees/factory-runs}
# The negative runs (the acceptance test on a base, which must fail), kept per base tree and test across runs.
NEG_CACHE=${FACTORY_NEG_CACHE:-$FACTORY_RUNS/.negative}
FACTORY_VM_ROOT=${FACTORY_VM_ROOT:-$HOME/VMs/factory}
VM_CPUS=8  VM_MEM=16G  VM_MAX=2  VM_SLOT_WAIT_MIN=120  VM_IDLE_MIN=10  VM_BOOT_MIN=10  GUEST_BUILD_MIN=30  HUMAN_WAIT_MIN=120
VM_XRES=1600  VM_YRES=900
DEFAULT_PROFILE=""
# Docs every change may update besides the ticket's scope (repo path prefixes; the project sets them). Verify doesn't count
# them as outside the scope, and `factory.sh which` treats them as shared by every product.
DOC_PATHS=""
PR_BASE=master
BRANCH_PREFIX=factory/
PROTECTED_EXTRA=""

PROJECT_DIR="" PROJECT_FROM=""
if [ -d "$FACTORY_DIR/profiles" ]; then
  PROJECT_DIR=$FACTORY_DIR PROJECT_FROM="repo ($FACTORY_DIR_REL)"
else
  _origin=$(git -C "$REPO" remote get-url origin 2> /dev/null)
  for _p in "$SKILL_DIR"/projects/*/config.sh; do
    [ -f "$_p" ] && [ -n "$_origin" ] || continue
    _m=$(REPO_MATCH=""; . "$_p" > /dev/null 2>&1; echo "$REPO_MATCH")
    [ -n "$_m" ] && echo "$_origin" | grep -qE "$_m" || continue
    PROJECT_DIR=$(dirname "$_p") PROJECT_FROM="skill (projects/$(basename "$(dirname "$_p")"), matches $_origin)"
    break
  done
fi
[ -n "$PROJECT_DIR" ] && [ -f "$PROJECT_DIR/config.sh" ] && . "$PROJECT_DIR/config.sh"

TICKETS_DIR=${FACTORY_TICKETS:-$MAIN_REPO/.claude/worktrees/factory-tickets}
# Specs, runs and run worktrees stay out of git even in a repo that doesn't ignore .claude/worktrees/ itself.
if ! git -C "$MAIN_REPO" check-ignore -q .claude/worktrees/factory-runs 2> /dev/null; then
  _ex=$(git -C "$MAIN_REPO" rev-parse --git-path info/exclude 2> /dev/null)
  [ -n "$_ex" ] && { mkdir -p "$(dirname "$MAIN_REPO/${_ex#$MAIN_REPO/}")"; echo '.claude/worktrees/' >> "$MAIN_REPO/${_ex#$MAIN_REPO/}"; }
fi
# Specs written before 0.3.0 sit in the repo's .factory/tickets/, on their ticket branch.
[ -n "${TICKET:-}" ] && [ ! -f "$TICKETS_DIR/$TICKET.sh" ] && [ -f "$FACTORY_DIR/tickets/$TICKET.sh" ] && TICKETS_DIR=$FACTORY_DIR/tickets

PROFILE="" PLATFORM="" TARGET_DIR="" PROFILE_DIR="" CODE_PATHS=""
# The limits the ticket .sh sets on purpose (B_MIN=240, …) win over every later layer: run-loop.sh applies them last.
TICKET_SET="" SIZE="" SIZE_WHY=""
if [ -n "${TICKET:-}" ] && [ -f "$TICKETS_DIR/$TICKET.sh" ]; then
  for _v in $CAP_VARS; do eval "_pre_$_v=\${$_v-}"; done
  . "$TICKETS_DIR/$TICKET.sh"
  for _v in $CAP_VARS; do eval "[ \"\${$_v-}\" = \"\$_pre_$_v\" ]" || TICKET_SET="$TICKET_SET $_v=$(eval "echo \${$_v}")"; done
  PROFILE=${PROFILE:-$DEFAULT_PROFILE}
  [ -n "$PROJECT_DIR" ] || { echo "factory: no project for this repo: no $FACTORY_DIR_REL/profiles, and no projects/*/config.sh in the skill whose REPO_MATCH matches its origin" >&2; return 2; }
  PROFILE_DIR=$PROJECT_DIR/profiles/$PROFILE
  [ -n "$PROFILE" ] && [ -f "$PROFILE_DIR/profile.sh" ] \
    || { echo "factory: no profile '$PROFILE' in $PROJECT_FROM (profiles/<name>/profile.sh; set PROFILE in the ticket .sh or DEFAULT_PROFILE)" >&2; return 2; }
  . "$PROFILE_DIR/profile.sh"
  # The ticket picks a target; the profile's first one is the default.
  PLATFORM=${PLATFORM:-${TARGETS%% *}}
  TARGET_DIR=$PROFILE_DIR/targets/$PLATFORM
  if [ -n "$PLATFORM" ]; then
    [ -f "$TARGET_DIR/target.sh" ] || { echo "factory: profile $PROFILE has no target '$PLATFORM'" >&2; return 2; }
    . "$TARGET_DIR/target.sh"
  fi
fi

FACTORY_USER_CONFIG=${FACTORY_USER_CONFIG:-$HOME/.factory/config.sh}
[ -f "$FACTORY_USER_CONFIG" ] && . "$FACTORY_USER_CONFIG"

# One golden image per guest OS: <VM root>/<guest os>/base.qcow2. A target may name a layer on it instead (GOLDEN_IMAGE).
FACTORY_VM_HOME=${FACTORY_VM_HOME:-$FACTORY_VM_ROOT/${GUEST_OS:-windows}}
GOLDEN_IMAGE=${GOLDEN_IMAGE:-base.qcow2}

# The QA agent drives the VM and nothing else. It runs in its own folder outside the repo with no blanket Read rule, so it
# reads its screenshots (inside that folder) but not the source.
QA_TOOLS=("Bash(python3 $VM/vm.py *)" "Bash($VM/vmssh *)" "Bash(sips *)")

# The builder must not change these: denied in its session (deny rules generated by run-loop.sh) and re-checked with git.
# Not all of .claude/: its skills are docs the builder keeps up to date. Its settings and hooks steer the agents (the
# reviewer and the charter run in the builder's worktree), so they stay out of reach.
PROTECTED_PATHS="${ORACLE_PATHS:-} $FACTORY_DIR_REL .claude/settings.json .claude/settings.local.json .claude/hooks $PROTECTED_EXTRA"
DENY_BASH=("Bash(git push *)" "Bash(gh *)")

# Nothing builds or tests on the Mac: run-loop.sh adds the run's guest tool (build and test in the build VM) to both lists.
BUILD_TOOLS=(
  "Read" "Edit" "Write" "Glob" "Grep" "Skill"
  "Bash(git --version)" "Bash(claude --version)" "Bash(date *)"
  "Bash(git add *)" "Bash(git commit *)" "Bash(git switch *)" "Bash(git log *)" "Bash(git diff *)"
  "Bash(git status *)" "Bash(git rev-parse *)" "Bash(git show *)"
  # Drops an experiment it won't commit: left in the worktree, it turns the round's verify red. The oracle is re-checked.
  "Bash(git restore *)")

REVIEW_TOOLS=(
  "Read" "Glob" "Grep"
  "Bash(git diff *)" "Bash(git log *)" "Bash(git show *)")

export VM_IMAGE=$GOLDEN_IMAGE
export FACTORY_VM_HOME VM_CPUS VM_MEM VM_MAX VM_SLOT_WAIT_MIN VM_IDLE_MIN VM_BOOT_MIN VM_XRES VM_YRES
export VM_SHARE_CHECK=${SHARE_CHECK:-}
