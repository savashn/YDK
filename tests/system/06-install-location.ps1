# ---------------------------------------------------------------------------
# YDK test - phase 9 (ELEVATED): the install location check, end to end
#   - installing from C:\Program Files\YDK works and the SYSTEM task runs
#   - installing from a folder ordinary users can write to is refused
#   - -SkipLocationCheck installs anyway
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $here) 'harness.ps1')

# Installs in this suite are about the registration, not about snapshots.
$script:InstallsSkipSnapshot = $true

$script:OutDir = Join-Path $script:TestRoot 'out-install-location-e2e'
New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
Get-ChildItem $script:OutDir -File -ErrorAction SilentlyContinue | Remove-Item -Force

Assert-SystemTestsAllowed

Start-Transcript -Path (Join-Path $script:TestRoot 'install-location-e2e-transcript.txt') -Force | Out-Null

$idn = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal] $idn).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'PHASE9 ABORTED: not elevated.' -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 9
}

$source   = Get-YdkScript
$safeDir  = Join-Path $env:ProgramFiles 'YDK'
$unsafe1  = 'C:\' + 'YDK'                                  # inherits Authenticated Users: Modify from C:\
$unsafe2  = Join-Path $script:TestRoot 'profile-install'              # under the user profile
$work     = Join-Path $script:TestRoot 'work-install-location-e2e'
$psExe    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

function Get-OurTasks {
    @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue |
      Where-Object { $_.TaskName -match '^(YDK|PF|UNSAFE)\d+$' } | Select-Object -ExpandProperty TaskName | Sort-Object)
}
function Remove-AllOurTasks {
    foreach ($n in (Get-OurTasks)) { Unregister-ScheduledTask -TaskName $n -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue }
}
function Get-ShadowIds { @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ID) }

$baselineShadows = Get-ShadowIds
$baselineTasks   = @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty TaskName | Sort-Object)
Remove-AllOurTasks

# --- fixtures --------------------------------------------------------------
New-Item -ItemType Directory -Path $safeDir -Force | Out-Null
Copy-Item -LiteralPath $source -Destination (Join-Path $safeDir 'ydk.ps1') -Force

New-Item -ItemType Directory -Path $unsafe1 -Force | Out-Null
Copy-Item -LiteralPath $source -Destination (Join-Path $unsafe1 'ydk.ps1') -Force

New-Item -ItemType Directory -Path $unsafe2 -Force | Out-Null
Copy-Item -LiteralPath $source -Destination (Join-Path $unsafe2 'ydk.ps1') -Force

$script:SUT = Join-Path $safeDir 'ydk.ps1'
Write-Host "safe   : $safeDir"
Write-Host "unsafe1: $unsafe1"
Write-Host "unsafe2: $unsafe2"

Write-Host ('=' * 100)
Write-Host 'A. Installing from C:\Program Files\YDK' -ForegroundColor Cyan

