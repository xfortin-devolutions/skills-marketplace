# needs.sh: what testing a ticket needs, from its assessment, sourced by run-loop.sh (bash 3.2). A need line:
#   - N<n>: <the need, in user terms> | <how>: <detail>
# <how> is one of
#   fixture: <name>[: <what>]        the ticket's own <KEY>.fixtures/<name>/ next to its spec (fixture.md, apply.ps1,
#                                    data files), written with the spec and kept until `factory.sh clean <KEY>`; the run
#                                    takes a copy at its start; applied in every QA, exploration and base re-check VM
#                                    before the app starts
#   provided: <name>[: <what>]       $FACTORY_PROVIDED/<name>/ (provided.md, the files the guest needs, optional
#                                    check.ps1 and apply.ps1): only a human can provide it; a missing one stops the run
#                                    before it spends anything, an unreachable one pauses it for input
#   qa-setup: <how>                  QA creates it in the app first, as setup steps
#   unmet: <why>                     nothing provides it: QA can't test what needs it, the hand-back says so
# In the guest, a fixture's files are in C:\factory\fixtures\<name>, a provided resource's in C:\factory\provided\<name>;
# its scripts run with $Dir set to that folder.

# ui_setup_steps <spec>: the numbers of the Runtime check's steps that build test data through the app (add a folder or
# an entry, create a vault or a user): every QA round repeats them, where a fixture puts the data in place once.
ui_setup_steps() {
  [ -f "${1:-}" ] || return 0
  awk '/^## Runtime check$/ { on = 1; next } /^## / { on = 0 }
    on && /^Steps:/ { st = 1; next } on && /^Expectations:/ { st = 0 }
    on && st && match($0, /^[0-9]+\./) { n = substr($0, 1, RLENGTH - 1) }
    on && st && n != "" && !(n in seen) && tolower($0) ~ /(→ *add|add +(a +|an +|another +|new +)?(entry|entries|folder|vault|user|credential|data source)|(create|new) +(a +|an +|the +)?(entry|entries|folder|vault|user|credential|data source))/ {
      seen[n] = 1; printf "%s%s", sep, n; sep = " " }
    END { if (sep != "") print "" }' "$1"
}

# needs_fixtures_or_provided <assessment>: true when a need line is met by a fixture or a provided resource
needs_fixtures_or_provided() { needs_lines "${1:-}" | grep -qE '\| *(fixture|provided):'; }

needs_lines() { [ -f "${1:-}" ] && grep -E '^- N[0-9]+: ' "$1"; return 0; }
need_id() { echo "$1" | sed -E 's/^- (N[0-9]+): .*/\1/'; }
need_what() { echo "$1" | sed -E 's/^- N[0-9]+: *//; s/ *\| *(fixture|provided|qa-setup|unmet):.*$//'; }
need_kind() { echo "$1" | sed -nE 's/.*\| *(fixture|provided|qa-setup|unmet):.*/\1/p'; }
need_detail() { echo "$1" | sed -E 's/.*\| *(fixture|provided|qa-setup|unmet): *//'; }
# need_name <line>: the fixture's or provided resource's name (the detail up to a colon or a space)
need_name() { need_detail "$1" | sed -E 's/[: ].*$//'; }

# fixture_dir <name>: the run's copy of the ticket's fixtures (FIXTURES_DIR, set by run-loop.sh), else the ticket's own
fixture_dir() { echo "${FIXTURES_DIR:-$TICKETS_DIR/$TICKET.fixtures}/$1"; }
provided_dir() { echo "$FACTORY_PROVIDED/$1"; }
# field <file> <Field>: a "<Field>: value" line of a fixture.md or provided.md
md_field() { sed -n "s/^$2: *//p" "$1" 2> /dev/null | head -1; }

# needs_preflight <assessment>: what must exist before a run spends anything. Sets NEEDS_MISSING (one line a missing
# provided resource or fixture, with what the assessor says it is) and NEEDS_COUNT.
needs_preflight() {
  local line k n
  NEEDS_MISSING="" NEEDS_COUNT=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    NEEDS_COUNT=$((NEEDS_COUNT + 1))
    k=$(need_kind "$line") n=$(need_name "$line")
    case "$k" in
      provided) [ -f "$(provided_dir "$n")/provided.md" ] \
                  || NEEDS_MISSING="${NEEDS_MISSING}provided $n ($(need_what "$line")): factory.sh provide $n
" ;;
      fixture) [ -f "$(fixture_dir "$n")/fixture.md" ] \
                 || NEEDS_MISSING="${NEEDS_MISSING}fixture $n ($(need_what "$line")): write it, factory.sh fixture $TICKET $n
" ;;
    esac
  done < <(needs_lines "$1")
}

