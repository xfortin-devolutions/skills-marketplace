#!/bin/bash
# products.test.sh: lib/products.sh and vmt's product commands on throwaway repos: a repo's .vm/ wins over the bundled
# definitions, REPO_MATCH picks the bundled project, the longest CODE_PATHS prefix picks the product, load_product
# exports what vmctl.sh reads, and vmt init writes the VM folder's guest.conf. No VM.
#   tests/products.test.sh
# bash 3.2 compatible.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SKILL=$(cd "$HERE/../skills/vm" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/vmt-products-test.XXXXXX")
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
FAILS=0
check() { if [ "$2" = "$3" ]; then echo "✓ $1"; else FAILS=$((FAILS + 1)); echo "✗ $1: wanted '$3', got '$2'"; fi; }

# A bundled project (in a copy of the skill) and two repos: one it matches, one with its own .vm/.
cp -R "$SKILL" "$T/skill"
rm -rf "$T/skill/projects"
mkdir -p "$T/skill/projects/acme/app/targets/windows" "$T/skill/projects/acme/admin/targets/windows"
echo "REPO_MATCH='[:/]acme/mono(\.git)?\$'" > "$T/skill/projects/acme/project.sh"
printf 'APP_NAME="Acme App"\nTARGETS="windows"\nCODE_PATHS="App/ Shared/"\n' > "$T/skill/projects/acme/app/product.sh"
printf 'APP_NAME="Acme Admin"\nTARGETS="windows"\nCODE_PATHS="Admin/ Shared/Admin/"\n' > "$T/skill/projects/acme/admin/product.sh"
for p in app admin; do
  printf 'GUEST_OS=windows\nGUEST_DESC="Fake"\nGOLDEN_IMAGE=%s\nSHARE_CHECK=x.sln\nGUEST_BUILD=$TARGET_DIR/build.ps1\nGUEST_TEST=$TARGET_DIR/test.ps1\nGUEST_LAUNCH=$TARGET_DIR/launch.ps1\n' \
    "$([ $p = admin ] && echo admin-layer.qcow2 || echo base.qcow2)" > "$T/skill/projects/acme/$p/targets/windows/target.sh"
done
for r in mono other own; do
  mkdir -p "$T/$r" && git -C "$T/$r" init -q
done
git -C "$T/mono" remote add origin git@github.com:acme/mono.git
git -C "$T/other" remote add origin https://github.com/acme/other.git
git -C "$T/own" remote add origin git@github.com:acme/mono.git
mkdir -p "$T/own/.vm/solo/targets/windows"
printf 'APP_NAME=Solo\nTARGETS=windows\nCODE_PATHS="src/"\n' > "$T/own/.vm/solo/product.sh"
printf 'GUEST_OS=windows\nGUEST_BUILD=$TARGET_DIR/build.ps1\nGUEST_TEST=$TARGET_DIR/test.ps1\n' > "$T/own/.vm/solo/targets/windows/target.sh"

VMT_DIR=$T/skill
. "$T/skill/scripts/lib/products.sh"
check "REPO_MATCH picks the bundled project" "$(products_dir "$T/mono")" "$T/skill/projects/acme"
check "no match, no definitions" "$(products_dir "$T/other"; echo "rc=$?")" "rc=1"
check "the repo's .vm/ wins" "$(products_dir "$T/own")" "$T/own/.vm"
check "products are listed" "$(products_list "$T/skill/projects/acme" | tr '\n' ' ')" "admin app "
check "longest CODE_PATHS prefix" "$(product_for_path "$T/skill/projects/acme" Shared/Admin/x.cs)" "admin"
check "shorter prefix elsewhere" "$(product_for_path "$T/skill/projects/acme" Shared/Core/x.cs)" "app"
check "no product for a path" "$(product_for_path "$T/skill/projects/acme" docs/x.md; echo "rc=$?")" "rc=1"
check "load_product exports the image and the share check" \
  "$(load_product "$T/skill/projects/acme/admin" && echo "$VM_IMAGE $VM_SHARE_CHECK $PLATFORM ${GUEST_BUILD#$T/}")" \
  "admin-layer.qcow2 x.sln windows skill/projects/acme/admin/targets/windows/build.ps1"
check "an unknown target fails" "$(load_product "$T/skill/projects/acme/app" linux 2> /dev/null; echo "rc=$?")" "rc=2"

# vmt init: guest.conf for a VM folder, from the repo's definitions (a fake HOME keeps this machine's config out).
export HOME=$T/home VM_ROOT=$T/vms
mkdir -p "$HOME"
check "init needs --product when the repo has several" \
  "$("$T/skill/scripts/vmt" init "$T/vm1" "$T/mono" 2>&1 | grep -c 'pass --product')" "1"
"$T/skill/scripts/vmt" init "$T/vm1" "$T/mono" --product admin > /dev/null
( . "$T/vm1/guest.conf"
  check "init: worktree and product" "$WORKTREE $PRODUCT" "$T/mono admin"
  check "init: image and home" "$VM_IMAGE ${VM_HOME#$T/}" "admin-layer.qcow2 vms/windows"
  check "init: scripts" "${GUEST_TEST#$T/}" "skill/projects/acme/admin/targets/windows/test.ps1" )
"$T/skill/scripts/vmt" init "$T/vm2" "$T/own" > /dev/null
( . "$T/vm2/guest.conf"; check "init: the only product needs no --product" "$PRODUCT $VM_IMAGE" "solo base.qcow2" )
check "which" "$(cd "$T/mono" && "$T/skill/scripts/vmt" which App/a.cs Admin/b.cs README.md | tr '\n' ' ')" \
  "App/a.cs: app Admin/b.cs: admin README.md: no product "

[ "$FAILS" = 0 ] && echo "products: all passed" || { echo "products: $FAILS failed"; exit 1; }
