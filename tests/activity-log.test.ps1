# Tests for the Stop hook (.claude/hooks/on-stop.ps1) and the log builder (tools/build-activity-log.ps1).
# Each case runs in a throwaway directory with a bare repo as "origin" and a working clone.
# Output: one line per check, "✅ name" or "❌ name - detail", then "TOTAL n FAILED m". Exit code 0 = all passed.
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$utf8 = New-Object Text.UTF8Encoding($false)
$repo = Split-Path -Parent $PSScriptRoot
$base = Join-Path ([IO.Path]::GetTempPath()) ('activity-log-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $base | Out-Null
$env:GIT_TERMINAL_PROMPT = '0'
$results = @()
$logName = 'יומן-פעולות'

function Check([string]$name, [bool]$ok, [string]$detail = '') {
  $script:results += [pscustomobject]@{ name = $name; ok = $ok }
  if ($ok) { Write-Output "✅ $name" } else { Write-Output "❌ $name - $detail" }
}
function G([string]$dir) { $o = & git -C $dir -c core.quotepath=false @args 2>&1; $script:gx = $LASTEXITCODE; ($o | Out-String).Trim() }

# New environment: bare origin + working clone with the two scripts, main pushed with upstream.
function New-Env([string]$id) {
  $d = Join-Path $base $id
  $bare = Join-Path $d 'origin.git'; $work = Join-Path $d 'work'
  New-Item -ItemType Directory -Force $bare, $work | Out-Null
  $null = G $bare init -q --bare -b main
  $null = G $work init -q -b main
  $null = G $work config user.email 't@example.com'
  $null = G $work config user.name 'Tester'
  $null = G $work config commit.gpgsign false
  $null = G $work remote add origin $bare
  foreach ($p in @('.claude\hooks\on-stop.ps1', 'tools\build-activity-log.ps1')) {
    $dest = Join-Path $work $p
    New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
    Copy-Item (Join-Path $repo $p) $dest
  }
  New-Item -ItemType Directory -Force (Join-Path $work "$logName\רשומות") | Out-Null
  [IO.File]::WriteAllText((Join-Path $work "$logName\רשומות\.gitkeep"), '', $utf8)
  $null = G $work add -A
  $null = G $work commit -q -m init
  $null = G $work push -q -u origin main
  [pscustomobject]@{ bare = $bare; work = $work }
}
# Writes an entry file: $obj is serialized to JSON, or $raw is written as is.
function Add-Entry($e, [string]$name, $obj = $null, [string]$raw = '') {
  $f = Join-Path $e.work "$logName\רשומות\$name"
  $text = if ($raw) { $raw } else { $obj | ConvertTo-Json -Depth 5 }
  [IO.File]::WriteAllText($f, $text, $utf8)
  $f
}
function Write-File($e, [string]$rel, [string]$text) {
  $f = Join-Path $e.work $rel
  New-Item -ItemType Directory -Force (Split-Path -Parent $f) | Out-Null
  [IO.File]::WriteAllText($f, $text, $utf8)
}
function Run-Hook($e, [string]$stdin = '{}') {
  $env:ACTIVITY_LOG_ROOT = $e.work
  $out = $stdin | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $e.work '.claude\hooks\on-stop.ps1') 2>&1
  Remove-Item Env:\ACTIVITY_LOG_ROOT
  ($out | Out-String).Trim()
}
function Index-Of($e) { [IO.File]::ReadAllText((Join-Path $e.work "$logName\index.html"), $utf8) }

