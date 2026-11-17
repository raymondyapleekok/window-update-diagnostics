# Case studies (diagnosed real failures; read before hypothesizing)

These are generalized from a long-running in-place upgrade case on this machine family (Windows 11 Home 22631 → 24H2/26100-class target, Z690-class desktop, Installation Assistant/MCT path) plus recurring Microsoft Q&A patterns. Each shows how an intuitive "root cause" failed the differential test.

## Case 1 — 0xC1900101-0x40017, "EaseUS storage filter" false positive

**Symptom.** Feature upgrade reached Post First Boot, `FirstBoot,End`, reboot-before-OOBE requested; next boot never reported; recovery retried once, rolled back. SetupDiag `FindRollbackFailure`; last operation "Ensure suspended services are stopped". Panther showed `EPMVolFl` migrated with doubled path `\SystemRoot\\SystemRoot\System32\drivers\EPMVolFl.sys` and DiskDrive/Volume UpperFilters containing EaseUS entries → looked like a textbook boot-filter failure.

**Action.** Vendor-uninstalled EaseUS Partition Master; verifier confirmed service registrations/filters gone; single-variable retry.

**Result.** SAME failure signature. EPMVolFl anomaly was real but not causal. Also `WinSetupMon.sys` copy access-denied (0x80070005) in an early attempt vanished on its own in the next attempt while rollback persisted → that error was neither sufficient nor necessary.

**Lessons.**
1. A doubled SystemRoot path / third-party class filter is a legitimate finding, not a diagnosis. Removing it must be tested as the single variable; expect the possibility it changes nothing.
2. Intermittent-looking setup errors can be attempt artifacts. Correlate per-attempt before ranking.
3. After removal + one identical retry, stop assuming; re-open evidence questions ("did new OS boot at all? what happened next boot?").

## Case 2 — Missing crash dump despite perfect current-OS settings

**Symptom.** No `MEMORY.DMP`, no `setupmem.dmp`, rollback log said no crash signature. Administrator had set Automatic memory dump + AutoReboot=0 + system-managed pagefile before the attempt; Panther proved setup READ dump type 7 and prepared a ~9.5 GiB pagefile.

**Evidence after elevated collection.** Saved new-OS `Kernel-Dump` event 10 explicitly: **"Crash dump disabled"**. Saved NewOS BCD had `restartonfailure Yes`, `hypervisorlaunchtype Auto`.

**Lessons.**
1. Absence of a dump does NOT exclude a bugcheck; check the target-OS Kernel-Dump event in the saved rollback data.
2. Setup-stage and BCD-level policies override current-OS UI settings; state this uncertainty when advising crash-capture prep; a pre-kernel/firmware hang may never write a dump regardless.
3. Protected rollback EVTX files require an ELEVATED reader; an unprivileged "nothing found" pass is not evidence. Log denied reads.

## Case 3 — BOOTSTAT "event 84" rabbit hole

**Symptom.** Rollback boot-status summary: NewOS 3 initializations, 3 launches, 1 error record, last error event **84**, `LastBootSucceeded=0`. A third-party bootstat parser produced inconsistent offsets, tempting "boot font missing" fixes.

**Lessons.** BOOTSTAT event numbers are internal records — not stop codes, not Event Viewer IDs, not Win32 error 84, not file names. Structural byte comparisons are evidence, not decoding. Never prescribe deletion/replacement of boot files from BOOTSTAT strings. Zero `FatalErrorCode` fields do not mean the boot succeeded.

## Case 4 — Noise classes that were NOT the cause (same case)

- Secure Boot off + SBAT key-update failure (status 0xC0000034) logged during the boot where setup then SUCCEEDED → not the failed-boot cause; did not justify firmware-key resets.
- Code Integrity: 9 informational policy-activation events, no block record → cannot exclude later-boot blocks, but provided no culprit.
- PnP watchdog ~20.6 s slow operation on a PCI root port above a secondary SSD, completed status 0 → lead only.
- Storport "unsupported/invalid CDB" responses and one admin timeout on NVMe: ended BEFORE the planned restart; no read/write failure at the failing reboot → not proof of a bad disk.
- 96 PnP 225 ejection-veto warnings = repeated attempts to restart a busy bridge → not 96 disk failures.
- VBS/hypervisor ran successfully in both old and new OS → presence is not conflict proof.
- Build confusion: attempt used an image reporting 26300 while another used 26100.9445; component versions mixed → verify the actual image, don't infer from folders or single component numbers.

