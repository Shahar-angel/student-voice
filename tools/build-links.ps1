# Builds "קישורים.html" (the clickable links page) and the links section of README.md
# from config/deployment.json, using the exact permanent-link format that apps-script/Code.gs generates.
# Run by the project hook; can also be run by hand:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-links.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)
$cfg  = [IO.File]::ReadAllText((Join-Path $root 'config\deployment.json'), $utf8) | ConvertFrom-Json
$code = [IO.File]::ReadAllText((Join-Path $root 'apps-script\Code.gs'), $utf8)

# Take the permanent link format from the server code so the page can never drift from what the app shows.
# These links do not depend on any course: after sign-in, each person reaches their own course.
$s = [regex]::Match($code, "function studentHome_\(\) \{ return appUrl_\(\) \+ '([^']*)'; \}")
$t = [regex]::Match($code, "function staffHome_\(\) \{ return appUrl_\(\) \+ '([^']*)'; \}")
if (-not $s.Success -or -not $t.Success) { Write-Output 'build-links: could not read studentHome_/staffHome_ from Code.gs'; exit 1 }

function Enc([string]$x) { [System.Net.WebUtility]::HtmlEncode($x) }
$app = $cfg.appUrl
$stamp = Get-Date -Format 'dd.MM.yyyy HH:mm'

$stu = $app + $s.Groups[1].Value
$stf = $app + $t.Groups[1].Value

$html = @"
<!DOCTYPE html>
<html dir="rtl" lang="he">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>קול הסטודנטים · קישורים</title>
<!-- נוצר אוטומטית מ-config/deployment.json על ידי tools/build-links.ps1. לא לערוך ידנית. -->
<style>
  :root { --bg:#F3F4F8; --card:#fff; --fg:#151A29; --muted:#5A6278; --line:#DDE0EA; --accent:#4352D9; --band:#1C2160; }
  @media (prefers-color-scheme: dark) { :root { --bg:#0F1220; --card:#181C2E; --fg:#E8EAF4; --muted:#9CA3BD; --line:#2A3048; --accent:#8E9AFF; --band:#151A45; } }
  * { box-sizing: border-box; } body { margin:0; background:var(--bg); color:var(--fg); font-family: Assistant, "Segoe UI", Arial, sans-serif; font-size:17px; line-height:1.5; }
  header { background:var(--band); color:#EEF0FF; padding:28px 16px 22px; } header div, main { max-width:760px; margin:0 auto; }
  h1 { margin:0 0 6px; font-size:1.9rem; } header p { margin:0; color:#A9B0E6; }
  main { padding:24px 16px 48px; display:flex; flex-direction:column; gap:16px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:16px; display:flex; flex-direction:column; gap:12px; }
  h2 { margin:0; font-size:1.25rem; } h2 span { color:var(--muted); font-weight:400; font-size:.95rem; margin-inline-start:10px; }
  .link { display:grid; grid-template-columns: 1fr auto; gap:6px 12px; align-items:center; border-top:1px solid var(--line); padding-top:12px; }
  .link:first-of-type { border-top:0; padding-top:0; }
  .link b { display:block; } .link small { color:var(--muted); }
  .link input { grid-column: 1 / -1; direction:ltr; font-family: Consolas, monospace; font-size:.78rem; padding:6px 8px; border:1px solid var(--line); border-radius:8px; background:var(--bg); color:var(--fg); width:100%; }
  .btn { background:var(--accent); color:#fff; text-decoration:none; border-radius:10px; padding:8px 18px; font-weight:700; white-space:nowrap; }
  .note { color:var(--muted); font-size:.92rem; } .note b { color:var(--fg); }
</style>
</head>
<body>
<header><div><h1>קול הסטודנטים</h1><p>הקישורים למערכת · עודכן $stamp</p></div></header>
<main>
  <section class="card">
    <div class="link"><div><b>דף המנהל</b><small>כל הקורסים, יצירה ומחיקה, ניהול אנשי הנהלה. נכנסים עם $(Enc $cfg.googleAccount)</small></div><a class="btn" href="$(Enc $app)" target="_blank" rel="noopener">פתיחה</a><input readonly value="$(Enc $app)" aria-label="קישור למנהל" onclick="this.select()"></div>
    <div class="link"><div><b>קוד המערכת ב-Google (Apps Script)</b><small>העורך שבו נמצאים Code.gs ו-Index, הגדרות הפרויקט (מפתח Claude) והפריסות. בחשבון $(Enc $cfg.googleAccount)</small></div><a class="btn" href="$(Enc $cfg.scriptProject)" target="_blank" rel="noopener">פתיחה</a><input readonly value="$(Enc $cfg.scriptProject)" aria-label="קישור לעורך הקוד" onclick="this.select()"></div>
  </section>
  <section class="card">
    <div class="link"><div><b>דף הסטודנטים</b><small>אותו קישור לכל הקורסים. שולחים לסטודנטים; כל אחד מגיע לקורס שלו, או בוחר מרשימה אם יש לו כמה</small></div><a class="btn" href="$(Enc $stu)" target="_blank" rel="noopener">פתיחה</a><input readonly value="$(Enc $stu)" aria-label="קישור לסטודנטים" onclick="this.select()"></div>
    <div class="link"><div><b>דף הנהלת הקורס</b><small>אותו קישור לכל הקורסים. מי שאישרת מגיע ללוח של הקורס שלו; מי שלא אושר בוחר קורס ושולח בקשת הרשאה</small></div><a class="btn" href="$(Enc $stf)" target="_blank" rel="noopener">פתיחה</a><input readonly value="$(Enc $stf)" aria-label="קישור להנהלה" onclick="this.select()"></div>
  </section>
  <p class="note"><b>כדאי לפתוח בחלון גלישה בסתר</b> (Ctrl+Shift+N): כשהדפדפן מחובר לכמה חשבונות גוגל, גוגל מחזירה שגיאה. לסטודנטים זה לא נדרש.<br>
  הקישור עצמו לא נותן גישה: כל אחד נכנס עם המייל שלו, והתפקיד נקבע לפי המייל.</p>
</main>
</body>
</html>
"@
[IO.File]::WriteAllText((Join-Path $root 'קישורים.html'), $html, $utf8)

# Same links in README.md, between markers.
$md = @("- **דף המנהל:** $app", "- **דף הסטודנטים (לכל הקורסים):** $stu", "- **דף הנהלת הקורס (לכל הקורסים):** $stf", "- **קוד המערכת ב-Google (Apps Script):** $($cfg.scriptProject)")
$readme = Join-Path $root 'README.md'
$t = [IO.File]::ReadAllText($readme, $utf8)
$block = "<!-- links:start -->`n" + ($md -join "`n") + "`n<!-- links:end -->"
$new = [regex]::Replace($t, '(?s)<!-- links:start -->.*?<!-- links:end -->', { param($m) $block })
if ($new -ne $t) { [IO.File]::WriteAllText($readme, $new, $utf8) }
Write-Output "build-links: קישורים.html עודכן (קישורים קבועים)"
