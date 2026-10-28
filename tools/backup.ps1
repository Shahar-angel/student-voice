# Saves a snapshot of the whole project as a zip in backups/, so any earlier version can be restored
# with tools/restore-backup.ps1. Called by the hook after every change; skips the snapshot when
# nothing changed since the last one.
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\backup.ps1 [-Label "שם"] [-Keep]
#   -Label  a short name shown in backups/גרסאות.md
#   -Keep   never delete this snapshot when old automatic ones are pruned
param([string]$Label = '', [switch]$Keep)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$utf8 = New-Object Text.UTF8Encoding($false)
$root = Split-Path -Parent $PSScriptRoot
$dir  = Join-Path $root 'backups'
$list = Join-Path $dir 'גרסאות.md'
$maxAuto = 150   # automatic snapshots kept; snapshots made with -Keep are never pruned
New-Item -ItemType Directory -Force $dir | Out-Null

# Files that make up the project: everything except backups/ and temporary test files.
$files = Get-ChildItem $root -Recurse -File -Force | Where-Object {
  $r = $_.FullName.Substring($root.Length + 1)
  $r -notmatch '^(backups|tests\\\.generated)(\\|$)'
} | Sort-Object FullName

# Fingerprint of names + contents, to skip a snapshot identical to the previous one.
$sha = [Security.Cryptography.SHA256]::Create()
$sb = New-Object Text.StringBuilder
foreach ($f in $files) {
  $h = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($f.FullName))) -replace '-', ''
  [void]$sb.Append($f.FullName.Substring($root.Length + 1)).Append('=').Append($h).Append("`n")
}
$print = ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($sb.ToString()))) -replace '-', '').Substring(0, 16)
$last = Join-Path $dir '.last'
if ((Test-Path $last) -and ([IO.File]::ReadAllText($last).Trim() -eq $print) -and -not $Label) { Write-Output 'ללא שינוי מאז הגיבוי האחרון'; exit 0 }

$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$name = $stamp + $(if ($Keep) { '_קבוע' } else { '' }) + '.zip'
$zipPath = Join-Path $dir $name
$zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
  foreach ($f in $files) {
    $entry = $f.FullName.Substring($root.Length + 1) -replace '\\', '/'
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $entry, 'Optimal')
  }
} finally { $zip.Dispose() }
[IO.File]::WriteAllText($last, $print, $utf8)

# Prune old automatic snapshots.
$auto = Get-ChildItem $dir -Filter *.zip | Where-Object { $_.Name -notmatch '_קבוע\.zip$' } | Sort-Object Name
if ($auto.Count -gt $maxAuto) { $auto | Select-Object -First ($auto.Count - $maxAuto) | Remove-Item -Force }

# Human-readable list, newest first.
if (-not (Test-Path $list)) {
  [IO.File]::WriteAllText($list, "# גרסאות שמורות של הפרויקט`n`nכל שורה היא גיבוי מלא של הפרויקט. לחזרה לגרסה: ``powershell -NoProfile -ExecutionPolicy Bypass -File tools\restore-backup.ps1 -Name <שם הקובץ>```n`n<!-- list -->`n", $utf8)
}
$t = [IO.File]::ReadAllText($list, $utf8)
$line = "- ``$name``" + $(if ($Label) { " · **$Label**" } else { '' })
$t = $t -replace '<!-- list -->\r?\n', "<!-- list -->`n$line`n"
# Drop lines of zips that were pruned.
$t = ($t -split "`n" | Where-Object { $_ -notmatch '^- `(.+?\.zip)`' -or (Test-Path (Join-Path $dir ([regex]::Match($_, '^- `(.+?\.zip)`').Groups[1].Value))) }) -join "`n"
[IO.File]::WriteAllText($list, $t, $utf8)
Write-Output "גיבוי נשמר: backups/$name"