**Lesson.** Rank every log record by (a) error level, (b) timestamp vs the failing transition, (c) whether it persists into the failing boot. Anything that recovered, succeeded afterwards, or predates the restart is background.

## Case 5 — Community 0x40017 successes (patterns that DO work when evidence matches)

- `MIG Plugin ... Unable to determine inbox status of driver 'oem102.inf' for ROOT\SYSTEM\0001` + `Failed to remove INF oem297.inf` in setuperr → mapped oem INFs via `pnputil /enum-drivers`, removed owning legacy/virtual-device packages, clean boot → upgrade succeeded (Microsoft Q&A, 23H2→25H2/24H2-class).
- Repeated CrowdStrike-style agent rollbacks resolved by removing the endpoint agent for the upgrade window (managed fleets: coordinate with admins).
- Installation Assistant loops (no BSOD visible): clean boot with Microsoft services hidden resolved several same-signature Assistant cases.

**Lesson.** When a MIG/plugin line NAMES an object and that object maps to a removable owning product, targeting it has a high hit rate; when logs name nothing that survives the boot boundary, prefer isolation tests (spare disk) over more driver purges.

## Case 6 — "I removed the AV and it still failed" (and why that test later expired)

Same PC family: Bitdefender Total Security was removed at some point before/during the failure streak; feature updates kept rolling back → the user reinstalled it (driver CreationTimes: reinstalled days later). Later attempts failed again with BD present.

**What the timeline actually licenses:**
- If an attempt failed while BD was ABSENT, BD is not a necessary cause - correct.
- Once BD is reinstalled, every later failure happens with BD PRESENT again, so absence is no longer tested; BD re-enters the candidate set for the NEW baseline (and 0x40017 is its documented error family).
- Conversely, BD cannot explain any attempt that predates its first install.

**Lessons.**
1. Build an attempt ledger with per-attempt presence/absence of each suspect (install/uninstall dates vs attempt dates). "Removed X, still failed" is a valid differential only for attempts executed while X was removed.
2. Reinstalling a removed suspect resets that variable; don't re-cite the old absence test against new failures.
3. RegisteredAV was "Windows Defender" even when BD boot minifilters loaded in earlier runs - AV registration in SetupDiag is not a reliable presence check; use filter/boot-driver inventory plus file dates.

## Case 7 — Uninstalled the app, but the boot filter stayed (Corel example)

Uninstalling Corel Graphics + reboot left `PxHlpa64.sys` still Boot-start RUNNING and still referenced as CDROM class LowerFilters, plus `cbfs6` (virtual-CD driver) running. The "Corel variable" was therefore NOT removed in any subsequent attempt until leftovers are gone.

**Lessons.**
1. After ANY vendor uninstall that targets a filter/boot driver: reboot, then re-run the filter/boot inventory. Treat "app gone from Installed apps" as insufficient.
2. Virtual-CD / burning-engine drivers (PxHlpa/PxRuns, cbfs, ElbyCDIO, etc.) survive app uninstalls because shared components keep them registered; use the vendor cleanup utility or a technician-supervised `pnputil`/service removal - never raw file/hive surgery.
3. Leftover class filters pointing at surviving services still migrate into the next upgrade attempt, silently keeping a suspect variable "on".

## Case 8 — 3-year-old OS lineage and "update everything first"

The failing host was an OS installed ~3 years earlier and itself created by a Windows 10→11 in-place upgrade (Panther install dates, legacy `ProductName` "Windows 10 Home"). Its patch level was frozen by 23H2 end-of-support (last LCU = final 23H2 patch), while its DriverStore accumulated ~2016-2026 third-party drivers across OS generations.

