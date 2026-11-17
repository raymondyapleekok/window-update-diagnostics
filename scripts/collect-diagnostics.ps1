<#
.SYNOPSIS
Read-only Windows Update / servicing diagnostic collection.
.DESCRIPTION
Collects system state, update services, crash-capture settings, filter-driver inventory,
recent Windows Update events, DISM/SFC read-only checks, and selected logs into a timestamped
folder plus a zip archive and a SHA256 manifest. Changes nothing. Elevation improves coverage
(event channel exports, Get-WindowsUpdateLog, setup log copies) but is not required to run it.
Logs can contain machine names, usernames, paths and update identifiers; review before sharing.
.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\collect-diagnostics.ps1 -IncludeSetupLogs -ConvertWindowsUpdateLog
#>
[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'WindowsUpdateDiagnostics'),
    [switch]$IncludeSetupLogs,
    [switch]$ConvertWindowsUpdateLog,
    [int]$DaysBack = 30,
    [int]$MaxWuEvents = 300
)

$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $OutputRoot "Diagnostic-$stamp"
$logDir = Join-Path $outDir 'Logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$report = Join-Path $outDir 'system-report.txt'
$notesFile = Join-Path $outDir 'collection-notes.txt'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
try { Start-Transcript -Path (Join-Path $outDir 'collection-transcript.txt') -Force | Out-Null } catch {}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Write-Section([string]$Name, [scriptblock]$Command) {
    "`r`n===== $Name =====" | Tee-Object -FilePath $report -Append
    try { & $Command 2>&1 | Out-String -Width 240 | Tee-Object -FilePath $report -Append }
    catch { "ERROR: $($_.Exception.Message)" | Tee-Object -FilePath $report -Append }
}
function Add-Note([string]$Text) { "$(Get-Date -Format 'o') $Text" | Add-Content -LiteralPath $notesFile }

Write-Host "Collecting read-only Windows diagnostics into: $outDir" -ForegroundColor Cyan
Write-Host "Elevated: $isAdmin (elevation adds event exports, WU ETL conversion, setup-log copies)" -ForegroundColor Yellow
Write-Host "Logs may contain identifying device/account information. Review before sharing." -ForegroundColor Yellow

