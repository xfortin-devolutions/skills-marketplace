#!/bin/bash
# check-profile.sh <repo> <tickets dir> <project dir> <profile>: checks one profile, its targets, its layer and the
# tickets (this machine's, in <tickets dir>) that use it
# against references/profiles.md. One line per problem: ERROR fails the check, WARN doesn't (usually this machine lacks
# something, such as an image). Called by factory.sh check. bash 3.2 compatible.
set -u
REPO=$1 TICKETS_DIR=$2 PROJECT_DIR=$3 P=$4
D=$PROJECT_DIR/profiles/$P
VM_ROOT=${FACTORY_VM_ROOT:-$HOME/VMs/factory}
[ -f "$HOME/.factory/config.sh" ] && VM_ROOT=$(. "$HOME/.factory/config.sh" > /dev/null 2>&1; echo "${FACTORY_VM_ROOT:-$VM_ROOT}")
DEFAULT_PROFILE=$( (. "$PROJECT_DIR/config.sh" > /dev/null 2>&1; echo "${DEFAULT_PROFILE:-}") )
errs=0 warns=0
err() { echo "  ERROR $*"; errs=$((errs + 1)); }
warn() { echo "  WARN  $*"; warns=$((warns + 1)); }
has() { grep -q -- "$2" "$1" 2> /dev/null; } # has <file> <text>

echo "profile $P"
if [ ! -f "$D/profile.sh" ]; then
  err "no profile.sh"; echo "  -> $errs error(s)"; exit 1
fi
for f in "$D/profile.sh" "$D/reviewer.md" "$D"/targets/*/* "$D/layer/layer.conf" "$D/layer/setup.ps1"; do
  [ -f "$f" ] && has "$f" 'TODO' && err "${f#$D/}: TODO left to fill"
done

TICKET=CHECK-1 PROFILE_DIR=$D
. "$D/profile.sh" > /dev/null 2>&1 || err "profile.sh fails when sourced"
[ -n "${APP_NAME:-}" ] || err "profile.sh: APP_NAME is empty"
[ -n "${TARGETS:-}" ] || err "profile.sh: TARGETS is empty"
[ -n "${BRANCH_PREFIX:-}" ] || err "profile.sh: BRANCH_PREFIX is empty"
[ -n "${PR_BASE:-}" ] || err "profile.sh: PR_BASE is empty"
if [ -z "${CODE_PATHS:-}" ]; then
  err "profile.sh: CODE_PATHS is empty (where the product's code is: how the spec step picks this profile)"
else
  for c in $CODE_PATHS; do [ -e "$REPO/$c" ] || err "CODE_PATHS $c is not in the repo"; done
fi
PROFILE_CODE_PATHS=${CODE_PATHS:-}
if [ -z "${REVIEW_STANDARDS:-}" ]; then
  err "profile.sh: REVIEW_STANDARDS is empty"
elif [ ! -s "$REVIEW_STANDARDS" ] && [ ! -s "$REPO/$REVIEW_STANDARDS" ]; then
  err "REVIEW_STANDARDS $REVIEW_STANDARDS is missing or empty"
fi
for v in BUILD_CMD TEST_CMD HOST_REQUIRES HOST_TOOLS REVIEW_HOST_TOOLS; do
  has "$D/profile.sh" "^$v=" && err "profile.sh sets $v: nothing builds on the Mac any more, the target's scripts do"
done

for t in ${TARGETS:-}; do
  TD=$D/targets/$t
  if [ ! -f "$TD/target.sh" ]; then
    err "target $t: no targets/$t/target.sh"; continue
  fi
  (
    errs=0 warns=0
    TARGET_DIR=$TD GOLDEN_IMAGE="" GUEST_OS="" GUEST_DESC="" SHARE_CHECK="" GUEST_BUILD="" GUEST_TEST="" GUEST_LAUNCH=""
    . "$TD/target.sh"
    for v in GUEST_OS GUEST_DESC SHARE_CHECK GUEST_BUILD GUEST_TEST GUEST_LAUNCH; do
      eval "[ -n \"\$$v\" ]" || err "target $t: $v is empty"
    done
    [ -z "$SHARE_CHECK" ] || [ -e "$REPO/$SHARE_CHECK" ] || err "target $t: SHARE_CHECK $SHARE_CHECK is not in the repo"
    for pair in "GUEST_BUILD:BUILD EXIT CODE" "GUEST_TEST:TEST EXIT CODE" "GUEST_LAUNCH:LAUNCH OK"; do
      v=${pair%%:*} marker=${pair#*:}
      eval "f=\$$v"
      [ -n "$f" ] || continue
      if [ ! -f "$f" ]; then err "target $t: $v ${f#$D/} is missing"; continue; fi
      has "$f" "$marker" || err "target $t: ${f#$D/} never prints \"$marker\""
    done
    [ -f "$GUEST_BUILD" ] && ! has "$GUEST_BUILD" '\$Project' && err "target $t: ${GUEST_BUILD#$D/} ignores \$Project"
    [ -f "$GUEST_TEST" ] && { has "$GUEST_TEST" '\$Project' && has "$GUEST_TEST" '\$Filter'; } \
      || { [ -f "$GUEST_TEST" ] && err "target $t: ${GUEST_TEST#$D/} must read \$Project and \$Filter"; }
    img=${GOLDEN_IMAGE:-base.qcow2}
    if [ ! -f "$VM_ROOT/$GUEST_OS/$img" ]; then
      warn "target $t: no $img in $VM_ROOT/$GUEST_OS on this machine (vm-setup.md for base.qcow2, factory.sh layer for a layer)"
    elif [ -w "$VM_ROOT/$GUEST_OS/$img" ]; then
      warn "target $t: $img is writable: clones refuse it until it is frozen (chmod a-w)"
    fi
    if [ "$img" != base.qcow2 ]; then
      layer=$( (FACTORY_VM_HOME=$VM_ROOT/$GUEST_OS LAYER=""; . "$D/layer/layer.conf" > /dev/null 2>&1; echo "$LAYER") 2> /dev/null)
      [ "$layer.qcow2" = "$img" ] || warn "target $t: GOLDEN_IMAGE $img has no recipe in this profile (layer/layer.conf LAYER=${img%.qcow2})"
    fi
    exit $(( errs > 0 ? 2 : (warns > 0 ? 1 : 0) ))
  )
  case $? in 2) errs=$((errs + 1)) ;; 1) warns=$((warns + 1)) ;; esac
done

if [ -d "$D/layer" ]; then
  if [ ! -f "$D/layer/layer.conf" ] || [ ! -f "$D/layer/setup.ps1" ]; then
    err "layer/ needs layer.conf and setup.ps1"
  else
    has "$D/layer/setup.ps1" 'LAYER SETUP OK' && has "$D/layer/setup.ps1" 'LAYER SETUP FAILED' \
      || err "layer/setup.ps1 must end its log with \"LAYER SETUP OK\" or \"LAYER SETUP FAILED: <why>\""
    msg=$( (FACTORY_VM_HOME=$VM_ROOT/windows LAYER=""; . "$D/layer/layer.conf" > /dev/null) 2>&1) \
      || warn "layer/layer.conf can't build on this machine: ${msg:-it returns an error}"
  fi
fi

# Fixtures (fixtures/<name>/): the assessor matches tickets' needs on What, QA reads Use, the runner runs apply.ps1.
for f in "$D"/fixtures/*/; do
  [ -d "$f" ] || continue
  n=$(basename "$f")
  [ -f "$f/fixture.md" ] || { err "fixture $n: no fixture.md"; continue; }
  grep -q '^What: [^<]' "$f/fixture.md" || err "fixture $n: fixture.md has no What: line"
  grep -q '^Use: [^<]' "$f/fixture.md" || err "fixture $n: fixture.md has no Use: line"
  [ -f "$f/apply.ps1" ] || warn "fixture $n: no apply.ps1 (its files are copied into the guest, nothing runs)"