**Lessons.**
1. Read version data from `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion` (`UBR`, `DisplayVersion`). Values under `SOFTWARE\Microsoft\Windows\CurrentVersion` are legitimately absent on modern builds - do not "discover" corruption there. `ProductName` "Windows 10 Home" on Win11 is a normal in-place-upgrade artifact.
2. On an EOL branch, "install all updates first" has a hard ceiling; latest SSU/LCU may require Microsoft Update Catalog. A stale SSU is a documented cause of update INSTALL failures - it does NOT explain a second-boot driver-migration rollback (0xC1900101-0x40017); keep each in its lane.
3. Multi-generation inherited driver stacks are the 0xC1900101 candidate pool: enumerate third-party DriverStore packages with `pnputil /enum-drivers` and file CreationTimes; the old 2016-era boot filters are classic 0x40017 suspects even when the owning "app" is long gone from Programs.
4. A long failure streak usually spans MULTIPLE codes (0xC1900101, 0x80070057, 0x800704C7 cancellations): classify each attempt separately in the ledger; cancelled/argument errors are different classes, not "the same rollback".
5. Lineage: this host's OS was itself migrated by EaseUS clone onto the Z690 board in 2023 (license now RETAIL-activated) — it has never first-booted from clean media on this hardware. That is precisely why spare-disk clean-install escalation carries high information value here, and why SetupDiag's generic `FindRollbackFailure` (no specific rule matched) was expected: multi-generation inherited stacks often fail in boot/filter migration without naming one package.
6. 2026 precedent: Microsoft Q&A threads (Oct/Nov 2026) with the identical 23H2→26H2 `0xC1900101-0x40017` signature — including WU+MCT+ISO all failing — were resolved by a **full clean boot then ISO in-place retry**. Clean boot suppresses third-party SERVICE conflicts; it does NOT unload boot-start filter drivers — if a clean-boot attempt fails unchanged, the next variable must address boot drivers, not more services.
7. Elevated `pnputil /enum-drivers` on this host confirmed the migrated-stack theory concretely: Intel chipset packages from FOUR platforms (Skylake/Sunrise/Coffee/Cannon alongside the correct Alder Lake), orphan storage drivers `iastorac.inf` (RST 15.7/2017) + `iaahcic.inf` (14.5/2015) on an NVMe-only Z690, and 2007-2012 era bus drivers (Eltima `vuh.inf`, EldoS `vpnpbus.inf`) plus Lenovo/Broadcom/CSR/Alcor/Synology/FTDI/HP residue. All Bitdefender packages are current and product-managed (exclude from pnputil; managed by the product). Orphan STORAGE packages are the top suspects that SetupDiag's generic FindRollbackFailure cannot name — plan removal via the cleanup-plan script, one attempt-variable at a time.

## Case 9 — clean-boot attempt that was NOT a clean boot, and a signature change to 0x80070057

A user intended "attempt #9 = clean boot". Post-attempt artifacts showed MSConfig `StartupType` blank (Normal startup) and the Bitdefender AV services RUNNING during the attempt window — so the clean-boot variable was never actually exercised. The attempt also failed with a DIFFERENT code than attempts 1-8: not `0xC1900101-0x40017` (Second Boot driver rollback) but `0x80070057` with `gle=0x000000B7` (ERROR_ALREADY_EXISTS) on `Add [2] package ...\DUImageSandbox\metadata\Windows11.0-KB5043080-x64 to NewOS` — a SafeOS-phase abort while injecting a dynamic update. Downlevel boot servicing had already succeeded (BFSVC copied bootx64.efi/fonts); "System partition is not in a space" was INFO, not an error. The queue then reported "Cannot revert execution... queue is now compromised" and rolled back.

**Lessons.**
1. ALWAYS verify the intended variable was in force from artifacts, not intent. An attempt that silently ran in Normal startup with AV active is not a clean-boot test; re-run it validly before concluding clean boot doesn't help.
2. A NEW signature is information, not regression: 0x80070057/0xB7 on a `DUImageSandbox` KB is a stale/duplicate **dynamic update**, an Installation-Assistant download-state problem — a completely different fix (fresh ISO, `/dynamicupdate disable`), NOT the driver ladder. Do not run driver cleanup against a DU failure.
3. `0x80070057` appears in two distinct lanes — downlevel Gather (install-time conversion) and SafeOS DU add (already-exists). Read the surrounding `Add [n] package`/`ExecuteOperations: Failed execution phase` lines to place it; the phase determines the remedy.
4. After "queue compromised" the rollback may be non-revertible; check pending-reboot indicators and let setup finish its own rollback before the next action.

