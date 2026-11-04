# apply.ps1: breaks the console connection string of the IIS instance /dvls, for tickets about an unparseable one
# (DEVEX-516). Runs in the QA VM over SSH as the desktop user, before the app starts; $Dir is this fixture's guest folder.
# Idempotent: the original string is saved once, so a second apply never saves the broken value as the original.
$ErrorActionPreference = 'Stop'
$malformed = 'Data Source=HOST\SQLEXPRESS;Initial Catalog'

Import-Module WebAdministration
$app = Get-WebApplication -Site 'Default Web Site' -Name 'dvls'
if (-not $app) { throw 'No IIS application Default Web Site/dvls: is this the devolutions-console layer?' }
$file = Join-Path ([Environment]::ExpandEnvironmentVariables($app.PhysicalPath)) 'appsettings.json'
if (-not (Test-Path $file)) { throw "No $file" }

# Only the LocalSqlServer value changes, so the rest of the file stays byte for byte.
$text = [IO.File]::ReadAllText($file)
$pattern = '("LocalSqlServer"\s*:\s*")((?:[^"\\]|\\.)*)(")'
$match = [regex]::Match($text, $pattern)
if (-not $match.Success) { throw "$file has no clear-text ConnectionStrings.LocalSqlServer (encrypted configuration?)" }
$current = ConvertFrom-Json ('"' + $match.Groups[2].Value + '"')

$saved = Join-Path $Dir 'original.txt'
if (-not (Test-Path $saved)) {
    if ($current -eq $malformed) { throw "$file is already broken and no original was saved" }
    [IO.File]::WriteAllText($saved, $current)
}
$original = [IO.File]::ReadAllText($saved)

if ($current -ne $malformed) {
    $escaped = (ConvertTo-Json $malformed).Trim('"')
    $text = $text.Substring(0, $match.Groups[2].Index) + $escaped + $text.Substring($match.Groups[2].Index + $match.Groups[2].Length)
    [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding($false)))
}

# The values QA re-enters in the connection editor, one per line, where it can open them from the desktop.
$builder = New-Object Data.Common.DbConnectionStringBuilder
$builder.ConnectionString = $original
$lines = foreach ($key in $builder.Keys) { "${key}: $($builder[$key])" }
$desktop = [Environment]::GetFolderPath('Desktop')
[IO.File]::WriteAllLines((Join-Path $desktop 'dvls original connection.txt'), [string[]]$lines)
"fixture malformed-console-connection: /dvls console connection string broken in $file"