Write-Section 'Collection metadata' {
    [pscustomobject]@{
        Collected=(Get-Date).ToString('o'); Computer=$env:COMPUTERNAME; User=$env:USERNAME
        PowerShell=$PSVersionTable.PSVersion.ToString(); Elevated=$isAdmin; DaysBack=$DaysBack
    } | Format-List
}
Write-Section 'Windows operating system (version data lives in Windows NT\CurrentVersion on Win10/11)' {
    $nt = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $os = Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{
        Caption=$os.Caption; CurrentBuild=$nt.CurrentBuild; UBR=$nt.UBR
        FullBuild=(" {0}.{1}" -f $nt.CurrentBuild,$nt.UBR); DisplayVersion=$nt.DisplayVersion; ReleaseId=$nt.ReleaseId
        EditionID=$nt.EditionID; InstallationType=$nt.InstallationType; ProductNameLegacy=$nt.ProductName
        BuildLab=$nt.BuildLab; OSArchitecture=$os.OSArchitecture
        InstallDate=(Get-Date '1970-01-01').AddSeconds($nt.InstallDate)
        LastBoot=$os.LastBootUpTime
        PatchFrozenHint=$( if ($nt.UBR) { 'Compare UBR build against current release health: a months-old UBR on an EOL branch is frozen servicing, not necessarily a fault.' } else { 'UBR missing - abnormal; servicing metadata damage suspected.' } )
    } | Format-List
}
Write-Section 'Computer system / firmware' {
    Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer,Model,SystemType,Domain,PartOfDomain,TotalPhysicalMemory | Format-List
    Get-CimInstance Win32_BIOS | Select-Object Manufacturer,SMBIOSBIOSVersion,ReleaseDate | Format-List
    try { "SecureBoot confirmed: " + (Confirm-SecureBootUefi) } catch { "SecureBoot query unavailable: $($_.Exception.Message)" }
    try {
        $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
        "VBS running: $($dg.VirtualizationBasedSecurityStatus) (0=off,1=cfg,2=running)  SecurityServicesRunning: $($dg.SecurityServicesRunning -join ',')"
    } catch { Add-Note "DeviceGuard query denied/unavailable"; "VBS query unavailable: $($_.Exception.Message)" }
}
Write-Section 'Volumes and free space' {
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
      Select-Object DeviceID,VolumeName,@{n='SizeGB';e={[math]::Round($_.Size/1GB,2)}},@{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,2)}},FileSystem | Format-Table -AutoSize
    "Feature updates require at least 20 GB free on the Windows volume; 60+ GB recommended."
}
Write-Section 'Update-related services (stopped trigger-start services are often normal)' {
    Get-CimInstance Win32_Service | Where-Object { $_.Name -in @('wuauserv','BITS','CryptSvc','UsoSvc','WaaSMedicSvc','TrustedInstaller','AppID','msiserver','rpcss') } |
      Select-Object Name,State,StartMode,ExitCode,ServiceSpecificExitCode,StartName | Format-Table -AutoSize
}
Write-Section 'Recent hotfixes' { Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 30 HotFixID,Description,InstalledOn,InstalledBy | Format-Table -AutoSize }
Write-Section 'Pending reboot indicators (clues only)' {
    $paths = @(
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'
    )
    $paths | ForEach-Object { [pscustomobject]@{Path=$_;Exists=(Test-Path -LiteralPath $_)} } | Format-Table -AutoSize
    $sm = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    "PendingFileRenameOperations present: $($null -ne $sm.PendingFileRenameOperations)"
    if (Test-Path "$env:windir\WinSxS\pending.xml") { "pending.xml exists (do NOT delete; note only)" } else { "pending.xml absent" }
}
Write-Section 'Crash capture and pagefile state' {
    $cc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction SilentlyContinue
    [pscustomobject]@{CrashDumpEnabled=$cc.CrashDumpEnabled; AutoReboot=$cc.AutoReboot; DumpFile=$cc.DumpFile} | Format-List
    "0=none 1=complete 2=kernel 3=small 7=automatic"
    Get-CimInstance Win32_PageFileUsage | Select-Object Name,AllocatedBaseSize,CurrentUsage | Format-Table -AutoSize
    $cs = Get-CimInstance Win32_ComputerSystem
    "AutomaticManagedPagefile: $($cs.AutomaticManagedPagefile)"
    foreach ($loc in @("$env:windir\MEMORY.DMP","$env:windir\Minidump")) { if (Test-Path $loc) { "Dump artifact present: $loc" } }
}
Write-Section 'Proxy configuration (winhttp)' { netsh winhttp show proxy }
Write-Section 'Windows Update policy indicators (read-only; managed devices go to their admin)' {
    foreach ($p in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update')) {
      "Path: $p"
      if (Test-Path $p) { Get-ItemProperty -Path $p | Select-Object * -ExcludeProperty PSPath,PSParentPath,PSChildName,PSDrive,PSProvider | Format-List } else { 'Not present' }
    }
}
Write-Section "Recent Windows Update client events (System log, last $DaysBack days)" {
    try {
        Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WindowsUpdateClient'; StartTime=(Get-Date).AddDays(-$DaysBack)} -ErrorAction Stop |
          Select-Object -First $MaxWuEvents TimeCreated,Id,LevelDisplayName,Message | Format-Table -AutoSize -Wrap
    } catch { "No WindowsUpdateClient events or channel unreadable: $($_.Exception.Message)" }
}
Write-Section "Recent WU operational channel failures (scan/download/install)" {
    try {
        Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-WindowsUpdateClient/Operational'; StartTime=(Get-Date).AddDays(-$DaysBack)} -ErrorAction Stop |
          Where-Object { $_.Id -in 20,25,31 -or $_.LevelDisplayName -in 'Error','Warning' } |
          Select-Object -First $MaxWuEvents TimeCreated,Id,LevelDisplayName,Message | Format-Table -AutoSize -Wrap
    } catch { "Operational channel unreadable (not enabled or access denied): $($_.Exception.Message)" }
}
Write-Section 'Storage filter / third-party boot driver inventory' {
    $inv = Join-Path $scriptDir 'inventory-storage-filters.ps1'
    if (Test-Path $inv) {
        & $inv -AsJson 2>$null | Out-File -LiteralPath (Join-Path $logDir 'filter-inventory.json') -Encoding UTF8
        'JSON saved to Logs\filter-inventory.json (full console detail also in the transcript; tables below may interleave).'
        Get-Content -LiteralPath (Join-Path $logDir 'filter-inventory.json') -Raw
    } else { 'inventory-storage-filters.ps1 not found beside collector' }
}
Write-Section 'Setup staging presence (do not delete; may hold rollback logs)' {
    @("$env:SystemDrive\`$WINDOWS.~BT","$env:SystemDrive\`$WINDOWS.~WS",'C:\Windows\Panther','C:\Windows\Logs\MoSetup','C:\Windows\Logs\SetupDiag') |
      ForEach-Object { [pscustomobject]@{Path=$_; Exists=(Test-Path -LiteralPath $_)} } | Format-Table -AutoSize
}
if ($isAdmin) {
    Write-Section 'DISM CheckHealth (read-only)' { & dism.exe /Online /Cleanup-Image /CheckHealth; "DISM exit code: $LASTEXITCODE" }
    Write-Section 'SFC verifyonly (read-only; can take minutes)' { & sfc.exe /verifyonly; "SFC exit code: $LASTEXITCODE (0 often means no integrity violations detected)" }
} else {
    Write-Section 'DISM/SFC health checks SKIPPED' { 'Re-run elevated: DISM requires administrator (exit 740) and SFC requires an elevated console. This is an evidence gap, not a healthy result.' }
}

