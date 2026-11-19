# RDM on the macOS guest (sourced by the VM toolkit's lib/products.sh): a tart VM (vmctl.sh), lean, with no SDK in it.
# The Mac builds the app (host-build.sh); the guest only runs it, from the shared worktree. No guest build or test
# scripts: RDM Mac's tests run on the Mac itself, which is the same OS.
GUEST_OS=macos
GUEST_DESC="macOS 26 Tahoe ARM64"
GOLDEN_IMAGE=base
SHARE_CHECK=RemoteDesktopManagerMac.sln
HOST_BUILD=$TARGET_DIR/host-build.sh
GUEST_LAUNCH=$TARGET_DIR/launch.sh
