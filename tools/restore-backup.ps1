# Restores the project to a snapshot from backups/. Saves the current state first, so a restore can be undone.
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\restore-backup.ps1 -Name 2026-10-27_10-00-00_קבוע.zip
#         (without -Name: lists the snapshots)
# The live app changes only after the restored apps-script files are deployed again (docs/01-התקנה-ופריסה.md).
param([string]$Name = '')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$root = Split-Path -Parent $PSScriptRoot
$dir  = Join-Path $root 'backups'
if (-not $Name) { Get-ChildItem $dir -Filter *.zip | Sort-Object Name -Descending | ForEach-Object { $_.Name }; exit 0 }
$zipPath = Join-Path $dir (Split-Path -Leaf $Name)
if (-not (Test-Path $zipPath)) { Write-Output "לא נמצא גיבוי בשם $Name"; exit 1 }

& (Join-Path $PSScriptRoot 'backup.ps1') -Label "לפני שחזור של $Name" -Keep | Out-Null

# Replace every project file (except backups/) with the snapshot's files.
Get-ChildItem $root -Force | Where-Object { $_.Name -ne 'backups' } | Remove-Item -Recurse -Force
$zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
  foreach ($e in $zip.Entries) {
    if (-not $e.Name) { continue }
    $target = [IO.Path]::GetFullPath((Join-Path $root $e.FullName))
    if (-not $target.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }  # never write outside the project
    New-Item -ItemType Directory -Force (Split-Path -Parent $target) | Out-Null
    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
  }
} finally { $zip.Dispose() }
Write-Output "הפרויקט שוחזר לגרסה $Name. הגרסה שהייתה לפני השחזור נשמרה גם היא בתיקייה backups."
