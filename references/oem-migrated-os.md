# Migrated / OEM-lineage OS: extra checks

A Windows install that was cloned from another machine (EaseUS/Acronis/Macrium disk clone), preinstalled by an OEM then moved, or built by stacked in-place upgrades behaves differently in feature-update troubleshooting. Establish the lineage first; it changes candidate ranking and escalation logic.

## Establishing lineage (read-only)

- `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion`: `InstallDate`, `ProductName` (legacy "Windows 10 Home" on Win11 = Win10→11 in-place lineage), `BuildBranch`.
- `C:\Windows\Panther` oldest file dates (original install/upgrade date of THIS OS copy); `C:\Windows.old` presence/absence.
- Activation: `Get-CimInstance SoftwareLicensingProduct` filtered to entries with `PartialProductKey`: channel (RETAIL/OEM/VOLUME) and `LicenseStatus` (1=licensed). Retail/digital-link licenses survive hardware moves; **OEM preinstall licenses do not legally transfer to different hardware** — activation may work but re-arm/support issues follow; never "fix" activation with KMS tools/activators.
- Hardware identity: `HKLM:\HARDWARE\DESCRIPTION\System\BIOS` (SystemManufacturer/SystemProductName) — cloned systems boot fine with foreign SMBIOS strings; mismatch between installed OEM bloatware/services and the current board indicates moved imaging.
- Migration-tool residue: storage filter/services from clone tools (EaseUS `EPMVolFl`/`EUDCPEPM`/`EUEDKEPM`, Acronis `snapdrive`/`flts`, Macrium `PiDriveDrv`...) — check even after app removal; see the orphan path in the playbook.
- Driver generations: elevated `pnputil /enum-drivers` (non-elevated returns nothing) + DriverStore folder dates; ghost devices via `Get-PnpDevice -PresentOnly:$false` (counts by class; heavy ghost DiskDrive/USB sets suggest moved disks/machines, but NVMe/USB re-enumeration ghosts are normal noise — do not over-read).

## Why lineage matters to update failures

1. **Clone without sysprep /generalize** carries the donor machine's driver stack, HAL-independent but driver-heavy: a migrated multi-year OS is a multi-generation DriverStore — the exact pool `0xC1900101` migration phases process. Suspect the *oldest surviving third-party boot drivers* first.
2. **Stacked in-place upgrades** (Win7→8→10→11, or Win10→11 then EOL branch) accumulate leftovers each hop; every further in-place hop re-migrates them. Failure probability compounds.
3. **OEM imaging** (recovery-drive restored systems) can include OEM driver packages and filter tools the user never installed intentionally; check vendor list against the current product.
4. **Escalation shifts**: for a migrated OS with repeated second-boot rollbacks, the spare-clean-disk test and clean install become *higher-value, earlier* options — the OS has never first-booted on this hardware from clean media, so "in-place compatibility" is fundamentally unverified. A repair install helps file corruption but does not cleanse driver lineage.
5. **Activation after hardware moves**: verify status before risky work; document that a clean install on a different/main board may need license purchase/transfer; never ask users for keys, only confirm what channel they own.

## Checklist for the report

State explicitly: lineage (clean install / in-place upgraded / cloned from other PC), license channel + status, migration-tool residue status, oldest third-party DriverStore packages (elevated run), and how lineage adjusts the recommended escalation point.
