---
name: weekly-update
description: "[EXPERIMENTAL] Drafts the weekly Slack post that goes with a weekly video (\"voici ce sur quoi j'ai travaillé cette semaine\"): every PR merged or still open since the author's last post in the channel, each line with its Jira ticket and its PR linked, grouped by product, written in the language and style of the author's previous posts, and saved as a Slack draft in that channel (never sent). Use for 'weekly update', 'my weekly video post', 'draft my weekly message', 'list my PRs of the week for Slack'. Not for release notes or a team-wide report."
---

# Weekly update post

Drafts the message the user posts with their weekly video. The user records the video and sends the post; this skill
only gathers, writes and saves the draft.

## Settings

Read `~/.claude/weekly-update.json` if it exists:

```json
{ "channel": "C0B8VDLQLTH", "githubOrg": "Devolutions", "jira": "https://devolutions.atlassian.net" }
```

A channel, org or Jira site the user names in the request wins. If the file is missing and the request names no
channel, ask for the channel once, then offer to save the answers to that file.

## 1. Find the window

1. Read the channel (`slack_read_channel`, ~30 messages) and keep the user's own posts (match their Slack email or
   name). The newest one that lists PRs is **the last post**.
2. The window starts at the last post's timestamp. With no previous post, it starts on Monday of the current week.
3. Collect every PR number and ticket key linked in the last post: they were already reported, so leave them out,
   even if they merged after it was sent.

## 2. Gather the work

```bash
gh search prs --author=@me --owner=<org> --merged-at=">=<window start date>" \
  --json number,title,repository,url,closedAt --limit 100
gh search prs --author=@me --owner=<org> --state=open \
  --json number,title,repository,url,isDraft,updatedAt --limit 50
```

- `--merged-at` takes a date, so drop merged PRs whose `closedAt` is before the last post's exact time.
- Keep an open PR only if it was updated inside the window; a PR untouched for weeks is not this week's work.
- Ticket key: the `[KEY-123]` prefix of the title (or a key in the branch name). Strip `CR:…` suffixes from titles.
  A PR with no key gets the PR link alone; never invent a ticket.
- A repo that is open source (e.g. `avalonia-extensions`) gets no Jira key or link in the post.
- When a title is too terse to describe in a sentence, read the PR body (`gh pr view <n> -R <repo> --json body`).

## 3. Write the post

Match the user's previous posts (the last 3–5 of them): their language (French so far), their greeting, their emoji.
On top of that, every item carries **both** links: the ticket, then the PR.

**Item line:**

```
:pr-merged: [DVLS-15761](https://devolutions.atlassian.net/browse/DVLS-15761) : Les logs serveur sont groupés par jour ([PR #22627](https://github.com/Devolutions/RDM/pull/22627))
```

- Status emoji: `:pr-merged:` merged, `:pr-open:` open (draft or not). The user also uses `:factory:` for a ticket
  running in their software factory with no PR yet; only use it if they mention one.
- The description is one sentence about what the user or the code can see, not the commit verb: a fix says what was
  wrong ("Escape ne fermait pas les wizards passé la première page"), a feature says what exists now ("Ajout de…").
- Several PRs for one ticket (a follow-up fix, a test fix, a hidden option for the same feature): **one line**, the
  ticket once, then every PR: `([PR #23654](…), [PR #24691](…))`. A test-only follow-up folds into its ticket.

**Grouping** (only as deep as needed):

- Top level by product: Devolutions Console (`DVLS-*` tickets, titles naming the Console), Remote Desktop Manager
  (`RDMW-*`, `DEVEX-*` not about the Console), then one section per other repo (FleetView, avalonia-extensions, …).
  A `DEVEX-*` ticket can be either; decide from its title or files.
- Inside a section with more than ~6 items, sub-group: features first, then themes that stand out (accessibility and
  keyboard, a control like DevoDataGrid), then "Des bugs:". A small section stays a flat list.

**Intro:** reuse the user's usual greeting ("Hey! Voici ce sur quoi j'ai travaillé cette semaine!"). If they said why
they post early ("je ne travaille pas demain"), say it. Leave the personal paragraph about the video to them.

## 4. Save the Slack draft

Use `slack_send_message_draft` on the channel, never `slack_send_message`.

- **Lists:** standard markdown, `- ` with two spaces per nesting level. Never type bullet characters (`•`, `◦`, `▪︎`):
  Slack keeps them as text and the whole post collapses into one paragraph.
- **One draft per channel:** Slack keeps a single attached draft per channel. `attached_draft_exists` means the user
  must send or clear the one in the message box first; ask them, then retry. A create that returns no `draft_id`
  did not attach either: say so instead of claiming the draft is there.
- After saving, tell the user in a few lines: the window covered, how many items per section, what was left out and
  why (already in the last post, stale open PR), and any description you were unsure of.
