# Tests for tools/deploy-google.ps1 (deploy to Google with clasp) and its trigger in the Stop hook (.claude/hooks/on-stop.ps1).
# Google is faked: a stub "clasp" serves a directory that plays the role of the Google projects. Nothing real is touched.
# Each case runs in a throwaway directory with a bare repo as "origin" and a working clone.
# Output: one line per check, "✅ name" or "❌ name - detail", then "TOTAL n FAILED m". Exit code 0 = all passed.
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$utf8 = New-Object Text.UTF8Encoding($false)
$repo = Split-Path -Parent $PSScriptRoot
$base = Join-Path ([IO.Path]::GetTempPath()) ('google-sync-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $base | Out-Null
$env:GIT_TERMINAL_PROMPT = '0'
$results = @()
$deployScript = Join-Path $repo 'tools\deploy-google.ps1'

function Check([string]$name, [bool]$ok, [string]$detail = '') {
  $script:results += [pscustomobject]@{ name = $name; ok = $ok }
  if ($ok) { Write-Output "✅ $name" } else { Write-Output "❌ $name - $detail" }
}
function G([string]$dir) { $o = & git -C $dir -c core.quotepath=false @args 2>&1; $script:gx = $LASTEXITCODE; ($o | Out-String).Trim() }
function Write-Text([string]$path, [string]$text) {
  New-Item -ItemType Directory -Force (Split-Path -Parent $path) | Out-Null
  [IO.File]::WriteAllText($path, $text, $utf8)
}

# --- the fake clasp: .cmd wrapper + PowerShell stub. State: $env:FAKE_GOOGLE\<scriptId>\{files\, deployments.txt, ver.txt}; log: $env:FAKE_LOG ---
$fakeDir = Join-Path $base 'fake'
New-Item -ItemType Directory -Force $fakeDir | Out-Null
[IO.File]::WriteAllText((Join-Path $fakeDir 'clasp.cmd'), "@powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-clasp.ps1`" %*`r`n", [Text.Encoding]::ASCII)
$fakeSrc = @'
$utf8 = New-Object Text.UTF8Encoding($false)
$a = @($args)
$g = $env:FAKE_GOOGLE; $log = $env:FAKE_LOG
function L([string]$s) { [IO.File]::AppendAllText($log, $s + "`n", $utf8) }
function Sid { (Get-Content -Raw -Encoding UTF8 .clasp.json | ConvertFrom-Json).scriptId }
switch ($a[0]) {
  'pull' {
    $sid = Sid; $files = Join-Path $g "$sid\files"; $n = 0
    foreach ($f in (Get-ChildItem $files -File)) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path (Get-Location) $f.Name) -Force; $n++ }
    L "pull $sid"; Write-Output "Pulled $n files."
  }
  'push' {
    if ($a -notcontains '-f') { Write-Output 'missing -f'; exit 1 }
    $sid = Sid; $files = Join-Path $g "$sid\files"; $names = @()
    Get-ChildItem $files -File | Remove-Item -Force
    foreach ($f in (Get-ChildItem -File | Where-Object { $_.Name -ne '.clasp.json' })) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $files $f.Name) -Force; $names += $f.Name }
    L ("push $sid " + (($names | Sort-Object) -join ','))
    Write-Output 'Pushed files.'
  }
  'list-deployments' {
    $sid = $a[1]; $lines = [IO.File]::ReadAllLines((Join-Path $g "$sid\deployments.txt"), $utf8)
    Write-Output "Found $($lines.Count) deployments."; $lines | ForEach-Object { Write-Output $_ }
  }
  'create-version' {
    $sid = Sid; $vf = Join-Path $g "$sid\ver.txt"; $v = [int][IO.File]::ReadAllText($vf) + 1
    [IO.File]::WriteAllText($vf, "$v"); L "version $sid $v $($a[1])"; Write-Output "Created version $v."
  }
  'update-deployment' {
    $sid = Sid; $id = $a[1]; $v = $null; $d = ''
    for ($i = 2; $i -lt $a.Count; $i++) { if ($a[$i] -eq '-V') { $v = $a[$i + 1] }; if ($a[$i] -eq '-d') { $d = $a[$i + 1] } }
    $df = Join-Path $g "$sid\deployments.txt"
    $lines = [IO.File]::ReadAllLines($df, $utf8) | ForEach-Object { if ($_ -like "- $id *") { "- $id @$v - $d" } else { $_ } }
    [IO.File]::WriteAllLines($df, $lines, $utf8)
    L "update $sid $id $v $d"; Write-Output "Updated deployment $id."
  }
  'list-versions' { $sid = Sid; $v = [IO.File]::ReadAllText((Join-Path $g "$sid\ver.txt")); Write-Output "Found $v versions."; Write-Output "$v - last" }
  default { L "UNKNOWN $($a -join ' ')"; Write-Output 'unknown command'; exit 1 }
}
exit 0
'@
[IO.File]::WriteAllText((Join-Path $fakeDir 'fake-clasp.ps1'), $fakeSrc, (New-Object Text.UTF8Encoding($true)))
$fakeClasp = Join-Path $fakeDir 'clasp.cmd'
$stubOk = Join-Path $fakeDir 'tests-pass.ps1';   [IO.File]::WriteAllText($stubOk, "exit 0`n", $utf8)
$stubFail = Join-Path $fakeDir 'tests-fail.ps1'; [IO.File]::WriteAllText($stubFail, "Write-Output 'boom'`nexit 1`n", $utf8)

