<#
.SYNOPSIS
Pattern/marker scan of Windows Update and Setup logs; produces leads, not root causes.
.DESCRIPTION
Scans files or directories for setup failure markers, error code families, migration abort
strings, filter-driver and rollback indicators. Reports per-file counts, first/last occurrence
timestamps where parseable, and a deduplicated error-code frequency table. Matches are leads:
correlate timestamps, phases and elevation gaps before concluding. Large logs: prefer scanning
the preserved bundle, not live locked files.
.EXAMPLE
.\analyse-update-logs.ps1 -Path C:\SetupDiag\DSH-20261109
.\analyse-update-logs.ps1 -Path .\setuperr.log -PatternSet Setup -ContextLines 3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string[]]$Path,
    [ValidateSet('All','Setup','Servicing')][string]$PatternSet = 'All',
    [int]$ContextLines = 2,
    [int]$MaxMatchesPerFile = 150,
    [string]$OutputFile
)
$ErrorActionPreference = 'Stop'

$setupPatterns = @(
  @{P='0xC1900101'; D='generic rollback'},
  @{P='0xC19002\d\d'; D='compat/requirement block'},
  @{P='0x8[0-9A-Fa-f]{7}\s*[-+]\s*0x2?[0-9A-Fa-f]{5}'; D='setup result+extend code'},
  @{P='gle=0x[0-9A-Fa-f]{4,8}'; D='Win32 last error'},
  @{P='Shell application requested abort'; D='migration abort request'},
  @{P='Abandoning apply due to error for object'; D='setup apply abandonment'},
  @{P='MIG Plugin'; D='migration plugin error'},
  @{P='Unable to determine inbox status of driver'; D='driver migration failure'},
  @{P='Failed to remove INF'; D='INF removal failure'},
  @{P='oem\d+\.inf'; D='third-party driver package reference'},
  @{P='BlockMigration'; D='driver marked not migrating'},
  @{P='Rollback|rollback'; D='rollback activity'},
  @{P='bugcheck|Bugcheck|BugCheck'; D='bugcheck mention'},
  @{P='Crash dump disabled'; D='target-OS crash capture off'},
  @{P='No crash detected'; D='rollback log found no dump signature'},
  @{P='boot status|BOOTSTAT|BootStatistics'; D='boot-statistics record (NOT a stop code)'},
  @{P='LastBootSucceeded\s*=\s*0'; D='new OS marked boot failure'},
  @{P='event\s*(code\s*)?84'; D='BOOTSTAT event number - not a driver or stop code'},
  @{P='0x80070005'; D='access denied'},
  @{P='SystemRoot\\\\SystemRoot'; D='doubled SystemRoot path (filter migration anomaly clue)'},
  @{P='WinSetupMon'; D='upgrade monitoring driver'},
  @{P='EPMVolFl|EUDCPEPM|EUEDKEPM|PxHlpa|cbfs|AISeR|gdrv|I2cHkBurn|MsIo'; D='third-party driver name seen'},
  @{P='0xC0000034'; D='STATUS_OBJECT_NAME_NOT_FOUND'},
  @{P='FATAL|Fatal Error'; D='fatal line'}
)
$servicingPatterns = @(
  @{P='0x800f081f|0x800f0906|CBS_E_SOURCE_MISSING'; D='DISM repair source missing'},
  @{P='0x80073712|CBS_E_STORE_CORRUPTION|store is corrupted'; D='component store corruption'},
  @{P='0x800736CC|hash mismatch|hash does not match'; D='component file hash mismatch'},
  @{P='0x8024[0-9A-Fa-f]{6}'; D='Windows Update agent code'},
  @{P='0x80070422|0x80070426'; D='update service state error'},
  @{P='SoftwareDistribution|catroot2'; D='cache references'},
  @{P='Failed to download|download failed'; D='download failure'},
  @{P='Installation failure|failed to install'; D='install failure'},
  @{P='pending\.xml|PackagesPending|RebootPending'; D='servicing pending state'},
  @{P='CORRUPT|corrupt'; D='corruption wording'}
)
$patterns = switch ($PatternSet) {
  'Setup' { $setupPatterns }
  'Servicing' { $servicingPatterns }
  default { $setupPatterns + $servicingPatterns }
}

$allHits = @()
$report = @()
foreach ($p in $Path) {
    $files = @()
    if (Test-Path -LiteralPath $p -PathType Leaf) { $files = @(Get-Item -LiteralPath $p) }
    elseif (Test-Path -LiteralPath $p -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $p -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.log','.txt','.xml' -and $_.Length -lt 4GB })
    } else { Write-Warning "Path not found: $p"; continue }

    foreach ($file in $files) {
        $report += "`n===== $($file.FullName) ($([math]::Round($file.Length/1KB,0)) KB) ====="
        $count = 0; $codeHits = @{}
        foreach ($pt in $patterns) {
            $m = Select-String -LiteralPath $file.FullName -Pattern $pt.P -AllMatches -ErrorAction SilentlyContinue
            foreach ($line in @($m)) {
                if (-not $line) { continue }
                if ($count -lt $MaxMatchesPerFile) {
                    $report += ('  L{0}: {1} [{2}] {3}' -f $line.LineNumber, $pt.D, $pt.P, $line.Line.Trim())
                    $count++
                }
                $key = "$($pt.D)"
                if (-not $codeHits.ContainsKey($key)) { $codeHits[$key] = 0 }
                $codeHits[$key]++
                $allHits += [pscustomobject]@{ File=$file.Name; Meaning=$pt.D; Line=$line.LineNumber }
            }
        }
        if ($count -eq 0) { $report += '  (no markers matched)' }
        elseif ($count -ge $MaxMatchesPerFile) { $report += "  (output capped at $MaxMatchesPerFile)" }
        if ($codeHits.Count -gt 0) {
            $report += '  -- frequency by marker --'
            foreach ($k in ($codeHits.GetEnumerator() | Sort-Object Value -Descending)) { $report += ("    {0,5}  {1}" -f $k.Value, $k.Key) }
        }
    }
}

$text = $report -join "`r`n"
Write-Host $text
$remind = "`r`nREMINDER: frequency != importance. Find the LAST occurrence of the result code, read UPWARD for the first failure at the failing phase boundary; decode gle=; confirm the failing boot's timestamps. BOOTSTAT numbers are internal records, not stop codes or file names. A marker in the restored OS does not identify the target-OS failure cause.`r`n"
Write-Host $remind -ForegroundColor Yellow
if ($OutputFile) { Set-Content -LiteralPath $OutputFile -Value ($text + $remind) -Encoding UTF8; Write-Host "Saved: $OutputFile" }
