# ---------------------------------------------------------------------------
# YDK system test: ydk-setup.ps1
#   Runs both without and with administrator rights; the elevation branch is
#   only exercised through its guards, never by raising a real UAC prompt.
# ---------------------------------------------------------------------------
param(
    [string] $SetupSource,   # ydk-setup.ps1; defaults to this working copy
    [string] $ToolSource     # ydk.ps1; defaults to this working copy
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $here) 'harness.ps1')

# Installs in this suite are about the registration, not about snapshots.
$script:InstallsSkipSnapshot = $true

$script:OutDir = Join-Path $script:TestRoot 'out-setup-script'
New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
Get-ChildItem $script:OutDir -File -ErrorAction SilentlyContinue | Remove-Item -Force

if (-not $SetupSource) { $SetupSource = Get-YdkSetupScript }
if (-not $ToolSource)  { $ToolSource  = Get-YdkScript }

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
               [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) { Assert-SystemTestsAllowed; Start-Transcript -Path (Join-Path $script:TestRoot 'setup-script-transcript.txt') -Force | Out-Null }

$work = Join-Path $script:TestRoot 'work-setup-script'
if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $work -Force | Out-Null

# a staging folder holding both files, the way a technician would carry them
$stage = Join-Path $work 'stage'
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item -LiteralPath $SetupSource -Destination (Join-Path $stage 'ydk-setup.ps1') -Force
Copy-Item -LiteralPath $ToolSource  -Destination (Join-Path $stage 'ydk.ps1')       -Force
$script:SUT = Join-Path $stage 'ydk-setup.ps1'

# a staging folder with the setup script but no tool next to it
$lonely = Join-Path $work 'lonely'
New-Item -ItemType Directory -Path $lonely -Force | Out-Null
Copy-Item -LiteralPath $SetupSource -Destination (Join-Path $lonely 'ydk-setup.ps1') -Force

Write-Host ("running as administrator: {0}" -f $isAdmin) -ForegroundColor Cyan

Write-Host ('-' * 100)
Write-Host 'A. Guards that must work before anything is touched' -ForegroundColor Cyan

Invoke-Case Q01 'ydk.ps1 missing next to the setup script -> clean error, exit 2' `
    -ScriptPath (Join-Path $lonely 'ydk-setup.ps1') -ArgLine '-Elevated' -ExpectExit 2 `
    -Expect 'ydk.ps1 is not in the same folder' -NotExpect 'Installing YDK into'

