<#
.SYNOPSIS
Read-only "attempt ledger": reconstruct failed update/upgrade attempts and what changed around each.
.DESCRIPTION
Builds a timeline from the persistent record: WindowsUpdateClient events (19/20/43/216/218 and scan
failures) over a long window, MoSetup/BlueBox markers, SetupDiag results (live registry + saved),
$WINDOWS.~BT presence/date (only the LAST attempt survives there), C:\Windows\Panther dates (OS
install age and earlier setup runs), installed-product and driver-file install dates for named
candidates, and current servicing currency (UBR/DisplayVersion from Windows NT\CurrentVersion,
Get-HotFix dates). WHY: a candidate's removal only tests it on the attempts that happened AFTER the
removal AND while it was present in the baseline failure; attempts before its install cannot be
explained by it. The ledger is the input to that reasoning. Changes nothing.
.EXAMPLE
.\get-attempt-history.ps1 -DaysBack 120 -Candidate vlflt.sys,atc.sys,PxHlpa64.sys,EPMVolFl.sys
#>
[CmdletBinding()]
param(
    [int]$DaysBack = 120,
    [string[]]$Candidate = @()
)
$ErrorActionPreference = 'Continue'
$start = (Get-Date).AddDays(-$DaysBack)

Write-Host "=== Servicing currency ===" -ForegroundColor Cyan
$nt = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
$os = Get-CimInstance Win32_OperatingSystem
[PSCustomObject]@{ Build=("{0}.{1}" -f $nt.CurrentBuild,$nt.UBR); DisplayVersion=$nt.DisplayVersion
  OSInstall=(Get-Date '1970-01-01').AddSeconds($nt.InstallDate) } | Format-List
Get-HotFix | Where-Object { $_.HotFixID -match 'KB50' } | Sort-Object InstalledOn -Descending |
  Select-Object -First 6 | Format-Table HotFixID,Description,InstalledOn -AutoSize
Write-Host 'Note: an EOL branch keeps its last LCU forever; "months old" is expected there. An OS install years old with in-place-upgrade lineage carries a multi-generation third-party driver stack (driver-file CreationTime tells the real driver ages).' -ForegroundColor Yellow

Write-Host "=== Feature/quality update attempt timeline (WindowsUpdateClient, $DaysBack days) ===" -ForegroundColor Cyan
try {
    Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WindowsUpdateClient'; StartTime=$start} -ErrorAction Stop |
      Where-Object { ($_.Id -in 19,20,21,25,26,43,216,218) -and ($_.Message -match 'Windows 11|Windows 10|Feature|version|Upgrade|update with error') } |
      Sort-Object TimeCreated | ForEach-Object {
        $kind = switch ($_.Id) { 19 {'SUCCESS'} 20 {'FAILURE'} 21 {'restart-required'} 25 {'scan-failed'} 26 {'scan-ok'} 43 {'install-start'} 216 {'commit-ok'} 218 {'commit-start'} }
        $msg = $_.Message -replace '\s+',' '
        "{0}  {1,-17} {2}" -f $_.TimeCreated.ToString('yyyy-MM-dd HH:mm'), $kind, $msg.Substring(0, [Math]::Min(150, $msg.Length))
      }
} catch { Write-Warning "System WU events unreadable: $($_.Exception.Message)" }

Write-Host "`n=== Last-attempt staging tree (only the most recent attempt lives here) ===" -ForegroundColor Cyan
foreach ($p in @("$env:SystemDrive\`$WINDOWS.~BT","$env:SystemDrive\`$WINDOWS.~BT\Sources\Rollback","C:\Windows\Panther\NewOs","C:\Windows\Logs\MoSetup\BlueBox.log")) {
    if (Test-Path -LiteralPath $p) {
        $it = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        "{0}  last={1}" -f $p, $it.LastWriteTime
    } else { "{0}  (absent - cleanup/age; cannot reconstruct that attempt anymore)" -f $p }
}
$vol = Join-Path $env:SystemDrive '$WINDOWS.~BT\Sources\Volume'
if (Test-Path -LiteralPath $vol) { Get-ChildItem $vol -Filter '*.xml' -ErrorAction SilentlyContinue | Select-Object Name,LastWriteTime | Format-Table -AutoSize }

Write-Host "=== SetupDiag last-result (volatile; overwritten each analysis) ===" -ForegroundColor Cyan
try { Get-ItemProperty 'HKLM:\SYSTEM\Setup\MoSetup\Volatile\SetupDiag' -ErrorAction Stop |
    Select-Object ProfileName,HostOSVersion,TargetOSVersion,UpgradeStartTime,RollbackEndTime,FailureDetails,ReportId | Format-List }
catch { 'not readable / none' }

Write-Host "=== Candidate install dates (compare against attempt timestamps!) ===" -ForegroundColor Cyan
if (@($Candidate).Count -eq 0) {
    $Candidate = Get-CimInstance Win32_SystemDriver | Where-Object { $_.StartMode -in 'Boot','System' -and $_.PathName } |
      ForEach-Object { ($_.PathName -replace '^\\\??\\','' -replace '^SystemRoot',$env:windir) } |
      Where-Object { Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue } | Select-Object -First 60
}
$Candidate | ForEach-Object {
    $f = if ($_ -match '^[A-Za-z]:') { $_ } else { Join-Path "$env:windir\System32\drivers" $_ }
    if (Test-Path -LiteralPath $f) {
        $i = Get-Item -LiteralPath $f
        $pub = try { $i.VersionInfo.CompanyName } catch { '' }
        "{0,-28} created={1:yyyy-MM-dd}  pub={2}" -f $i.Name, $i.CreationTime, $pub
    }
} | Sort-Object -Unique
Write-Host 'Interpretation rules: (1) component created AFTER an attempt = cannot explain that attempt; (2) a removal "test" is valid only for attempts after the removal AND while the component was present in the baseline failure set; (3) reinstalling a removed suspect resets the ledger - later failures no longer test its absence.' -ForegroundColor Yellow
