# Builds the Devolutions Console (Avalonia) in place on R: (the shared worktree), from the Windows solution filter, or
# $Project when the factory's guest.sh sets it.
# A running Console locks its bin\ files on the share, so it is stopped first.
Get-Process Devolutions.Console.Windows -ErrorAction SilentlyContinue | Stop-Process -Force
# No R: means the harness failed: stop without a BUILD EXIT CODE so the runner reports ERROR, not the change's FAIL.
Set-Location R:\ -ErrorAction Stop
$sw = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force C:\factory | Out-Null
$target = if ($Project) { $Project } else { 'Console\Console.Windows.slnf' }
dotnet build $target -nologo -v:minimal -clp:Summary 2>&1 | Tee-Object -FilePath C:\factory\build.log
"BUILD EXIT CODE: $LASTEXITCODE after $([int]$sw.Elapsed.TotalSeconds) s"
