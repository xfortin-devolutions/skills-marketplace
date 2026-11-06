#!/bin/bash
# pr.sh <run dir> [--open]: the pull request of a finished loop run, an ordinary one: the issue, how it was fixed, the
# technical changes and the commits, never the factory's record (the hand-back stays the judge's). A fresh read-only
# session (agents/factory-pr.md), in the run's worktree, writes it the way the repo's own PR instructions say
# (PR_INSTRUCTIONS first, then what it finds; templates/pr-template.md for a repo with none) from the ticket, the diff
# and the hand-back; the runner adds the commit list. Writes pr-title.txt and pr.md in the run folder.
#   --open   also drops handback/ from the branch (its own commit; the files stay on disk), pushes the branch and opens
#            a draft PR against PR_BASE, or updates the title and body of the branch's open PR. Prints the PR URL last.
# Called by `factory.sh pr` and by run-loop.sh --open-pr. Run from inside the repo.
set -u
X=$(cd "$(dirname "$0")" && pwd)
SKILL=$(cd "$X/.." && pwd)
RUN=${1:-}
[ -n "$RUN" ] && [ -f "$RUN/state.sh" ] || { echo "pr: usage: pr.sh <run dir> [--open] (a loop run's folder, with its state.sh)" >&2; exit 2; }
OPEN=no
[ "${2:-}" = --open ] && OPEN=yes
REPO=$(git rev-parse --show-toplevel 2> /dev/null) || { echo "pr: run this from inside the repo" >&2; exit 2; }
. "$RUN/state.sh"
TICKET=$S_TICKET
. "$X/lib/config.sh" || exit 2
. "$X/lib/timebox.sh"
PR_MODEL=${PR_MODEL:-claude-sonnet-5-5} PR_USD=${PR_USD:-1} PR_MIN=${PR_MIN:-10}  # defaults: lib/config.sh
BRANCH=$S_BRANCH WT=$S_WT
HANDBACK=handback/$(echo "$BRANCH" | tr '/' '-')
# The ticket's spec as it is now (a human may have corrected it since the run), else the run's copy.
SPEC=$TICKETS_DIR/$TICKET.md
[ -d "$WT" ] || { echo "pr: the run's worktree $WT is gone" >&2; exit 1; }
[ -f "$SPEC" ] || SPEC=$RUN/spec/$TICKET.md
[ -f "$SPEC" ] || { echo "pr: no spec for $TICKET in the run or $TICKETS_DIR" >&2; exit 1; }
log() { echo "pr: $*" >&2; [ -f "$RUN/events.log" ] && echo "$(date -u +%FT%TZ) pr: $*" >> "$RUN/events.log"; }

# The hand-back is the factory's working record: never in the product PR. Dropped in its own commit, kept on disk.
if [ "$OPEN" = yes ] && [ -n "$(git -C "$WT" ls-files -- handback | head -1)" ]; then
  git -C "$WT" rm -r -q --cached -- handback >&2 \
    && git -C "$WT" commit -q -m "[$TICKET] Removed handback/ from the branch" >&2 \
    || { log "could not drop handback/ from $BRANCH"; exit 1; }
  log "dropped handback/ from $BRANCH ($(git -C "$WT" rev-parse --short HEAD))"
fi

SHA=$(git -C "$WT" rev-parse --short HEAD)
# The PR's base, not the run's: the ticket's own commits (the oracle) are part of the PR.
MB=$(git -C "$WT" merge-base "origin/$PR_BASE" HEAD 2> /dev/null) || MB=$S_BASE
MB=$(git -C "$WT" rev-parse --short "$MB")
# The repo's own PR instructions come first (the writer runs in the worktree, so its CLAUDE.md and skills load too); the
# engine's template is the fallback for a repo with none.
TEMPLATE=$SKILL/templates/pr-template.md
found="" missing=""
for f in $PR_INSTRUCTIONS; do
  if [ -f "$WT/$f" ]; then found="$found \`$f\`"; else missing="$missing $f"; fi
done
[ -n "$missing" ] && log "PR_INSTRUCTIONS not in the worktree:$missing"
if [ -n "$found" ]; then INSTRUCTIONS="Read these first:$found."
else INSTRUCTIONS="The project names none: find them."; fi
URL=$(grep -m1 -oE "https?://[^ )>\`]*$TICKET\b" "$SPEC")

{ sed -e "s|@TICKET@|$TICKET|g" -e "s|@BRANCH@|$BRANCH|g" -e "s|@BASE@|$MB|g" -e "s|@SHA@|$SHA|g" \
      -e "s|@SPEC@|$SPEC|g" -e "s|@HANDBACK@|$HANDBACK|g" -e "s|@TICKET_URL@|$URL|g" -e "s|@TITLE_MAX@|$PR_TITLE_MAX|g" \
      -e "s|@INSTRUCTIONS@|$INSTRUCTIONS|g" "$SKILL/prompts/pr.txt" \
    | awk -v t="$TEMPLATE" '$0 == "@TEMPLATE@" { while ((getline l < t) > 0) print l; next } { print }'; } > "$RUN/pr.prompt"
