#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Full removal of Autodesk software and leftovers from a Windows machine.

.DESCRIPTION
    1. Stops Autodesk processes and services
    2. Uninstalls all Autodesk products (products first, then licensing/SSO/ODIS components), 2 passes
    3. Removes services, scheduled tasks, firewall rules
    4. Removes folders (Program Files, ProgramData, Common Files, all user profiles)
    5. Cleans registry (HKLM + every user hive, including offline ones), env vars, PATH
    6. Prints a report of what is left and must be done manually

.PARAMETER DryRun
    Only show what would be done, change nothing.
.PARAMETER SkipUninstall
    Skip the uninstall phase (only clean leftovers).
.PARAMETER RemoveUserDocuments
    Also remove Documents\Autodesk in every profile (may contain user projects/templates!).
.PARAMETER RemoveFlexNet
    Also remove FlexNet Licensing Service (shared with other vendors - off by default).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Remove-Autodesk.ps1 -DryRun
    powershell -ExecutionPolicy Bypass -File .\Remove-Autodesk.ps1
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipUninstall,
    [switch]$RemoveUserDocuments,
    [switch]$RemoveFlexNet
)

$ErrorActionPreference = 'Continue'
$script:Locked = New-Object System.Collections.Generic.List[string]
$script:FailedUninstall = New-Object System.Collections.Generic.List[string]

