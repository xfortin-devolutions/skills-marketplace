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
. "$VMT/scripts/lib/timebox.sh"
PR_MODEL=${PR_MODEL:-claude-sonnet-5-5} PR_USD=${PR_USD:-1} PR_MIN=${PR_MIN:-10}  # defaults: lib/config.sh
BRANCH=$S_BRANCH WT=$S_WT
HANDBACK=handback/$(echo "$BRANCH" | tr '/' '-')
# The ticket's spec as it is now (a human may have corrected it since the run), else the run's copy.
SPEC=$TICKETS_DIR/$TICKET.md
[ -d "$WT" ] || { echo "pr: the run's worktree $WT is gone" >&2; exit 1; }
[ -f "$SPEC" ] || SPEC=$RUN/spec/$TICKET.md
[ -f "$SPEC" ] || { echo "pr: no spec for $TICKET in the run or $TICKETS_DIR" >&2; exit 1; }
log() { echo "pr: $*" >&2; [ -f "$RUN/events.log" ] && echo "$(date -u +%FT%TZ) pr: $*" >> "$RUN/events.log"; }

# The hand-back is the factory's working record: never in the product PR. Dropped in its own commit, kept on disk. A
# public repo's (TICKET_IN_GIT=no) gets the branch without it ever (public_history below) instead: its hand-back commits
# name the ticket.
if [ "$OPEN" = yes ] && [ "$TICKET_IN_GIT" != no ] && [ -n "$(git -C "$WT" ls-files -- handback | head -1)" ]; then
  git -C "$WT" rm -r -q --cached -- handback >&2 \
    && git -C "$WT" commit -q -m "[$TICKET] Removed handback/ from the branch" >&2 \
    || { log "could not drop handback/ from $BRANCH"; exit 1; }
  log "dropped handback/ from $BRANCH ($(git -C "$WT" rev-parse --short HEAD))"
fi

SHA=$(git -C "$WT" rev-parse --short HEAD)
# The PR's base, not the run's: the ticket's own commits (the oracle) are part of the PR.
MB=$(git -C "$WT" merge-base "origin/$PR_BASE" HEAD 2> /dev/null) || MB=$S_BASE
MB=$(git -C "$WT" rev-parse --short "$MB")

# public_history: the branch as a public repo gets it: each commit again without handback/ (one that only touched it
# goes), with its message, author and committer, so the same branch gives the same commits on each --open; the run's
# branch and worktree keep theirs. Prints the last commit.
public_history() {
  local c t prev ptree idx
  idx=$(mktemp -d)/index prev=$(git -C "$WT" rev-parse "$MB") ptree=$(git -C "$WT" rev-parse "$MB^{tree}")
  for c in $(git -C "$WT" rev-list --reverse "$MB..HEAD"); do
    GIT_INDEX_FILE=$idx git -C "$WT" read-tree "$c" || return 1
    GIT_INDEX_FILE=$idx git -C "$WT" rm -r -q -f --cached --ignore-unmatch -- handback > /dev/null || return 1
    t=$(GIT_INDEX_FILE=$idx git -C "$WT" write-tree) || return 1
    [ "$t" = "$ptree" ] && continue
    prev=$(who() { git -C "$WT" log -1 --format="$1" "$c"; }
           export GIT_AUTHOR_NAME="$(who %an)" GIT_AUTHOR_EMAIL="$(who %ae)" GIT_AUTHOR_DATE="$(who %aI)" \
             GIT_COMMITTER_NAME="$(who %cn)" GIT_COMMITTER_EMAIL="$(who %ce)" GIT_COMMITTER_DATE="$(who %cI)"
           who %B | git -C "$WT" commit-tree "$t" -p "$prev") || return 1
    ptree=$t
  done
  rm -rf "$(dirname "$idx")"
  echo "$prev"
}
# key_leak: where the text on stdin names a ticket (a key of the ticket's project, a Jira link), at most five places.
key_leak() { grep -noiE "\b${TICKET%%-*}-[0-9]+\b|atlassian\.net|/browse/" | head -5 | tr '\n' ' '; }
PUB=HEAD
if [ "$TICKET_IN_GIT" = no ]; then
  PUB=$(public_history) || { log "could not write $BRANCH without handback/"; exit 1; }
  log "the branch without handback/: $(git -C "$WT" rev-parse --short "$PUB") (the run's branch keeps it)"
