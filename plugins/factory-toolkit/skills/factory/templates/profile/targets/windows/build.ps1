# Builds what ships in place on R: (the shared worktree), or $Project when the factory's guest.sh sets it.
# TODO: stop the running app first: it locks its bin\ files on the share.
Get-Process 'TODO-process-name' -ErrorAction SilentlyContinue | Stop-Process -Force
# No R: means the harness failed: stop without a BUILD EXIT CODE so the runner reports ERROR, not the change's FAIL.
Set-Location R:\ -ErrorAction Stop
$sw = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force C:\factory | Out-Null
$target = if ($Project) { $Project } else { 'TODO: the solution or solution filter that ships' }
dotnet build $target -nologo -v:minimal -clp:Summary 2>&1 | Tee-Object -FilePath C:\factory\build.log
"BUILD EXIT CODE: $LASTEXITCODE after $([int]$sw.Elapsed.TotalSeconds) s"
