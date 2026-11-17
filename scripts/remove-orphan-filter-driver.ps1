<#
.SYNOPSIS
Guarded removal of ORPHANED third-party filter/boot drivers left behind after a vendor uninstall.
.DESCRIPTION
Sanctioned exception to the "never touch filter values" rule, used ONLY when: (1) the owning product
is fully uninstalled, (2) the machine was rebooted, and (3) the inventory still shows the leftover.
For each named service it: exports the service key, finds every device-class UpperFilters/LowerFilters
and SafeConfiguration reference, saves original values to a restore script, removes ONLY its own entry
from those lists, then deletes the service (sc delete). Optionally moves (never deletes) the .sys file
to the backup folder. Order guarantees a class filter is never left dangling on a deleted service.
Run elevated; -WhatIf to preview. A restore .ps1 is written to the backup folder.
After success: REBOOT, then re-run inventory-storage-filters.ps1 to verify.
.EXAMPLE
.\remove-orphan-filter-driver.ps1 -ServiceName PxHlpa64,cbfs6 -WhatIf
.\remove-orphan-filter-driver.ps1 -ServiceName PxHlpa64,cbfs6
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [Parameter(Mandatory=$true)][string[]]$ServiceName,
    [string]$BackupRoot = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'OrphanFilterCleanup'),
    [switch]$QuarantineSysFiles
)
$ErrorActionPreference = 'Stop'
# powershell.exe -File passes 'A,B' as ONE token for [string[]]; normalize comma-joined names.
$ServiceName = $ServiceName | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run in an elevated PowerShell window. No changes were made.' }
if (Test-Path 'C:\$WINDOWS.~BT\Sources\Panther\setupact.log') {
    Write-Warning 'Active setup staging tree found. If this cleanup is for an upgrade retry: fine. Otherwise preserve evidence first.'
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bdir = Join-Path $BackupRoot "backup-$stamp"
New-Item -ItemType Directory -Path $bdir -Force | Out-Null
$classes = [ordered]@{
    'DiskDrive' = '{4d36e967-e325-11ce-bfc1-08002be10318}'; 'Volume' = '{71a27cdd-812a-11d0-bec7-08002be2092f}'
    'CDROM' = '{4d36e965-e325-11ce-bfc1-08002be10318}'; 'TapeDrive' = '{6bdd1fc1-8105-11d0-bec7-08002be2092f}'
    'Keyboard' = '{4d36e96b-e325-11ce-bfc1-08002be10318}'; 'Mouse' = '{4d36e96f-e325-11ce-bfc1-08002be10318}'
    'USB' = '{36fc9e60-c465-11cf-8056-444553540000}'; 'Net' = '{4d36e972-e325-11ce-bfc1-08002be10318}'
    'Bluetooth' = '{e0cbf06c-cd8b-4647-bb8a-263b43f0f974}'
}
$msNames = @('partmgr','volsnap','EhStorClass','fvevol','iorate','rdyboost','mouclass','kbdclass','FileInfo','UCPD','spaceport','storahci','stornvme')
$restoreLines = @("# Restore script generated $stamp. Run ELEVATED if you need to undo the filter edits, before deleting services again.")

foreach ($name in $ServiceName) {
    if ($name -in $msNames) { throw "'$name' is a Microsoft driver entry; refusing." }
    $svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
    if (-not (Test-Path -LiteralPath $svcKey)) { Write-Warning "No service key for $name (already removed?). Still scanning class filters for stale references."; }
    else {
        $img = (Get-ItemProperty -LiteralPath $svcKey).ImagePath
        $exported = Join-Path $bdir "service-$name.reg"
        if ($PSCmdlet.ShouldProcess($svcKey,'Export service key backup')) {
            & reg.exe export "HKLM\SYSTEM\CurrentControlSet\Services\$name" $exported /y | Out-Null
            Write-Host "Backed up service key $name -> $exported (ImagePath=$img)"
        }
    }

    # 1) Remove filter references FIRST (never leave a class filter pointing at a service we delete)
    foreach ($cls in $classes.Keys) {
        $guid = $classes[$cls]
        foreach ($scope in @("HKLM:\SYSTEM\CurrentControlSet\Control\Class\$guid", "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$guid\SafeConfiguration")) {
            if (-not (Test-Path -LiteralPath $scope)) { continue }
            foreach ($val in @('UpperFilters','LowerFilters')) {
                $cur = (Get-ItemProperty -LiteralPath $scope -Name $val -ErrorAction SilentlyContinue).$val
                if (@($cur).Count -eq 0) { continue }
                if ($cur -notcontains $name) { continue }
                $original = @($cur)
                $restoreLines += "Set-ItemProperty -LiteralPath '$scope' -Name $val -Value @('$($original -join "','")') -Type MultiString"
                $remaining = @($original | Where-Object { $_ -ne $name })
                if ($PSCmdlet.ShouldProcess("$scope\$val", "Remove only '$name' entry (was: $($original -join ';'))")) {
                    if ($remaining.Count -eq 0) { Remove-ItemProperty -LiteralPath $scope -Name $val -Force }
                    else { Set-ItemProperty -LiteralPath $scope -Name $val -Value $remaining -Type MultiString }
                    Write-Host "Removed '$name' from $cls/$val" -ForegroundColor Green
                    Write-Host ("  was: {0}  now: {1}" -f ($original -join ';'), ($remaining -join ';'))
                }
            }
        }
    }

    # 2) Then delete the service
    if (Test-Path -LiteralPath $svcKey) {
        if ($PSCmdlet.ShouldProcess("Service $name",'sc delete (registry service key removal; .reg backup taken)')) {
            & sc.exe delete $name | Out-Null
            Write-Host "Deleted service $name." -ForegroundColor Green
        }
    }

    # 3) Optionally quarantine the .sys file (MOVE to backup, never delete)
    if ($QuarantineSysFiles -and $img) {
        $path = ([string]$img).Trim('"')
        if ($path.StartsWith('\??\')) { $path = $path.Substring(4) }
        $path = $path -replace '^\\SystemRoot\\',"$env:windir\" -replace '^SystemRoot\\?',"$env:windir\" -replace '^%SystemRoot%\\?',"$env:windir\" -replace '^system32\\?',("$env:windir\System32\")
        if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $env:windir $path }
        if (Test-Path -LiteralPath $path) {
            if ($PSCmdlet.ShouldProcess($path, "Move to $bdir (never delete)")) {
                try {
                    Move-Item -LiteralPath $path -Destination (Join-Path $bdir ((Split-Path $path -Leaf) + ".orphan")) -Force -ErrorAction Stop
                    Write-Host "Quarantined file to $bdir." -ForegroundColor Green
                } catch {
                    try {
                        $smKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
                        $cur = @((Get-ItemProperty -LiteralPath $smKey -Name PendingFileRenameOperations -EA SilentlyContinue).PendingFileRenameOperations)
                        $cur += "\??\$path"; $cur += ''
                        Set-ItemProperty -LiteralPath $smKey -Name PendingFileRenameOperations -Value $cur -Type MultiString
                        Write-Host "File locked (driver still loaded); deletion scheduled at next boot: $path" -ForegroundColor Yellow
                    } catch { Write-Warning "Could not quarantine or schedule $path : leave file, service already removed." }
                }
            }
        }
    }
}

$restorePath = Join-Path $bdir 'restore-filters.ps1'
$restoreLines | Set-Content -LiteralPath $restorePath -Encoding UTF8
Write-Host "`nBackups + restore script: $bdir" -ForegroundColor Cyan
Write-Host 'NEXT STEPS: 1) REBOOT. 2) Re-run inventory-storage-filters.ps1 and confirm the names are gone from filters AND boot-driver list. 3) Only then consider the variable removed for the upgrade retry.' -ForegroundColor Yellow
Write-Host 'If a service you deleted turns out to be needed by another product (rare: cbfs/px-style SDK drivers), reinstall that product rather than restoring registry keys.' -ForegroundColor Yellow
