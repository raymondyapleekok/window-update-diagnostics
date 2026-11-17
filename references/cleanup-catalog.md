# Cleanup catalog (whitelist, approval per item)

Housekeeping ONLY from this list, each item approved individually, each with its plain-language line shown to the user. Timing tags: **[Fix]** = legitimate part of a repair variable; **[After-success]** = only once the original problem is verified fixed. Every item: reversible method first (rename/move/backup-export), verify after, and record in the change log. Never outside this list; no registry cleaners, tune-up tools, or "optimizer" suites ever.

## Drivers and devices
- **Orphan third-party driver packages** **[Fix]** — `get-orphan-driver-cleanup-plan.ps1` (plan/backup) + curated `pnputil /delete-driver oemN.inf /uninstall`; verify with connected-device re-check; restore via `pnputil /add-driver`. Plain: "Old hardware memories Windows carries into every upgrade; we delete only memories of hardware that is gone."
- **Orphan filter/boot drivers from uninstalled products** **[Fix]** — `remove-orphan-filter-driver.ps1`. Plain: "A program was removed but left a core piece loaded at startup; we clear the leftover safely, keeping backups."
- **Ghost (non-present) device nodes** — optional **[After-success]**; `pnputil /remove-device "<instance-id>"` only for clearly removed devices; default leave-alone (harmless). Plain: "Remembered USB devices; harmless, deleting only tidies the list."

## Update servicing leftovers
- **`.bak-*` update caches** created by repair scripts **[After-success]** — delete `SoftwareDistribution\DataStore.bak-*`, `Download.bak-*`, `catroot2.bak-*` after ≥1 successful update cycle. Plain: "Spare copies of Windows Update's notebooks made while fixing it; safe to discard now that it behaves."
- **Windows Update cleanup + Delivery Optimization cache** **[After-success]** — Settings → Storage → Temporary files → Windows Update Cleanup (or `cleanmgr`). Plain: "Old installer copies Windows kept in case you needed them."
- **Component store superseded components** **[After-success]** — `DISM /Online /Cleanup-Image /StartComponentCleanup`; `/ResetBase` only with explicit warning it removes the ability to uninstall current updates; NEVER while a problem is open. Plain: "Pruning the parts warehouse; frees space but removes the 'go back to older part' option."
- **`Windows.old` / `$WINDOWS.~BT`** **[After-success + user decision]** — keeps the ~10-day "go back" door and the failure evidence; delete only when user declines rollback AND evidence is archived. Plain: "The folder that lets Windows back out of the upgrade; deleting it closes the exit door."
- **Old failed attempt evidence bundles** **[After-success]** — keep ONE final hashed bundle; delete duplicates/temp copies only with user consent. Plain: "Keep one complete case file; discard the photocopies."

## Software leftovers
- **Uninstalled-product folders** (`Program Files`, `ProgramData`) **[After-success]** — confirm product really gone; MOVE to quarantine folder, reboot once, delete after confirming no complaints. Plain: "Boxes an uninstalled program left in the attic; we put them aside and watch before throwing away."
- **Startup entries / scheduled tasks pointing to missing files** **[After-success]** — list `Win32_StartupCommand` + Run keys; disable first, delete only after a clean boot cycle. Plain: "Shortcuts that open doors to rooms that no longer exist."
- **Services with Start=auto from removed products** **[After-success]** — note: many are driver services; only non-driver orphan services via `sc.exe qc` review + delete with backup of the key. Driver services → driver tools above only.

## System hygiene
- **Temp files** **[After-success]** — user `%temp%`, `C:\Windows\Temp` via Disk Cleanup/Storage Sense. Plain: "Scratch files programs drop while working."
- **Prefetch — do NOT delete** (myth): Windows self-manages; deleting slows next boots. Say so if asked.
- **Restore points** **[After-success]** — `wmic.exe /Namespace:\\root\default Path SystemRestore Call CreateRestorePoint "post-repair"` then Disk Cleanup "More Options → System Restore" to prune old ones (keeps newest). Plain: "Take one fresh snapshot, discard the old clutter."
- **Re-enable/restore diagnostics** **[After-success]** — msconfig normal startup, startup items, disabled services, crash-capture revert, reinstalled security product. Plain: "Take the training wheels off and make sure protection is back on."

## Presentation format for each offer
`<item>` — what it is (technical) / "In plain terms: …" / size or count found / benefit / risk / reversibility / [Approve? Y/N]. Batch trivial same-category items into one approval. Log every yes/no decision.
