# Profile: the avalonia-extensions themes and controls, run in the SampleApp (sourced by the factory's config loader
# after the ticket's .sh; bash 3.2 compatible). Contract: the factory skill's references/profiles.md; `factory.sh check
# sampleapp`. The product itself (APP_NAME, TARGETS, CODE_PATHS, targets/) is the VM toolkit's product definition
# sampleapp, in its projects/avalonia-extensions/.
# The ticket's .sh sets ACCEPT_TEST (usually tests/Devolutions.AvaloniaControls.Tests/Devolutions.AvaloniaControls.Tests.csproj),
# ACCEPT_FILTER (part of a test's full name, no spaces), ORACLE_PATHS, SCOPE_REGEX, and, because the project keeps ticket
# keys out of git (TICKET_IN_GIT=no): BRANCH_SLUG (<action>-<feature>, e.g. fix-combobox-drop-down-width) and AREA, the
# repo's project prefix for branches and commits (Controls, DevExpress, MacOS, Linux, SampleApp; default Controls).

# Randy (the repo's review bot) asks for a human review of these; the builder never touches them.
PROTECTED_EXTRA=".github/workflows .github/CODEOWNERS .github/randy.yml"
REVIEW_STANDARDS="$PROFILE_DIR/reviewer.md"

# The repo's conventions (.claude/commands/commit.md): branches {Project}/{action}-{feature}, commits
# "[Project] Action description".
BRANCH_PREFIX="${AREA:-Controls}/"
COMMIT_PREFIX="[${AREA:-Controls}] "
PR_BASE=master
