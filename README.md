# Windows Update Diagnostic & Repair — Kilo Skill

Version 2.1.0 — see [CHANGELOG.md](CHANGELOG.md).

Safety-first diagnosis of Windows 10/11 Windows Update, servicing, feature-upgrade, and rollback
failures. Built from Microsoft documentation (SetupDiag, upgrade resolution procedures, Windows
Update logs/reset guidance) plus hard lessons from a real multi-attempt `0xC1900101-0x40017`
feature-update rollback investigation (storage-filter false positives, BOOTSTAT misreads,
target-OS crash-capture surprises, elevation gaps).

## Install

1. Extract; copy the `windows-update-diagnostic` folder to `%USERPROFILE%\.kilo\skills\`.
2. Confirm `%USERPROFILE%\.kilo\skills\windows-update-diagnostic\SKILL.md` exists.
3. Restart/reload Kilo. Prompt example: "Use the windows-update-diagnostic skill to investigate my Windows Update failure. Start read-only."

## Files

- `SKILL.md` — dispatch layer: triage → collect → SetupDiag → interpret → differential repair ladder → verify → escalate.
- `scripts/collect-diagnostics.ps1` — read-only collector (system, services, filters, WU events, logs, manifest).
- `scripts/get-attempt-history.ps1` — read-only attempt ledger: WU event timeline, servicing currency (correct `Windows NT\CurrentVersion` keys), staging-tree survival, candidate install dates vs attempt dates.
- `scripts/snapshot-startup-state.ps1` — read-only startup/services baseline (StartMode + delayed, MSConfig overrides, Run keys incl. WOW6432Node, StartupApproved raw bytes); `-CompareFile` diffs current vs baseline so restores replay recorded values, not defaults.
- `scripts/collect-upgrade-evidence.ps1` — ELEVATED read-only capture of protected rollback EVTX/bootstat/BCD + event windows (the evidence non-admin tools miss).
- `scripts/run-setupdiag.ps1` — finds and runs Microsoft SetupDiag (online/offline/Recovery); `-DownloadLatest` fetches the current Microsoft-signed copy from the official link (signature-verified).
- `scripts/analyse-update-logs.ps1` — marker/pattern scan with interpretation reminders.
- `scripts/inventory-storage-filters.ps1` — class-filter + boot-driver third-party inventory.
- `scripts/remove-orphan-filter-driver.ps1` — guarded orphan-filter cleanup after vendor uninstalls (backup + ordered removal + quarantine, never raw deletion).
- `scripts/get-orphan-driver-cleanup-plan.ps1` — elevated DriverStore orphan planner for migrated/multi-generation systems (protects live products, tiers candidates, backs up, optional guarded -Apply).
- `scripts/verify-system-health.ps1` — DISM/SFC/service/space/crash-capture/filter sanity checks.
- `scripts/repair-windows-update.ps1` — guarded repairs: DISM/SFC, cache component reset (rename-only), detection scan, crash-capture prep/revert. `-WhatIf` supported.
- `references/` — internals; logs & SetupDiag; error codes; repair playbook; rollback & recovery; close-out reconciliation; case studies; cleanup catalog (approved housekeeping whitelist); safety & reporting. Output follows the two-layer communication standard: technical detail plus a plain-language restatement, always as numbered steps.
- `docs/DESIGN-NOTES.md` — why the skill is structured this way (maintainer context).

Every script carries comment-based help (`Get-Help .\scripts\<name>.ps1 -Full`).

## Typical first pass (as in SKILL.md)

```powershell
Set-Location "$env:USERPROFILE\.kilo\skills\windows-update-diagnostic"
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\collect-diagnostics.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\run-setupdiag.ps1 -Output C:\SetupDiag\Results.log
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\analyse-update-logs.ps1 -Path .\path\to\Logs
```

After a feature-update rollback, in an ELEVATED PowerShell window:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\collect-upgrade-evidence.ps1
```

## Sample report (redacted, two-layer format)

```text
Finding (confirmed): SetupDiag FindRollbackFailure → 0xC1900101-0x40017, first-boot phase.
Boot-start class filter from oemNNN.inf (2007-era virtual-USB adapter package, device not
present) survives into the new OS. No crash dump: target-OS kernel dump was disabled by setup.
Evidence: C:\$WINDOWS.~BT\Sources\Panther\setuperr.log 2026-11-12 03:14; pnputil mapping.

In plain terms: the upgrade choked on a saved copy of a 19-year-old driver for hardware you no
longer own, and Windows never got to tell us why. We remove that saved copy — not anything you use.

Next (one variable): remove the orphan package with the guarded script, reboot, verify removal,
retry the update with "Keep personal files and apps". Revert path: package is backed up.
```

## Security & privacy

- Collection scripts are read-only; every state-changing operation requires explicit approval and supports `-WhatIf` preview; caches are renamed, never deleted.
- No passwords, product keys, or BitLocker recovery keys are ever collected. Ask users to keep them private.
- Logs and memory dumps can contain machine names, paths, identifiers, and sensitive data — review bundles before sharing and **never publish memory dumps**.
- Case studies and reports committed to this repo must be scrubbed of machine names, account names, user paths, serials, and board models.
- SetupDiag is obtained only from the official Microsoft download link and its signature is verified; never use mirrors or rehosts.
- Filter-driver removal follows vendor uninstallers only; the skill refuses generic "disable security / rebuild boot / delete .sys" fixes.

## Contributing

- Real diagnosed case? Append an entry to `references/case-studies.md`: failure signature, evidence, what was tried, outcome, dead ends. The skill instructs the agent to do this after every run — human-contributed cases follow the same shape. Scrub identifiers first (see Security & privacy).
- Keep `SKILL.md` a dispatch layer: detailed procedures live in `references/` (they are canonical; on conflict the references win). Avoid restating procedure text in SKILL.md — drift is the documented failure mode this design prevents.
- Scripts: Windows PowerShell 5.1-compatible syntax, read-only by default, `-WhatIf`/confirmation on state changes, comment-based help, no machine-wide execution-policy changes.
- One fix per PR; cite the evidence signature (error pair, log line, SetupDiag rule) that motivated the change.

## Requirements

Windows PowerShell 5.1+ (also runs on PowerShell 7 for most collection tasks). SetupDiag is not
bundled — obtain the current Microsoft-signed copy from the SetupDiag page on Microsoft Learn.
Some evidence paths require administrator elevation; scripts state what they skipped.

## License

MIT — see [LICENSE](LICENSE).
