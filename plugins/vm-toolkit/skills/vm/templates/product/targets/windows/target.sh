# @PRODUCT@ on the Windows 11 ARM64 guest (sourced by the VM toolkit's lib/products.sh).
# Contract: build.ps1 ends with "BUILD EXIT CODE: <n>", test.ps1 with "TEST EXIT CODE: <n>" (both read $Project, test.ps1
# also $Filter); launch.ps1 prints "LAUNCH OK" once the app is starting.
GUEST_OS=windows
GUEST_DESC="Windows 11 ARM64"
# The image clones start from: base.qcow2, or a layer the product builds (layer/, vmt layer @PRODUCT@).
GOLDEN_IMAGE=base.qcow2
# A file the shared worktree must contain: proves the right repo is shared.
SHARE_CHECK="TODO: a repo-relative file, e.g. the solution"
GUEST_BUILD=$TARGET_DIR/build.ps1
# Optional: builds on the Mac instead (a bash script, cross-compiling for the guest; references/products.md), on a
# machine with VM_HOST_BUILD=yes. Only once its output is proven to launch and test in the guest like build.ps1's.
# HOST_BUILD=$TARGET_DIR/host-build.sh
GUEST_TEST=$TARGET_DIR/test.ps1
GUEST_LAUNCH=$TARGET_DIR/launch.ps1
