# Error code reference

Read the FULL code: result + extend (`0xRRRRRRRR-0xEEEEEEEE`). Codes here are documented causes/mitigations, not verdicts — confirm against logs and current Microsoft docs for the user's build.

## Setup phase model

Downlevel (inside old OS) → SafeOS (WinRE-based) → First Boot (sysprep/specialization + data migration) → Second Boot / OOBE. Extend code's first nibble after `0x` indicates phase (`2`=SAFE_OS, `3`=FIRST_BOOT, `4`=SECOND_BOOT/OOBE); last bytes indicate the operation.

## 0xC1900101 — generic rollback (usually incompatible driver)

Thrown in any phase except downlevel. Analysis sources: `$Windows.~BT\Sources\Rollback\setupmem.dmp`, saved `*.evtx`, `Rollback\setupapi\setupapi.dev.log`, `Rollback\setupact.log`.

| Full code | Phase/operation | Documented cause | Microsoft mitigations |
|---|---|---|---|
| 0xC1900101-0x20004 | SAFE_OS / INSTALL_RECOVERY_ENVIRONMENT | Out-of-date drivers | Uninstall AV; remove unused SATA devices/devices/drivers; update drivers+BIOS |
| 0xC1900101-0x2000C | SAFE_OS / WIM apply (WinPE) | Out-of-date drivers; disk corruption | Disconnect all peripherals but mouse/keyboard/display; vendor drivers; check disk; accept "Download and install updates" |
| 0xC1900101-0x20017 | SAFE_OS / boot | Driver illegal op; non-Microsoft disk encryption; hardware failure | Update all drivers; find named driver via `%windir%\Panther` setuperr/setupact; update/uninstall it |
| 0xC1900101-0x3000D | FIRST_BOOT / MIGRATE_DATA | Display driver | Disconnect peripherals; update or uninstall display driver |
| 0xC1900101-0x30018 | FIRST_BOOT / SYSPREP (PNP specialization) | Device driver stopped responding | Disconnect peripherals; vendor driver updates; remove unused device drivers; read `setupapi.dev.log` |
| 0xC1900101-0x4000D | SECOND_BOOT / MIGRATE_DATA (OOBE) | Driver configuration; BSOD; low space | Check dumps/events in Rollback; free space; update BIOS; (legacy) disable BIOS caching/shadowing |
| 0xC1900101-0x40017 | SECOND_BOOT / boot (post-OOBE reboot) | Faulty driver; AV or encryption FILTER drivers | **Clean boot**, then retry; accept "Download and install updates"; identify filter drivers (see inventory script); uninstall owning product |

Rollback succeeded ≠ system fixed: confirm old build boots, evidence preserved, then apply the row above for the NEXT single attempt.

## Other setup result codes

| Code | Meaning |
|---|---|
| 0xC1900200 | SYSREQ block: hardware not eligible (TPM/SecureBoot/RAM/space safeguards) |
| 0xC1900204 | MIGRATION-choice block (edition change not allowed, e.g. Enterprise→Home) |
| 0xC1900208 | COMPAT block: actionable app/driver incompatibility (named in report) |
| 0xC1900210 | Scan-only, no issues (not a failure) |
| 0xC1900107 | Setup prerequisites/downlevel incompatibility (BlueBox.log) |
| 0x8007042B-0x2000D | Migration gather failure of a specific object — find the named file/registry object in setuperr, decode `gle` (e.g. `0x570` ERROR_FILE_CORRUPT); a corrupt named object can be the true cause |
| 0x80070005 in Panther copy/install | Access denied moving an upgrade component (e.g. WinSetupMon.sys): a real error but frequently NOT the rollback cause — verify it recurs and correlates with the failing phase before treating as primary. Intermittent access-denied on driver-file copies can implicate security-software self-protection (AV filter drivers) — a lead to clean-boot test, not proof |
| 0x80070057 in downlevel/Gather | E_INVALIDARG; documented SetupDiag sample shows `Error converting install time ... [gle=0x00000057]` during `Gather data` (FindSPFatalError). A mixed streak with both 0xC1900101 (boot rollback) and 0x80070057 (downlevel gather/arg) means TWO different failure classes; recheck registry install-time values only if 0x57 becomes the recurring class |
| 0x80070057 with `gle=0x000000B7` (183 ERROR_ALREADY_EXISTS) on `Add [n] package ...DUImageSandbox\metadata\Windows11.0-KBxxxxxxx-x64 to NewOS` | SafeOS phase aborts while injecting a **dynamic update (DU)** into the new image: the DU (CU/SSU staged by Installation Assistant / MCT) already exists in the image or the DU sandbox is stale. NOT a driver failure. Remediation order: preserve evidence → fully remove `$WINDOWS.~BT` + `$WINDOWS.~WS` + Assistant temp caches and re-download fresh → use the **ISO route** and/or run `setup.exe /auto upgrade /dynamicupdate disable` (documented switch; skips DU injection entirely) as one clean test. "Cannot revert execution... Execution queue is now compromised" after this error means rollback relied on non-revertible boot changes — verify no pending reboot afterwards and let setup's own rollback complete first |
| Release-specific path rules | Enablement packages (e.g., 26H2 KB5121794) require specific prerequisite releases/KBs (24H2/25H2 + a named cumulative update); older branches (23H2) must use FULL setup media (ISO/Installation Assistant), not enablement. Verify the supported path for the exact target on Microsoft's release pages before blaming failures |
| Safeguard hold | Feature update simply never offered / "on its way but not ready" = safeguard hold (see SetupDiag GatedCompatBlock) — a compatibility block by design, not a failure; wait or check release-health. Holds do not block manual full-media setup, so a hold is not the explanation for manual-setup rollbacks |
| 0x80070057 (E_INVALIDARG) at feature-update install | Downlevel/setup-argument or compatibility-state error, NOT a second-boot driver rollback. In a mixed streak, classify separately; often follows interrupted/failed prior attempts or corrupt staging leftovers |
| 0x800704C7 | Attempt was cancelled (user or setup abort) — record as a cancelled attempt, not evidence of a cause |
| 0x80073D02 (Store apps) | App package in use/blocked install; recurring noise unrelated to feature-upgrade rollbacks; do not add to the driver-hypothesis pool |