done

for k in "$TICKETS_DIR"/*.sh; do
  [ -f "$k" ] || continue
  (
    PROFILE="" ACCEPT_TEST="" ORACLE_PATHS="" SCOPE_REGEX="" BUILD_PROJ=""
    . "$k" > /dev/null 2>&1
    [ "${PROFILE:-${DEFAULT_PROFILE:-}}" = "$P" ] || exit 0
    n=$(basename "$k" .sh) errs=0
    [ -f "$TICKETS_DIR/$n.md" ] || err "ticket $n: no $n.md"
    in_code=no
    for c in $PROFILE_CODE_PATHS; do case "$ACCEPT_TEST" in "$c"*) in_code=yes ;; esac; done
    [ -z "$ACCEPT_TEST" ] || [ "$in_code" = yes ] || echo "  WARN  ticket $n: ACCEPT_TEST is outside $P's CODE_PATHS ($PROFILE_CODE_PATHS): right profile?"
    [ -n "$ACCEPT_TEST" ] || err "ticket $n: ACCEPT_TEST is empty"
    [ -z "$ACCEPT_TEST" ] || [ -f "$REPO/$ACCEPT_TEST" ] || err "ticket $n: ACCEPT_TEST $ACCEPT_TEST is not in the repo"
    [ -n "$ORACLE_PATHS" ] || err "ticket $n: ORACLE_PATHS is empty (the builder could edit the oracle)"
    [ -n "$SCOPE_REGEX" ] || err "ticket $n: SCOPE_REGEX is empty"
    [ -z "$BUILD_PROJ" ] || err "ticket $n: BUILD_PROJ is gone (verify builds what the target ships)"
    [ -z "${PLATFORM:-}" ] || [ -f "$D/targets/$PLATFORM/target.sh" ] || err "ticket $n: PLATFORM $PLATFORM is not a target of $P"
    a=$TICKETS_DIR/$n.assessment.md
    if [ -f "$a" ]; then
      grep -E '^- N[0-9]+: .*\| *fixture: ' "$a" | sed -E 's/.*\| *fixture: *([a-z0-9-]+).*/\1/' | while read -r fx; do
        [ -f "$D/fixtures/$fx/fixture.md" ] || echo "  WARN  ticket $n: its assessment needs fixture $fx, which $P doesn't have"
      done
      grep -E '^- N[0-9]+: ' "$a" | grep -vqE '\| *(fixture|provided|qa-setup|unmet): ' \
        && echo "  WARN  ticket $n: an assessment need line says neither fixture, provided, qa-setup nor unmet"
    fi
    exit $(( errs > 0 ? 2 : 0 ))
  )
  [ $? -eq 2 ] && errs=$((errs + 1))
done

if [ "$errs" -gt 0 ]; then
  echo "  -> $errs problem(s) to fix, $warns warning(s)"; exit 1
fi
[ "$warns" -gt 0 ] && echo "  -> OK ($warns warning(s))" || echo "  -> OK"
