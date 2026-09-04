# ---------------------------------------------------------------------------
# YDK test - phase 7 (no administrator rights needed)
#   task prefix validation (black box) + Remove-OldLogFile in depth (unit)
# ---------------------------------------------------------------------------
param([string] $Sut)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $here) 'harness.ps1')

if (-not $Sut) { $Sut = Get-YdkScript }
$script:SUT    = $Sut
$script:OutDir = Join-Path $script:TestRoot 'out-log-retention'
New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
Get-ChildItem $script:OutDir -File -ErrorAction SilentlyContinue | Remove-Item -Force

$work = Join-Path $script:TestRoot 'work-log-retention'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

Write-Host ('-' * 100)
Write-Host 'A. Task prefix validation (runs before the administrator check)' -ForegroundColor Cyan

$bad = @('YDK\X', 'A/B', 'A:B', 'A*', 'A?', 'A<B', 'A>B', 'A|B')
$i = 0
foreach ($p in $bad) {
    $i++
    Invoke-Case ("W{0:00}" -f $i) "Prefix '$p' is rejected" `
        -ArgLine ('-Uninstall -TaskPrefix "{0}"' -f $p) -ExpectExit 2 `
        -Expect 'not allowed in a task name'
}

Invoke-Case W09 'Prefix with a double quote is rejected' -ArgLine '-Uninstall -TaskPrefix ''A"B''' -ExpectExit 2
Invoke-Case W10 'Empty prefix is rejected'      -ArgLine '-Uninstall -TaskPrefix ""'   -ExpectExit 2 -Expect 'cannot be empty'
Invoke-Case W11 'Whitespace prefix is rejected' -ArgLine '-Uninstall -TaskPrefix "  "' -ExpectExit 2 -Expect 'cannot be empty'

# valid prefixes must pass validation and only then hit the administrator gate
Invoke-Case W12 'Prefix Y+K is accepted (stops at the administrator check)' `
    -ArgLine '-Uninstall -TaskPrefix Y+K' -ExpectExit 2 -Expect 'administrator' -NotExpect 'not allowed in a task name'
Invoke-Case W13 'Prefix with Turkish characters is accepted' `
    -ArgLine '-Uninstall -TaskPrefix İZ' -ExpectExit 2 -Expect 'administrator' -NotExpect 'not allowed in a task name'
Invoke-Case W14 'Prefix with a space is accepted' `
    -ArgLine '-Status -TaskPrefix "My YDK"' -ExpectExit 2 -Expect 'administrator' -NotExpect 'not allowed'
Invoke-Case W15 'Prefix validation also applies to -Install' `
    -ArgLine '-Install -TaskPrefix "A|B"' -ExpectExit 2 -Expect 'not allowed in a task name'
Invoke-Case W16 '-Volume + -TaskPrefix resolves to the Install set and asks for -Install' `
    -ArgLine '-Volume C -TaskPrefix "A|B"' -Expect 'missing mandatory parameters: Install'

Write-Host ('-' * 100)
Write-Host 'B. Remove-OldLogFile (function lifted out of the script)' -ForegroundColor Cyan

Set-StrictMode -Version Latest
$ast = [System.Management.Automation.Language.Parser]::ParseFile($SUT, [ref] $null, [ref] $null)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($f.Name -eq 'Remove-OldLogFile' -or $f.Name -eq 'Write-Log') {
        . ([scriptblock]::Create($f.Extent.Text))
    }
}

$today   = (Get-Date).Date
$logDir  = Join-Path $work 'logs'
$script:LogFile = Join-Path $logDir ("ydk-{0}.log" -f $today.ToString('yyyy-MM-dd'))

function Reset-Logs {
    param([string[]] $Names)
    if (Test-Path $logDir) { Get-ChildItem $logDir -Recurse -Force | Remove-Item -Recurse -Force }
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    foreach ($n in $Names) { Set-Content -LiteralPath (Join-Path $logDir $n) -Value 'x' -Encoding UTF8 }
}
function Name-For { param([int] $DaysAgo, [string] $Prefix = 'ydk')
    "{0}-{1}.log" -f $Prefix, $today.AddDays(-$DaysAgo).ToString('yyyy-MM-dd')
}
function Test-Case {
    param([string] $Id, [string] $Name, [string[]] $Seed, [int] $Days,
          [string[]] $ShouldGo, [string[]] $ShouldStay, [switch] $WhatIf)
    Reset-Logs -Names $Seed
    try {
        if ($WhatIf) { Remove-OldLogFile -Folder $logDir -RetentionDays $Days -WhatIf }
        else         { Remove-OldLogFile -Folder $logDir -RetentionDays $Days }
    } catch {
        Add-Result $Id $Name 'FAIL' "threw: $($_.Exception.Message)"
        return
    }
    $problems = @()
    foreach ($g in $ShouldGo)   { if (Test-Path (Join-Path $logDir $g))       { $problems += "$g should have been deleted" } }
    foreach ($s in $ShouldStay) { if (-not (Test-Path (Join-Path $logDir $s))) { $problems += "$s must not have been deleted" } }
    Add-Result $Id $Name $(if ($problems) { 'FAIL' } else { 'PASS' }) ($problems -join ' | ')
}

$old   = Name-For 400
$old2  = Name-For 200 'Yedek'
$today0 = Split-Path -Leaf $script:LogFile

Test-Case R01 'Old ydk- and Yedek- logs are deleted, the active one is kept' `
    -Seed @($old, $old2, $today0) -Days 90 -ShouldGo @($old, $old2) -ShouldStay @($today0)

