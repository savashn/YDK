# ---------------------------------------------------------------------------
# YDK test - phase 8 (no administrator rights needed)
#   Get-UnsafeWriteAccess against real folders whose ACLs the test sets up.
# ---------------------------------------------------------------------------
param([string] $Sut)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $here) 'harness.ps1')

if (-not $Sut) { $Sut = Get-YdkScript }
$script:SUT    = $Sut
$script:OutDir = Join-Path $script:TestRoot 'out-install-location'
New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
Get-ChildItem $script:OutDir -File -ErrorAction SilentlyContinue | Remove-Item -Force

$work = Join-Path $script:TestRoot 'work-install-location'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

Set-StrictMode -Version Latest
$ast = [System.Management.Automation.Language.Parser]::ParseFile($SUT, [ref] $null, [ref] $null)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($f.Name -eq 'Get-UnsafeWriteAccess') { . ([scriptblock]::Create($f.Extent.Text)) }
}
if (-not (Get-Command Get-UnsafeWriteAccess -ErrorAction SilentlyContinue)) {
    Add-Result 'X00' 'Get-UnsafeWriteAccess could not be lifted out of the script' 'FAIL'
    Write-Report -Path (Join-Path $script:TestRoot 'report-install-location.json')
    return
}

# --- helpers ---------------------------------------------------------------
# Get-Acl/Set-Acl round-trips the owner and audit sections and then wants
# SeSecurityPrivilege, which an ordinary user does not have. Reading and writing
# only the Access section through the FileSystemInfo object avoids that.
function Get-Sec {
    param([string] $Path)
    $item = Get-Item -LiteralPath $Path -Force
    return $item.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
}
function Set-Sec {
    param([string] $Path, $Security)
    $item = Get-Item -LiteralPath $Path -Force
    $item.SetAccessControl($Security)
}
function New-Rule {
    param([string] $Path, [string] $Identity, [string] $Rights, [string] $Type = 'Allow')
    $inherit = if (Test-Path -LiteralPath $Path -PathType Container) { 'ContainerInherit,ObjectInherit' } else { 'None' }
    New-Object Security.AccessControl.FileSystemAccessRule(
        (New-Object Security.Principal.SecurityIdentifier($Identity)), $Rights, $inherit, 'None', $Type)
}

function New-TestFolder {
    <# A folder with inheritance removed. SYSTEM and Administrators get full
       control, the current user only read+execute - which is exactly the shape
       of C:\Program Files, and lets this (non-elevated) test read the ACL back. #>
    param([string] $Name, [switch] $OwnerCanWrite)

    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir 'ydk.ps1'
    Copy-Item -LiteralPath $script:SUT -Destination $file -Force

    $me  = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $sec = Get-Sec $dir
    $sec.SetAccessRuleProtection($true, $false)          # drop inheritance, copy nothing
    foreach ($r in @($sec.Access)) { [void] $sec.RemoveAccessRule($r) }
    $sec.AddAccessRule((New-Rule $dir 'S-1-5-18'     'FullControl'))
    $sec.AddAccessRule((New-Rule $dir 'S-1-5-32-544' 'FullControl'))
    $sec.AddAccessRule((New-Rule $dir $me $(if ($OwnerCanWrite) { 'FullControl' } else { 'ReadAndExecute' })))
    Set-Sec $dir $sec
    return $file
}

function Add-Rule {
    param([string] $Path, [string] $Identity, [string] $Rights, [string] $Type = 'Allow')
    $sec = Get-Sec $Path
    $sec.AddAccessRule((New-Rule $Path $Identity $Rights $Type))
    Set-Sec $Path $sec
}

