<#
.SYNOPSIS
Elevated, read-only-first orphan driver package planner for DriverStore cleanup (optional -Apply).
.DESCRIPTION
On migrated/multi-generation systems the DriverStore accumulates third-party packages for hardware
that no longer exists; Windows Setup still migrates them, making them first-class suspects for
0xC1900101-0x40017 second-boot rollbacks (SetupDiag rule UnknownDriverMigrationFailure).
This script: enumerates packages (pnputil/Get-WindowsDriver), collects oemN.inf used by CONNECTED
devices (pnputil /enum-devices /connected), excludes those + Microsoft providers + packages whose
driver service is currently registered/running (protects live products like AV), and tiers the rest:
  Tier1 = unused third-party in boot-relevant classes (System, HDC, SCSIAdapter, DiskDrive, Volume,
          CDROM, USB, Ports, HIDClass, Net, Extension) - storage/System orphans are the priority.
  Tier2 = other unused third-party packages (hygiene; removal optional).
Writes a JSON+text report, BACKS UP Tier1 packages' FileRepository folders and INF files to the
output folder, and prints the exact pnputil delete commands. -Apply deletes Tier1 packages with
per-item confirmation and /uninstall (never /force). Reboot afterwards, then re-run the upgrade
attempt as the SINGLE changed variable (or combine deliberately, accepting reduced attribution).
.EXAMPLE
# Elevated:
.\get-orphan-driver-cleanup-plan.ps1                 # plan + backup only
.\get-orphan-driver-cleanup-plan.ps1 -Apply          # plan, backup, then Tier1 removal with prompts
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [switch]$Apply,
    [switch]$IncludeTier2,
    [string]$OutDir = (Join-Path ([Environment]::GetFolderPath('Desktop')) ("OrphanDriverPlan-" + (Get-Date -Format 'yyyyMMdd-HHmmss')))
)
$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run in an ELEVATED PowerShell window (pnputil enumeration and deletion require it). Nothing was changed.' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$bk = Join-Path $OutDir 'DriverStoreBackup'; New-Item -ItemType Directory -Path $bk -Force | Out-Null

# 1) Connected-device driver usage
$usedBy = @{}
$devTxt = pnputil.exe /enum-devices /connected 2>&1 | Out-String
foreach ($m in [regex]::Matches($devTxt, '(?im)^(?:Driver Name|Inf File)\s*:\s*(oem\d+\.inf)')) { $usedBy[$m.Groups[1].Value.ToLower()] = $true }
"Connected devices reference $($usedBy.Count) distinct oem packages."

# 2) Registered/running driver service names (protect live products)
$liveSvc = @{}
Get-CimInstance Win32_SystemDriver -EA SilentlyContinue | ForEach-Object { $liveSvc[$_.Name.ToLower()] = $_.State }

# 3) Package inventory
$pkgs = @()
$txt = pnputil.exe /enum-drivers 2>&1 | Out-String
foreach ($b in ($txt -split "(?m)^Published\s+Name\s*:\s*")) {
    if ($b -notmatch '(?im)^oem\d+\.inf') { continue }
    $pub = ($b -split "`r?`n" | Select-Object -First 1).Trim()
    $prov = if ($b -match '(?im)^Provider Name\s*:\s*(.+)') { $matches[1].Trim() } else { '?' }
    $cls  = if ($b -match '(?im)^Class Name\s*:\s*(.+)') { $matches[1].Trim() } else { '?' }
    $ver  = if ($b -match '(?im)^Driver Version\s*:\s*(.+)') { $matches[1].Trim() } else { '?' }
    $path = if ($b -match '(?im)^Driver Store Path\s*:\s*(.+?)\s*$') { $matches[1].Trim() } else { $null }
    $pkgs += [pscustomobject]@{ Inf=$pub; Provider=$prov; Class=$cls; Version=$ver; StorePath=$path }
}
"DriverStore packages parsed: $($pkgs.Count)"
if ($pkgs.Count -eq 0) { throw 'No packages parsed - rerun elevated.' }

$bootClasses = 'System','HDC','SCSIAdapter','DiskDrive','Volume','CDROM','USB','Ports','HIDClass','Net','Extension','Keyboard','Mouse'
$ms = @('Microsoft','Microsoft Windows','Microsoft Windows Hardware Compatibility Publisher')
function Is-MsInf($p) { $p -match '(?i)microsoft' }

$cands = foreach ($p in $pkgs) {
    if ($usedBy.ContainsKey($p.Inf.ToLower())) { continue }
    if (Is-MsInf $p.Provider) { continue }
    $stem = ($p.Inf -replace '\.inf$','').ToLower()
    $origInf = Join-Path $env:windir "INF\$($p.Inf)"
    $svcGuess = $null
    if (Test-Path -LiteralPath $origInf) {
        try { $src = Get-Content -LiteralPath $origInf -Raw -EA Stop
              if ($src -match '(?im)^\s*AddService\s*=\s*([A-Za-z0-9_\-]+)') { $svcGuess = $matches[1].ToLower() } } catch {}
    }
    if ($svcGuess -and $liveSvc.ContainsKey($svcGuess)) {
        [pscustomobject]@{ Inf=$p.Inf; Tier='LIVE-SERVICE'; Keep=$true; Provider=$p.Provider; Class=$p.Class; Version=$p.Version; Note="AddService=$svcGuess state=$($liveSvc[$svcGuess])" }
        continue
    }
    $tier = if ($bootClasses -contains $p.Class) { 'Tier1' } else { 'Tier2' }
    [pscustomobject]@{ Inf=$p.Inf; Tier=$tier; Keep=$false; Provider=$p.Provider; Class=$p.Class; Version=$p.Version; Note='' }
}

