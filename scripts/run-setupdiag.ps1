<#
.SYNOPSIS
Locate and run Microsoft SetupDiag against live or collected Windows Setup logs.
.DESCRIPTION
Finds SetupDiag.exe in (order): -Path, this script's folder, C:\SetupDiag, the Setup-staged copy
at %SystemDrive%\$WINDOWS.~BT\Sources, or PATH. Runs it online or offline (-LogsPath), with optional
/Format, /Scenario Recovery, /Verbose, /NoTel, and prints where results also appear:
%windir%\Logs\SetupDiag\ and HKLM\SYSTEM\Setup\MoSetup\Volatile\SetupDiag (manual online runs).
Never downloads anything: if missing, it tells you to obtain SetupDiag from Microsoft Learn
(https://learn.microsoft.com/windows/deployment/upgrade/setupdiag). Run elevated when analyzing
live rollback data. This script only changes the output files you point it at.
.EXAMPLE
.\run-setupdiag.ps1 -Output C:\SetupDiag\Results.log
.\run-setupdiag.ps1 -LogsPath C:\SetupDiag\DSH-collected\Panther -Output C:\SetupDiag\Offline.log
.\run-setupdiag.ps1 -Scenario Recovery -Format xml
#>
[CmdletBinding()]
param(
    [string]$Exe,
    [string]$Output = (Join-Path (Get-Location).Path ("SetupDiagResults-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [string]$LogsPath,
    [ValidateSet('text','xml','json')][string]$Format = 'text',
    [ValidateSet('None','Recovery')][string]$Scenario = 'None',
    [ValidateSet('Default','True','False')][string]$ZipLogs = 'False',
    [switch]$Verbose2,
    [switch]$NoTel,
    [switch]$DownloadLatest
)
$ErrorActionPreference = 'Stop'
$officialUrl = 'https://go.microsoft.com/fwlink/?linkid=870142'  # Microsoft Download Center "latest SetupDiag" (per Microsoft Learn)
if ($DownloadLatest) {
    $dest = Join-Path $env:SystemDrive 'SetupDiag'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $target = Join-Path $dest 'SetupDiag.exe'
    Write-Host "Downloading latest SetupDiag from Microsoft official link to $target" -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    $tmp = "$target.new"
    Invoke-WebRequest -Uri $officialUrl -OutFile $tmp -UseBasicParsing -MaximumRedirection 5 -ErrorAction Stop
    $sig = Get-AuthenticodeSignature -FilePath $tmp
    "Signature: $($sig.Status) signer=$($sig.SignerCertificate.Subject)"
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft') { Remove-Item $tmp -Force; throw 'Downloaded file is not Microsoft-signed/valid; refusing to replace existing SetupDiag.' }
    if (Test-Path $target) { Move-Item $target "$target.old-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force }
    Move-Item $tmp $target -Force
    Write-Host 'Updated SetupDiag installed (previous copy kept as .old-*).' -ForegroundColor Green
}
$candidates = @()
if ($Exe) { $candidates += $Exe }
$candidates += @(
    (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'SetupDiag.exe'),
    'C:\SetupDiag\SetupDiag.exe',
    (Join-Path $env:SystemDrive '$WINDOWS.~BT\Sources\SetupDiag.exe'),
    (Join-Path $env:TEMP 'SetupDiag\SetupDiag.exe')
)
$cmd = Get-Command SetupDiag.exe -ErrorAction SilentlyContinue
if ($cmd) { $candidates += $cmd.Source }
$found = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $found) {
    Write-Host "SetupDiag.exe not found in: $($candidates -join '; ')" -ForegroundColor Yellow
    Write-Host "Obtain the current Microsoft-signed SetupDiag: official download $officialUrl (or re-run with -DownloadLatest)."
    Write-Host "Docs: https://learn.microsoft.com/windows/deployment/upgrade/setupdiag. Save under C:\SetupDiag or beside this script. Do not use third-party mirrors."
    exit 2
}
Write-Host "Using SetupDiag: $found" -ForegroundColor Cyan
$foundDir = Split-Path -Parent $found
$outDir = Split-Path -Parent $Output
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$diagArgs = @()
$diagArgs += "/Output:$Output"
if ($LogsPath) { $diagArgs += "/LogsPath:$LogsPath" }
if ($Format -ne 'text') { $diagArgs += "/Format:$Format" }
if ($Scenario -ne 'None') { $diagArgs += "/Scenario:$Scenario" }
if ($ZipLogs -ne 'Default') { $diagArgs += "/ZipLogs:$ZipLogs" }
if ($Verbose2) { $diagArgs += '/Verbose' }
if ($NoTel) { $diagArgs += '/NoTel' }

Write-Host "Arguments: $($diagArgs -join ' ')" -ForegroundColor Cyan
Write-Host 'Running (may take minutes while large setup logs are parsed)...' -ForegroundColor Cyan
$cmdline = '"' + $found + '" ' + ($diagArgs -join ' ')
cmd.exe /c $cmdline 2>&1 | ForEach-Object { Write-Host $_ }
$code = $LASTEXITCODE
Write-Host "SetupDiag exit code: $code" -ForegroundColor Cyan
$deadline = (Get-Date).AddSeconds(120)
while (-not (Test-Path -LiteralPath $Output) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
if (-not (Test-Path -LiteralPath $Output)) {
    Write-Warning "No results file yet. SetupDiag may need elevation for live analysis: open an elevated PowerShell window and run: & '$found' $($diagArgs -join ' ')"
}
if (Test-Path -LiteralPath $Output) { Write-Host "Results file: $Output" -ForegroundColor Green }
if (-not $LogsPath) {
    Write-Host "Also check: $env:windir\Logs\SetupDiag\ (SetupDiagResults.xml from Setup's own run) and HKLM\SYSTEM\Setup\MoSetup\Volatile\SetupDiag" -ForegroundColor Yellow
}
if (Test-Path -LiteralPath $Output) {
    Write-Host "`n--- Head of results ---" -ForegroundColor Cyan
    Get-Content -LiteralPath $Output -TotalCount 30
    $keyLines = Select-String -LiteralPath $Output -Pattern 'Matching Profile|Error:|Last Phase|Last Operation|Refer to' | Select-Object -First 12
    if ($keyLines) { Write-Host "`n--- Key lines ---" -ForegroundColor Cyan; $keyLines | ForEach-Object { $_.Line } }
}
Write-Host "`nInterpretation: a matched rule is a LEAD. Correlate with Panther/Rollback logs and references/error-codes.md before any repair. Preserve logs before cleanup." -ForegroundColor Yellow


