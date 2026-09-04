# ---------------------------------------------------------------------------
# YDK test - phase 6 (ELEVATED): environment edge cases
#   a second NTFS volume (VHD), a FAT32 volume, a subst drive, VSS left
#   Disabled, a locked log file, task/prefix/path oddities.
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $here) 'harness.ps1')

$script:OutDir = Join-Path $script:TestRoot 'out-environment'
New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
Get-ChildItem $script:OutDir -File -ErrorAction SilentlyContinue | Remove-Item -Force

Assert-SystemTestsAllowed

Start-Transcript -Path (Join-Path $script:TestRoot 'environment-transcript.txt') -Force | Out-Null

$idn = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal] $idn).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'PHASE6 ABORTED: not elevated.' -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 9
}

$script:SUT = 'C:\Program Files\YDK\ydk.ps1'
$work   = Join-Path $script:TestRoot 'work-environment'
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$VssKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\VSS\Settings'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

function Get-Vol { param([string] $Letter) Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq $Letter } }
function Get-ShadowsOf {
    param([string] $Letter)
    $v = Get-Vol $Letter
    if (-not $v) { return @() }
    @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue | Where-Object { $_.VolumeName -eq $v.DeviceID })
}
function Get-ShadowIds { @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ID) }
function Get-OurTasks {
    @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue |
      Where-Object { $_.TaskName -match '^(YDK|Y\+K|İZ|TEST)' } | Select-Object -ExpandProperty TaskName | Sort-Object)
}
function Remove-AllOurTasks {
    foreach ($n in (Get-OurTasks)) { Unregister-ScheduledTask -TaskName $n -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue }
}

$baselineShadows = Get-ShadowIds
$baselineTasks   = @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty TaskName | Sort-Object)
$vssOrig    = (Get-Service VSS).StartType
$swprvOrig  = (Get-Service swprv).StartType
Write-Host ("BASELINE: {0} shadow copies, {1} tasks, VSS start type {2}" -f $baselineShadows.Count, $baselineTasks.Count, $vssOrig)

$vhd = Join-Path $work 'ydk-test.vhd'
$vhdAttached = $false

