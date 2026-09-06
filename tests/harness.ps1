# Shared test harness for ydk.ps1
#
# Every suite dot-sources this file. Nothing is written inside the repository:
# scratch folders, logs and reports all live under $script:TestRoot.
$ErrorActionPreference = 'Continue'
$script:PS       = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:Results  = New-Object System.Collections.Generic.List[object]
$script:TestRoot = Join-Path $env:TEMP 'ydk-tests'
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null

# Two things the tool does get in the way of a suite that installs and removes
# tasks dozens of times to test the registration itself: -Install ends with a
# real snapshot the suite would then have to account for and clean up, and
# -Uninstall deletes the install folder out from under every case that comes
# after it. A suite sets this to $true and Invoke-Case then adds
# -NoInitialSnapshot to every install it runs and turns every -Uninstall into
# -Stop, which removes the same tasks and leaves the files alone. The cases that
# are about those two behaviours opt back in with -InitialSnapshot /
# -RemoveFiles.
$script:SuiteManagesInstall = $false

function Get-YdkScript {
    <# The ydk.ps1 under test: the one in this working copy. #>
    Join-Path $script:RepoRoot 'ydk.ps1'
}

function Get-YdkSetupScript {
    Join-Path $script:RepoRoot 'ydk-setup.ps1'
}

function Assert-SystemTestsAllowed {
    <# The suites under tests\system change the machine: they create and delete
       shadow copies, register scheduled tasks, write to the registry, mount a
       VHD and stop the VSS service for a moment. They put everything back and
       check that they did, but they have no business running on a machine
       somebody depends on. run.ps1 sets this variable after the operator has
       confirmed; running a suite by hand needs it set by hand. #>
    if ($env:YDK_TESTS_ALLOW_SYSTEM -ne '1') {
        Write-Host ''
        Write-Host 'This suite changes the machine it runs on and must only be used on a test' -ForegroundColor Red
        Write-Host 'machine or a virtual machine you can throw away.' -ForegroundColor Red
        Write-Host ''
        Write-Host 'Start it through:  .\tests\run.ps1 -System -IKnowThisIsATestMachine' -ForegroundColor Yellow
        Write-Host 'or set $env:YDK_TESTS_ALLOW_SYSTEM = ''1'' first.' -ForegroundColor Yellow
        Write-Host ''
        exit 9
    }
}

function Get-NonNtfsVolumeLetter {
    <# A drive letter VSS cannot snapshot (a DVD, a FAT32 stick), or $null.
       Suites use it to skip the "not NTFS" cases when the machine has none. #>
    $v = Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue |
         Where-Object { $_.DriveLetter -and $_.FileSystem -and $_.FileSystem -ne 'NTFS' } |
         Select-Object -First 1
    if ($v) { return $v.DriveLetter.TrimEnd(':') }
    return $null
}

function Get-FreeDriveLetter {
    <# A drive letter nothing is using, searched from the end of the alphabet. #>
    param([string[]] $Skip = @())
    $used = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    foreach ($c in @('Y', 'X', 'W', 'V', 'U', 'T', 'S', 'R', 'Q', 'P')) {
        if ($used -notcontains $c -and $Skip -notcontains $c) { return $c }
    }
    return $null
}