$mainSid = 'MAINSID'; $mainDep = 'MAINDEP'; $sendSid = 'SENDSID'; $sendDep = 'SENDDEP'
$mainCode = "// קוד ראשי שלום 😀 `"quotes`" & more`nfunction a() { return 'א'; }`n"
$mainIndex = "<!doctype html><html><head><title>קול הסטודנטים</title></head><body>ok</body></html>`n"
$mainManifest = "{`n  `"timeZone`": `"Asia/Jerusalem`"`n}`n"
$sendCode = "// sender code`nfunction s() {}`n"
$sendManifest = "{`n  `"timeZone`": `"Asia/Jerusalem`"`n}`n"

# New environment: bare origin + working clone (main pushed) + a fake Google holding the same code. Descriptions are the "active deployment" ones.
function New-Env([string]$id, [string]$mainDesc = 'v20 legacy description', [string]$sendDesc = 'v3 legacy description') {
  $d = Join-Path $base $id
  $bare = Join-Path $d 'origin.git'; $work = Join-Path $d 'work'; $google = Join-Path $d 'google'
  New-Item -ItemType Directory -Force $bare, $work, $google | Out-Null
  $null = G $bare init -q --bare -b main
  $null = G $work init -q -b main
  $null = G $work config user.email 't@example.com'
  $null = G $work config user.name 'Tester'
  $null = G $work config commit.gpgsign false
  $null = G $work config core.autocrlf false
  $null = G $work remote add origin $bare
  Write-Text (Join-Path $work '.gitignore') "backups/`n"
  Write-Text (Join-Path $work 'apps-script\Code.gs') $mainCode
  Write-Text (Join-Path $work 'apps-script\Index.html') $mainIndex
  Write-Text (Join-Path $work 'apps-script\appsscript.json') $mainManifest
  Write-Text (Join-Path $work 'apps-script-sender\Code.gs') $sendCode
  Write-Text (Join-Path $work 'apps-script-sender\appsscript.json') $sendManifest
  $cfg = [ordered]@{ appUrl = 'http://127.0.0.1:9/exec'; scriptId = $mainSid; deploymentId = $mainDep; senderScriptId = $sendSid; senderDeploymentId = $sendDep }
  Write-Text (Join-Path $work 'config\deployment.json') ($cfg | ConvertTo-Json)
  $null = G $work add -A
  $null = G $work commit -q -m 'init'
  $null = G $work push -q -u origin main
  foreach ($p in @(@($mainSid, $mainDep, $mainDesc), @($sendSid, $sendDep, $sendDesc))) {
    $gd = Join-Path $google "$($p[0])\files"
    New-Item -ItemType Directory -Force $gd | Out-Null
    [IO.File]::WriteAllText((Join-Path $google "$($p[0])\ver.txt"), '20')
    [IO.File]::WriteAllLines((Join-Path $google "$($p[0])\deployments.txt"), @("- HEAD$($p[0]) @HEAD ", "- $($p[1]) @20 - $($p[2])"), $utf8)
  }
  Write-Text (Join-Path $google "$mainSid\files\קוד.js") $mainCode
  Write-Text (Join-Path $google "$mainSid\files\Index.html") $mainIndex
  Write-Text (Join-Path $google "$mainSid\files\appsscript.json") $mainManifest
  Write-Text (Join-Path $google "$sendSid\files\קוד.js") $sendCode
  Write-Text (Join-Path $google "$sendSid\files\appsscript.json") $sendManifest
  [pscustomobject]@{ bare = $bare; work = $work; google = $google; log = (Join-Path $d 'clasp.log') }
}
function Commit-File($e, [string]$rel, [string]$text, [string]$msg, [bool]$push = $true) {
  Write-Text (Join-Path $e.work $rel) $text
  $null = G $e.work add -A
  $null = G $e.work commit -q -m $msg
  if ($push) { $null = G $e.work push -q origin main }
}
function Run-Deploy($e, [string[]]$extra = @('-SkipTests')) {
  $env:FAKE_GOOGLE = $e.google; $env:FAKE_LOG = $e.log
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $deployScript -Root $e.work -Clasp $fakeClasp -SkipLiveCheck @extra 2>&1
  $script:dx = $LASTEXITCODE
  Remove-Item Env:\FAKE_GOOGLE, Env:\FAKE_LOG
  ($out | ForEach-Object { "$_" }) -join "`n"
}
function Log-Lines($e) { if (Test-Path $e.log) { @([IO.File]::ReadAllLines($e.log, $utf8) | Where-Object { $_ }) } else { @() } }
function Pushes($e) { @(Log-Lines $e | Where-Object { $_ -like 'push *' }) }
function Mutations($e) { @(Log-Lines $e | Where-Object { $_ -match '^(push|version|update) ' }) }
function Dep-Line($e, [string]$sid, [string]$dep) { [IO.File]::ReadAllLines((Join-Path $e.google "$sid\deployments.txt"), $utf8) | Where-Object { $_ -like "- $dep *" } | Select-Object -First 1 }
function Google-File($e, [string]$sid, [string]$name) { [IO.File]::ReadAllBytes((Join-Path $e.google "$sid\files\$name")) }

