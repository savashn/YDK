# ---------------------------------------------------------------------------
# YDK test - phase 3 (ELEVATED)
#   re-runs the checks whose phase-2 assertions were wrong (C: volume filter,
#   exit codes of parallel runs), plus the cases phase 2 could not reach.
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $here) 'harness.ps1')

$script:OutDir = Join-Path $script:TestRoot 'out-counts-and-limits'
New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
Get-ChildItem $script:OutDir -File -ErrorAction SilentlyContinue | Remove-Item -Force

Assert-SystemTestsAllowed

Start-Transcript -Path (Join-Path $script:TestRoot 'counts-and-limits-transcript.txt') -Force | Out-Null

$idn = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal] $idn).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'PHASE3 ABORTED: not elevated.' -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 9
}

$script:SUT = 'C:\Program Files\YDK\ydk.ps1'
$work       = Join-Path $script:TestRoot 'work-counts-and-limits'
$VssKey     = 'HKLM:\SYSTEM\CurrentControlSet\Services\VSS\Settings'
$psExe      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

# --- correct helpers (phase 2 used a broken WQL filter) --------------------
$CVol = Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq 'C:' }
Write-Host ("C: device id = {0}" -f $CVol.DeviceID)
function Get-CShadows { @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue | Where-Object { $_.VolumeName -eq $CVol.DeviceID }) }
function Get-CCount   { (Get-CShadows).Count }
function Get-ShadowIds { @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ID) }
function Get-CStorage {
    Get-CimInstance Win32_ShadowStorage -ErrorAction SilentlyContinue |
        Where-Object { $_.Volume.DeviceID -eq $CVol.DeviceID } | Select-Object -First 1
}
function Get-CapGB { $s = Get-CStorage; if ($s) { [math]::Round($s.MaxSpace / 1GB, 2) } else { $null } }
function Get-YdkTaskNames {
    @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue |
      Where-Object { $_.TaskName -match '^(YDK|TEST|SPC|Yedek)\d+$' } | Select-Object -ExpandProperty TaskName | Sort-Object)
}
function Remove-AllOurTasks {
    foreach ($n in (Get-YdkTaskNames)) { Unregister-ScheduledTask -TaskName $n -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue }
}
function Remove-TaskIfPresent {
    param([string] $Name, [string] $Path = '\')
    $t = Get-ScheduledTask -TaskName $Name -TaskPath $Path -ErrorAction SilentlyContinue
    if ($t) { Unregister-ScheduledTask -TaskName $Name -TaskPath $Path -Confirm:$false; return $true }
    return $false
}

$baselineShadows = Get-ShadowIds
$baselineTasks   = @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty TaskName | Sort-Object)
$origCap         = Get-CapGB
Write-Host ("BASELINE: {0} shadow copies ({1} on C:), shadow storage cap on C: {2} GB" -f $baselineShadows.Count, (Get-CCount), $origCap)
Write-Host ("Root tasks: {0}" -f ($baselineTasks -join ', '))

# Is System Restore even turned on? (tells us whether any restore point could
# have been among the shadow copies the cleanup removed)
try {
    $sr = Get-CimInstance -Namespace 'root\default' -ClassName SystemRestoreConfig -ErrorAction Stop
    Write-Host ("SystemRestoreConfig: {0}" -f ($sr | Out-String).Trim())
} catch { Write-Host "SystemRestoreConfig could not be read: $($_.Exception.Message)" }
$srDrives = & vssadmin.exe list shadowstorage 2>&1 | Out-String
Write-Host $srDrives

# ===========================================================================
Write-Host ('=' * 100)
Write-Host 'A. Snapshot counting (redo with the correct volume filter)' -ForegroundColor Cyan

$c0 = Get-CCount
Invoke-Case A01 'One snapshot per run: -Volume C' `
    -ArgLine ('-Volume C -LogPath "{0}"' -f (Join-Path $work 'a01.log')) -ExpectExit 0 -Expect 'snapshot created' `
    -Check { $n = Get-CCount; if ($n -ne $c0 + 1) { "C: snapshot count went $c0 -> $n (expected +1)" } }

$c1 = Get-CCount
Invoke-Case A02 'Duplicate volume -Volume C,C creates two snapshots' `
    -ArgLine ('-Volume C,C -LogPath "{0}"' -f (Join-Path $work 'a02.log')) -ExpectExit 0 `
    -Check {
        $n = Get-CCount
        Write-Host ("        (info) C: snapshots $c1 -> $n")
        if ($n -ne $c1 + 2) { "expected +2 for a duplicated volume, got $($n - $c1)" }
    }

