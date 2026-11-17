<#
.SYNOPSIS
Read-only post-repair / pre-attempt health verification.
.DESCRIPTION
Checks DISM CheckHealth (and optionally ScanHealth), SFC verifyonly, update service states,
volume free space vs feature-update thresholds, crash-capture and pagefile readiness,
class-filter sanity (Microsoft entries present), and recent WU client failures.
These checks do NOT prove Windows Update can install an update; final proof is the update succeeding.
Run elevated for reliable DISM/SFC results. Changes nothing.
.EXAMPLE
.\verify-system-health.ps1 -Full
#>
[CmdletBinding()]
param(
    [switch]$Full,
    [int]$WuEventDays = 14
)
$ErrorActionPreference = 'Continue'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "Elevated: $isAdmin" -ForegroundColor Cyan
if (-not $isAdmin) { Write-Warning 'Run elevated for dependable DISM/SFC/event results.' }

if ($isAdmin) {
    Write-Host "`n=== DISM CheckHealth ===" -ForegroundColor Cyan
    & dism.exe /Online /Cleanup-Image /CheckHealth
    Write-Host "DISM exit code: $LASTEXITCODE"
    if ($Full) {
        Write-Host "`n=== DISM ScanHealth (minutes) ===" -ForegroundColor Cyan
        & dism.exe /Online /Cleanup-Image /ScanHealth
        Write-Host "DISM exit code: $LASTEXITCODE"
    }
    Write-Host "`n=== SFC verifyonly (verification only, no repair; minutes) ===" -ForegroundColor Cyan
    & sfc.exe /verifyonly
    Write-Host "SFC exit code: $LASTEXITCODE"
} else {
    Write-Warning 'DISM/SFC SKIPPED: elevation required (DISM exit 740). This is an evidence gap, not a clean result.'
}

Write-Host "`n=== Update service states (trigger-stopped is normal) ===" -ForegroundColor Cyan
Get-CimInstance Win32_Service | Where-Object { $_.Name -in @('wuauserv','BITS','CryptSvc','UsoSvc','WaaSMedicSvc','TrustedInstaller','rpcss') } |
  Select-Object Name,State,StartMode,ExitCode | Format-Table -AutoSize

Write-Host "=== Volume free space vs feature-update thresholds (20 GB min / 60 GB comfortable) ===" -ForegroundColor Cyan
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
    $freeGB = [math]::Round($_.FreeSpace/1GB,1)
    $flag = if ($freeGB -lt 20) { 'TOO LOW for feature update' } elseif ($freeGB -lt 60) { 'below comfortable' } else { 'ok' }
    [pscustomobject]@{ Volume=$_.DeviceID; FreeGB=$freeGB; Assessment=$flag }
} | Format-Table -AutoSize

Write-Host "=== Crash capture / pagefile (diagnostic-attempt readiness) ===" -ForegroundColor Cyan
$cc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction SilentlyContinue
"CrashDumpEnabled=$($cc.CrashDumpEnabled) (7=automatic recommended) AutoReboot=$($cc.AutoReboot) (0=manual stop reading) DumpFile=$($cc.DumpFile)"
$cs = Get-CimInstance Win32_ComputerSystem
"AutomaticManagedPagefile=$($cs.AutomaticManagedPagefile); pagefile C: present: $((Get-CimInstance Win32_PageFileUsage | Where-Object { $_.Name -like "$env:SystemDrive\*" }) -ne $null)"

Write-Host "`n=== Class filter sanity (Microsoft anchors must exist) ===" -ForegroundColor Cyan
$checks = @{
    '{4d36e967-e325-11ce-bfc1-08002be10318}' = @('UpperFilters','partmgr');
    '{71a27cdd-812a-11d0-bec7-08002be2092f}' = @('UpperFilters','volsnap')
}
foreach ($k in $checks.Keys) {
    $val = $checks[$k][0]; $want = $checks[$k][1]
    $list = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$k" -Name $val -ErrorAction SilentlyContinue).$val
    "{0} class {1}: {2} present={3}; full list: {4}" -f $k.Substring(1,8), $val, $want, ($list -contains $want), ($list -join ',')
}
Write-Host 'Run inventory-storage-filters.ps1 for third-party filter/boot-driver candidates.'

Write-Host "`n=== Recent Windows Update client failures (last $WuEventDays days) ===" -ForegroundColor Cyan
try {
    Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WindowsUpdateClient'; StartTime=(Get-Date).AddDays(-$WuEventDays); Level=2} -ErrorAction Stop |
      Select-Object -First 25 TimeCreated,Id,Message | Format-Table -AutoSize -Wrap
} catch { 'No error-level WindowsUpdateClient events (or channel unreadable).' }

Write-Host "`nChecks complete. Success criterion remains: the originally failing update installs and the boot stays clean." -ForegroundColor Yellow
