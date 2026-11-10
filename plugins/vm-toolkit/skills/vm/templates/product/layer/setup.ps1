# Fills the @PRODUCT@ layer. Runs in the guest, elevated, in the signed-in desktop session (vmt layer starts it as
# a scheduled task). Every step is skipped when its result is already there, so a failed run can be started again.
# The log is C:\factory\layer\setup.log; its last line must be "LAYER SETUP OK" or "LAYER SETUP FAILED: <why>".
# Generated credentials go to C:\factory\secrets\ (administrators only), never to the log.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Root = 'C:\factory\layer'
$Log = "$Root\setup.log"

function Say($m) {
    # vmt layer reads the log while this writes it: retry on the sharing violation instead of failing the setup.
    $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $m
    for ($i = 0; $i -lt 20; $i++) { try { [IO.File]::AppendAllText($Log, $line + "`r`n"); break } catch { Start-Sleep -Milliseconds 250 } }
    Write-Host $line
}
# Step <name> <is it done?> <do it>: skipped when done; fails when doing it didn't make it done.
function Step($name, [scriptblock]$done, [scriptblock]$do) {
    if (& $done) { Say "skip  $name (already done)"; return }
    Say "start $name"
    & $do
    if (-not (& $done)) { throw "$name did not take effect" }
    Say "done  $name"
}

try {
    Step 'TODO: first step' { $false } { throw 'TODO' }
    Say 'LAYER SETUP OK'
} catch {
    Say "LAYER SETUP FAILED: $($_.Exception.Message)"
    exit 1
}