$logDir = Join-Path $env:SystemDrive 'Temp'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir ("Autodesk-Cleanup_{0}_{1}.log" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
Start-Transcript -Path $log | Out-Null

function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------- helpers
function Remove-PathForce([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($DryRun) { Write-Host "[dry-run] remove path: $Path"; return }
    Info "Removing $Path"
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return } catch {}
    # take ownership and retry
    & takeown.exe /f "$Path" /r /d Y *> $null
    & icacls.exe "$Path" /grant '*S-1-5-32-544:(OI)(CI)F' /t /c /q *> $null
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
    catch { Warn "Could not remove $Path (locked?) - will need reboot/manual removal"; $script:Locked.Add($Path) }
}

function Remove-RegKey([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($DryRun) { Write-Host "[dry-run] remove reg key: $Path"; return }
    Info "Removing registry key $Path"
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
    catch { Warn "Failed to remove $Path : $_" }
}

function Stop-AdskProcesses {
    $nameRx = '^(acad|acadlt|adsk.*|autodesk.*|adsso.*|adappmgrsvc|genuineservice|revit|3dsmax|maya|mayabatch|inventor|navisworks|roamer|simulate|lmgrd|adskflex|odis.*|adodis.*)$'
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Id -ne $PID -and (
            $_.ProcessName -match $nameRx -or
            ($_.Path -and ($_.Path -like '*\Autodesk\*' -or $_.Path -like '*\Autodesk Shared\*'))
        )
    } | ForEach-Object {
        if ($DryRun) { Write-Host "[dry-run] kill process $($_.ProcessName) ($($_.Id))" }
        else { Info "Killing process $($_.ProcessName) ($($_.Id))"; Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    }
}

function Get-AdskServices {
    Get-CimInstance Win32_Service | Where-Object {
        $_.Name -match '^(Adsk|Autodesk|AdAppMgrSvc|GenuineService|AutodeskDesktopApp|AdskLicensing)' -or
        $_.DisplayName -like '*Autodesk*' -or
        $_.PathName -like '*\Autodesk\*' -or
        $_.PathName -like '*\Autodesk Shared\*'
    }
}

# ---------------------------------------------------------------- product discovery
$explicitNames = 'AutoCAD*','Revit*','DWG TrueView*','Navisworks*','3ds Max*','Inventor*','Civil 3D*',
                 'Advance Steel*','ReCap*','Moldflow*','Vault*','Maya*','MotionBuilder*','Mudbox*','Fusion 360*'
$supportRx = 'Licensing|Single Sign On|Desktop App|Identity Manager|Genuine|Autodesk Access|Material Library|Content Service|Shared|Save to Web|ODIS|Installer|Desktop Connector|Application Manager|Network License|Sign-?In'

function Get-AdskProducts {
    $paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $items = foreach ($p in $paths) {
        Get-ItemProperty -Path $p -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
    }
    $items | Where-Object {
        $name = $_.DisplayName; $pub = $_.Publisher
        ($pub -like '*Autodesk*') -or ($name -like '*Autodesk*') -or
        ((-not $pub) -and ($explicitNames | Where-Object { $name -like $_ }))
    } | Sort-Object @{ Expression = { if ($_.DisplayName -match $supportRx) { 1 } else { 0 } } }, DisplayName -Unique
}

function Invoke-AdskUninstall($p) {
    $guid = $null
    if ($p.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') { $guid = $p.PSChildName }
    elseif ($p.UninstallString -match '(\{[0-9A-Fa-f-]{36}\})') { $guid = $Matches[1] }

    $cmd = $null
    if ($guid -and ($p.WindowsInstaller -eq 1 -or $p.UninstallString -match 'msiexec')) {
        $cmd = "msiexec.exe /x $guid /qn /norestart REBOOT=ReallySuppress"
    }
    elseif ($p.UninstallString -match 'Installer\.exe') {           # ODIS-based products (2020+)
        $cmd = $p.UninstallString
        if ($cmd -notmatch '\s-q(\s|$)') { $cmd += ' -q' }
    }
    elseif ($p.QuietUninstallString) { $cmd = $p.QuietUninstallString }

    if (-not $cmd) { Warn "No silent uninstall method for '$($p.DisplayName)'"; return $false }

    if ($DryRun) { Write-Host "[dry-run] uninstall '$($p.DisplayName)': $cmd"; return $true }
    Info "Uninstalling '$($p.DisplayName)' $($p.DisplayVersion)"
    $proc = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList "/c $cmd" -Wait -PassThru -WindowStyle Hidden
    Write-Host "    exit code: $($proc.ExitCode)"
    return ($proc.ExitCode -in 0, 3010, 1641)
}

# ================================================================= PHASE 1: stop
Info "Phase 1: stopping Autodesk processes and services"
Stop-AdskProcesses
Get-AdskServices | ForEach-Object {
    if ($DryRun) { Write-Host "[dry-run] stop service $($_.Name)" }
    else { Info "Stopping service $($_.Name)"; Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue }
}

# ================================================================= PHASE 2: uninstall
if (-not $SkipUninstall) {
    Info "Phase 2: uninstalling products"
    for ($pass = 1; $pass -le 2; $pass++) {
        $list = @(Get-AdskProducts)
        if ($list.Count -eq 0) { Info "No Autodesk products left in Uninstall registry"; break }
        Info "Pass $pass : $($list.Count) item(s)"
        $list | ForEach-Object { Write-Host "    - $($_.DisplayName) $($_.DisplayVersion)" }
        foreach ($p in $list) { [void](Invoke-AdskUninstall $p); Stop-AdskProcesses }
        if ($DryRun) { break }
    }
    if (-not $DryRun) {
        Get-AdskProducts | ForEach-Object { $script:FailedUninstall.Add("$($_.DisplayName) $($_.DisplayVersion)") }
    }
}

# ================================================================= PHASE 3: services / tasks / firewall
Info "Phase 3: services, scheduled tasks, firewall rules"
Stop-AdskProcesses
Get-AdskServices | ForEach-Object {
    if ($DryRun) { Write-Host "[dry-run] delete service $($_.Name)" }
    else { Info "Deleting service $($_.Name)"; & sc.exe delete $_.Name | Out-Null }
}

if ($RemoveFlexNet) {
    Get-Service -Name 'FlexNet Licensing Service*' -ErrorAction SilentlyContinue | ForEach-Object {
        if ($DryRun) { Write-Host "[dry-run] remove FlexNet service $($_.Name)" }
        else { Stop-Service $_ -Force -ErrorAction SilentlyContinue; & sc.exe delete $_.Name | Out-Null }
    }
    Remove-PathForce "${env:ProgramFiles}\Common Files\Macrovision Shared"
    Remove-PathForce "${env:ProgramFiles(x86)}\Common Files\Macrovision Shared"
} elseif (Get-Service -Name 'FlexNet Licensing Service*' -ErrorAction SilentlyContinue) {
    Warn "FlexNet Licensing Service is present (shared with other vendors) - left in place. Use -RemoveFlexNet to remove."
}

Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.TaskName -like '*Autodesk*' -or $_.TaskPath -like '*Autodesk*' -or $_.TaskName -like 'Adsk*'
} | ForEach-Object {
    if ($DryRun) { Write-Host "[dry-run] remove scheduled task $($_.TaskPath)$($_.TaskName)" }
    else { Info "Removing scheduled task $($_.TaskName)"; Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction SilentlyContinue }
}

Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {
    $_.DisplayName -like '*Autodesk*' -or $_.DisplayName -like 'Adsk*'
} | ForEach-Object {
    if ($DryRun) { Write-Host "[dry-run] remove firewall rule $($_.DisplayName)" }
    else { Info "Removing firewall rule $($_.DisplayName)"; Remove-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue }
}

# ================================================================= PHASE 4: files
Info "Phase 4: removing folders"
$folders = @(
    "$env:ProgramFiles\Autodesk",
    "${env:ProgramFiles(x86)}\Autodesk",
    "$env:ProgramFiles\Common Files\Autodesk Shared",
    "${env:ProgramFiles(x86)}\Common Files\Autodesk Shared",
    "$env:ProgramData\Autodesk",
    "$env:SystemDrive\Autodesk",
    "$env:Public\Documents\Autodesk",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Autodesk"
)
foreach ($f in $folders) { Remove-PathForce $f }

# FlexNet license data files belonging to Autodesk
Get-ChildItem "$env:ProgramData\FLEXnet" -Filter 'adsk*' -Force -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-PathForce $_.FullName }

# every user profile
$userRel = @(
    'AppData\Local\Autodesk',
    'AppData\Roaming\Autodesk',
    'AppData\LocalLow\Autodesk',
    'AppData\Local\Identities',
    'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Autodesk'
)
if ($RemoveUserDocuments) { $userRel += 'Documents\Autodesk' }

$profiles = Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path $_.LocalPath) }
foreach ($up in $profiles) {
    foreach ($rel in $userRel) { Remove-PathForce (Join-Path $up.LocalPath $rel) }
    $tmp = Join-Path $up.LocalPath 'AppData\Local\Temp'
    Get-ChildItem $tmp -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'Autodesk*' -or $_.Name -like 'adsk*' -or $_.Name -like 'AdskLicensing*' } |
        ForEach-Object { Remove-PathForce $_.FullName }
}
Get-ChildItem "$env:SystemRoot\Temp" -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'Autodesk*' -or $_.Name -like 'adsk*' } |
    ForEach-Object { Remove-PathForce $_.FullName }