Invoke-Case Z01 'Install from Program Files is not blocked' -ArgLine '-Install -Time 10:00,13:00 -Volume C,D' `
    -ExpectExit 0 -Expect 'Registered: YDK0', 'Registered: YDK1' `
    -NotExpect 'can be modified by users who are not administrators', 'lives under a user profile' `
    -Check {
        $problems = @()
        $t = Get-ScheduledTask -TaskName 'YDK0' -TaskPath '\' -ErrorAction SilentlyContinue
        if (-not $t) { return @('YDK0 was not created') }
        $a = @($t.Actions)[0].Arguments
        if ($a -notmatch '-File "C:\\Program Files\\YDK\\ydk\.ps1"') { $problems += "the path is not quoted properly: $a" }
        if ($t.Principal.UserId -notmatch 'S-1-5-18|SYSTEM')         { $problems += "principal: $($t.Principal.UserId)" }
        $problems
    }

Write-Host '  Z02: running the task as SYSTEM out of Program Files...'
Start-ScheduledTask -TaskName 'YDK0' -TaskPath '\'
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 180 -and (Get-ScheduledTask -TaskName 'YDK0' -TaskPath '\').State -eq 'Running') { Start-Sleep -Milliseconds 500 }
Start-Sleep -Seconds 1
$info = Get-ScheduledTaskInfo -TaskName 'YDK0' -TaskPath '\'
$log  = Join-Path $safeDir ("Logs\ydk-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
$tail = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 20 | Out-String } else { '' }
$prob = @()
if ($info.LastTaskResult -ne 0)                { $prob += "LastTaskResult = $($info.LastTaskResult)" }
if (-not (Test-Path -LiteralPath $log))        { $prob += "SYSTEM could not create the log under Program Files ($log)" }
if ($tail -notmatch 'snapshot created')        { $prob += 'no snapshot was created' }
if ($tail -notmatch 'Requested volumes: C, D') { $prob += 'the volume list did not arrive intact' }
Add-Result 'Z02' 'The SYSTEM task runs from Program Files, writes its log and takes a snapshot' `
           $(if ($prob) { 'FAIL' } else { 'PASS' }) ($prob -join ' | ') $tail

Invoke-Case Z03 'The log folder created by SYSTEM is not writable by ordinary users' -ArgLine '-Status' `
    -Check {
        $logDir = Join-Path $safeDir 'Logs'
        if (-not (Test-Path -LiteralPath $logDir)) { return @('the log folder was not created') }
        $bad = @()
        foreach ($ace in (Get-Acl -LiteralPath $logDir).Access) {
            if ($ace.AccessControlType -ne 'Allow') { continue }
            if (($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
            if (([int] $ace.FileSystemRights -band (0x10000000 -bor 0x40000000 -bor 0x116 -bor 0x10000)) -eq 0) { continue }
            $sid = $null
            try { $sid = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
            if ($sid -and @('S-1-5-18','S-1-5-32-544','S-1-3-0','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464') -contains $sid) { continue }
            $bad += "$($ace.IdentityReference): $($ace.FileSystemRights)"
        }
        if ($bad.Count) { "non-administrators can write in the log folder: $($bad -join ' ; ')" }
    }

Invoke-Case Z04 'Uninstall from Program Files' -ArgLine '-Uninstall' -ExpectExit 0 -Expect 'Deleted: YDK0'

Write-Host ('=' * 100)
Write-Host 'B. A folder ordinary users can write to' -ForegroundColor Cyan

$sutUnsafe1 = Join-Path $unsafe1 'ydk.ps1'
Invoke-Case Z05 'Install from C:\YDK is refused' -ScriptPath $sutUnsafe1 `
    -ArgLine '-Install -Time 10:00' -ExpectExit 2 `
    -Expect 'can be modified by users who are not administrators', 'Install cancelled', 'C:\\Program Files\\YDK' `
    -Check {
        $problems = @()
        if ((Get-OurTasks).Count) { $problems += "tasks were registered anyway: $((Get-OurTasks) -join ',')" }
        $out = Get-Content (Join-Path $script:OutDir 'Z05.out.txt') -Raw -ErrorAction SilentlyContinue
        Write-Host '        ---- refusal message ----'
        Write-Host $out
        $problems
    }

Invoke-Case Z06 'The same install with -SkipLocationCheck goes through' -ScriptPath $sutUnsafe1 `
    -ArgLine '-Install -TaskPrefix UNSAFE -Time 10:00 -SkipLocationCheck' -ExpectExit 0 `
    -Expect 'Installing anyway because -SkipLocationCheck', 'Registered: UNSAFE0' `
    -Check { if (-not (Get-ScheduledTask -TaskName 'UNSAFE0' -TaskPath '\' -ErrorAction SilentlyContinue)) { 'UNSAFE0 was not created' } }

Invoke-Case Z07 'Removing that install again' -ScriptPath $sutUnsafe1 -ArgLine '-Uninstall -TaskPrefix UNSAFE' `
    -ExpectExit 0 -Expect 'Deleted: UNSAFE0'