function Invoke-Case {
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Name,
        [string] $ScriptPath = $script:SUT,
        [string] $ArgLine = '',
        [ValidateSet('File','Command')][string] $Mode = 'File',
        $ExpectExit = $null,
        [string[]] $Expect = @(),
        [string[]] $NotExpect = @(),
        [scriptblock] $Pre = $null,
        [scriptblock] $Check = $null,
        [switch] $NoRun,
        # Let this case take the first snapshot that -Install ends with.
        [switch] $InitialSnapshot,
        # Let this case run a real -Uninstall, which deletes the install folder.
        [switch] $RemoveFiles
    )

    if ($Pre) { & $Pre | Out-Null }

    # See $script:SuiteManagesInstall above. ydk-setup.ps1 is covered by the
    # first rule too: it hands the switch straight through to "ydk.ps1 -Install".
    if ($script:SuiteManagesInstall -and -not $InitialSnapshot -and
        $ArgLine -notmatch '-NoInitialSnapshot' -and
        ($ArgLine -match '(^|\s)-Install(\s|$)' -or $ScriptPath -like '*ydk-setup.ps1')) {
        $ArgLine = ($ArgLine + ' -NoInitialSnapshot').Trim()
    }

    if ($script:SuiteManagesInstall -and -not $RemoveFiles -and
        $ArgLine -match '(^|\s)-Uninstall(\s|$)') {
        $ArgLine = $ArgLine -replace '(^|\s)-Uninstall(\s|$)', '$1-Stop$2'
    }

    $o = Join-Path $script:OutDir "$Id.out.txt"
    $e = Join-Path $script:OutDir "$Id.err.txt"

    if ($Mode -eq 'File') {
        $cmdline = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f $ScriptPath, $ArgLine
    } else {
        $inner   = '$LASTEXITCODE=0; & ''{0}'' {1}; exit $LASTEXITCODE' -f $ScriptPath, $ArgLine
        $cmdline = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "{0}"' -f $inner
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p  = Start-Process -FilePath $script:PS -ArgumentList $cmdline -NoNewWindow -Wait -PassThru `
                        -RedirectStandardOutput $o -RedirectStandardError $e
    $sw.Stop()

    $out = (Get-Content -LiteralPath $o -Raw -ErrorAction SilentlyContinue)
    $err = (Get-Content -LiteralPath $e -Raw -ErrorAction SilentlyContinue)
    $all = ($out + "`n" + $err)
    $code = $p.ExitCode

    # PowerShell wraps error text at the console width, which can split a word
    # in half ("LogRetentionDa\nys"). Patterns are matched against the raw output
    # and, failing that, against a copy with every run of whitespace collapsed.
    $glued = ($all -replace "`r", '' -replace "`n", '')
    $problems = New-Object System.Collections.Generic.List[string]
    if ($null -ne $ExpectExit -and $code -ne $ExpectExit) {
        $problems.Add("exit code $code, expected $ExpectExit")
    }
    foreach ($pat in $Expect) {
        if ($all -notmatch $pat -and $glued -notmatch $pat) { $problems.Add("missing pattern: $pat") }
    }
    foreach ($pat in $NotExpect) {
        if ($all -match $pat -or $glued -match $pat) { $problems.Add("unexpected pattern: $pat") }
    }
    if ($Check) {
        # A broken assertion must fail its own case, not tear down the phase.
        try {
            $r = & $Check
            if ($r) { foreach ($x in @($r)) { $problems.Add([string]$x) } }
        } catch {
            $problems.Add("the check itself threw: $($_.Exception.Message)")
        }
    }

    $status = if ($problems.Count -eq 0) { 'PASS' } else { 'FAIL' }
    $script:Results.Add([pscustomobject]@{
        Id = $Id; Name = $Name; Cmd = $cmdline; Exit = $code; Status = $status
        Problems = ($problems -join ' | '); Ms = [int]$sw.ElapsedMilliseconds
        Output = $all
    })

    $col = if ($status -eq 'PASS') { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1,-6} {2,-4} exit={3,-3} {4}" -f $status, $Id, '', $code, $Name) -ForegroundColor $col
    if ($problems.Count) { foreach ($x in $problems) { Write-Host "        -> $x" -ForegroundColor Red } }
}

function Add-Result {
    param([string]$Id,[string]$Name,[string]$Status,[string]$Problems='',[string]$Output='')
    $script:Results.Add([pscustomobject]@{
        Id=$Id; Name=$Name; Cmd='(inline)'; Exit=$null; Status=$Status; Problems=$Problems; Ms=0; Output=$Output })
    $col = switch ($Status) { 'PASS' {'Green'} 'FAIL' {'Red'} default {'Yellow'} }
    Write-Host ("[{0}] {1,-6}      {2}" -f $Status, $Id, $Name) -ForegroundColor $col
    if ($Problems) { Write-Host "        -> $Problems" -ForegroundColor $col }
}

function Write-Report {
    param([string]$Path)
    $script:Results | Select-Object Id,Name,Status,Exit,Problems,Ms,Cmd |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
    $full = [IO.Path]::ChangeExtension($Path, '.full.txt')
    $sb = New-Object Text.StringBuilder
    foreach ($r in $script:Results) {
        [void]$sb.AppendLine(('=' * 100))
        [void]$sb.AppendLine("[$($r.Status)] $($r.Id)  $($r.Name)   exit=$($r.Exit)")
        [void]$sb.AppendLine("CMD: $($r.Cmd)")
        if ($r.Problems) { [void]$sb.AppendLine("PROBLEMS: $($r.Problems)") }
        [void]$sb.AppendLine('--- output ---')
        [void]$sb.AppendLine($r.Output)
    }
    Set-Content -LiteralPath $full -Value $sb.ToString() -Encoding UTF8
    $p = @($script:Results | Where-Object Status -eq 'PASS').Count
    $f = @($script:Results | Where-Object Status -eq 'FAIL').Count
    $s = @($script:Results | Where-Object Status -notin 'PASS','FAIL').Count
    Write-Host ''
    Write-Host ("TOTAL {0}  PASS {1}  FAIL {2}  OTHER {3}" -f $script:Results.Count, $p, $f, $s) -ForegroundColor Cyan

    # run.ps1 builds its summary from this file: suites report through Write-Host,
    # which never reaches the pipeline, so the caller cannot read their output.
    $name = [IO.Path]::GetFileNameWithoutExtension($Path) -replace '^report-', ''
    Add-Content -LiteralPath (Join-Path $script:TestRoot 'summary.txt') `
                -Value ("{0}|{1}|{2}|{3}|{4}" -f $name, $script:Results.Count, $p, $f, $s) -Encoding UTF8
    Write-Host "report: $Path"
    Write-Host "full  : $full"
}
