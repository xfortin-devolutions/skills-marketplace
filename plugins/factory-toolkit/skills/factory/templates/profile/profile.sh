# Profile @PROFILE@ (sourced by the factory's config loader after the ticket's .sh; bash 3.2 compatible).
# The contract: the factory skill's references/profiles.md. Check it with `factory.sh check @PROFILE@`.

# What the builder and the QA agent are told they work on.
APP_NAME="TODO: product name"
# Guest targets under targets/<name>/, space-separated; the first is the default a ticket gets.
TARGETS="windows"

# Paths the builder may never touch, beyond the ticket's oracle, .factory and .claude (space-separated, repo-relative).
PROTECTED_EXTRA=".github"
# The reviewer's standards for this product (what to check, what Data flows means here).
REVIEW_STANDARDS="$PROFILE_DIR/reviewer.md"

# Branches the remote accepts, and the PR target. TICKET is set: e.g. DEVEX-123 -> devex/factory-devex-123-build-<stamp>.
BRANCH_PREFIX="$(echo "${TICKET%%-*}" | tr '[:upper:]' '[:lower:]')/factory-"
PR_BASE=master
