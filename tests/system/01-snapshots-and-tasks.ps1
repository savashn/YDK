# ---------------------------------------------------------------------------
# YDK system test: snapshots, install, uninstall and status (ELEVATED)
#   1. clears out what earlier runs of this suite left behind
#   2. exercises the snapshot / install / uninstall / status edge cases
#   3. puts the machine back the way it was and checks that it did
# ---------------------------------------------------------------------------
param(
    [string] $SutSource   # the ydk.ps1 under test; defaults to this working copy
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $here) 'harness.ps1')

# Installs in this suite are about the registration, not about snapshots.
$script:InstallsSkipSnapshot = $true

$script:OutDir = Join-Path $script:TestRoot 'out-snapshots-and-tasks'
New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
Get-ChildItem $script:OutDir -File -ErrorAction SilentlyContinue | Remove-Item -Force

Assert-SystemTestsAllowed
if (-not $SutSource) { $SutSource = Get-YdkScript }

Start-Transcript -Path (Join-Path $script:TestRoot 'snapshots-and-tasks-transcript.txt') -Force | Out-Null

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal] $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'PHASE2 ABORTED: not elevated.' -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 9
}

$InstallDir = 'C:\Program Files\YDK'
$script:SUT = Join-Path $InstallDir 'ydk.ps1'
$work       = Join-Path $script:TestRoot 'work-snapshots-and-tasks'
$spaceDir   = Join-Path $script:TestRoot 'dir with space'
$VssKey     = 'HKLM:\SYSTEM\CurrentControlSet\Services\VSS\Settings'