Test-Case R02 'Retention 0 deletes nothing' `
    -Seed @($old, $today0) -Days 0 -ShouldGo @() -ShouldStay @($old, $today0)

Test-Case R03 'Negative retention deletes nothing' `
    -Seed @($old, $today0) -Days -5 -ShouldGo @() -ShouldStay @($old, $today0)

Test-Case R04 'Boundary: with retention 1 yesterday stays, the day before goes' `
    -Seed @((Name-For 1), (Name-For 2), $today0) -Days 1 `
    -ShouldGo @((Name-For 2)) -ShouldStay @((Name-For 1), $today0)

Test-Case R05 'Boundary: with retention 2 the two-day-old log stays' `
    -Seed @((Name-For 2), (Name-For 3), $today0) -Days 2 `
    -ShouldGo @((Name-For 3)) -ShouldStay @((Name-For 2), $today0)

Test-Case R06 'Names that only look like ours are left alone' `
    -Seed @($old, 'ydk-2020-13-45.log', 'ydk-notadate.log', 'ydk-2020-01-01.log.bak',
            'ydk-2020-01-01.txt', 'ydk_2020-01-01.log', 'ydk-2020-01-01.log.log',
            'notes.txt', 'ydk-2020-1-1.log', 'x-ydk-2020-01-01.log') -Days 90 `
    -ShouldGo @($old) `
    -ShouldStay @('ydk-2020-13-45.log', 'ydk-notadate.log', 'ydk-2020-01-01.log.bak',
                  'ydk-2020-01-01.txt', 'ydk_2020-01-01.log', 'ydk-2020-01-01.log.log',
                  'notes.txt', 'ydk-2020-1-1.log', 'x-ydk-2020-01-01.log')

Test-Case R07 'Upper-case YDK- and .LOG variants match too (case-insensitive)' `
    -Seed @('YDK-2020-01-01.log', 'ydk-2020-01-02.LOG', $today0) -Days 90 `
    -ShouldGo @('YDK-2020-01-01.log', 'ydk-2020-01-02.LOG') -ShouldStay @($today0)

Test-Case R08 'A future-dated log is kept' `
    -Seed @(("ydk-{0}.log" -f $today.AddDays(30).ToString('yyyy-MM-dd')), $old) -Days 90 `
    -ShouldGo @($old) -ShouldStay @(("ydk-{0}.log" -f $today.AddDays(30).ToString('yyyy-MM-dd')))

Test-Case R09 '-WhatIf deletes nothing' -Seed @($old, $today0) -Days 90 `
    -ShouldGo @() -ShouldStay @($old, $today0) -WhatIf

