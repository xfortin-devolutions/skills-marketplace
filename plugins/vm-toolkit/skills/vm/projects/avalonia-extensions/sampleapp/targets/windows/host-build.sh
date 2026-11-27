# Builds avalonia-extensions on the Mac, in the worktree ($WORKTREE): the solution, or $PROJECT when guest.sh sets it. The
# projects are portable net10.0 (no RID), so the output carries every runtime's natives (Skia, HarfBuzz, ANGLE) and the
# ARM64 guest runs it with `dotnet <dll>` (launch.ps1, test.ps1); the Mac's app hosts are never used there.
# No dotnet or no worktree means the harness failed: stop without a BUILD EXIT CODE so the runner reports ERROR.
# --check: exit 0 when this Mac can build this worktree (a .NET 10 SDK); else say why (guest.sh then builds in the guest).
if [ "${1:-}" = --check ]; then
  v=$(cd "$WORKTREE" && dotnet --version 2> /dev/null) || { echo "no dotnet SDK on this Mac"; exit 1; }
  case "$v" in 10.*) exit 0 ;; *) echo "this Mac's dotnet SDK is $v, not 10.x"; exit 1 ;; esac
fi
command -v dotnet > /dev/null || { echo "no dotnet SDK on this Mac (brew install --cask dotnet-sdk)"; exit; }
cd "$WORKTREE" || exit
start=$(date +%s)
dotnet build "${PROJECT:-avalonia-extensions.sln}" -nologo -v:minimal -clp:Summary 2>&1
echo "BUILD EXIT CODE: $? after $(( $(date +%s) - start )) s"
