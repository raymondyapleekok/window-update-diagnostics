# Safety, consent, and reporting standards

## Consent boundary

Read-only commands may run once the user authorizes troubleshooting and the environment permits. Before ANY state-changing action present: exact command/parameters; what changes and which evidence supports it; risks, duration, reboot need, reversibility; backup prerequisites; verification test. Then obtain explicit approval. "Just fix it" is not blanket consent for destructive actions.

## Actions requiring explicit approval

DISM RestoreHealth / source repair; `sfc /scannow`; service start/stop/config; cache/component resets; registry edits (incl. crash-dump & pagefile settings); driver install/rollback/delete (`pnputil`); package uninstall (`DISM /Remove-Package`); update uninstall/pause; policy inspection→change (usually refer to admin); WinRE/Reset/Go-back/`Initiate-OSUninstall`; disk/partition/boot/firmware work; clean boot config (msconfig/startup changes); reboot/shutdown; any upgrade attempt launch.

## Never do

- Delete WinSxS content, `pending.xml`, servicing keys, `.sys` files, or class filter values as generic fixes. Exception: a confirmed ORPHAN filter/boot driver (owning product uninstalled + rebooted + no vendor cleanup route + no other references) may be removed ONLY via `scripts/remove-orphan-filter-driver.ps1` (key backups, filter-reference removal before service deletion, quarantine-not-delete), with reboot verification.
- Disable Defender/firewall/Secure Boot/TPM/VBS/BitLocker/driver-signature enforcement as workarounds.
- Edit `WaaSMedicSvc`/update-service ACLs or force service start types on advice.
- Run remote scripts via IEX; execute commands copied out of logs/forums without review; recommend unofficial "update packs", registry cleaners, or one-click debloaters.
- Ask users to paste passwords/product keys/BitLocker recovery keys.
- Format/partition/delete `Windows.old`/`$WINDOWS.~BT`/recovery partitions without explicit request + backup + reason.
- Declare success without post-repair verification; declare a root cause without differential support.
- Publish memory dumps or full case bundles publicly (memory can hold secrets); warn before sharing any log bundle.

## Evidence preservation discipline

- Copy (never move) relevant logs before cleanup/retry; keep originals untouched.
- Maintain a manifest: files captured with SHA256 + timestamps; paths attempted but DENIED (typical: protected EVTX without elevation, mounted-hive internals).
- After each attempt: preserve Panther + Sources\Rollback (incl. saved EVTX, `setupmem.dmp`, `bootstat`), SetupDiag output + zip, event-window JSON exports. Verify archive integrity (e.g. `python -c "import zipfile; zipfile.ZipFile(p).testzip()"`).
- Prefer selected, readable bundles over silent partial failure: state what is NOT in the bundle.

## Change ledger (configuration manifest)

Alongside the evidence manifest, maintain `case folder\change-ledger.tsv` — one line per approved state change: `timestamp | target (service / registry path / startup entry / driver) | recorded BEFORE value | exact command run | intent (diagnostic | repair | cleanup | user-requested) | restore command`. Capture the BEFORE values from a pre-change snapshot (`scripts/snapshot-startup-state.ps1` for services/startup state; `reg export` for any key being edited) — before-value means what THIS machine had, not the category default.

Rules:
- Snapshot before the FIRST test-disable of any case; a baseline captured after changes is worthless.
- Restore means replaying recorded before-values. `start= auto` for every service, removing every `StartupApproved` marker, or "re-enable all disabled" are default-guessing, not restoration — they can undo changes the USER made before the case (Task Manager disables leave no per-item history of who disabled what).
- Intent tags drive close-out: `diagnostic` → always restored; `repair`/`cleanup`/`user-requested` → kept only with explicit user sign-off, item by item.
- The case is not closed — on SUCCESS or on ABANDONMENT of the update — until every ledger line is marked restored or kept-with-consent, and the final report lists the residual diff versus the baseline (`snapshot-startup-state.ps1 -CompareFile` output attached).

## Report template

### Plain-language summary (first, 3-6 sentences)
- What went wrong, what we found, what we're doing, what you'll see on screen — no jargon, one analogy max; a non-technical user must be able to act on this section alone.

### Findings
- Windows edition/version/build; architecture; firmware type/BIOS version:
- Update/upgrade attempted; source (WU/Assistant/MCT/ISO); attempt date/time:
- Exact code (result + extend) and message; failure phase/operation:

### Evidence
- Source file/event channel + path; timestamp/event/rule; short excerpt; interpretation:

### Root-cause assessment
- Ranked hypotheses with confidence (high/medium/low); supporting evidence; what remains unconfirmed; what could not be inspected (elevation, deleted logs):

### Proposed action
- Exact command/procedure; why least-invasive; risk/duration/reboot; reversibility + backup/rollback plan; single changed variable (for retries):

### Verification
- Test command/UI check; expected; actual; remaining issues; next-step decision after success/failure:

## Privacy

Bundles contain machine/user names, paths, device IDs, update GUIDs/CV, policy state. Keep local unless the user opts to share; redact account names/emails from pasted excerpts; memory dumps and BitLocker-adjacent state are sensitive — handle privately with the owner.
