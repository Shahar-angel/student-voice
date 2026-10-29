# Runs every test (server, E2E, edge cases, security) against the real Code.gs and Index.html.
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
# Exit code 0 = all passed, 1 = a test or the static security scan failed.
# -Quick skips the slow PowerShell groups (activity log, Google sync); the edit hook uses it. CI and deploy-google.ps1 run everything.
param([switch]$Quick)
$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $PSScriptRoot
$app   = Join-Path $root 'apps-script'   # exactly the files that live in the Google project
$tests = $PSScriptRoot
$gen   = Join-Path $tests '.generated'   # temporary; removed at the end of every run
$utf8  = New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force $gen | Out-Null

# 1. Feed the real source files to the test page.
$code  = [IO.File]::ReadAllText((Join-Path $app 'Code.gs'), $utf8)
$index = [IO.File]::ReadAllText((Join-Path $app 'Index.html'), $utf8)
[IO.File]::WriteAllText((Join-Path $gen 'code.js'), $code, $utf8)
[IO.File]::WriteAllText((Join-Path $gen 'index-html.js'), 'window.INDEX_HTML = ' + ($index | ConvertTo-Json -Compress) + ';', $utf8)
# The personal sender (a separate Google project): its source is run by MOCK.makeSender in tests/gas-mock.js.
$senderDir = Join-Path $root 'apps-script-sender'
$sender = [IO.File]::ReadAllText((Join-Path $senderDir 'Code.gs'), $utf8)
[IO.File]::WriteAllText((Join-Path $gen 'sender.js'), 'window.SENDER_SOURCE = ' + ($sender | ConvertTo-Json -Compress) + ';', $utf8)

# 2. Static security scan of the shipped files.
$static = @()
foreach ($f in @((Join-Path $app 'Code.gs'), (Join-Path $app 'Index.html'), (Join-Path $senderDir 'Code.gs'))) {
  $text = [IO.File]::ReadAllText($f, $utf8)
  $n = (Split-Path -Leaf (Split-Path -Parent $f)) + '/' + (Split-Path -Leaf $f)
  $static += [pscustomobject]@{ name = "$n - no API key in the code"; ok = -not ($text -match 'sk-ant-[A-Za-z0-9_\-]{10,}') }
  $static += [pscustomobject]@{ name = "$n - no eval or new Function"; ok = -not ($text -match '\beval\s*\(|new Function\s*\(') }
}
# The sender must reach only the app's own address, and never call another service.
$static += [pscustomobject]@{ name = 'apps-script-sender/Code.gs - talks only to the app (one fetch, to MAIN_URL)'; ok = (([regex]::Matches($sender, 'UrlFetchApp\.fetch\(')).Count -eq 1 -and $sender -match 'UrlFetchApp\.fetch\(MAIN_URL,') }
$mainUrl = ([IO.File]::ReadAllText((Join-Path $root 'config\deployment.json'), $utf8) | ConvertFrom-Json).appUrl
$static += [pscustomobject]@{ name = 'apps-script-sender/Code.gs - MAIN_URL is the deployed app (config/deployment.json)'; ok = $sender.Contains("const MAIN_URL = '$mainUrl';") }
# innerHTML may only receive fixed markup: string literals joined with "+" are fine, a variable is not.
$dynamicHtml = Select-String -Path (Join-Path $app 'Index.html') -Pattern '\.innerHTML\s*=.*\+\s*[^\s''"]' | Where-Object { $_.Line -notmatch "^\s*//" }
$static += [pscustomobject]@{ name = 'Index.html - innerHTML only with fixed markup'; ok = (@($dynamicHtml).Count -eq 0) }