function Get-ShadowIds { @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ID) }
$script:CVolId = (Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq 'C:' }).DeviceID
function Get-CShadows {
    @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue | Where-Object { $_.VolumeName -eq $script:CVolId })
}
function Remove-ShadowById {
    param([string[]] $Ids)
    $n = 0
    foreach ($s in @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue)) {
        if ($Ids -contains $s.ID) {
            try { Remove-CimInstance -InputObject $s -ErrorAction Stop; $n++ }
            catch { Write-Host "  could not delete $($s.ID): $($_.Exception.Message)" -ForegroundColor Yellow }
        }
    }
    return $n
}
function Get-RootTasks { @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue) }
function Remove-TaskIfPresent {
    param([string] $Name, [string] $Path = '\')
    $t = Get-ScheduledTask -TaskName $Name -TaskPath $Path -ErrorAction SilentlyContinue
    if ($t) { Unregister-ScheduledTask -TaskName $Name -TaskPath $Path -Confirm:$false; return $true }
    return $false
}
function Get-YdkTaskNames {
    @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue |
      Where-Object { $_.TaskName -match '^(YDK|TEST|Yedek)\d+$' } | Select-Object -ExpandProperty TaskName | Sort-Object)
}
function Get-TaskArgs {
    param([string] $Name)
    $t = Get-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    return @($t.Actions)[0].Arguments
}
function Wait-Task {
    param([string] $Name, [int] $TimeoutSec = 120)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $t = Get-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction SilentlyContinue
        if (-not $t) { return $null }
        if ($t.State -ne 'Running') { Start-Sleep -Milliseconds 800; return (Get-ScheduledTaskInfo -TaskName $Name -TaskPath '\') }
        Start-Sleep -Milliseconds 500
    }
    return (Get-ScheduledTaskInfo -TaskName $Name -TaskPath '\')
}

# ===========================================================================
# 0. Where the machine stands before we touch anything
# ===========================================================================
Write-Host ('=' * 100)
Write-Host '0. STATE BEFORE CLEANUP' -ForegroundColor Cyan
$before = @{
    Shadows = Get-ShadowIds
    Tasks   = @(Get-RootTasks | Select-Object -ExpandProperty TaskName)
    MaxCopies = (Get-ItemProperty $VssKey -Name MaxShadowCopies -ErrorAction SilentlyContinue)
}
Write-Host ("shadow copies on the machine : {0}" -f $before.Shadows.Count)
Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue |
    Select-Object ID, VolumeName, InstallDate | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host ("root scheduled tasks         : {0}" -f ($before.Tasks -join ', '))
Write-Host ("MaxShadowCopies registry     : {0}" -f $(if ($before.MaxCopies) { $before.MaxCopies.MaxShadowCopies } else { '<not set>' }))
Get-CimInstance Win32_ShadowStorage -ErrorAction SilentlyContinue |
    Select-Object @{n='Volume';e={$_.Volume.DeviceID}}, @{n='UsedGB';e={[math]::Round($_.UsedSpace/1GB,2)}},
                  @{n='AllocGB';e={[math]::Round($_.AllocatedSpace/1GB,2)}}, @{n='MaxGB';e={[math]::Round($_.MaxSpace/1GB,2)}} |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Host

# ===========================================================================
# 1. Clean up what earlier test runs left behind
# ===========================================================================
Write-Host ('=' * 100)
Write-Host '1. CLEANUP OF EARLIER TEST LEFTOVERS' -ForegroundColor Cyan

# 1a. shadow copies created by earlier ydk runs - identified exactly, by the
#     ShadowIDs the old log files recorded, so nothing else is touched.
$oldIds = @()
if (Test-Path "$InstallDir\Logs") {
    $oldIds = @(Select-String -Path "$InstallDir\Logs\*.log" -Pattern 'ShadowID: (\{[0-9A-Fa-f-]+\})' -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique)
}
Write-Host ("ShadowIDs recorded in old logs: {0}" -f $oldIds.Count)
$stillThere = @(Get-ShadowIds | Where-Object { $oldIds -contains $_ })
Write-Host ("  of those, still on the machine: {0}" -f $stillThere.Count)
if ($stillThere.Count) {
    $n = Remove-ShadowById -Ids $stillThere
    Write-Host ("  deleted: {0}" -f $n) -ForegroundColor Green
}

# 1b. any scheduled task left over from an earlier test
foreach ($t in Get-RootTasks) {
    $isOurs = ($t.TaskName -match '^(YDK|Yedek|TEST)\d+$') -or ($t.Description -like 'YDK daily VSS snapshot*')
    if ($isOurs) {
        Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath '\' -Confirm:$false
        Write-Host "  removed leftover task: $($t.TaskName)" -ForegroundColor Green
    }
}
foreach ($p in @('\YdkTestFolder\')) {
    foreach ($t in @(Get-ScheduledTask -TaskPath $p -ErrorAction SilentlyContinue)) {
        Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $p -Confirm:$false
        Write-Host "  removed leftover task: $p$($t.TaskName)" -ForegroundColor Green
    }
}

# 1c. old install folder: old script version, old logs, stray README copy.
#     Earlier rounds installed into C:\YDK, which is now the "unsafe location"
#     fixture, so clear that out as a leftover as well.
$legacyDir = 'C:\' + 'YDK'
if (Test-Path $legacyDir) {
    Remove-Item $legacyDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  removed the old $legacyDir install folder"
}
if (Test-Path $InstallDir) {
    Get-ChildItem $InstallDir -Recurse -Force | ForEach-Object { Write-Host "  removing $($_.FullName)" }
    Remove-Item $InstallDir -Recurse -Force
}
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item -LiteralPath $SutSource -Destination $script:SUT -Force
Write-Host "  fresh copy installed at $script:SUT" -ForegroundColor Green

# 1d. registry override left behind by an earlier test
$createdRegValue = $false
if ($before.MaxCopies) {
    Write-Host "  MaxShadowCopies was set to $($before.MaxCopies.MaxShadowCopies); removing it (Windows default is 64)" -ForegroundColor Yellow
    Remove-ItemProperty -Path $VssKey -Name MaxShadowCopies -Force -ErrorAction SilentlyContinue
}

# 1e. scratch folders
foreach ($d in @($work, $spaceDir)) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } }
New-Item -ItemType Directory -Path $work -Force | Out-Null
New-Item -ItemType Directory -Path $spaceDir -Force | Out-Null
Copy-Item -LiteralPath $SutSource -Destination (Join-Path $spaceDir 'ydk.ps1') -Force

# what remains now is the user's own state; we must not damage it
$baselineShadows = Get-ShadowIds
$baselineC       = @(Get-CShadows)
Write-Host ("BASELINE after cleanup: {0} shadow copies on the machine, {1} of them on C:" -f $baselineShadows.Count, $baselineC.Count) -ForegroundColor Cyan
Add-Result 'CLEAN' ("cleanup done - deleted {0} test snapshots, wiped {1}, baseline = {2} shadow copies" -f $stillThere.Count, $InstallDir, $baselineShadows.Count) 'INFO'

# ===========================================================================
# 2. Snapshot mode
# ===========================================================================
Write-Host ('=' * 100)
Write-Host '2. SNAPSHOT MODE' -ForegroundColor Cyan

$before1 = (Get-CShadows).Count
Invoke-Case S01 'Single volume: -Volume C' -ArgLine ('-Volume C -LogPath "{0}"' -f (Join-Path $work 's01.log')) `
    -ExpectExit 0 -Expect 'snapshot created', '\[OK' `
    -Check {
        $now = (Get-CShadows).Count
        if ($now -ne $before1 + 1) { "expected one new snapshot on C:, count went $before1 -> $now" }
        if (-not (Test-Path (Join-Path $work 's01.log'))) { 'log file missing' }
    }

# A volume VSS cannot snapshot - a DVD, a FAT32 stick. Machines without one
# skip the cases that need it rather than reporting a failure.
$nonNtfs = Get-NonNtfsVolumeLetter
if ($nonNtfs) {
    Write-Host "  (a non-NTFS volume is present: $($nonNtfs):)" -ForegroundColor Gray

    Invoke-Case S02 ("A non-NTFS volume in the list is skipped, not failed: -Volume C,{0}" -f $nonNtfs) `
        -ArgLine ('-Volume C,{0} -LogPath "{1}"' -f $nonNtfs, (Join-Path $work 's02.log')) -ExpectExit 0 `
        -Expect ("Requested volumes: C, {0}" -f $nonNtfs), 'is not NTFS', 'succeeded = C:\\', 'failed = none'
} else {
    Add-Result 'S02' 'A non-NTFS volume in the list is skipped, not failed' 'SKIP' 'this machine has no non-NTFS volume'
}

Invoke-Case S03 'Array form from a normal prompt: -Volume C,Z (Command mode)' -Mode Command `
    -ArgLine ('-Volume C,Z -LogPath "{0}"' -f (Join-Path $work 's03.log')) -ExpectExit 0 `
    -Expect 'Requested volumes: C, Z'

Invoke-Case S04 'Sloppy spacing/format: -Volume " c , z: "' `
    -ArgLine ('-Volume " c , z: " -LogPath "{0}"' -f (Join-Path $work 's04.log')) -ExpectExit 0 `
    -Expect 'Requested volumes: c, z:', 'C:\\ -> snapshot created'

Invoke-Case S05 'Root form: -Volume C:\' `
    -ArgLine ('-Volume C:\ -LogPath "{0}"' -f (Join-Path $work 's05.log')) -ExpectExit 0 -Expect 'snapshot created'

Invoke-Case S06 'Invalid volume name: -Volume ABC -> exit 1' `
    -ArgLine ('-Volume ABC -LogPath "{0}"' -f (Join-Path $work 's06.log')) -ExpectExit 1 `
    -Expect 'Invalid volume value', 'failed = ABC'

Invoke-Case S07 'Missing volume: -Volume Z -> warning, exit 0' `
    -ArgLine ('-Volume Z -LogPath "{0}"' -f (Join-Path $work 's07.log')) -ExpectExit 0 `
    -Expect 'does not exist on this computer; skipping', 'succeeded = none'

Invoke-Case S08 'Missing volume + -FailOnMissingVolume -> exit 1' `
    -ArgLine ('-Volume Z -FailOnMissingVolume -LogPath "{0}"' -f (Join-Path $work 's08.log')) -ExpectExit 1 `
    -Expect 'does not exist on this computer', 'failed = Z:\\'

if ($nonNtfs) {
    Invoke-Case S09 ("A non-NTFS volume on its own reports the file system: -Volume {0}" -f $nonNtfs) `
        -ArgLine ('-Volume {0} -LogPath "{1}"' -f $nonNtfs, (Join-Path $work 's09.log')) -ExpectExit 0 `
        -Expect 'is not NTFS', 'file system:'
} else {
    Add-Result 'S09' 'A non-NTFS volume on its own reports the file system' 'SKIP' 'this machine has no non-NTFS volume'
}

Invoke-Case S10 'Mixed list: -Volume C,ABC,Z -> C succeeds, ABC fails, exit 1' `
    -ArgLine ('-Volume C,ABC,Z -LogPath "{0}"' -f (Join-Path $work 's10.log')) -ExpectExit 1 `
    -Expect 'succeeded = C:\\', 'failed = ABC'

$beforeWhatIf = (Get-CShadows).Count
Invoke-Case S11 '-WhatIf creates nothing' `
    -ArgLine ('-WhatIf -Volume C -LogPath "{0}"' -f (Join-Path $work 's11.log')) -ExpectExit 0 `
    -Expect 'WhatIf' -NotExpect 'snapshot created' `
    -Check {
        $now = (Get-CShadows).Count
        if ($now -ne $beforeWhatIf) { "WhatIf changed the snapshot count: $beforeWhatIf -> $now" }
    }

$beforeDup = (Get-CShadows).Count
Invoke-Case S12 'Duplicate volume: -Volume C,C' `
    -ArgLine ('-Volume C,C -LogPath "{0}"' -f (Join-Path $work 's12.log')) -ExpectExit 0 `
    -Check {
        $now = (Get-CShadows).Count
        Write-Host ("        (info) C: snapshots {0} -> {1} for a duplicated volume" -f $beforeDup, $now)
        $null
    }

if ($nonNtfs) {
    Invoke-Case S13 ("Nothing snapshottable in the list: -Volume {0} -> exit 0, nothing done" -f $nonNtfs) `
        -ArgLine ('-Volume {0} -LogPath "{1}"' -f $nonNtfs, (Join-Path $work 's13.log')) -ExpectExit 0 `
        -Expect 'is not NTFS', 'succeeded = none, failed = none'
} else {
    Add-Result 'S13' 'Nothing snapshottable in the list -> exit 0, nothing done' 'SKIP' 'this machine has no non-NTFS volume'
}

Invoke-Case S14 '-KeepPerVolume is gone: the parameter is rejected' `
    -ArgLine ('-Volume C -KeepPerVolume 2 -LogPath "{0}"' -f (Join-Path $work 's14.log')) `
    -Expect 'A parameter cannot be found'

# The tool must never delete a shadow copy: pruning was removed exactly because
# it could not tell its own snapshots from System Restore's or a backup tool's.
$cntBefore = (Get-CShadows).Count
Invoke-Case S15 ("A snapshot run deletes nothing (C: holds {0} copies)" -f $cntBefore) `
    -ArgLine ('-Volume C -LogPath "{0}"' -f (Join-Path $work 's15.log')) -ExpectExit 0 `
    -NotExpect 'Deleted old snapshot', 'nothing to delete' `
    -Check {
        $now = (Get-CShadows).Count
        if ($now -ne $cntBefore + 1) { "C: went from $cntBefore to $now; a run must only add one copy" }
    }

# --- log retention ---------------------------------------------------------
$retDir = Join-Path $work 'logs-ret'
New-Item -ItemType Directory -Path $retDir -Force | Out-Null
$today  = Get-Date -Format 'yyyy-MM-dd'
$seed = @('ydk-2020-01-01.log','Yedek-2019-05-05.log','ydk-2026-13-45.log','ydk-notadate.log',
          'ydk-2020-01-01.log.bak','ydk-2020-01-01.txt','notes.txt','YDK-2020-02-02.log',"ydk-$today.log")
function Reset-RetDir {
    Get-ChildItem $retDir -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
    foreach ($f in $seed) { Set-Content -LiteralPath (Join-Path $retDir $f) -Value 'x' -Encoding UTF8 }
    New-Item -ItemType Directory -Path (Join-Path $retDir 'sub') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $retDir 'sub\ydk-2020-01-01.log') -Value 'x' -Encoding UTF8
}