$c2 = Get-CCount
Invoke-Case A03 '-WhatIf really creates nothing' `
    -ArgLine ('-WhatIf -Volume C -LogPath "{0}"' -f (Join-Path $work 'a03.log')) -ExpectExit 0 `
    -NotExpect 'snapshot created' `
    -Check { $n = Get-CCount; if ($n -ne $c2) { "WhatIf changed the count: $c2 -> $n" } }

# The tool deletes no shadow copies at all any more; several runs in a row must
# only ever add to what is already there.
& $psExe -NoProfile -ExecutionPolicy Bypass -File $script:SUT -Volume C -LogPath (Join-Path $work 'seed.log') | Out-Null
$c3  = Get-CCount
$ids = @(Get-CShadows | Select-Object -ExpandProperty ID)
Invoke-Case A04 ("Repeated runs delete nothing (C: holds {0} snapshots)" -f $c3) `
    -ArgLine ('-Volume C -LogPath "{0}"' -f (Join-Path $work 'a04.log')) -ExpectExit 0 `
    -NotExpect 'Deleted old snapshot' `
    -Check {
        $problems = @()
        $n = Get-CCount
        if ($n -ne $c3 + 1) { $problems += "expected $($c3 + 1) snapshots on C:, found $n" }
        $now = @(Get-CShadows | Select-Object -ExpandProperty ID)
        $gone = @($ids | Where-Object { $now -notcontains $_ })
        if ($gone.Count) { $problems += "$($gone.Count) existing snapshot(s) disappeared" }
        $problems
    }

Invoke-Case A05 'The removed -KeepPerVolume option is rejected as unknown' `
    -ArgLine ('-Volume C -KeepPerVolume 1 -LogPath "{0}"' -f (Join-Path $work 'a05.log')) `
    -Expect 'A parameter cannot be found' `
    -Check {
        $n = Get-CCount
        if ($n -lt $c3 + 1) { "snapshots disappeared: $n" }
    }

# --- two runs at the same time --------------------------------------------
Write-Host '  A06: two runs at the same time...'
$sb = {
    param($ps, $sut, $log)
    & $ps -NoProfile -ExecutionPolicy Bypass -File $sut -Volume C -LogPath $log 2>&1 | Out-String
    "EXITCODE=$LASTEXITCODE"
}
$j1 = Start-Job -ScriptBlock $sb -ArgumentList $psExe, $script:SUT, (Join-Path $work 'p1.log')
$j2 = Start-Job -ScriptBlock $sb -ArgumentList $psExe, $script:SUT, (Join-Path $work 'p2.log')
$r1 = (Receive-Job -Job (Wait-Job $j1) | Out-String)
$r2 = (Receive-Job -Job (Wait-Job $j2) | Out-String)
Remove-Job $j1, $j2
$both = "$r1`n$r2"
$codes = [regex]::Matches($both, 'EXITCODE=(\d+)') | ForEach-Object { $_.Groups[1].Value }
$prob = @()
foreach ($c in $codes) { if ($c -ne '0') { $prob += "exit code $c" } }
if ($codes.Count -ne 2) { $prob += "could not read both exit codes ($($codes -join ','))" }
$note = if ($both -match 'already in progress') { 'the code 9 retry path was exercised' } else { 'VSS serialised them, no code 9' }
Add-Result 'A06' "Two snapshot runs at the same time ($note; exit codes $($codes -join ','))" `
           $(if ($prob) { 'FAIL' } else { 'PASS' }) ($prob -join ' | ') $both

# ===========================================================================
Write-Host ('=' * 100)
Write-Host 'B. -Time handling (comma-separated string vs. array)' -ForegroundColor Cyan

Remove-AllOurTasks
Invoke-Case B01 '-Time 11:00,12:00 through -File (Task Scheduler style)' -ArgLine '-Install -Time 11:00,12:00' `
    -Check {
        Write-Host ("        (info) tasks: {0}" -f ((Get-YdkTaskNames) -join ','))
        $null
    }

