# Starts the Debug build on R: in the signed-in desktop session (SSH runs in session 0, which has no desktop), as an
# Interactive scheduled task. On the ARM64 guest the project picks win-arm64 itself (Console.Windows.csproj).
# Console/Directory.Build.props puts the output under Console\artifacts (since 2026-10-26); older commits use bin\.
# The exe is Devolutions.Console.exe since RDM #20595 (2026-11); older commits build Devolutions.Console.Windows.exe.
$exe = Get-ChildItem 'R:\Console\artifacts\bin\Console.Windows\debug_win-arm64\Devolutions.Console.exe',
        'R:\Console\artifacts\bin\Console.Windows\debug_win-arm64\Devolutions.Console.Windows.exe',
        'R:\Console\Console.Windows\bin\Debug\*\win-arm64\Devolutions.Console.Windows.exe' -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $exe) {
    throw 'Not built yet: no Devolutions.Console.exe or Devolutions.Console.Windows.exe under R:\Console\artifacts\bin or R:\Console\Console.Windows\bin'
}
Get-Process Devolutions.Console, Devolutions.Console.Windows -ErrorAction SilentlyContinue | Stop-Process -Force
$action = New-ScheduledTaskAction -Execute $exe -WorkingDirectory (Split-Path $exe)
# Elevated like the existing Console: it manages IIS sites and Windows services.
$principal = New-ScheduledTaskPrincipal -UserId rdmtest -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName VmRun -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName VmRun
Start-Sleep 3
# 0x41301 = running (good); 0x80070005 = access denied (usually the share's execute permission)
$result = (Get-ScheduledTaskInfo VmRun).LastTaskResult
'task result: 0x{0:X}' -f $result
if ($result -eq 0x41301) { 'LAUNCH OK' }