try {
    # =======================================================================
    Write-Host ('=' * 100)
    Write-Host 'A. A second NTFS volume (VHD mounted as Y:)' -ForegroundColor Cyan

    # Y: has to be free: if something is already mounted there, the diskpart
    # script below would leave it alone and the suite would then take snapshots
    # of somebody else's volume.
    if (Get-Vol 'Y:') {
        Add-Result 'G01' 'Second-volume tests skipped: the drive letter Y: is already in use' 'SKIP'
        $yv = $null
    } else {

    $dpCreate = @"
create vdisk file="$vhd" maximum=2048 type=expandable
select vdisk file="$vhd"
attach vdisk
convert mbr
create partition primary
format fs=ntfs quick label=YDKTEST
assign letter=Y
"@
    $dpOut = ($dpCreate | diskpart) 2>&1 | Out-String
    Write-Host $dpOut
    $vhdAttached = $true

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Get-Vol 'Y:') -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 500 }
    $yv = Get-Vol 'Y:'

    if (-not $yv) {
        Add-Result 'G01' 'A second NTFS volume could not be created, section A skipped' 'SKIP' 'diskpart did not produce Y:'
    } else {
        Write-Host ("  Y: {0} {1} GB" -f $yv.FileSystem, [math]::Round($yv.Capacity / 1GB, 2))
        Set-Content -LiteralPath 'Y:\seed.txt' -Value ('x' * 1024) -Encoding UTF8

        $cBefore = (Get-ShadowsOf 'C:').Count
        Invoke-Case G01 'Snapshot of a second NTFS volume: -Volume Y' `
            -ArgLine ('-Volume Y -LogPath "{0}"' -f (Join-Path $work 'g01.log')) -ExpectExit 0 `
            -Expect 'Y:\\ -> snapshot created' `
            -Check { if ((Get-ShadowsOf 'Y:').Count -lt 1) { 'no shadow copy on Y:' } }

        Invoke-Case G02 'Both volumes in one run: -Volume C,Y' `
            -ArgLine ('-Volume C,Y -LogPath "{0}"' -f (Join-Path $work 'g02.log')) -ExpectExit 0 `
            -Expect 'succeeded = C:\\, Y:\\'

        # three snapshots on Y:, one prune, C: must be untouched
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $script:SUT -Volume Y -LogPath (Join-Path $work 'seedy.log') | Out-Null
        $cNow = (Get-ShadowsOf 'C:').Count
        $yNow = (Get-ShadowsOf 'Y:').Count
        Invoke-Case G03 ("A run on Y: leaves the C: snapshots alone (Y: {0}, C: {1})" -f $yNow, $cNow) `
            -ArgLine ('-Volume Y -LogPath "{0}"' -f (Join-Path $work 'g03.log')) -ExpectExit 0 `
            -NotExpect 'Deleted old snapshot' `
            -Check {
                $problems = @()
                if ((Get-ShadowsOf 'Y:').Count -ne $yNow + 1) { $problems += "Y: has $((Get-ShadowsOf 'Y:').Count) snapshots, expected $($yNow + 1)" }
                if ((Get-ShadowsOf 'C:').Count -ne $cNow) { $problems += "the C: snapshot count changed: $cNow -> $((Get-ShadowsOf 'C:').Count)" }
                $problems
            }

        Invoke-Case G04 '-Status lists both volumes separately' -ArgLine '-Status' `
            -Expect 'C:\s', 'Y:\s' `
            -Check {
                $out = Get-Content (Join-Path $script:OutDir 'G04.out.txt') -Raw -ErrorAction SilentlyContinue
                Write-Host $out
                $null
            }

        # ---- FAT32: VSS cannot snapshot it ---------------------------------
        foreach ($s in (Get-ShadowsOf 'Y:')) { Remove-CimInstance -InputObject $s -ErrorAction SilentlyContinue }
        $fmt = @"
select vdisk file="$vhd"
select volume Y
format fs=fat32 quick label=YDKFAT
"@
        ($fmt | diskpart) 2>&1 | Out-String | Write-Host
        Start-Sleep -Seconds 2
        $yv2 = Get-Vol 'Y:'
        Write-Host ("  Y: is now {0}" -f $yv2.FileSystem)

        Invoke-Case G05 'A writable non-NTFS (FAT32) volume is skipped, not failed' `
            -ArgLine ('-Volume Y -LogPath "{0}"' -f (Join-Path $work 'g05.log')) -ExpectExit 0 `
            -Expect "is not NTFS \(file system: 'FAT32'", 'succeeded = none, failed = none'

        Invoke-Case G06 'FAT32 volume with -FailOnMissingVolume is still only skipped' `
            -ArgLine ('-Volume Y -FailOnMissingVolume -LogPath "{0}"' -f (Join-Path $work 'g06.log')) -ExpectExit 0 `
            -Expect 'is not NTFS'
    }
    }   # end of the "Y: was free" branch

    # =======================================================================
    Write-Host ('=' * 100)
    Write-Host 'B. subst drive, VSS service left Disabled' -ForegroundColor Cyan

    if (Get-PSDrive -Name X -ErrorAction SilentlyContinue) {
        Add-Result 'G07' 'subst tests skipped: the drive letter X: is already in use' 'SKIP'
    } else {
        & subst X: $env:SystemRoot | Out-Null
        Start-Sleep -Seconds 1
        Invoke-Case G07 'A subst (virtual) drive is treated as a missing volume' `
            -ArgLine ('-Volume X -LogPath "{0}"' -f (Join-Path $work 'g07.log')) -ExpectExit 0 `
            -Expect 'does not exist on this computer; skipping'
        Invoke-Case G08 'A subst drive with -FailOnMissingVolume -> exit 1' `
            -ArgLine ('-Volume X -FailOnMissingVolume -LogPath "{0}"' -f (Join-Path $work 'g08.log')) -ExpectExit 1
        & subst X: /D | Out-Null
    }

    Stop-Service VSS -Force -ErrorAction SilentlyContinue
    Set-Service VSS -StartupType Disabled
    Invoke-Case G09 'VSS service left Disabled -> the script re-enables and starts it' `
        -ArgLine ('-Volume C -LogPath "{0}"' -f (Join-Path $work 'g09.log')) -ExpectExit 0 `
        -Expect "Service 'VSS' is Disabled; setting it to Manual", 'snapshot created' `
        -Check {
            $s = Get-Service VSS
            if ($s.StartType -ne 'Manual') { "VSS start type is now $($s.StartType)" }
        }
    Set-Service VSS -StartupType $vssOrig

    # =======================================================================
    Write-Host ('=' * 100)
    Write-Host 'C. Log file edge cases' -ForegroundColor Cyan

    $locked = Join-Path $work 'locked.log'
    Set-Content -LiteralPath $locked -Value 'held open' -Encoding UTF8
    $fs = [IO.File]::Open($locked, 'Open', 'Write', 'None')
    Invoke-Case G10 'A log file held open by another process (exclusive lock)' `
        -ArgLine ('-Volume Z -LogPath "{0}"' -f $locked) -ExpectExit 0 `
        -Expect 'Could not write to the log file' `
        -NotExpect 'Unhandled|Exception calling'
    $fs.Close(); $fs.Dispose()

    Write-Host '  G11: two runs writing the SAME log file at the same time...'
    $shared = Join-Path $work 'shared.log'
    $sb = {
        param($ps, $sut, $log)
        & $ps -NoProfile -ExecutionPolicy Bypass -File $sut -Volume Z -LogPath $log 2>&1 | Out-String
        "EXITCODE=$LASTEXITCODE"
    }
    $j1 = Start-Job -ScriptBlock $sb -ArgumentList $psExe, $script:SUT, $shared
    $j2 = Start-Job -ScriptBlock $sb -ArgumentList $psExe, $script:SUT, $shared
    $o1 = (Receive-Job -Job (Wait-Job $j1) | Out-String)
    $o2 = (Receive-Job -Job (Wait-Job $j2) | Out-String)
    Remove-Job $j1, $j2
    $both  = "$o1`n$o2"
    $codes = [regex]::Matches($both, 'EXITCODE=(\d+)') | ForEach-Object { $_.Groups[1].Value }
    $prob  = @()
    foreach ($c in $codes) { if ($c -ne '0') { $prob += "exit code $c" } }
    $clash = if ($both -match 'Could not write to the log file') { 'at least one line was lost to a sharing violation' } else { 'no sharing violation' }
    Add-Result 'G11' "Two runs writing the same log file ($clash; exit codes $($codes -join ','))" `
               $(if ($prob) { 'FAIL' } else { 'PASS' }) ($prob -join ' | ') $both

    # retention boundary: retention 1 keeps yesterday, deletes the day before
    $retDir = Join-Path $work 'ret'
    New-Item -ItemType Directory -Path $retDir -Force | Out-Null
    $today = Get-Date
    $names = @{
        Today     = "ydk-{0}.log" -f $today.ToString('yyyy-MM-dd')
        Yesterday = "ydk-{0}.log" -f $today.AddDays(-1).ToString('yyyy-MM-dd')
        TwoDays   = "ydk-{0}.log" -f $today.AddDays(-2).ToString('yyyy-MM-dd')
        Future    = "ydk-{0}.log" -f $today.AddDays(3).ToString('yyyy-MM-dd')
    }
    foreach ($n in $names.Values) { Set-Content -LiteralPath (Join-Path $retDir $n) -Value 'x' -Encoding UTF8 }
    Invoke-Case G12 'Retention boundary: -LogRetentionDays 1 keeps yesterday, deletes the day before' `
        -ArgLine ('-Volume Z -LogRetentionDays 1 -LogPath "{0}"' -f (Join-Path $retDir $names.Today)) -ExpectExit 0 `
        -Check {
            $problems = @()
            if (-not (Test-Path (Join-Path $retDir $names.Yesterday))) { $problems += "yesterday's log was deleted (cut-off is exclusive)" }
            if (Test-Path (Join-Path $retDir $names.TwoDays))          { $problems += 'the two-day-old log was not deleted' }
            if (-not (Test-Path (Join-Path $retDir $names.Future)))    { $problems += 'a log dated in the future was deleted' }
            if (-not (Test-Path (Join-Path $retDir $names.Today)))     { $problems += "today's log (the active one) was deleted" }
            $problems
        }

    Invoke-Case G13 'Default log location is next to the script, not the working directory' `
        -ArgLine '-Volume Z' -ExpectExit 0 `
        -Check {
            $p = Join-Path 'C:\Program Files\YDK\Logs' ("ydk-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
            if (-not (Test-Path $p)) { "no log at $p" }
        }

    # =======================================================================
    Write-Host ('=' * 100)
    Write-Host 'D. Task prefix and script path oddities' -ForegroundColor Cyan

    Remove-AllOurTasks
    Invoke-Case G14 'Prefix with a regex metacharacter: -TaskPrefix Y+K' `
        -ArgLine '-Install -TaskPrefix Y+K -Time 10:00' -ExpectExit 0 -Expect 'Registered: Y\+K0' `
        -Check { if (-not (Get-ScheduledTask -TaskName 'Y+K0' -TaskPath '\' -ErrorAction SilentlyContinue)) { 'Y+K0 was not created' } }

    Invoke-Case G15 '-Status with that prefix' -ArgLine '-Status -TaskPrefix Y+K' -Expect 'Y\+K0'
    Invoke-Case G16 '-Uninstall with that prefix' -ArgLine '-Uninstall -TaskPrefix Y+K' -ExpectExit 0 -Expect 'Deleted: Y\+K0' `
        -Check { if (Get-ScheduledTask -TaskName 'Y+K0' -TaskPath '\' -ErrorAction SilentlyContinue) { 'Y+K0 was not deleted' } }

    Invoke-Case G17 'Prefix with Turkish characters: -TaskPrefix İZ' `
        -ArgLine '-Install -TaskPrefix İZ -Time 10:00' -ExpectExit 0 `
        -Check { if (-not (Get-ScheduledTask -TaskName 'İZ0' -TaskPath '\' -ErrorAction SilentlyContinue)) { 'İZ0 was not created' } }
    Invoke-Case G18 'Uninstall with the Turkish prefix' -ArgLine '-Uninstall -TaskPrefix İZ' -ExpectExit 0 `
        -Check { if (Get-ScheduledTask -TaskName 'İZ0' -TaskPath '\' -ErrorAction SilentlyContinue) { 'İZ0 was not deleted' } }

    Remove-AllOurTasks
    Invoke-Case G19a 'A normal install before the illegal-prefix test' -ArgLine '-Install -Time 10:00' -ExpectExit 0
    Invoke-Case G19 'A prefix with a character that is illegal in a task name is rejected' `
        -ArgLine '-Install -TaskPrefix "YDK\X" -Time 10:00' -ExpectExit 2 `
        -Expect 'not allowed in a task name' `
        -Check {
            $problems = @()
            if (@(Get-ScheduledTask -TaskPath '\YDK\' -ErrorAction SilentlyContinue).Count) {
                $problems += 'a task was created under a \YDK\ folder'
            }
            if (-not (Get-ScheduledTask -TaskName 'YDK0' -TaskPath '\' -ErrorAction SilentlyContinue)) {
                $problems += 'the already installed YDK0 was removed by the failed install'
            }
            $problems
        }

    $oddDir = Join-Path $work "a&b [c] dir"
    New-Item -ItemType Directory -Path $oddDir -Force | Out-Null
    Copy-Item 'C:\Program Files\YDK\ydk.ps1' (Join-Path $oddDir 'ydk.ps1') -Force
    Invoke-Case G20 'Install from a path containing & and [ ]' -ScriptPath (Join-Path $oddDir 'ydk.ps1') `
        -ArgLine '-Install -TaskPrefix TEST -Time 10:00 -Volume C -SkipLocationCheck' -ExpectExit 0 -Expect 'Registered: TEST0'

    Write-Host '  G21: running that task...'
    Start-ScheduledTask -TaskName 'TEST0' -TaskPath '\'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 120 -and (Get-ScheduledTask -TaskName 'TEST0' -TaskPath '\').State -eq 'Running') { Start-Sleep -Milliseconds 500 }
    Start-Sleep -Seconds 1
    $info = Get-ScheduledTaskInfo -TaskName 'TEST0' -TaskPath '\'
    $oddLog = Join-Path $oddDir ("Logs\ydk-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
    $prob = @()
    if ($info.LastTaskResult -ne 0)     { $prob += "LastTaskResult = $($info.LastTaskResult)" }
    if (-not (Test-Path -LiteralPath $oddLog)) { $prob += "no log at $oddLog" }
    Add-Result 'G21' 'A task installed from a path with & and [ ] runs correctly' `
               $(if ($prob) { 'FAIL' } else { 'PASS' }) ($prob -join ' | ')
    Invoke-Case G22 'Uninstall it' -ScriptPath (Join-Path $oddDir 'ydk.ps1') -ArgLine '-Uninstall -TaskPrefix TEST' -ExpectExit 0

    # =======================================================================
    Write-Host ('=' * 100)
    Write-Host 'E. -Time and -Status details' -ForegroundColor Cyan

    Remove-AllOurTasks
    Invoke-Case G23 '-Time 00:00 (midnight) is valid' -ArgLine '-Install -Time 00:00' -ExpectExit 0 `
        -Check {
            $t = Get-ScheduledTask -TaskName 'YDK0' -TaskPath '\' -ErrorAction SilentlyContinue
            if (-not $t) { 'YDK0 missing' }
            elseif (([datetime]@($t.Triggers)[0].StartBoundary).ToString('HH:mm') -ne '00:00') { 'the trigger is not at midnight' }
        }
    Invoke-Case G24 '-Time 24:00 is rejected' -ArgLine '-Install -Time 24:00' -ExpectExit 2 -Expect 'Invalid time'
    Invoke-Case G25 '-Time 9:5 (single-digit minute) is rejected' -ArgLine '-Install -Time 9:5' -ExpectExit 2 -Expect 'Invalid time'
    Invoke-Case G26 '-Time " 10:00 , 13:00 " (extra spaces) is accepted' -ArgLine '-Install -Time " 10:00 , 13:00 "' -ExpectExit 0 `
        -Check {
            $times = @('YDK0','YDK1') | ForEach-Object {
                $t = Get-ScheduledTask -TaskName $_ -TaskPath '\' -ErrorAction SilentlyContinue
                if ($t) { ([datetime]@($t.Triggers)[0].StartBoundary).ToString('HH:mm') }
            }
            if (($times -join ',') -ne '10:00,13:00') { "trigger times: $($times -join ',')" }
        }
    Invoke-Case G27 'Duplicate times register two tasks at the same hour' -ArgLine '-Install -Time 10:00,10:00' -ExpectExit 0 `
        -Check { $n = @(Get-OurTasks); if ($n.Count -ne 2) { "tasks: $($n -join ',')" } }

    Invoke-Case G28 '-LogRetentionDays 0 is written into the task command line' `
        -ArgLine '-Install -Time 10:00 -LogRetentionDays 0' -ExpectExit 0 `
        -Check {
            $a = @((Get-ScheduledTask -TaskName 'YDK0' -TaskPath '\').Actions)[0].Arguments
            if ($a -notmatch '-LogRetentionDays 0') { "arguments: $a" }
        }

    # a disabled task and a task that fails must show up in -Status
    Disable-ScheduledTask -TaskName 'YDK0' -TaskPath '\' | Out-Null
    $failAct = New-ScheduledTaskAction -Execute 'C:\Windows\System32\cmd.exe' -Argument '/c exit 3'
    $failTrg = New-ScheduledTaskTrigger -Daily -At (Get-Date).Date.AddHours(3)
    Register-ScheduledTask -TaskName 'YDK4' -Action $failAct -Trigger $failTrg -Description 'YDK daily VSS snapshot (failing test task)' -Force | Out-Null
    Start-ScheduledTask -TaskName 'YDK4' -TaskPath '\'
    Start-Sleep -Seconds 3
    Invoke-Case G29 '-Status reports a disabled task and a failed run' -ArgLine '-Status' -ExpectExit 1 `
        -Expect 'is disabled', 'FAILED \(3\)' `
        -Check {
            $out = Get-Content (Join-Path $script:OutDir 'G29.out.txt') -Raw -ErrorAction SilentlyContinue
            Write-Host $out
            $null
        }
    Enable-ScheduledTask -TaskName 'YDK0' -TaskPath '\' | Out-Null
    Unregister-ScheduledTask -TaskName 'YDK4' -TaskPath '\' -Confirm:$false

    # copy-count warning: 2 of a maximum 2
    Set-ItemProperty -Path $VssKey -Name MaxShadowCopies -Value 2 -Type DWord
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $script:SUT -Volume C -LogPath (Join-Path $work 'cap1.log') | Out-Null
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $script:SUT -Volume C -LogPath (Join-Path $work 'cap2.log') | Out-Null
    Invoke-Case G30 '-Status warns when the copy count reaches the VSS limit' -ArgLine '-Status' -ExpectExit 1 `
        -Expect 'of a maximum 2', '2 \(overridden\)'

    # a registry value the tool itself would never write: 0 used to divide by zero
    Set-ItemProperty -Path $VssKey -Name MaxShadowCopies -Value 0 -Type DWord
    Invoke-Case G33 '-Status survives MaxShadowCopies = 0 in the registry' -ArgLine '-Status' `
        -NotExpect 'Attempted to divide by zero|divide by zero' `
        -Expect 'not a usable' `
        -Check {
            $out = Get-Content (Join-Path $script:OutDir 'G33.out.txt') -Raw -ErrorAction SilentlyContinue
            Write-Host ('        (info) ' + (@($out -split "`n" | Select-String 'MaxShadowCopies|usable') -join ' / '))
            $null
        }
    Remove-ItemProperty -Path $VssKey -Name MaxShadowCopies -Force -ErrorAction SilentlyContinue

    # -Confirm could sit waiting for an answer, so it runs in a job with a timeout
    Write-Host '  G31: -Confirm in a non-interactive session...'
    $sbC = {
        param($ps, $sut, $log)
        & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $sut -Volume C -Confirm -LogPath $log 2>&1 | Out-String
        "EXITCODE=$LASTEXITCODE"
    }
    $jc = Start-Job -ScriptBlock $sbC -ArgumentList $psExe, $script:SUT, (Join-Path $work 'g31.log')
    if (Wait-Job $jc -Timeout 45) {
        $co = (Receive-Job $jc | Out-String)
        Add-Result 'G31' ("-Confirm in a non-interactive session: {0}" -f (($co -replace '\s+', ' ').Trim())) 'INFO'
    } else {
        Stop-Job $jc
        Add-Result 'G31' '-Confirm in a non-interactive session HANGS waiting for input (killed after 45s)' 'FAIL' 'the process waited for a prompt'
    }
    Remove-Job $jc -Force

    Write-Host '  G32: two installs at the same time...'
    $sbI = {
        param($ps, $sut)
        & $ps -NoProfile -ExecutionPolicy Bypass -File $sut -Install -Time 10:00,13:00 2>&1 | Out-String
        "EXITCODE=$LASTEXITCODE"
    }
    Remove-AllOurTasks
    $k1 = Start-Job -ScriptBlock $sbI -ArgumentList $psExe, $script:SUT
    $k2 = Start-Job -ScriptBlock $sbI -ArgumentList $psExe, $script:SUT
    $q1 = (Receive-Job -Job (Wait-Job $k1) | Out-String)
    $q2 = (Receive-Job -Job (Wait-Job $k2) | Out-String)
    Remove-Job $k1, $k2
    $names2 = @(Get-OurTasks)
    Add-Result 'G32' ("Two -Install runs at the same time -> tasks: {0}" -f ($names2 -join ',')) `
               $(if ($names2.Count -ge 1) { 'PASS' } else { 'FAIL' }) '' "$q1`n$q2"

} finally {
    # =======================================================================
    Write-Host ('=' * 100)
    Write-Host 'RESTORING THE MACHINE' -ForegroundColor Cyan

    Remove-AllOurTasks
    foreach ($n in @('YDK4','TEST0')) {
        $t = Get-ScheduledTask -TaskName $n -TaskPath '\' -ErrorAction SilentlyContinue
        if ($t) { Unregister-ScheduledTask -TaskName $n -TaskPath '\' -Confirm:$false }
    }
    # a prefix containing a backslash may have created \YDK\... in the task tree
    foreach ($p in @('\YDK\')) {
        foreach ($t in @(Get-ScheduledTask -TaskPath $p -ErrorAction SilentlyContinue)) {
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $p -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  removed stray task: $p$($t.TaskName)"
        }
    }
    try { $sch = New-Object -ComObject 'Schedule.Service'; $sch.Connect(); $sch.GetFolder('\').DeleteFolder('YDK', 0); Write-Host '  removed stray \YDK task folder' } catch { }

    Remove-ItemProperty -Path $VssKey -Name MaxShadowCopies -Force -ErrorAction SilentlyContinue
    Set-Service VSS -StartupType $vssOrig -ErrorAction SilentlyContinue
    Set-Service swprv -StartupType $swprvOrig -ErrorAction SilentlyContinue
    & subst X: /D 2>$null | Out-Null

    if ($vhdAttached) {
        foreach ($s in (Get-ShadowsOf 'Y:')) { Remove-CimInstance -InputObject $s -ErrorAction SilentlyContinue }
        $det = @"
select vdisk file="$vhd"
detach vdisk
"@
        ($det | diskpart) 2>&1 | Out-String | Write-Host
        Start-Sleep -Seconds 2
        Remove-Item -LiteralPath $vhd -Force -ErrorAction SilentlyContinue
        Write-Host ("  VHD detached and deleted (still on disk: {0})" -f (Test-Path $vhd))
    }

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
    if ((Get-Service VSS).StartType -ne $vssOrig) { $prob += "VSS start type is $((Get-Service VSS).StartType), was $vssOrig" }
    if (Test-Path $vhd) { $prob += 'the VHD file is still there' }
    if (Get-Vol 'Y:')   { $prob += 'Y: is still mounted' }
    Add-Result 'REST' 'Machine restored (VHD, subst, services, tasks, registry, shadow copies)' `
               $(if ($prob) { 'FAIL' } else { 'PASS' }) ($prob -join ' | ')

    Write-Host ("FINAL: {0} shadow copies, {1} tasks, VSS {2}" -f $finalShadows.Count, $finalTasks.Count, (Get-Service VSS).StartType)
    Write-Report -Path (Join-Path $script:TestRoot 'report-environment.json')
    Stop-Transcript | Out-Null
}

