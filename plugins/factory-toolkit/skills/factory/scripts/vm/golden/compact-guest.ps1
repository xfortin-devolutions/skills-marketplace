# Frees what a Windows golden image does not need, before compact.sh trims and compresses it. Sent with vmssh -.
# Keeps the NuGet packages folder: without it every QA build downloads the whole package graph again.
$before = (Get-PSDrive C).Free
"== component store"
DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase /English | Select-String 'completed|Error'
"== Windows Update and Delivery Optimization downloads, temp files, crash dumps"
Delete-DeliveryOptimizationCache -Force
Remove-Item C:\Windows\SoftwareDistribution\Download\*, $env:TEMP\*, C:\Windows\Temp\*, C:\Windows\LiveKernelReports\*.dmp `
    -Recurse -Force -ErrorAction SilentlyContinue
"== NuGet HTTP cache"
if (Get-Command dotnet -ErrorAction SilentlyContinue) { dotnet nuget locals http-cache --clear }
"== no hibernation file, page file fixed at 2 GB (applies at the next boot)"
powercfg /h off
# Set-CimInstance on Win32_PageFileSetting fails with "Value out of range"; the registry value is what Windows reads.
$mm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
Set-ItemProperty $mm -Name PagingFiles -Type MultiString -Value 'C:\pagefile.sys 2048 2048'
Set-CimInstance -InputObject (Get-CimInstance Win32_ComputerSystem) -Property @{AutomaticManagedPagefile = $false}
"Freed {0:N1} GB" -f (((Get-PSDrive C).Free - $before) / 1GB)