log "writing the PR for $TICKET ($MB..$SHA, instructions:${found:- the repo's own, else the engine's template})"
( cd "$WT" && timebox $((PR_MIN * 60)) claude -p "$(cat "$RUN/pr.prompt")" --model "$PR_MODEL" \
    --append-system-prompt "$(awk 'f > 1; /^---$/ { f++ }' "$SKILL/agents/factory-pr.md")" \
    --max-budget-usd "$PR_USD" --tools Read Grep Glob Bash --allowedTools "${REVIEW_TOOLS[@]}" --add-dir "$(dirname "$SPEC")" \
    --output-format json > "$RUN/pr.json" 2> "$RUN/pr.err" < /dev/null )
rc=$?
jq -r '.result // ""' "$RUN/pr.json" > "$RUN/pr.raw" 2> /dev/null
COST=$(jq -r '.total_cost_usd // 0' "$RUN/pr.json" 2> /dev/null)
TITLE=$(grep -m1 '^TITLE: ' "$RUN/pr.raw" | sed 's/^TITLE: *//')
[ "$rc" -eq 0 ] && [ -n "$TITLE" ] || { log "no usable answer (exit $rc): $RUN/pr.json, $RUN/pr.err"; exit 1; }
case "$TITLE" in "[$TICKET]"*) ;; *) TITLE="[$TICKET] $TITLE" ;; esac
FORMAT=$(grep -m1 '^FORMAT: ' "$RUN/pr.raw" | sed 's/^FORMAT: *//')
log "format: ${FORMAT:-not said}"
# The repo's instructions set the title's limit; the engine holds the template's titles to PR_TITLE_MAX only.
case "$FORMAT" in repo*) ;; *) [ ${#TITLE} -le "$PR_TITLE_MAX" ] \
  || log "the title is ${#TITLE} characters ($PR_TITLE_MAX at most): shorten it in pr-title.txt" ;; esac
printf '%s\n' "$TITLE" > "$RUN/pr-title.txt"

# The commits a reviewer sees: every one that touches something outside handback/.
COMMITS=$(git -C "$WT" rev-list --reverse "$MB..$SHA" | while read -r c; do
  [ -n "$(git -C "$WT" diff-tree --no-commit-id --name-only -r "$c" | grep -v '^handback/')" ] \
    && git -C "$WT" log -1 --format='- %h - %s' --abbrev=8 "$c"
done)
BODY=$(awk 'f && !(started == 0 && /^(FORMAT: |$)/) { started = 1; print; next } /^TITLE: / { f = 1 }' "$RUN/pr.raw")
# The factory's own words must not reach the PR: a description that names them is the writer's mistake, for a human.
LEAK=$(printf '%s\n%s\n' "$TITLE" "$BODY" | grep -noiE 'hand-?back|factory|builder|reviewer|verdict|charter|oracle|exploratory|verification record|golden image|time box|\$[0-9]+(\.[0-9]+)?|\bVMs?\b' | head -5 | tr '\n' ' ')
printf '%s\n' "$BODY" | COMMITS=$COMMITS awk '$0 == "@COMMITS@" { print ENVIRON["COMMITS"]; next } { print }' > "$RUN/pr.md"
log "wrote $RUN/pr-title.txt and $RUN/pr.md (\$$COST)"
if [ -n "$LEAK" ]; then
  log "the description names the factory ($LEAK): fix pr.md$([ "$OPEN" = yes ] && echo ", then factory.sh pr $(basename "$RUN") --open again")"
  [ "$OPEN" = yes ] && exit 1
fi
[ "$OPEN" = yes ] || exit 0

git -C "$WT" push -q -u origin "$BRANCH" 2>> "$RUN/pr.err" || { log "push of $BRANCH failed: $RUN/pr.err"; exit 1; }
existing=$(cd "$WT" && gh pr view "$BRANCH" --json url,state -q 'select(.state == "OPEN") | .url' 2> /dev/null)
if [ -n "$existing" ]; then
  (cd "$WT" && gh pr edit "$BRANCH" --title "$TITLE" --body-file "$RUN/pr.md" > /dev/null 2>> "$RUN/pr.err") \
    || { log "could not update $existing: $RUN/pr.err"; exit 1; }
  log "updated $existing"; echo "$existing"
else
  url=$(cd "$WT" && gh pr create --draft --base "$PR_BASE" --head "$BRANCH" --title "$TITLE" --body-file "$RUN/pr.md" 2>> "$RUN/pr.err") \
    || { log "gh pr create failed: $RUN/pr.err"; exit 1; }
  log "opened $url"; echo "$url"
fi
