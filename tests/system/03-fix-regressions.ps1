# ---------------------------------------------------------------------------
# YDK test - phase 4 (ELEVATED): regression tests for the eight fixes
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $here) 'harness.ps1')

# This suite drives install/uninstall itself; see the harness.
$script:SuiteManagesInstall = $true

$script:OutDir = Join-Path $script:TestRoot 'out-fix-regressions'
New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
Get-ChildItem $script:OutDir -File -ErrorAction SilentlyContinue | Remove-Item -Force

Assert-SystemTestsAllowed

Start-Transcript -Path (Join-Path $script:TestRoot 'fix-regressions-transcript.txt') -Force | Out-Null

$idn = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal] $idn).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'PHASE4 ABORTED: not elevated.' -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 9
}

$script:SUT = 'C:\Program Files\YDK\ydk.ps1'
$work       = Join-Path $script:TestRoot 'work-fix-regressions'
$psExe      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

$CVolId = (Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq 'C:' }).DeviceID
function Get-ShadowIds { @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ID) }
function Get-OurTasks {
    @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue |
      Where-Object { $_.TaskName -match '^(YDK|TEST|SPC)\d+$' } | Select-Object -ExpandProperty TaskName | Sort-Object)
}
function Remove-AllOurTasks {
    foreach ($n in (Get-OurTasks)) { Unregister-ScheduledTask -TaskName $n -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue }
}
function Remove-TaskIfPresent {
    param([string] $Name, [string] $Path = '\')
    $t = Get-ScheduledTask -TaskName $Name -TaskPath $Path -ErrorAction SilentlyContinue
    if ($t) { Unregister-ScheduledTask -TaskName $Name -TaskPath $Path -Confirm:$false; return $true }
    return $false
}
function Get-TriggerTimes {
    param([string[]] $Names)
    @($Names | ForEach-Object {
        $t = Get-ScheduledTask -TaskName $_ -TaskPath '\' -ErrorAction SilentlyContinue
        if ($t) { ([datetime]@($t.Triggers)[0].StartBoundary).ToString('HH:mm') }
    })
}

$baselineShadows = Get-ShadowIds
$baselineTasks   = @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty TaskName | Sort-Object)
Write-Host ("BASELINE: {0} shadow copies, {1} root tasks" -f $baselineShadows.Count, $baselineTasks.Count)

$act = New-ScheduledTaskAction -Execute 'C:\Windows\System32\notepad.exe'
$trg = New-ScheduledTaskTrigger -Daily -At (Get-Date).Date.AddHours(4)

Write-Host ('=' * 100)
Write-Host 'FIX 2 + 3: -Time parsing' -ForegroundColor Cyan

Remove-AllOurTasks
Invoke-Case F01 'FIX 2: -Time 11:00,12:00 through -File now installs both tasks' `
    -ArgLine '-Install -Time 11:00,12:00' -ExpectExit 0 -Expect 'Registered: YDK0', 'Registered: YDK1' `
    -Check {
        $problems = @()
        $names = Get-OurTasks
        if (($names -join ',') -ne 'YDK0,YDK1') { $problems += "tasks: $($names -join ',')" }
        $times = Get-TriggerTimes @('YDK0','YDK1')
        if (($times -join ',') -ne '11:00,12:00') { $problems += "trigger times: $($times -join ',')" }
        $problems
    }

Remove-AllOurTasks
Invoke-Case F02 'FIX 3: an invalid time in the list registers nothing at all' `
    -ArgLine '-Install -Time 10:00,xx,16:00' -ExpectExit 2 -Expect "Invalid time: 'xx'" `
    -Check { $n = Get-OurTasks; if ($n.Count) { "these tasks were registered anyway: $($n -join ',')" } }

Invoke-Case F03 'FIX 3: a bad time at the very end still registers nothing' `
    -ArgLine '-Install -Time 10:00,13:00,99:99' -ExpectExit 2 -Expect 'Invalid time' `
    -Check { $n = Get-OurTasks; if ($n.Count) { "these tasks were registered anyway: $($n -join ',')" } }

Write-Host ('=' * 100)
Write-Host 'FIX 4: no orphan tasks are left behind' -ForegroundColor Cyan

