# Profile: Remote Desktop Manager (sourced by the factory's config loader after the ticket's .sh; bash 3.2 compatible).
# The ticket's .sh sets ACCEPT_TEST (test csproj), ACCEPT_FILTER (optional), ORACLE_PATHS, SCOPE_REGEX. Builds and tests
# run in the target's guest (targets/<name>/build.ps1, test.ps1), never on the Mac.

APP_NAME="Remote Desktop Manager (RDM)"
# Guest targets under targets/<name>/; the first is the default. macOS and Linux come later.
TARGETS="windows"

PROTECTED_EXTRA=".github"
# Where its code is (repo paths, space-separated): `factory.sh which <path>` picks the profile from these.
CODE_PATHS="RDM/"
REVIEW_STANDARDS="$PROFILE_DIR/reviewer.md"

# GitHub only accepts branches under a team prefix (devex/, rdmw/, …): use the ticket's project key.
BRANCH_PREFIX="$(echo "${TICKET%%-*}" | tr '[:upper:]' '[:lower:]')/factory-"
PR_BASE=master