# ================================================================= PHASE 5: registry
Info "Phase 5: registry (HKLM)"
foreach ($k in 'HKLM:\SOFTWARE\Autodesk', 'HKLM:\SOFTWARE\WOW6432Node\Autodesk',
               'HKLM:\SOFTWARE\Wow6432Node\FLEXlm\adskflex') {
    Remove-RegKey $k
}

# orphaned Uninstall entries
foreach ($base in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
    Get-ChildItem $base -ErrorAction SilentlyContinue | ForEach-Object {
        $pr = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($pr.Publisher -like '*Autodesk*' -or $pr.DisplayName -like '*Autodesk*') { Remove-RegKey $_.PSPath }
    }
}

# ProgIDs
Get-ChildItem 'HKLM:\SOFTWARE\Classes' -Name -ErrorAction SilentlyContinue |
    Where-Object { $_ -match '^(Autodesk|Adsk|AutoCAD|Revit|Inventor)\.' } |
    ForEach-Object { Remove-RegKey "HKLM:\SOFTWARE\Classes\$_" }

# App Paths pointing into Autodesk folders
foreach ($base in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
                  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths') {
    Get-ChildItem $base -ErrorAction SilentlyContinue | ForEach-Object {
        $d = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).'(default)'
        if ($d -like '*\Autodesk*') { Remove-RegKey $_.PSPath }
    }
}

# Run keys
function Clear-RunValues([string]$KeyPath) {
    if (-not (Test-Path $KeyPath)) { return }
    $props = Get-ItemProperty $KeyPath
    foreach ($n in ($props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and "$($_.Value)" -match 'Autodesk|adsk' })) {
        if ($DryRun) { Write-Host "[dry-run] remove Run value $($n.Name) in $KeyPath" }
        else { Info "Removing Run value $($n.Name)"; Remove-ItemProperty -Path $KeyPath -Name $n.Name -ErrorAction SilentlyContinue }
    }
}
Clear-RunValues 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
Clear-RunValues 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'

# Environment variables (machine) and PATH
$envRx = '^(ADSK_.*|ADSKFLEX_LICENSE_FILE|AUTODESK_.*)$'
$envKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
(Get-Item $envKey).GetValueNames() | Where-Object { $_ -match $envRx } | ForEach-Object {
    if ($DryRun) { Write-Host "[dry-run] remove machine env var $_" }
    else { Info "Removing machine env var $_"; Remove-ItemProperty -Path $envKey -Name $_ -ErrorAction SilentlyContinue }
}
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$cleanPath = (($machinePath -split ';') | Where-Object { $_ -and $_ -notlike '*Autodesk*' }) -join ';'
if ($cleanPath -ne $machinePath) {
    if ($DryRun) { Write-Host "[dry-run] strip Autodesk entries from machine PATH" }
    else { Info "Cleaning machine PATH"; [Environment]::SetEnvironmentVariable('Path', $cleanPath, 'Machine') }
}
if ([Environment]::GetEnvironmentVariable('LM_LICENSE_FILE', 'Machine')) {
    Warn "LM_LICENSE_FILE is set (may belong to other vendors) - check manually."
}

