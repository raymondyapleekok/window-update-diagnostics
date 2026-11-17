# Windows Update and servicing internals

## Main components

- **Windows Update service (`wuauserv`)**: detection/download/install coordination. Manual/trigger-start; stopped is often normal.
- **BITS (`bits`)**: background transfers; not every download path uses BITS.
- **Cryptographic Services (`cryptsvc`)**: catalog/signature functions; owns `catroot2`.
- **Update Orchestrator (`UsoSvc`)** and `MoUsoCoreWorker.exe`: schedules and sequences update sessions; logs to `C:\ProgramData\USOShared\Logs\UpdateSessionOrchestration.etl`.
- **Windows Update Medic (`WaaSMedicSvc`)** + `WaaSMedicAgent.exe`: remediation of the update stack. Never disable; never edit its `Start` value or ACLs. Settings → "Restart now"-style repairs use it. Service may legitimately show STOPPED.
- **Update Stack / MoSetup**: `setup.exe` ↔ Windows Update communication; `C:\Windows\Logs\MoSetup\BlueBox.log` records Installation Assistant / feature-update handoff (also for `0xC1900107`).
- **Component-Based Servicing (CBS)** and **TiWorker/TrustedInstaller**: package install, component store (`WinSxS`) maintenance; log `%windir%\Logs\CBS\CBS.log`.
- **DISM**: image/component-store servicing; log `%windir%\Logs\DISM\dism.log`.
- **Windows Error Reporting / SetupReport**: bugcheck collection during setup.

Do not force services to Automatic or disable them based on generic internet advice; a stopped trigger-started service is not a fault.

## Cache and data locations

- `%windir%\SoftwareDistribution` (`DataStore`, `Download`): scan/download metadata/content.
- `%ALLUSERSPROFILE%\Application Data\Microsoft\Network\Downloader\qmgr*.dat`: BITS transfer queue.
- `%windir%\System32\catroot2`: catalog database (cryptsvc).
- `%windir%\WinSxS`: component store — never manually delete.
- `%windir%\Logs\CBS`, `%windir%\Logs\DISM`, `%windir%\Logs\MoSetup`, `C:\ProgramData\USOShared\Logs`.
- `pending.xml` / `RebootPending` / `PendingFileRenameOperations`: servicing clues, not proof of an error; never delete `pending.xml` as a "fix".

## Health and repair commands

Read-only checks (run first):

```text
DISM /Online /Cleanup-Image /CheckHealth
DISM /Online /Cleanup-Image /ScanHealth
sfc /verifyonly
```

Repairs (explicit approval):

```text
DISM /Online /Cleanup-Image /RestoreHealth
sfc /scannow
```

- RestoreHealth normally pulls repair files from Windows Update. If it fails with `0x800f081f` (CBS_E_SOURCE_MISSING), use a repair source: same product family, release, language, architecture, and update level ≥ target. Prefer RTM/current ISO `install.wim`:

```text
DISM /Get-WimInfo /WimFile:X:\sources\install.wim
DISM /Online /Cleanup-Image /RestoreHealth /Source:WIM:X:\sources\install.wim:INDEX /LimitAccess
```

  `install.esd` uses the `ESD:` prefix (and may refuse; `install.wim` media is the documented source format). A shared `\\server\c$\windows` from a matching running OS also works with `/LimitAccess`.
- After DISM succeeds, run `sfc /scannow`, then recheck and retry the original update.
- Component-store cleanup (`StartComponentCleanup`, `/ResetBase`) removes superseded/in-flight packages and thereby removes the ability to uninstall updates. Do not run while troubleshooting a pending update problem.

## Version data and servicing currency (read the right key)

On Windows 10/11 the authoritative version data is `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion`: `CurrentBuild`, `UBR`, `DisplayVersion`, `ReleaseId`, `InstallDate`, `ProductName`. `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion` legitimately lacks DisplayVersion/UBR on modern builds — absence there is NOT corruption. `ProductName` still reading "Windows 10 Home" on a Windows 11 box is a normal in-place-upgrade artifact but does reveal upgrade lineage.

- **Servicing Stack Updates (SSU)** are bundled into monthly LCU packages; the installed SSU level comes with the latest applied LCU (check `Get-HotFix` dates / `DISM /Online /Get-Packages`). A stale SSU is documented to cause update *installation* failures and boot-loop risk — relevant to quality-update errors, NOT to a driver-migration second-boot rollback (`0xC1900101-0x40017`). Feature-update setup carries its own new servicing into the target OS.
- **End-of-support branches are frozen**: after EOL (e.g., Win11 23H2 on 2025-11-12), Windows Update stops offering LCUs; the last patch stays forever. "My updates are N months/years old" is expected there; the security implication is real, but "install all updates first" cannot be the rollback fix. Latest SSU/LCU, if specifically needed, come from the Microsoft Update Catalog (or are already inside a current ISO).
- **Multi-generation driver inheritance**: a years-old OS that itself arrived by in-place upgrade accumulates third-party drivers across releases (`pnputil /enum-drivers`, DriverStore file CreationTimes). This inherited stack — not the Windows version alone — is what feature-update migration processes, and where 0xC1900101 suspects live.

## Update detection and control (safe, official)

- Detection-only scan without installing, elevated:

```powershell
$u = New-Object -ComObject Microsoft.Update.Session
$searcher = $u.CreateUpdateSearcher()
$searcher.Search("IsInstalled=0").Updates | Select-Object Title, IsDownloaded
```

- `UsoClient.exe StartScan` / `StartDownload` / `StartInstall` / `StartInteractiveScan` (elevated) drive the orchestrator's normal cycles; they are not "reset" magic.
- Update history in Settings shows user-visible state; `Get-HotFix` is NOT a complete package inventory. Full package list: `DISM /Online /Get-Packages /Format:Table`. Uninstall by exact identity: `DISM /Online /Remove-Package /PackageName:...` (evidence + approval; some SSUs are non-removable).

## Reboot and servicing state indicators

```text
HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending
HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired
HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager : PendingFileRenameOperations
```

These are clues; combine with CBS/DISM logs before claiming a stuck transaction.

## Managed devices

Check policy sources before "fixing" anything: `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` (WSUS/DoNotConnect...), MDM/Intune update rings, domain GPO. A Home-edition machine is usually unmanaged, but `sc.exe query wuauserv` plus policy keys prove it. Do not delete policy keys to force updates; refer organisation-managed devices to the administrator.
