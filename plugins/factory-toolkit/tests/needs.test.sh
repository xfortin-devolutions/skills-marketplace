#!/bin/bash
# needs.test.sh: lib/needs.sh's checks that need no VM and no agent. bash 3.2 compatible.
set -u
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
. "$(dirname "$0")/../skills/factory/scripts/lib/needs.sh"
pass=0 fail=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "✓ $1"; else fail=$((fail + 1)); echo "✗ $1: expected [$2], got [$3]"; fi
}

cat > "$T/setup.md" <<'SPEC'
## Runtime check

Steps:
1. Right-click "Local workspace" → Add → Folder…. Set Name to `Servers` and click Save.
2. Right-click `Servers` → "Add entry…". Pick RDP, then click "Select".
   - Tick "Add another entry", set Name to `Alpha` and click Save.
3. Click `Servers`, then type `be`. Take a screenshot.
4. Create a new vault named `Lab`.

Expectations:
- E1: add entry is not a step here.

## Scope
1. Add a folder: not the Runtime check.
SPEC
check "steps that build data through the app" "1 2 4" "$(ui_setup_steps "$T/setup.md")"

cat > "$T/fixture.md" <<'SPEC'
## Runtime check

Steps:
1. In the Navigation pane, check that `Servers` holds the six entries.
2. Click `Servers`, then type `be`. Take a screenshot.

Expectations:
- E1: Beta is selected.
SPEC
check "steps that start from a fixture" "" "$(ui_setup_steps "$T/fixture.md")"
check "no spec" "" "$(ui_setup_steps "$T/missing.md")"

printf -- '- N1: a folder of entries | fixture: servers-entries\n' > "$T/a1.md"
printf -- '- N1: an entry | qa-setup: add one RDP entry\n' > "$T/a2.md"
needs_fixtures_or_provided "$T/a1.md"; check "a fixture need" 0 $?
needs_fixtures_or_provided "$T/a2.md"; check "a qa-setup need only" 1 $?

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
