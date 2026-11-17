<#
.SYNOPSIS
Read-only inventory of storage/class filter drivers and third-party boot-start kernel drivers.
.DESCRIPTION
Lists UpperFilters/LowerFilters on key device classes (DiskDrive, Volume, CDROM, TapeDrive,
Keyboard, Mouse) and SafeConfiguration entries, resolves each filter to its service (start type,
ImagePath, file presence, publisher, signature), and separately lists non-Microsoft boot/system
start kernel drivers. Flags third-party entries as differential-test CANDIDATES only - presence is
not proof of causation. Changes nothing; safe to run any time. Elevation gives fuller signature data.
Key Microsoft filter entries that must NEVER be removed: partmgr, volsnap, EhStorClass, fvevol,
iorate, rdyboost (and dump* minidrivers).
.EXAMPLE
.\inventory-storage-filters.ps1
#>
[CmdletBinding()]
param(
    [switch]$AsJson,
    [switch]$IncludeSignedMicrosoftBootDrivers
)

$ErrorActionPreference = 'Continue'
$classes = [ordered]@{
    'DiskDrive'   = '{4d36e967-e325-11ce-bfc1-08002be10318}'
    'Volume'      = '{71a27cdd-812a-11d0-bec7-08002be2092f}'
    'CDROM'       = '{4d36e965-e325-11ce-bfc1-08002be10318}'
    'TapeDrive'   = '{6bdd1fc1-8105-11d0-bec7-08002be2092f}'
    'Keyboard'    = '{4d36e96b-e325-11ce-bfc1-08002be10318}'
    'Mouse'       = '{4d36e96f-e325-11ce-bfc1-08002be10318}'
    'USB'         = '{36fc9e60-c465-11cf-8056-444553540000}'
    'Net'         = '{4d36e972-e325-11ce-bfc1-08002be10318}'
    'Bluetooth'   = '{e0cbf06c-cd8b-4647-bb8a-263b43f0f974}'
}
$msFilters = @('partmgr','volsnap','EhStorClass','fvevol','iorate','rdyboost','FileInfo','UCPD','dumpata','dumpstor','dumpsw','spaceport','storahci','stornvme','mouclass','kbdclass')

