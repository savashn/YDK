# ---------------------------------------------------------------------------
# YDK test - phase 1: parameter binding, non-admin behaviour, unit tests
# Runs WITHOUT administrator rights on purpose.
# ---------------------------------------------------------------------------
param([string] $Sut)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $here) 'harness.ps1')

if (-not $Sut) { $Sut = Get-YdkScript }
$script:SUT    = $Sut
$script:OutDir = Join-Path $script:TestRoot 'out-parameters'
New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
Get-ChildItem $script:OutDir -File | Remove-Item -Force

$work = Join-Path $script:TestRoot 'work-parameters'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

Write-Host "SUT: $SUT" -ForegroundColor Cyan
Write-Host ('-' * 100)
Write-Host 'A. Parameter binding / validation' -ForegroundColor Cyan

Invoke-Case P01 'Install + Uninstall together -> parameter set conflict' -ArgLine '-Install -Uninstall' -Expect 'Parameter set cannot be resolved|AmbiguousParameterSet'
Invoke-Case P02 'Status + Volume (not in the Status set)'   -ArgLine '-Status -Volume C'        -Expect 'Parameter set cannot be resolved|AmbiguousParameterSet'
Invoke-Case P03 '-KeepPerVolume no longer exists (snapshot mode)' -ArgLine '-Volume C -KeepPerVolume 5' -Expect 'A parameter cannot be found'
Invoke-Case P04 '-KeepPerVolume no longer exists (install mode)'  -ArgLine '-Install -KeepPerVolume 5' -Expect 'A parameter cannot be found'
Invoke-Case P05 'LogRetentionDays above the range (4000)'   -ArgLine '-Volume C -LogRetentionDays 4000' -Expect "Cannot validate argument on parameter 'LogRetentionDays'"
Invoke-Case P06 'MaxShadowCopies 0 (below the range)'       -ArgLine '-Install -MaxShadowCopies 0'   -Expect "Cannot validate argument on parameter 'MaxShadowCopies'"
Invoke-Case P07 'MaxShadowCopies 513 (above the range)'     -ArgLine '-Install -MaxShadowCopies 513' -Expect "Cannot validate argument on parameter 'MaxShadowCopies'"
Invoke-Case P08 'Install + FailOnMissingVolume (snapshot-only switch)' -ArgLine '-Install -FailOnMissingVolume' -Expect 'Parameter set cannot be resolved|AmbiguousParameterSet'
Invoke-Case P09 'Install + LogPath (snapshot-only parameter)'         -ArgLine '-Install -LogPath x.log'        -Expect 'Parameter set cannot be resolved|AmbiguousParameterSet'
Invoke-Case P10 'Time without Install (Install is mandatory there)' -ArgLine '-Time 10:00'  -Expect 'missing mandatory parameters: Install'
Invoke-Case P11 'Uninstall + Volume'                        -ArgLine '-Uninstall -Volume C' -Expect 'Parameter set cannot be resolved|AmbiguousParameterSet'
Invoke-Case P12 'Status + LogRetentionDays'                 -ArgLine '-Status -LogRetentionDays 5' -Expect 'Parameter set cannot be resolved|AmbiguousParameterSet'
Invoke-Case P13 'Unknown parameter'                         -ArgLine '-Foo bar' -Expect 'A parameter cannot be found|named parameter'
Invoke-Case P14 'Volume without a value'                    -ArgLine '-Volume' -Expect 'Missing an argument|cannot be found'
Invoke-Case P15 'Stop + Uninstall together -> parameter set conflict' -ArgLine '-Stop -Uninstall' -Expect 'Parameter set cannot be resolved|AmbiguousParameterSet'
Invoke-Case P16 'Uninstall + NoInitialSnapshot (install-only switch)' -ArgLine '-Uninstall -NoInitialSnapshot' -Expect 'Parameter set cannot be resolved|AmbiguousParameterSet'
Invoke-Case P17 'Stop + Volume (not in the Stop set)'                 -ArgLine '-Stop -Volume C' -Expect 'Parameter set cannot be resolved|AmbiguousParameterSet'

