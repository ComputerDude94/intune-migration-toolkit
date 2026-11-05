# Device Migration Toolkit

PowerShell 5.1 tool for the Workspace ONE (+ SCCM + AD) to Entra ID / Intune move, plus the Autopilot hash workflow. Entry points: `MigrationToolkit.ps1` (GUI and `-Action`s), `Start-MigrationToolkit.cmd`; code in `Modules/`, settings in `Config/toolkit.json`. Read `README.md` first.

- Must stay Windows PowerShell 5.1 compatible (no PS7-only syntax).
- Checks: `Tests/Engine.Tests.ps1` (mocked, runs anywhere) and `.github/workflows/checks.yml` (parse check, PSScriptAnalyzer, tests on every push). Run them before committing.
- `-DryRun` and `-Action Preflight` must stay read-only. Any new destructive step needs a dry-run path.
- The WS1 unenroll path has not been tested against a real enrollment (see README); say so rather than claiming it works.
- `Output/` holds run output; don't commit device data or hashes.
