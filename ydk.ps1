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

[CmdletBinding(DefaultParameterSetName = 'Snapshot', SupportsShouldProcess = $true)]
param(
    [Parameter(ParameterSetName = 'Install', Mandatory)]
    [switch] $Install,

    [Parameter(ParameterSetName = 'Uninstall', Mandatory)]
    [switch] $Uninstall,

    [Parameter(ParameterSetName = 'Status', Mandatory)]
    [switch] $Status,

    [Parameter(ParameterSetName = 'Snapshot')]
    [Parameter(ParameterSetName = 'Install')]
    [string[]] $Volume = @('C', 'D'),

    [Parameter(ParameterSetName = 'Install')]
    [string[]] $Time = @('10:00', '13:00', '16:00'),

    [Parameter(ParameterSetName = 'Install')]
    [Parameter(ParameterSetName = 'Uninstall')]
    [Parameter(ParameterSetName = 'Status')]
    [string] $TaskPrefix = 'YDK',

    # -Install refuses to register a task for a script that non-administrators
    # can overwrite. This switch installs anyway; see Get-UnsafeWriteAccess.
    [Parameter(ParameterSetName = 'Install')]
    [switch] $SkipLocationCheck,

    # Both of the following are unset by default: when not passed, Windows' own
    # VSS defaults (10% storage cap, 64 shadow copies per volume) are left alone.
    [Parameter(ParameterSetName = 'Install')]
    [string] $ShadowStorageMaxSize,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateRange(1, 512)]
    [int] $MaxShadowCopies,

    [Parameter(ParameterSetName = 'Snapshot')]
    [string] $LogPath,

    [Parameter(ParameterSetName = 'Snapshot')]
    [Parameter(ParameterSetName = 'Install')]
    [ValidateRange(0, 3650)]
    [int] $LogRetentionDays = 90,

    [Parameter(ParameterSetName = 'Snapshot')]
    [switch] $FailOnMissingVolume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# How hard to retry when VSS reports "another shadow copy operation is already
# in progress" (Win32_ShadowCopy::Create return code 9).
$script:SnapshotRetryCount        = 3
$script:SnapshotRetryDelaySeconds = 10

# Task Scheduler runs the script as "powershell.exe -File ydk.ps1 -Volume C,D".
# In -File mode arguments are passed as plain text, so "C,D" does not become an
# array - it arrives as a single string. Writing "-Volume C D" instead silently
# swallows the second value. So we split comma-separated values ourselves here,
# which makes the script behave identically whether it is invoked through -File
# or from a normal PowerShell prompt.
$Volume = @($Volume |
            ForEach-Object { $_ -split ',' } |
            ForEach-Object { $_.Trim() } |
            Where-Object   { $_ })

# -Time has exactly the same problem: "10:00,13:00" reaches the script as one
# string in -File mode, and without splitting it here every one of those runs
# fails with "Invalid time".
$Time = @($Time |
          ForEach-Object { $_ -split ',' } |
          ForEach-Object { $_.Trim() } |
          Where-Object   { $_ })

# ===========================================================================
# Shared helpers
# ===========================================================================

function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal] $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Note: because $ErrorActionPreference is 'Stop', Write-Error is itself
# terminating and any 'exit' statement after it is never reached. To keep exit
# codes reliable we report fatal errors with Write-Host and exit explicitly.
function Exit-WithError {
    param([Parameter(Mandatory)][string] $Message, [int] $Code = 2)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit $Code
}