fi
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
# A public repo's PR never names the ticket: outsiders can't open it.
[ "$TICKET_IN_GIT" = no ] && URL="" INSTRUCTIONS="$INSTRUCTIONS This repo is public: never name the ticket's key ($TICKET) or link it, in the title or the description, and leave out any section that would only hold it; describe the issue in plain words."
# A repo that wants its agent-written PRs signed (PR_FOOTER; @LOGIN@ is the gh account's login): the runner signs it.
[ -n "${PR_FOOTER:-}" ] && INSTRUCTIONS="$INSTRUCTIONS Write no signature or footer line: the runner adds the repo's."

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
[ "$TICKET_IN_GIT" = no ] || case "$TITLE" in "[$TICKET]"*) ;; *) TITLE="[$TICKET] $TITLE" ;; esac
FORMAT=$(grep -m1 '^FORMAT: ' "$RUN/pr.raw" | sed 's/^FORMAT: *//')
log "format: ${FORMAT:-not said}"
# The repo's instructions set the title's limit; the engine holds the template's titles to PR_TITLE_MAX only.
case "$FORMAT" in repo*) ;; *) [ ${#TITLE} -le "$PR_TITLE_MAX" ] \
  || log "the title is ${#TITLE} characters ($PR_TITLE_MAX at most): shorten it in pr-title.txt" ;; esac
printf '%s\n' "$TITLE" > "$RUN/pr-title.txt"

# The commits a reviewer sees: every one that touches something outside handback/.
COMMITS=$(git -C "$WT" rev-list --reverse "$MB..$PUB" | while read -r c; do
  [ -n "$(git -C "$WT" diff-tree --no-commit-id --name-only -r "$c" | grep -v '^handback/')" ] \
    && git -C "$WT" log -1 --format='- %h - %s' --abbrev=8 "$c"
done)
BODY=$(awk 'f && !(started == 0 && /^(FORMAT: |$)/) { started = 1; print; next } /^TITLE: / { f = 1 }' "$RUN/pr.raw")
# The factory's own words must not reach the PR: a description that names them is the writer's mistake, for a human.
LEAK=$(printf '%s\n%s\n' "$TITLE" "$BODY" | grep -noiE 'hand-?back|factory|builder|reviewer|verdict|charter|oracle|exploratory|verification record|golden image|time box|\$[0-9]+(\.[0-9]+)?|\bVMs?\b' | head -5 | tr '\n' ' ')
printf '%s\n' "$BODY" | COMMITS=$COMMITS awk '$0 == "@COMMITS@" { print ENVIRON["COMMITS"]; next } { print }' > "$RUN/pr.md"
if [ -n "${PR_FOOTER:-}" ]; then
  login=$(cd "$WT" && gh api user --jq .login 2> /dev/null)
  [ -n "$login" ] || { log "PR_FOOTER: no gh login (gh api user) to sign the description with"; [ "$OPEN" = yes ] && exit 1; }
  printf '\n%s\n' "${PR_FOOTER//@LOGIN@/$login}" >> "$RUN/pr.md"
fi
log "wrote $RUN/pr-title.txt and $RUN/pr.md (\$$COST)"
if [ -n "$LEAK" ]; then
  log "the description names the factory ($LEAK): fix pr.md$([ "$OPEN" = yes ] && echo ", then factory.sh pr $(basename "$RUN") --open again")"
  [ "$OPEN" = yes ] && exit 1
fi
# A public repo's: the ticket named anywhere it would publish (the branch, the PR, the commits and what they add) is
# never pushed. Lines are numbered in that order: the branch's name, the title, the description, the messages, the diff.
if [ "$TICKET_IN_GIT" = no ]; then
  KEYS=$( { echo "$BRANCH"; printf '%s\n%s\n' "$TITLE" "$BODY"; git -C "$WT" log --format=%B "$MB..$PUB"
           git -C "$WT" diff "$MB" "$PUB" | grep '^+'; } | key_leak)
  if [ -n "$KEYS" ]; then
    log "this public repo's branch or PR names the ticket ($KEYS): fix the commits or pr.md$([ "$OPEN" = yes ] && echo "; nothing was pushed")"
    [ "$OPEN" = yes ] && exit 1
  fi
fi
[ "$OPEN" = yes ] || exit 0

if [ "$TICKET_IN_GIT" = no ]; then
  # The branch without handback/, again on each --open: the same commits (public_history), so never a force push.
  git -C "$WT" push -q origin "$PUB:refs/heads/$BRANCH" 2>> "$RUN/pr.err" \
    || { log "push of $BRANCH failed: $RUN/pr.err"; exit 1; }
else
  git -C "$WT" push -q -u origin "$BRANCH" 2>> "$RUN/pr.err" || { log "push of $BRANCH failed: $RUN/pr.err"; exit 1; }
fi
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
