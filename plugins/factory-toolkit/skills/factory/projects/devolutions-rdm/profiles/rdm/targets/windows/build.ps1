# Builds the Windows solution in place on R: (the shared worktree), or $Project when the factory's guest.sh sets it.
# A running RDM locks its bin\ files on the share, so it is stopped first.
# SkipResxSorter: the pre-build ResxSorter step would rewrite .resx files in the worktree.
Get-Process RemoteDesktopManager -ErrorAction SilentlyContinue | Stop-Process -Force
# No R: means the harness failed: stop without a BUILD EXIT CODE so the runner reports ERROR, not the change's FAIL.
Set-Location R:\ -ErrorAction Stop
$sw = [Diagnostics.Stopwatch]::StartNew()
# Tee: the output streams back over SSH and a copy stays on the guest's disk (C:\factory\build.log) if the session drops.
New-Item -ItemType Directory -Force C:\factory | Out-Null
$target = if ($Project) { $Project } else { 'RemoteDesktopManagerWindows.slnx' }
dotnet build $target -p:SkipResxSorter=true -nologo -v:minimal -clp:Summary 2>&1 | Tee-Object -FilePath C:\factory\build.log
"BUILD EXIT CODE: $LASTEXITCODE after $([int]$sw.Elapsed.TotalSeconds) s"