# ---- user hives (loaded and offline)
Info "Phase 5b: registry (user hives)"
function Clear-UserHive([string]$Root) {
    Remove-RegKey "$Root\Software\Autodesk"
    $un = "$Root\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    if (Test-Path $un) {
        Get-ChildItem $un -ErrorAction SilentlyContinue | ForEach-Object {
            $pr = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($pr.Publisher -like '*Autodesk*' -or $pr.DisplayName -like '*Autodesk*') { Remove-RegKey $_.PSPath }
        }
    }
    Clear-RunValues "$Root\Software\Microsoft\Windows\CurrentVersion\Run"
    $ek = "$Root\Environment"
    if (Test-Path $ek) {
        (Get-Item $ek).GetValueNames() | Where-Object { $_ -match $envRx } | ForEach-Object {
            if ($DryRun) { Write-Host "[dry-run] remove user env var $_" }
            else { Remove-ItemProperty -Path $ek -Name $_ -ErrorAction SilentlyContinue }
        }
    }
}

foreach ($up in $profiles) {
    $sid = $up.SID
    if (Test-Path "Registry::HKEY_USERS\$sid") {
        Clear-UserHive "Registry::HKEY_USERS\$sid"
    }
    else {
        $dat = Join-Path $up.LocalPath 'NTUSER.DAT'
        if (-not (Test-Path $dat)) { continue }
        if ($DryRun) { Write-Host "[dry-run] load and clean hive $dat"; continue }
        & reg.exe load 'HKU\ADSK_TMP' "$dat" *> $null
        if ($LASTEXITCODE -eq 0) {
            try { Clear-UserHive 'Registry::HKEY_USERS\ADSK_TMP' } catch { Warn "Hive cleanup error: $_" }
            [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 500
            & reg.exe unload 'HKU\ADSK_TMP' *> $null
            if ($LASTEXITCODE -ne 0) { Warn "Could not unload hive for $($up.LocalPath) (will unload on reboot)" }
        } else { Warn "Could not load hive $dat" }
    }
}
Clear-UserHive 'HKCU:'

# ================================================================= PHASE 6: report
Info "Phase 6: leftover check"
$left = New-Object System.Collections.Generic.List[string]
foreach ($f in $folders) { if (Test-Path $f) { $left.Add("Folder: $f") } }
foreach ($up in $profiles) { foreach ($rel in $userRel) { $x = Join-Path $up.LocalPath $rel; if (Test-Path $x) { $left.Add("Folder: $x") } } }
if (Get-AdskServices) { Get-AdskServices | ForEach-Object { $left.Add("Service: $($_.Name) (marked for deletion - reboot)") } }
foreach ($k in 'HKLM:\SOFTWARE\Autodesk', 'HKLM:\SOFTWARE\WOW6432Node\Autodesk') { if (Test-Path $k) { $left.Add("Registry: $k") } }

Write-Host ""
Write-Host "================ SUMMARY ================" -ForegroundColor Green
if ($DryRun) { Write-Host "DRY RUN - nothing was changed." }
if ($script:FailedUninstall.Count) { Warn "Not uninstalled (use Autodesk Uninstall Tool / MS Install-Uninstall troubleshooter):"; $script:FailedUninstall | ForEach-Object { Write-Host "    - $_" } }
if ($script:Locked.Count)         { Warn "Locked paths (delete after reboot):";                                              $script:Locked | ForEach-Object { Write-Host "    - $_" } }
if ($left.Count)                  { Warn "Remaining items:";                                                                $left | ForEach-Object { Write-Host "    - $_" } }
if (-not $DryRun -and -not $script:FailedUninstall.Count -and -not $script:Locked.Count -and -not $left.Count) {
    Write-Host "Autodesk fully removed. REBOOT the computer before installing anything." -ForegroundColor Green
} else {
    Write-Host "Reboot, then run the script once more to finish cleanup." -ForegroundColor Yellow
}
Write-Host "Log: $log"
Stop-Transcript | Out-Null