Remove-AllOurTasks
Invoke-Case B02 "-Time '11:00','12:00' as an array (normal prompt)" -Mode Command -ArgLine "-Install -Time '11:00','12:00'" `
    -ExpectExit 0 -Expect 'Registered: YDK0', 'Registered: YDK1'

Remove-AllOurTasks
Invoke-Case B03 '-Volume C,D through -File is split correctly (the documented workaround)' `
    -ArgLine '-Install -Volume C,D -Time 11:00' -ExpectExit 0 `
    -Check {
        $t = Get-ScheduledTask -TaskName 'YDK0' -TaskPath '\' -ErrorAction SilentlyContinue
        if (-not $t) { 'YDK0 missing' }
        elseif (@($t.Actions)[0].Arguments -notmatch '-Volume C,D') { "arguments: $(@($t.Actions)[0].Arguments)" }
    }

# ===========================================================================
Write-Host ('=' * 100)
Write-Host 'C. Uninstall safety (redo)' -ForegroundColor Cyan

$act = New-ScheduledTaskAction -Execute 'C:\Windows\System32\notepad.exe'
$trg = New-ScheduledTaskTrigger -Daily -At (Get-Date).Date.AddHours(4)
Remove-AllOurTasks
Register-ScheduledTask -TaskName 'YDK7'   -Action $act -Trigger $trg -Description 'Not ours - decoy' -Force | Out-Null
Register-ScheduledTask -TaskName 'YDKfoo' -Action $act -Trigger $trg -Description 'YDK daily VSS snapshot (decoy)' -Force | Out-Null
Register-ScheduledTask -TaskName 'YDK8'   -TaskPath '\YdkTestFolder\' -Action $act -Trigger $trg -Description 'YDK daily VSS snapshot (wrong folder)' -Force | Out-Null

Invoke-Case C01 'Install next to the decoys (Command mode)' -Mode Command -ArgLine "-Install -Time '11:00','12:00'" `
    -ExpectExit 0 -Expect 'Registered: YDK0', 'Registered: YDK1'

