# check.ps1 (rename from check.ps1.example to use it): runs in each QA VM before the app starts, with $Dir set to this
# resource's folder there. Throw when the resource can't be used, with a line that says why: the run then pauses for
# a human instead of sending the change back. Print nothing secret.
$ErrorActionPreference = 'Stop'
# Example: the server answers on its port.
if (-not (Test-NetConnection -ComputerName 'lab-dvls.example.local' -Port 443 -InformationLevel Quiet)) {
    throw 'lab-dvls.example.local:443 does not answer from the VM (VPN on the Mac?)'
}
