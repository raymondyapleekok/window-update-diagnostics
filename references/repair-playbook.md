# Repair playbook

Only after evidence supports the repair; explicit approval before each state change (see `safety-and-reporting.md`). Work top-down; verify after each change.

## 1. First-line, low-risk

1. Pending reboot → reboot; retry once.
2. Disk space: feature updates need ≥20 GB (64-bit); keep ≥60 GB free for comfort. Check Windows volume and free MB on system/EFI/recovery partitions.
3. Peripherals: disconnect docks, USB storage, card readers, extra monitors; keep keyboard/mouse/display. Do NOT disconnect internal disks that host user data or pagefiles — map pagefiles first.
4. Windows Update troubleshooter: Settings → System → Troubleshoot → Other troubleshooters → Windows Update; or Get Help (aka.ms/GetHelp-WindowsUpdateTroubleshooter). On 24H2+ troubleshooters are standalone apps; `Get-TroubleshootingPack` is gone.
5. Install ALL other pending updates (incl. SSU and drivers via WU Optional updates), reboot, retry the failing one once.

## 2. Scan/download/cache faults (evidence: 0x8024xxxx, 0x80070002/3, repeated download failures)

Guarded: `scripts/repair-windows-update.ps1 -ResetUpdateComponents -WhatIf` then real run. It mirrors the documented Microsoft manual reset, rename-only (reversible): stop bits/wuauserv/cryptsvc → optionally remove `qmgr*.dat` → rename `SoftwareDistribution\DataStore`, `SoftwareDistribution\Download`, `System32\catroot2` → restart services → verify. Microsoft's more aggressive documented variant deletes `%systemroot%\SoftwareDistribution` outright; renaming is safer. Skip `sc sdset` service-ACL rewrites unless explicitly investigating corrupted service security — they overwrite custom ACLs. DLL re-registration (`regsvr32 wuapi.dll ...`) and `netsh winsock reset` are legacy steps: only with concrete evidence, with approval, and warn winsock reset disrupts network filters.

After reset: `UsoClient StartScan` or COM detection scan; verify download proceeds.

## 3. Component store / protected files (0x800f081f, 0x80073712, CBS hash mismatches)

1. Preserve CBS.log + dism.log.
2. `DISM /Online /Cleanup-Image /CheckHealth`, then `/ScanHealth`, `sfc /verifyonly`.
3. Approved `DISM /Online /Cleanup-Image /RestoreHealth`; if 0x800f081f use matching repair source (`WIM:X:\sources\install.wim:INDEX`, `/Get-WimInfo` for index; RTM-or-newer media; `ESD:` may fail).
4. Approved `sfc /scannow`; recheck health; retry update.
5. "Repair source" mistakes to avoid: wrong edition, refresh (non-RTM) media, older servicing level than target, pointing DISM at random ISOs.

## 4. Feature update / in-place upgrade rollback (0xC1900101 family)

**Step 0 - ledger before ladder:** reconstruct per-attempt changes (`get-attempt-history.ps1` + user memory + case folders). Exclude variables already disproved *under valid conditions* (component present in baseline, absent in the failed test), re-include variables reinstalled since their absence-test, and classify mixed codes (0x80070057/0x800704C7 = downlevel/cancelled attempts - separate class). Confirm servicing currency (UBR from `Windows NT\CurrentVersion`); on EOL branches note the patch ceiling and consider latest SSU/LCU from Microsoft Update Catalog only if downlevel/staging errors demand it.

Sequence (each numbered step is ONE attempt variable):

