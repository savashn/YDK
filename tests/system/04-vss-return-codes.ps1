# ---------------------------------------------------------------------------
# YDK test - phase 5 (ELEVATED): every Win32_ShadowCopy::Create return code.
# VSS will not produce these on demand, so a copy of the script is used with
# New-ShadowCopy replaced by a stub that returns whatever the test asks for.
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $here) 'harness.ps1')

$script:OutDir = Join-Path $script:TestRoot 'out-vss-return-codes'
New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
Get-ChildItem $script:OutDir -File -ErrorAction SilentlyContinue | Remove-Item -Force

Assert-SystemTestsAllowed

Start-Transcript -Path (Join-Path $script:TestRoot 'vss-return-codes-transcript.txt') -Force | Out-Null

$idn = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal] $idn).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'PHASE5 ABORTED: not elevated.' -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 9
}

$work = Join-Path $script:TestRoot 'work-vss-return-codes'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

# --- build the stubbed copy ------------------------------------------------
$src = Get-Content -LiteralPath 'C:\Program Files\YDK\ydk.ps1' -Raw
$idx = $src.IndexOf('# Main flow')
$hdr = $src.LastIndexOf('# ====', $idx)
if ($idx -lt 0 -or $hdr -lt 0) { throw 'could not find the main flow marker in ydk.ps1' }

$stub = @'
# --- TEST STUB (inserted by the test harness, not part of the tool) --------
$script:SnapshotRetryDelaySeconds = 1
function New-ShadowCopy {
    param([Parameter(Mandatory)][string] $VolumeRoot)
    if ($env:YDK_STUB_LOG) { Add-Content -LiteralPath $env:YDK_STUB_LOG -Value ("call $VolumeRoot") }
    switch ($env:YDK_STUB_MODE) {
        'throw' { throw 'stubbed VSS failure' }
        'empty' { return @{ ReturnValue = 0; ShadowID = '' } }
        default { return @{ ReturnValue = [int] $env:YDK_STUB_CODE; ShadowID = '{11111111-1111-1111-1111-111111111111}' } }
    }
}

'@

$script:SUT = Join-Path $work 'ydk-stub.ps1'
Set-Content -LiteralPath $script:SUT -Value ($src.Substring(0, $hdr) + $stub + $src.Substring($hdr)) -Encoding UTF8
Write-Host "stubbed copy: $script:SUT"

$stubLog = Join-Path $work 'stub-calls.txt'
function Reset-Stub {
    param([string] $Code = '0', [string] $Mode = '')
    Remove-Item $stubLog -ErrorAction SilentlyContinue
    $env:YDK_STUB_CODE = $Code
    $env:YDK_STUB_MODE = $Mode
    $env:YDK_STUB_LOG  = $stubLog
}
function Get-StubCalls { if (Test-Path $stubLog) { @(Get-Content $stubLog).Count } else { 0 } }

Write-Host ('=' * 100)
Write-Host 'Win32_ShadowCopy::Create return codes' -ForegroundColor Cyan

$codes = @(
    @{ Id='V01'; Code='1';  Text='Access denied' }
    @{ Id='V02'; Code='2';  Text='Invalid argument' }
    @{ Id='V03'; Code='3';  Text='Specified volume not found' }
    @{ Id='V04'; Code='4';  Text='Specified volume not supported' }
    @{ Id='V05'; Code='5';  Text='Unsupported shadow copy context' }
    @{ Id='V06'; Code='6';  Text='Insufficient storage' }
    @{ Id='V07'; Code='7';  Text='Volume is in use' }
    @{ Id='V08'; Code='8';  Text='Maximum number of shadow copies reached' }
    @{ Id='V09'; Code='10'; Text='provider vetoed' }
    @{ Id='V10'; Code='11'; Text='provider not registered' }
    @{ Id='V11'; Code='12'; Text='provider failure' }
    @{ Id='V12'; Code='13'; Text='Unknown error' }
    @{ Id='V13'; Code='42'; Text='Undefined error code' }
    @{ Id='V14'; Code='-1'; Text='Undefined error code' }
)

