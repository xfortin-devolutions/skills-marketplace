# products.sh: finds and loads product VM definitions (bash 3.2 compatible). Set before sourcing: VMT_DIR (the skill
# folder). A definitions folder holds one folder per product: <product>/product.sh (APP_NAME, TARGETS, CODE_PATHS) and
# <product>/targets/<os>/target.sh with the target's scripts, plus <product>/layer/ when it has a VM layer
# (references/products.md). The repo's own .vm/ wins; until a repo carries one, the toolkit bundles it in
# projects/<name>/, whose project.sh says which repo it is for (REPO_MATCH, an ERE on the origin remote URL).

# products_dir <path in a repo>: that repo's definitions folder; nothing (exit 1) when it has none.
products_dir() {
  local top origin p m
  top=$(git -C "$1" rev-parse --show-toplevel 2> /dev/null) || return 1
  [ -d "$top/.vm" ] && { echo "$top/.vm"; return 0; }
  origin=$(git -C "$top" remote get-url origin 2> /dev/null) || return 1
  for p in "$VMT_DIR"/projects/*/project.sh; do
    [ -f "$p" ] || continue
    m=$(REPO_MATCH=""; . "$p" > /dev/null 2>&1; echo "$REPO_MATCH")
    [ -n "$m" ] && echo "$origin" | grep -qE "$m" && { dirname "$p"; return 0; }
  done
  return 1
}

# products_list <definitions folder>: one product name a line
products_list() {
  local d
  for d in "$1"/*/product.sh; do [ -f "$d" ] && basename "$(dirname "$d")"; done
}

# product_field <product folder> <VAR>: one variable of its product.sh, read without changing the caller's
product_field() { (eval "$2=''"; . "$1/product.sh" > /dev/null 2>&1; eval "echo \"\$$2\""); }

# product_for_path <definitions folder> <repo-relative path>: the product whose CODE_PATHS has the longest prefix of it
product_for_path() {
  local p best="" blen=0 c
  for p in "$1"/*/product.sh; do
    [ -f "$p" ] || continue
    for c in $(product_field "$(dirname "$p")" CODE_PATHS); do
      case "$2" in "$c"*) [ ${#c} -gt $blen ] && best=$(basename "$(dirname "$p")") blen=${#c} ;; esac
    done
  done
  [ -n "$best" ] && echo "$best"
}

# load_product <product folder> [<target>]: sources product.sh, then the target's target.sh (the given one, else
# PLATFORM, else the product's first), with TARGET_DIR set as target.sh expects. Sets PRODUCT_DIR, PLATFORM, TARGET_DIR,
# the target's GUEST_* and GOLDEN_IMAGE, and exports VM_IMAGE and VM_SHARE_CHECK for vmctl.sh.
load_product() {
  PRODUCT_DIR=$1
  [ -f "$PRODUCT_DIR/product.sh" ] || { echo "no product definition in $PRODUCT_DIR (product.sh)" >&2; return 2; }
  . "$PRODUCT_DIR/product.sh"
  PLATFORM=${2:-${PLATFORM:-${TARGETS%% *}}}
  TARGET_DIR=$PRODUCT_DIR/targets/$PLATFORM
  [ -n "$PLATFORM" ] && [ -f "$TARGET_DIR/target.sh" ] \
    || { echo "product $(basename "$PRODUCT_DIR") has no target '$PLATFORM' (targets/<os>/target.sh)" >&2; return 2; }
  . "$TARGET_DIR/target.sh"
  GOLDEN_IMAGE=${GOLDEN_IMAGE:-base.qcow2}
  export VM_IMAGE=$GOLDEN_IMAGE VM_SHARE_CHECK=${SHARE_CHECK:-}
}