function Check-Path {
    param([string] $Id, [string] $Name, [string] $Path, [bool] $ExpectUnsafe, [string] $ExpectText)
    try {
        $r = @(Get-UnsafeWriteAccess -Path $Path)
    } catch {
        Add-Result $Id $Name 'FAIL' "threw: $($_.Exception.Message)"
        return
    }
    $problems = @()
    if ($ExpectUnsafe -and $r.Count -eq 0)      { $problems += 'reported as safe, expected a finding' }
    if (-not $ExpectUnsafe -and $r.Count -gt 0) { $problems += "reported unsafe: $($r -join ' ; ')" }
    if ($ExpectText -and ($r -join ' ') -notmatch $ExpectText) { $problems += "no entry matching '$ExpectText' (got: $($r -join ' ; '))" }
    Add-Result $Id $Name $(if ($problems) { 'FAIL' } else { 'PASS' }) ($problems -join ' | ') ($r -join "`n")
}

$SID_USERS   = 'S-1-5-32-545'   # BUILTIN\Users
$SID_AUTH    = 'S-1-5-11'       # Authenticated Users
$SID_EVERY   = 'S-1-1-0'        # Everyone
$SID_INTER   = 'S-1-5-4'        # INTERACTIVE
$SID_SERVICE = 'S-1-5-19'       # LOCAL SERVICE

Write-Host ('-' * 100)
Write-Host 'A. Real folders whose permissions the test controls' -ForegroundColor Cyan

$safe = New-TestFolder -Name 'safe'
Check-Path X01 'Only SYSTEM + Administrators -> safe' $safe $false ''

$f = New-TestFolder -Name 'users-modify'
Add-Rule -Path (Split-Path -Parent $f) -Identity $SID_USERS -Rights 'Modify'
Check-Path X02 'Folder gives BUILTIN\Users Modify -> unsafe' $f $true 'Users'

$f = New-TestFolder -Name 'auth-full'
Add-Rule -Path (Split-Path -Parent $f) -Identity $SID_AUTH -Rights 'FullControl'
Check-Path X03 'Folder gives Authenticated Users FullControl -> unsafe' $f $true ''

$f = New-TestFolder -Name 'everyone-write'
Add-Rule -Path (Split-Path -Parent $f) -Identity $SID_EVERY -Rights 'Write'
Check-Path X04 'Folder gives Everyone Write -> unsafe' $f $true ''

$f = New-TestFolder -Name 'users-readonly'
Add-Rule -Path (Split-Path -Parent $f) -Identity $SID_USERS -Rights 'ReadAndExecute'
Check-Path X05 'Folder gives Users ReadAndExecute -> safe' $f $false ''

$f = New-TestFolder -Name 'users-listonly'
Add-Rule -Path (Split-Path -Parent $f) -Identity $SID_USERS -Rights 'ReadAttributes,ReadData,Synchronize'
Check-Path X06 'Read-only rights on the folder -> safe' $f $false ''

$f = New-TestFolder -Name 'file-writable'
Add-Rule -Path $f -Identity $SID_USERS -Rights 'Modify'
Check-Path X07 'Folder is safe but the FILE itself is writable -> unsafe' $f $true 'ydk.ps1'

$f = New-TestFolder -Name 'delete-only'
Add-Rule -Path (Split-Path -Parent $f) -Identity $SID_USERS -Rights 'Delete'
Check-Path X08 'Delete right on the folder is enough to be unsafe' $f $true ''

$f = New-TestFolder -Name 'createfiles'
Add-Rule -Path (Split-Path -Parent $f) -Identity $SID_USERS -Rights 'CreateFiles'
Check-Path X09 'CreateFiles (WriteData) on the folder -> unsafe' $f $true ''

$f = New-TestFolder -Name 'changeperm'
Add-Rule -Path (Split-Path -Parent $f) -Identity $SID_USERS -Rights 'ChangePermissions'
Check-Path X10 'ChangePermissions on the folder -> unsafe' $f $true ''

$f = New-TestFolder -Name 'takeowner'
Add-Rule -Path (Split-Path -Parent $f) -Identity $SID_USERS -Rights 'TakeOwnership'
Check-Path X11 'TakeOwnership on the folder -> unsafe' $f $true ''

