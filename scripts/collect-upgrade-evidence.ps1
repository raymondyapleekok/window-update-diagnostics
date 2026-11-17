<#
.SYNOPSIS
Elevated, read-only evidence collector for a failed Windows feature update / rollback.
.DESCRIPTION
Must be run in an ALREADY-elevated PowerShell window (never auto-elevates). After a rollback it
copies protected saved EVTX/bootstat/BCD artifacts from the setup staging tree that non-elevated
collectors cannot read, exports events within the attempt window, captures live state
(BCD, filters, reagent, drivers, crash/pagefile) and writes a SHA256 manifest. Changes nothing:
no reboots, no setup launches, no setting changes.
Adapted from a real Z690/24H2-class rollback case where protected EVTX reads were the missing evidence.
.EXAMPLE
# Windows PowerShell as Administrator:
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\collect-upgrade-evidence.ps1 -WindowStart (Get-date).AddDays(-2)
#>
[CmdletBinding()]
param(
    [Nullable[DateTime]]$WindowStart = $null,
    [Nullable[DateTime]]$WindowEnd = $null,
    [string]$OutRoot = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'WindowsUpdateEvidence'),
    [string[]]$Channels = @('System','Setup','Microsoft-Windows-Kernel-Boot','Microsoft-Windows-Kernel-PnP','Microsoft-Windows-Kernel-PnP/Configuration','Microsoft-Windows-FilterManager','Microsoft-Windows-CodeIntegrity/Operational','Microsoft-Windows-DriverFrameworks-UserMode/Operational','Microsoft-Windows-WHEA-System')
)

$ErrorActionPreference = 'Continue'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error 'This collector must be run in an ALREADY-elevated Windows PowerShell window (Run as administrator). No collection attempted.'
    exit 2
}
if (-not $WindowStart) { $WindowStart = (Get-Date).AddDays(-1) }
if (-not $WindowEnd) { $WindowEnd = (Get-Date) }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $OutRoot "AdminEvidence-$stamp"
foreach ($sub in @('evtx','events','bcd','state')) { New-Item -ItemType Directory -Path (Join-Path $outDir $sub) -Force | Out-Null }
$notesFile = Join-Path $outDir 'collection-notes.txt'
"Collection started $(Get-Date -Format 'o'); window $WindowStart..$WindowEnd" | Set-Content -LiteralPath $notesFile -Encoding UTF8
function Add-Note([string]$Text) { "$(Get-Date -Format 'o') $Text" | Add-Content -LiteralPath $notesFile }
Write-Host "Admin read-only evidence collection -> $outDir" -ForegroundColor Cyan
Write-Host "Window: $WindowStart .. $WindowEnd" -ForegroundColor Yellow

# 1) Copy saved rollback/setup artifacts (protected; elevation required)
# NOTE PS5.1: -Include is ignored when combined with -LiteralPath; filter by Name via Where-Object.
$bt = "$env:SystemDrive\`$WINDOWS.~BT"
$namePattern = '\.(evtx|dmp)$|^bootstat|^BCD$|^bcd$|^setuperr\.log$|^WinSetupMon\.log$|^checkpoint\.info$|^diagnostics\.dat$'
$sources = @(
    (Join-Path $bt 'Sources\Rollback'),
    (Join-Path $bt 'Sources\Panther'),
    'C:\Windows\Panther'
)
Write-Host "Step 1/6: copying targeted artifacts (EVTX/DMP/bootstat/BCD/setuperr)..." -ForegroundColor Yellow
foreach ($src in $sources) {
    if (-not (Test-Path -LiteralPath $src)) { Add-Note "Absent: $src"; continue }
    foreach ($f in Get-ChildItem -Path $src -File -Recurse -Force -EA SilentlyContinue | Where-Object { $_.Name -match $namePattern }) {
        $destName = ($f.FullName -replace '[:\\]','_')
        $dest = Join-Path (Join-Path $outDir 'evtx') $destName
        if ($f.Length -gt 2GB) { Add-Note "Oversized, skipped: $($f.FullName)"; continue }
        try { Copy-Item -LiteralPath $f.FullName -Destination $dest -Force -EA Stop }
        catch { Add-Note "COPY DENIED/failed: $($f.FullName) - $($_.Exception.Message)" }
    }
    "  scanned $src" | Add-Content $notesFile
}