Write-Host ('-' * 100)
Write-Host 'B. Non-administrator behaviour' -ForegroundColor Cyan

$logC = Join-Path $work 'nested\deep\custom.log'

Invoke-Case N01 'Snapshot without admin -> exit 2 + explanation' `
    -ArgLine ('-Volume C -LogPath "{0}"' -f (Join-Path $work 'n01.log')) -ExpectExit 2 `
    -Expect 'must be run as administrator', 'ERROR' `
    -Check { if (-not (Test-Path (Join-Path $work 'n01.log'))) { 'log file was not written' } }

Invoke-Case N02 'Status without admin'    -ArgLine '-Status'    -ExpectExit 2 -Expect 'administrator'
Invoke-Case N03 'Install without admin'   -ArgLine '-Install'   -ExpectExit 2 -Expect 'administrator'
Invoke-Case N04 'Uninstall without admin' -ArgLine '-Uninstall' -ExpectExit 2 -Expect 'administrator' `
    -Check { if (-not (Test-Path -LiteralPath $SUT)) { 'the admin check runs before anything is deleted, but the script is gone' } }
Invoke-Case N04b 'Stop without admin' -ArgLine '-Stop' -ExpectExit 2 -Expect 'administrator'
Invoke-Case N05 'WhatIf snapshot without admin (admin check comes first)' `
    -ArgLine ('-WhatIf -Volume C -LogPath "{0}"' -f (Join-Path $work 'n05.log')) -ExpectExit 2 -Expect 'administrator'

Invoke-Case N06 'Empty -Volume ""'          -ArgLine '-Volume ""'      -ExpectExit 2 -Expect 'volume list is empty'
Invoke-Case N07 'Whitespace/comma -Volume " , "' -ArgLine '-Volume " , "' -ExpectExit 2 -Expect 'volume list is empty'
Invoke-Case N08 'Volume list of only commas' -ArgLine '-Volume ",,,"'   -ExpectExit 2 -Expect 'volume list is empty'

Invoke-Case N09 'LogPath in a non-existent nested folder -> folder is created' `
    -ArgLine ('-Volume C -LogPath "{0}"' -f $logC) -ExpectExit 2 `
    -Check { if (-not (Test-Path $logC)) { 'nested log folder/file was not created' } }

Invoke-Case N10 'LogPath pointing at an unwritable folder (C:\Windows)' `
    -ArgLine '-Volume C -LogPath "C:\Windows\ydk-test-unwritable.log"' `
    -Expect 'Could not write to the log file|Access'

Invoke-Case N11 'LogPath whose folder cannot be created -> clean error, exit 2' `
    -ArgLine '-Volume C -LogPath "C:\Windows\ydk-test-x\a.log"' -ExpectExit 2 `
    -Expect 'Could not create the log folder'

Invoke-Case N12 'LogPath that is an existing directory' `
    -ArgLine '-Volume C -LogPath "C:\Windows"' -Expect 'Could not write to the log file|denied|Access'

