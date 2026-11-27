# Starts the SampleApp's Debug build on R: in the signed-in desktop session (SSH runs in session 0, which has no
# desktop), as an Interactive scheduled task. It runs as `dotnet SampleApp.dll` from its bin folder: a Mac build has no
# Windows exe, and the app reads its theme from App.axaml relative to that folder (.claude/CLAUDE.md, "Running the
# Sample App").
$dll = Get-ChildItem 'R:\samples\SampleApp\bin\Debug\*\SampleApp.dll' -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $dll) { throw 'Not built yet: no R:\samples\SampleApp\bin\Debug\*\SampleApp.dll' }
Get-CimInstance Win32_Process -Filter "Name = 'dotnet.exe'" | Where-Object { $_.CommandLine -like '*SampleApp.dll*' } |
    Invoke-CimMethod -MethodName Terminate | Out-Null
$dotnet = (Get-Command dotnet -ErrorAction Stop).Source
$action = New-ScheduledTaskAction -Execute $dotnet -Argument "`"$dll`"" -WorkingDirectory (Split-Path $dll)
$principal = New-ScheduledTaskPrincipal -UserId rdmtest -LogonType Interactive
Register-ScheduledTask -TaskName VmRun -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName VmRun
Start-Sleep 3
# 0x41301 = running (good); 0x80070005 = access denied (usually the share's execute permission)
$result = (Get-ScheduledTaskInfo VmRun).LastTaskResult
'task result: 0x{0:X}' -f $result
if ($result -eq 0x41301) { 'LAUNCH OK' }
