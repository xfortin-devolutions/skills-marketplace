# Runs one test project in place on R: (the shared worktree). Inputs, set by the factory's guest.sh: $Project, $Filter.
Get-Process 'TODO-process-name' -ErrorAction SilentlyContinue | Stop-Process -Force
# No R: means the harness failed: stop without a TEST EXIT CODE so the runner reports ERROR, not the change's FAIL.
Set-Location R:\ -ErrorAction Stop
$sw = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force C:\factory | Out-Null
$testArgs = @('test', $Project, '-nologo', '-v:minimal')
if ($Filter) { $testArgs += @('--filter', $Filter) }
dotnet @testArgs 2>&1 | Tee-Object -FilePath C:\factory\test.log
"TEST EXIT CODE: $LASTEXITCODE after $([int]$sw.Elapsed.TotalSeconds) s"