**RESOLUTION (attempt #10, same day): SUCCESS — build 26300.9457 / 26H2 installed and stable.** What changed since the last 0x40017 rollback (#8, Nov 12): the Corel `PxHlpa64`/`cbfs6` orphan boot filters were removed (Nov 15), the stale Assistant staging (`$WINDOWS.~BT`/`$WINDOWS.~WS`) was deleted, and setup ran from the **official ISO with `/dynamicupdate disable`**. Attempt #9 (Assistant, post-Corel-removal) proved the DU blocker in isolation; #10 was the first second-boot since the filter removal and it survived Second Boot + OOBE into a clean, device-problem-free 26H2. Attribution is deliberately joint (filter removal + media/DU bypass + 26300 image), and the clean-boot variable was never exercised end-to-end — moot for the outcome; the ledger records exactly which attempt tested what. Final checks: 0 problem devices, no pending reboot, Bitdefender registered-active, Windows.old rollback available ~10 days.

**Post-resolution state (same evening):** after the orphan-driver cleanup wave, Memory Integrity (HVCI) was re-enabled and verified active (`SecurityServicesRunning=2`) with zero blocked-driver CodeIntegrity errors. Residual finding: Bitdefender's `bdamsi\antimalware_provider64.dll` is a **2024-02 binary signed only by Bitdefender SRL**, rejected by 26H2's signing requirements for protected processes (repeated 3033 events) — in-product "update" refreshes signatures, not program binaries, so the remedy is a full **program reinstall** from the vendor's current installer; never relax CI/HVCI to silence it. Also note: Windows Firewall WFP `2042 Config Read Failed` events appear when a third-party firewall/tamper-protection governs WFP — benign unless connectivity breaks.

**Case moral:** long upgrade failure streaks on migrated systems frequently have MULTIPLE concurrent blockers at different phases. Fixing one reveals the next with a different signature — treat a signature CHANGE as progress, not regression, and re-climb the ladder for the new phase.

## Case 10 — Post-upgrade driver housekeeping: vulnerable-driver blocks and the wave that cleaned them

First 26H2 boot surfaced Program Compatibility Assistant "vulnerable driver" blocks (ene.sys) — 24H2+ enforces the Microsoft blocklist by default and setup even auto-disabled Memory Integrity. Housekeeping wave (user-approved): 9 orphan services removed with key backups + file quarantine (Gigabyte/Ene charger trio, Baidu 2017 net driver, /n software virtual bus, Intel ReadyMode, WDC SAM, orphan Intel RST service), then 17 orphan driver PACKAGES deleted after re-curation.

**Lessons.**
1. `oemNN.inf` names are **renumbered by every feature upgrade** — never carry a deletion list across an upgrade; re-enumerate and re-curate by provider/class/version/date.
2. "No connected device" is not enough: pnputil correctly refused two printer packages whose devices remain *installed* but powered off. A refusal with "devices presently installed" = leave it; it is not an orphan.
3. Running drivers whose service was just deleted disappear at next reboot (`sc delete` → DELETE_PENDING); quarantining a loaded `.sys` requires next-boot rename-delete — verify after reboot.
4. Post-upgrade security posture check belongs in Phase 7: vulnerable-driver popup → remove the driver (never the blocklist); once clean, re-enable Memory Integrity.
5. Vendor surprises during binding checks are normal (CTIIO = Creative, bbnetdriver = Baidu): publisher metadata decides, not folder folklore.

## Case 11 — The restore wave that restored defaults, and the disable that never happened

Post-success evening (2026-11-15, same host as Cases 9-10). `restore-wave.ps1` re-enabled seven services with `sc.exe config <name> start= auto` and removed three `StartupApproved` markers (SecurityHealth, Bdagent, RtkAudUService). No pre-clean-boot baseline existed in the case folder, so "restored" really meant "set to default": nothing proved those services were originally Auto rather than Manual/delayed, and nothing distinguished startup items WE disabled for testing from ones the USER had disabled long ago. In the same window `startup-off.ps1` logged `not found (already off?)` for two startup apps while `startup-off2.ps1` — same key, read with `reg.exe` — found both values and disabled them properly. Mechanism (reproduced later on the same machine): PS 5.1 `Microsoft.Win32.RegistryKey.GetValue(name, default, bool)` has NO bool overload (the third parameter is the `RegistryValueOptions` enum), so the call threw; with `$ErrorActionPreference='Continue'` and an unlogged stderr, `$val` stayed null and the script printed its own "already off?" conclusion. The CIM verify line (`still in enabled startup: none`) agreed with the lie because `Win32_StartupCommand` enumerates ENABLED entries only — absence is indistinguishable from never-having-disabled. Without the `reg.exe` retry, those disables would have silently no-op'd. The pattern finally used IS the keeper: `reg.exe export` of the Run key into the case folder, then disable by renaming the value to `<name>.disabled-YYYYMMDD` with the original command preserved as the value data.

**Lessons.**
1. A disable is not "already off" unless two independent readers agree (script API + `reg.exe`) and the script's error stream is captured in the log. Verify the disable by reading the exact key edited; enabled-only enumerations cannot prove a disable.
2. Restoration requires the baseline. Without a before-snapshot, "restore the appropriate ones" is guesswork: `start= auto` is a guess; versioned service names (Google/Chrome updaters) may no longer exist; removing every `StartupApproved` marker un-disables the user's own choices. Use `snapshot-startup-state.ps1` before the first test-disable; restore the recorded `was:` values; prove it with `-CompareFile`.
3. Tag intent per ledger line: `diagnostic` (auto-restore at close) vs `cleanup`/`user-requested` (keep with sign-off). That same evening the wave restored security posture (Bdagent/SecurityHealth markers back ON) while deliberately LEAVING WiFi GO!/WD Quick View off — bulk "re-enable everything" would have resurrected the user's choices; bulk "leave as-is" would have finished the case with AV and Windows Security startup items still off.
4. Close-out is symmetric: abandoning the update after repeated failures requires the same baseline reconciliation as success, before the update posture (pause/defer/stay) is finalized. A half-clean-booted machine is not a finished case either way.

## Meta-lessons for the skill

1. Preserve-before-touch; hash; record denied reads.
2. One variable per attempt; a cause must survive removal-without-success being impossible.
3. Target-OS evidence > current-OS opinions.
4. Informational ≠ causal; recovered ≠ causal.
5. Two identical failures with no new signal → stop retrying; escalate with the bundle.
6. **Record install dates of every candidate driver/product** (driver file CreationTime, uninstall registry InstallDate). In this case Bitdefender Total Security (vlflt/atc/gemma boot filters) was installed between attempts - it cannot explain earlier failures but DID change the differential baseline for later ones, and 0x40017 is its documented error family. Always compare candidate install dates against each attempt timestamp before ranking.
7. Post-upgrade app error-loops (e.g., Samsung Magician "encountered an error and cannot continue" on every launch) usually mean the app's OWN service was left Disabled/Crashed, not that the app binary is broken: check `Get-Service`/`Win32_Service` StartMode+State, re-enable + start, relaunch the app; only escalate to vendor reinstall if the service itself crash-exits. When scripting "close hung app windows", exclude the service's own process — own-process services run exes named like the service and a naive name match kills what you just fixed.
8. A third-party AV may not appear as `RegisteredAV` even while its boot minifilters load; the filter/boot-driver inventory - not the AV registration - is the authoritative check.
9. A script's "not found" is a claim, not a measurement: confirm with a second independent reader and capture the error stream; an unlogged `GetValue` overload bug manufactured a false "already off" verdict and would have voided an attempt's variable.
10. Restore means the recorded before-value, never the category default. The case closes - on success OR abandonment - only after the change ledger is reconciled against the pre-case baseline (`snapshot-startup-state.ps1`) and every kept change is user-approved.