1. **Preserve** prior attempt evidence; run SetupDiag; record result+extend code, `Last Phase`, `Last Operation`, CV, matched rule, named drivers/INFs/plugins.
2. Work the extend-code row from `error-codes.md` (e.g. 0x40017 → clean boot + filter-driver audit).
3. **Clean boot properly**: first snapshot the pre-case state — `scripts/snapshot-startup-state.ps1 -OutFile <case folder>\startup-baseline.json`, and `reg.exe export` any Run key you will edit. Then `msconfig` → Services → tick **Hide all Microsoft services** → Disable all → disable Startup items → record EVERY change in the change ledger with the exact ORIGINAL value (`sc.exe qc <svc>` before touching it — record START_TYPE and delayed-autostart; the restore target is NOT `auto` for services that were Manual/delayed). Prefer reversible disable by renaming the Run value to `<name>.disabled-YYYYMMDD` (command data preserved in place) over Task-Manager toggles that record nothing; ledger line = original name + renamed value + restore command. Reboot. Confirm the disable actually took effect with TWO independent readers — `reg.exe query` on the edited key AND the PowerShell read; they can disagree because a script bug can throw into an unlogged error stream and print a false "not found (already off?)" — PS 5.1 has no `RegistryKey.GetValue(name, default, bool)` overload (third arg is the `RegistryValueOptions` enum), so that exact pattern fabricated a bogus already-off verdict in a real case (see `case-studies.md` Case 11). After testing, restore from the ledger/baseline — `sc.exe config <svc> start=<original>` per service, msconfig Normal startup, remove the recorded `StartupApproved` markers, rename Run values back — and verify with `scripts/snapshot-startup-state.ps1 -CompareFile startup-baseline.json` until drift is 0 except intended changes.
4. **Driver/INF targeting**: map `oemNNN.inf` names from logs to publisher via `pnputil /enum-drivers` (elevated); uninstall the OWNING application or driver package (`pnputil /delete-driver oemNNN.inf /uninstall` only with approval + rollback plan), never the raw `.sys`. On migrated/multi-generation DriverStores, also run `scripts/get-orphan-driver-cleanup-plan.ps1` (elevated): orphan third-party packages — especially STORAGE-class (old Intel RST iaStorAC/iaAHCI, external RAID) and ancient bus drivers (virtual USB/parallel) — are `UnknownDriverMigrationFailure`-class suspects that SetupDiag's generic rules won't name. Backup + per-item confirmation built in. Compatibility-report `BlockMigration` entries and print-INF oddities are leads, not proof of a hard block.
5. **Storage/security filter audit**: `scripts/inventory-storage-filters.ps1`. For each third-party boot-start/filter candidate (disk managers, encryption, virtual drives, backup agents, RGB/hw-monitor tools with kernel components): verify no pending disk operations, then vendor-uninstall ONE product, reboot, and RE-VERIFY the inventory — app-uninstall often leaves boot filters loaded (e.g. PxHlpa/cbfs virtual-CD drivers, class-filter references surviving); leftovers mean the variable was never removed. Treat reinstalls of previously-removed products as re-arming that variable. Retry upgrade ONCE.
6. **Firmware/BIOS**: only when SetupDiag/MS guidance/vendor release notes point there (storage/controller/AGESA/VID fixes). Record current version; vendor tool; never as ritual.
7. **Media/build hygiene for the retry**: download fresh ISO/MCT/Assistant; verify release/build/edition/language/arch matches target; launch `setup.exe` FROM running Windows (not boot-from-USB); select **Keep personal files and apps** + **Download and install updates (recommended)**; close files; don't move pagefiles during tests.
8. **Crash capture readiness before a diagnostic attempt** (`repair-windows-update.ps1 -SetCrashCapture`, records old values): Automatic memory dump, AutoReboot off, system-managed pagefile on C:. Tell the user Setup may still disable target-OS capture; after failure, check saved new-OS Kernel-Dump event. Suggest recording a phone video of the restart sequence to catch a brief stop code.
9. **Two consecutive attempts with identical signatures and no changed variable = STOP.** Do not repeat Assistant/ISO attempts unchanged; escalate (repair install → isolation test → Microsoft support).

## 4a. SafeOS dynamic-update (DU) abort — 0x80070057 gle=0xB7 on `Add ... DUImageSandbox ... KB... to NewOS`

VALIDATED (2026-11): on a 10-attempt streak, ISO + `/dynamicupdate disable` + deleted `$WINDOWS.~BT`/`$WINDOWS.~WS` resolved this class outright. Do NOT run the driver ladder against it. Sequence (approval per step):
1. Confirm from `Panther\setupact.log` the failing op is a DU package add and `gle=0x000000B7` (already exists). Check the pending-reboot indicators first; let any in-progress rollback finish.
2. Preserve evidence, then clear Assistant/MCT download state: delete `$WINDOWS.~BT`, `$WINDOWS.~WS`, the Installation Assistant cache under `%TEMP%\Windows11InstallationAssistant*`, and let the Assistant re-download fresh (or switch media). Stale DU metadata causes the already-exists.
3. Switch to the ISO route (full 26H2 media matching edition/language/arch) and/or run once with `setup.exe /auto upgrade /dynamicupdate disable` — the documented switch that skips dynamic-update injection, isolating the DU as the variable. Keep "Keep personal files and apps".
4. Verify: if it now passes the former failure phase, the DU/media was causal; a later Second-Boot rollback (0x40017) is then a SEPARATE variable — continue the ladder. Reboot, re-check pending indicators, record in the ledger.

