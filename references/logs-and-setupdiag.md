# Logs, event channels, and SetupDiag

## Windows Update (quality updates, downloads)

- **Text log from ETL**: `Get-WindowsUpdateLog -LogPath <out\WindowsUpdate.log>` merges the agent's ETL files. Needs symbol download sometimes; failure to convert is not proof WU is broken.
- **Event channel** `Microsoft-Windows-WindowsUpdateClient/Operational` and the `System` log (same provider): read the session as a timeline. Common IDs (message text is authoritative; numbering can shift across releases):
  - `19` installation success, `20` installation failure (includes `errorCode` HRESULT and `updateGuid`)
  - `21`/`25` restart-required / scan(detection) failure, `26` scan completed (updates found)
  - `31` download failure, `43` installation started, `44` download started
- Export before sharing: `wevtutil epl Microsoft-Windows-WindowsUpdateClient/Operational out.evtx /ow:true` (System/Setup channels and most exports require elevation).
- USO orchestrator: `C:\ProgramData\USOShared\Logs\*.etl` (scan/download/install sequencing, reboot prompts).
- `C:\Windows\Logs\MoSetup\BlueBox.log`: Installation Assistant / feature-update to setup handoff, WSUS downlevel failures, `0xC1900107`.

## Windows Setup / feature upgrade log map (Microsoft-documented)

| File | Phase: location | Use |
|---|---|---|
| `setupact.log` | Downlevel: `C:\$WINDOWS.~BT\Sources\Panther` | All downlevel failures; starting point for any rollback investigation |
| `setupact.log` | OOBE: `...\Sources\Panther\UnattendGC` | OOBE-phase failures (`0x4001C/D/E/F`) |
| `setupact.log` | Rollback: `C:\$WINDOWS.~BT\Sources\Rollback` | Generic rollbacks `0xC1900101` |
| `setupact.log` | Post-upgrade: `C:\Windows\Panther` | Post-upgrade issues |
| `setuperr.log` | Same dirs | Errors only; search from bottom upward |
| `setupapi.dev.log` | `%windir%\INF` and `...\Sources\Rollback\setupapi` | Device-install failures (`0x30018`) |
| `miglog.xml` | `C:\Windows\Panther` | Post-upgrade migration issues |
| `setupmem.dmp`, saved `*.evtx` (e.g. `NewOs...`), `bootstat.dat` | `...\Sources\Rollback` (+ saved new-OS data) | Bugcheck/boot evidence for the failed boot |

`$WINDOWS.~BT` is deleted by cleanup/retries — preserve it first.

## Parsing procedure for setup logs

1. Determine result + extend code (from UI, `setuperr.log`, or SetupDiag).
2. Pick the log by extend-code phase (see table).
3. Search the result code from the END upward; read several lines up from that last occurrence.
4. Also search: `Shell application requested abort`, `Abandoning apply due to error for object`, `Error SP`, `MIG Plugin`, `oemNNN.inf`, `.sys`, `gle=0x` (decode the Win32 code), `Fatal`.
5. Note exact timestamps, then cross-search other logs (CBS, setupapi, events) at those times.
6. Useful components: `SP` (setup platform), `MIG` (migration), `CONX` (compatibility), `PANTHR`, `MOUPG`, `IBSLIB`, `DISM`, `CBS`.

## SetupDiag

Microsoft's rule-based analyzer for setup/upgrade and reset/recovery failures. Microsoft recommends the LATEST version for manual runs — official download: `https://go.microsoft.com/fwlink/?linkid=870142` (current release as of 2026-11: v1.7.0.0; page updated 2026-03). Requirements: .NET Framework 4.7.2+, elevated prompt recommended. Record the tool version alongside each analysis — rule sets grow between releases.

- Automatic run by Setup uses: `/ZipLogs:False /Format:xml /Output:%windir%\logs\SetupDiag\SetupDiagResults.xml /RegPath:HKEY_LOCAL_MACHINE\SYSTEM\Setup\SetupDiag\Results`. Check that XML and registry key even when no manual output exists.
- Manual run writes `SetupDiagResults.log` beside the exe and (online mode) registry `HKLM\SYSTEM\Setup\MoSetup\Volatile\SetupDiag`.

| Parameter | Meaning |
|---|---|
| `/?` | Help |
| `/Output:<path>` | Result file; quote paths with spaces |
| `/LogsPath:<dir>` | Offline mode: parse logs from a folder tree (recursive). `/Mode:Offline` is deprecated |
| `/ZipLogs:True|False` | Zip results + parsed logs (default true for manual runs) |
| `/Format:xml|json` | Structured output (default text) |
| `/Scenario:Recovery` | Analyze reset/recovery (PBR) logs instead of upgrade logs |
| `/Scenario:Debug` | Debug setup memory dumps when Windows Debugging Tools are installed (offline, dump in `/LogsPath`) |
| `/Verbose` | Extra processing detail |
| `/NoTel` | Suppress telemetry |
| `/RegPath:<HKLM|HKCU\...>` | Custom results registry path |
| `/AddReg` | Offline mode: also write results to local registry |

