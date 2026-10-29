# Profile: Devolutions Console, the Avalonia port of the DVLS Console (sourced by the factory's config loader after the
# ticket's .sh; bash 3.2 compatible). Contract: the factory skill's references/profiles.md; `factory.sh check console`.
# The ticket's .sh sets ACCEPT_TEST (usually Console/Console.Shared.Tests/Console.Shared.Tests.csproj), ACCEPT_FILTER,
# ORACLE_PATHS, SCOPE_REGEX.

APP_NAME="Devolutions Console"
# Linux (Console.Linux) comes with the factory's Linux guest.
TARGETS="windows"

PROTECTED_EXTRA=".github"
# Where its code is (repo paths, space-separated): `factory.sh which <path>` picks the profile from these.
CODE_PATHS="Console/"
REVIEW_STANDARDS="$PROFILE_DIR/reviewer.md"

# GitHub only accepts branches under a team prefix (devex/, rdmw/, …): use the ticket's project key.
BRANCH_PREFIX="$(echo "${TICKET%%-*}" | tr '[:upper:]' '[:lower:]')/factory-"
PR_BASE=master
