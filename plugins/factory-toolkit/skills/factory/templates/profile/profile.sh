# Profile @PROFILE@ (sourced by the factory's config loader after the ticket's .sh; bash 3.2 compatible).
# The contract: the factory skill's references/profiles.md. Check it with `factory.sh check @PROFILE@`.
# The factory's settings for one product. The product itself (APP_NAME, TARGETS, CODE_PATHS, its targets' build, test
# and launch scripts, its VM layer) is a VM toolkit product definition: VM_PRODUCT, default the profile's name
# (`vmt new-product <name>` starts one).
#VM_PRODUCT="@PROFILE@"

# Paths the builder may never touch, beyond the ticket's oracle, .factory and .claude (space-separated, repo-relative).
PROTECTED_EXTRA=".github"
# The reviewer's standards for this product (what to check, what Data flows means here).
REVIEW_STANDARDS="$PROFILE_DIR/reviewer.md"

# Branches the remote accepts, and the PR target. TICKET is set: e.g. DEVEX-123 -> devex/factory-devex-123-build-<stamp>.
BRANCH_PREFIX="$(echo "${TICKET%%-*}" | tr '[:upper:]' '[:lower:]')/factory-"
PR_BASE=master
