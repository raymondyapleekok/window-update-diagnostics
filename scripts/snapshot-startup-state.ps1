<#
.SYNOPSIS
  Snapshots and diffs Windows startup configuration (read-only): service StartMode/delayed-auto,
  MSConfig overrides, Run/RunOnce entries, StartupApproved markers, enabled startup items.

.DESCRIPTION
  Captures the startup/services baseline to JSON BEFORE the first diagnostic test-disable of a case.
  Re-running with -CompareFile diffs current state against that baseline and prints every change as
  "was: <baseline value>  now: <current value>". Restore targets are the recorded was: values, never
  defaults. Changes nothing; safe at any time.

.PARAMETER OutFile
  Path of the JSON baseline to write. Default: startup-baseline-<timestamp>.json in the current directory.

.PARAMETER CompareFile
  A previously saved baseline JSON to diff current state against (prints DRIFT lines and a total).

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\snapshot-startup-state.ps1 -OutFile C:\Cases\Case1\startup-baseline.json

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\snapshot-startup-state.ps1 -CompareFile C:\Cases\Case1\startup-baseline.json

.NOTES
  Non-elevated runs may miss machine-scope entries protected by policy; output states what was skipped.
  Service State is volatile — the compare focuses on start configuration.
#>
[CmdletBinding()]
param(
    [string]$OutFile,
    [string]$CompareFile
)

$ErrorActionPreference = 'Continue'

function Get-RegValues {
    param([string]$Path)
    $out = @()
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return ,$out }
    foreach ($n in $item.GetValueNames()) {
        if ($n -eq '') { continue }
        $kind = 'Unknown'
        try { $kind = [string]$item.GetValueKind($n) } catch { }
        $data = ''
        try {
            $opts = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            if ($kind -eq 'Binary') {
                $b = $item.GetValue($n, $null, $opts)
                if ($b) { $data = (($b | ForEach-Object { $_.ToString('x2') }) -join '') }
            } else {
                $data = [string]$item.GetValue($n, '', $opts)
            }
        } catch { $data = '<unreadable>' }
        $out += [pscustomobject]@{ Name = $n; Kind = $kind; Data = $data }
    }
    return ,$out
}

function Get-StartupState {
    $services = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            Name           = $_.Name
            DisplayName    = $_.DisplayName
            State          = $_.State
            StartMode      = $_.StartMode
            DelayedAutoStart = $_.DelayedAutoStart
            PathName       = $_.PathName
        } })
    $msBase = 'HKLM:\SOFTWARE\Microsoft\Shared Tools\MSConfig'
    $startupType = ''
    try { $startupType = [string](Get-Item -LiteralPath $msBase -ErrorAction Stop).GetValue('StartupType', '', $true) } catch { }
    $msServices = @()
    try {
        $svcKey = Get-Item -LiteralPath ($msBase + '\SERVICES') -ErrorAction Stop
        foreach ($n in $svcKey.GetValueNames()) {
            $msServices += [pscustomobject]@{ Name = $n; StartValue = ([string]$svcKey.GetValue($n, '', $true)) }
        }
    } catch { }
    $approved = @()
    foreach ($base in @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved')) {
        $b = Get-Item -LiteralPath $base -ErrorAction SilentlyContinue
        if ($null -eq $b) { continue }
        foreach ($sub in $b.GetSubKeyNames()) {
            foreach ($v in (Get-RegValues ($base + '\' + $sub))) {
                $approved += [pscustomobject]@{ Hive = ($base + '\' + $sub); Name = $v.Name; Kind = $v.Kind; Data = $v.Data }
            }
        }
    }
    $run = @()
    foreach ($p in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce')) {
        foreach ($v in (Get-RegValues $p)) {
            $run += [pscustomobject]@{ Hive = $p; Name = $v.Name; Kind = $v.Kind; Data = $v.Data }
        }
    }
    $enabled = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Sort-Object Name, Location | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Command = $_.Command; Location = $_.Location; User = $_.User } })
    [pscustomobject]@{
        CollectedAt             = (Get-Date).ToString('o')
        Services                = $services
        MSConfigStartupType     = $startupType
        MSConfigServiceOverrides = $msServices
        StartupApproved         = $approved
        RunEntries              = $run
        EnabledStartup          = $enabled
    }
}

