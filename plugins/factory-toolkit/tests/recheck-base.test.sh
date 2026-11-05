#!/bin/bash
# recheck-base.test.sh: run-loop.sh's recheck_base on a scratch repo: a ticket branch with the oracle only re-checks its
# tip; one that also carries product code re-checks the merge-base with PR_BASE. bash 3.2 compatible.
set -u
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
eval "$(sed -n '/^recheck_base() {/,/^}/p' "$(dirname "$0")/../skills/factory/scripts/run-loop.sh")"
ev() { echo "$*" >> "$T/events"; }
pass=0 fail=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "✓ $1"; else fail=$((fail + 1)); echo "✗ $1: expected [$2], got [$3]"; fi
}

REPO=$T/repo PR_BASE=master ORACLE_PATHS="tests/OracleTests.cs tests/Fixture.axaml"
git init -q -b master "$REPO"
g() { git -C "$REPO" -c user.name=t -c user.email=t@t "$@"; }
mkdir -p "$REPO/src" "$REPO/tests"
echo product > "$REPO/src/Grid.cs"
g add -A && g commit -qm base
master=$(g rev-parse --short=12 HEAD)
g checkout -qb ticket
echo oracle > "$REPO/tests/OracleTests.cs"; echo fixture > "$REPO/tests/Fixture.axaml"
g add -A && g commit -qm oracle

BASE=$(g rev-parse --short HEAD)
check "an oracle-only ticket branch re-checks its tip" "$BASE" "$(recheck_base)"
check "and says nothing" "" "$(cat "$T/events" 2> /dev/null)"

echo change >> "$REPO/src/Grid.cs"
g add -A && g commit -qm "the change, squashed for a PR"
BASE=$(g rev-parse --short HEAD)
check "a ticket branch with product code re-checks the merge-base" "$master" "$(recheck_base)"
grep -q "carries product code beyond the oracle (src/Grid.cs" "$T/events"; check "and says why" 0 $?

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
