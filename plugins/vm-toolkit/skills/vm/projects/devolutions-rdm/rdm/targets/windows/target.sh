# RDM on the Windows 11 ARM64 guest (sourced by the VM toolkit's lib/products.sh).
# Contract: build.ps1 ends with "BUILD EXIT CODE: <n>", test.ps1 with "TEST EXIT CODE: <n>" (both read $Project, test.ps1
# also $Filter); launch.ps1 prints "LAUNCH OK" once the app is starting.
GUEST_OS=windows
GUEST_DESC="Windows 11 ARM64"
SHARE_CHECK=RemoteDesktopManagerWindows.slnx
GUEST_BUILD=$TARGET_DIR/build.ps1
# Builds on the Mac instead (cross-compiled; the guest only tests and runs), unless the machine says VM_HOST_BUILD=no
# or host-build.sh --check declines the worktree (a commit before RDM's cross-compile fix, #22751: no RDP/SSH natives).
HOST_BUILD=$TARGET_DIR/host-build.sh
GUEST_TEST=$TARGET_DIR/test.ps1
GUEST_LAUNCH=$TARGET_DIR/launch.ps1
