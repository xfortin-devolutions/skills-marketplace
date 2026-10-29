# Fills the devolutions-console layer: what the Console needs on the machine, from the 2026-10-23 dry run (../layer.md).
# Runs in the guest, elevated, in the signed-in desktop session (factory.sh layer starts it as a scheduled task: the PostgreSQL
# installer fails from an SSH session). Every step is skipped when its result is already there, so a failed run can be
# started again. Output goes to C:\factory\layer\setup.log; the last line is "LAYER SETUP OK" or "LAYER SETUP FAILED: …".
# Credentials are generated here and kept in C:\factory\secrets\ (administrators only); none is ever written to the log.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Root = 'C:\factory\layer'
$Secrets = 'C:\factory\secrets'
$Log = "$Root\setup.log"
$ConsoleDir = 'C:\Program Files\Devolutions\Devolutions Server Console'
$Cli = "$ConsoleDir\DPS.Console.CLI.exe"
$Host_ = $env:COMPUTERNAME.ToLower()

function Say($m) {
    # factory.sh layer reads the log while this writes it: retry on the sharing violation instead of failing the setup.
    $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $m
    for ($i = 0; $i -lt 20; $i++) { try { [IO.File]::AppendAllText($Log, $line + "`r`n"); break } catch { Start-Sleep -Milliseconds 250 } }
    Write-Host $line
}
function Step($name, [scriptblock]$done, [scriptblock]$do) {
    if (& $done) { Say "skip  $name (already done)"; return }
    Say "start $name"
    & $do
    if (-not (& $done)) { throw "$name did not take effect" }
    Say "done  $name"
}
function Fetch($url, $file) {
    $path = "$Root\$file"
    if (-not (Test-Path $path)) { Invoke-WebRequest $url -OutFile $path -UseBasicParsing }
    $path
}
function Run($exe, [string[]]$arguments, [int[]]$ok = @(0, 3010)) {
    $p = Start-Process $exe -ArgumentList $arguments -Wait -PassThru
    if ($ok -notcontains $p.ExitCode) { throw "$(Split-Path $exe -Leaf) exited $($p.ExitCode)" }
}
function NewSecret { -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ }) }
function Secret($name) {
    $f = "$Secrets\$name.txt"
    if (-not (Test-Path $f)) { Set-Content $f (NewSecret) }
    (Get-Content $f -Raw).Trim()
}
function X64Framework($name) { Test-Path "C:\Program Files\dotnet\x64\shared\$name\10.*" }
function Invoke-ConsoleCli([string[]]$Arguments, [string]$What, [string]$CliExe = $Cli) {
    # The CLI ignores unknown switches silently, and answers 0 on some failures: the caller checks the site afterwards.
    $out = "$Root\cli-$What.log"
    # Not -Wait: it also waits for the processes the CLI starts, and basic-install leaves Edge open on the new site.
    $p = Start-Process $CliExe -ArgumentList $Arguments -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    $p.WaitForExit()
    Say "      CLI $What exit $($p.ExitCode) (full output: $out)"
}
function SiteUp($path) {
    $code = curl.exe -k -s -o NUL -w '%{http_code}' --max-time 120 "https://localhost$path/"
    $code -eq '200'
}
function AppExists($path) {
    # Whether the instance exists, not whether it answers yet: after a reboot a site can take minutes to answer, and
    # reinstalling over an existing instance fails ("Encryption keys file must have a value ...").
    Import-Module WebAdministration
    [bool](Get-WebApplication -Site 'Default Web Site' -Name $path.TrimStart('/'))
}
function WaitSite($path) {
    # First start runs the database migrations behind a 503 "Maintenance Mode" page for about a minute.
    for ($i = 0; $i -lt 30 -and -not (SiteUp $path); $i++) { Start-Sleep 10 }
}