$sutUnsafe2 = Join-Path $unsafe2 'ydk.ps1'
Invoke-Case Z08 'Install from a user profile folder is refused' -ScriptPath $sutUnsafe2 `
    -ArgLine '-Install -Time 10:00' -ExpectExit 2 -Expect 'can be modified by users who are not administrators' `
    -Check { if ((Get-OurTasks).Count) { "tasks were registered anyway: $((Get-OurTasks) -join ',')" } }

Invoke-Case Z09 'The check does not get in the way of -Uninstall' -ScriptPath $sutUnsafe2 -ArgLine '-Uninstall' `
    -ExpectExit 0 -NotExpect 'can be modified by users'

Invoke-Case Z10 'The check does not get in the way of -Status' -ScriptPath $sutUnsafe2 -ArgLine '-Status' `
    -NotExpect 'can be modified by users'

Invoke-Case Z11 'The check does not get in the way of a snapshot run' -ScriptPath $sutUnsafe2 `
    -ArgLine ('-Volume Z -LogPath "{0}"' -f (Join-Path $work 'z11.log')) -ExpectExit 0 `
    -NotExpect 'can be modified by users'

Invoke-Case Z12 '-Install -WhatIf from an unsafe folder is refused as well' -ScriptPath $sutUnsafe1 `
    -ArgLine '-Install -Time 10:00 -WhatIf' -ExpectExit 2 -Expect 'Install cancelled'

Invoke-Case Z13 'Hardening the folder makes the same install succeed' -ScriptPath $sutUnsafe1 `
    -Pre {
        & icacls.exe $unsafe1 /inheritance:r /grant 'SYSTEM:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    } `
    -ArgLine '-Install -TaskPrefix PF -Time 10:00' -ExpectExit 0 -Expect 'Registered: PF0' `
    -NotExpect 'can be modified by users who are not administrators'

Invoke-Case Z14 'Clean up that install' -ScriptPath $sutUnsafe1 -ArgLine '-Uninstall -TaskPrefix PF' -ExpectExit 0

Write-Host ('=' * 100)
Write-Host 'RESTORING THE MACHINE' -ForegroundColor Cyan

Remove-AllOurTasks
foreach ($d in @($unsafe1, $unsafe2, $safeDir)) {
    if (Test-Path -LiteralPath $d) {
        Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  removed $d"
    }
}

$created = @((Get-ShadowIds) | Where-Object { $baselineShadows -notcontains $_ })
$n = 0
foreach ($s in @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue)) {
    if ($created -contains $s.ID) {
        try { Remove-CimInstance -InputObject $s -ErrorAction Stop; $n++ } catch { }
    }
}
Write-Host ("  shadow copies created by this phase: {0}, deleted: {1}" -f $created.Count, $n)

$finalTasks = @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty TaskName | Sort-Object)
$prob = @()
$lost  = @($baselineTasks | Where-Object { $finalTasks -notcontains $_ })
$extra = @($finalTasks | Where-Object { $baselineTasks -notcontains $_ })
if ($lost.Count)  { $prob += "tasks lost: $($lost -join ',')" }
if ($extra.Count) { $prob += "tasks left behind: $($extra -join ',')" }
if (@((Get-ShadowIds) | Where-Object { $baselineShadows -notcontains $_ }).Count) { $prob += 'test shadow copies left behind' }
foreach ($d in @($unsafe1, $unsafe2, $safeDir)) { if (Test-Path -LiteralPath $d) { $prob += "$d is still there" } }
Add-Result 'REST' 'Machine restored (install folders, tasks, shadow copies)' $(if ($prob) { 'FAIL' } else { 'PASS' }) ($prob -join ' | ')

Write-Report -Path (Join-Path $script:TestRoot 'report-install-location-e2e.json')
Stop-Transcript | Out-Null
