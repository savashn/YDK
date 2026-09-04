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
    Runs the test suites for ydk.ps1.

        .\tests\run.ps1                                       safe suites only
        .\tests\run.ps1 -System -IKnowThisIsATestMachine       everything

    The safe suites need no administrator rights and change nothing outside
    their own scratch folder. The system suites take real snapshots, register
    scheduled tasks, write to the registry, mount a VHD and stop the VSS
    service for a moment. They put all of it back and verify that they did, but
    they must only be run on a machine you can throw away - see tests\README.md.
#>

[CmdletBinding()]
param(
    [switch] $Safe,
    [switch] $System,
    [switch] $IKnowThisIsATestMachine
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $Safe -and -not $System) { $Safe = $true }

if ($System) {
    if (-not $IKnowThisIsATestMachine) {
        Write-Host ''
        Write-Host 'The system suites change this machine. Run them on a virtual machine or a' -ForegroundColor Red
        Write-Host 'test box only, and confirm with:' -ForegroundColor Red
        Write-Host ''
        Write-Host '    .\tests\run.ps1 -System -IKnowThisIsATestMachine' -ForegroundColor Yellow
        Write-Host ''
        exit 2
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                   [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host 'ERROR: the system suites need an elevated PowerShell window.' -ForegroundColor Red
        exit 2
    }

    $env:YDK_TESTS_ALLOW_SYSTEM = '1'
}

$suites = @()
if ($Safe)   { $suites += @(Get-ChildItem (Join-Path $here 'safe')   -Filter '*.ps1' | Sort-Object Name) }
if ($System) { $suites += @(Get-ChildItem (Join-Path $here 'system') -Filter '*.ps1' | Sort-Object Name) }

# The suites report through Write-Host, which does not reach the pipeline, so
# each one appends its counts to this file as it finishes.
$testRoot   = Join-Path $env:TEMP 'ydk-tests'
$summaryLog = Join-Path $testRoot 'summary.txt'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
Remove-Item -LiteralPath $summaryLog -ErrorAction SilentlyContinue

foreach ($suite in $suites) {
    Write-Host ''
    Write-Host ('#' * 100) -ForegroundColor Cyan
    Write-Host ("# {0}" -f $suite.Name) -ForegroundColor Cyan
    Write-Host ('#' * 100) -ForegroundColor Cyan
    & $suite.FullName
}

$summary = @()
foreach ($line in @(Get-Content -LiteralPath $summaryLog -ErrorAction SilentlyContinue)) {
    $parts = $line -split '\|'
    if ($parts.Count -eq 5) {
        $summary += [pscustomobject]@{
            Suite = $parts[0]; Total = [int]$parts[1]; Pass = [int]$parts[2]
            Fail  = [int]$parts[3]; Skipped = [int]$parts[4]
        }
    }
}

Write-Host ''
Write-Host ('=' * 100)
Write-Host 'SUMMARY'
if (-not $summary.Count) {
    Write-Host 'No suite reported a result - something went wrong before the first one finished.' -ForegroundColor Red
    exit 1
}
$summary | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

if ($summary.Count -ne $suites.Count) {
    Write-Host ("Only {0} of {1} suites reported a result; one of them stopped early." -f
                $summary.Count, $suites.Count) -ForegroundColor Red
    exit 1
}

$failed = @($summary | Where-Object { $_.Fail -gt 0 })
if ($failed.Count) {
    Write-Host ("{0} suite(s) reported failures." -f $failed.Count) -ForegroundColor Red
    exit 1
}

Write-Host ("All suites passed: {0} checks, {1} skipped." -f
            (($summary | Measure-Object Total -Sum).Sum), (($summary | Measure-Object Skipped -Sum).Sum)) -ForegroundColor Green
Write-Host ("Reports and transcripts: {0}" -f $testRoot)
exit 0