Invoke-Case N13 'LogPath with characters that are invalid in a file name' `
    -ArgLine ('-Volume C -LogPath "{0}"' -f (Join-Path $work 'a<b>.log'))

Write-Host ('-' * 100)
Write-Host 'C. Unit tests (functions lifted out of the script with the AST)' -ForegroundColor Cyan

Set-StrictMode -Version Latest
$ast = [System.Management.Automation.Language.Parser]::ParseFile($SUT, [ref]$null, [ref]$null)
$fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($f in $fns) {
    if ($f.Name -eq 'ConvertTo-VolumeRoot' -or $f.Name -eq 'Test-IsYdkTask') {
        . ([scriptblock]::Create($f.Extent.Text))
    }
}

# --- ConvertTo-VolumeRoot --------------------------------------------------
$okCases = @(
    @{ In='c';      Out='C:\' }, @{ In='C';     Out='C:\' }
    @{ In='C:';     Out='C:\' }, @{ In='c:';    Out='C:\' }
    @{ In='C:\';    Out='C:\' }, @{ In='c:/';   Out='C:\' }
    @{ In=' d ';    Out='D:\' }, @{ In='"C"';   Out='C:\' }
    @{ In='"C:\"';  Out='C:\' }, @{ In='z';     Out='Z:\' }
    @{ In='i';      Out='I:\' }, @{ In='C: '; Out='C:\' }
)
foreach ($c in $okCases) {
    try {
        $r = ConvertTo-VolumeRoot -Value $c.In
        if ($r -ceq $c.Out) { Add-Result "U-V[$($c.In)]" "ConvertTo-VolumeRoot '$($c.In)' -> '$($c.Out)'" 'PASS' }
        else { Add-Result "U-V[$($c.In)]" "ConvertTo-VolumeRoot '$($c.In)'" 'FAIL' "returned '$r', expected '$($c.Out)'" }
    } catch { Add-Result "U-V[$($c.In)]" "ConvertTo-VolumeRoot '$($c.In)'" 'FAIL' "threw: $($_.Exception.Message)" }
}

$badCases = @('', ' ', 'CD', 'C:\Users', '1', 'C::', '\\server\share', 'C:\\', '::', '-C', 'CC:', 'C:\Users\')
foreach ($b in $badCases) {
    try {
        $r = ConvertTo-VolumeRoot -Value $b
        Add-Result "U-VX[$b]" "ConvertTo-VolumeRoot rejects '$b'" 'FAIL' "accepted it and returned '$r'"
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'Invalid volume value|cannot be bound|null or empty|empty string') { Add-Result "U-VX[$b]" "ConvertTo-VolumeRoot rejects '$b'" 'PASS' }
        else { Add-Result "U-VX[$b]" "ConvertTo-VolumeRoot rejects '$b'" 'FAIL' "unexpected error: $msg" }
    }
}

# Turkish culture: 'i'.ToUpper() is a dotted capital in tr-TR; ToUpperInvariant must not be.
$old = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
    $r = ConvertTo-VolumeRoot -Value 'i'
    if ($r -ceq 'I:\') { Add-Result 'U-TR' "ConvertTo-VolumeRoot 'i' under tr-TR -> 'I:\'" 'PASS' }
    else { Add-Result 'U-TR' "ConvertTo-VolumeRoot 'i' under tr-TR" 'FAIL' "returned '$r'" }
} finally { [Threading.Thread]::CurrentThread.CurrentCulture = $old }

# --- Test-IsYdkTask --------------------------------------------------------
function New-FakeTask {
    param($Path = '\', $Name = 'YDK0', $Desc = $null, $TaskArgs = $null, $Actions = $null)
    if ($null -eq $Actions) {
        $Actions = if ($null -eq $TaskArgs) { @() } else { @([pscustomobject]@{ Arguments = $TaskArgs }) }
    }
    [pscustomobject]@{ TaskPath = $Path; TaskName = $Name; Description = $Desc; Actions = $Actions }
}

$ydkDesc = 'YDK daily VSS snapshot (10:00) - ydk.ps1'
$ydkArgs = '-NoProfile -NonInteractive -File "C:\YDK\ydk.ps1" -Volume C,D'

$taskCases = @(
    @{ Id='T01'; Expect=$true;  Prefix='YDK'; Task=(New-FakeTask -Desc $ydkDesc);                       Why='root + YDK0 + our description' }
    @{ Id='T02'; Expect=$true;  Prefix='YDK'; Task=(New-FakeTask -TaskArgs $ydkArgs);                   Why='no description, but the action runs ydk.ps1' }
    @{ Id='T03'; Expect=$true;  Prefix='YDK'; Task=(New-FakeTask -Name 'YDK12' -Desc $ydkDesc);         Why='multi-digit index' }
    @{ Id='T04'; Expect=$true;  Prefix='YDK'; Task=(New-FakeTask -TaskArgs '-File C:\eski\Yedek.ps1');  Why='old Yedek.ps1 name' }
    @{ Id='T05'; Expect=$false; Prefix='YDK'; Task=(New-FakeTask -Path '\Microsoft\Windows\' -Desc $ydkDesc); Why='not in the root folder' }
    @{ Id='T06'; Expect=$false; Prefix='YDK'; Task=(New-FakeTask -Name 'YDKfoo' -Desc $ydkDesc);        Why='name is not prefix+digits' }
    @{ Id='T07'; Expect=$false; Prefix='YDK'; Task=(New-FakeTask -Name 'YDK'    -Desc $ydkDesc);        Why='no digits' }
    @{ Id='T08'; Expect=$false; Prefix='YDK'; Task=(New-FakeTask -Name 'XYDK0'  -Desc $ydkDesc);        Why='prefix is not at the start' }
    @{ Id='T09'; Expect=$false; Prefix='YDK'; Task=(New-FakeTask -Desc 'Some other tool' -TaskArgs 'notepad.exe'); Why='foreign task with a colliding name' }
    @{ Id='T10'; Expect=$false; Prefix='Y.K'; Task=(New-FakeTask -Name 'YAK0' -Desc $ydkDesc);          Why='regex metacharacter in the prefix must be escaped' }
    @{ Id='T11'; Expect=$false; Prefix='YDK'; Task=(New-FakeTask -Desc 'x' -Actions @([pscustomobject]@{ ClassId='{guid}' })); Why='ComHandler action without Arguments' }
    @{ Id='T12'; Expect=$false; Prefix='YDK'; Task=(New-FakeTask -Desc 'x' -Actions @());               Why='no actions at all' }
    @{ Id='T13'; Expect=$false; Prefix='T';   Task=(New-FakeTask -Name 'Tpm-Maintenance' -Desc 'Tpm' -TaskArgs 'x'); Why='the -TaskPrefix T trap named in the comment' }
    @{ Id='T14'; Expect=$true;  Prefix='YDK'; Task=(New-FakeTask -Name 'ydk0' -Desc $ydkDesc);          Why='lower-case name still matches (task names are case-insensitive in Windows)' }
    @{ Id='T15'; Expect=$false; Prefix='YDK'; Task=(New-FakeTask -Path '\' -Name 'YDK0 ' -Desc $ydkDesc); Why='trailing space in the name' }
    @{ Id='T16'; Expect=$false; Prefix='YDK'; Task=(New-FakeTask -Desc 'x' -Actions @([pscustomobject]@{ Arguments = $null })); Why='action with a null Arguments value' }
)

foreach ($tc in $taskCases) {
    try {
        $r = [bool] (Test-IsYdkTask -Task $tc.Task -Prefix $tc.Prefix)
        if ($r -eq $tc.Expect) { Add-Result "U-$($tc.Id)" "Test-IsYdkTask: $($tc.Why)" 'PASS' }
        else { Add-Result "U-$($tc.Id)" "Test-IsYdkTask: $($tc.Why)" 'FAIL' "returned $r, expected $($tc.Expect)" }
    } catch {
        Add-Result "U-$($tc.Id)" "Test-IsYdkTask: $($tc.Why)" 'FAIL' "threw: $($_.Exception.Message)"
    }
}

# Actions = $null is a separate case: it must not blow up under StrictMode.
try {
    $t = [pscustomobject]@{ TaskPath='\'; TaskName='YDK0'; Description='x'; Actions=$null }
    $r = [bool] (Test-IsYdkTask -Task $t -Prefix 'YDK')
    Add-Result 'U-T17' 'Test-IsYdkTask: Actions = $null does not throw' 'PASS' "returned $r"
} catch {
    Add-Result 'U-T17' 'Test-IsYdkTask: Actions = $null does not throw' 'FAIL' "threw: $($_.Exception.Message)"
}

Write-Report -Path (Join-Path $script:TestRoot 'report-parameters.json')
