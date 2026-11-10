#!/bin/bash
# check-profile.sh <repo> <tickets dir> <project dir> <profile>: checks one profile, the VM toolkit's product definition
# it uses (the toolkit's lib/check-product.sh: targets, scripts, images, layer) and the tickets (this machine's, in
# <tickets dir>) that use it, against references/profiles.md. One line per problem: ERROR fails the check, WARN doesn't
# (usually this machine lacks something, such as an image). Called by factory.sh check, with VMT set (lib/vmt.sh).
# bash 3.2 compatible.
set -u
REPO=$1 TICKETS_DIR=$2 PROJECT_DIR=$3 P=$4
D=$PROJECT_DIR/profiles/$P
VM_ROOT=${FACTORY_VM_ROOT:-$HOME/VMs/factory}
DEFAULT_PROFILE=$( (. "$PROJECT_DIR/config.sh" > /dev/null 2>&1; echo "${DEFAULT_PROFILE:-}") )
errs=0 warns=0
err() { echo "  ERROR $*"; errs=$((errs + 1)); }
warn() { echo "  WARN  $*"; warns=$((warns + 1)); }
has() { grep -q -- "$2" "$1" 2> /dev/null; } # has <file> <text>
. "$(dirname "$0")/needs.sh"
VMT_DIR=$VMT
. "$VMT/scripts/lib/products.sh"

echo "profile $P"
if [ ! -f "$D/profile.sh" ]; then
  err "no profile.sh"; echo "  -> $errs error(s)"; exit 1
fi
for f in "$D/profile.sh" "$D/reviewer.md"; do
  [ -f "$f" ] && has "$f" 'TODO' && err "${f#$D/}: TODO left to fill"
done

TICKET=CHECK-1 PROFILE_DIR=$D VM_PRODUCT=""
. "$D/profile.sh" > /dev/null 2>&1 || err "profile.sh fails when sourced"
[ -n "${BRANCH_PREFIX:-}" ] || err "profile.sh: BRANCH_PREFIX is empty"
[ -n "${PR_BASE:-}" ] || err "profile.sh: PR_BASE is empty"
if [ -z "${REVIEW_STANDARDS:-}" ]; then
  err "profile.sh: REVIEW_STANDARDS is empty"
elif [ ! -s "$REVIEW_STANDARDS" ] && [ ! -s "$REPO/$REVIEW_STANDARDS" ]; then
  err "REVIEW_STANDARDS $REVIEW_STANDARDS is missing or empty"
fi
for v in BUILD_CMD TEST_CMD HOST_REQUIRES HOST_TOOLS REVIEW_HOST_TOOLS; do
  has "$D/profile.sh" "^$v=" && err "profile.sh sets $v: nothing builds on the Mac any more, the target's scripts do"
done
# Since the VM toolkit (factory 0.8.0), the product is its definition, not the profile's.
for v in APP_NAME TARGETS CODE_PATHS; do
  has "$D/profile.sh" "^$v=" && warn "profile.sh sets $v: the product definition's (VM toolkit product.sh) wins for the VMs; move it there"
done
[ -d "$D/targets" ] || [ -d "$D/layer" ] && err "targets/ and layer/ belong to the product definition now (VM toolkit: vmt new-product, references/products.md)"

PROD=${VM_PRODUCT:-$P} PD="" PROFILE_CODE_PATHS=""
if ! PDEFS=$(products_dir "$REPO"); then
  err "no VM product definitions for this repo (vmt products says why)"
elif [ ! -f "$PDEFS/$PROD/product.sh" ]; then
  err "product $PROD (VM_PRODUCT) is not defined in $PDEFS: vmt new-product $PROD"
else
  PD=$PDEFS/$PROD
  echo "  product $PROD: $PD"
  out=$(VM_ROOT=$VM_ROOT "$VMT/scripts/lib/check-product.sh" "$REPO" "$PD")
  [ -n "$out" ] && echo "$out"
  n=$(printf '%s\n' "$out" | grep -c '^  ERROR'); errs=$((errs + n))
  n=$(printf '%s\n' "$out" | grep -c '^  WARN'); warns=$((warns + n))
  PROFILE_CODE_PATHS=$(product_field "$PD" CODE_PATHS)
fi

# Fixtures belong to tickets (<KEY>.fixtures/ next to the spec), not to profiles: a profile's fixtures/ is never read.
[ ! -d "$D/fixtures" ] || warn "fixtures/ is not read: a fixture belongs to its ticket, <KEY>.fixtures/<name>/ in $TICKETS_DIR"

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
    [ -z "${PLATFORM:-}" ] || [ -z "$PD" ] || [ -f "$PD/targets/$PLATFORM/target.sh" ] || err "ticket $n: PLATFORM $PLATFORM is not a target of $PROD"
    a=$TICKETS_DIR/$n.assessment.md
    steps=$(ui_setup_steps "$TICKETS_DIR/$n.md")
    [ -z "$steps" ] || needs_fixtures_or_provided "$a" \
      || echo "  WARN  ticket $n: its Runtime check builds its data through the app (steps $steps), which every QA round repeats: put it in place with a fixture (factory.sh fixture $n <name>), name it in $n.assessment.md and start the steps from it"
    if [ -f "$a" ]; then
      grep -E '^- N[0-9]+: .*\| *fixture: ' "$a" | sed -E 's/.*\| *fixture: *([a-z0-9-]+).*/\1/' | while read -r fx; do
        [ -f "$TICKETS_DIR/$n.fixtures/$fx/fixture.md" ] \
          || echo "  WARN  ticket $n: its assessment needs fixture $fx, not written yet: factory.sh fixture $n $fx"
      done
      grep -E '^- N[0-9]+: ' "$a" | grep -vqE '\| *(fixture|provided|qa-setup|unmet): ' \
        && echo "  WARN  ticket $n: an assessment need line says neither fixture, provided, qa-setup nor unmet"
    fi
    # The ticket's fixtures: QA reads Use, the runner runs apply.ps1.
    for f in "$TICKETS_DIR/$n.fixtures"/*/; do
      [ -d "$f" ] || continue
      fx=$(basename "$f")
      [ -f "$f/fixture.md" ] || { err "ticket $n: fixture $fx has no fixture.md"; continue; }
      grep -q '^What: [^<]' "$f/fixture.md" || err "ticket $n: fixture $fx: fixture.md has no What: line"
      grep -q '^Use: [^<]' "$f/fixture.md" || err "ticket $n: fixture $fx: fixture.md has no Use: line"
      [ -f "$f/apply.ps1" ] || warn "ticket $n: fixture $fx has no apply.ps1 (its files are copied into the guest, nothing runs)"
    done
    exit $(( errs > 0 ? 2 : 0 ))
  )
  [ $? -eq 2 ] && errs=$((errs + 1))
done

if [ "$errs" -gt 0 ]; then
  echo "  -> $errs problem(s) to fix, $warns warning(s)"; exit 1
fi
[ "$warns" -gt 0 ] && echo "  -> OK ($warns warning(s))" || echo "  -> OK"