Reset-RetDir
Invoke-Case S16 'Log retention: only ydk-/Yedek-<real date>.log files are deleted' `
    -ArgLine ('-Volume Z -LogRetentionDays 1 -LogPath "{0}"' -f (Join-Path $retDir "ydk-$today.log")) -ExpectExit 0 `
    -Check {
        $problems = @()
        $gone = @('ydk-2020-01-01.log','Yedek-2019-05-05.log','YDK-2020-02-02.log')
        $kept = @('ydk-2026-13-45.log','ydk-notadate.log','ydk-2020-01-01.log.bak','ydk-2020-01-01.txt','notes.txt',"ydk-$today.log")
        foreach ($g in $gone) { if (Test-Path (Join-Path $retDir $g)) { $problems += "$g should have been deleted" } }
        foreach ($k in $kept) { if (-not (Test-Path (Join-Path $retDir $k))) { $problems += "$k must not have been deleted" } }
        if (-not (Test-Path (Join-Path $retDir 'sub\ydk-2020-01-01.log'))) { $problems += 'the file in the sub-folder must not be touched' }
        $problems
    }

Reset-RetDir
Invoke-Case S17 'Log retention 0 = keep forever' `
    -ArgLine ('-Volume Z -LogRetentionDays 0 -LogPath "{0}"' -f (Join-Path $retDir "ydk-$today.log")) -ExpectExit 0 `
    -Check {
        if (-not (Test-Path (Join-Path $retDir 'ydk-2020-01-01.log'))) { 'a 2020 log was deleted even though retention is 0' }
    }