# 2) Parse copied saved-EVTX for the attempt window (error/warning events)
Write-Host "Step 2/6: parsing copied saved EVTX for window events..." -ForegroundColor Yellow
$saved = @()
foreach ($e in Get-ChildItem -LiteralPath (Join-Path $outDir 'evtx') -Filter '*.evtx' -ErrorAction SilentlyContinue) {
    try {
        $ev = Get-WinEvent -Path $e.FullName -FilterXPath "*[System[(Level=1 or Level=2 or Level=3) and TimeCreated[@SystemTime>='$($WindowStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))'] and TimeCreated[@SystemTime<='$($WindowEnd.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))']]]" -ErrorAction Stop
        $j = $ev | ForEach-Object { [pscustomobject]@{Time=$_.TimeCreated; Id=$_.Id; Level=$_.LevelDisplayName; Provider=$_.Provider.Name; Message=$_.Message} }
        $out = Join-Path (Join-Path $outDir 'events') ($e.BaseName + '.json')
        $j | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $out -Encoding UTF8
        $saved += [pscustomobject]@{File=$e.Name; Count=@($j).Count}
    } catch { Add-Note "Saved EVTX unreadable: $($e.Name) - $($_.Exception.Message)" }
}
$saved | Format-Table -AutoSize | Out-String -Width 200 | Tee-Object -FilePath (Join-Path $outDir 'events\saved-evtx-summary.txt')

# 3) Live channels within the window (for comparison; these usually reflect the RESTORED OS)
Write-Host "Step 3/6: exporting live event channels..." -ForegroundColor Yellow
foreach ($ch in $Channels) {
    try {
        $ev = Get-WinEvent -FilterHashtable @{LogName=$ch; StartTime=$WindowStart; EndTime=$WindowEnd} -ErrorAction Stop |
              Where-Object { $_.LevelDisplayName -in 'Error','Warning','Critical' -or $_.Id -in 19,20,25,31,43,44,104,125,138,139,140,225,226,292,10,13 }
        $out = Join-Path (Join-Path $outDir 'events') ("live-$($ch -replace '[\\/:*?"<>|]','_').json")
        $ev | Select-Object -First 5000 | ForEach-Object { [pscustomobject]@{Time=$_.TimeCreated; Id=$_.Id; Level=$_.LevelDisplayName; Provider=$_.Provider.Name; Message=$_.Message} } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $out -Encoding UTF8
    } catch { Add-Note "Live channel export none/denied: $ch - $($_.Exception.Message)" }
}

# 4) Boot configuration: live store + targeted saved stores (NO full-tree recursion: the staging
#    tree contains a mounted Windows image; enumerate only known/likely BCD locations)
Write-Host "Step 4/6: enumerating boot stores..." -ForegroundColor Yellow
& bcdedit.exe /enum all 2>&1 | Out-File (Join-Path $outDir 'bcd\bcd-live.txt') -Encoding utf8
$bcdCandidates = @(
    "$env:SystemDrive\EFI\Microsoft\Boot\BCD",
    "$env:SystemDrive\Boot\BCD",
    (Join-Path $bt 'Sources\Rollback\bootstat\BCD'),
    (Join-Path $bt 'Sources\Rollback\BCD'),
    (Join-Path $bt 'EFI\Microsoft\Boot\BCD'),
    (Join-Path $bt 'Sources\Panther\bootstat\BCD')
)
$bcdCandidates += @(Get-ChildItem -Path (Join-Path $bt 'Sources\Rollback') -File -Recurse -Force -EA SilentlyContinue | Where-Object { $_.Name -eq 'BCD' -and $_.Length -lt 10MB } | Select-Object -ExpandProperty FullName)
foreach ($p in ($bcdCandidates | Where-Object { $_ } | Select-Object -Unique)) {
    if (Test-Path -LiteralPath $p) { & bcdedit.exe /store $p /enum all 2>&1 | Out-File (Join-Path $outDir ("bcd\bcd-saved-" + ($p -replace '[:\\]','_') + ".txt")) -Encoding utf8 }
}