## 5. Filter-driver safety rules (hard rules)

- Uninstall via the product's own uninstaller; reboot; re-verify class filters (`HKLM:\SYSTEM\CurrentControlSet\Control\Class\{...DiskDrive,Volume...}` Upper/LowerFilters, `SafeConfiguration`) are gone or vendor-sanitized.
- NEVER delete `.sys` files by hand, NEVER blank/remove UpperFilters/LowerFilters values, NEVER set a filter service to Disabled while class references remain — can render Windows unbootable (INACCESSIBLE_BOOT_DEVICE).
- Preserve Microsoft entries: `partmgr`, `volsnap`, `EhStorClass`, `fvevol`, `iorate`, `rdyboost`.
- Leftovers after uninstall → vendor cleanup/repair under supervision with backup + recovery media; not generic driver tools. **Orphan path when no vendor route exists** (product fully uninstalled, rebooted, inventory still shows it, and no DriverStore package so `pnputil /delete-driver` does not apply): `scripts/remove-orphan-filter-driver.ps1` — backs up the service keys, removes the orphan entry from class filter lists BEFORE deleting the service, optionally quarantines (moves, never deletes) the `.sys`; reboot and re-verify with the inventory.
- Duplicated SystemRoot paths (`\SystemRoot\\SystemRoot\...`) in migrated service data signal a third-party filter migration anomaly worth noting — but removal must still be differential-tested, not assumed curative.

## 6. Problem update already installed, system unhealthy

1. Match symptom start-date to update: Settings → Update history → Uninstall updates (exact KB).
2. WinRE route when unbootable: `rollback-and-recovery.md`.
3. Package-level: `DISM /Online /Get-Packages`, then `/Remove-Package` for the exact identity (SSUs may be non-removable).
4. Then pause updates (Settings, up to 35 days) so it doesn't immediately return; plan reinstallation/mitigation — removal lowers security posture.

## 7. Repair install (in-place) when OS itself damaged or upgrade blocked by migration state

- Same or newer release, same edition (Home↔Home etc.), same language+arch; run `setup.exe` from the running OS; **Keep personal files and apps**. If "keep apps" is unavailable, edition/build mismatch — fix source, don't proceed blindly.
- Pre-reqs: backup, BitLocker key availability, driver media, app reactivation inventory.
- A repair install replaces system files while keeping data+apps; it does not migrate broken filter drivers out and is not a malware cure.

## 8. Spare-disk isolation test (hardware/migration separation)

When repeated in-place rollbacks are unexplained and a spare expendable SSD exists:

1. Identification gate: record spare model/capacity/partition plan; never trust remembered disk numbers; any needed data on "spare" disqualifies it until backed up.
2. Verified backups + BitLocker keys with owner + installation USB on its own expendable stick.
3. Power off; physically disconnect ALL other internal storage and unplug external data drives. Only spare + installer USB.
4. UEFI-boot installer; confirm the ONLY internal disk matches the recorded spare before any partitioning; stop if identification is unclear.
5. Clean install matching installed edition. Observe: setup completes? subsequent normal reboots stable? — success points at migrated OS/drivers or original-disk/topology; failure points at platform/firmware/media/attached devices. Neither result names a component — continue differential logic.
6. Reconnect originals per recorded plan; boot selection by firmware entry, not by identical "Windows Boot Manager" labels.

## 9. Escalation bundle for Microsoft support / professional kernel debugging

Preserve and hash: Panther + `Sources\Rollback` (incl. saved EVTX, `setupmem.dmp` if any), `setupapi.dev.log`+`.dev`, BlueBox.log, CBS/dism, SetupDiag results (+`/ZipLogs` archive), bootstat copies, BCD stores (live + saved), filter inventory, event JSON exports for attempt windows, timeline notes, manifest of denied reads. Dumps privately only — they can contain sensitive memory. State explicitly: hypotheses tested and eliminated, attempts made, settings changed.