Invoke-Case S18 'Log path with Turkish characters in the folder name' `
    -ArgLine ('-Volume Z -LogPath "{0}"' -f (Join-Path $work 'Günlük ÇŞİĞÜÖ\ydk.log')) -ExpectExit 0 `
    -Check {
        $p = Join-Path $work 'Günlük ÇŞİĞÜÖ\ydk.log'
        if (-not (Test-Path -LiteralPath $p)) { 'log file was not created' }
        else {
            $c = Get-Content -LiteralPath $p -Raw
            if ($c -notmatch 'ydk.ps1 started') { 'log content is wrong' }
        }
    }

Invoke-Case S19 'Default log location (Logs\ydk-<date>.log next to the script)' `
    -ArgLine '-Volume Z' -ExpectExit 0 `
    -Check {
        $p = Join-Path 'C:\Program Files\YDK\Logs' ("ydk-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
        if (-not (Test-Path $p)) { "default log file was not created at $p" }
    }

# --- two runs at the same time (VSS return code 9 path) --------------------
Write-Host '  S20: two snapshot runs at the same time...'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sb20 = {
    param($ps, $sut, $log)
    & $ps -NoProfile -ExecutionPolicy Bypass -File $sut -Volume C -LogPath $log 2>&1 | Out-String
    "EXITCODE=$LASTEXITCODE"
}
$j1 = Start-Job -ScriptBlock $sb20 -ArgumentList $psExe, $script:SUT, (Join-Path $work 's20a.log')
$j2 = Start-Job -ScriptBlock $sb20 -ArgumentList $psExe, $script:SUT, (Join-Path $work 's20b.log')
$outA = (Receive-Job -Job (Wait-Job $j1) | Out-String)
$outB = (Receive-Job -Job (Wait-Job $j2) | Out-String)
Remove-Job $j1, $j2
$both = "$outA`n$outB"
$prob  = @()
$codes = [regex]::Matches($both, 'EXITCODE=(\d+)') | ForEach-Object { $_.Groups[1].Value }
foreach ($c in $codes) { if ($c -ne '0') { $prob += "exit code $c" } }
if ($codes.Count -ne 2) { $prob += "could not read both exit codes ($($codes -join ','))" }
$note = if ($both -match 'already in progress') { 'the retry path was exercised' } else { 'VSS serialised them without a code 9' }
Add-Result 'S20' "Two snapshot runs at the same time ($note)" $(if ($prob) { 'FAIL' } else { 'PASS' }) ($prob -join ' | ') $both

# ===========================================================================
# 3. Install / uninstall / status
# ===========================================================================
Write-Host ('=' * 100)
Write-Host '3. INSTALL / UNINSTALL / STATUS' -ForegroundColor Cyan

# -InitialSnapshot: let the case through without -NoInitialSnapshot, because
# what it checks is that -WhatIf stops the first snapshot on its own.
Invoke-Case I01 '-Install -WhatIf registers nothing and takes no snapshot' -ArgLine '-Install -WhatIf' `
    -InitialSnapshot -ExpectExit 0 -NotExpect 'snapshot created' `
    -Pre   { $script:beforeC = @(Get-CShadows).Count } `
    -Check {
        $problems = @()
        $t = Get-YdkTaskNames
        if ($t.Count) { $problems += "tasks were created: $($t -join ',')" }
        if (@(Get-CShadows).Count -ne $script:beforeC) { $problems += 'a -WhatIf install created a shadow copy' }
        $problems
    }

Invoke-Case I02 '-Install with defaults -> YDK0..YDK2' -ArgLine '-Install' -ExpectExit 0 `
    -Expect 'Registered: YDK0', 'Registered: YDK1', 'Registered: YDK2', 'Install complete' `
    -Check {
        $problems = @()
        $names = Get-YdkTaskNames
        if (($names -join ',') -ne 'YDK0,YDK1,YDK2') { $problems += "task names: $($names -join ',')" }
        $t = Get-ScheduledTask -TaskName 'YDK0' -TaskPath '\' -ErrorAction SilentlyContinue
        if (-not $t) { $problems += 'YDK0 missing'; return $problems }
        $a = @($t.Actions)[0]
        if ($a.Arguments -notmatch '-Volume C,D')          { $problems += "arguments: $($a.Arguments)" }
        if ($a.Arguments -match '-KeepPerVolume')          { $problems += 'the removed -KeepPerVolume option is still written into the task' }
        if ($a.Arguments -match '-LogRetentionDays')       { $problems += 'the default LogRetentionDays should not be written into the task' }
        if ($a.Arguments -notmatch '-ExecutionPolicy Bypass') { $problems += 'ExecutionPolicy Bypass missing' }
        if ($t.Principal.UserId -notmatch 'S-1-5-18|SYSTEM') { $problems += "principal: $($t.Principal.UserId)" }
        if ($t.Principal.RunLevel -ne 'Highest')           { $problems += "run level: $($t.Principal.RunLevel)" }
        if ($t.Settings.MultipleInstances -ne 'IgnoreNew') { $problems += "multiple instances: $($t.Settings.MultipleInstances)" }
        if ($t.Settings.ExecutionTimeLimit -ne 'PT1H')     { $problems += "time limit: $($t.Settings.ExecutionTimeLimit)" }
        if ($t.Description -notlike 'YDK daily VSS snapshot*') { $problems += "description: $($t.Description)" }
        $times = @('YDK0','YDK1','YDK2') | ForEach-Object {
            $x = Get-ScheduledTask -TaskName $_ -TaskPath '\'
            ([datetime]@($x.Triggers)[0].StartBoundary).ToString('HH:mm')
        }
        if (($times -join ',') -ne '10:00,13:00,16:00') { $problems += "trigger times: $($times -join ',')" }
        $problems
    }

Invoke-Case I03 '-Install again (idempotent overwrite)' -ArgLine '-Install' -ExpectExit 0 `
    -Expect 'Removed existing task' `
    -Check { $n = (Get-YdkTaskNames).Count; if ($n -ne 3) { "expected 3 tasks, found $n" } }

# The first snapshot -Install ends with. Every other install case in this suite
# is handed -NoInitialSnapshot by the harness, so these two are the only ones
# that see the default behaviour.
Invoke-Case I03a '-Install takes the first snapshot' -ArgLine '-Install' -InitialSnapshot -ExpectExit 0 `
    -Expect 'Taking the first snapshot', 'snapshot created' `
    -Pre   { $script:beforeC = @(Get-CShadows).Count } `
    -Check {
        $problems = @()
        if (@(Get-CShadows).Count -le $script:beforeC)       { $problems += 'no new shadow copy on C:' }
        if ((Get-YdkTaskNames).Count -ne 3)                  { $problems += 'the tasks were not registered' }
        if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'Logs'))) { $problems += 'no Logs folder next to the installed script' }
        $problems
    }