# 5) Live state queries (read-only; several need admin)
Write-Host "Step 5/6: capturing live state (reagent, filters, drivers, BCD state)..." -ForegroundColor Yellow
& reagentc.exe /info 2>&1 | Out-File (Join-Path $outDir 'state\reagentc.txt') -Encoding utf8
& fltmc.exe filters 2>&1 | Out-File (Join-Path $outDir 'state\fltmc-filters.txt') -Encoding utf8
& fltmc.exe volumes 2>&1 | Out-File (Join-Path $outDir 'state\fltmc-volumes.txt') -Encoding utf8
& pnputil.exe /enum-drivers 2>&1 | Out-File (Join-Path $outDir 'state\pnputil-enum-drivers.txt') -Encoding utf8
Get-CimInstance Win32_SystemDriver | Where-Object { $_.State -eq 'Running' -and $_.StartMode -in 'Boot','System' } |
  Select-Object Name,DisplayName,PathName,StartMode,State | Sort-Object Name |
  Format-Table -AutoSize | Out-String -Width 240 | Out-File (Join-Path $outDir 'state\boot-start-drivers.txt') -Encoding utf8
$inv = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'inventory-storage-filters.ps1'
if (Test-Path $inv) { & $inv -AsJson 2>$null | Out-File -LiteralPath (Join-Path $outDir 'state\storage-filters.json') -Encoding utf8 }
$cc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction SilentlyContinue
[PSCustomObject]@{CrashDumpEnabled=$cc.CrashDumpEnabled; AutoReboot=$cc.AutoReboot; DumpFile=$cc.DumpFile} | Format-List | Out-File (Join-Path $outDir 'state\crash-control.txt') -Encoding utf8
Get-CimInstance Win32_PageFileUsage | Format-Table -AutoSize | Out-String | Out-File (Join-Path $outDir 'state\pagefiles.txt') -Encoding utf8
Get-Disk | Format-Table Number,FriendlyName,Size,PartitionStyle,IsOffline,BootFromDisk -AutoSize | Out-String -Width 240 | Out-File (Join-Path $outDir 'state\disks.txt') -Encoding utf8
Get-Partition | Format-Table DiskNumber,PartitionNumber,DriveLetter,Size,Type,IsBoot,IsSystem -AutoSize | Out-String -Width 240 | Out-File (Join-Path $outDir 'state\partitions.txt') -Encoding utf8
Get-BitLockerVolume -ErrorAction SilentlyContinue | Select-Object MountPoint,ProtectionStatus,KeyProtector | Format-List | Out-File (Join-Path $outDir 'state\bitlocker.txt') -Encoding utf8

# 6) Manifest
Write-Host "Step 6/6: hashing manifest..." -ForegroundColor Yellow
$manifest = @()
Get-ChildItem -LiteralPath $outDir -Recurse -File | ForEach-Object {
    $h = try { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } catch { 'UNREADABLE' }
    $manifest += [pscustomobject]@{ Path=$_.FullName.Substring($outDir.Length).TrimStart('\'); Size=$_.Length; SHA256=$h }
}
$manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $outDir 'manifest.json') -Encoding UTF8

$summary = [pscustomobject]@{
    Output=$outDir; Computer=$env:COMPUTERNAME; Time=(Get-Date).ToString('o'); Elevated=$isAdmin
    Window="$WindowStart .. $WindowEnd"
    FilesCopied=@($manifest).Count
    SavedEvtxExports=($saved | ForEach-Object { "$($_.File)=$($_.Count)" }) -join '; '
    Notes='See collection-notes.txt for denied reads'
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $outDir 'summary.json') -Encoding UTF8
Write-Host "`nDone. Return or open: $outDir" -ForegroundColor Green
Write-Host "Interpretation order per references: (1) saved EVTX Kernel-Dump/Crash event 'Crash dump disabled'?, (2) Kernel-PnP/FilterManager/CodeIntegrity records AT the failing boot, (3) saved vs live BCD diff, (4) filter inventory changes. BOOTSTAT numbers are NOT stop codes." -ForegroundColor Yellow
$summary | Format-List
