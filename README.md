# Device Migration Toolkit

One tool for the Workspace ONE (+ SCCM + Active Directory) to Entra ID / Intune move, plus the Autopilot hash workflow that used to live in the USB Tools scripts. Windows PowerShell 5.1, no installation.

## Run it

Copy the folder to a local drive (for example `C:\MigrationToolkit`), then double-click `Start-MigrationToolkit.cmd` (it asks for admin), or from an elevated prompt:

```powershell
.\MigrationToolkit.ps1                          # GUI
.\MigrationToolkit.ps1 -Action Preflight        # read-only report
.\MigrationToolkit.ps1 -Action RunPhase -DryRun # preview the whole automatic run, nothing changes
.\MigrationToolkit.ps1 -Action RunPhase -GroupTag 'AutoPilot-Shared-FacStaff'   # run the next phase
.\MigrationToolkit.ps1 -Action AddGroupTag -GroupTag 'Lab-Shared 2026'
.\MigrationToolkit.ps1 -Action CaptureHash -GroupTag 'Lab-Shared 2026'
.\MigrationToolkit.ps1 -Action MergeCsv -Folder E:\Hashes
```

Tick **Dry run** in the GUI (or pass `-DryRun`) to log what each step would do without changing anything. Put `Profwiz.exe` / `MCPR.exe` in `Tools\`. Built-in group tags, the temporary admin name and the debloat list are in `Config\toolkit.json`. Logs are in `C:\ProgramData\MigrationToolkit\Logs`; step results and automatic-run progress survive reboots in `state.json` and `runplan.json` there.

## Automatic run (the Play button)

The **Automatic run** page does everything it can in order. A phase ends where Windows needs a restart or a new sign-in, progress is saved, and you press the button again to continue.

| Phase | What it does | Ends with |
|---|---|---|
| **1. Prepare and leave the old environment** | Temporary local admin (only if none exists), pre-flight checks, hardware-hash capture (+ optional Autopilot upload), remove Workspace ONE, remove SCCM, leave Active Directory | Restart |
| **2. Join Entra ID and enroll in Intune** | Entra join, verify Intune enrollment, BitLocker key escrow | Sign in as the new user |
| **3. Finish** | Profile Wizard (you finish it by hand), remove preinstalled apps, optionally remove the temporary admin | Done |

Behaviour that makes it safe to leave running:

- Everything is validated **before** the first change (AD credentials, local admin, group tag), so it cannot get half-way and then discover a missing input.
- A required step that fails stops the run with the reason; optional steps (hash, upload, apps, Profile Wizard) warn and continue. Starting again skips the steps that already finished.
- It confirms by asking you to type the computer name, and shows the name and serial in the header and in every log.
- **Dry run** walks all three phases and changes nothing (it writes a separate preview plan file).
- Credentials and the temporary-admin password are held in memory for that run only; the saved plan contains no secrets.

## Group tags

Pick one from the list or press **New tag**. New tags are validated (letters, numbers, spaces, `- _ .`, up to 128 characters), de-duplicated ignoring case, and saved to `Config\grouptags.user.json` (or `C:\ProgramData\MigrationToolkit` if the toolkit folder is read-only) so they appear in every list. The tag is written into each captured CSV and checked again when CSVs are merged or uploaded. Built-in tags live in `Config\toolkit.json`; only tags you added can be deleted.

## Safety model: this device only

- No function takes a computer name, opens a remote session or uses `-ComputerName` / `Invoke-Command`; every action targets the machine it runs on. `Remove-Computer` is deliberately called without `-ComputerName`.
- Actions that change the device are **refused** in a remote PowerShell session and when the toolkit is run from a network location (UNC path or mapped drive). Copy it to a local disk first.
- Domain credentials are used once, for this computer's own AD object, and never stored. **Offline unjoin** needs no credentials at all. Pre-flight warns when you are signed in with a domain account, because that profile stops working after the unjoin.
- The saved run plan is tied to this device's MachineGuid and is ignored if the folder or state is copied to another device. `-ExpectSerial` lets a script refuse to run on the wrong machine.
- The Intune upload sends only the devices in the CSV you choose; duplicate checks match the serial number exactly.
- It will not touch accounts or keys it did not create: the temporary admin must carry the toolkit's marker description to be reset or deleted (`Administrator`, `Guest` and similar names are rejected), the MDM cleanup refuses the Intune enrollment, and config-driven cleanup paths are limited to vendor keys under `HKLM:\SOFTWARE` and folders under ProgramData / Program Files (never `Microsoft`, `Windows`, or a drive root).

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

Written and statically reviewed on a Mac. **It has not been run on Windows.** What was machine-checked: both scripts parse, PSScriptAnalyzer reports no errors, the custom-control C# parses as C# 5, and the phased-run engine and group-tag logic were exercised with mocked Windows calls (pause and resume across restarts, failure stops and resume skips finished steps, validation before any change, device-lock on the saved plan, dry run changes nothing, no secrets saved). What was **not** checked: the WinForms layout and look (never rendered), and every real Windows call. Please run in this order on a spare VM or pilot laptop:

1. Open the GUI and check it renders; run `-Action Preflight`, then the **Automatic run** with Dry run ticked
2. Hash capture, new group tag and merge (no side effects)
3. The real automatic run on one sacrificial device: Phase 1, restart, Phase 2, sign-in, Phase 3

Not independently verifiable from here:

- **Graph upload**: endpoints, the `groupTag` field on `importedWindowsAutopilotDeviceIdentity`, and the Graph beta API are from memory of the public docs. Confirm with one device first.
- **WS1 unenroll**: the tool first asks Windows to unenroll (`UnregisterDeviceWithManagement` in `mdmregistration.dll`) and only falls back to deleting registry keys and tasks (community practice, not a VMware procedure, and policies pushed by WS1 can linger). The unenroll call has not been tested against a real WS1 enrollment. Name matching (`*Workspace ONE*`, `*AirWatch*`, plus Store-app packages) is a best guess for newer, rebranded Hub builds. Retire the device in the WS1 console as well.
- **Profwiz**: the freeware edition is GUI only, so that step launches it; you finish the wizard by hand.
- **Silent Entra join** via `.ppkg` and the `ms-settings:workplace` flow depend on your tenant settings (join permissions, MDM user scope, Intune licence).