try {
    New-Item -ItemType Directory -Force $Root, $Secrets | Out-Null
    icacls $Secrets /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' | Out-Null
    Say "layer setup on $Host_"

    Step 'pause Windows Update, Store and Edge updates' {
        (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue).NoAutoUpdate -eq 1 -and
        (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -ErrorAction SilentlyContinue).AutoDownload -eq 2 -and
        (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' -ErrorAction SilentlyContinue).UpdateDefault -eq 0
    } {
        $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        New-Item $au -Force | Out-Null
        Set-ItemProperty $au -Name NoAutoUpdate -Value 1 -Type DWord
        New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Force | Out-Null
        Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name AutoDownload -Value 2 -Type DWord
        New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' -Force | Out-Null
        Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' -Name UpdateDefault -Value 0 -Type DWord
        Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' -Name DODownloadMode -Value 0 -Type DWord -ErrorAction SilentlyContinue
    }

    # The Console and DVLS are published x64: on ARM64 Windows they need the x64 runtimes, which the ARM64 SDK lacks.
    Step 'x64 .NET 10 Desktop Runtime' { X64Framework 'Microsoft.WindowsDesktop.App' } {
        Run (Fetch 'https://aka.ms/dotnet/10.0/windowsdesktop-runtime-win-x64.exe' 'windowsdesktop-runtime-x64.exe') '/install', '/quiet', '/norestart'
    }
    # Without it DVLS answers 500.31 and its Scheduler service doesn't start; the Hosting Bundle only brings ARM64.
    Step 'x64 ASP.NET Core 10 runtime' { X64Framework 'Microsoft.AspNetCore.App' } {
        Run (Fetch 'https://aka.ms/dotnet/10.0/aspnetcore-runtime-win-x64.exe' 'aspnetcore-runtime-x64.exe') '/install', '/quiet', '/norestart'
    }

    Step 'Devolutions Server Console' { Test-Path $Cli } {
        $setup = Get-ChildItem $Root -Filter 'Setup.DVLS.Console*.exe' | Select-Object -First 1
        if (-not $setup) { throw "no Setup.DVLS.Console*.exe in $Root (factory.sh layer copies it from <VM home>/installers)" }
        Run $setup.FullName '/exenoui', '/qn'
    }

    # The CLI never runs these: only the Console UI's IIS diagnostics does.
    Step 'IIS features, URL Rewrite, ARR (DVLS-Prerequisites.ps1)' {
        (Get-WindowsOptionalFeature -Online -FeatureName IIS-WebSockets).State -eq 'Enabled' -and (Test-Path "$env:windir\System32\inetsrv\rewrite.dll")
    } {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ConsoleDir\Scripts\DVLS-Prerequisites.ps1" *>> "$Root\prerequisites.log"
    }
    Step 'ASP.NET Core Hosting Bundle / ANCM (DVLS-InstallANCM.ps1)' { Test-Path "$env:ProgramFiles\IIS\Asp.Net Core Module\V2\aspnetcorev2.dll" } {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ConsoleDir\Scripts\DVLS-InstallANCM.ps1" *>> "$Root\ancm.log"
    }

    # x64 only (no Windows ARM64 build from EDB or winget); runs emulated.
    Step 'PostgreSQL 18' { Get-Service postgresql-x64-18 -ErrorAction SilentlyContinue } {
        $pg = Fetch 'https://sbp.enterprisedb.com/getfile.jsp?fileid=1260607' 'postgresql-18-windows-x64.exe'
        if ((Get-AuthenticodeSignature $pg).SignerCertificate.Subject -notmatch 'EnterpriseDB') { throw 'PostgreSQL installer is not signed by EnterpriseDB' }
        Run $pg '--mode', 'unattended', '--unattendedmodeui', 'none', '--superpassword', (Secret 'postgres-superuser'), '--serverport', '5432', '--disable-components', 'stackbuilder'
    }

    # basic-install installs SQL Server Express itself (sa password in its passwords file on this user's Desktop) and
    # creates the admin dvls-admin / dvls-admin; it ignores the database host and credential switches.
    Step 'DVLS /dvls on SQL Server Express (basic-install)' { AppExists '/dvls' } {
        Invoke-ConsoleCli -Arguments @('server', 'basic-install', '--accept-eula') -What 'dvls-sqlserver'
        WaitSite '/dvls'
        if (-not (SiteUp '/dvls')) { throw '/dvls does not answer 200' }
    }

    $admin = @('--admin-username=dvls-admin', '--admin-password=dvls-admin', '--admin-email=dvls-admin@factory.local')
    $common = @('server', 'install', '--accept-eula', '--quiet', '--disable-password', ('--backup-keys-password=' + (Secret 'dvls-backup-keys')))
    # Each 'switch=' + value is parenthesized: in an array literal the comma binds tighter than +.
$pgDb = @('--database-type=PostgreSql', '--database-host=localhost', '--database-port=5432', '--database-username=postgres',
        ('--database-password=' + (Secret 'postgres-superuser')))

    Step 'DVLS /dvls-pg on PostgreSQL' { AppExists '/dvls-pg' } {
        Invoke-ConsoleCli -What 'dvls-pg' -Arguments ($common + $admin + $pgDb + @('--dps-path=C:\inetpub\wwwroot\dvls-pg', '--web-application-name=/dvls-pg', '--app-pool-name=dvls-pg',
            '--database-name=dvls_pg', "--access-uri=https://$Host_/dvls-pg", '--create-recovery-kit-path=C:\factory\recovery\dvls-pg'))
        WaitSite '/dvls-pg'
        if (-not (SiteUp '/dvls-pg')) { throw '/dvls-pg does not answer 200' }
    }

    # The database must be outside any user profile: the app pool identity can't open one (500.30 in the dry run).
    Step 'DVLS /dvls-sqlite on SQLite' { AppExists '/dvls-sqlite' } {
        New-Item -ItemType Directory -Force 'C:\ProgramData\Devolutions\DVLS\sqlite' | Out-Null
        # Console 2026.3.11 doesn't grant the app pool (or the Scheduler's LocalService) write access to the database
        # folder (the source does since 2026-09-29): without it, 'attempt to write a readonly database' at first start.
        icacls 'C:\ProgramData\Devolutions\DVLS\sqlite' /grant 'IIS_IUSRS:(OI)(CI)M' '*S-1-5-19:(OI)(CI)M' | Out-Null
        Invoke-ConsoleCli -What 'dvls-sqlite' -Arguments ($common + $admin + @('--dps-path=C:\inetpub\wwwroot\dvls-sqlite', '--web-application-name=/dvls-sqlite', '--app-pool-name=dvls-sqlite',
            '--database-type=Sqlite', '--database-file=C:\ProgramData\Devolutions\DVLS\sqlite\dvls.db', "--access-uri=https://$Host_/dvls-sqlite",
            '--create-recovery-kit-path=C:\factory\recovery\dvls-sqlite'))
        WaitSite '/dvls-sqlite'
        if (-not (SiteUp '/dvls-sqlite')) { throw '/dvls-sqlite does not answer 200' }
    }

    # Released CLIs can't install Kestrel: KestrelInstallCommand doesn't register the Kestrel options (DEVEX-552), so
    # the listener stays null ("Value cannot be null (Parameter 'uriString')"). factory.sh layer copies a CLI built from the
    # fix to $PatchedCli when one is given; without it, the Kestrel instance is installed by hand from the Console UI.
    # Its own .exe (win-x64), not 'dotnet <dll>': the CLI finds Scripts\ next to the running program.
    $PatchedCli = "$Root\cli-patched\DPS.Console.CLI.exe"
    $kestrelUp = { (curl.exe -k -s -o NUL -w '%{http_code}' --max-time 60 https://localhost:5000/) -eq '200' }
    if (Get-Service 'Devolutions_Server_Kestrel*' -ErrorAction SilentlyContinue) { Say 'skip  DVLS on Kestrel (already installed)' }
    elseif (-not (Test-Path $PatchedCli)) { Say 'MANUAL DVLS on Kestrel: install it from the Console UI (the released CLI cannot, DEVEX-552)' }
    else {
        # SQLite: on PostgreSQL the source-built CLI's database check timed out ("Invalid credentials for database
        # connection") although psql connected in 0.4 s with the same login; not investigated further.
        Step 'DVLS on Kestrel (SQLite, CLI built from the DEVEX-552 fix)' $kestrelUp {
            Copy-Item "$ConsoleDir\Scripts" "$Root\cli-patched" -Recurse -Force
            New-Item -ItemType Directory -Force 'C:\ProgramData\Devolutions\DVLS\kestrel' | Out-Null
            icacls 'C:\ProgramData\Devolutions\DVLS\kestrel' /grant '*S-1-5-19:(OI)(CI)M' | Out-Null
            Invoke-ConsoleCli -What 'dvls-kestrel' -CliExe $PatchedCli -Arguments ($common + $admin + @('--instance-type=Kestrel',
                '--database-type=Sqlite', '--database-file=C:\ProgramData\Devolutions\DVLS\kestrel\dvls.db',
                '--dps-path=C:\DVLS\kestrel', '--kestrel-http-listener-uri=https://localhost:5000',
                '--access-uri=https://localhost:5000', '--generate-self-signed-certificate', '--store-certificate-subject=localhost',
                '--store-certificate-location=LocalMachine', '--store-certificate-store=My',
                '--create-recovery-kit-path=C:\factory\recovery\dvls-kestrel'))
            # The Kestrel service's watchdog (Worker.cs) gives DVLS 10 s to answer, then stops the service; under emulation
            # the first start (migrations) takes ~5 min. Run that first start directly, then let the service take over.
            Stop-Service 'Devolutions_Server_Kestrel*' -ErrorAction SilentlyContinue
            $first = Start-Process 'C:\DVLS\kestrel\Devolutions.Server.exe' -WorkingDirectory 'C:\DVLS\kestrel' -PassThru -WindowStyle Hidden
            for ($i = 0; $i -lt 90 -and -not (& $kestrelUp); $i++) { Start-Sleep 10 }
            Stop-Process -Id $first.Id -Force -ErrorAction SilentlyContinue
            Start-Service (Get-Service 'Devolutions_Server_Kestrel*').Name
            for ($i = 0; $i -lt 18 -and -not (& $kestrelUp); $i++) { Start-Sleep 10 }
        }
    }

    # At boot a Scheduler service can start before SQL Server Express is up and crash (SqlException) for good.
    Step 'Scheduler services on Automatic (Delayed Start)' {
        -not (Get-CimInstance Win32_Service -Filter "Name LIKE 'DevolutionsScheduler%'" | Where-Object { -not $_.DelayedAutoStart })
    } {
        Get-Service 'DevolutionsScheduler*' | ForEach-Object { sc.exe config $_.Name start= delayed-auto | Out-Null }
    }

    # SQL Express installs as delayed-auto too: it then races the /dvls Scheduler, which crashes when SQL isn't up yet.
    Step 'SQL Express on Automatic, the /dvls Scheduler depending on it' {
        $sql = Get-CimInstance Win32_Service -Filter "Name = 'MSSQL`$SQLEXPRESS'"
        $deps = @((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\DevolutionsSchedulerServicedvls').DependOnService)
        -not $sql.DelayedAutoStart -and $deps -contains 'MSSQL$SQLEXPRESS'
    } {
        sc.exe config 'MSSQL$SQLEXPRESS' start= auto | Out-Null
        $deps = @((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\DevolutionsSchedulerServicedvls').DependOnService) | Where-Object { $_ }
        sc.exe config DevolutionsSchedulerServicedvls depend= ((@($deps) + 'MSSQL$SQLEXPRESS' | Select-Object -Unique) -join '/') | Out-Null
    }

    Say 'LAYER SETUP OK'
} catch {
    Say "LAYER SETUP FAILED: $($_.Exception.Message)"
    exit 1
}
