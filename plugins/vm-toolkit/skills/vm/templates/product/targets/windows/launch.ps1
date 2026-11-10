# Starts the build verify made, from R:, in the signed-in desktop session. SSH runs in session 0 (no desktop), so an
# Interactive scheduled task launches it as rdmtest instead.
$exe = Get-ChildItem 'R:\TODO\bin\Debug' -Recurse -Filter 'TODO.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (-not $exe) {
    throw 'Not built yet: no TODO.exe under R:\TODO\bin\Debug'
}
Get-Process 'TODO-process-name' -ErrorAction SilentlyContinue | Stop-Process -Force
$action = New-ScheduledTaskAction -Execute $exe -WorkingDirectory (Split-Path $exe)
$principal = New-ScheduledTaskPrincipal -UserId rdmtest -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName VmRun -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName VmRun
Start-Sleep 3
# 0x41301 = running (good); 0x80070005 = access denied (usually the share's execute permission)
$result = (Get-ScheduledTaskInfo VmRun).LastTaskResult
'task result: 0x{0:X}' -f $result
if ($result -eq 0x41301) { 'LAUNCH OK' }
