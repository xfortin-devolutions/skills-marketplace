# Project: the Devolutions/avalonia-extensions repo (the Devolutions Avalonia themes and controls, shown by its
# SampleApp). Team defaults, sourced by the factory skill's scripts/lib/config.sh; bash 3.2 compatible. Bundled with the
# skill while the factory is experimental; moving it to the repo is copying this folder to <repo>/.factory/.
# Machine-specific values (VM root, CPUs, RAM, budget overrides) go in ~/.factory/config.sh, not here.

# Which repo this project is for: an ERE on its origin remote URL (ignored once the project lives in the repo).
REPO_MATCH='[:/]Devolutions/avalonia-extensions(\.git)?$'

DEFAULT_PROFILE=sampleapp
# The repo is open source: outsiders can't open Devolutions tickets, so no ticket key or link reaches it. Branches are
# named by the ticket .sh (BRANCH_SLUG, and AREA for the repo's project prefix), commits by the profile's COMMIT_PREFIX,
# the PR is written without them, and pr.sh refuses to push a branch or a PR that names a ticket.
TICKET_IN_GIT=no
# The repo's own PR instructions, read first by the PR writer; each must exist at run time.
PR_INSTRUCTIONS=".claude/CLAUDE.md AGENTS.md"
# Its rules (.claude/CLAUDE.md, "GitHub Identity for Agents"): an agent-written PR body ends signed.
PR_FOOTER="_Posted by Claude Code (agent), on behalf of @@LOGIN@._"
# Docs a change may always update. The repo's .claude/CLAUDE.md and .claude/docs/ go through the hand-back's docs/
# (references/profiles.md); a theme's README.md (its control status list) is under src/, in the change's scope.
DOC_PATHS=".claude/CLAUDE.md .claude/docs/ docs/ README.md AGENTS.md .github/skills/ .github/copilot-instructions.md"