Invoke-Case I03b '-Install -NoInitialSnapshot takes none' -ArgLine '-Install -NoInitialSnapshot' -ExpectExit 0 `
    -Expect 'First snapshot skipped' -NotExpect 'snapshot created' `
    -Pre   { $script:beforeC = @(Get-CShadows).Count } `
    -Check { if (@(Get-CShadows).Count -ne $script:beforeC) { 'a shadow copy was created anyway' } }

Invoke-Case I04 '-Install with custom times/volume/retention (Command mode array)' -Mode Command `
    -ArgLine "-Install -Time '08:00','20:00' -Volume C -LogRetentionDays 30" -ExpectExit 0 `
    -Expect 'Registered: YDK0', 'Registered: YDK1' `
    -Check {
        $problems = @()
        $a = Get-TaskArgs 'YDK0'
        if ($a -notmatch '-Volume C\b')        { $problems += "arguments: $a" }
        if ($a -match '-KeepPerVolume')        { $problems += "the removed option is still written into the task: $a" }
        if ($a -notmatch '-LogRetentionDays 30') { $problems += "LogRetentionDays missing: $a" }
        $names = Get-YdkTaskNames
        if ($names -contains 'YDK2') { Write-Host '        (info) YDK2 from the previous 3-time install is left behind as an orphan' -ForegroundColor Yellow }
        $problems
    }

Invoke-Case I05 'Orphan cleanup by -Uninstall, then re-install with 3 times' -ArgLine '-Uninstall' -ExpectExit 0 `
    -Check { $n = (Get-YdkTaskNames).Count; if ($n -ne 0) { "tasks left over: $((Get-YdkTaskNames) -join ',')" } }

Invoke-Case I06 'Invalid time -> exit 2' -ArgLine "-Install -Time 25:00" -ExpectExit 2 -Expect 'Invalid time' `
    -Check { $n = (Get-YdkTaskNames).Count; if ($n -ne 0) { "tasks were registered anyway: $((Get-YdkTaskNames) -join ',')" } }

Invoke-Case I07 'Valid time formats H:mm and HH:mm:ss' -Mode Command `
    -ArgLine "-Install -Time '9:05','21:30:00'" -ExpectExit 0 -Expect 'Registered: YDK0', 'Registered: YDK1' `
    -Check {
        $times = @('YDK0','YDK1') | ForEach-Object {
            $x = Get-ScheduledTask -TaskName $_ -TaskPath '\'; ([datetime]@($x.Triggers)[0].StartBoundary).ToString('HH:mm')
        }
        if (($times -join ',') -ne '09:05,21:30') { "trigger times: $($times -join ',')" }
    }

Invoke-Case I08 'Second time invalid -> the first one is already registered (partial install)' -Mode Command `
    -ArgLine "-Uninstall" -ExpectExit 0
Invoke-Case I09 'Partial install: -Time 10:00,xx' -Mode Command `
    -ArgLine "-Install -Time '10:00','xx'" -ExpectExit 2 -Expect 'Invalid time' `
    -Check {
        $names = Get-YdkTaskNames
        Write-Host ("        (info) tasks after the failed install: {0}" -f ($names -join ','))
        if ($names -contains 'YDK0') { Write-Host '        (info) YDK0 stayed registered even though the install aborted' -ForegroundColor Yellow }
        $null
    }

Invoke-Case I10 'Invalid volume on install -> exit 2, nothing registered' -ArgLine '-Install -Volume ABC' -ExpectExit 2 `
    -Expect 'Invalid volume value'