# provided_lock <name>: a resource that is not Shared waits for the run that uses it (VM_SLOT_WAIT_MIN at most). Held
# by this run until provided_release; a lock whose runner is gone is stale.
provided_lock() {
  local d l waited=0
  d=$(provided_dir "$1") l=$(provided_dir "$1")/.in-use.d
  [ "$(md_field "$d/provided.md" Shared | awk '{print tolower($1)}')" = no ] || return 0
  while ! mkdir "$l" 2> /dev/null; do
    [ "$(cat "$l/run" 2> /dev/null)" = "$ID" ] && return 0
    kill -0 "$(cat "$l/pid" 2> /dev/null)" 2> /dev/null || { rm -rf "$l"; continue; }
    [ "$waited" -ge $((VM_SLOT_WAIT_MIN * 60)) ] && return 1
    [ "$waited" = 0 ] && ev "provided $1 is in use by $(cat "$l/run" 2> /dev/null) (Shared: no): waiting"
    sleep 10; waited=$((waited + 10))
  done
  echo "$ID" > "$l/run"; echo $$ > "$l/pid"
}
provided_release() {
  local l
  for l in "$FACTORY_PROVIDED"/*/.in-use.d; do [ "$(cat "$l/run" 2> /dev/null)" = "$ID" ] && rm -rf "$l"; done
  return 0
}

# needs_apply <assessment> <log file>: puts the ticket's fixtures and provided resources in the VM (vmctl env already
# exported), before the app starts, with the VM toolkit's apply.sh (copy, check.ps1, apply.ps1). Returns 0; 2 when a
# fixture fails (the harness); 4 when a provided resource is unreachable or in use (a human must act). NEEDS_WHY says why.
needs_apply() {
  local line k n src g rc
  NEEDS_WHY=""
  while IFS= read -r line; do
    k=$(need_kind "$line") n=$(need_name "$line")
    case "$k" in
      fixture) src=$(fixture_dir "$n") g="C:\\factory\\fixtures\\$n" ;;
      provided) src=$(provided_dir "$n") g="C:\\factory\\provided\\$n"
                provided_lock "$n" || { NEEDS_WHY="provided $n is still in use by $(cat "$src/.in-use.d/run" 2> /dev/null)"; return 4; } ;;
      *) continue ;;
    esac
    echo "== $k $n" >> "$2"
    VMT_VM_DIR=$VM "$VMT/scripts/apply.sh" "$src" "$g" "$2"
    rc=$?
    case $rc in
      0) ;;
      2) NEEDS_WHY="could not copy $k $n into the guest: $(tail -1 "$2")"; return 2 ;;
      4) NEEDS_WHY="$k $n: its check fails in the guest: $(tail -1 "$2")"; return 4 ;;
      *) NEEDS_WHY="$k $n: apply.ps1 fails in the guest: $(tail -1 "$2")"
         [ "$k" = provided ] && return 4; return 2 ;;
    esac
    ev "needs: $k $n in place" > /dev/null
  done < <(needs_lines "$1")
  return 0
}

# needs_prompt <assessment>: the "Test setup" section of the QA, explorer and charter prompts: what is already in the
# VM and how to use it, what QA must create first, and what nobody could provide.
needs_prompt() {
  local line k n d f acc
  [ -n "$(needs_lines "$1")" ] || return 0
  printf '\n## Test setup\nWhat this ticket needs to be tested, and how it is met on your VM:\n'
  while IFS= read -r line; do
    k=$(need_kind "$line") n=$(need_name "$line")
    case "$k" in
      fixture) f=$(fixture_dir "$n")/fixture.md
        printf -- '- %s: in place (files in C:\\factory\\fixtures\\%s). %s\n' "$(need_what "$line")" "$n" "$(md_field "$f" Use)" ;;
      provided) f=$(provided_dir "$n")/provided.md acc=$(md_field "$f" Access | awk '{print tolower($1)}')
        printf -- '- %s: provided by a human (files in C:\\factory\\provided\\%s). %s %s\n' "$(need_what "$line")" "$n" "$(md_field "$f" Use)" \
          "$([ "$acc" = scratch ] && echo "You may change it." || echo "It is read-only: look, open and use what is there, but never change or delete anything that existed before you, and create nothing in it.")" ;;
      qa-setup) printf -- '- %s: not in place: create it yourself first, as setup steps: %s\n' "$(need_what "$line")" "$(need_detail "$line")" ;;
      unmet) printf -- '- %s: not available (%s): what needs it cannot be tested; report each such expectation as "can'"'"'t tell: <need> not available"\n' \
               "$(need_what "$line")" "$(need_detail "$line")" ;;
    esac
  done < <(needs_lines "$1")
}

# needs_section <assessment>: the hand-back's "Test needs" lines: how each need was met, so the judge knows what the QA
# verdict rests on
needs_section() {
  local line k n
  if [ -z "$(needs_lines "$1")" ]; then echo "- Needs: none beyond what QA creates in the app"; return; fi
  echo "- Needs: from \`$TICKET.assessment.md\` (the assessor's, as the spec's author left it)"
  while IFS= read -r line; do
    k=$(need_kind "$line") n=$(need_name "$line")
    case "$k" in
      fixture) echo "  $(need_id "$line") $(need_what "$line"): fixture $n" ;;
      provided) echo "  $(need_id "$line") $(need_what "$line"): provided by a human: $n ($(md_field "$(provided_dir "$n")/provided.md" Access | awk '{print $1}'))" ;;
      qa-setup) echo "  $(need_id "$line") $(need_what "$line"): set up by QA in the app" ;;
      unmet) echo "  $(need_id "$line") $(need_what "$line"): not met, untested: $(need_detail "$line")" ;;
      *) echo "  $(need_id "$line") $(need_what "$line"): unknown way to meet it: $(need_detail "$line")" ;;
    esac
  done < <(needs_lines "$1")
}

# catalog <dir> <file name>: each entry's name, then its file, for the assessor's prompt (never the other files: a
# provided resource's are secrets)
catalog() {
  local f
  for f in "$1"/*/"$2"; do
    [ -f "$f" ] || continue
    printf '### %s\n' "$(basename "$(dirname "$f")")"
    cat "$f"; echo
  done
}