function Get-FilterInfo([string]$ServiceName) {
    $svc = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -ErrorAction SilentlyContinue
    if (-not $svc) {
        return [pscustomobject]@{ Name=$ServiceName; Present=$false; Start=$null; ImagePath=$null; Publisher='service key MISSING'; Signed='-' }
    }
    $img = $svc.ImagePath
    $path = $null
    if ($img) {
        $path = $img -replace '^\\\?\\','' -replace '^\\SystemRoot\\',("$env:windir\") -replace '^SystemRoot\\?',"$env:windir\" -replace '^%SystemRoot%\\?',"$env:windir\" -replace '^system32\\?',("$env:windir\System32\") -replace '^"','' -replace '"$',''
        if ($path -notmatch '^[A-Za-z]:\\') { $path = Join-Path $env:windir ($path -replace '^\\','') }
    }
    $pub = ''; $signed = '-'
    if ($path -and (Test-Path -LiteralPath $path)) {
        try { $vi = (Get-Item -LiteralPath $path).VersionInfo; $pub = $vi.CompanyName } catch {}
        try { $sig = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction SilentlyContinue; $signed = "$($sig.Status)" } catch { $signed = 'unchecked' }
    } elseif ($path) { $pub = 'FILE MISSING' }
    [pscustomobject]@{
        Name=$ServiceName; Present=$true; Start=$svc.Start
        ImagePath=$img; Publisher=if($pub){$pub}else{'(unknown)'}; Signed=$signed
    }
}

$rows = @()
foreach ($cls in $classes.Keys) {
    $clsPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$($classes[$cls])"
    if (-not (Test-Path -LiteralPath $clsPath)) { continue }
    foreach ($val in @('UpperFilters','LowerFilters')) {
        $list = (Get-ItemProperty -LiteralPath $clsPath -Name $val -ErrorAction SilentlyContinue).$val
        foreach ($f in @($list)) {
            if (-not $f) { continue }
            $info = Get-FilterInfo $f
            $rows += [pscustomobject]@{ Class=$cls; Role=$val; Filter=$f; Start=$info.Start; Publisher=$info.Publisher; Signed=$info.Signed; ServicePresent=$info.Present }
        }
    }
    $safe = (Get-ItemProperty -LiteralPath "$clsPath\SafeConfiguration" -ErrorAction SilentlyContinue)
    foreach ($val in @('UpperFilters','LowerFilters')) {
        foreach ($f in @($safe.$val)) { if ($f) { $rows += [pscustomobject]@{ Class="$cls (SafeConfiguration)"; Role=$val; Filter=$f; Start='n/a'; Publisher='(safe-mode list)'; Signed='-'; ServicePresent=$true } } }
    }
}

Write-Host '=== Class filter drivers (Upper/Lower) ===' -ForegroundColor Cyan
$rows | Format-Table -AutoSize | Out-String -Width 220 | ForEach-Object { Write-Host $_ }

$bootDrivers = Get-CimInstance Win32_SystemDriver | Where-Object { $_.StartMode -in 'Boot','System' } | ForEach-Object {
    $path = $_.PathName -replace '^\\\.\.\\','' -replace '^SystemRoot',$env:windir
    $pub = ''
    if ($path -and (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) { try { $pub = (Get-Item -LiteralPath $path).VersionInfo.CompanyName } catch {} }
    $isMs = ($pub -match 'Microsoft')
    if ($isMs -and -not $IncludeSignedMicrosoftBootDrivers) { return }
    if (-not $pub) { $pub = '(unknown)' }
    [pscustomobject]@{ Name=$_.Name; State=$_.State; StartMode=$_.StartMode; Publisher=$pub; Path=$path }
}
Write-Host '=== Boot/System start kernel drivers with non-Microsoft (or unknown) publisher ===' -ForegroundColor Cyan
Write-Host '(Windows-signed drivers can still be third-party in DriverStore; use pnputil /enum-drivers and vendor uninstallers to remove. Never delete .sys files or class filter values.)' -ForegroundColor Yellow
$bootDrivers | Sort-Object Publisher,Name | Format-Table -AutoSize | Out-String -Width 240 | ForEach-Object { Write-Host $_ }

Write-Host '=== Filter manager (requires elevation; empty otherwise) ===' -ForegroundColor Cyan
& fltmc.exe filters 2>&1 | ForEach-Object { Write-Host "$_" }

Write-Host '=== Assessment ===' -ForegroundColor Cyan
$thirdPartyFilters = $rows | Where-Object { $_.Filter -notin $msFilters }
$flaggedBoot = $bootDrivers | Where-Object { $_.Publisher -notmatch 'Microsoft' }
if (@($thirdPartyFilters).Count -eq 0 -and @($flaggedBoot).Count -eq 0) {
    Write-Host 'No third-party class filters and no unknown-publisher boot drivers detected at this elevation level.' -ForegroundColor Green
} else {
    Write-Host 'CANDIDATES for one-variable-at-a-time differential testing (uninstall via owning product only):' -ForegroundColor Yellow
    $thirdPartyFilters | ForEach-Object { Write-Host ("  filter: {0} [{1} {2}] publisher={3} signed={4}" -f $_.Filter,$_.Class,$_.Role,$_.Publisher,$_.Signed) }
    $flaggedBoot | ForEach-Object { Write-Host ("  boot-driver: {0} publisher={1} ({2})" -f $_.Name,$_.Publisher,$_.StartMode) }
    Write-Host 'Check missing-service filter references FIRST (ServicePresent=False): a class filter pointing at a missing service can make Windows unbootable - restore via vendor cleanup, not by hand-editing hives.' -ForegroundColor Red
}
if ($AsJson) { [pscustomobject]@{ ClassFilters=$rows; ThirdPartyBootDrivers=$bootDrivers } | ConvertTo-Json -Depth 5 }