# 3. Run the browser tests headless.
$browser = @(
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { Write-Output 'No Edge or Chrome found to run the tests.'; exit 1 }
$profileDir = Join-Path $gen 'profile'
$url = 'file:///' + ((Join-Path $tests 'run.html') -replace '\\', '/')
$ErrorActionPreference = 'Continue' # the browser logs harmless warnings to stderr
$dom = & $browser --headless=new --disable-gpu --no-first-run --allow-file-access-from-files "--user-data-dir=$profileDir" --virtual-time-budget=600000 --dump-dom $url 2>$null | Out-String
Remove-Item -Recurse -Force $gen -ErrorAction SilentlyContinue  # browser profile + copies, ~15MB

$match = [regex]::Match($dom, '<pre id="results"[^>]*data-done="1"[^>]*>([\s\S]*?)</pre>')
if (-not $match.Success) { $match = [regex]::Match($dom, '<pre id="results" data-done="1">([\s\S]*?)</pre>') }
if (-not $match.Success) { Write-Output 'The test page did not finish. Output:'; Write-Output ($dom.Substring(0, [Math]::Min(2000, $dom.Length))); exit 1 }
$json = [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
$results = $json | ConvertFrom-Json

# 4. Report.
$failed = @($results | Where-Object { -not $_.ok }) + @($static | Where-Object { -not $_.ok })
$lines = @()
$lines += '# תוצאות הבדיקות האחרונות'
$lines += ''
$lines += "הורץ: $(Get-Date -Format 'yyyy-MM-dd HH:mm')  ·  עברו: $(@($results | Where-Object ok).Count + @($static | Where-Object ok).Count)  ·  נכשלו: $($failed.Count)"
$lines += ''
foreach ($g in ($results | Group-Object group)) {
  $lines += "## $($g.Name) ($(@($g.Group | Where-Object ok).Count)/$($g.Count))"
  foreach ($r in $g.Group) { $lines += $(if ($r.ok) { "- ✅ $($r.name)" } else { "- ❌ $($r.name) — $($r.error)" }) }
  $lines += ''
}
$lines += "## סריקה סטטית ($(@($static | Where-Object ok).Count)/$($static.Count))"
foreach ($s in $static) { $lines += $(if ($s.ok) { "- ✅ $($s.name)" } else { "- ❌ $($s.name)" }) }
if (@($dynamicHtml).Count) { $dynamicHtml | ForEach-Object { $lines += "  - Index.html:$($_.LineNumber)" } }
# 5. Activity log: the Stop hook and its builder (tests/activity-log.test.ps1, runs against throwaway git repos).
[Console]::OutputEncoding = $utf8
$alRaw = if ($Quick) { @() } else { (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tests 'activity-log.test.ps1') 2>&1 | Out-String) -split "`r?`n" }
$al = @($alRaw | Where-Object { $_ -match '^(✅|❌) ' })
$alOk = @($al | Where-Object { $_ -like '✅*' }).Count
$alFail = @($al | Where-Object { $_ -like '❌*' }).Count
if (-not $al.Count -and -not $Quick) { $alFail = 1; $al = @('❌ activity-log.test.ps1 produced no results') }
$lines += ''
$lines += "## יומן פעולות ($alOk/$($al.Count))"
foreach ($a in $al) { $lines += "- $a" }
# 6. Google sync: tools/deploy-google.ps1 with a fake clasp, and the hook's deploy trigger (tests/google-sync.test.ps1).
$gsRaw = if ($Quick) { @() } else { (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tests 'google-sync.test.ps1') 2>&1 | Out-String) -split "`r?`n" }
$gs = @($gsRaw | Where-Object { $_ -match '^(✅|❌) ' })
$gsOk = @($gs | Where-Object { $_ -like '✅*' }).Count
$gsFail = @($gs | Where-Object { $_ -like '❌*' }).Count
if (-not $gs.Count -and -not $Quick) { $gsFail = 1; $gs = @('❌ google-sync.test.ps1 produced no results') }
$lines += ''
$lines += "## סנכרון Google ($gsOk/$($gs.Count))"
foreach ($a in $gs) { $lines += "- $a" }
$totalOk = @($results | Where-Object ok).Count + @($static | Where-Object ok).Count + $alOk + $gsOk
$lines[2] = "הורץ: $(Get-Date -Format 'yyyy-MM-dd HH:mm')  ·  עברו: $totalOk  ·  נכשלו: $($failed.Count + $alFail + $gsFail)" + $(if ($Quick) { '  ·  מצב מהיר (בלי יומן פעולות וסנכרון Google)' } else { '' })
$report = $lines -join "`n"
[IO.File]::WriteAllText((Join-Path $tests 'last-results.md'), $report + "`n", $utf8)
Write-Output $report
if ($failed.Count -or $alFail -or $gsFail) { exit 1 } else { exit 0 }