Invoke-Case F04 'Install with three times' -ArgLine '-Install -Time 10:00,13:00,16:00' -ExpectExit 0 `
    -Check { $n = Get-OurTasks; if (($n -join ',') -ne 'YDK0,YDK1,YDK2') { "tasks: $($n -join ',')" } }

Invoke-Case F05 'FIX 4: installing with two times removes YDK2' `
    -ArgLine '-Install -Time 08:00,20:00' -ExpectExit 0 -Expect 'Removed existing task' `
    -Check {
        $problems = @()
        $n = Get-OurTasks
        if (($n -join ',') -ne 'YDK0,YDK1') { $problems += "tasks: $($n -join ',') (YDK2 should be gone)" }
        $times = Get-TriggerTimes @('YDK0','YDK1')
        if (($times -join ',') -ne '08:00,20:00') { $problems += "trigger times: $($times -join ',')" }
        $problems
    }

Invoke-Case F06 'FIX 4: -Install -WhatIf must NOT remove the installed tasks' `
    -ArgLine '-Install -Time 09:00 -WhatIf' -ExpectExit 0 `
    -Check {
        $problems = @()
        $n = Get-OurTasks
        if (($n -join ',') -ne 'YDK0,YDK1') { $problems += "WhatIf changed the task list: $($n -join ',')" }
        $times = Get-TriggerTimes @('YDK0','YDK1')
        if (($times -join ',') -ne '08:00,20:00') { $problems += "WhatIf changed the trigger times: $($times -join ',')" }
        $problems
    }

Write-Host ('=' * 100)
Write-Host 'Uninstall safety after the install rewrite' -ForegroundColor Cyan

Register-ScheduledTask -TaskName 'YDK7'   -Action $act -Trigger $trg -Description 'Not ours - decoy' -Force | Out-Null
Register-ScheduledTask -TaskName 'YDKfoo' -Action $act -Trigger $trg -Description 'YDK daily VSS snapshot (decoy)' -Force | Out-Null
Register-ScheduledTask -TaskName 'YDK8'   -TaskPath '\YdkTestFolder\' -Action $act -Trigger $trg -Description 'YDK daily VSS snapshot (wrong folder)' -Force | Out-Null

Invoke-Case F07 'Re-installing next to decoys leaves the decoys alone' `
    -ArgLine '-Install -Time 10:00,13:00' -ExpectExit 0 `
    -Check {
        $problems = @()
        if (-not (Get-ScheduledTask -TaskName 'YDK7' -TaskPath '\' -ErrorAction SilentlyContinue))   { $problems += 'the YDK7 decoy was deleted by -Install' }
        if (-not (Get-ScheduledTask -TaskName 'YDKfoo' -TaskPath '\' -ErrorAction SilentlyContinue)) { $problems += 'the YDKfoo decoy was deleted by -Install' }
        if (-not (Get-ScheduledTask -TaskName 'YDK8' -TaskPath '\YdkTestFolder\' -ErrorAction SilentlyContinue)) { $problems += 'the sub-folder decoy was deleted by -Install' }
        $problems
    }

Invoke-Case F08 '-Uninstall still removes only our tasks' -ArgLine '-Uninstall' -ExpectExit 0 `
    -Expect 'Deleted: YDK0', 'Deleted: YDK1' `
    -Check {
        $problems = @()
        if (Get-ScheduledTask -TaskName 'YDK0' -TaskPath '\' -ErrorAction SilentlyContinue) { $problems += 'YDK0 was not deleted' }
        if (-not (Get-ScheduledTask -TaskName 'YDK7' -TaskPath '\' -ErrorAction SilentlyContinue))   { $problems += 'the YDK7 decoy was deleted' }
        if (-not (Get-ScheduledTask -TaskName 'YDKfoo' -TaskPath '\' -ErrorAction SilentlyContinue)) { $problems += 'the YDKfoo decoy was deleted' }
        if (-not (Get-ScheduledTask -TaskName 'YDK8' -TaskPath '\YdkTestFolder\' -ErrorAction SilentlyContinue)) { $problems += 'the sub-folder decoy was deleted' }
        $problems
    }

# a foreign task occupying the name we are about to register
Register-ScheduledTask -TaskName 'YDK0' -Action $act -Trigger $trg -Description 'Foreign task holding the name' -Force | Out-Null
Invoke-Case F09 'A foreign task with the same name is overwritten, with a warning' `
    -ArgLine '-Install -Time 10:00' -ExpectExit 0 -Expect 'it will be re-registered' `
    -Check {
        $t = Get-ScheduledTask -TaskName 'YDK0' -TaskPath '\' -ErrorAction SilentlyContinue
        if (-not $t) { 'YDK0 is missing' }
        elseif ($t.Description -notlike 'YDK daily VSS snapshot*') { "description: $($t.Description)" }
    }

Write-Host ('=' * 100)
Write-Host 'FIX 5 + 6: empty prefix / empty lists' -ForegroundColor Cyan

Register-ScheduledTask -TaskName '99' -Action $act -Trigger $trg -Description 'Foreign numeric task' -Force | Out-Null

Invoke-Case F10 'FIX 5: -Uninstall -TaskPrefix "" -> clean error, exit 2' `
    -ArgLine '-Uninstall -TaskPrefix ""' -ExpectExit 2 -Expect 'task prefix cannot be empty' `
    -NotExpect 'Cannot bind argument' `
    -Check {
        $problems = @()
        if (-not (Get-ScheduledTask -TaskName '99' -TaskPath '\' -ErrorAction SilentlyContinue))   { $problems += 'DANGER: the foreign task 99 was deleted' }
        if (-not (Get-ScheduledTask -TaskName 'YDK0' -TaskPath '\' -ErrorAction SilentlyContinue)) { $problems += 'YDK0 was deleted' }
        $problems
    }

Invoke-Case F11 'FIX 5: -Status -TaskPrefix "" -> clean error, exit 2' `
    -ArgLine '-Status -TaskPrefix ""' -ExpectExit 2 -Expect 'task prefix cannot be empty' -NotExpect 'Cannot bind argument'

Invoke-Case F12 'FIX 5: -TaskPrefix "   " (whitespace only)' `
    -ArgLine '-Uninstall -TaskPrefix "   "' -ExpectExit 2 -Expect 'task prefix cannot be empty'

Invoke-Case F13 'FIX 6: -Install -Volume "" -> clean error, exit 2' `
    -ArgLine '-Install -Volume ""' -ExpectExit 2 -Expect 'volume list is empty' -NotExpect 'Cannot bind argument' `
    -Check { if (-not (Get-ScheduledTask -TaskName 'YDK0' -TaskPath '\' -ErrorAction SilentlyContinue)) { 'the existing YDK0 was removed by a failed install' } }

Invoke-Case F14 'FIX 6: -Install -Time "" -> clean error, exit 2' `
    -ArgLine '-Install -Time ""' -ExpectExit 2 -Expect 'time list is empty'

Invoke-Case F15 'FIX 6: -Install -Time ",,," -> clean error, exit 2' `
    -ArgLine '-Install -Time ",,,"' -ExpectExit 2 -Expect 'time list is empty'

Remove-TaskIfPresent -Name '99' | Out-Null

Write-Host ('=' * 100)
Write-Host 'FIX 1 + 8: -Status with a trigger-less task' -ForegroundColor Cyan

Remove-AllOurTasks
Invoke-Case F16 'Install for the status test' -ArgLine '-Install -Time 10:00,13:00' -ExpectExit 0
Register-ScheduledTask -TaskName 'YDK5' -Action $act -Description 'YDK daily VSS snapshot (no trigger)' -Force | Out-Null

Invoke-Case F17 'FIX 1: -Status no longer crashes on a trigger-less task' -ArgLine '-Status' `
    -NotExpect 'Cannot index into a null array', 'You cannot call a method on a null-valued expression' `
    -Expect 'YDK5', 'has no trigger' `
    -Check {
        $out = Get-Content (Join-Path $script:OutDir 'F17.out.txt') -Raw -ErrorAction SilentlyContinue
        Write-Host '        ---- status output ----'
        Write-Host $out
        $null
    }

Invoke-Case F18 '-Uninstall removes the trigger-less task too' -ArgLine '-Uninstall' -ExpectExit 0 `
    -Check { if (Get-ScheduledTask -TaskName 'YDK5' -TaskPath '\' -ErrorAction SilentlyContinue) { 'YDK5 is still there' } }

Write-Host ('=' * 100)
Write-Host 'FIX 7: log folder that cannot be created' -ForegroundColor Cyan

Invoke-Case F19 'FIX 7: -LogPath on a drive that does not exist -> clean error, exit 2' `
    -ArgLine '-Volume C -LogPath "Q:\nope\ydk.log"' -ExpectExit 2 -Expect 'Could not create the log folder' `
    -NotExpect 'New-Item :'

Invoke-Case F20 'A usable -LogPath still works' `
    -ArgLine ('-Volume C -LogPath "{0}"' -f (Join-Path $work 'ok\deep\ydk.log')) -ExpectExit 0 `
    -Check { if (-not (Test-Path (Join-Path $work 'ok\deep\ydk.log'))) { 'log file was not created' } }

Write-Host ('=' * 100)
Write-Host 'End-to-end sanity run' -ForegroundColor Cyan

Invoke-Case F21 'Install -> run the task -> status -> uninstall' -ArgLine '-Install -Time 23:50' -ExpectExit 0
Start-ScheduledTask -TaskName 'YDK0' -TaskPath '\'
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 180 -and (Get-ScheduledTask -TaskName 'YDK0' -TaskPath '\').State -eq 'Running') { Start-Sleep -Milliseconds 500 }
Start-Sleep -Seconds 1
$info = Get-ScheduledTaskInfo -TaskName 'YDK0' -TaskPath '\'
$logToday = Join-Path 'C:\Program Files\YDK\Logs' ("ydk-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
$tail = if (Test-Path $logToday) { Get-Content $logToday -Tail 20 | Out-String } else { '' }
$prob = @()
if ($info.LastTaskResult -ne 0)               { $prob += "LastTaskResult = $($info.LastTaskResult)" }
if ($tail -notmatch 'Requested volumes: C, D') { $prob += 'the comma-separated volume list was not parsed' }
if ($tail -notmatch 'snapshot created')        { $prob += 'the task created no snapshot' }
Add-Result 'F22' 'The scheduled task still runs correctly as SYSTEM' $(if ($prob) { 'FAIL' } else { 'PASS' }) ($prob -join ' | ') $tail

Invoke-Case F23 '-Status on the healthy machine' -ArgLine '-Status' -ExpectExit 0 -Expect 'No problems found'
Invoke-Case F24 'Final -Uninstall' -ArgLine '-Uninstall' -ExpectExit 0 -Expect 'Deleted: YDK0'

Write-Host ('=' * 100)
Write-Host 'RESTORING THE MACHINE' -ForegroundColor Cyan

Remove-AllOurTasks
foreach ($n in @('YDK5','YDK7','YDKfoo','99')) { if (Remove-TaskIfPresent -Name $n) { Write-Host "  decoy removed: $n" } }
if (Remove-TaskIfPresent -Name 'YDK8' -Path '\YdkTestFolder\') { Write-Host '  decoy removed: \YdkTestFolder\YDK8' }
try { $s = New-Object -ComObject 'Schedule.Service'; $s.Connect(); $s.GetFolder('\').DeleteFolder('YdkTestFolder', 0) } catch { }

$created = @((Get-ShadowIds) | Where-Object { $baselineShadows -notcontains $_ })
$n = 0
foreach ($s in @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue)) {
    if ($created -contains $s.ID) {
        try { Remove-CimInstance -InputObject $s -ErrorAction Stop; $n++ } catch { }
    }
}
Write-Host ("  shadow copies created by this phase: {0}, deleted: {1}" -f $created.Count, $n)
Get-ChildItem 'C:\Program Files\YDK\Logs' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

$finalTasks   = @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty TaskName | Sort-Object)
$finalShadows = Get-ShadowIds
$prob = @()
$lost  = @($baselineTasks | Where-Object { $finalTasks -notcontains $_ })
$extra = @($finalTasks | Where-Object { $baselineTasks -notcontains $_ })
if ($lost.Count)  { $prob += "tasks lost: $($lost -join ',')" }
if ($extra.Count) { $prob += "tasks left behind: $($extra -join ',')" }
if (@($finalShadows | Where-Object { $baselineShadows -notcontains $_ }).Count) { $prob += 'test shadow copies left behind' }
Add-Result 'REST' 'Machine restored' $(if ($prob) { 'FAIL' } else { 'PASS' }) ($prob -join ' | ')

Write-Host ("FINAL: {0} shadow copies, root tasks {1}" -f $finalShadows.Count, $finalTasks.Count)
Write-Report -Path (Join-Path $script:TestRoot 'report-fix-regressions.json')
Stop-Transcript | Out-Null
