# Builds the Devolutions Console (Avalonia) on the Mac, in the worktree ($WORKTREE), from the Windows solution filter, or
# $PROJECT when guest.sh sets it: the same output build.ps1 leaves (Console.Windows.csproj picks win-<host arch> itself, so
# an ARM64 guest runs it). Checked 2026-11-17: 0 errors; the Mac-built Console runs in the guest and its tests run there
# with --no-build.
# EnableWindowsTargeting: the DVLS console projects (WinForms) don't set it, so a non-Windows SDK refuses them
# (NETSDK1073). DefaultAppHostRuntimeIdentifier: a plain net10.0 test project (Console.Shared.Tests) would get a macOS app
# host, and xUnit v3 starts a test assembly through its .exe in the guest ("Could not find app host executable").
# No dotnet or no worktree means the harness failed: stop without a BUILD EXIT CODE so the runner reports ERROR.
command -v dotnet > /dev/null || { echo "no dotnet SDK on this Mac (brew install --cask dotnet-sdk)"; exit; }
cd "$WORKTREE" || exit
start=$(date +%s)
dotnet build "${PROJECT:-Console/Console.Windows.slnf}" -p:EnableWindowsTargeting=true \
  -p:DefaultAppHostRuntimeIdentifier=win-$(uname -m | sed 's/x86_64/x64/') -nologo -v:minimal -clp:Summary 2>&1
echo "BUILD EXIT CODE: $? after $(( $(date +%s) - start )) s"