Typical commands:

```text
SetupDiag.exe /Output:C:\SetupDiag\Results.log
SetupDiag.exe /Output:C:\SetupDiag\Results.xml /Format:xml
SetupDiag.exe /Output:C:\SetupDiag\Offline.log /LogsPath:D:\Collected\Panther
SetupDiag.exe /Scenario:Recovery /Format:xml
```

For offline analysis copy the WHOLE relevant tree (`Panther`, `Rollback`, or `Windows\Panther\NewOS`), not single files — some rules need context.

### Reading a SetupDiag result

- `Matching Profile found:` line = matched rule (e.g. `FindRollbackFailure - <guid>`). `FindRollbackFailure` is the GENERIC fallback: no specific rule matched — it localizes phase/operation but names no culprit. Specific rules worth knowing: `UnknownDriverMigrationFailure` (bad driver package; removal + reboot + retry), `DriverMigrationFailure`, `WinSetupBootFilterFailure` (kernel-mode file ops failure — filter-driver family), `HardblockDeviceOrDriver`, `GatedCompatBlock` (safeguard hold), `DeviceInstallHang`, `DebugSetupMemoryDump` (dump debugging), `FindSPFatalError` (downlevel fatal, e.g. `Error converting install time ... gle=0x57`).
- When SetupDiag reports MULTIPLE failures, Microsoft: the LAST failure in the log is typically the fatal one, not the first.
- System Information block: host vs target build strings, edition, language, firmware type, BIOS date/version, `RegisteredAV`, `FilterDrivers`, `UpgradeStartTime/EndTime`, `RollbackStartTime/EndTime`, `CV` correlation vector (useful for telemetry tickets).
- `Last Phase` / `Last Operation` and the Setup Operation Info list (each operation's start/end/success) pinpoint the phase. An operation named in `Last Operation` (e.g. "Ensure suspended services are stopped") is NOT automatically the culprit — an earlier instance of the same operation may have completed successfully.
- `ClientId Media360` in operation args = upgrade launched via media/Media Creation Tool path.
- A result names rules and codes, not causes: validate against Panther/Rollback evidence before acting.

## Reconstructing MANY past attempts (ledger sources and their limits)

- `C:\$WINDOWS.~BT` and `C:\Windows\Panther\NewOs` survive only for the **most recent** attempt (until cleanup). Preserve them now if the case is active.
- Persistent per-attempt records: System log source `Microsoft-Windows-WindowsUpdateClient` events `43` install-start, `216/218` commit start/ok, `19/20` success/failure-with-code, `25` scan failure — query with `Get-WinEvent` over months (channel rolls; export early). Titles ("Windows 11, version 24H2/25H2/26H2") identify what was attempted.
- `C:\Windows\Logs\MoSetup\BlueBox.log` (Installation Assistant/feature-update handoff) rolls but often covers weeks; grep attempt starts, result codes.
- `HKLM\SYSTEM\Setup\MoSetup\Volatile\SetupDiag` = last SetupDiag analysis only; `%windir%\Logs\SetupDiag\SetupDiagResults.xml` = last Setup-triggered analysis.
- OS install age: `Windows NT\CurrentVersion\InstallDate`, and `C:\Windows\Panther` oldest file dates (also reveals prior in-place upgrades, e.g. Win10→Win11 lineage).
- Cross-reference uninstall/install dates of suspects (`C:\Windows\System32\drivers\*.sys` CreationTime; uninstall-registry `InstallDate`) against attempt timestamps before crediting/blaming any removal test.

## Interpretation traps (confirmed in real cases)

- **BOOTSTAT**: `...\Rollback\setupact.log` boot-status summaries ("NewOS: error event 84, LastBootSucceeded=0") are internal boot-statistics records. Event number ≠ bugcheck, ≠ Event Viewer ID, ≠ system error 84, and does not name a driver or file. Structural/offset comparisons are evidence, not decoding.
- **Missing dump**: `No crash detected` in the rollback log plus no `setupmem.dmp` cannot exclude a bugcheck. Check the saved new-OS `Kernel-Dump` event for "Crash dump disabled". Setup reads current-OS dump settings and prepares pagefiles, yet target-OS capture can still be off; the saved NewOS BCD may set `restartonfailure`/`hypervisorlaunchtype`. Set Automatic dump + AutoReboot=0 before a diagnostic retry and say explicitly this is not guaranteed to survive setup.
- **SafeOS drive letters**: WinPE/SafeOS letters (e.g. `F:\$WINDOWS.~BT\NewOS`) differ from the booted OS; they do not prove the wrong disk was selected. Disk numbers ≠ Storport adapter/port numbers.
- **Informational noise**: Code Integrity policy-activation events, WHEA informational CPER, SBAT key-update failure recorded during a boot that then succeeded, recovered PnP watchdog slow operations (status 0), repeated ejection-veto warnings, post-rollback service failures — none identify the failed boot's cause by themselves.
- **Elevation**: saved rollback EVTX files and protected channels need an elevated process; a non-elevated collector that "found nothing" may simply have been denied — record denied reads in the manifest.
