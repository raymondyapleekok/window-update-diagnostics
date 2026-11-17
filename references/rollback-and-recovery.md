# Rollback and recovery paths

Two different things are called "rollback": (a) Setup automatically reverting a FAILED feature upgrade (already happened, system is back on the old build); (b) deliberately returning from an INSTALLED new build to the previous one. Treat them separately.

## A. Upgrade rolled back on its own (0xC1900101 etc.)

- Old build is restored automatically; personal files are preserved by design. Confirm: `winver` shows the prior build; system boots; BitLocker not suspended unexpectedly.
- The rollback attempt itself can fail (rare): "we couldn't undo the changes". Then boot from installation/recovery media → Repair your computer; do NOT improvise disk operations. Escalate.
- Before ANY next upgrade attempt, capture the failed attempt's logs (they get deleted) — see `logs-and-setupdiag.md`.
- Rollback "success" does not mean success: it means the system is safe to diagnose and one repair variable can change per retry.

## B. Go back to a PREVIOUS installed Windows version

- Settings → System → Recovery → **Go back** ("Return to the previous version of Windows"): only within the rollback window, ~10 days by default; keeps personal files; removes apps/drivers installed after the upgrade and reverts settings. Greyed out = the retained files (`Windows.old`, `$WINDOWS.~BT`) are gone or the window closed.
- CLI equivalents (admin):
  - `DISM /Online /Get-OSUninstallWindow`
  - `DISM /Online /Set-OSUninstallWindow /Value:60` (max 60; extends the window — a supported way to preserve the option briefly)
  - `DISM /Online /Initiate-OSUninstall` — starts rollback to the retained previous install, IMMEDIATE restart. Approval + saved work + backup confirmation first.
- Never manually delete `Windows.old` or `$WINDOWS.~BT` while the user may still want to go back or while logs are needed; Disk Cleanup/"Temporary files" deletes them.

## C. WinRE (Windows not booting after updates)

Entry: automatic after repeated failed boots; or Settings → Recovery → Advanced startup → Restart now; or hold **Shift** while clicking Restart; or installation/recovery USB. BitLocker devices prompt for the **recovery key** — owner must have it (never share it with the assistant).

Tools under Troubleshoot → Advanced options:

- **Uninstall Updates** → *Uninstall latest quality update* or *Uninstall latest feature update* (feature entry may be hidden by policy/version). Reboot and retest.
- **Startup Repair** (collect the `C:\Windows\System32\Logfiles\Srt\SrtTrail.txt` it produces).
- **System Restore** (if a restore point exists; not a build rollback).
- **Command Prompt** for evidence preservation and DISM against the offline OS (`DISM /Image:C:\ /Get-Packages`, where C: is the offline Windows under WinRE — verify letter with `diskpart list volumes` first because WinRE letters shift).
- Startup Settings → Safe Mode for driver/filter cleanup if the system boots there.
- Reset this PC: last resort before clean install; explain keep-files vs remove-all and app loss.

## D. Uninstalling an update that broke a booting system

- Settings → Windows Update → Update history → **Uninstall updates** (removable KBs only; SSUs and some updates can't be removed; `wusa /uninstall /kb:` often no longer applies to combined SSU+LCU packages).
- If removed update keeps returning: pause updates (up to 35 days) or hide via Show/Hide updates tool; check "Get the latest updates as soon as they're available" state; enterprise → admin ring deferral.
- Removing a security update widens exposure: pair it with a mitigation plan or Microsoft's known-issue guidance.

## E. Restore points and imaging

- Feature upgrades remove existing restore checkpoints by design; do not expect System Restore to undo an upgrade.
- Before risky repairs (filter removal, BCD work, package surgery), create a restore point if enabled and preferably a file/image backup the user can verify. Record what was changed for reversibility.
- BitLocker: any boot/firmware/recovery work needs the recovery key available to the OWNER. Suspension during upgrades is normal; verify protection state after (`manage-bde -status`, approval for changes).
