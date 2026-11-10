# RDM on the Windows 11 ARM64 guest (sourced by the VM toolkit's lib/products.sh).
# Contract: build.ps1 ends with "BUILD EXIT CODE: <n>", test.ps1 with "TEST EXIT CODE: <n>" (both read $Project, test.ps1
# also $Filter); launch.ps1 prints "LAUNCH OK" once the app is starting.
GUEST_OS=windows
GUEST_DESC="Windows 11 ARM64"
SHARE_CHECK=RemoteDesktopManagerWindows.slnx
GUEST_BUILD=$TARGET_DIR/build.ps1
GUEST_TEST=$TARGET_DIR/test.ps1
GUEST_LAUNCH=$TARGET_DIR/launch.ps1
