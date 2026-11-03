# apply.ps1: runs in the QA VM over SSH, as the desktop user but in session 0 (no desktop), before the app starts, with
# $Dir set to this fixture's folder in the guest (its data files are there). Throw on failure. Idempotent: a VM may get
# it once per QA round.
$ErrorActionPreference = 'Stop'
# Example: copy a prepared settings file into the app's data folder.
# Copy-Item (Join-Path $Dir 'settings.cfg') (Join-Path $env:LOCALAPPDATA 'App\settings.cfg') -Force