try {
  # (a) E2E on a feature branch
  $e = New-Env 'a'
  $null = G $e.work checkout -q -b feat-x
  $ef = Add-Entry $e '2026-10-28_10-00_e2e.json' ([ordered]@{ title = 'בדיקת E2E'; request = 'לבדוק'; done = @('א', 'ב') })
  Write-File $e 'apps-script/Code.gs' '// change'
  $out = Run-Hook $e
  $null = G $e.bare rev-parse --verify feat-x
  Check 'E2E: branch pushed to origin' ($gx -eq 0) $out
  Check 'E2E: working tree clean after the run' ((G $e.work status --porcelain) -eq '') (G $e.work status --porcelain)
  Check 'E2E: success message names the branch' ($out -match 'נשמר ונדחף' -and $out -match 'feat-x') $out
  $ent = [IO.File]::ReadAllText($ef, $utf8) | ConvertFrom-Json
  Check 'E2E: entry got done_at, branch and files' ($ent.done_at -and $ent.branch -eq 'feat-x' -and (@($ent.files) -contains 'apps-script/Code.gs')) ($ent | ConvertTo-Json)
  Check 'E2E: index.html shows the title' ((Index-Of $e).Contains('בדיקת E2E'))
  $msg = G $e.work log -1 --format=%B
  Check 'E2E: commit message has the title and co-author line' ($msg -match 'בדיקת E2E' -and $msg -match 'Co-Authored-By: Claude Opus 5.5') $msg

  # (b) no changes: silent, nothing committed
  $e = New-Env 'b'
  $head = G $e.work rev-parse HEAD
  $out = Run-Hook $e
  Check 'No changes: no output' ($out -eq '') $out
  Check 'No changes: nothing committed' ((G $e.work rev-parse HEAD) -eq $head)

  # (c) main: only the log is committed
  $e = New-Env 'c'
  $null = Add-Entry $e '2026-10-28_10-01_main.json' ([ordered]@{ title = 'ב-main' })
  Write-File $e 'apps-script/Code.gs' '// code on main'
  $out = Run-Hook $e
  $files = G $e.work show --name-only --format= HEAD
  Check 'main: only the log is in the commit' ($files -match $logName -and $files -notmatch 'apps-script') $files
  Check 'main: code change is still uncommitted' ((G $e.work status --porcelain) -match 'apps-script')
  Check 'main: warning about code on main' ($out -match 'main') $out

  # (d) secret in a file: nothing committed
  $e = New-Env 'd'
  $null = G $e.work checkout -q -b feat-d
  $head = G $e.work rev-parse HEAD
  $secret = 'ghp_' + ('a' * 30)
  Write-File $e 'notes.txt' "token $secret"
  $out = Run-Hook $e
  Check 'Secret: nothing committed' ((G $e.work rev-parse HEAD) -eq $head)
  Check 'Secret: warning names the file, not the secret' ($out -match 'notes\.txt' -and -not $out.Contains($secret)) $out
  Check 'Secret: nothing left staged' ((G $e.work diff --cached --name-only) -eq '')
  $null = G $e.bare rev-parse --verify feat-d
  Check 'Secret: nothing pushed' ($gx -ne 0)

  # (e) markup in a title is escaped
  $e = New-Env 'e'
  $null = G $e.work checkout -q -b feat-e
  $null = Add-Entry $e '2026-10-28_10-02_xss.json' ([ordered]@{ title = '<script>alert(1)</script>'; request = '<img src=x onerror=alert(2)>'; done = @('<b>x</b>') })
  $null = Run-Hook $e
  $html = Index-Of $e
  Check 'XSS: no raw script or img tag in index.html' (-not $html.Contains('<script>alert') -and -not $html.Contains('<img src=x'))
  Check 'XSS: escaped text is present' ($html.Contains('&lt;script&gt;alert(1)&lt;/script&gt;'))

  # (f) invalid and empty JSON entries
  $e = New-Env 'f'
  $null = G $e.work checkout -q -b feat-f
  $null = Add-Entry $e '2026-10-28_10-03_broken.json' -raw '{ not json'
  $null = Add-Entry $e '2026-10-28_10-04_empty.json' -raw '{}'
  Write-File $e 'a.txt' 'x'
  $out = Run-Hook $e
  $html = Index-Of $e
  Check 'Bad JSON: index still built with the corrupt-entry notes' ($html.Contains('רשומה פגומה: 2026-10-28_10-03_broken.json') -and $html.Contains('רשומה פגומה: 2026-10-28_10-04_empty.json')) $out
  Check 'Bad JSON: the hook still committed' ((G $e.work status --porcelain) -eq '')

  # (g) very long field
  $e = New-Env 'g'
  $null = G $e.work checkout -q -b feat-g
  $null = Add-Entry $e '2026-10-28_10-05_long.json' ([ordered]@{ title = 'ארוך'; request = ('x' * 20000); done = @(1..300 | ForEach-Object { "item$_" }) })
  $null = Run-Hook $e
  $html = Index-Of $e
  Check 'Long field: truncated to 4000 characters' ($html.Contains('x' * 4000) -and -not $html.Contains('x' * 4001))

  # (h) push failure, then recovery
  $e = New-Env 'h'
  $null = G $e.work checkout -q -b feat-h
  $null = G $e.work remote set-url origin (Join-Path $base 'does-not-exist.git')
  $null = Add-Entry $e '2026-10-28_10-06_push.json' ([ordered]@{ title = 'דחיפה נכשלת' })
  Write-File $e 'b.txt' 'y'
  $out = Run-Hook $e
  Check 'Push failure: commit is kept' ((G $e.work log -1 --format=%s) -match 'דחיפה נכשלת') (G $e.work log -1 --format=%s)
  Check 'Push failure: warning says it will be pushed next time' ($out -match 'תידחף') $out
  $null = G $e.work remote set-url origin $e.bare
  $out = Run-Hook $e
  $null = G $e.bare rev-parse --verify feat-h
  Check 'Push recovery: a clean-tree run pushes the pending commit' ($gx -eq 0) $out

  # (i) stop_hook_active
  $e = New-Env 'i'
  $null = G $e.work checkout -q -b feat-i
  $head = G $e.work rev-parse HEAD
  Write-File $e 'c.txt' 'z'
  $out = Run-Hook $e '{"stop_hook_active": true}'
  Check 'stop_hook_active: no-op' ($out -eq '' -and (G $e.work rev-parse HEAD) -eq $head) $out
} finally {
  Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue
}
$failed = @($results | Where-Object { -not $_.ok }).Count
Write-Output "TOTAL $($results.Count) FAILED $failed"
if ($failed) { exit 1 } else { exit 0 }