$t1 = @($cands | Where-Object Tier -eq 'Tier1')
$t2 = @($cands | Where-Object Tier -eq 'Tier2')
$live = @($cands | Where-Object Tier -eq 'LIVE-SERVICE')

"--- Tier1 (boot-relevant classes, no connected device): $($t1.Count) ---" | Tee-Object (Join-Path $OutDir 'report.txt')
$t1 | Format-Table Inf,Tier,Class,Provider,Version,Note -AutoSize | Out-String -Width 200 | Tee-Object (Join-Path $OutDir 'report.txt') -Append
"--- Tier2 (other unused third-party; optional hygiene): $($t2.Count) ---" | Tee-Object (Join-Path $OutDir 'report.txt') -Append
$t2 | Format-Table Inf,Tier,Class,Provider,Version -AutoSize | Out-String -Width 200 | Tee-Object (Join-Path $OutDir 'report.txt') -Append
"--- Excluded: live third-party driver services (product-managed - do NOT pnputil these) ---" | Tee-Object (Join-Path $OutDir 'report.txt') -Append
$live | Format-Table Inf,Class,Provider,Note -AutoSize | Out-String -Width 200 | Tee-Object (Join-Path $OutDir 'report.txt') -Append
@{ Tier1=$t1; Tier2=$t2; LiveService=$live; UsedByConnected=$usedBy.Keys } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutDir 'plan.json') -Encoding UTF8

# 4) Backup Tier1 (+Tier2 if including) store folders and INF sources
$toHandle = if ($IncludeTier2) { $t1 + $t2 } else { $t1 }
foreach ($c in $toHandle) {
    $p = $pkgs | Where-Object { $_.Inf -eq $c.Inf } | Select-Object -First 1
    if ($p.StorePath -and (Test-Path -LiteralPath $p.StorePath)) {
        try { Copy-Item -LiteralPath $p.StorePath -Destination (Join-Path $bk (Split-Path $p.StorePath -Leaf)) -Recurse -Force -EA Stop }
        catch { "backup FAILED for $($c.Inf): $($_.Exception.Message)" | Add-Content (Join-Path $OutDir 'notes.txt') }
    } else { "no Driver Store Path listed for $($c.Inf); backing up INF only" | Add-Content (Join-Path $OutDir 'notes.txt') }
    $infSrc = Join-Path $env:windir "INF\$($c.Inf)"
    if (Test-Path -LiteralPath $infSrc) { try { Copy-Item -LiteralPath $infSrc -Destination $bk -Force } catch {} }
}
"Backups: $bk  (restore later with: pnputil /add-driver <path>.inf /install)" | Tee-Object (Join-Path $OutDir 'report.txt') -Append

# 5) Commands / apply
$cmdFile = Join-Path $OutDir 'delete-commands.txt'
$toHandle | ForEach-Object { "pnputil /delete-driver $($_.Inf) /uninstall" } | Set-Content $cmdFile -Encoding ASCII
"--- Deletion commands written to $cmdFile ---"
if ($Apply) {
    foreach ($c in $toHandle) {
        if ($PSCmdlet.ShouldProcess("$($c.Inf) ($($c.Provider) - $($c.Class) - $($c.Version))", 'pnputil delete-driver /uninstall')) {
            & pnputil.exe /delete-driver $c.Inf /uninstall
            "exit=$LASTEXITCODE for $($c.Inf)" | Add-Content (Join-Path $OutDir 'delete-log.txt')
        }
    }
    Write-Host 'Deletions done. REBOOT, re-run inventory-storage-filters.ps1 + get-attempt-history.ps1, then make the upgrade attempt the single changed variable.' -ForegroundColor Yellow
} else {
    Write-Host "Plan ready. Review $OutDir\report.txt, then rerun with -Apply to remove Tier1 (confirmation per item; -IncludeTier2 to add Tier2)." -ForegroundColor Cyan
}
Write-Host 'MANDATORY: manual curation required before -Apply. The heuristic over-flags current-platform Extension/System INFs (e.g., same-chipset DMA/LPSS extensions bound via other package names) and phone/peripheral drivers you may want. Verify each Tier1 entry against your hardware history; keep anything belonging to the CURRENT motherboard family or live products. Excluded LIVE-SERVICE entries include orphan-but-registered storage drivers (iaStorA etc.) - handle those as a documented separate step after confirming the boot disk uses Microsoft stornvme/storahci.' -ForegroundColor Red
Write-Host 'Reminder: Bitdefender and other LIVE products are auto-excluded (LIVE-SERVICE). If a connected device was plugged in AFTER enumeration, rerun before applying.' -ForegroundColor Yellow
