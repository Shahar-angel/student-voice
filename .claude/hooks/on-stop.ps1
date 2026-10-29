# Stop hook for this project: at the end of every assistant turn, commit all changes and push the branch to GitHub.
#  - pending activity-log entries (יומן-פעולות/רשומות/*.json without done_at) get time/branch/files/testSummary/done_at, index.html is rebuilt
#  - a secret scan of what would be committed runs first; on a hit nothing is committed or pushed
#  - on main only יומן-פעולות/ is committed (code changes belong on a feature branch)
#  - if the push fails (offline, auth) the commit stays local and is pushed by the next run
# Never blocks Claude: always exit 0, reports through {"systemMessage": "..."} only when it did something or something went wrong.
# Root: -Root, else env ACTIVITY_LOG_ROOT, else two levels above this script.
param([string]$Root = '')
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$utf8 = New-Object Text.UTF8Encoding($false)
$env:GIT_TERMINAL_PROMPT = '0'

function Out-Msg([string]$m) { Write-Output (@{ systemMessage = $m } | ConvertTo-Json -Compress) }

try {
  $payload = $null
  if ([Console]::IsInputRedirected) {
    try { [Console]::InputEncoding = [Text.Encoding]::UTF8; $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { $payload = $null }
  }
  if ($payload -and $payload.stop_hook_active -eq $true) { exit 0 }

  if (-not $Root) { $Root = $env:ACTIVITY_LOG_ROOT }
  if (-not $Root) { $Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
  Set-Location $Root

  function GitC { $out = & git.exe -c core.quotepath=false -c i18n.commitEncoding=utf-8 @args 2>&1; $script:gitExit = $LASTEXITCODE; $out }

  $null = GitC rev-parse --is-inside-work-tree
  if ($gitExit -ne 0) { exit 0 }
  $branch = ((GitC rev-parse --abbrev-ref HEAD) | Out-String).Trim()
  if ($gitExit -ne 0 -or -not $branch -or $branch -eq 'HEAD') { exit 0 }

  $logName = 'יומן-פעולות'
  $status = @(GitC status --porcelain -uall | Where-Object { $_ -and "$_".Length -gt 3 })
  $null = GitC rev-parse --abbrev-ref '@{u}'
  $hasUpstream = ($gitExit -eq 0)
  $ahead = 0
  if ($hasUpstream) { $ahead = [int]((GitC rev-list --count '@{u}..HEAD') | Out-String).Trim() }
  $needPush = (-not $hasUpstream) -or ($ahead -gt 0)
  if ($status.Count -eq 0 -and -not $needPush) { exit 0 }

  $changed = @($status | ForEach-Object {
    $p = "$_".Substring(3)
    if ($p -match ' -> ') { $p = ($p -split ' -> ')[-1] }
    $p.Trim('"')
  })
  $codeChanged = @($changed | Where-Object { $_ -ne "$logName/" -and -not $_.StartsWith("$logName/") })

  # --- 2. pending entries ---
  $entriesDir = Join-Path $Root "$logName\רשומות"
  $builder = Join-Path $Root 'tools\build-activity-log.ps1'
  $titles = @()
  if (Test-Path $entriesDir) {
    $testSummary = $null
    $lr = Join-Path $Root 'tests\last-results.md'
    if (Test-Path $lr) { $testSummary = [IO.File]::ReadAllLines($lr, $utf8) | Where-Object { $_ -match 'עברו:' } | Select-Object -First 1 }
    foreach ($f in (Get-ChildItem $entriesDir -Filter *.json -File)) {
      try {
        $e = [IO.File]::ReadAllText($f.FullName, $utf8) | ConvertFrom-Json
        if ($e -isnot [pscustomobject] -or -not $e.title -or $e.done_at) { continue }
      } catch { continue }
      $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
      if (-not $e.time) { $e | Add-Member -NotePropertyName time -NotePropertyValue $now -Force }
      $e | Add-Member -NotePropertyName branch -NotePropertyValue $branch -Force
      $e | Add-Member -NotePropertyName files -NotePropertyValue @($codeChanged) -Force
      if ($testSummary) { $e | Add-Member -NotePropertyName testSummary -NotePropertyValue "$testSummary".TrimStart('-', ' ') -Force }
      $e | Add-Member -NotePropertyName done_at -NotePropertyValue $now -Force
      [IO.File]::WriteAllText($f.FullName, ($e | ConvertTo-Json -Depth 6), $utf8)
      $t = ("$($e.title)" -replace '\s+', ' ').Trim()
      if ($t.Length -gt 200) { $t = $t.Substring(0, 200) }
      $titles += $t
    }
  }
  if (Test-Path $builder) { try { & $builder -Root $Root } catch { } }

  # --- 3/4. stage (main: only the log), then scan what is staged ---
  $null = GitC reset -q
  if ($branch -eq 'main') { $null = GitC add -A -- $logName } else { $null = GitC add -A }

  $patterns = @(
    'sk-ant-[A-Za-z0-9_\-]{20,}', 'ghp_[A-Za-z0-9]{20,}', 'gho_[A-Za-z0-9]{20,}', 'github_pat_[A-Za-z0-9_]{20,}',
    'AKIA[0-9A-Z]{16}', 'AIza[0-9A-Za-z_\-]{35}', '-----BEGIN [A-Z ]*PRIVATE KEY', 'xox[bp]-[A-Za-z0-9-]{10,}'
  )
  $hitFiles = @()
  $cur = ''
  foreach ($line in @(GitC diff --cached -U0 --no-color)) {
    $l = "$line"
    if ($l.StartsWith('+++ ')) { $cur = $l.Substring(4); if ($cur.StartsWith('b/')) { $cur = $cur.Substring(2) }; continue }
    if (-not $l.StartsWith('+')) { continue }
    foreach ($p in $patterns) {
      $m = [regex]::Match($l, $p)
      if (-not $m.Success) { continue }
      if ($p.StartsWith('sk-ant-') -and $cur.StartsWith('tests/') -and $m.Value -match 'test') { continue }
      if ($hitFiles -notcontains $cur) { $hitFiles += $cur }
    }
  }
  if ($hitFiles.Count) {
    $null = GitC reset -q
    Out-Msg ('נמצא מה שנראה כמו מפתח או סיסמה בקובץ: ' + ($hitFiles -join ', ') + '. לא נשמר ולא נדחף. יש להסיר את הסוד ולהמשיך.')
    exit 0
  }

  # --- 5. commit ---
  $messages = @()
  $staged = @(GitC diff --cached --name-only | Where-Object { $_ })
  if ($staged.Count) {
    $subject = if ($titles.Count) { $titles -join '; ' } else { "עדכון אוטומטי: $($staged.Count) קבצים" }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('stop-commit-' + [Guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($tmp, $subject + "`n`nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`n", $utf8)
    $null = GitC commit -q -F $tmp
    $commitExit = $gitExit
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if ($commitExit -ne 0) { Out-Msg 'השמירה ב-Git נכשלה. השינויים נשארו במחשב.'; exit 0 }
  }
  if ($branch -eq 'main' -and $codeChanged.Count) {
    $messages += 'שינויי קוד ב-main לא נשמרו. יש להעביר אותם לענף יכולת חדש.'
  }

  # --- 7. push ---
  $null = GitC push -u origin $branch --quiet
  if ($gitExit -ne 0) {
    $messages += 'השמירה נשמרה במחשב ותידחף בפעם הבאה'
  } else {
    $messages += "נשמר ונדחף ל-GitHub: $branch ($($staged.Count) קבצים)"
  }
  Out-Msg ($messages -join ' | ')
} catch {
  Out-Msg 'hook השמירה האוטומטית נתקל בשגיאה ולא השלים. השינויים נשארו במחשב.'
}
exit 0
