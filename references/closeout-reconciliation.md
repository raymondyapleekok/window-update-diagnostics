# Close-out reconciliation (restore to recorded baseline)

Run at case close on EITHER ending (success or abandonment) — the machine is never left in a half-diagnostic state. SKILL.md Phase 7 dispatches here; this file is canonical for restore semantics, audit method, and verification traps.

## Why the baseline governs

- Without a case-start baseline (`scripts/snapshot-startup-state.ps1` captured before the first test-disable), what the case disabled cannot be distinguished from what the USER had already disabled; marker removal or bulk re-enable then silently un-disables the user's own choices.
- Restore **recorded original values, never defaults**. `sc.exe config <svc> start=auto` on an originally Manual or Delayed-Auto service silently changes boot behavior.

## Restore mapping by artifact

| What changed during the case | Restore action | Source of the original value |
|---|---|---|
| Service start type | `sc.exe config <svc> start=<original>` | Baseline `Services.StartMode` (+ `DelayedAutoStart` flag) |
| Startup-app disable | Remove the `StartupApproved` marker value recorded in the baseline, in the hive where the Run entry lives (HKCU / HKLM / WOW6432Node) | Baseline `StartupApproved` (raw bytes recorded; the disable WAS the marker's presence) |
| msconfig selective/clean startup | Restore normal startup (`StartupType`) and clear the `SERVICES` overrides the case set | Baseline `MSConfigStartupType` / `MSConfigServiceOverrides` |
| Crash-capture settings | `scripts/repair-windows-update.ps1 -RevertCrashCapture` | Change-ledger before-values |
| Disconnected hardware | Reconnect; verify device re-enumeration | Case record |

Never decode `StartupApproved` flag bytes heuristically. Presence/absence of the marker recorded in the baseline is the restore target, not bit-pattern interpretation.

## Audit method (when no ledger exists)

- Disabled services: `Get-CimInstance Win32_Service -Filter "StartMode='Disabled'"` grouped by file publisher. On migrated/cloned machines expect orphan vendor suites from PREVIOUS machines (ASUS/Gigabyte mixes); classify against a product inventory — never bulk re-enable or bulk-delete.
- msconfig's disabled list lives in `HKLM:\SOFTWARE\Microsoft\Shared Tools\MSConfig\SERVICES` overrides, not in the service configuration itself.
- `Win32_StartupCommand` and Task Manager enumerate ENABLED entries only: presence proves enabled; absence proves nothing.

## Verification traps

- Verify an executed registry enable/disable with TWO independent readers (PowerShell .NET registry API and `reg.exe`) and capture the error stream before concluding "already off" or "not found" — a broken disable call fabricates absence and silently skips the variable (see Case 11).
- Hidden ≠ absent: clean-boot "Hide all Microsoft services" does not unload boot-start minifilters (`scripts/inventory-storage-filters.ps1` proves what is still loaded).
- If a `SupportsShouldProcess`/`-Confirm` script prompts when invoked via `powershell.exe -File` (the `-Confirm:` colon syntax does not bind there), run it in the current session with the user's approval; do not hand-inline its operations.

## Abandonment branch (Phase 7 step 6)

Same reconciliation applies. Change-ledger intent tags make the split mechanical: `diagnostic` restores; `repair` stays if its fix was approved and verified; `cleanup` / `user-requested` stays only with explicit user keep sign-off. Bulk re-enable therefore never resurrects apps the user chose to kill, and bulk leave-alone never abandons a machine with Windows Security or AV startup entries still off. Pin the update posture (pause/defer/stay), state end-of-support exposure plainly, and report residual diffs in the final report.
