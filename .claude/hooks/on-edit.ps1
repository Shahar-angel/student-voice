# PostToolUse hook (Write|Edit) for this project.
#  - any file                      -> snapshot of the whole project in backups/ (tools/backup.ps1)
#  - a guide in docs/ changed      -> rebuild the docs index in README.md and log the change in docs/שינויים.md
#  - config/deployment.json, apps-script/Code.gs or tools/build-links.ps1 -> rebuild קישורים.html (tools/build-links.ps1)
#  - apps-script/Code.gs, apps-script/Index.html, apps-script-sender/*, tests  -> run the test suite, log the result, and hand the result back to Claude
# Reads the hook payload (JSON) from stdin. Prints hook JSON on stdout. Never blocks the edit itself.
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.Encoding]::UTF8
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$utf8 = New-Object Text.UTF8Encoding($false)
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

try { $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { exit 0 }
$path = $payload.tool_input.file_path
if (-not $path) { $path = $payload.tool_response.filePath }
if (-not $path) { exit 0 }
$full = [IO.Path]::GetFullPath($path)
if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { exit 0 }
$rel = ($full.Substring($root.Length).TrimStart('\', '/')) -replace '\\', '/'

# --- every change: snapshot the project into backups/ (tools/backup.ps1 skips it when nothing changed) ---
if ($rel -notmatch '^backups/') {
  try { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\backup.ps1') 2>&1 | Out-Null } catch { }
}

$changelog = Join-Path $root 'docs\שינויים.md'
$readme    = Join-Path $root 'README.md'
$testsFile = Join-Path $root 'tests\last-results.md'

function Add-Log([string]$line) {
  if (-not (Test-Path $changelog)) { return }
  $t = [IO.File]::ReadAllText($changelog, $utf8).TrimEnd()
  [IO.File]::WriteAllText($changelog, $t + "`n- $(Get-Date -Format 'yyyy-MM-dd HH:mm') · $line`n", $utf8)
}

function Update-Index {
  if (-not (Test-Path $readme)) { return }
  $lines = @()
  foreach ($d in (Get-ChildItem (Join-Path $root 'docs') -Filter *.md | Sort-Object Name)) {
    $title = Get-Content $d.FullName -Encoding UTF8 -TotalCount 5 | Where-Object { $_ -match '^# ' } | Select-Object -First 1
    $title = if ($title) { $title -replace '^#\s*', '' } else { $d.BaseName }
    $lines += "- [$title](docs/$($d.Name)) · עודכן $($d.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))"
  }
  if (Test-Path $testsFile) {
    $status = Get-Content $testsFile -Encoding UTF8 | Where-Object { $_ -match '^הורץ:' } | Select-Object -First 1
    if ($status) { $lines += ''; $lines += "**בדיקות אחרונות:** $status ([פירוט](tests/last-results.md))" }
  }
  $t = [IO.File]::ReadAllText($readme, $utf8)
  $block = "<!-- docs-index:start -->`n" + ($lines -join "`n") + "`n<!-- docs-index:end -->"
  $new = [regex]::Replace($t, '(?s)<!-- docs-index:start -->.*?<!-- docs-index:end -->', { param($m) $block })
  if ($new -ne $t) { [IO.File]::WriteAllText($readme, $new, $utf8) }
}

function Out-Hook($obj) { $obj | ConvertTo-Json -Compress -Depth 5 }

# --- a guide changed ---
if ($rel -match '^docs/.+\.md$') {
  if ($rel -ne 'docs/שינויים.md') { Add-Log "עודכן מסמך: $rel" }
  Update-Index
  Out-Hook @{ systemMessage = "אינדקס המסמכים ויומן השינויים עודכנו ($rel)"; suppressOutput = $true }
  exit 0
}
if ($rel -eq 'README.md' -or $rel -eq 'CLAUDE.md' -or $rel -eq 'קישורים.html') { exit 0 }

# --- links source changed: rebuild קישורים.html (and README links) ---
$linksMsg = ''
if ($rel -match '^(config/deployment\.json|apps-script/Code\.gs|tools/build-links\.ps1)$') {
  $ErrorActionPreference = 'Continue'
  $linksMsg = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\build-links.ps1') 2>&1 | Out-String).Trim()
  Add-Log "קישורים.html נבנה מחדש אחרי שינוי ב-$rel"
  if ($rel -ne 'apps-script/Code.gs') {
    Out-Hook @{ systemMessage = $linksMsg; suppressOutput = $true; hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = "Links page rebuilt: $linksMsg. If appUrl or a course changed, tell the user the new links." } }
    exit 0
  }
}

# --- code or tests changed: run the suite ---
if ($rel -match '^apps-script/(Code\.gs|Index\.html)$' -or $rel -match '^apps-script-sender/' -or ($rel -match '^tests/' -and $rel -notmatch '^tests/(\.generated/|last-results\.md)')) {
  $runner = Join-Path $root 'tests\run-tests.ps1'
  $ErrorActionPreference = 'Continue'
  # The slow PowerShell groups run only when their own scripts change; CI and deploy-google.ps1 always run everything.
  $quick = if ($rel -match '^tests/.*\.ps1$') { @() } else { @('-Quick') }
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $runner @quick 2>&1 | Out-String
  $code = $LASTEXITCODE
  $summary = ($out -split "`n" | Where-Object { $_ -match '^הורץ:' } | Select-Object -First 1)
  if (-not $summary) { $summary = 'הבדיקות לא הסתיימו' }
  $failures = ($out -split "`n" | Where-Object { $_ -match '❌' }) -join "`n"
  Add-Log "שונה $rel · בדיקות: $($summary.Trim())"
  Update-Index
  $verdict = if ($code -eq 0) { 'All tests passed.' } else { "TESTS FAILED:`n$failures`n$($out.Substring(0, [Math]::Min(1500, $out.Length)))" }
  $context = "Test run after editing ${rel}: $($summary.Trim()) (exit $code). $verdict`n" +
    $(if ($linksMsg) { "Links page: $linksMsg`n" } else { '' }) +
    "Reminders: report the actual results to the user; run the security review (injection, prompt injection, input validation, secrets in code); " +
    "update the matching guide in docs/ if behavior, limits, links or setup changed; the live app changes only after redeploying (docs/01-התקנה-ופריסה.md)."
  Out-Hook @{
    systemMessage = $(if ($code -eq 0) { "בדיקות: $($summary.Trim())" } else { "⚠️ בדיקות נכשלו: $($summary.Trim())" })
    hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $context }
  }
  exit 0
}
exit 0