$f = New-TestFolder -Name 'writeattr'
Add-Rule -Path (Split-Path -Parent $f) -Identity $SID_USERS -Rights 'WriteAttributes'
Check-Path X12 'WriteAttributes alone does not allow a rewrite -> safe' $f $false ''

$f = New-TestFolder -Name 'interactive'
Add-Rule -Path (Split-Path -Parent $f) -Identity $SID_INTER -Rights 'Modify'
Check-Path X13 'INTERACTIVE Modify -> unsafe' $f $true ''

$f = New-TestFolder -Name 'localservice'
Add-Rule -Path (Split-Path -Parent $f) -Identity $SID_SERVICE -Rights 'Modify'
Check-Path X14 'LOCAL SERVICE Modify -> unsafe (not an administrator)' $f $true ''

$f = New-TestFolder -Name 'deny-then-allow'
Add-Rule -Path (Split-Path -Parent $f) -Identity $SID_USERS -Rights 'Modify'
Add-Rule -Path (Split-Path -Parent $f) -Identity $SID_USERS -Rights 'Modify' -Type 'Deny'
Check-Path X15 'An Allow entry is still reported when a Deny also exists (conservative)' $f $true ''

$f = New-TestFolder -Name 'owner-full' -OwnerCanWrite
Check-Path X16 'A named user with FullControl is reported (that user can rewrite it)' $f $true ''

Write-Host ('-' * 100)
Write-Host 'B. Real locations on this machine' -ForegroundColor Cyan

Check-Path X17 'A not-yet-existing file under C:\Program Files -> safe (the folder decides)' `
    (Join-Path $env:ProgramFiles 'ydk.ps1') $false ''

Check-Path X18 'A not-yet-existing file under C:\Windows\System32 -> safe' `
    (Join-Path $env:SystemRoot 'System32\ydk.ps1') $false ''

if (Test-Path -LiteralPath 'C:\YDK\ydk.ps1') {
    Check-Path X19 'The real C:\YDK\ydk.ps1 -> unsafe (Authenticated Users inherited from C:\)' 'C:\YDK\ydk.ps1' $true 'C:\\YDK'
} else {
    Add-Result 'X19' 'C:\YDK\ydk.ps1 is not present, skipped' 'SKIP'
}

Check-Path X20 'A path in the user profile (Desktop) -> unsafe' `
    (Join-Path $env:USERPROFILE 'Desktop\ydk.ps1') $true ''

Check-Path X21 'A path in the temp folder -> unsafe' (Join-Path $env:TEMP 'ydk.ps1') $true ''

# a path that does not exist at all: the parent still decides
Check-Path X22 'A file that does not exist yet under a safe folder -> safe' `
    (Join-Path (Split-Path -Parent $safe) 'not-there.ps1') $false ''

# a path that is not there at all has nothing to judge
Check-Path X23 'A path on a drive that does not exist -> nothing to report' 'Q:\nope\ydk.ps1' $false ''

# but an existing item whose permissions cannot be read must be reported
$hidden = Join-Path $work 'unreadable'
New-Item -ItemType Directory -Path $hidden -Force | Out-Null
$hiddenFile = Join-Path $hidden 'ydk.ps1'
Copy-Item -LiteralPath $script:SUT -Destination $hiddenFile -Force
$sec = Get-Sec $hiddenFile
$sec.SetAccessRuleProtection($true, $false)
foreach ($r in @($sec.Access)) { [void] $sec.RemoveAccessRule($r) }
$sec.AddAccessRule((New-Rule $hiddenFile 'S-1-5-18' 'FullControl'))
Set-Sec $hiddenFile $sec
# (The owner of a file can always read its DACL, so the "permissions could not be
#  read" branch cannot be produced from a non-elevated test. What is verified
#  here is that a hardened file inside a writable folder is still reported,
#  because the folder rights alone are enough to swap the file out.)
Check-Path X24 'A locked-down file in a writable folder is still reported' $hiddenFile $true 'unreadable'

Write-Report -Path (Join-Path $script:TestRoot 'report-install-location.json')