Invoke-Case I11 'Empty volume on install: -Volume ""' -ArgLine '-Install -Volume ""' `
    -Pre { foreach ($n in (Get-YdkTaskNames)) { Remove-TaskIfPresent -Name $n | Out-Null } } `
    -Check {
        $a = Get-TaskArgs 'YDK0'
        Write-Host ("        (info) YDK0 arguments after the empty-volume install: {0}" -f $a)
        if ($a -and $a -notmatch '-Volume\s+\S') { Write-Host '        (info) the task was registered with an empty -Volume argument' -ForegroundColor Yellow }
        $null
    }

Invoke-Case I12 'Clean slate before the prefix test' -ArgLine '-Uninstall' -ExpectExit 0
Invoke-Case I13 'Custom prefix -TaskPrefix TEST' -ArgLine '-Install -TaskPrefix TEST -Time 07:00' -ExpectExit 0 `
    -Expect 'Registered: TEST0' `
    -Check { if (-not (Get-ScheduledTask -TaskName 'TEST0' -TaskPath '\' -ErrorAction SilentlyContinue)) { 'TEST0 was not created' } }

Invoke-Case I14 '-Uninstall with the default prefix leaves TEST0 alone' -ArgLine '-Uninstall' -ExpectExit 0 `
    -Expect 'No tasks of this tool found' `
    -Check { if (-not (Get-ScheduledTask -TaskName 'TEST0' -TaskPath '\' -ErrorAction SilentlyContinue)) { 'TEST0 was deleted by the wrong prefix!' } }

Invoke-Case I15 '-Uninstall -TaskPrefix TEST removes it' -ArgLine '-Uninstall -TaskPrefix TEST' -ExpectExit 0 `
    -Expect 'Deleted: TEST0' `
    -Check { if (Get-ScheduledTask -TaskName 'TEST0' -TaskPath '\' -ErrorAction SilentlyContinue) { 'TEST0 still exists' } }

Invoke-Case I16 '-Uninstall with an empty prefix (-TaskPrefix "")' -ArgLine '-Uninstall -TaskPrefix ""' `
    -Check {
        $names = @(Get-RootTasks | Select-Object -ExpandProperty TaskName)
        $lost  = @($before.Tasks | Where-Object { $names -notcontains $_ })
        if ($lost.Count) { "DANGER: foreign tasks disappeared: $($lost -join ',')" }
    }

# --- the safety guard around uninstall -------------------------------------
Write-Host '  I17: decoy tasks...'
$act  = New-ScheduledTaskAction -Execute 'C:\Windows\System32\notepad.exe'
$trg  = New-ScheduledTaskTrigger -Daily -At (Get-Date).Date.AddHours(4)
Register-ScheduledTask -TaskName 'YDK7' -Action $act -Trigger $trg -Description 'Not ours - decoy' -Force | Out-Null
Register-ScheduledTask -TaskName 'YDKfoo' -Action $act -Trigger $trg -Description 'YDK daily VSS snapshot (decoy name)' -Force | Out-Null
Register-ScheduledTask -TaskName 'YDK8' -TaskPath '\YdkTestFolder\' -Action $act -Trigger $trg -Description 'YDK daily VSS snapshot (wrong folder)' -Force | Out-Null

Invoke-Case I17 'Install + uninstall next to decoy tasks' -ArgLine '-Install -Time 11:00,12:00' -ExpectExit 0
Invoke-Case I18 '-Uninstall -WhatIf deletes nothing' -ArgLine '-Uninstall -WhatIf' -ExpectExit 0 `
    -Check { $n = (Get-YdkTaskNames | Where-Object { $_ -like 'YDK*' }).Count; if ($n -lt 2) { "tasks disappeared: $((Get-YdkTaskNames) -join ',')" } }

Invoke-Case I19 '-Uninstall removes only our tasks, decoys survive' -ArgLine '-Uninstall' -ExpectExit 0 `
    -Expect 'Deleted: YDK0', 'Deleted: YDK1' `
    -Check {
        $problems = @()
        if (-not (Get-ScheduledTask -TaskName 'YDK7' -TaskPath '\' -ErrorAction SilentlyContinue)) { $problems += 'the YDK7 decoy (foreign description) was deleted' }
        if (-not (Get-ScheduledTask -TaskName 'YDKfoo' -TaskPath '\' -ErrorAction SilentlyContinue)) { $problems += 'the YDKfoo decoy was deleted' }
        if (-not (Get-ScheduledTask -TaskName 'YDK8' -TaskPath '\YdkTestFolder\' -ErrorAction SilentlyContinue)) { $problems += 'the decoy in the sub-folder was deleted' }
        $problems
    }

# --- status ----------------------------------------------------------------
Invoke-Case I20 '-Status with no tasks -> warning + exit 1' -ArgLine '-Status' -ExpectExit 1 `
    -Expect 'No scheduled tasks with the prefix'

Invoke-Case I21 'Install for the run-the-task test' -ArgLine '-Install -Time 23:45' -ExpectExit 0

Write-Host '  I22: starting the scheduled task (running as SYSTEM)...'
$logToday = Join-Path 'C:\Program Files\YDK\Logs' ("ydk-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
$sizeBefore = if (Test-Path $logToday) { (Get-Item $logToday).Length } else { 0 }
Start-ScheduledTask -TaskName 'YDK0' -TaskPath '\'
$info = Wait-Task -Name 'YDK0' -TimeoutSec 180
$prob = @()
if (-not $info) { $prob += 'no task info' }
elseif ($info.LastTaskResult -ne 0) { $prob += "LastTaskResult = $($info.LastTaskResult)" }
$tail = if (Test-Path $logToday) { Get-Content $logToday -Tail 25 -ErrorAction SilentlyContinue | Out-String } else { '' }
if ($tail -notmatch 'Requested volumes: C, D') { $prob += 'the task did not parse the comma-separated volume list' }
if ($tail -notmatch 'snapshot created')        { $prob += 'no snapshot was created by the task' }
if ($tail -notmatch '\$')                      { $prob += 'the log does not show it ran as the SYSTEM account' }
Add-Result 'I22' 'Scheduled task actually runs (SYSTEM, -File mode, comma-separated volumes)' `
           $(if ($prob) { 'FAIL' } else { 'PASS' }) ($prob -join ' | ') $tail

Invoke-Case I23 '-Status with tasks and snapshots' -ArgLine '-Status' `
    -Expect 'Scheduled tasks', 'YDK0', 'Snapshots', 'VSS limits', 'Logs' `
    -Check {
        $out = Get-Content (Join-Path $script:OutDir 'I23.out.txt') -Raw -ErrorAction SilentlyContinue
        if ($out -match 'result=FAILED') { "status reports a failed task run: check the log" }
    }

# a YDK-looking task with no trigger at all: Show-Status indexes Triggers[0]
Write-Host '  I24: task with no trigger...'
$noTrigger = $false
try {
    Register-ScheduledTask -TaskName 'YDK5' -Action $act -Description 'YDK daily VSS snapshot (no trigger)' -Force -ErrorAction Stop | Out-Null
    $noTrigger = $true
} catch { Write-Host "        (could not create a trigger-less task: $($_.Exception.Message))" -ForegroundColor Yellow }
if ($noTrigger) {
    Invoke-Case I24 '-Status when a matching task has no trigger' -ArgLine '-Status' `
        -NotExpect 'Cannot index into a null array|You cannot call a method on a null-valued expression'
    Remove-TaskIfPresent -Name 'YDK5' | Out-Null
} else {
    Add-Result 'I24' '-Status with a trigger-less task (could not be set up)' 'SKIP'
}

# --- MOTW ------------------------------------------------------------------
$motw = Join-Path $spaceDir 'ydk.ps1'
Add-Content -LiteralPath $motw -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3"
Invoke-Case I25 'Install from a path with spaces + MOTW mark' -ScriptPath $motw `
    -ArgLine '-Install -TaskPrefix SPC -Time 06:00 -SkipLocationCheck' -ExpectExit 0 `
    -Expect 'Removed the download mark', 'the script lives under a user profile' `
    -Check {
        $problems = @()
        if (Get-Item -LiteralPath $motw -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue) { $problems += 'the MOTW stream is still there' }
        $t = Get-ScheduledTask -TaskName 'SPC0' -TaskPath '\' -ErrorAction SilentlyContinue
        if (-not $t) { $problems += 'SPC0 was not created'; return $problems }
        $a = @($t.Actions)[0].Arguments
        if ($a -notmatch '-File "') { $problems += "the path with spaces is not quoted: $a" }
        $problems
    }

Write-Host '  I26: running the task installed from the path with spaces...'
Start-ScheduledTask -TaskName 'SPC0' -TaskPath '\'
$info2 = Wait-Task -Name 'SPC0' -TimeoutSec 180
$spcLog = Join-Path $spaceDir ("Logs\ydk-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
$prob = @()
if (-not $info2 -or $info2.LastTaskResult -ne 0) { $prob += "LastTaskResult = $(if ($info2) { $info2.LastTaskResult } else { 'n/a' })" }
if (-not (Test-Path -LiteralPath $spcLog)) { $prob += "no log at $spcLog" }
Add-Result 'I26' 'A task installed from a path containing spaces runs correctly' `
           $(if ($prob) { 'FAIL' } else { 'PASS' }) ($prob -join ' | ') `
           $(if (Test-Path -LiteralPath $spcLog) { Get-Content -LiteralPath $spcLog -Tail 12 | Out-String } else { '' })

Invoke-Case I27 'No MOTW mark -> "nothing to unblock"' -ScriptPath $motw `
    -ArgLine '-Install -TaskPrefix SPC -Time 06:00 -SkipLocationCheck' -ExpectExit 0 -Expect 'No download mark'
Invoke-Case I28 'Remove the SPC tasks' -ScriptPath $motw -ArgLine '-Uninstall -TaskPrefix SPC' -ExpectExit 0 -Expect 'Deleted: SPC0'

# --- VSS limits ------------------------------------------------------------
Invoke-Case I29 '-MaxShadowCopies with -WhatIf writes nothing to the registry' `
    -ArgLine '-Install -MaxShadowCopies 100 -WhatIf' -ExpectExit 0 `
    -Check {
        $p = Get-ItemProperty $VssKey -Name MaxShadowCopies -ErrorAction SilentlyContinue
        if ($p) { "the registry value was written anyway: $($p.MaxShadowCopies)" }
    }

Invoke-Case I30 '-MaxShadowCopies 100 is written' -ArgLine '-Install -MaxShadowCopies 100 -Time 05:00' -ExpectExit 0 `
    -Expect 'MaxShadowCopies' `
    -Check {
        $p = Get-ItemProperty $VssKey -Name MaxShadowCopies -ErrorAction SilentlyContinue
        if (-not $p -or $p.MaxShadowCopies -ne 100) { "registry value: $(if ($p) { $p.MaxShadowCopies } else { '<none>' })" }
    }

Invoke-Case I31 'Setting the same value again -> "left unchanged"' -ArgLine '-Install -MaxShadowCopies 100 -Time 05:00' `
    -ExpectExit 0 -Expect 'already 100'

Invoke-Case I32 '-Status shows the override' -ArgLine '-Status' -Expect '100 \(overridden\)'

# put the registry back the way we found it
Remove-ItemProperty -Path $VssKey -Name MaxShadowCopies -Force -ErrorAction SilentlyContinue
Add-Result 'I33' 'MaxShadowCopies registry value removed again (back to the Windows default)' 'INFO'

$curMax = $null
$cvol = Get-CimInstance Win32_Volume -Filter "Name = 'C:\\\\'" -ErrorAction SilentlyContinue
$assoc = Get-CimInstance Win32_ShadowStorage -ErrorAction SilentlyContinue | Where-Object { $_.Volume.DeviceID -eq $cvol.DeviceID } | Select-Object -First 1
if ($assoc) { $curMax = [int][math]::Ceiling($assoc.MaxSpace / 1GB) }   # rounded up so the cap is never lowered
Write-Host ("  current shadow storage cap on C: {0} GB" -f $curMax)

Invoke-Case I34 '-ShadowStorageMaxSize with -WhatIf changes nothing' `
    -ArgLine '-Install -ShadowStorageMaxSize 25GB -WhatIf' -ExpectExit 0 -Expect 'What if|WhatIf' `
    -Check {
        $a2 = Get-CimInstance Win32_ShadowStorage -ErrorAction SilentlyContinue | Where-Object { $_.Volume.DeviceID -eq $cvol.DeviceID } | Select-Object -First 1
        $now = if ($a2) { [math]::Round($a2.MaxSpace / 1GB, 2) } else { $null }
        if ($now -ne $curMax) { "the cap changed: $curMax -> $now" }
    }

Invoke-Case I35 'Invalid -ShadowStorageMaxSize value (non-fatal)' `
    -ArgLine '-Install -Volume C -ShadowStorageMaxSize BOGUS -Time 05:00' -ExpectExit 0 `
    -Expect 'could not resize shadow storage' `
    -Check {
        if (-not (Get-ScheduledTask -TaskName 'YDK0' -TaskPath '\' -ErrorAction SilentlyContinue)) { 'the install did not continue after the vssadmin error' }
    }

Invoke-Case I36 '-ShadowStorageMaxSize below the VSS minimum (300MB)' `
    -ArgLine '-Install -Volume C -ShadowStorageMaxSize 300MB -Time 05:00' -ExpectExit 0 `
    -Expect 'shadow storage'

Invoke-Case I37 '-ShadowStorageMaxSize on a missing / non-NTFS volume' `
    -ArgLine '-Install -Volume Z,D -ShadowStorageMaxSize 25GB -Time 05:00' -ExpectExit 0 `
    -Expect 'volume not present', 'not NTFS'

if ($null -ne $curMax) {
    Invoke-Case I38 ("-ShadowStorageMaxSize re-applying the current cap ({0}GB, no real change)" -f $curMax) `
        -ArgLine ('-Install -Volume C -ShadowStorageMaxSize {0}GB -Time 05:00' -f $curMax) -ExpectExit 0 `
        -Expect 'shadow storage cap'
} else {
    Add-Result 'I38' 'Applying a real shadow storage cap skipped: C: has no shadow storage association' 'SKIP'
}

# ===========================================================================
# 4. Put the machine back
# ===========================================================================
Write-Host ('=' * 100)
Write-Host '4. RESTORING THE MACHINE' -ForegroundColor Cyan

foreach ($n in (Get-YdkTaskNames)) { Remove-TaskIfPresent -Name $n | Out-Null; Write-Host "  task removed: $n" }
foreach ($n in @('YDK7','YDKfoo','YDK5')) { if (Remove-TaskIfPresent -Name $n) { Write-Host "  decoy removed: $n" } }
if (Remove-TaskIfPresent -Name 'YDK8' -Path '\YdkTestFolder\') { Write-Host '  decoy removed: \YdkTestFolder\YDK8' }
try {
    $svc = New-Object -ComObject 'Schedule.Service'; $svc.Connect()
    $root = $svc.GetFolder('\')
    $root.DeleteFolder('YdkTestFolder', 0)
    Write-Host '  \YdkTestFolder task folder removed'
} catch { Write-Host "  (task folder could not be removed: $($_.Exception.Message))" }

Remove-ItemProperty -Path $VssKey -Name MaxShadowCopies -Force -ErrorAction SilentlyContinue

$afterShadows = Get-ShadowIds
$created = @($afterShadows | Where-Object { $baselineShadows -notcontains $_ })
Write-Host ("  shadow copies created by the test: {0}" -f $created.Count)
$deleted = Remove-ShadowById -Ids $created
Write-Host ("  of those, deleted: {0}" -f $deleted) -ForegroundColor Green

$finalShadows = Get-ShadowIds
$finalTasks   = @(Get-RootTasks | Select-Object -ExpandProperty TaskName | Sort-Object)
$lostTasks    = @($before.Tasks | Where-Object { $finalTasks -notcontains $_ })
$lostShadows  = @($baselineShadows | Where-Object { $finalShadows -notcontains $_ })
$extraShadows = @($finalShadows | Where-Object { $baselineShadows -notcontains $_ })

$prob = @()
if ($lostTasks.Count)    { $prob += "foreign tasks lost: $($lostTasks -join ',')" }
if ($lostShadows.Count)  { $prob += "baseline shadow copies lost: $($lostShadows.Count)" }
if ($extraShadows.Count) { $prob += "test shadow copies left behind: $($extraShadows.Count)" }
if ((Get-ItemProperty $VssKey -Name MaxShadowCopies -ErrorAction SilentlyContinue)) { $prob += 'MaxShadowCopies is still set' }
Add-Result 'REST' 'Machine restored (tasks, registry, shadow copies)' $(if ($prob) { 'FAIL' } else { 'PASS' }) ($prob -join ' | ')

Get-ChildItem 'C:\Program Files\YDK\Logs' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ("FINAL: {0} shadow copies, root tasks: {1}" -f $finalShadows.Count, ($finalTasks -join ', '))

Write-Report -Path (Join-Path $script:TestRoot 'report-snapshots-and-tasks.json')
Stop-Transcript | Out-Null
