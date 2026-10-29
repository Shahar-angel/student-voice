# Deploys the code of `main` to the two Google Apps Script projects with clasp, safely:
#  1. only from a clean, pushed `main`          2. the test suite must pass
#  3. drift check: what is in Google must equal the commit it was deployed from (nobody edited it in the browser)
#  4. push only the projects that changed, new version on the EXISTING deployment id (the public links never change)
#  5. verify by pulling again (and, for the app, by opening the public address)
# Any failure stops with a Hebrew message and exit 1; nothing is pushed unless every check passed.
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\deploy-google.ps1 [-DryRun] [-SkipTests]
# -Clasp: path to clasp (else env CLASP_CMD, else `clasp` on PATH, else the default Node install in the user profile).
# -TestScript / -SkipLiveCheck exist for the automated tests (tests/google-sync.test.ps1).
param(
  [string]$Root = '',
  [string]$Clasp = '',
  [switch]$SkipTests,
  [switch]$DryRun,
  [string]$TestScript = '',
  [switch]$SkipLiveCheck
)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$utf8 = New-Object Text.UTF8Encoding($false)
$env:GIT_TERMINAL_PROMPT = '0'
if (-not $Root) { $Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
$Root = $Root.TrimEnd('\', '/')
if (-not $TestScript) { $TestScript = Join-Path $Root 'tests\run-tests.ps1' }
$work = Join-Path ([IO.Path]::GetTempPath()) ('deploy-google-' + [Guid]::NewGuid().ToString('N'))

function Stop-Deploy([string]$msg) {
  Write-Output $msg
  Write-Output 'לא נפרס כלום ל-Google.'
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
  exit 1
}
function Invoke-Git { $o = & git.exe -C $Root -c core.quotepath=false @args 2>&1 | ForEach-Object { "$_" }; $script:gitExit = $LASTEXITCODE; ($o -join "`n").Trim() }
function Invoke-Clasp { $o = & $script:ClaspExe @args 2>&1 | ForEach-Object { "$_" }; $script:claspExit = $LASTEXITCODE; ($o -join "`n") }
# Raw bytes of `git show <rev>:<path>` ($rev is validated, $path is a fixed repo path), decoded as UTF-8 text; $null when missing.
function Get-GitText([string]$rev, [string]$path) {
  if ($rev -ne 'HEAD' -and $rev -notmatch '^[0-9a-f]{7,40}$') { return $null }
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'git.exe'
  $psi.Arguments = '-C "' + $Root + '" show ' + $rev + ':' + $path
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $p = [Diagnostics.Process]::Start($psi)
  $ms = New-Object IO.MemoryStream
  $errTask = $p.StandardError.ReadToEndAsync()
  $p.StandardOutput.BaseStream.CopyTo($ms)
  $p.WaitForExit()
  if ($p.ExitCode -ne 0) { return $null }
  $utf8.GetString($ms.ToArray())
}
function Format-Text([string]$t) { if ($null -eq $t) { return $null }; ($t -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd("`n") }
function Read-File([string]$path) { if (Test-Path -LiteralPath $path) { Format-Text ([IO.File]::ReadAllText($path, $utf8)) } else { $null } }

# --- config ---
$cfgPath = Join-Path $Root 'config\deployment.json'
if (-not (Test-Path $cfgPath)) { Stop-Deploy 'חסר הקובץ config\deployment.json.' }
$cfg = [IO.File]::ReadAllText($cfgPath, $utf8) | ConvertFrom-Json
foreach ($k in 'scriptId', 'deploymentId', 'senderScriptId', 'senderDeploymentId', 'appUrl') {
  if (-not $cfg.$k -or "$($cfg.$k)" -notmatch '^[A-Za-z0-9_\-:/\.]+$') { Stop-Deploy "חסר או לא תקין השדה '$k' ב-config\deployment.json." }
}
$projects = @(
  [pscustomobject]@{ name = 'main'; title = 'האפליקציה'; scriptId = "$($cfg.scriptId)"; depId = "$($cfg.deploymentId)"; dir = 'apps-script'
    files = @(@{ local = 'Code.gs'; remote = 'קוד.js' }, @{ local = 'Index.html'; remote = 'Index.html' }, @{ local = 'appsscript.json'; remote = 'appsscript.json' }) },
  [pscustomobject]@{ name = 'sender'; title = 'השולח האישי'; scriptId = "$($cfg.senderScriptId)"; depId = "$($cfg.senderDeploymentId)"; dir = 'apps-script-sender'
    files = @(@{ local = 'Code.gs'; remote = 'קוד.js' }, @{ local = 'appsscript.json'; remote = 'appsscript.json' }) }
)

# --- 1. preconditions ---
$branch = Invoke-Git rev-parse --abbrev-ref HEAD
if ($gitExit -ne 0) { Stop-Deploy 'התיקייה אינה מאגר Git תקין.' }
if ($branch -ne 'main') { Stop-Deploy "פריסה ל-Google מתבצעת רק מענף main, והענף הנוכחי הוא '$branch'. יש למזג ל-main קודם." }
if (Invoke-Git status --porcelain) { Stop-Deploy 'יש שינויים שלא נשמרו ב-Git. יש לשמור (commit) לפני הפריסה.' }
$null = Invoke-Git fetch --quiet origin
if ($gitExit -ne 0) { Stop-Deploy 'לא ניתן להתחבר ל-GitHub (git fetch נכשל), ולכן אי אפשר לוודא ש-main מעודכן.' }
$local = Invoke-Git rev-parse main
$remote = Invoke-Git rev-parse origin/main
if ($gitExit -ne 0 -or -not $remote) { Stop-Deploy 'לא נמצא origin/main.' }
if ($local -ne $remote) { Stop-Deploy 'main המקומי שונה מ-origin/main ב-GitHub. יש לדחוף או למשוך קודם, כך שהם יהיו זהים.' }
$head = $local
$short = Invoke-Git rev-parse --short=7 HEAD
$subject = (Invoke-Git log -1 --format=%s HEAD)
$subject = ($subject -split "`n")[0]
# Only letters, digits and a few safe marks go into the description: it is passed to clasp (a .cmd file), so no shell metacharacters.
$subject = ([regex]::Replace($subject, '[^\p{L}\p{N} .,_:()/+\-]', ' ') -replace '\s+', ' ').Trim()
if ($subject.Length -gt 60) { $subject = $subject.Substring(0, 60).Trim() }
$desc = ("main@$short $subject").Trim()

# --- clasp ---
$ClaspExe = $null
if ($Clasp) { $ClaspExe = $Clasp }
elseif ($env:CLASP_CMD) { $ClaspExe = $env:CLASP_CMD }
else {
  $c = Get-Command clasp -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { $ClaspExe = $c.Source }
  else {
    $fallback = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs') -Directory -Filter 'node-v*' -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'clasp.cmd' } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($fallback) { $ClaspExe = $fallback }
  }
}
if (-not $ClaspExe -or -not (Test-Path -LiteralPath $ClaspExe)) { Stop-Deploy 'לא נמצא clasp. יש להתקין אותו (ראו docs\01-התקנה-ופריסה.md, "הגדרה חד-פעמית").' }

# --- 2. tests ---
if (-not $SkipTests) {
  if (-not (Test-Path -LiteralPath $TestScript)) { Stop-Deploy 'לא נמצא סקריפט הבדיקות.' }
  $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TestScript 2>&1
  if ($LASTEXITCODE -ne 0) { Stop-Deploy 'הבדיקות נכשלו (ראו tests\last-results.md).' }
}

# --- 3. staging dirs with the files under their Google names ---
New-Item -ItemType Directory -Force $work | Out-Null
function New-ClaspDir([string]$dir, [string]$scriptId) {
  New-Item -ItemType Directory -Force $dir | Out-Null
  [IO.File]::WriteAllText((Join-Path $dir '.clasp.json'), (@{ scriptId = $scriptId; rootDir = '.' } | ConvertTo-Json -Compress), $utf8)
}
function Get-DeploymentLine([string]$scriptId, [string]$depId, [string]$dir) {
  $out = Invoke-Clasp list-deployments $scriptId
  if ($claspExit -ne 0) { return $null }
  foreach ($l in ($out -split "`n")) {
    $m = [regex]::Match($l.TrimEnd("`r"), '^\s*-\s+(\S+)\s+@(\S+)(?:\s+-\s+(.*))?\s*$')
    if ($m.Success -and $m.Groups[1].Value -eq $depId) { return [pscustomobject]@{ version = $m.Groups[2].Value; description = "$($m.Groups[3].Value)".Trim() } }
  }
  $null
}
function Pull-Project($p, [string]$dir) {
  New-ClaspDir $dir $p.scriptId
  Push-Location $dir
  try { $null = Invoke-Clasp pull } finally { Pop-Location }
  $claspExit -eq 0
}

# --- 4. drift check (nothing has been pushed yet) ---
$state = @{}
foreach ($p in $projects) {
  $pullDir = Join-Path $work ("pull-" + $p.name)
  if (-not (Pull-Project $p $pullDir)) { Stop-Deploy "הורדת הקוד הנוכחי מ-Google נכשלה עבור $($p.title). אולי חסרה התחברות (clasp login) או שה-Apps Script API כבוי." }
  $dep = Get-DeploymentLine $p.scriptId $p.depId $pullDir
  if (-not $dep) { Stop-Deploy "הפריסה $($p.depId) של $($p.title) לא נמצאה ב-Google." }
  $pulled = @{}
  foreach ($f in $p.files) { $pulled[$f.local] = Read-File (Join-Path $pullDir $f.remote) }
  # Which commit should Google equal? main@<hash> in the description; for old descriptions any recent commit that touched the project.
  $candidates = @()
  $m = [regex]::Match($dep.description, 'main@([0-9a-f]{7,40})')
  $legacy = $true
  if ($m.Success) {
    $null = Invoke-Git cat-file -e ($m.Groups[1].Value + '^{commit}')
    if ($gitExit -eq 0) { $candidates = @($m.Groups[1].Value); $legacy = $false }
  }
  if ($legacy) {
    $candidates = @('HEAD') + @((Invoke-Git log -n 30 --format=%H HEAD -- $p.dir) -split "`n" | Where-Object { $_ -match '^[0-9a-f]{40}$' })
  }
  $matchedRev = $null
  foreach ($rev in $candidates) {
    $same = $true
    foreach ($f in $p.files) {
      if ($pulled[$f.local] -ne (Format-Text (Get-GitText $rev ($p.dir + '/' + $f.local)))) { $same = $false; break }
    }
    if ($same) { $matchedRev = $rev; break }
  }
  if (-not $matchedRev) {
    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $driftDir = Join-Path $Root "backups\google-drift\$stamp\$($p.name)"
    New-Item -ItemType Directory -Force $driftDir | Out-Null
    $baseRev = if ($candidates.Count) { $candidates[0] } else { 'HEAD' }
    $diffText = @()
    foreach ($f in $p.files) {
      $src = Join-Path $pullDir $f.remote
      if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $driftDir $f.remote) -Force }
      $expected = Format-Text (Get-GitText $baseRev ($p.dir + '/' + $f.local))
      $tmpExp = Join-Path $work ('expected-' + $p.name + '-' + $f.local)
      [IO.File]::WriteAllText($tmpExp, "$expected`n", $utf8)
      $d = Invoke-Git diff --no-index --no-color -- $tmpExp $src
      $diffText += "=== $($f.local) (ימין = Google, שמאל = הקוד ב-Git, $baseRev) ==="
      $diffText += $d
    }
    [IO.File]::WriteAllText((Join-Path $driftDir 'drift.diff'), ($diffText -join "`n") + "`n", $utf8)
    Stop-Deploy ("מישהו שינה את הקוד של $($p.title) ישירות בעורך של Google, והוא כבר לא זהה למה ש-Git מכיר. כדי לא לדרוס את השינוי, הפריסה נעצרה. " +
      "העותק מ-Google וקובץ ההבדלים נשמרו ב: $driftDir . יש לבדוק את השינוי, להעביר אותו ל-Git (ענף חדש) או להחליט לוותר עליו, ואז להריץ שוב.")
  }
  $state[$p.name] = [pscustomobject]@{ pulled = $pulled; dep = $dep; pullDir = $pullDir }
}

# --- 5. decide what changed ---
$toPush = @()
foreach ($p in $projects) {
  $changed = $false
  foreach ($f in $p.files) {
    if ($state[$p.name].pulled[$f.local] -ne (Format-Text (Get-GitText 'HEAD' ($p.dir + '/' + $f.local)))) { $changed = $true }
  }
  if ($changed) { $toPush += $p }
}
if ($DryRun) {
  if ($toPush.Count) { Write-Output ('בדיקה בלבד: היו נפרסים: ' + (($toPush | ForEach-Object { $_.title }) -join ', ') + " (תיאור הפריסה: $desc). לא נפרס כלום.") }
  else { Write-Output 'בדיקה בלבד: ללא שינוי, אין מה לפרוס.' }
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
  exit 0
}
if (-not $toPush.Count) {
  Write-Output 'ללא שינוי: הקוד ב-Google זהה לקוד ב-main.'
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
  exit 0
}

# --- push, new version, same deployment id ---
$summary = @()
foreach ($p in $toPush) {
  $stage = Join-Path $work ("stage-" + $p.name)
  New-ClaspDir $stage $p.scriptId
  foreach ($f in $p.files) {
    $t = Format-Text (Get-GitText 'HEAD' ($p.dir + '/' + $f.local))
    if ($null -eq $t) { Stop-Deploy "הקובץ $($p.dir)/$($f.local) לא נמצא ב-Git (HEAD)." }
    [IO.File]::WriteAllText((Join-Path $stage $f.remote), "$t`n", $utf8)
  }
  Push-Location $stage
  try {
    $null = Invoke-Clasp push -f
    if ($claspExit -ne 0) { Write-Output "הדחיפה של $($p.title) ל-Google נכשלה."; Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue; exit 1 }
    $out = Invoke-Clasp create-version $desc
    if ($claspExit -ne 0) { Write-Output "יצירת גרסה ל$($p.title) נכשלה (הקוד כבר הועלה)."; Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue; exit 1 }
    $vm = [regex]::Match($out, '(?i)version\s+(\d+)')
    if (-not $vm.Success) {
      $lv = Invoke-Clasp list-versions
      $nums = @(([regex]::Matches($lv, '(?m)^\s*-?\s*(\d+)\s+-') | ForEach-Object { [int]$_.Groups[1].Value }))
      if ($nums.Count) { $vm = [pscustomobject]@{ Success = $true; Groups = @($null, [pscustomobject]@{ Value = ($nums | Measure-Object -Maximum).Maximum }) } }
    }
    if (-not $vm.Success) { Write-Output "לא ניתן היה לקבוע את מספר הגרסה החדשה של $($p.title)."; Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue; exit 1 }
    $ver = "$($vm.Groups[1].Value)"
    $null = Invoke-Clasp update-deployment $p.depId -V $ver -d $desc
    if ($claspExit -ne 0) { Write-Output "עדכון הפריסה של $($p.title) לגרסה $ver נכשל."; Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue; exit 1 }
  } finally { Pop-Location }
  $state[$p.name] | Add-Member -NotePropertyName version -NotePropertyValue $ver -Force
}

# --- 6. verify ---
$problems = @()
foreach ($p in $toPush) {
  $vDir = Join-Path $work ("verify-" + $p.name)
  if (-not (Pull-Project $p $vDir)) { $problems += "אימות $($p.title): הורדה חוזרת נכשלה"; continue }
  foreach ($f in $p.files) {
    if ((Read-File (Join-Path $vDir $f.remote)) -ne (Format-Text (Get-GitText 'HEAD' ($p.dir + '/' + $f.local)))) { $problems += "אימות $($p.title): $($f.local) ב-Google שונה מ-main" }
  }
  $dep = Get-DeploymentLine $p.scriptId $p.depId $vDir
  if (-not $dep -or $dep.version -ne $state[$p.name].version) { $problems += "אימות $($p.title): הפריסה לא מצביעה על הגרסה החדשה" }
}
if (-not $SkipLiveCheck -and ($toPush | Where-Object { $_.name -eq 'main' })) {
  $marker = [regex]::Match((Get-GitText 'HEAD' 'apps-script/Index.html'), '<title>([^<]+)</title>').Groups[1].Value
  $body = Join-Path $work 'live.html'
  $code = (& curl.exe -sL -m 60 -o $body -w '%{http_code}' $cfg.appUrl 2>$null | Out-String).Trim()
  if ($code -ne '200') { $problems += "הכתובת הציבורית של האפליקציה החזירה $code" }
  elseif ($marker -and -not ([IO.File]::ReadAllText($body, $utf8)).Contains($marker)) { $problems += 'הכתובת הציבורית נפתחת אבל לא מציגה את הדף הצפוי' }
}
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
if ($problems.Count) { Write-Output ('הפריסה בוצעה אך האימות מצא בעיה: ' + ($problems -join '; ')); exit 1 }
$names = ($toPush | ForEach-Object { "$($_.title) (גרסה $($state[$_.name].version))" }) -join ', '
Write-Output "נפרס ל-Google ואומת: $names. תיאור: $desc"
exit 0
