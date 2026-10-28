# Guest setup run once from seed.iso at first logon (autounattend.xml, FirstLogonCommands order 7), elevated, as rdmtest.
# Automates steps 3 and 4 of the original rdm-windows-vm-test README.
$ProgressPreference = 'SilentlyContinue'
$seed = (Get-PSDrive -PSProvider FileSystem | Where-Object { Test-Path (Join-Path $_.Root 'setup-guest.ps1') } | Select-Object -First 1).Root

# Allow PowerShell scripts (the Windows 11 client default is Restricted)
Set-ExecutionPolicy Bypass -Scope LocalMachine -Force

# .NET 10 SDK, arm64, machine-wide (curl.exe: plain curl is an Invoke-WebRequest alias in 5.1)
curl.exe -fsSL -o "$env:TEMP\dotnet-sdk.exe" https://aka.ms/dotnet/10.0/dotnet-sdk-win-arm64.exe
Start-Process "$env:TEMP\dotnet-sdk.exe" '/install /quiet /norestart' -Wait

# QEMU's Samba share allows guest logins only; Windows 11 blocks those and requires signing by default
Set-SmbClientConfiguration -EnableInsecureGuestLogons $true -RequireSecuritySignature $false -Force
New-Item HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation -Force | Out-Null
Set-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation AllowInsecureGuestAuth 1 -Type DWord

# Share in the Local Intranet zone: no security prompt for RDM or .ps1 files launched from it
$r = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Ranges\Range1'
New-Item $r -Force | Out-Null
Set-ItemProperty $r ':Range' '10.0.2.4'
Set-ItemProperty $r 'file' 1 -Type DWord

# Elevated and non-elevated processes see the same mapped drives
Set-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System EnableLinkedConnections 1 -Type DWord

# Defender skips the share (build speed)
Add-MpPreference -ExclusionPath 'R:\', '\\10.0.2.4\qemu'

# NuGet config with the Artifactory credentials (Windows reads %APPDATA%\NuGet, not .nuget\NuGet)
New-Item -ItemType Directory -Force "$env:APPDATA\NuGet" | Out-Null
if ($seed -and (Test-Path (Join-Path $seed 'NuGet.Config'))) {
    Copy-Item (Join-Path $seed 'NuGet.Config') "$env:APPDATA\NuGet\NuGet.Config" -Force
}

# Map R: at every logon: the share only exists once a factory VM boots, so a persistent mapping can't be made here
$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c net use R: \\10.0.2.4\qemu /persistent:no'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User rdmtest
$principal = New-ScheduledTaskPrincipal -UserId rdmtest -LogonType Interactive
Register-ScheduledTask -TaskName MapShare -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
