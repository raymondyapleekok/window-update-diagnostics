<#
.SYNOPSIS
Guarded, opt-in Windows Update repair actions. Nothing runs without an explicit switch.
.DESCRIPTION
Supports -WhatIf and confirmation (ConfirmImpact High); requires elevation.
Switches:
  -RunDISMRestoreHealth   Component-store repair (approval + evidence required; may use WU or /Source).
  -RunSFCScanNow          sfc /scannow after DISM success.
  -ResetUpdateComponents  Microsoft-documented manual reset, RENAME-only (reversible):
                          stops bits/wuauserv/cryptsvc, renames SoftwareDistribution\DataStore,
                          ...\Download and System32\catroot2 to timestamped backups, restarts services.
                          -IncludeQmgr also removes BITS qmgr*.dat transfer files (recreated).
  -ResetUpdateCache       Coarser variant: renames whole SoftwareDistribution and catroot2.
  -RunWuauservDetect      Starts wuauserv and performs a DETECTION-ONLY scan via COM (installs nothing).
  -SetCrashCapture        Diagnostic-attempt prep: CrashDumpEnabled=7 (automatic), AutoReboot=0.
                          Records previous values to crash-control-previous.txt beside this script
                          for reverting. Warns that Setup may not carry these into the target OS.
  -RevertCrashCapture     Restores values recorded by -SetCrashCapture.
Do NOT run because a blog said so; run because the evidence supports it.
.EXAMPLE
.\repair-windows-update.ps1 -ResetUpdateComponents -WhatIf
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [switch]$RunDISMRestoreHealth,
    [switch]$RunSFCScanNow,
    [switch]$ResetUpdateComponents,
    [switch]$IncludeQmgr,
    [switch]$ResetUpdateCache,
    [switch]$RunWuauservDetect,
    [switch]$SetCrashCapture,
    [switch]$RevertCrashCapture
)
$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Open PowerShell as Administrator, then rerun. No changes have been made.' }
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not ($RunDISMRestoreHealth -or $RunSFCScanNow -or $ResetUpdateComponents -or $ResetUpdateCache -or $RunWuauservDetect -or $SetCrashCapture -or $RevertCrashCapture)) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed | Out-String | Write-Host
    return
}

