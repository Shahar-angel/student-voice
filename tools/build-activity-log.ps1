# Rebuilds יומן-פעולות/index.html from every entry in יומן-פעולות/רשומות/*.json (newest first).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-activity-log.ps1 [-Root <repo root>]
# Every value is HTML-encoded, so entry text can never become markup. Broken JSON files are listed, never fatal.
param([string]$Root = '')
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$logDir = Join-Path $Root 'יומן-פעולות'
$entriesDir = Join-Path $logDir 'רשומות'
$repoUrl = 'https://github.com/Shahar-angel/student-voice'
$maxField = 4000
$maxFiles = 200

function Enc([object]$v) {
  $s = if ($null -eq $v) { '' } else { [string]$v }
  if ($s.Length -gt $maxField) { $s = $s.Substring(0, $maxField) + '…' }
  [Net.WebUtility]::HtmlEncode($s)
}
function ListOf($v) { if ($null -eq $v) { @() } else { @($v) } }
function Section([string]$title, [string]$body) { if ($body) { "<section><h3>$title</h3>$body</section>" } else { '' } }
function Ul($items, [int]$limit = 0) {
  $items = @(ListOf $items | Where-Object { $null -ne $_ -and "$_" -ne '' })
  if (-not $items.Count) { return '' }
  $extra = 0
  if ($limit -and $items.Count -gt $limit) { $extra = $items.Count - $limit; $items = $items[0..($limit - 1)] }
  $html = '<ul>' + (($items | ForEach-Object { '<li>' + (Enc $_) + '</li>' }) -join '') + '</ul>'
  if ($extra) { $html += '<p class="muted">ועוד ' + $extra + ' קבצים…</p>' }
  $html
}
function Para([object]$v) { if ($null -eq $v -or "$v" -eq '') { '' } else { '<p>' + (Enc $v) + '</p>' } }

$cards = @()
$files = @()
if (Test-Path $entriesDir) { $files = @(Get-ChildItem $entriesDir -Filter *.json -File | Sort-Object Name -Descending) }
foreach ($f in $files) {
  $e = $null
  try { $e = [IO.File]::ReadAllText($f.FullName, $utf8) | ConvertFrom-Json } catch { $e = $null }
  if ($null -eq $e -or $e -isnot [pscustomobject] -or -not $e.title) {
    $cards += '<article class="bad">רשומה פגומה: ' + (Enc $f.Name) + '</article>'
    continue
  }
  $meta = @()
  if ($e.time) { $meta += '<span>' + (Enc $e.time) + '</span>' }
  if ($e.branch) {
    $b = [string]$e.branch
    $meta += '<a href="' + $repoUrl + '/commits/' + [Uri]::EscapeDataString($b).Replace('%2F', '/') + '">ענף: ' + (Enc $b) + '</a>'
  }
  $body = (Section 'מה ביקשו' (Para $e.request)) +
    (Section 'מה נעשה' (Ul $e.done)) +
    (Section 'החלטות' (Ul $e.decisions)) +
    (Section 'בדיקות' ((Para $e.tests) + (Para $e.testSummary))) +
    (Section 'מה נשאר' (Ul $e.open))
  $fl = ListOf $e.files
  if ($fl.Count) { $body += '<details><summary>קבצים ששונו (' + $fl.Count + ')</summary>' + (Ul $fl $maxFiles) + '</details>' }
  $cards += '<article><h2>' + (Enc $e.title) + '</h2><p class="meta">' + ($meta -join ' · ') + '</p>' + $body + '</article>'
}
if (-not $cards.Count) { $cards = @('<p class="muted">אין עדיין רשומות.</p>') }

$page = @"
<!doctype html>
<html lang="he" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>יומן פעולות - קול הסטודנטים</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--text:#1d2330;--muted:#667085;--line:#e1e5ec;--accent:#2457c5;--bad:#b42318}
@media (prefers-color-scheme:dark){:root{--bg:#12151c;--card:#1b2029;--text:#e6e9ef;--muted:#9aa4b5;--line:#2c3340;--accent:#7aa2ff;--bad:#ff8a80}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:16px/1.6 system-ui,'Segoe UI',Arial,sans-serif}
main{max-width:820px;margin:0 auto;padding:24px 16px 48px}
h1{font-size:1.6rem;margin:0 0 4px}
article{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 18px;margin:16px 0;overflow-wrap:anywhere}
article.bad{color:var(--bad);border-color:var(--bad)}
h2{font-size:1.2rem;margin:0}
h3{font-size:.95rem;color:var(--muted);margin:14px 0 2px}
p{margin:4px 0}ul{margin:4px 0;padding-inline-start:22px}
.meta,.muted{color:var(--muted);font-size:.9rem}
a{color:var(--accent)}
details{margin-top:12px}summary{cursor:pointer;color:var(--muted)}
</style>
</head>
<body>
<main>
<h1>יומן פעולות</h1>
<p class="muted">זיכרון משני של הפרויקט. נוצר אוטומטית מהקבצים ב-<code>יומן-פעולות/רשומות</code>, לא לערוך ידנית. החדש למעלה.</p>
$($cards -join "`n")
</main>
</body>
</html>
"@
New-Item -ItemType Directory -Force $logDir | Out-Null
[IO.File]::WriteAllText((Join-Path $logDir 'index.html'), $page, $utf8)
