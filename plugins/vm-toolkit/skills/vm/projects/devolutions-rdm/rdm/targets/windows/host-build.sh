# Builds the Windows solution on the Mac, in the worktree ($WORKTREE), or $PROJECT when guest.sh sets it: the same
# output build.ps1 leaves (RDM/Windows/Common.Windows.props cross-compiles from a non-Windows host: EnableWindowsTargeting,
# the win-<host arch> RID, so an ARM64 guest runs it). Checked 2026-11-17: the whole solution, 0 errors, ~3 min; the
# Mac-built RDM runs in the guest and its tests run there with --no-build.
# DefaultAppHostRuntimeIdentifier: a plain net10.0 test project would get a macOS app host, and xUnit v3 starts a test
# assembly through its .exe in the guest. SkipResxSorter: the pre-build ResxSorter step would rewrite .resx files.
# RdmTrimDebugOutput=false: RDM's Directory.Build.targets keeps only the build machine's runtimes/ natives in a portable
# Debug project (plain net10.0, no RID), so a Mac build ships osx natives where the guest needs win-arm64 ones
# (Theme.Business.Tests: "Unable to load DLL 'libHarfBuzzSharp'"); off, the project keeps them all.
# No dotnet or no worktree means the harness failed: stop without a BUILD EXIT CODE so the runner reports ERROR.
# --check: exit 0 when this Mac can build this worktree; else say why (guest.sh then builds it in the guest). A Mac build
# needs the repo's cross-compile fix (RDM #22751, 2026-11-17: native files of NuGet packages; older commits ship without
# RDP, VNC, the terminal and PowerShell) and a .NET 10 SDK (RDM has no global.json, and its Windows projects treat
# warnings as errors: another major's new warnings would fail the build).
if [ "${1:-}" = --check ]; then
  grep -q RdmAddWindowsHostOnlyPackageNatives "$WORKTREE/RDM/Windows/Common.Windows.props" 2> /dev/null \
    || { echo "this commit predates RDM's cross-compile fix (RDM #22751)"; exit 1; }
  v=$(cd "$WORKTREE" && dotnet --version 2> /dev/null) || { echo "no dotnet SDK on this Mac"; exit 1; }
  case "$v" in 10.*) exit 0 ;; *) echo "this Mac's dotnet SDK is $v, not 10.x"; exit 1 ;; esac
fi
command -v dotnet > /dev/null || { echo "no dotnet SDK on this Mac (brew install --cask dotnet-sdk)"; exit; }
cd "$WORKTREE" || exit
start=$(date +%s)
dotnet build "${PROJECT:-RemoteDesktopManagerWindows.slnx}" -p:SkipResxSorter=true -p:RdmTrimDebugOutput=false \
  -p:DefaultAppHostRuntimeIdentifier=win-$(uname -m | sed 's/x86_64/x64/') -nologo -v:minimal -clp:Summary 2>&1
echo "BUILD EXIT CODE: $? after $(( $(date +%s) - start )) s"