Invoke-Case C02 '-Uninstall -WhatIf deletes nothing' -ArgLine '-Uninstall -WhatIf' -ExpectExit 0 `
    -Check {
        $problems = @()
        foreach ($n in @('YDK0','YDK1','YDK7','YDKfoo')) {
            if (-not (Get-ScheduledTask -TaskName $n -TaskPath '\' -ErrorAction SilentlyContinue)) { $problems += "$n was deleted by -WhatIf" }
        }
        $problems
    }

Invoke-Case C03 '-Uninstall removes YDK0/YDK1 only; decoys survive' -ArgLine '-Uninstall' -ExpectExit 0 `
    -Expect 'Deleted: YDK0', 'Deleted: YDK1' `
    -Check {
        $problems = @()
        foreach ($n in @('YDK0','YDK1')) {
            if (Get-ScheduledTask -TaskName $n -TaskPath '\' -ErrorAction SilentlyContinue) { $problems += "$n was not deleted" }
        }
        if (-not (Get-ScheduledTask -TaskName 'YDK7' -TaskPath '\' -ErrorAction SilentlyContinue))   { $problems += 'the YDK7 decoy (foreign description) was deleted' }
        if (-not (Get-ScheduledTask -TaskName 'YDKfoo' -TaskPath '\' -ErrorAction SilentlyContinue)) { $problems += 'the YDKfoo decoy was deleted' }
        if (-not (Get-ScheduledTask -TaskName 'YDK8' -TaskPath '\YdkTestFolder\' -ErrorAction SilentlyContinue)) { $problems += 'the decoy in the sub-folder was deleted' }
        $problems
    }

# empty prefix, this time with real tasks present
Invoke-Case C04 'Install a real task for the empty-prefix test' -Mode Command -ArgLine "-Install -Time '11:00'" -ExpectExit 0
Register-ScheduledTask -TaskName '99' -Action $act -Trigger $trg -Description 'Foreign numeric task' -Force | Out-Null
Invoke-Case C05 '-Uninstall -TaskPrefix "" (empty prefix)' -ArgLine '-Uninstall -TaskPrefix ""' `
    -Check {
        $problems = @()
        if (-not (Get-ScheduledTask -TaskName '99' -TaskPath '\' -ErrorAction SilentlyContinue)) { $problems += 'DANGER: the foreign task named 99 was deleted' }
        if (-not (Get-ScheduledTask -TaskName 'YDK0' -TaskPath '\' -ErrorAction SilentlyContinue)) { $problems += '(info) YDK0 was deleted' }
        $problems
    }
Invoke-Case C06 '-Status -TaskPrefix "" (empty prefix)' -ArgLine '-Status -TaskPrefix ""'

Remove-TaskIfPresent -Name '99' | Out-Null

# a task that matches but has no trigger -> Show-Status indexes Triggers[0]
Register-ScheduledTask -TaskName 'YDK5' -Action $act -Description 'YDK daily VSS snapshot (no trigger)' -Force | Out-Null
Invoke-Case C07 '-Status when a matching task has no trigger (known crash)' -ArgLine '-Status' `
    -NotExpect 'Cannot index into a null array' `
    -Check {
        if (-not (Get-ScheduledTask -TaskName 'YDK5' -TaskPath '\' -ErrorAction SilentlyContinue)) { 'the trigger-less task disappeared' }
    }
Invoke-Case C08 '-Uninstall with a trigger-less task present' -ArgLine '-Uninstall' `
    -Check {
        if (Get-ScheduledTask -TaskName 'YDK5' -TaskPath '\' -ErrorAction SilentlyContinue) { '(info) YDK5 is still there' }
    }
Remove-TaskIfPresent -Name 'YDK5' | Out-Null
Remove-TaskIfPresent -Name 'YDK7' | Out-Null
Remove-TaskIfPresent -Name 'YDKfoo' | Out-Null
Remove-TaskIfPresent -Name 'YDK8' -Path '\YdkTestFolder\' | Out-Null
try {
    $sch = New-Object -ComObject 'Schedule.Service'; $sch.Connect(); $sch.GetFolder('\').DeleteFolder('YdkTestFolder', 0)
} catch { }

# ===========================================================================
Write-Host ('=' * 100)
Write-Host 'D. VSS limits' -ForegroundColor Cyan

Remove-AllOurTasks
Write-Host ("  current cap on C: {0} GB, snapshots on C: {1}" -f (Get-CapGB), (Get-CCount))

$capBefore = Get-CapGB
$raise = [int][math]::Ceiling($capBefore) + 10
Invoke-Case D01 ("Raising the shadow storage cap: -ShadowStorageMaxSize {0}GB" -f $raise) `
    -ArgLine ('-Install -Volume C -Time 05:00 -ShadowStorageMaxSize {0}GB' -f $raise) -ExpectExit 0 `
    -Expect 'shadow storage cap' `
    -Check {
        $now = Get-CapGB
        if ($null -eq $now -or [math]::Abs($now - $raise) -gt 1.5) { "cap is $now GB, expected about $raise GB" }
    }

Invoke-Case D02 'Lowering it back warns about possible snapshot loss' `
    -ArgLine ('-Install -Volume C -Time 05:00 -ShadowStorageMaxSize {0}GB' -f [int][math]::Floor($capBefore)) -ExpectExit 0 `
    -Expect 'the cap was lowered'

Invoke-Case D03 'Percentage form: -ShadowStorageMaxSize 10%' `
    -ArgLine '-Install -Volume C -Time 05:00 -ShadowStorageMaxSize 10%' -ExpectExit 0 `
    -Expect 'shadow storage cap' `
    -Check {
        $now = Get-CapGB
        Write-Host ("        (info) cap is now {0} GB (was {1} GB at the start)" -f $now, $capBefore)
        if ($null -eq $now) { 'no shadow storage association any more' }
    }

Invoke-Case D04 'MaxShadowCopies 1: Windows drops the oldest copy by itself' `
    -ArgLine '-Install -Volume C -Time 05:00 -MaxShadowCopies 1' -ExpectExit 0 -Expect 'MaxShadowCopies' `
    -Check {
        $p = Get-ItemProperty $VssKey -Name MaxShadowCopies -ErrorAction SilentlyContinue
        if (-not $p -or $p.MaxShadowCopies -ne 1) { "registry: $(if ($p) { $p.MaxShadowCopies } else { '<none>' })" }
    }

& $psExe -NoProfile -ExecutionPolicy Bypass -File $script:SUT -Volume C -LogPath (Join-Path $work 'max1a.log') | Out-Null
$afterFirst = Get-CCount
Invoke-Case D05 'Second snapshot while the limit is 1' `
    -ArgLine ('-Volume C -LogPath "{0}"' -f (Join-Path $work 'max1b.log')) `
    -Check {
        $n = Get-CCount
        Write-Host ("        (info) C: snapshots {0} -> {1} with MaxShadowCopies = 1" -f $afterFirst, $n)
        $out = Get-Content (Join-Path $script:OutDir 'D05.out.txt') -Raw -ErrorAction SilentlyContinue
        if ($out -match 'Code 8') { Write-Host '        (info) VSS answered with code 8 (maximum reached)' -ForegroundColor Yellow }
        $null
    }

Remove-ItemProperty -Path $VssKey -Name MaxShadowCopies -Force -ErrorAction SilentlyContinue
Add-Result 'D06' 'MaxShadowCopies registry value removed (back to the Windows default of 64)' 'INFO'

# ===========================================================================
Write-Host ('=' * 100)
Write-Host 'E. Status output on a healthy machine' -ForegroundColor Cyan

Remove-AllOurTasks
Invoke-Case E01 'Install + fresh snapshot, then -Status' -Mode Command -ArgLine "-Install -Time '10:00','13:00','16:00'" -ExpectExit 0
& $psExe -NoProfile -ExecutionPolicy Bypass -File $script:SUT -Volume C | Out-Null
Invoke-Case E02 '-Status on a healthy machine' -ArgLine '-Status' `
    -Expect 'YDK0', 'copies   oldest', 'storage .* GB used of', 'MaxShadowCopies per volume', 'Logs' `
    -Check {
        $out = Get-Content (Join-Path $script:OutDir 'E02.out.txt') -Raw -ErrorAction SilentlyContinue
        Write-Host '        ---- status output ----'
        Write-Host $out
        $null
    }

# ===========================================================================
Write-Host ('=' * 100)
Write-Host 'F. RESTORING THE MACHINE' -ForegroundColor Cyan

Remove-AllOurTasks
foreach ($n in @('YDK5','YDK7','YDKfoo','99')) { if (Remove-TaskIfPresent -Name $n) { Write-Host "  decoy removed: $n" } }
Remove-ItemProperty -Path $VssKey -Name MaxShadowCopies -Force -ErrorAction SilentlyContinue

$created = @((Get-ShadowIds) | Where-Object { $baselineShadows -notcontains $_ })
$n = 0
foreach ($s in @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue)) {
    if ($created -contains $s.ID) {
        try { Remove-CimInstance -InputObject $s -ErrorAction Stop; $n++ } catch { Write-Host "  could not delete $($s.ID)" -ForegroundColor Yellow }
    }
}
Write-Host ("  shadow copies created by this phase: {0}, deleted: {1}" -f $created.Count, $n)

# put the shadow storage cap back to what it was (10% of the volume)
$capNow = Get-CapGB
if ($null -ne $origCap -and $null -ne $capNow -and [math]::Abs($capNow - $origCap) -gt 0.5) {
    & vssadmin.exe resize shadowstorage /For=C: /On=C: /MaxSize=10% | Out-Null
    Write-Host ("  cap restored: {0} GB -> {1} GB" -f $capNow, (Get-CapGB))
}

Get-ChildItem 'C:\Program Files\YDK\Logs' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

$finalTasks   = @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty TaskName | Sort-Object)
$finalShadows = Get-ShadowIds
$prob = @()
$lostTasks  = @($baselineTasks | Where-Object { $finalTasks -notcontains $_ })
$extraTasks = @($finalTasks | Where-Object { $baselineTasks -notcontains $_ })
if ($lostTasks.Count)  { $prob += "tasks lost: $($lostTasks -join ',')" }
if ($extraTasks.Count) { $prob += "tasks left behind: $($extraTasks -join ',')" }
if (@($finalShadows | Where-Object { $baselineShadows -notcontains $_ }).Count) { $prob += 'test shadow copies left behind' }
if (Get-ItemProperty $VssKey -Name MaxShadowCopies -ErrorAction SilentlyContinue) { $prob += 'MaxShadowCopies is still set' }
$capEnd = Get-CapGB
if ($null -ne $origCap -and $null -ne $capEnd -and [math]::Abs($capEnd - $origCap) -gt 0.5) { $prob += "shadow storage cap is $capEnd GB, was $origCap GB" }
Add-Result 'REST' 'Machine restored (tasks, registry, shadow copies, storage cap)' $(if ($prob) { 'FAIL' } else { 'PASS' }) ($prob -join ' | ')

Write-Host ''
Write-Host ("FINAL: shadow copies {0} (C: {1}), cap {2} GB" -f $finalShadows.Count, (Get-CCount), $capEnd)
Write-Host ("Root tasks: {0}" -f ($finalTasks -join ', '))

Write-Report -Path (Join-Path $script:TestRoot 'report-counts-and-limits.json')
Stop-Transcript | Out-Null