function Stop-WuServices {
    $stopped = @()
    foreach ($name in @('bits','wuauserv','cryptsvc')) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { Stop-Service -Name $name -Force -ErrorAction Stop; $stopped += $name }
    }
    return $stopped
}
function Start-BackServices([string[]]$names) {
    foreach ($name in $names) { try { Start-Service -Name $name -ErrorAction Stop } catch { Write-Warning "Could not restart ${name}: $($_.Exception.Message)" } }
}
function Rename-WithBackup([string]$folder) {
    if (-not (Test-Path -LiteralPath $folder)) { Write-Host "Absent, skipped: $folder"; return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $leaf = Split-Path $folder -Leaf
    $bak = Join-Path (Split-Path $folder -Parent) ("$leaf.bak-$stamp")
    if (Test-Path -LiteralPath $bak) { throw "Backup path already exists: $bak" }
    Rename-Item -LiteralPath $folder -NewName (Split-Path $bak -Leaf) -ErrorAction Stop
    Write-Host "Renamed $folder -> $bak"
}

if ($RunDISMRestoreHealth) {
    Write-Warning 'DISM RestoreHealth can take considerable time and may download from Windows Update. Do not interrupt. If it fails 0x800f081f, use a matching repair source (see references/windows-update-internals.md).'
    if ($PSCmdlet.ShouldProcess('Online Windows image','Run DISM RestoreHealth')) {
        & dism.exe /Online /Cleanup-Image /RestoreHealth
        if ($LASTEXITCODE -ne 0) { throw "DISM failed with exit code $LASTEXITCODE. Preserve %windir%\Logs\CBS\CBS.log and dism.log; investigate before continuing." }
    }
}
if ($RunSFCScanNow) {
    Write-Warning 'sfc /scannow repairs protected system files; run after DISM when component repair was needed.'
    if ($PSCmdlet.ShouldProcess('Protected Windows system files','Run sfc /scannow')) {
        & sfc.exe /scannow
        if ($LASTEXITCODE -ne 0) { throw "SFC exit code $LASTEXITCODE. Review CBS.log." }
    }
}
if ($ResetUpdateComponents -or $ResetUpdateCache) {
    Write-Warning 'Reversible rename of update cache/catalog data. Windows recreates folders; updates may re-download. Keep .bak folders until verified, then remove with approval. Does NOT fix component-store corruption.'
    if ($PSCmdlet.ShouldProcess('WU caches (SoftwareDistribution / catroot2) and services bits/wuauserv/cryptsvc','Stop services, rename caches, restart services')) {
        $stopped = Stop-WuServices
        try {
            if ($IncludeQmgr) {
                $q = Join-Path $env:ALLUSERSPROFILE 'Application Data\Microsoft\Network\Downloader'
                if (Test-Path -LiteralPath $q) { Get-ChildItem -LiteralPath $q -Filter 'qmgr*.dat' -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue; Write-Host 'Removed BITS qmgr*.dat queue files (recreated).' }
            }
            if ($ResetUpdateComponents) {
                Rename-WithBackup (Join-Path $env:windir 'SoftwareDistribution\DataStore')
                Rename-WithBackup (Join-Path $env:windir 'SoftwareDistribution\Download')
                Rename-WithBackup (Join-Path $env:windir 'System32\catroot2')
            }
            if ($ResetUpdateCache) {
                Rename-WithBackup (Join-Path $env:windir 'SoftwareDistribution')
                Rename-WithBackup (Join-Path $env:windir 'System32\catroot2')
            }
        } finally { Start-BackServices $stopped }
        Write-Host 'Cache reset done. Verify with verify-system-health.ps1 then retry the update once.' -ForegroundColor Green
    }
}
if ($RunWuauservDetect) {
    if ($PSCmdlet.ShouldProcess('Windows Update service','Start service and run detection-only scan')) {
        Start-Service wuauserv -ErrorAction SilentlyContinue
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        Write-Host 'Detection scan (no download/install)...' -ForegroundColor Cyan
        $result = $searcher.Search('IsInstalled=0')
        "Updates detected: $($result.Updates.Count)"
        $result.Updates | Select-Object -First 30 @{n='Title';e={$_.Title}},@{n='Downloaded';e={$_.IsDownloaded}},@{n='Eula';e={$_.EulaAccepted}} | Format-Table -AutoSize
    }
}
$ccPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
$ccBackup = Join-Path $scriptDir 'crash-control-previous.txt'
if ($SetCrashCapture) {
    Write-Warning 'Sets automatic memory dump and disables automatic restart so a failed upgrade can leave a readable stop code. WARNING: Windows Setup may not carry these into the target OS (confirmed in real cases: target logged "Crash dump disabled" anyway). Record current values; revert afterwards if desired.'
    if ($PSCmdlet.ShouldProcess('CrashControl registry','Set CrashDumpEnabled=7, AutoReboot=0')) {
        $cc = Get-ItemProperty -LiteralPath $ccPath
        "CrashDumpEnabled=$($cc.CrashDumpEnabled);AutoReboot=$($cc.AutoReboot);DumpFile=$($cc.DumpFile)" | Set-Content -LiteralPath $ccBackup -Encoding ASCII
        Set-ItemProperty -LiteralPath $ccPath -Name CrashDumpEnabled -Value 7
        Set-ItemProperty -LiteralPath $ccPath -Name AutoReboot -Value 0
        "Previous values saved to $ccBackup. Set effective: CrashDumpEnabled=$((Get-ItemProperty -LiteralPath $ccPath).CrashDumpEnabled) AutoReboot=$((Get-ItemProperty -LiteralPath $ccPath).AutoReboot)"
        Write-Host 'Also ensure the dump volume (usually C:) has free space ~ RAM size for kernel/automatic dumps, and consider system-managed pagefile.' -ForegroundColor Yellow
    }
}
if ($RevertCrashCapture) {
    if (-not (Test-Path -LiteralPath $ccBackup)) { throw "No saved backup at $ccBackup; nothing reverted." }
    if ($PSCmdlet.ShouldProcess('CrashControl registry','Restore previously recorded values')) {
        $prev = Get-Content -LiteralPath $ccBackup -Raw
        if ($prev -match 'CrashDumpEnabled=(\d+)') { Set-ItemProperty -LiteralPath $ccPath -Name CrashDumpEnabled -Value ([int]$Matches[1]) }
        if ($prev -match 'AutoReboot=(\d+)') { Set-ItemProperty -LiteralPath $ccPath -Name AutoReboot -Value ([int]$Matches[1]) }
        Write-Host "Restored: $prev" -ForegroundColor Green
    }
}
Write-Host 'Selected actions finished or were previewed. Run verify-system-health.ps1, retry the original update once, and record expected-vs-observed outcome.' -ForegroundColor Cyan
