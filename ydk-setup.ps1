<#
Copyright (C) 2026 Savas Sahin <savashn@proton.me>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
#>

<#
    Copies ydk.ps1 to a folder only administrators can write to and installs the
    scheduled tasks from there.

    Everything this file does can be typed by hand in three commands (see the
    README). What it adds is that it elevates itself, so a technician can start
    it from an ordinary window, and that it prints the health report afterwards
    so a failed install cannot go unnoticed.

    It deliberately does NOT delete the copy it was started from. That is one
    Remove-Item, and doing it automatically would destroy the master copy for
    anyone who runs this straight off a deployment share or a USB stick.

    All the real work stays in ydk.ps1: this file registers nothing itself, and
    the location check that refuses a user-writable install folder lives there.
#>

[CmdletBinding()]
param(
    # Where ydk.ps1 should live. Ordinary users must not be able to write here;
    # ydk.ps1 -Install refuses the install otherwise.
    [string] $Destination = 'C:\Program Files\YDK',

    # Passed straight through to "ydk.ps1 -Install" when given.
    [string[]] $Time,
    [string[]] $Volume,
    [int]      $LogRetentionDays,
    [string]   $TaskPrefix,

    # Passed through as well: "ydk.ps1 -Install" ends with a first snapshot
    # unless this is given.
    [switch]   $NoInitialSnapshot,

    # Set on the copy that this script starts elevated; it stops an endless
    # relaunch loop if elevation somehow does not raise the token.
    [switch] $Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Exit-WithError {
    param([Parameter(Mandatory)][string] $Message, [int] $Code = 2)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit $Code
}

# --- the tool has to be next to this file ----------------------------------
# Checked before elevating, so a missing file does not cost a UAC prompt first.
$source = Join-Path $PSScriptRoot 'ydk.ps1'
if (-not (Test-Path -LiteralPath $source)) {
    Exit-WithError "ydk.ps1 is not in the same folder as this script ($PSScriptRoot). Copy both files to the same folder and try again."
}

# --- elevate ----------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin   = ([Security.Principal.WindowsPrincipal] $identity).IsInRole(
                 [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    if ($Elevated) {
        Exit-WithError 'Still not running as administrator after elevating. Open PowerShell with "Run as administrator" and start this script again.'
    }

    # Rebuild the command line for the elevated copy. -NoExit keeps the new
    # window open so whoever started this can read the result; the exit code of
    # that window is therefore not reported back here. Scripted installs should
    # run this from an already elevated shell instead.
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $PSCommandPath), '-Elevated')
    foreach ($name in @('Destination', 'TaskPrefix')) {
        if ($PSBoundParameters.ContainsKey($name)) { $argList += @("-$name", ('"{0}"' -f $PSBoundParameters[$name])) }
    }
    foreach ($name in @('LogRetentionDays')) {
        if ($PSBoundParameters.ContainsKey($name)) { $argList += @("-$name", $PSBoundParameters[$name]) }
    }
    foreach ($name in @('Time', 'Volume')) {
        if ($PSBoundParameters.ContainsKey($name)) { $argList += @("-$name", ('"{0}"' -f ($PSBoundParameters[$name] -join ','))) }
    }
    # Switches carry no value; passing one would bind as a positional argument.
    foreach ($name in @('NoInitialSnapshot')) {
        if ($PSBoundParameters.ContainsKey($name)) { $argList += "-$name" }
    }

    Write-Host 'Administrator rights are needed; asking for them now...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                      -ArgumentList $argList -Verb RunAs -ErrorAction Stop | Out-Null
    } catch {
        Exit-WithError "Elevation was cancelled or failed: $($_.Exception.Message)"
    }

    Write-Host 'The installation continues in the elevated window that just opened.'
    exit 0
}

# --- copy -------------------------------------------------------------------
Write-Host ''
Write-Host ('Installing YDK into: {0}' -f $Destination)

if (-not (Test-Path -LiteralPath $Destination)) {
    try {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Write-Host "  created $Destination"
    } catch {
        Exit-WithError "Could not create '$Destination': $($_.Exception.Message)"
    }
}

$target = Join-Path $Destination 'ydk.ps1'

if ((Resolve-Path -LiteralPath $source).Path -ieq $target) {
    Write-Host '  already running from the destination; nothing to copy'
} else {
    try {
        Copy-Item -LiteralPath $source -Destination $target -Force
        Write-Host "  copied ydk.ps1 to $target"
    } catch {
        Exit-WithError "Could not copy ydk.ps1 to '$target': $($_.Exception.Message)"
    }
}

# --- install ----------------------------------------------------------------
# Whatever the caller passed is handed over unchanged; ydk.ps1 owns every
# decision from here on, including refusing a folder ordinary users can write to.
$installArgs = @{}
foreach ($name in @('Time', 'Volume', 'LogRetentionDays', 'TaskPrefix', 'NoInitialSnapshot')) {
    if ($PSBoundParameters.ContainsKey($name)) { $installArgs[$name] = $PSBoundParameters[$name] }
}

Write-Host ''
& $target -Install @installArgs
$code = $LASTEXITCODE
if ($code -ne 0) {
    Exit-WithError "ydk.ps1 -Install failed (exit code $code). Nothing else was changed." $code
}

# --- verify -----------------------------------------------------------------
Write-Host ''
Write-Host 'Checking the result:' -ForegroundColor Cyan
$statusArgs = @{}
if ($PSBoundParameters.ContainsKey('TaskPrefix')) { $statusArgs['TaskPrefix'] = $TaskPrefix }
& $target -Status @statusArgs
$statusCode = $LASTEXITCODE

Write-Host ''
Write-Host "Installed: $target" -ForegroundColor Green
if ((Resolve-Path -LiteralPath $source).Path -ine $target) {
    Write-Host 'The copy you started from is not used any more. On the machine being set up you can remove it:'
    Write-Host ("    Remove-Item '{0}'" -f $source)
    Write-Host 'Keep your master copy (repository, deployment share) where it is.'
}

# The health report exits with 1 when it finds anything worth mentioning. That
# says nothing about whether the install worked, so it is reported, not passed
# on. Since -Install ends with a first snapshot, the report is normally clean
# here; with -NoInitialSnapshot the machine has no shadow copies yet and the
# report will say so.
if ($statusCode -ne 0) {
    Write-Host ''
    Write-Host 'The health report above lists something to look at.' -ForegroundColor Yellow
    if ($NoInitialSnapshot) {
        Write-Host 'On a machine that has not taken its first snapshot yet, that is expected.' -ForegroundColor Yellow
    }
}

exit 0