try {
  # (a) not on main
  $e = New-Env 'a'
  $null = G $e.work checkout -q -b feat-a
  $out = Run-Deploy $e
  Check 'Not on main: refused with exit 1 and a Hebrew message' ($dx -eq 1 -and $out -match 'main' -and $out -match 'לא נפרס כלום') $out
  Check 'Not on main: nothing contacted Google' ((Log-Lines $e).Count -eq 0)

  # (b) dirty tree
  $e = New-Env 'b'
  Write-Text (Join-Path $e.work 'apps-script\Code.gs') '// dirty'
  $out = Run-Deploy $e
  Check 'Dirty tree: refused' ($dx -eq 1 -and $out -match 'לא נשמרו') $out
  Check 'Dirty tree: nothing pushed' ((Mutations $e).Count -eq 0)
  $e = New-Env 'b2'
  Write-Text (Join-Path $e.work 'new-untracked.txt') 'x'
  $out = Run-Deploy $e
  Check 'Untracked file counts as dirty' ($dx -eq 1) $out

  # (c) local ahead of origin
  $e = New-Env 'c'
  Commit-File $e 'apps-script\Code.gs' "// ahead`n" 'local only' $false
  $out = Run-Deploy $e
  Check 'Local main ahead of origin: refused' ($dx -eq 1 -and $out -match 'origin/main') $out
  Check 'Local main ahead of origin: nothing pushed' ((Mutations $e).Count -eq 0)

  # (c2) origin unreachable
  $e = New-Env 'c2'
  $null = G $e.work remote set-url origin (Join-Path $base 'no-such-origin.git')
  $out = Run-Deploy $e
  Check 'Fetch fails: stops and says so' ($dx -eq 1 -and $out -match 'GitHub') $out

  # (d) tests fail / pass (stub test scripts)
  $e = New-Env 'd'
  Commit-File $e 'apps-script\Code.gs' "// changed d`n" 'change d'
  $out = Run-Deploy $e @('-TestScript', $stubFail)
  Check 'Failing tests: refused, nothing pushed' ($dx -eq 1 -and $out -match 'הבדיקות נכשלו' -and (Mutations $e).Count -eq 0) $out
  $out = Run-Deploy $e @('-TestScript', $stubOk)
  Check 'Passing tests: deploy goes ahead' ($dx -eq 0 -and (Pushes $e).Count -eq 1) $out

  # (e) drift: Google main edited in the browser, sender has a legitimate change -> nothing pushed to either
  $e = New-Env 'e'
  Commit-File $e 'apps-script-sender\Code.gs' "// sender v2`n" 'sender change'
  Write-Text (Join-Path $e.google "$mainSid\files\קוד.js") "$mainCode// edited in the Google editor`n"
  $out = Run-Deploy $e
  Check 'Drift: refused with a Hebrew message' ($dx -eq 1 -and $out -match 'בעורך של Google' -and $out -match 'לא נפרס כלום') $out
  Check 'Drift: nothing pushed to either project' ((Mutations $e).Count -eq 0)
  $driftRoot = Join-Path $e.work 'backups\google-drift'
  $driftDiff = Get-ChildItem $driftRoot -Recurse -Filter 'drift.diff' -ErrorAction SilentlyContinue | Select-Object -First 1
  Check 'Drift: folder with a diff was created' ($null -ne $driftDiff -and ([IO.File]::ReadAllText($driftDiff.FullName, $utf8)).Contains('edited in the Google editor')) "$driftRoot"
  Check 'Drift: pulled copy saved beside the diff' ($null -ne $driftDiff -and (Test-Path (Join-Path (Split-Path -Parent $driftDiff.FullName) 'קוד.js')))
  Check 'Drift: backups/ is ignored, tree stays clean' ((G $e.work status --porcelain) -eq '')

  # (e2) drift when the deployment description names the exact commit
  $e = New-Env 'e2'
  $h0 = G $e.work rev-parse --short=7 HEAD
  [IO.File]::WriteAllLines((Join-Path $e.google "$mainSid\deployments.txt"), @("- $mainDep @20 - main@$h0 init"), $utf8)
  Commit-File $e 'apps-script\Code.gs' "// real change`n" 'real change'
  Write-Text (Join-Path $e.google "$mainSid\files\Index.html") "$mainIndex<!-- hand edit -->`n"
  $out = Run-Deploy $e
  Check 'Drift against main@<hash>: refused' ($dx -eq 1 -and $out -match 'בעורך של Google' -and (Mutations $e).Count -eq 0) $out
  # same hash, Google untouched -> the legitimate change deploys
  Write-Text (Join-Path $e.google "$mainSid\files\Index.html") $mainIndex
  $out = Run-Deploy $e
  Check 'main@<hash> matches Google: deploys the new commit' ($dx -eq 0 -and (Pushes $e).Count -eq 1) $out

  # (f) legacy description + identical content: nothing happens
  $e = New-Env 'f'
  $out = Run-Deploy $e
  Check 'Legacy description + same content: "ללא שינוי", exit 0' ($dx -eq 0 -and $out -match 'ללא שינוי') $out
  Check 'Legacy description + same content: no push, no version' ((Mutations $e).Count -eq 0)

  # (g) changed main code: only the main project is pushed, same deployment id
  $e = New-Env 'g'
  $newCode = "// קוד חדש 🎉 שלום`nfunction b() { return '😀 ש'; }`n"
  Commit-File $e 'apps-script\Code.gs' $newCode 'שינוי קוד: feature (g)'
  $short = G $e.work rev-parse --short=7 HEAD
  $out = Run-Deploy $e
  Check 'Changed Code.gs: exit 0 and a Hebrew summary' ($dx -eq 0 -and $out -match 'נפרס ל-Google') $out
  $pushes = @(Pushes $e)
  Check 'Only the main project was pushed' ($pushes.Count -eq 1 -and $pushes[0] -like "push $mainSid *") ($pushes -join '|')
  Check 'File arrives as קוד.js with the other files' ($pushes[0] -match 'appsscript.json,Index.html,קוד.js$') ($pushes -join '|')
  Check 'Hebrew and emoji content is byte-exact in Google' ([Convert]::ToBase64String((Google-File $e $mainSid 'קוד.js')) -eq [Convert]::ToBase64String($utf8.GetBytes($newCode)))
  Check 'Unchanged files are byte-exact too' ([Convert]::ToBase64String((Google-File $e $mainSid 'Index.html')) -eq [Convert]::ToBase64String($utf8.GetBytes($mainIndex)))
  $dl = Dep-Line $e $mainSid $mainDep
  Check 'Deployment updated: same id, new version, description main@<hash>' ($dl -like "- $mainDep @21 - main@$short *") $dl
  Check 'Version created before the deployment update' ((((Log-Lines $e | Where-Object { $_ -match '^(version|update) ' }) -join '|')) -match '^version MAINSID 21 main@.*\|update MAINSID MAINDEP 21 main@')
  Check 'Sender not touched (no push, deployment unchanged)' ((Dep-Line $e $sendSid $sendDep) -like '*@20 - v3 legacy*' -and -not (Log-Lines $e | Where-Object { $_ -like '*SENDSID*' -and $_ -notlike 'pull *' }))
  Check 'No deployment was created or deleted (only update)' (-not (Log-Lines $e | Where-Object { $_ -match 'UNKNOWN' }))
  # run again: description now has the current hash and the content equals -> nothing to do
  $before = (Mutations $e).Count
  $out = Run-Deploy $e
  Check 'Second run: ללא שינוי and no new push' ($dx -eq 0 -and $out -match 'ללא שינוי' -and (Mutations $e).Count -eq $before) $out

  # (h) both projects changed
  $e = New-Env 'h'
  Commit-File $e 'apps-script-sender\Code.gs' "// sender v2`n" 'both'
  Commit-File $e 'apps-script\appsscript.json' "{`n  `"timeZone`": `"UTC`"`n}`n" 'manifest'
  $out = Run-Deploy $e
  Check 'Both changed: both pushed' ($dx -eq 0 -and (Pushes $e).Count -eq 2) $out
  Check 'Both changed: both deployments moved to @21' ((Dep-Line $e $mainSid $mainDep) -like '*@21 *' -and (Dep-Line $e $sendSid $sendDep) -like '*@21 *')

  # (i) dry run
  $e = New-Env 'i'
  Commit-File $e 'apps-script\Code.gs' "// dry`n" 'dry run change'
  $out = Run-Deploy $e @('-SkipTests', '-DryRun')
  Check 'DryRun: reports what would be deployed' ($dx -eq 0 -and $out -match 'בדיקה בלבד' -and $out -match 'האפליקציה') $out
  Check 'DryRun: nothing pushed' ((Mutations $e).Count -eq 0)
  Write-Text (Join-Path $e.google "$mainSid\files\קוד.js") '// drifted'
  $out = Run-Deploy $e @('-SkipTests', '-DryRun')
  Check 'DryRun still runs the drift check' ($dx -eq 1 -and $out -match 'בעורך של Google')

  # (j) long / hostile commit subject
  $e = New-Env 'j'
  $subj = ('x' * 150) + ' & | < > % ^ "quote" `$(calc)'
  Commit-File $e 'apps-script\Code.gs' "// subject test`n" $subj
  $out = Run-Deploy $e
  $dl = Dep-Line $e $mainSid $mainDep
  $dtext = ($dl -split ' - ', 2)[1]
  Check 'Long subject: deployed' ($dx -eq 0) $out
  Check 'Long subject: description is "main@<hash> " + at most 60 chars' ($dtext -match '^main@[0-9a-f]{7} x+$' -and $dtext.Length -le 'main@abc1234 '.Length + 60) $dtext
  $subj2 = 'תיאור עם מטרות & פיפ | ואחוז % וגם ^'
  Commit-File $e 'apps-script\Code.gs' "// subject test 2`n" $subj2
  $null = Run-Deploy $e
  $dtext = ((Dep-Line $e $mainSid $mainDep) -split ' - ', 2)[1]
  Check 'Shell characters never reach the description' ($dtext -notmatch '[&|<>%^"`$]' -and $dtext -match '^main@[0-9a-f]{7} ') $dtext

  # (k) clasp missing / failing
  $e = New-Env 'k'
  Commit-File $e 'apps-script\Code.gs' "// k`n" 'k'
  $env:FAKE_GOOGLE = $e.google; $env:FAKE_LOG = $e.log
  $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $deployScript -Root $e.work -Clasp (Join-Path $base 'no-clasp.cmd') -SkipTests -SkipLiveCheck 2>&1 | ForEach-Object { "$_" }) -join "`n"
  $kx = $LASTEXITCODE
  Remove-Item Env:\FAKE_GOOGLE, Env:\FAKE_LOG
  Check 'clasp not found: refused with a Hebrew message' ($kx -eq 1 -and $out -match 'clasp') $out
  $e = New-Env 'k2'
  Commit-File $e 'apps-script\Code.gs' "// k2`n" 'k2'
  Remove-Item -Recurse -Force (Join-Path $e.google $mainSid)
  $out = Run-Deploy $e
  Check 'clasp pull fails: refused, nothing pushed' ($dx -eq 1 -and (Mutations $e).Count -eq 0) $out

  # (l) static checks of the script
  $src = [IO.File]::ReadAllText($deployScript, $utf8)
  Check 'Script has no ids or tokens hard-coded' (-not ($src -match 'AKfycb[A-Za-z0-9_\-]{20,}' -or $src -match '15RZeUDEYP' -or $src -match '1P9GDTFgV4'))
  $cfgReal = [IO.File]::ReadAllText((Join-Path $repo 'config\deployment.json'), $utf8) | ConvertFrom-Json
  Check 'config/deployment.json has scriptId, deploymentId, senderScriptId, senderDeploymentId' ($cfgReal.scriptId -and $cfgReal.deploymentId -and $cfgReal.senderScriptId -and $cfgReal.senderDeploymentId)
  Check 'Deployment ids in the config match the public URLs' ($cfgReal.appUrl -like "*/$($cfgReal.deploymentId)/exec" -and $cfgReal.senderUrl -like "*/$($cfgReal.senderDeploymentId)/exec")
  Check 'Script never creates or deletes a deployment' (-not ($src -match "Invoke-Clasp\s+(create-deployment|deploy|undeploy|delete-deployment)\b"))
  Check '.gitignore keeps clasp files out of Git' ((([IO.File]::ReadAllText((Join-Path $repo '.gitignore'), $utf8)) -match '(?m)^\.clasp\.json\s*$') -and (([IO.File]::ReadAllText((Join-Path $repo '.gitignore'), $utf8)) -match '(?m)^\.clasprc\.json\s*$'))

  # --- the Stop hook only deploys when apps-script*/ changed in what it pushed ---
  $stub = Join-Path $fakeDir 'stub-deploy.ps1'
  [IO.File]::WriteAllText($stub, "param([string]`$Root)`n[IO.File]::AppendAllText(`$env:STUB_MARK, 'called ' + `$Root + [Environment]::NewLine)`nif (`$env:STUB_FAIL) { Write-Output 'stub stopped'; exit 1 }`nWrite-Output 'stub deployed'`nexit 0`n", $utf8)
  function New-HookEnv([string]$id) {
    $he = New-Env $id
    foreach ($p in @('.claude\hooks\on-stop.ps1', 'tools\build-activity-log.ps1')) {
      $dest = Join-Path $he.work $p
      New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
      Copy-Item (Join-Path $repo $p) $dest
    }
    $null = G $he.work add -A; $null = G $he.work commit -q -m 'hook files'; $null = G $he.work push -q origin main
    $he | Add-Member -NotePropertyName mark -NotePropertyValue (Join-Path $base "$id-mark.txt")
    $he
  }
  function Run-Hook($he, [bool]$fail = $false) {
    $env:ACTIVITY_LOG_ROOT = $he.work; $env:DEPLOY_GOOGLE_SCRIPT = $stub; $env:STUB_MARK = $he.mark
    if ($fail) { $env:STUB_FAIL = '1' }
    $out = '{}' | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $he.work '.claude\hooks\on-stop.ps1') 2>&1
    $script:hx = $LASTEXITCODE
    Remove-Item Env:\ACTIVITY_LOG_ROOT, Env:\DEPLOY_GOOGLE_SCRIPT, Env:\STUB_MARK, Env:\STUB_FAIL -ErrorAction SilentlyContinue
    ($out | Out-String).Trim()
  }

  $he = New-HookEnv 'ha'
  Commit-File $he 'apps-script\Code.gs' "// hook change`n" 'code change' $false
  $out = Run-Hook $he
  Check 'Hook: main push with apps-script change calls the deploy script' ((Test-Path $he.mark) -and $out -match 'stub deployed' -and $hx -eq 0) $out
  Check 'Hook: deploy script got the repo root' (Test-Path $he.mark) 
  Check 'Hook: the pushed commit reached origin' ((G $he.bare rev-parse main) -eq (G $he.work rev-parse HEAD))

  $he = New-HookEnv 'hb'
  Commit-File $he 'apps-script-sender\Code.gs' "// sender hook change`n" 'sender change' $false
  $out = Run-Hook $he
  Check 'Hook: apps-script-sender change also deploys' ((Test-Path $he.mark) -and $out -match 'stub deployed') $out

  $he = New-HookEnv 'hc'
  Commit-File $he 'docs\note.md' "docs only`n" 'docs change' $false
  $out = Run-Hook $he
  Check 'Hook: docs-only push does not deploy' (-not (Test-Path $he.mark) -and $out -match 'נשמר ונדחף') $out

  $he = New-HookEnv 'hd'
  $null = G $he.work checkout -q -b feat-hook
  Commit-File $he 'apps-script\Code.gs' "// feature`n" 'feature change' $false
  $null = G $he.work push -q -u origin feat-hook
  Write-Text (Join-Path $he.work 'apps-script\Code.gs') "// more feature`n"
  $out = Run-Hook $he
  Check 'Hook: feature branch never deploys' (-not (Test-Path $he.mark)) $out

  $he = New-HookEnv 'he'
  Commit-File $he 'apps-script\Code.gs' "// fail case`n" 'fail change' $false
  $out = Run-Hook $he $true
  Check 'Hook: failed deploy is reported and the hook still exits 0' ($hx -eq 0 -and $out -match 'נעצרה' -and $out -match 'stub stopped') $out

  $he = New-HookEnv 'hf'
  Commit-File $he 'apps-script\Code.gs' "// nothing new to push`n" 'already pushed' $true
  $out = Run-Hook $he
  Check 'Hook: nothing new pushed means no deploy' (-not (Test-Path $he.mark)) $out
} finally {
  Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue
}
$failed = @($results | Where-Object { -not $_.ok }).Count
Write-Output "TOTAL $($results.Count) FAILED $failed"
if ($failed) { exit 1 } else { exit 0 }
