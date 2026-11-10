# Product: Remote Desktop Manager (sourced by the VM toolkit's lib/products.sh; bash 3.2 compatible). Contract:
# references/products.md; `vmt check rdm`.

APP_NAME="Remote Desktop Manager (RDM)"
# Guest targets under targets/<name>/; the first is the default. macOS and Linux come later.
TARGETS="windows"
# Where its code is (repo paths, space-separated): `vmt which <path>` picks the product from these.
CODE_PATHS="RDM/"
