# The SampleApp on the Windows 11 ARM64 guest (sourced by the VM toolkit's lib/products.sh): the plain golden image, no
# layer. Contract: build.ps1 ends with "BUILD EXIT CODE: <n>", test.ps1 with "TEST EXIT CODE: <n>" (both read $Project,
# test.ps1 also $Filter); launch.ps1 prints "LAUNCH OK" once the app is starting.
GUEST_OS=windows
GUEST_DESC="Windows 11 ARM64"
SHARE_CHECK=avalonia-extensions.sln
GUEST_BUILD=$TARGET_DIR/build.ps1
# Builds on the Mac instead (the projects are portable net10.0: the output runs in the guest with `dotnet <dll>`),
# unless the machine says VM_HOST_BUILD=no or host-build.sh --check declines the worktree.
HOST_BUILD=$TARGET_DIR/host-build.sh
GUEST_TEST=$TARGET_DIR/test.ps1
GUEST_LAUNCH=$TARGET_DIR/launch.ps1
