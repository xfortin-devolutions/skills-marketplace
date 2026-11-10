# Profile: Remote Desktop Manager (sourced by the factory's config loader after the ticket's .sh; bash 3.2 compatible).
# The factory's settings for this product. What the product is and how its VM builds, tests and launches it (APP_NAME,
# TARGETS, CODE_PATHS, targets/) is the VM toolkit's product definition VM_PRODUCT (default: the profile's name).
# The ticket's .sh sets ACCEPT_TEST (test csproj), ACCEPT_FILTER (optional), ORACLE_PATHS, SCOPE_REGEX.

PROTECTED_EXTRA=".github"
REVIEW_STANDARDS="$PROFILE_DIR/reviewer.md"

# GitHub only accepts branches under a team prefix (devex/, rdmw/, …): use the ticket's project key.
BRANCH_PREFIX="$(echo "${TICKET%%-*}" | tr '[:upper:]' '[:lower:]')/factory-"
PR_BASE=master