# a directory whose name looks like an old log file
Reset-Logs -Names @($today0)
New-Item -ItemType Directory -Path (Join-Path $logDir 'ydk-2019-01-01.log') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $logDir 'ydk-2019-01-01.log\inner.txt') -Value 'x'
try {
    Remove-OldLogFile -Folder $logDir -RetentionDays 30
    $ok = (Test-Path (Join-Path $logDir 'ydk-2019-01-01.log\inner.txt'))
    Add-Result 'R10' 'A directory named like an old log file is not touched' $(if ($ok) { 'PASS' } else { 'FAIL' }) `
               $(if ($ok) { '' } else { 'the directory was deleted' })
} catch { Add-Result 'R10' 'A directory named like an old log file is not touched' 'FAIL' "threw: $($_.Exception.Message)" }

# the file currently being written is never deleted, even when its name is old
Reset-Logs -Names @($old, (Name-For 300))
$script:LogFile = Join-Path $logDir $old
try {
    Remove-OldLogFile -Folder $logDir -RetentionDays 30
    $problems = @()
    if (-not (Test-Path (Join-Path $logDir $old)))          { $problems += 'the active log file was deleted' }
    if (Test-Path (Join-Path $logDir (Name-For 300)))       { $problems += 'the other old file was not deleted' }
    Add-Result 'R11' 'The log file being written to is never deleted, even if it is old' `
               $(if ($problems) { 'FAIL' } else { 'PASS' }) ($problems -join ' | ')
} catch { Add-Result 'R11' 'The log file being written to is never deleted' 'FAIL' "threw: $($_.Exception.Message)" }
$script:LogFile = Join-Path $logDir $today0

# read-only file
Reset-Logs -Names @($old, $today0)
Set-ItemProperty -Path (Join-Path $logDir $old) -Name IsReadOnly -Value $true
try {
    Remove-OldLogFile -Folder $logDir -RetentionDays 30
    $gone = -not (Test-Path (Join-Path $logDir $old))
    Add-Result 'R12' 'A read-only old log file is still deleted (Remove-Item -Force)' $(if ($gone) { 'PASS' } else { 'FAIL' }) `
               $(if ($gone) { '' } else { 'the read-only file survived' })
} catch { Add-Result 'R12' 'A read-only old log file is still deleted' 'FAIL' "threw: $($_.Exception.Message)" }

# locked file: must be reported, must not stop the rest
Reset-Logs -Names @($old, (Name-For 300), $today0)
$fs = [IO.File]::Open((Join-Path $logDir $old), 'Open', 'Read', 'None')
try {
    Remove-OldLogFile -Folder $logDir -RetentionDays 30
    $problems = @()
    if (-not (Test-Path (Join-Path $logDir $old)))    { $problems += 'the locked file was somehow deleted' }
    if (Test-Path (Join-Path $logDir (Name-For 300))) { $problems += 'a locked file stopped the other deletions' }
    Add-Result 'R13' 'A locked log file is reported and the rest are still deleted' `
               $(if ($problems) { 'FAIL' } else { 'PASS' }) ($problems -join ' | ')
} catch {
    Add-Result 'R13' 'A locked log file is reported and the rest are still deleted' 'FAIL' "threw: $($_.Exception.Message)"
} finally { $fs.Close(); $fs.Dispose() }

# folder that does not exist / empty folder
try {
    Remove-OldLogFile -Folder (Join-Path $work 'no-such-folder') -RetentionDays 30
    Add-Result 'R14' 'A missing log folder is handled quietly' 'PASS'
} catch { Add-Result 'R14' 'A missing log folder is handled quietly' 'FAIL' "threw: $($_.Exception.Message)" }

Reset-Logs -Names @()
try {
    Remove-OldLogFile -Folder $logDir -RetentionDays 30
    Add-Result 'R15' 'An empty log folder is handled quietly' 'PASS'
} catch { Add-Result 'R15' 'An empty log folder is handled quietly' 'FAIL' "threw: $($_.Exception.Message)" }

# large number of files
Reset-Logs -Names @()
1..120 | ForEach-Object { Set-Content -LiteralPath (Join-Path $logDir (Name-For (100 + $_))) -Value 'x' }
Set-Content -LiteralPath (Join-Path $logDir $today0) -Value 'x'
try {
    Remove-OldLogFile -Folder $logDir -RetentionDays 30
    $left = @(Get-ChildItem $logDir -File)
    $ok = ($left.Count -eq 1 -and $left[0].Name -eq $today0)
    Add-Result 'R16' '120 old log files are all deleted in one pass' $(if ($ok) { 'PASS' } else { 'FAIL' }) `
               $(if ($ok) { '' } else { "files left: $($left.Count)" })
} catch { Add-Result 'R16' '120 old log files are all deleted in one pass' 'FAIL' "threw: $($_.Exception.Message)" }

Write-Report -Path (Join-Path $script:TestRoot 'report-log-retention.json')