function Compare-Section {
    param([string]$Label, [array]$Old, [array]$New, [string[]]$KeyProps, [string[]]$ValueProps)
    $oldMap = @{}
    foreach ($r in $Old) {
        $k = ($KeyProps | ForEach-Object { [string]$r.$_ }) -join '|'
        if ($k) { $oldMap[$k] = $r }
    }
    $newMap = @{}
    foreach ($r in $New) {
        $k = ($KeyProps | ForEach-Object { [string]$r.$_ }) -join '|'
        if ($k) { $newMap[$k] = $r }
    }
    foreach ($k in ($oldMap.Keys | Sort-Object)) {
        if (-not $newMap.ContainsKey($k)) {
            $oldVal = ($ValueProps | ForEach-Object { [string]$oldMap[$k].$_ }) -join ' | '
            Write-Output ("DRIFT [{0}] REMOVED: {1}  (was: {2})" -f $Label, $k, $oldVal)
        }
    }
    foreach ($k in ($newMap.Keys | Sort-Object)) {
        if (-not $oldMap.ContainsKey($k)) {
            $newVal = ($ValueProps | ForEach-Object { [string]$newMap[$k].$_ }) -join ' | '
            Write-Output ("DRIFT [{0}] ADDED: {1}  (now: {2})" -f $Label, $k, $newVal)
        }
    }
    foreach ($k in ($oldMap.Keys | Sort-Object)) {
        if ($newMap.ContainsKey($k)) {
            $a = ($ValueProps | ForEach-Object { [string]$oldMap[$k].$_ }) -join ' | '
            $b = ($ValueProps | ForEach-Object { [string]$newMap[$k].$_ }) -join ' | '
            if ($a -ne $b) {
                Write-Output ("DRIFT [{0}] CHANGED: {1}  (was: {2})  (now: {3})" -f $Label, $k, $a, $b)
            }
        }
    }
}

function Get-JsonArray { param($Object, [string]$Prop)
    $v = $Object.$Prop
    if ($null -eq $v) { return @() }
    return @($v)
}

if ($CompareFile) {
    if (-not (Test-Path -LiteralPath $CompareFile)) { Write-Error "Baseline not found: $CompareFile"; exit 1 }
    $baseline = ConvertFrom-Json ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $CompareFile).Path))
    $current = Get-StartupState
    $total = 0
    Write-Output ("Baseline: {0}  (captured {1})" -f $CompareFile, $baseline.CollectedAt)
    Write-Output ("Current:  captured {0}" -f $current.CollectedAt)
    $out = Compare-Section 'Services' @(Get-JsonArray $baseline 'Services') @($current.Services) @('Name') @('StartMode','DelayedAutoStart','PathName')
    $out; $total += @($out).Count
    $out = Compare-Section 'MSConfig-Services' @(Get-JsonArray $baseline 'MSConfigServiceOverrides') @($current.MSConfigServiceOverrides) @('Name') @('StartValue')
    $out; $total += @($out).Count
    if (([string]$baseline.MSConfigStartupType) -ne ([string]$current.MSConfigStartupType)) {
        Write-Output ("DRIFT [MSConfig] CHANGED: StartupType  (was: {0})  (now: {1})" -f $baseline.MSConfigStartupType, $current.MSConfigStartupType); $total++
    }
    $out = Compare-Section 'StartupApproved' @(Get-JsonArray $baseline 'StartupApproved') @($current.StartupApproved) @('Hive','Name') @('Data')
    $out; $total += @($out).Count
    $out = Compare-Section 'Run' @(Get-JsonArray $baseline 'RunEntries') @($current.RunEntries) @('Hive','Name') @('Kind','Data')
    $out; $total += @($out).Count
    $out = Compare-Section 'EnabledStartup' @(Get-JsonArray $baseline 'EnabledStartup') @($current.EnabledStartup) @('Name','Location') @('Command')
    $out; $total += @($out).Count
    Write-Output ("Total drift items vs baseline: {0}" -f $total)
    Write-Output 'Note: compare diffs start configuration only (service State is volatile). Restore to recorded baseline values, never to defaults.'
    exit 0
}

$state = Get-StartupState
if (-not $OutFile) { $OutFile = "startup-baseline-$(Get-Date -Format 'yyyyMMdd-HHmmss').json" }
$json = $state | ConvertTo-Json -Depth 6
$target = $OutFile
if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path (Get-Location).Path $target }
$target = [System.IO.Path]::GetFullPath($target)
[System.IO.File]::WriteAllText($target, $json, (New-Object System.Text.UTF8Encoding($true)))
Write-Output ("Baseline written: {0}" -f $target)
Write-Output ("  Services: {0} | Run values: {1} | StartupApproved markers: {2} | Enabled startup (CIM): {3} | MSConfig overrides: {4}" -f `
    $state.Services.Count, $state.RunEntries.Count, $state.StartupApproved.Count, $state.EnabledStartup.Count, $state.MSConfigServiceOverrides.Count)
Write-Output 'Read-only. Use -CompareFile to diff current state against this baseline later (restore targets are the recorded was: values).'

