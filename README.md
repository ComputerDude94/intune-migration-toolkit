# Device Migration Toolkit

One tool for the Workspace ONE (+ SCCM + Active Directory) to Entra ID / Intune move, plus the Autopilot hash workflow that used to live in the USB Tools scripts. Windows PowerShell 5.1, no installation.

## Run it

Double-click `Start-MigrationToolkit.cmd` (it asks for admin), or from an elevated prompt:

```powershell
.\MigrationToolkit.ps1                          # GUI
.\MigrationToolkit.ps1 -Action Preflight        # read-only report
.\MigrationToolkit.ps1 -Action RemoveWS1 -DryRun
.\MigrationToolkit.ps1 -Action CaptureHash -GroupTag 'AutoPilot-Shared-FacStaff'
.\MigrationToolkit.ps1 -Action MergeCsv -Folder E:\Hashes
```

Tick **Dry run** in the GUI (or pass `-DryRun`) to log what each step would do without changing anything. Put `Profwiz.exe` / `MCPR.exe` in `Tools\`. Group tags, the temporary admin name and the debloat list are in `Config\toolkit.json`. Logs are in `C:\ProgramData\MigrationToolkit\Logs`; step results survive reboots in `state.json` there.

## Two ways to get a device into Intune

| Path | Steps |
|---|---|
| **In place** (what the old tool did) | Pre-flight, remove WS1, remove SCCM, unjoin AD, restart, join Entra, verify Intune, Profwiz, cleanup |
| **Autopilot reset** | Capture hash, merge, upload to Intune, assign a profile, then reset the device and let Autopilot enrol it |

Hash upload is only needed for the Autopilot path. An in-place Entra join does not need it.

## What changed from the original scripts

| Original | Problem | Now |
|---|---|---|
| Launcher pipe progress | The server read one line and quit, so only the first status ever arrived; the child ran hidden, so credential prompts could be lost | Actions run in-process on a background runspace and stream to a live log |
| `OnPremRelease` | Put the AD password in a PowerShell command line (visible in process list; breaks on `'` in a password) | Credential object stays in memory and goes straight to `Remove-Computer` |
| `OnPremRelease` | Forced a restart; never checked a local admin exists (lock-out risk) | Refuses to unjoin without an enabled local admin; restart is offered, cancellable |
| `OnPremRelease` | Hub uninstall only; the MDM enrollment, tasks and registry stay behind | Also removes the leftover WS1 enrollment, tasks and keys, then verifies |
| `OnPremRelease` | Did not handle hybrid-joined devices | Runs `dsregcmd /leave` when needed |
| `JoinEntra` | Slept 30 s and assumed success | Polls `dsregcmd` until the join is confirmed (or times out) |
| Consolidate scripts | Re-read the previous `Consolidated*.csv` plus per-device files, so devices duplicated | Ignores `Consolidated*`, validates base64 hash, de-duplicates by serial |
| `GetHash` | `Get-ScriptDrive` breaks on UNC paths; per-device file named by hostname (`DESKTOP-xxxx`, not unique); needs the gallery and NuGet | Reads the hash from WMI directly; file named by serial |
| `GetHash2.Cmd` | `timeout \t 2` typo | Gone |
| Debloat | `Remove-AppxProvisionedPackage -PackagePath` is the wrong parameter; Teams entry used a package family name against `.Name` so it never matched; a mistyped Lenovo name | `-PackageName`, matches name or family name, names fixed |
| EXEs | Run blind | Signature and SHA-256 logged first; MCPR refused if unsigned |

New: pre-flight report, Graph upload to Autopilot with per-device result polling, Autopilot sync, Intune / Autopilot device lookup, forced MDM enrollment, BitLocker key escrow to Entra, temporary local admin helper, optional `.ppkg` silent join.

## Verification status (read this before using on real devices)

Written and statically reviewed on a Mac. **It has not been run on Windows.** Only bracket balance and the JSON config were machine-checked. Please run in this order on a spare VM or pilot laptop:

1. `-Action Preflight`, then any action with `-DryRun`
2. Hash capture and merge (no side effects)
3. WS1 removal, SCCM removal, unjoin, Entra join on one sacrificial device

Not independently verifiable from here:

- **Graph upload**: endpoints, the `groupTag` field on `importedWindowsAutopilotDeviceIdentity`, and the Graph beta API are from memory of the public docs. Confirm with one device first.
- **WS1 leftover cleanup**: the registry / task list is the community-standard MDM-enrollment cleanup, not a VMware-documented procedure. Retire the device in the WS1 console as well.
- **Profwiz**: the freeware edition is GUI only, so that step launches it; you finish the wizard by hand.
- **Silent Entra join** via `.ppkg` and the `ms-settings:workplace` flow depend on your tenant settings (join permissions, MDM user scope, Intune licence).
