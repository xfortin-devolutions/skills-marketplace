# devolutions-console image layer

A qcow2 layer `devolutions-console.qcow2` on the frozen Windows `base.qcow2` (one golden image per guest OS; this layer
holds only what the Console needs). Built in a maintenance boot; every Console QA clone starts from it.
Status (2026-10-26): built and frozen (6.0 GB). Recipe: `layer/setup.ps1` (guest) with `layer/layer.conf`, run by
`factory.sh layer console --test | --build`. The frozen image got two hand-applied maintenance boots on 2026-10-26 (the
Scheduler delayed start, then SQL Express on Automatic with the `/dvls` Scheduler depending on it); both are in
`setup.ps1`, so a rebuild from scratch includes them. A single clean `--build` pass of the current recipe is unproven.
Kestrel installs through a CLI built from master (DEVEX-552, merged) until a Console release ships it.

## Scripted run: what it taught (2026-10-23)
- The Console CLI (`DPS.Console.CLI.exe`, elevated) does `/dvls` with `server basic-install`, and `/dvls-pg`,
  `/dvls-sqlite` with `server install` and explicit switches. It never runs `DVLS-Prerequisites.ps1`; the IIS install
  never runs `DVLS-InstallANCM.ps1` (the prerequisites script already installs ANCM).
- **Kestrel can't be installed from the CLI** (2026.3.11 and the source in this repo): `Validation/Port.cs` builds a Uri
  from `KestrelHttpListenerUri`, which has no switch in `KestrelInstallCommand.cs` and no default, so it fails with
  "Value cannot be null (Parameter 'uriString')". Manual step from the Console UI until the CLI gets a listener switch.
- SQLite: Console 2026.3.11 doesn't grant the app pool write access to the database folder (the source does since
  2026-09-29): "attempt to write a readonly database". `setup.ps1` grants `IIS_IUSRS` and LocalService Modify first.
- `basic-install` and `server install` open Edge on the new site at the end: a `Start-Process -Wait` on the CLI then
  never returns (it waits for child processes). Wait on the CLI process only.
- First start of an instance runs migrations behind a 503 "Maintenance Mode" page; under x64 emulation the first
  start of `/dvls` came several minutes after the CLI said completed.
- The CLI ignores unknown switches without an error: check the site, not the CLI's exit code.

End state of the dry run, all answering 200 over HTTPS, each with its Scheduler service running:

| Instance | Hosting | Database |
|---|---|---|
| `/dvls` | IIS | SQL Server Express (`SQLEXPRESS`) |
| `/dvls-1` | IIS | PostgreSQL 18 (`localhost:5432`) |
| `/dvls-sqlite-1` | IIS | SQLite (`.db` outside the user profile) |
| Kestrel | Windows service, `https://localhost:5000` | SQL Server Express |

## What the Console needs on the machine, in order

| Step | How (dry run) | Scripted form |
|---|---|---|
| Existing Devolutions Server Console 2026.3.11 (x64 only) | downloaded from devolutions.net | its installer, silent |
| x64 .NET 10 Windows Desktop Runtime | asked for by the Console on first start (the image has the ARM64 SDK only; an x64 app can't use it) | `windowsdesktop-runtime-10.0.x-win-x64.exe /install /quiet /norestart` |
| IIS features (18, incl. WebSockets, Windows Auth, static compression, manager) | Console: IIS diagnostics, Install prerequisites | `DVLS/Console/Console.UI/Scripts/DVLS-Prerequisites.ps1` |
| URL Rewrite 2 (7.2.1993), ARR 3.0 | same button; both installed fine on ARM64 | same script (MSIs via redirection.devolutions.com, `/q`) |
| ASP.NET Core 10.0.10 Hosting Bundle (ARM64 runtime + ANCM V2) | same button | `DVLS-InstallANCM.ps1` |
| **x64 ASP.NET Core 10 runtime** (not installed by the Console) | DVLS is published win-x64: without it the site gives 500.31 ("Microsoft.AspNetCore.App (x64) not found", ANCM `0x8000ffff`) and the Scheduler service fails to start. Added by hand after the basic install; then `iisreset` and `Start-Service DevolutionsSchedulerService<name>`. IIS in-process worked as is (no app-pool change) | `aspnetcore-runtime-10.0.x-win-x64.exe /install /quiet /norestart` (https://aka.ms/dotnet/10.0/aspnetcore-runtime-win-x64.exe), **before** the basic install |
| SQL Server Express 2022 (x64, runs emulated), instance `SQLEXPRESS` | Console: Basic installation (no SQL detected, installs it) | `DVLS-InstallSQLExpress.ps1` (`/Q`) |
| DVLS instance on SQL Server | Basic installation; self-signed certificate. Works: `https://localhost/dvls/` answers 200 after the first start (503 "Maintenance Mode" for ~1 min while its migrations run) | CLI `server basic-install` (`--AcceptEula`, database type/host/user/password, certificate, access URI) |
| PostgreSQL 18.6 (x64 only: no Windows ARM64 build from EDB or winget; runs emulated) | EDB installer (https://sbp.enterprisedb.com/getfile.jsp?fileid=1260607, 396 MB, signed by EnterpriseDB). Over SSH it exits 1 after 16 s (`Error writing file …\temp_check_comspec.bat`); run as an elevated Interactive scheduled task it works. Service `postgresql-x64-18`, port 5432 | `--mode unattended --unattendedmodeui none --superpassword <pw> --serverport 5432 --disable-components stackbuilder`, from the desktop session (`-LogonType Interactive -RunLevel Highest`); the superuser password is generated in the guest and kept in `Documents\Devolutions Server Console\postgresql_superuser.txt` |
| DVLS instance on PostgreSQL | Console install against `localhost:5432`, user `postgres`: works | CLI `server basic-install` with the PostgreSQL database type |
| DVLS instance on SQLite | First try: the `.db` landed in `C:\Users\rdmtest\Documents\Devolutions Server Console\` (the folder chosen for the passwords file); the app pool identity can't open the user profile: 500.30 (`UnauthorizedAccessException` in `SqliteDatabaseInstanceLock.Acquire`) and the Scheduler service fails | Put the `.db` outside any user profile (e.g. `C:\DVLSData\sqlite\`): reinstalled that way, works |
| DVLS instance on Kestrel | Console Kestrel install on SQL Server Express: works. Windows service `Devolutions_Server_Kestrel (<guid>)` + its own Scheduler service, HTTPS on `localhost:5000` (localhost only) | CLI Kestrel `install` | CLI `server basic-install` with the database type / `--DatabaseFile`; Kestrel `install` |

## Credentials
The basic install writes `dvls_<date>_passwords.txt` (SQL login, DVLS admin) to the user's
`Documents\Devolutions Server Console\`. Never copy it into the repo; the harness reads it in the guest when a ticket
needs it.

## Also to do in the layer
- Pause Windows Update: in a clone, Edge, WebView2 and Copilot updated themselves within minutes of boot (the factory-toolkit plugin's GAPS.md, V22).
- The old Console may be removed once the instances exist, if the Avalonia Console under test doesn't need it.