$channels = @('Microsoft-Windows-WindowsUpdateClient/Operational','System','Setup','Microsoft-Windows-FilterManager','Microsoft-Windows-Kernel-PnP/Configuration')
foreach ($channel in $channels) {
    $safe = $channel -replace '[\\/:*?"<>|]','_'
    $dest = Join-Path $logDir "$safe.evtx"
    try {
        & wevtutil.exe epl $channel $dest '/ow:true' 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "Exported $channel" } else { Add-Note "wevtutil epl DENIED/failed for $channel (exit $LASTEXITCODE; usually requires elevation)" }
    } catch { Add-Note "wevtutil epl failed for $channel : $($_.Exception.Message)" }
}

$copyTargets = @(
  @{Source="$env:windir\Logs\CBS\CBS.log";Name='CBS.log'},
  @{Source="$env:windir\Logs\DISM\dism.log";Name='dism.log'},
  @{Source="$env:windir\INF\setupapi.dev.log";Name='setupapi.dev.log'},
  @{Source="$env:windir\Logs\MoSetup\BlueBox.log";Name='BlueBox.log'}
)
foreach ($item in $copyTargets) {
    if (Test-Path -LiteralPath $item.Source) {
        try { Copy-Item -LiteralPath $item.Source -Destination (Join-Path $logDir $item.Name) -ErrorAction Stop }
        catch { Add-Note "Copy failed: $($item.Source) - $($_.Exception.Message)" }
    }
}

if ($ConvertWindowsUpdateLog) {
    try {
        $wulog = Join-Path $logDir 'WindowsUpdate.log'
        Get-WindowsUpdateLog -LogPath $wulog -ErrorAction Stop | Out-Null
        if (-not (Test-Path $wulog)) { Add-Note 'Get-WindowsUpdateLog produced no file' }
    } catch { Add-Note "Get-WindowsUpdateLog failed: $($_.Exception.Message)" }
}

if ($IncludeSetupLogs) {
    $setupSources = @(
        @{Dir="$env:SystemDrive\`$WINDOWS.~BT\Sources\Panther"; Name='WINDOWS-BT-Sources-Panther'},
        @{Dir="$env:SystemDrive\`$WINDOWS.~BT\Sources\Rollback"; Name='WINDOWS-BT-Sources-Rollback'},
        @{Dir='C:\Windows\Panther'; Name='Windows-Panther'}
    )
    foreach ($s in $setupSources) {
        if (-not (Test-Path -LiteralPath $s.Dir)) { continue }
        $target = Join-Path $logDir $s.Name
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Get-ChildItem -LiteralPath $s.Dir -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Length -gt 400MB) { Add-Note "Skipped oversized file $($_.FullName) ($([math]::Round($_.Length/1MB,0)) MB); copy manually if needed"; return }
            $rel = $_.FullName.Substring($s.Dir.Length).TrimStart('\')
            $dest = Join-Path $target $rel
            $destDir = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            try { Copy-Item -LiteralPath $_.FullName -Destination $dest -Force -ErrorAction Stop }
            catch { Add-Note "Setup log copy denied: $($_.FullName) - $($_.Exception.Message)" }
        }
    }
}

try { Stop-Transcript | Out-Null } catch {}

$manifest = @()
Get-ChildItem -LiteralPath $outDir -Recurse -File | ForEach-Object {
    $h = try { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } catch { 'UNREADABLE' }
    $manifest += [pscustomobject]@{ Path=$_.FullName.Substring($outDir.Length).TrimStart('\'); Size=$_.Length; SHA256=$h }
}
$manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $outDir 'manifest.json') -Encoding UTF8

$zip = "$outDir.zip"
try {
    Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zip -CompressionLevel Optimal
    Write-Host "`nFinished. Archive: $zip" -ForegroundColor Green
} catch { Write-Warning "Could not create archive: $($_.Exception.Message). Folder remains at $outDir" }

Write-Host "`nNext steps:" -ForegroundColor Cyan
Write-Host "  1. Review collection-notes.txt for denied reads (run elevated to capture protected EVTX)."
Write-Host "  2. Run SetupDiag via run-setupdiag.ps1 (or elevated collector collect-upgrade-evidence.ps1 after a rollback)."
Write-Host "  3. Feed the Logs folder to analyse-update-logs.ps1, then interpret against references/error-codes.md."
if (-not $isAdmin) { Write-Host "  Collector ran NON-ELEVATED: System/Setup channel exports and saved rollback EVTX may be missing." -ForegroundColor Yellow }
