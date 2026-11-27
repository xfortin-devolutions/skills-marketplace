# Runs one test project in place on R: (the shared worktree). Inputs, set by the factory's guest.sh: $Project (a .csproj),
# $Filter (no spaces: part of a test's full name, e.g. ComboBoxDropDownWidthTests or a FullyQualifiedName~ filter),
# $NoBuild.
# The projects are xUnit v3 executables, and `dotnet test` prints nothing in this guest: the test assembly runs itself
# (`dotnet <dll>`, which also works for a Mac build, whose app host is a Mac one), and its summary is printed again in
# `dotnet test`'s words ("Failed <name>", "Passed!/Failed! - Failed: f, Passed: p, Skipped: s"), which the runner reads.
# Avalonia's headless tests share one dispatcher: -parallel none.
Get-CimInstance Win32_Process -Filter "Name = 'dotnet.exe'" | Where-Object { $_.CommandLine -like '*R:\*' } |
    Invoke-CimMethod -MethodName Terminate | Out-Null
# No R: means the harness failed: stop without a TEST EXIT CODE so the runner reports ERROR, not the change's FAIL.
Set-Location R:\ -ErrorAction Stop
$sw = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force C:\factory | Out-Null
$proj = $Project -replace '/', '\'
if (-not $NoBuild) {
    dotnet build $proj -nologo -v:minimal 2>&1 | Tee-Object -FilePath C:\factory\test-build.log
    if ($LASTEXITCODE -ne 0) { "TEST EXIT CODE: $LASTEXITCODE after $([int]$sw.Elapsed.TotalSeconds) s (build)"; return }
}
$name = [IO.Path]::GetFileNameWithoutExtension($proj)
$dll = Get-ChildItem (Join-Path (Split-Path $proj) "bin\Debug\*\$name.dll") -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $dll) { "Failed! - not built: no bin\Debug\*\$name.dll"; "TEST EXIT CODE: 1"; return }
$runArgs = @($dll, '-parallel', 'none', '-noColor')
if ($Filter) { $runArgs += @('-method', "*$($Filter -replace '^FullyQualifiedName[~=]', '')*") }
Push-Location (Split-Path $dll)
$out = & dotnet @runArgs 2>&1 | ForEach-Object { "$_" }
$code = $LASTEXITCODE
Pop-Location
$out | Tee-Object -FilePath C:\factory\test.log
# xUnit v3 names a failure "<test> [FAIL]".
foreach ($l in $out) { if ($l -match '^\s*(\S.*?)\s+\[FAIL\]\s*$') { "  Failed $($Matches[1])" } }
$sum = $out | Where-Object { $_ -match 'Total: *(\d+), *Errors: *(\d+), *Failed: *(\d+), *Skipped: *(\d+)' } | Select-Object -Last 1
if ($sum -and ($sum -match 'Total: *(\d+), *Errors: *(\d+), *Failed: *(\d+), *Skipped: *(\d+)')) {
    $failed = [int]$Matches[2] + [int]$Matches[3]
    $passed = [int]$Matches[1] - [int]$Matches[3] - [int]$Matches[4]
    $verdict = if ($failed -gt 0 -or $code -ne 0) { 'Failed!' } else { 'Passed!' }
    "$verdict - Failed: $failed, Passed: $passed, Skipped: $($Matches[4]), Total: $($Matches[1])"
}
"TEST EXIT CODE: $code after $([int]$sw.Elapsed.TotalSeconds) s"