if (-not $isAdmin) {
    Invoke-Case Q02 'Without administrator rights and -Elevated set -> refuses instead of looping' `
        -ArgLine '-Elevated' -ExpectExit 2 -Expect 'Still not running as administrator' `
        -NotExpect 'Installing YDK into'

    Invoke-Case Q03 'The missing-file check runs before elevation is attempted' `
        -ScriptPath (Join-Path $lonely 'ydk-setup.ps1') -ArgLine '' -ExpectExit 2 `
        -Expect 'ydk.ps1 is not in the same folder' `
        -NotExpect 'Administrator rights are needed'

    Add-Result 'Q04' 'The elevation branch itself is not tested here (it would raise a UAC prompt)' 'SKIP'
    Write-Report -Path (Join-Path $script:TestRoot 'report-setup-script.json')
    return
}

# ===========================================================================
# From here on: elevated
# ===========================================================================
$dest    = Join-Path $env:ProgramFiles 'YDK'
$unsafe  = 'C:\' + 'YDK'
$psExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Get-OurTasks {
    @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue |
      Where-Object { $_.TaskName -match '^(YDK|SET)\d+$' } | Select-Object -ExpandProperty TaskName | Sort-Object)
}
function Remove-AllOurTasks {
    foreach ($n in (Get-OurTasks)) { Unregister-ScheduledTask -TaskName $n -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue }
}
function Get-ShadowIds { @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ID) }

$baselineShadows = Get-ShadowIds
$baselineTasks   = @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty TaskName | Sort-Object)
Remove-AllOurTasks
foreach ($d in @($dest, $unsafe)) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }

Write-Host ('-' * 100)
Write-Host 'B. A full setup run' -ForegroundColor Cyan

Invoke-Case Q05 'Default run: copies into Program Files, installs, prints the report' `
    -ArgLine '' -ExpectExit 0 `
    -Expect 'Installing YDK into: C:\\Program Files\\YDK', 'copied ydk.ps1 to', 'Registered: YDK0', 'Registered: YDK2',
            'YDK status', 'Installed: C:\\Program Files\\YDK\\ydk.ps1', 'Remove-Item' `
    -Check {
        $problems = @()
        if (-not (Test-Path -LiteralPath (Join-Path $dest 'ydk.ps1'))) { $problems += 'ydk.ps1 was not copied' }
        $names = Get-OurTasks
        if (($names -join ',') -ne 'YDK0,YDK1,YDK2') { $problems += "tasks: $($names -join ',')" }
        $t = Get-ScheduledTask -TaskName 'YDK0' -TaskPath '\' -ErrorAction SilentlyContinue
        if ($t -and @($t.Actions)[0].Arguments -notmatch '-File "C:\\Program Files\\YDK\\ydk\.ps1"') {
            $problems += "the task does not point at the installed copy: $(@($t.Actions)[0].Arguments)"
        }
        if (-not (Test-Path -LiteralPath (Join-Path $stage 'ydk.ps1'))) { $problems += 'the staged copy was deleted (it must not be)' }
        $problems
    }

Invoke-Case Q05b 'The install it runs ends with a first snapshot' `
    -ArgLine '-Volume C' -InitialSnapshot -ExpectExit 0 `
    -Expect 'Taking the first snapshot', 'snapshot created' `
    -Pre   { $script:beforeShadows = (Get-ShadowIds).Count } `
    -Check {
        $problems = @()
        if ((Get-ShadowIds).Count -le $script:beforeShadows) { $problems += 'no shadow copy was created' }
        if (-not (Test-Path -LiteralPath (Join-Path $dest 'Logs'))) { $problems += 'no Logs folder in the install folder' }
        $problems
    }

Invoke-Case Q06 'Options are handed through to -Install unchanged' `
    -ArgLine '-Time 08:00,20:00 -Volume C -LogRetentionDays 30' -ExpectExit 0 `
    -Expect 'Registered: YDK0', 'Registered: YDK1' `
    -Check {
        $problems = @()
        $names = Get-OurTasks
        if (($names -join ',') -ne 'YDK0,YDK1') { $problems += "tasks: $($names -join ',') (the third one should be gone)" }
        $a = @((Get-ScheduledTask -TaskName 'YDK0' -TaskPath '\').Actions)[0].Arguments
        if ($a -notmatch '-Volume C\b')          { $problems += "volume: $a" }
        if ($a -match '-KeepPerVolume')          { $problems += "the removed option is still written into the task: $a" }
        if ($a -notmatch '-LogRetentionDays 30') { $problems += "retention: $a" }
        $times = @('YDK0','YDK1') | ForEach-Object {
            ([datetime]@((Get-ScheduledTask -TaskName $_ -TaskPath '\').Triggers)[0].StartBoundary).ToString('HH:mm')
        }
        if (($times -join ',') -ne '08:00,20:00') { $problems += "times: $($times -join ',')" }
        $problems
    }

Invoke-Case Q07 'A custom -TaskPrefix reaches both -Install and -Status' `
    -ArgLine '-TaskPrefix SET -Time 09:00' -ExpectExit 0 `
    -Expect 'Registered: SET0' `
    -Check { if (-not (Get-ScheduledTask -TaskName 'SET0' -TaskPath '\' -ErrorAction SilentlyContinue)) { 'SET0 was not created' } }

& (Join-Path $dest 'ydk.ps1') -Uninstall -TaskPrefix SET | Out-Null

Write-Host '  Q08: does the installed task actually run?'
Start-ScheduledTask -TaskName 'YDK0' -TaskPath '\'
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 180 -and (Get-ScheduledTask -TaskName 'YDK0' -TaskPath '\').State -eq 'Running') { Start-Sleep -Milliseconds 500 }
Start-Sleep -Seconds 1
$info = Get-ScheduledTaskInfo -TaskName 'YDK0' -TaskPath '\'
$log  = Join-Path $dest ("Logs\ydk-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
$tail = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 15 | Out-String } else { '' }
$prob = @()
if ($info.LastTaskResult -ne 0)         { $prob += "LastTaskResult = $($info.LastTaskResult)" }
if ($tail -notmatch 'snapshot created') { $prob += 'no snapshot was created' }
Add-Result 'Q08' 'A task installed by ydk-setup.ps1 runs as SYSTEM and takes a snapshot' `
           $(if ($prob) { 'FAIL' } else { 'PASS' }) ($prob -join ' | ') $tail

Write-Host ('-' * 100)
Write-Host 'C. Re-running, and the paths that must fail' -ForegroundColor Cyan

Set-Content -LiteralPath (Join-Path $stage 'marker.txt') -Value 'newer version marker' -Encoding UTF8
Add-Content -LiteralPath (Join-Path $stage 'ydk.ps1') -Value '# updated copy' -Encoding UTF8
Invoke-Case Q09 'Running it again updates the installed copy (idempotent)' -ArgLine '' -ExpectExit 0 `
    -Expect 'copied ydk.ps1 to' `
    -Check {
        $problems = @()
        $installed = Get-Content -LiteralPath (Join-Path $dest 'ydk.ps1') -Raw
        if ($installed -notmatch '# updated copy') { $problems += 'the new version was not copied over' }
        $names = Get-OurTasks
        if (($names -join ',') -ne 'YDK0,YDK1,YDK2') { $problems += "tasks: $($names -join ',')" }
        $problems
    }

Invoke-Case Q10 'Started from the destination itself: nothing to copy, install still runs' `
    -ScriptPath (Join-Path $dest 'ydk-setup.ps1') `
    -Pre { Copy-Item -LiteralPath $SetupSource -Destination (Join-Path $dest 'ydk-setup.ps1') -Force } `
    -ArgLine '-Time 07:00' -ExpectExit 0 `
    -Expect 'already running from the destination', 'Registered: YDK0' `
    -NotExpect 'The copy you started from is not used any more'

Invoke-Case Q11 'A destination ordinary users can write to is refused by ydk.ps1' `
    -ArgLine ('-Destination "{0}" -Time 10:00' -f $unsafe) -ExpectExit 2 `
    -Expect 'can be modified by users who are not administrators', 'ydk.ps1 -Install failed' `
    -Check {
        $problems = @()
        if (-not (Test-Path -LiteralPath (Join-Path $unsafe 'ydk.ps1'))) { $problems += 'the copy step should still have happened' }
        foreach ($n in (Get-OurTasks)) {
            $t = Get-ScheduledTask -TaskName $n -TaskPath '\' -ErrorAction SilentlyContinue
            if ($t -and @($t.Actions)[0].Arguments -match [regex]::Escape($unsafe)) { $problems += "a task points at $unsafe" }
        }
        $problems
    }

Invoke-Case Q12 'An invalid option is rejected by ydk.ps1 and reported by setup' `
    -ArgLine '-Time 25:00' -ExpectExit 2 -Expect 'Invalid time', 'ydk.ps1 -Install failed'

Invoke-Case Q13 'A destination that cannot be created -> clean error' `
    -ArgLine '-Destination "Q:\nope\YDK"' -ExpectExit 2 -Expect 'Could not create'

Write-Host ('-' * 100)
Write-Host 'RESTORING THE MACHINE' -ForegroundColor Cyan

Remove-AllOurTasks
foreach ($d in @($dest, $unsafe)) {
    if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "  removed $d" }
}
$created = @((Get-ShadowIds) | Where-Object { $baselineShadows -notcontains $_ })
$n = 0
foreach ($s in @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue)) {
    if ($created -contains $s.ID) { try { Remove-CimInstance -InputObject $s -ErrorAction Stop; $n++ } catch { } }
}
Write-Host ("  shadow copies created by this phase: {0}, deleted: {1}" -f $created.Count, $n)

$finalTasks = @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty TaskName | Sort-Object)
$prob = @()
$lost  = @($baselineTasks | Where-Object { $finalTasks -notcontains $_ })
$extra = @($finalTasks | Where-Object { $baselineTasks -notcontains $_ })
if ($lost.Count)  { $prob += "tasks lost: $($lost -join ',')" }
if ($extra.Count) { $prob += "tasks left behind: $($extra -join ',')" }
if (@((Get-ShadowIds) | Where-Object { $baselineShadows -notcontains $_ }).Count) { $prob += 'test shadow copies left behind' }
foreach ($d in @($dest, $unsafe)) { if (Test-Path -LiteralPath $d) { $prob += "$d is still there" } }
Add-Result 'REST' 'Machine restored' $(if ($prob) { 'FAIL' } else { 'PASS' }) ($prob -join ' | ')

Write-Report -Path (Join-Path $script:TestRoot 'report-setup-script.json')
Stop-Transcript | Out-Null