| Program Compatibility Assistant: "A driver cannot load on this device… security setting is detecting this as a vulnerable driver" | NOT an update failure — Windows 11 24H2+ enforces the **Microsoft Vulnerable Driver Blocklist** by default (WDAC EA policy, independent of HVCI, which 23H2 did not enforce). Post-upgrade popups for old utility drivers (EneTech `ene.sys`, Gigabyte `AppleCharger`/`UsbCharger`/`CTIIO`, etc.) = blocked-list members migrated from the old OS. Check: service state + PnP device binding (`Win32_PnPSignedDriver`); bound to nothing = orphan → remove via `remove-orphan-filter-driver.ps1 -QuarantineSysFiles`. NEVER advise disabling Memory Integrity/blocklist to "allow" the driver. Related: setup may turn Memory Integrity OFF during upgrade when it detects such drivers — re-enable after the orphaned ones are gone (and only after checking remaining bound members). Third-party AV signing-level noise in CodeIntegrity 3033 (e.g. `bdamsi` DLLs) usually clears after updating the AV product to its new-release build. |

## Windows Update agent errors (scan/download/install of quality updates)

| Code | Name / meaning | Typical next step |
|---|---|---|
| 0x8024001F / 0x8024402C / 0x80244022 / 0x80240438 | No internet to WU / proxy-to-WU / HTTP 503 server / unexpected | Network/proxy/policy check; time sync; retry |
| 0x80240034 / 0x80240033 | Download failed / EULA unavailable | Retry; cache reset if repeat at same file |
| 0x80070422 / 0x80070426 | wuauserv could not start / update service not started | Verify services (`sc qc`), dependency RPCss; do not "force auto"; troubleshooter |
| 0x80070002 / 0x80070003 | File/path not found in download cache | Cache reset (`-ResetUpdateComponents`) |
| 0x80073CF0-0x80073D00 range (e.g. 0x80073CF9, 0x80073D00) | MSIX/staging/install failures incl. reboot-required | Reboot; DISM/SFC; check CBS for named package |
| 0x800f081f / 0x800f0906 / 0x800f0831 | Source missing / cannot download repair files / store corrupted | DISM RestoreHealth with matching repair source |
| 0x80073712 / 0x800736CC / 0x8007000D | Component-store inconsistent / file hash mismatch / invalid data | CheckHealth→ScanHealth→RestoreHealth→sfc; CBS named component |
| 0x80240020 | Reboot required to continue | Reboot, then retry once |
| 0x80070643 / 0x8007066D / 0x8007065B / 0x800706BE | MSI generic install failure / security failure / user cancelled / timeout | Map inner CBS error; KB-specific MS guidance |

Decode HRESULT once, keep the original string. Distinguish primary failure (first meaningful error at the phase boundary) from downstream symptoms (every later "ERROR" line).

## Where codes appear

- Settings → Windows Update → Update history (codes per item), Upgrade error screen text, System log source `WindowsUpdateClient` (events 19/20 with errorCode), `setuperr.log`, SetupDiag result, `SetupDiagResults.xml` from Setup's automatic run, `HKLM\SYSTEM\Setup\MoSetup\Volatile\SetupDiag`.