foreach ($c in $codes) {
    Reset-Stub -Code $c.Code
    # NOTE: the patterns must be built into a variable first. Written inline as
    # "-Expect (expr), 'x'" PowerShell binds only the first element to -Expect
    # and pushes the rest onto the positional parameters.
    $name    = "Create returns {0} -> '{1}', exit 1" -f $c.Code, $c.Text
    $expect  = @(("Code {0} : " -f $c.Code), [regex]::Escape($c.Text), 'failed = C:\\')
    $argLine = '-Volume C -LogPath "{0}"' -f (Join-Path $work "$($c.Id).log")
    Invoke-Case $c.Id $name -ArgLine $argLine -ExpectExit 1 -Expect $expect `
        -Check { if ((Get-StubCalls) -ne 1) { "Create was called $(Get-StubCalls) times, expected once" } }
}

Reset-Stub -Code '9'
$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-Case V15 'Create returns 9 -> retried three times, then reported' `
    -ArgLine ('-Volume C -LogPath "{0}"' -f (Join-Path $work 'v15.log')) -ExpectExit 1 `
    -Expect 'retrying in 1s \(1/3\)', 'retrying in 1s \(2/3\)', 'Code 9 : Another shadow copy operation', 'failed = C:\\' `
    -NotExpect 'retrying in 1s \(3/3\)' `
    -Check {
        $n = Get-StubCalls
        if ($n -ne 3) { "Create was called $n times, expected 3 (1 + 2 retries)" }
    }
Write-Host ("        (info) the run with two retries took {0:N1} s" -f $sw.Elapsed.TotalSeconds)

Reset-Stub -Code '9'
Invoke-Case V16 'Return code 9 on two volumes retries per volume' `
    -ArgLine ('-Volume C,C -LogPath "{0}"' -f (Join-Path $work 'v16.log')) -ExpectExit 1 `
    -Check { $n = Get-StubCalls; if ($n -ne 6) { "Create was called $n times, expected 6" } }

Reset-Stub -Code '9'
Invoke-Case V17 '-WhatIf never calls Create at all' `
    -ArgLine ('-WhatIf -Volume C -LogPath "{0}"' -f (Join-Path $work 'v17.log')) -ExpectExit 0 `
    -Check { $n = Get-StubCalls; if ($n -ne 0) { "Create was called $n times under -WhatIf" } }

Reset-Stub -Mode 'throw'
Invoke-Case V18 'Create throws -> logged as an error, volume marked failed' `
    -ArgLine ('-Volume C -LogPath "{0}"' -f (Join-Path $work 'v18.log')) -ExpectExit 1 `
    -Expect 'could not create snapshot: stubbed VSS failure', 'failed = C:\\' `
    -Check { $n = Get-StubCalls; if ($n -ne 1) { "Create was called $n times; a thrown error must not be retried" } }

Reset-Stub -Mode 'empty'
Invoke-Case V19 'Create returns 0 with an empty ShadowID' `
    -ArgLine ('-Volume C -LogPath "{0}"' -f (Join-Path $work 'v19.log')) -ExpectExit 0 `
    -Expect 'snapshot created', 'succeeded = C:\\'

Reset-Stub -Code '0'
Invoke-Case V20 'Mixed run: one volume fails, another succeeds' `
    -ArgLine ('-Volume C,ABC -LogPath "{0}"' -f (Join-Path $work 'v20.log')) -ExpectExit 1 `
    -Expect 'succeeded = C:\\', 'failed = ABC'

Reset-Stub -Code '6'
Invoke-Case V21 'A failing volume does not stop the volumes after it' `
    -ArgLine ('-Volume C,D,C -LogPath "{0}"' -f (Join-Path $work 'v21.log')) -ExpectExit 1 `
    -Expect 'is not NTFS' `
    -Check { $n = Get-StubCalls; if ($n -ne 2) { "Create was called $n times, expected 2 (D: is skipped)" } }

$env:YDK_STUB_CODE = $null
$env:YDK_STUB_MODE = $null
$env:YDK_STUB_LOG  = $null

Write-Report -Path (Join-Path $script:TestRoot 'report-vss-return-codes.json')
Stop-Transcript | Out-Null
