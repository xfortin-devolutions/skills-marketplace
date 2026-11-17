# Builds the Windows solution on the Mac, in the worktree ($WORKTREE), or $PROJECT when guest.sh sets it: the same
# output build.ps1 leaves (RDM/Windows/Common.Windows.props cross-compiles from a non-Windows host: EnableWindowsTargeting,
# the win-<host arch> RID, so an ARM64 guest runs it). Checked 2026-11-17: the whole solution, 0 errors, ~3 min; the
# Mac-built RDM runs in the guest and its tests run there with --no-build.
# DefaultAppHostRuntimeIdentifier: a plain net10.0 test project would get a macOS app host, and xUnit v3 starts a test
# assembly through its .exe in the guest. SkipResxSorter: the pre-build ResxSorter step would rewrite .resx files.
# No dotnet or no worktree means the harness failed: stop without a BUILD EXIT CODE so the runner reports ERROR.
command -v dotnet > /dev/null || { echo "no dotnet SDK on this Mac (brew install --cask dotnet-sdk)"; exit; }
cd "$WORKTREE" || exit
start=$(date +%s)
dotnet build "${PROJECT:-RemoteDesktopManagerWindows.slnx}" -p:SkipResxSorter=true \
  -p:DefaultAppHostRuntimeIdentifier=win-$(uname -m | sed 's/x86_64/x64/') -nologo -v:minimal -clp:Summary 2>&1
echo "BUILD EXIT CODE: $? after $(( $(date +%s) - start )) s"
