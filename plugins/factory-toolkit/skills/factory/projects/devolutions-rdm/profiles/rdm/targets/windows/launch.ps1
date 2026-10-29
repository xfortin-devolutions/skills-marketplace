# Starts the Debug build on R: in the signed-in desktop session. SSH runs in session 0 (no desktop),
# so an Interactive scheduled task launches it as rdmtest instead.
$exe = 'R:\RDM\Windows\RemoteDesktopManager\Program\bin\Debug\net10.0-windows10.0.19041\RemoteDesktopManager.exe'
if (-not (Test-Path $exe)) {
    throw "Not built yet: $exe"
}
Get-Process RemoteDesktopManager -ErrorAction SilentlyContinue | Stop-Process -Force
$action = New-ScheduledTaskAction -Execute $exe -Argument '/NoSplashScreen' -WorkingDirectory (Split-Path $exe)
$principal = New-ScheduledTaskPrincipal -UserId rdmtest -LogonType Interactive
Register-ScheduledTask -TaskName VmRun -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName VmRun
Start-Sleep 3
# 0x41301 = running (good); 0x80070005 = access denied (usually the share's execute permission)
$result = (Get-ScheduledTaskInfo VmRun).LastTaskResult
'task result: 0x{0:X}' -f $result
if ($result -eq 0x41301) { 'LAUNCH OK' }