function ConvertTo-VolumeRoot {
    # "c", "C:", "C:\", "c:/" -> "C:\"
    param([Parameter(Mandatory)][string] $Value)

    $v = $Value.Trim().Trim('"')
    if ($v -match '^[A-Za-z]$')        { return ($v.ToUpperInvariant() + ':\') }
    if ($v -match '^[A-Za-z]:[\\/]?$') { return ($v.Substring(0, 1).ToUpperInvariant() + ':\') }

    throw "Invalid volume value: '$Value'. Expected one of 'C', 'C:' or 'C:\'."
}

# ===========================================================================
# Install / uninstall
# ===========================================================================

function Get-UnsafeWriteAccess {
    <# Lists the access rules that would let someone who is not an administrator
       replace the given file, either directly or by writing in the folder that
       holds it.

       This is the one thing that decides whether the tool is safe to install on
       a machine other people use: the scheduled task runs the script as SYSTEM,
       so whoever can change the file can run their own code as SYSTEM. Folder
       rights count as well - being able to create or delete files in the folder
       is enough to swap the script out.

       Note that a folder created directly under C:\ inherits an
       "Authenticated Users: Modify" entry from the root, so C:\YDK is writable
       by every logged-on user. C:\Program Files gives ordinary users read and
       execute only, which is why that is the recommended location. #>
    param([Parameter(Mandatory)][string] $Path)

    # The identities that are supposed to have write access to program files.
    $trusted = @(
        'S-1-5-18',      # NT AUTHORITY\SYSTEM
        'S-1-5-32-544',  # BUILTIN\Administrators
        'S-1-3-0',       # CREATOR OWNER (applies to whoever creates a child item)
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'  # TrustedInstaller
    )

    # Rights that allow the file to be replaced. The two generic bits at the end
    # (GENERIC_ALL and GENERIC_WRITE) are how inherited entries often show up.
    $rights = [int] ([Security.AccessControl.FileSystemRights]::WriteData -bor
                     [Security.AccessControl.FileSystemRights]::AppendData -bor
                     [Security.AccessControl.FileSystemRights]::Delete -bor
                     [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
                     [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
                     [Security.AccessControl.FileSystemRights]::TakeOwnership)
    $mask = $rights -bor 0x10000000 -bor 0x40000000

    $found = New-Object System.Collections.Generic.List[string]

    foreach ($item in @($Path, (Split-Path -Parent $Path))) {
        if (-not $item) { continue }

        # Nothing to judge about a path that is not there. For -Install the
        # script file always exists; this only skips a parent that does not.
        if (-not (Test-Path -LiteralPath $item)) { continue }

        try {
            $acl = Get-Acl -LiteralPath $item -ErrorAction Stop
        } catch {
            # Being unable to read the permissions is itself a reason to stop.
            $found.Add("$item - permissions could not be read: $($_.Exception.Message)")
            continue
        }

        foreach ($ace in $acl.Access) {
            if ($ace.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }

            # An inherit-only entry does not grant anything on this item itself.
            if (($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }

            if (([int] $ace.FileSystemRights -band $mask) -eq 0) { continue }

            $sid = $null
            try { $sid = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
            if ($sid -and ($trusted -contains $sid)) { continue }

            # CAUTION: the extra pair of parentheses is required. Inside a method
            # call the commas would otherwise separate arguments to Add(), and
            # the format string would be left with a single value to fill in.
            $found.Add(("{0} - {1} : {2}" -f $item, $ace.IdentityReference, $ace.FileSystemRights))
        }
    }

    return $found
}

function Install-YdkTask {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]   $SelfPath,
        [Parameter(Mandatory)][string[]] $TaskTime,
        [Parameter(Mandatory)][string[]] $TaskVolume,
        [Parameter(Mandatory)][int]      $LogDays,
        [Parameter(Mandatory)][string]   $Prefix
    )

    # The task runs as SYSTEM, so the folder holding the script has to be
    # reachable machine-wide. Paths under a user profile (Desktop, Documents,
    # OneDrive and so on) can be inaccessible to SYSTEM, so warn about them.
    if ($SelfPath -like "$env:SystemDrive\Users\*") {
        Write-Host ''
        Write-Host 'WARNING: the script lives under a user profile:' -ForegroundColor Yellow
        Write-Host "         $SelfPath" -ForegroundColor Yellow
        Write-Host '         The task will run as SYSTEM. Profile folders (especially ones synced' -ForegroundColor Yellow
        Write-Host '         by OneDrive) may not be accessible to SYSTEM. Moving the script to a' -ForegroundColor Yellow
        Write-Host '         shared location such as C:\YDK is recommended.' -ForegroundColor Yellow
        Write-Host ''
    }

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    # CAUTION: in powershell.exe -File mode arguments are passed as plain text,
    # so "C,D" is not converted into an array and "-Volume C D" would silently
    # swallow the second value. That is why we join with commas here and let the
    # script split the string itself (see the top of this file). Do not change
    # this to space-separated arguments.
    $scriptArgs = @('-Volume', ($TaskVolume -join ','))
    if ($LogDays -ne 90) { $scriptArgs += @('-LogRetentionDays', $LogDays) }

    $argument = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" {1}' -f
                $SelfPath, ($scriptArgs -join ' ')

    $action = New-ScheduledTaskAction -Execute $powershell -Argument $argument `
                                      -WorkingDirectory (Split-Path -Parent $SelfPath)

    # SYSTEM + highest privileges: no UAC prompt, no VBS helper needed, and the
    # task runs even when nobody is logged on.
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' `
                                            -LogonType ServiceAccount `
                                            -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                                             -DontStopIfGoingOnBatteries `
                                             -StartWhenAvailable `
                                             -MultipleInstances IgnoreNew `
                                             -ExecutionTimeLimit (New-TimeSpan -Hours 1)

    # CAUTION: the type must be [string[]] for the array overload of
    # TryParseExact to be selected. Passing @(...) (Object[]) makes PowerShell
    # fall back to the single-string overload, which rejects even valid times.
    [string[]] $timeFormats = @('HH:mm', 'H:mm', 'HH:mm:ss')

    # Parse EVERY time before touching the task store. Validating inside the
    # registration loop instead would leave a half-installed schedule behind:
    # "-Time 10:00,xx" would register YDK0 and only then abort.
    $schedule = New-Object System.Collections.Generic.List[object]
    foreach ($t in $TaskTime) {

        [datetime] $parsed = [datetime]::MinValue
        $ok = [datetime]::TryParseExact($t, $timeFormats,
                                        [Globalization.CultureInfo]::InvariantCulture,
                                        [Globalization.DateTimeStyles]::None, [ref] $parsed)
        if (-not $ok) {
            Exit-WithError "Invalid time: '$t'. Expected 'HH:mm' format (for example 21:00)."
        }

        $schedule.Add([pscustomobject]@{ Text = $t; TimeOfDay = $parsed.TimeOfDay })
    }

    # Drop the tasks this tool already owns under this prefix. Without this an
    # install with fewer times than the previous one leaves the extra tasks
    # (YDK2 and up) behind, still firing on yesterday's schedule. The same
    # Test-IsYdkTask guard as -Uninstall decides what may be removed, so a
    # foreign task is never deleted here.
    foreach ($old in @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue |
                       Where-Object { Test-IsYdkTask -Task $_ -Prefix $Prefix })) {
        if ($PSCmdlet.ShouldProcess($old.TaskName, 'Remove the previously installed task')) {
            Unregister-ScheduledTask -TaskName $old.TaskName -TaskPath '\' -Confirm:$false
            Write-Host "Removed existing task '$($old.TaskName)'." -ForegroundColor Yellow
        }
    }

    $index = 0
    foreach ($item in $schedule) {

        $t        = $item.Text
        $taskName = "$Prefix$index"
        $index++

        # TryParseExact leaves the date part at 0001-01-01; combine the time
        # with today's date so the trigger gets a valid start boundary.
        $at = (Get-Date).Date.Add($item.TimeOfDay)
        $trigger = New-ScheduledTaskTrigger -Daily -At $at

        if (-not $PSCmdlet.ShouldProcess($taskName, "Register daily task at $t")) { continue }

        # Our own tasks are already gone by now, so this only catches a
        # same-named task we do not recognise - typically one left behind by the
        # old BAT/VBS install. Scoped to the root folder so a same-named task
        # living under \Microsoft\Windows\... is never touched.
        if (Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false
            Write-Host "Removed existing task '$taskName' (it will be re-registered)." -ForegroundColor Yellow
        }

        Register-ScheduledTask -TaskName $taskName `
                               -Action $action `
                               -Trigger $trigger `
                               -Principal $principal `
                               -Settings $settings `
                               -Description "YDK daily VSS snapshot ($t) - ydk.ps1" | Out-Null

        Write-Host "Registered: $taskName  (daily at $t)" -ForegroundColor Green
    }

    Write-Host ''
    Write-Host 'Install complete.' -ForegroundColor Green
    Write-Host "Command the task will run: $powershell $argument"
    Write-Host ''
    Write-Host 'To try it right away:'
    Write-Host "  Start-ScheduledTask -TaskName '${Prefix}0'"
    Write-Host "  Get-ScheduledTaskInfo -TaskName '${Prefix}0'"
    Write-Host ''
    Write-Host 'To remove:  .\ydk.ps1 -Uninstall'
}

function Test-IsYdkTask {
    <# A task counts as ours only if ALL of the following hold. This is the guard
       that keeps -Uninstall from touching anything it did not create.

       DO NOT loosen this to a "$Prefix*" wildcard. Get-ScheduledTask -TaskName
       "T*" matches every task on the machine whose name starts with T, in every
       folder - Tpm-Maintenance, ThemesSyncedImageDownload and so on - and
       Unregister-ScheduledTask will happily delete all of them. #>
    param(
        [Parameter(Mandatory)] $Task,
        [Parameter(Mandatory)][string] $Prefix
    )

    # 1) Registered at the root folder, which is where Install-YdkTask puts them.
    if ($Task.TaskPath -ne '\') { return $false }

    # 2) Name is exactly the prefix followed by digits: YDK0, YDK1, ... and
    #    nothing else. "YDKSomethingElse" does not match.
    if ($Task.TaskName -notmatch ('^{0}\d+$' -f [regex]::Escape($Prefix))) { return $false }

    # 3) It actually points at this tool: either the description we stamp on it,
    #    or an action that runs ydk.ps1 (Yedek.ps1 covers installs made by the
    #    older name).
    if ($Task.Description -like 'YDK daily VSS snapshot*') { return $true }

    foreach ($a in @($Task.Actions)) {
        # A task can come back with Actions = $null; under Set-StrictMode that
        # would turn the property access below into a terminating error.
        if ($null -eq $a) { continue }

        if ($a.PSObject.Properties.Name -contains 'Arguments' -and
            ($a.Arguments -like '*ydk.ps1*' -or $a.Arguments -like '*Yedek.ps1*')) { return $true }
    }

    return $false
}

function Uninstall-YdkTask {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string] $Prefix)

    $tasks = @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue |
               Where-Object { Test-IsYdkTask -Task $_ -Prefix $Prefix })

    if (-not $tasks) {
        Write-Host "No tasks of this tool found with the prefix '$Prefix'." -ForegroundColor Yellow
        return
    }

    foreach ($t in $tasks) {
        if ($PSCmdlet.ShouldProcess($t.TaskName, 'Delete scheduled task')) {
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath '\' -Confirm:$false
            Write-Host "Deleted: $($t.TaskName)" -ForegroundColor Green
        }
    }
}

function Get-ShadowStorageMaxGB {
    <# Current shadow storage cap for a volume, in GB, or $null if the volume has
       no storage association yet. #>
    param([Parameter(Mandatory)][string] $VolumeRoot)

    $vol = Get-CimInstance -ClassName Win32_Volume `
                           -Filter ("Name = '{0}'" -f $VolumeRoot.Replace('\', '\\')) -ErrorAction SilentlyContinue
    if (-not $vol) { return $null }

    $assoc = Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction SilentlyContinue |
             Where-Object { $_.Volume.DeviceID -eq $vol.DeviceID }
    if (-not $assoc) { return $null }

    return [math]::Round(($assoc | Select-Object -First 1).MaxSpace / 1GB, 2)
}

function Set-ShadowStorageMaxSize {
    <# Applies an explicit shadow storage cap to a volume via vssadmin. Only ever
       called when the caller passed -ShadowStorageMaxSize; without it Windows'
       own 10% default is left in place. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string] $VolumeRoot,
        [Parameter(Mandatory)][string] $Spec
    )

    $drive = $VolumeRoot.TrimEnd('\')          # "C:\" -> "C:"

    $target = Get-CimInstance -ClassName Win32_Volume `
                              -Filter ("Name = '{0}'" -f $VolumeRoot.Replace('\', '\\')) -ErrorAction SilentlyContinue
    if (-not $target) {
        Write-Host "  $drive - volume not present, skipping shadow storage." -ForegroundColor Yellow
        return
    }
    if ($target.FileSystem -ne 'NTFS') {
        Write-Host "  $drive - not NTFS, skipping shadow storage." -ForegroundColor Yellow
        return
    }

    $currentGB = Get-ShadowStorageMaxGB -VolumeRoot $VolumeRoot
    $currentText = if ($null -eq $currentGB) { 'not set (Windows default)' } else { "$currentGB GB" }

    if (-not $PSCmdlet.ShouldProcess("$drive shadow storage", "Set maximum size to $Spec (current: $currentText)")) {
        return
    }

    $out = & vssadmin.exe resize shadowstorage /For=$drive /On=$drive /MaxSize=$Spec 2>&1

    if ($LASTEXITCODE -eq 0) {
        $newGB = Get-ShadowStorageMaxGB -VolumeRoot $VolumeRoot
        Write-Host "  $drive - shadow storage cap: $currentText -> $newGB GB" -ForegroundColor Green
        if ($null -ne $currentGB -and $null -ne $newGB -and $newGB -lt $currentGB) {
            Write-Host "  $drive - note: the cap was lowered, which can delete existing shadow copies." -ForegroundColor Yellow
        }
    } else {
        # Not fatal: snapshots still work, they just have less room to live in.
        Write-Host "  $drive - could not resize shadow storage (exit $LASTEXITCODE):" -ForegroundColor Yellow
        $out | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }
    }
}

function Set-MaxShadowCopies {
    <# Overrides the maximum number of shadow copies Windows keeps per volume.
       This is the only registry value the script ever writes, and only when
       -MaxShadowCopies was passed explicitly. Without it the OS default of 64
       per volume applies. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][ValidateRange(1, 512)][int] $Value)

    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\VSS\Settings'

    $prop    = Get-ItemProperty -Path $key -Name MaxShadowCopies -ErrorAction SilentlyContinue
    $current = if ($prop) { $prop.MaxShadowCopies } else { $null }
    $currentText = if ($null -eq $current) { 'not set (OS default, 64)' } else { $current }

    if ($current -eq $Value) {
        Write-Host "  MaxShadowCopies is already $Value; left unchanged."
        return
    }

    if (-not $PSCmdlet.ShouldProcess("$key\MaxShadowCopies", "Set to $Value (current: $currentText)")) {
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $key)) {
            New-Item -Path $key -Force | Out-Null
        }
        Set-ItemProperty -Path $key -Name MaxShadowCopies -Value $Value -Type DWord -ErrorAction Stop
        Write-Host "  MaxShadowCopies: $currentText -> $Value" -ForegroundColor Green
        Write-Host "  (applies to shadow copies created from now on; nothing is deleted immediately)"
    } catch {
        # Not fatal: snapshots still work, they are just capped at the old count.
        Write-Host "  Could not set MaxShadowCopies: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Unblock-SelfFile {
    <# Windows tags files that arrive from another machine over a network share,
       e-mail or a browser with a "Internet zone" mark (MOTW). Under the default
       RemoteSigned execution policy that mark blocks an unsigned script from
       being run by hand. We clear it once during install so later manual runs
       are not blocked.

       Note: the scheduled task carries -ExecutionPolicy Bypass on its command
       line, so the task itself is unaffected by the mark either way. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string] $Path)

    $zone = Get-Item -LiteralPath $Path -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue

    if (-not $zone) {
        Write-Host 'No download mark (MOTW) on the file; nothing to unblock.'
        return
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Remove the download mark (Unblock-File)')) {
        try {
            Unblock-File -LiteralPath $Path -ErrorAction Stop
            Write-Host "Removed the download mark (MOTW) from: $Path" -ForegroundColor Yellow
        } catch {
            # Not fatal: the task already runs with Bypass, only manual runs can
            # trip over the execution policy.
            Write-Host "Could not remove the download mark ($Path): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# ===========================================================================
# Status
# ===========================================================================

function Show-Status {
    <# One-screen health report: are the tasks there, did they run, how many
       snapshots exist, and how close is the machine to either VSS ceiling.
       Returns the number of problems found so the caller can turn it into an
       exit code - that is what makes it usable from a fleet monitoring script. #>
    param([Parameter(Mandatory)][string] $Prefix)

    $warn = New-Object System.Collections.Generic.List[string]

    Write-Host ("YDK status - {0} - {1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ('=' * 72)

    # --- Scheduled tasks --------------------------------------------------
    Write-Host ''
    Write-Host 'Scheduled tasks'
    $tasks = @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue |
               Where-Object { Test-IsYdkTask -Task $_ -Prefix $Prefix } |
               Sort-Object TaskName)

    if (-not $tasks) {
        Write-Host "  none registered with the prefix '$Prefix'" -ForegroundColor Yellow
        $warn.Add("No scheduled tasks with the prefix '$Prefix' - snapshots are not automated on this machine.")
    }

    foreach ($t in $tasks) {
        $i    = $t | Get-ScheduledTaskInfo
        $last = if ($i.LastRunTime -and $i.LastRunTime.Year -gt 2000) { $i.LastRunTime.ToString('yyyy-MM-dd HH:mm') } else { 'never' }
        $next = if ($i.NextRunTime) { $i.NextRunTime.ToString('yyyy-MM-dd HH:mm') } else { '-' }
        $res  = switch ($i.LastTaskResult) {
                    0      { 'ok' }
                    267011 { 'not yet run' }
                    267009 { 'running' }
                    default { "FAILED ($($i.LastTaskResult))" }
                }
        # A task can have no trigger at all (edited by hand in Task Scheduler, or
        # imported from a broken XML), and a trigger can carry an empty
        # StartBoundary. Indexing Triggers[0] blindly turns the whole status
        # report into "Cannot index into a null array", so read it defensively.
        $trigger = @($t.Triggers) | Select-Object -First 1
        $at = '-'
        if ($trigger -and $trigger.StartBoundary) {
            try   { $at = ([datetime] $trigger.StartBoundary).ToString('HH:mm') }
            catch { $at = '?' }
        }

        $colour = if ($res -like 'FAILED*') { 'Red' } else { 'Gray' }
        Write-Host ("  {0,-8} {1,-7} {2,-6} last={3,-17} result={4,-14} next={5}" -f
                    $t.TaskName, $t.Principal.UserId, $at,
                    $last, $res, $next) -ForegroundColor $colour

        if ($res -like 'FAILED*')    { $warn.Add("Task $($t.TaskName) last finished with result $($i.LastTaskResult) - check the log.") }
        if ($t.State -eq 'Disabled') { $warn.Add("Task $($t.TaskName) is disabled.") }
        if (-not $trigger)           { $warn.Add("Task $($t.TaskName) has no trigger, so it never runs on its own.") }
    }

    # --- Snapshots and storage, per volume --------------------------------
    Write-Host ''
    Write-Host 'Snapshots'
    $shadows = @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue)
    $vols    = @(Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue |
                 Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'NTFS' })

    $maxCopies = 64
    $mcText    = 'not set (Windows default, 64)'
    $mc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\VSS\Settings' `
                           -Name MaxShadowCopies -ErrorAction SilentlyContinue
    if ($mc) {
        # The value is read from the registry, so it does not have to be one of
        # ours: a 0 (or a garbage value) would otherwise divide by zero below and
        # take the whole status report down with it.
        $raw = 0
        if ([int]::TryParse([string] $mc.MaxShadowCopies, [ref] $raw) -and $raw -gt 0) {
            $maxCopies = $raw
            $mcText    = "$maxCopies (overridden)"
        } else {
            $mcText = "$($mc.MaxShadowCopies) (overridden, but not a usable number - Windows will fall back to its own limit)"
            $warn.Add("The MaxShadowCopies registry value is '$($mc.MaxShadowCopies)', which is not a usable limit.")
        }
    }

    if (-not $shadows) {
        Write-Host '  none' -ForegroundColor Yellow
        $warn.Add('There are no shadow copies on this machine.')
    }

    foreach ($v in $vols) {
        $mine = @($shadows | Where-Object { $_.VolumeName -eq $v.DeviceID } | Sort-Object InstallDate)
        if (-not $mine) { continue }

        Write-Host ("  {0}  {1} copies   oldest {2}   newest {3}" -f
                    $v.DriveLetter, $mine.Count,
                    $mine[0].InstallDate.ToString('yyyy-MM-dd HH:mm'),
                    $mine[-1].InstallDate.ToString('yyyy-MM-dd HH:mm'))

        $st = Get-CimInstance Win32_ShadowStorage -ErrorAction SilentlyContinue |
              Where-Object { $_.Volume.DeviceID -eq $v.DeviceID } | Select-Object -First 1
        if ($st) {
            $usedGB = $st.UsedSpace / 1GB
            $maxGB  = $st.MaxSpace  / 1GB
            $pct    = if ($maxGB -gt 0) { [math]::Round($usedGB / $maxGB * 100) } else { 0 }
            Write-Host ("      storage {0:N2} GB used of {1:N1} GB cap ({2}%)" -f $usedGB, $maxGB, $pct)
            if ($pct -ge 85) {
                $warn.Add("$($v.DriveLetter) shadow storage is $pct% full - Windows will start deleting the oldest snapshots.")
            }
        }

        $copyPct = [math]::Round($mine.Count / $maxCopies * 100)
        if ($copyPct -ge 85) {
            $warn.Add("$($v.DriveLetter) holds $($mine.Count) of a maximum $maxCopies shadow copies ($copyPct%).")
        }

        $ageHours = ((Get-Date) - $mine[-1].InstallDate).TotalHours
        if ($ageHours -gt 26) {
            $warn.Add("$($v.DriveLetter) newest snapshot is $([math]::Round($ageHours)) hours old.")
        }
    }

    Write-Host ''
    Write-Host 'VSS limits'
    Write-Host "  MaxShadowCopies per volume : $mcText"

    # --- Logs --------------------------------------------------------------
    Write-Host ''
    Write-Host 'Logs'
    $logDir = Split-Path -Parent $script:LogFile
    if (Test-Path -LiteralPath $logDir) {
        $logs = @(Get-ChildItem -LiteralPath $logDir -File -Filter '*.log' -ErrorAction SilentlyContinue)
        $kb   = if ($logs) { [math]::Round((($logs | Measure-Object Length -Sum).Sum) / 1KB) } else { 0 }
        Write-Host ("  {0}  ({1} files, {2} KB)" -f $logDir, $logs.Count, $kb)

        $newest = $logs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newest) {
            $summary = Get-Content -LiteralPath $newest.FullName -Tail 40 -ErrorAction SilentlyContinue |
                       Select-String -Pattern 'Summary:' | Select-Object -Last 1
            if ($summary) { Write-Host ("  last run: {0}" -f $summary.Line.Trim()) }
        }
    } else {
        Write-Host "  $logDir (does not exist yet)" -ForegroundColor Yellow
    }

    # --- Verdict -----------------------------------------------------------
    Write-Host ''
    if ($warn.Count -eq 0) {
        Write-Host 'No problems found.' -ForegroundColor Green
    } else {
        Write-Host "Problems found ($($warn.Count)):" -ForegroundColor Yellow
        foreach ($w in $warn) { Write-Host "  - $w" -ForegroundColor Yellow }
    }
    Write-Host ('=' * 72)

    return $warn.Count
}

# ===========================================================================
# Snapshot
# ===========================================================================

# Documented return codes of Win32_ShadowCopy::Create
$ShadowCopyReturnCode = @{
    0  = 'Success'
    1  = 'Access denied (administrator rights required)'
    2  = 'Invalid argument'
    3  = 'Specified volume not found'
    4  = 'Specified volume not supported (may be non-NTFS or removable media)'
    5  = 'Unsupported shadow copy context'
    6  = 'Insufficient storage (shadow copy storage area is full)'
    7  = 'Volume is in use'
    8  = 'Maximum number of shadow copies reached'
    9  = 'Another shadow copy operation is already in progress'
    10 = 'Shadow copy provider vetoed the operation'
    11 = 'Shadow copy provider not registered'
    12 = 'Shadow copy provider failure'
    13 = 'Unknown error'
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string] $Level = 'INFO'
    )

    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }

    try {
        # -WhatIf:$false - writing a log line is not a state change worth
        # simulating. Without this, a -WhatIf run prints "What if: Add Content"
        # noise for every single line and buries the actual output.
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 `
                    -WhatIf:$false -Confirm:$false -ErrorAction Stop
    } catch {
        Write-Host "!! Could not write to the log file ($script:LogFile): $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Remove-OldLogFile {
    <# Deletes this tool's own log files older than $RetentionDays.

       The match is deliberately narrow: the file name must be exactly
       "ydk-YYYY-MM-DD.log" (or the old "Yedek-" name) AND the date in the name
       must parse as a real date. Age comes from that name, not from the file
       timestamp, so a file touched by a backup tool is not spared or condemned
       by accident. Anything else in the folder is never looked at, let alone
       deleted. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string] $Folder,
        [Parameter(Mandatory)][int]    $RetentionDays
    )

    if ($RetentionDays -le 0) { return }          # 0 = keep forever
    if (-not (Test-Path -LiteralPath $Folder))    { return }

    $cutoff  = (Get-Date).Date.AddDays(-$RetentionDays)
    $deleted = 0

    foreach ($f in @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue)) {

        if ($f.Name -notmatch '^(?:ydk|Yedek)-(\d{4}-\d{2}-\d{2})\.log$') { continue }

        [datetime] $stamp = [datetime]::MinValue
        $ok = [datetime]::TryParseExact($Matches[1], 'yyyy-MM-dd',
                                        [Globalization.CultureInfo]::InvariantCulture,
                                        [Globalization.DateTimeStyles]::None, [ref] $stamp)
        if (-not $ok -or $stamp -ge $cutoff) { continue }

        # Never delete the file we are writing to right now.
        if ($f.FullName -eq $script:LogFile) { continue }

        if ($PSCmdlet.ShouldProcess($f.FullName, 'Delete old log file')) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $deleted++
            } catch {
                Write-Log "Could not delete old log '$($f.Name)': $($_.Exception.Message)" -Level WARN
            }
        }
    }

    if ($deleted -gt 0) {
        Write-Log "Log retention: deleted $deleted log file(s) older than $RetentionDays days."
    }
}

function Start-VssService {
    <# VSS and swprv are usually set to Manual and sit stopped; the Create call
       starts them on demand, but on machines where they were left Disabled the
       call fails. If they are Disabled we set them back to Manual and start. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    foreach ($name in @('VSS', 'swprv')) {
        try {
            $svc = Get-Service -Name $name -ErrorAction Stop
        } catch {
            Write-Log "Service '$name' not found: $($_.Exception.Message)" -Level WARN
            continue
        }

        if ($svc.StartType -eq 'Disabled') {
            if ($PSCmdlet.ShouldProcess($name, 'Set service to Manual and start it')) {
                Write-Log "Service '$name' is Disabled; setting it to Manual." -Level WARN
                Set-Service -Name $name -StartupType Manual
            }
        }

        if ($svc.Status -ne 'Running') {
            if ($PSCmdlet.ShouldProcess($name, 'Start service')) {
                try {
                    Start-Service -Name $name -ErrorAction Stop
                    Write-Log "Service '$name' started."
                } catch {
                    # VSS usually starts on demand anyway, so this is not fatal.
                    Write-Log "Could not start service '$name': $($_.Exception.Message)" -Level WARN
                }
            }
        }
    }
}

function New-ShadowCopy {
    <# Calls Win32_ShadowCopy::Create through CIM, falling back to WMI.
       Returns @{ ReturnValue = <int>; ShadowID = <string> }. #>
    param([Parameter(Mandatory)][string] $VolumeRoot)

    # CAUTION: do not change Context = 'ClientAccessible'. That context gives the
    # snapshot the ClientAccessible + Persistent + NoAutoRelease flags together,
    # and Windows' "Previous Versions" tab lists exactly that combination. With a
    # different context snapshots are still created, but users can no longer see
    # them under right-click -> Properties -> Previous Versions, and recovery is
    # only possible by mounting the snapshot with mklink.
    #
    # Note: the automatic $args variable must not be shadowed, hence the name.
    $createArgs = @{ Volume = $VolumeRoot; Context = 'ClientAccessible' }

    try {
        $r = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create `
                              -Arguments $createArgs -ErrorAction Stop
        return @{
            ReturnValue = [int] $r.ReturnValue
            ShadowID    = [string] $r.ShadowID
        }
    } catch {
        # On some machines the CIM path fails because of WinMgmt/DCOM
        # configuration; the older WMI call does the same job.
        Write-Log "CIM call failed ($($_.Exception.Message)); falling back to WMI." -Level WARN

        $class = [wmiclass] 'root\cimv2:Win32_ShadowCopy'
        $r = $class.Create($VolumeRoot, 'ClientAccessible')
        return @{
            ReturnValue = [int] $r.ReturnValue
            ShadowID    = [string] $r.ShadowID
        }
    }
}

function Invoke-Snapshot {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string[]] $TargetVolume,
        [Parameter(Mandatory)][bool]     $FailMissing
    )

    Write-Log ('=' * 70)
    Write-Log "ydk.ps1 started. Computer: $env:COMPUTERNAME  User: $env:USERNAME"
    # Only a log header. If CIM cannot answer, that is worth noting but it is no
    # reason to abort before a single volume has been tried.
    $osName = 'unknown'
    try { $osName = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { }
    Write-Log ("Operating system: {0} (build {1})" -f $osName, [Environment]::OSVersion.Version.Build)
    Write-Log "Requested volumes: $($TargetVolume -join ', ')"

    Start-VssService

    $succeeded = New-Object System.Collections.Generic.List[string]
    $failed    = New-Object System.Collections.Generic.List[string]

    foreach ($item in $TargetVolume) {

        try {
            $root = ConvertTo-VolumeRoot -Value $item
        } catch {
            Write-Log $_.Exception.Message -Level ERROR
            $failed.Add($item)
            continue
        }

        # --- Can this volume actually be snapshotted? ---
        $target = Get-CimInstance -ClassName Win32_Volume `
                                  -Filter ("Name = '{0}'" -f $root.Replace('\', '\\')) -ErrorAction SilentlyContinue

        if (-not $target) {
            if ($FailMissing) {
                Write-Log "Volume $root does not exist on this computer." -Level ERROR
                $failed.Add($root)
            } else {
                Write-Log "Volume $root does not exist on this computer; skipping." -Level WARN
            }
            continue
        }

        if ($target.FileSystem -ne 'NTFS') {
            # VSS can only create shadow copies on NTFS volumes.
            Write-Log ("Volume $root is not NTFS (file system: '{0}', drive type: {1}); skipping." -f
                       $target.FileSystem, $target.DriveType) -Level WARN
            continue
        }

        # --- Create the snapshot ---
        if (-not $PSCmdlet.ShouldProcess($root, 'Create VSS shadow copy')) {
            Write-Log "$root -> (WhatIf) a snapshot would have been created."
            continue
        }

        Write-Log "$root -> creating snapshot..."

        # VSS serialises shadow copy creation machine-wide. If something else is
        # mid-operation - most commonly a manual run overlapping the scheduled
        # one - Create returns code 9 and there is nothing wrong except timing,
        # so wait and try again rather than reporting a failure.
        $attempt = 0
        $result  = $null
        while ($true) {
            $attempt++
            try {
                $result = New-ShadowCopy -VolumeRoot $root
            } catch {
                Write-Log "$root -> could not create snapshot: $($_.Exception.Message)" -Level ERROR
                $result = $null
                break
            }

            if ($result.ReturnValue -ne 9 -or $attempt -ge $script:SnapshotRetryCount) { break }

            Write-Log ("$root -> another shadow copy operation is in progress; retrying in {0}s ({1}/{2})." -f
                       $script:SnapshotRetryDelaySeconds, $attempt, $script:SnapshotRetryCount) -Level WARN
            Start-Sleep -Seconds $script:SnapshotRetryDelaySeconds
        }

        if ($null -eq $result) {
            $failed.Add($root)
            continue
        }

        if ($result.ReturnValue -eq 0) {
            # Nothing is deleted here on purpose. Windows already drops the
            # oldest shadow copies by itself once the volume's shadow storage
            # cap or its MaxShadowCopies limit is reached, and a rule of our own
            # would delete copies made by System Restore or a backup product
            # just as happily. Use -ShadowStorageMaxSize or -MaxShadowCopies to
            # set those ceilings.
            Write-Log "$root -> snapshot created. ShadowID: $($result.ShadowID)" -Level OK
            $succeeded.Add($root)
        } else {
            $code = $result.ReturnValue
            $desc = if ($ShadowCopyReturnCode.ContainsKey($code)) { $ShadowCopyReturnCode[$code] } else { 'Undefined error code' }
            Write-Log "$root -> could not create snapshot. Code $code : $desc" -Level ERROR
            $failed.Add($root)
        }
    }

    Write-Log ("Summary: succeeded = {0}, failed = {1}" -f
               $(if ($succeeded.Count) { $succeeded -join ', ' } else { 'none' }),
               $(if ($failed.Count)    { $failed -join ', ' }    else { 'none' }))
    Write-Log "Log file: $script:LogFile"
    Write-Log ('=' * 70)

    return $failed.Count
}

# ===========================================================================
# Main flow
# ===========================================================================

$selfPath = if ($PSCommandPath) { $PSCommandPath } else { $null }
$baseDir  = if ($PSScriptRoot)  { $PSScriptRoot }  else { (Get-Location).Path }

# An empty -TaskPrefix would reach Test-IsYdkTask, whose -Prefix is mandatory,
# and come back out as a raw parameter binding error in the middle of a task
# listing. Reject it here instead, with the same exit code as any other bad
# parameter.
if ($PSCmdlet.ParameterSetName -ne 'Snapshot') {
    if ([string]::IsNullOrWhiteSpace($TaskPrefix)) {
        Exit-WithError 'The task prefix cannot be empty. Example: -TaskPrefix YDK'
    }

    # Task names cannot contain these characters. Checking here matters for
    # -Install in particular: the previously installed tasks are removed before
    # the new ones are registered, so a prefix that Register-ScheduledTask would
    # reject halfway through would leave the machine with no tasks at all.
    if ($TaskPrefix -match '[\\/:*?"<>|]') {
        Exit-WithError "The task prefix ('$TaskPrefix') contains a character that is not allowed in a task name: \ / : * ? "" < > |"
    }
}

switch ($PSCmdlet.ParameterSetName) {

    'Status' {
        if (-not (Test-Administrator)) {
            Exit-WithError 'Reading scheduled tasks and shadow copies requires administrator rights. Open PowerShell with "Run as administrator".'
        }
        $script:LogFile = if ($LogPath) { $LogPath }
                          else { Join-Path (Join-Path $baseDir 'Logs') ("ydk-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd')) }
        $problems = Show-Status -Prefix $TaskPrefix
        if ($problems -gt 0) { exit 1 }
        exit 0
    }

    'Uninstall' {
        if (-not (Test-Administrator)) {
            Exit-WithError 'This operation requires administrator rights. Open PowerShell with "Run as administrator".'
        }
        Uninstall-YdkTask -Prefix $TaskPrefix
        exit 0
    }

    'Install' {
        if (-not (Test-Administrator)) {
            Exit-WithError 'This operation requires administrator rights. Open PowerShell with "Run as administrator".'
        }
        if (-not $selfPath) {
            Exit-WithError 'Could not determine the script''s own path; -Install requires the script to be run from a file.'
        }

        # Empty lists would otherwise surface as a parameter binding error from
        # Install-YdkTask ("empty array"), or quietly register a task whose
        # command line carries a bare "-Volume".
        if ($Volume.Count -eq 0) {
            Exit-WithError 'The volume list is empty. Example: -Volume C,D'
        }
        if ($Time.Count -eq 0) {
            Exit-WithError 'The time list is empty. Example: -Time 10:00,13:00,16:00'
        }

        # Validate the volume list BEFORE writing it into a task. Without this a
        # typo such as "-Volume ABC" installs cleanly and then fails on every
        # scheduled run - exactly the silent-failure mode this tool exists to
        # prevent.
        foreach ($item in $Volume) {
            try { $null = ConvertTo-VolumeRoot -Value $item }
            catch { Exit-WithError $_.Exception.Message }
        }

        # The task will run this file as SYSTEM three times a day, so refuse to
        # register it while ordinary users can still rewrite it.
        $unsafe = @(Get-UnsafeWriteAccess -Path $selfPath)
        if ($unsafe.Count) {
            Write-Host ''
            Write-Host 'This script can be modified by users who are not administrators:' -ForegroundColor Red
            foreach ($u in $unsafe) { Write-Host "  $u" -ForegroundColor Red }
            Write-Host ''

            if ($SkipLocationCheck) {
                Write-Host 'Installing anyway because -SkipLocationCheck was passed.' -ForegroundColor Yellow
                Write-Host ''
            } else {
                Write-Host 'The scheduled task runs this file as SYSTEM, so anyone who can change it can run' -ForegroundColor Yellow
                Write-Host 'their own code as SYSTEM. Install it where only administrators can write:' -ForegroundColor Yellow
                Write-Host ''
                Write-Host '    New-Item -ItemType Directory "C:\Program Files\YDK" -Force' -ForegroundColor Yellow
                Write-Host ('    Copy-Item "{0}" "C:\Program Files\YDK\ydk.ps1"' -f $selfPath) -ForegroundColor Yellow
                Write-Host '    & "C:\Program Files\YDK\ydk.ps1" -Install' -ForegroundColor Yellow
                Write-Host ''
                Write-Host 'or lock the folder it is in down:' -ForegroundColor Yellow
                Write-Host ('    icacls "{0}" /inheritance:r /grant "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "Users:(OI)(CI)RX"' -f (Split-Path -Parent $selfPath)) -ForegroundColor Yellow
                Write-Host ''
                Exit-WithError 'Install cancelled. Pass -SkipLocationCheck to install here anyway.'
            }
        }

        Unblock-SelfFile -Path $selfPath

        # VSS limits are only touched when explicitly asked for. Without these
        # switches Windows' own defaults (10% storage cap, 64 copies) stand.
        if ($PSBoundParameters.ContainsKey('ShadowStorageMaxSize')) {
            Write-Host ''
            Write-Host "VSS storage cap (-ShadowStorageMaxSize $ShadowStorageMaxSize):"
            foreach ($item in $Volume) {
                try {
                    Set-ShadowStorageMaxSize -VolumeRoot (ConvertTo-VolumeRoot -Value $item) `
                                             -Spec $ShadowStorageMaxSize
                } catch {
                    Write-Host "  $item - $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }

        if ($PSBoundParameters.ContainsKey('MaxShadowCopies')) {
            Write-Host ''
            Write-Host "VSS copy limit (-MaxShadowCopies $MaxShadowCopies):"
            Set-MaxShadowCopies -Value $MaxShadowCopies
        }

        Install-YdkTask -SelfPath   $selfPath `
                        -TaskTime   $Time `
                        -TaskVolume $Volume `
                        -LogDays    $LogRetentionDays `
                        -Prefix     $TaskPrefix
        exit 0
    }

    default {
        if ($Volume.Count -eq 0) {
            Exit-WithError 'The volume list is empty. Example: -Volume C,D'
        }

        # Log file path (Write-Log reads this from the script scope)
        if ($LogPath) {
            $script:LogFile = $LogPath
        } else {
            $script:LogFile = Join-Path (Join-Path $baseDir 'Logs') ("ydk-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
        }

        # The log folder is exempt from -WhatIf too; without this a -WhatIf run
        # would report "could not write to the log" on every line.
        $logDir = Split-Path -Parent $script:LogFile
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            try {
                New-Item -ItemType Directory -Path $logDir -Force -WhatIf:$false -ErrorAction Stop | Out-Null
            } catch {
                # A -LogPath pointing somewhere unwritable is a parameter
                # problem, so report it as one instead of letting the raw
                # New-Item error escape.
                Exit-WithError "Could not create the log folder ('$logDir'): $($_.Exception.Message)"
            }
        }

        if (-not (Test-Administrator)) {
            Write-Log 'This script must be run as administrator. Creating a VSS snapshot requires it.' -Level ERROR
            Write-Log 'If you are running it by hand, open PowerShell with "Run as administrator" and try again.' -Level ERROR
            Write-Log 'If it is running from Task Scheduler, the task must be registered as SYSTEM with highest privileges (see -Install).' -Level ERROR
            exit 2
        }

        Remove-OldLogFile -Folder (Split-Path -Parent $script:LogFile) `
                          -RetentionDays $LogRetentionDays

        $failedCount = Invoke-Snapshot -TargetVolume $Volume `
                                       -FailMissing  ([bool] $FailOnMissingVolume)

        if ($failedCount -gt 0) { exit 1 }
        exit 0
    }
}
