# Builds RDM Mac (Debug, ARM64: the guest's architecture) on the Mac, in the worktree ($WORKTREE), or $PROJECT when
# guest.sh sets it: RemoteDesktopManager.app under RDM/Mac/RemoteDesktopManager/Clients/RemoteDesktopManager/bin/ARM64/Debug/,
# which launch.sh starts in the guest. From the repo's root, like the IDE's solution build: RDM/Mac/RemoteDesktopManager's
# own global.json pins an exact SDK patch the Mac may not have. SkipResxSorter: the pre-build ResxSorter step would
# rewrite .resx files in the worktree.
# No dotnet or no worktree means the harness failed: stop without a BUILD EXIT CODE so the runner reports ERROR.
# --check: exit 0 when this Mac can build it: a .NET 10 SDK with the macos workload (there is no guest build to fall
# back on: the macOS VM has no SDK).
if [ "${1:-}" = --check ]; then
  v=$(cd "$WORKTREE" && dotnet --version 2> /dev/null) || { echo "no dotnet SDK on this Mac"; exit 1; }
  case "$v" in 10.*) ;; *) echo "this Mac's dotnet SDK is $v, not 10.x"; exit 1 ;; esac
  (cd "$WORKTREE" && dotnet workload list 2> /dev/null) | grep -q '^macos ' \
    || { echo "no macos workload in this Mac's dotnet SDK (sudo dotnet workload install macos)"; exit 1; }
  exit 0
fi
command -v dotnet > /dev/null || { echo "no dotnet SDK on this Mac (brew install --cask dotnet-sdk)"; exit; }
cd "$WORKTREE" || exit
start=$(date +%s)
dotnet build "${PROJECT:-RemoteDesktopManagerMac.sln}" -c Debug -p:Platform=ARM64 -p:SkipResxSorter=true \
  -nologo -v:minimal -clp:Summary 2>&1
echo "BUILD EXIT CODE: $? after $(( $(date +%s) - start )) s"
