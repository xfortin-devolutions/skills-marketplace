# Builds avalonia-extensions in place on R: (the shared worktree): the solution, or $Project when the factory's guest.sh
# sets it. Used when the Mac can't build (host-build.sh --check, VM_HOST_BUILD=no).
# A running SampleApp or test assembly locks its bin\ files on the share, so they are stopped first.
Get-CimInstance Win32_Process -Filter "Name = 'dotnet.exe'" | Where-Object { $_.CommandLine -like '*R:\*' } |
    Invoke-CimMethod -MethodName Terminate | Out-Null
# No R: means the harness failed: stop without a BUILD EXIT CODE so the runner reports ERROR, not the change's FAIL.
Set-Location R:\ -ErrorAction Stop
$sw = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force C:\factory | Out-Null
$target = if ($Project) { $Project } else { 'avalonia-extensions.sln' }
dotnet build $target -nologo -v:minimal -clp:Summary 2>&1 | Tee-Object -FilePath C:\factory\build.log
"BUILD EXIT CODE: $LASTEXITCODE after $([int]$sw.Elapsed.TotalSeconds) s"
