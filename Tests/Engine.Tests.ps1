# Logic tests for the phased run, group tags and safety guards. Windows calls are mocked, so this runs anywhere.
# Usage: powershell -File Tests\Engine.Tests.ps1   (exit code 1 on any failure)
$ErrorActionPreference = 'Stop'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("tk-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
$env:ProgramData = $tmp
$env:COMPUTERNAME = 'TESTPC'; $env:USERDOMAIN = 'CORP'; $env:USERNAME = 'tech'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Modules\MigrationCore.psm1') -Force
$mod = Get-Module MigrationCore
Initialize-Toolkit
$fails = 0
function Invoke-MigrationRun { param([hashtable]$Options = @{}) & $mod { param($o) Invoke-MigrationRun -Options $o } $Options }
function Check($name, $cond) { if ($cond) { "PASS  $name" } else { "FAIL  $name"; $script:fails++ } }

# ---- group tags (user tag file lands in repo Config; use a copy of the module root instead)
& $mod { function script:Get-UserTagPath { @((Join-Path $env:ProgramData 'a\g.json'), (Join-Path $env:ProgramData 'b\g.json')) } }
Check 'builtin tags listed' ((Get-GroupTagList).Count -eq 4)
Check 'valid name accepted' (-not (Test-GroupTagName 'Lab-Shared 2026'))
Check 'empty rejected' [bool](Test-GroupTagName '')
Check 'comma rejected' [bool](Test-GroupTagName 'a,b')
Check 'leading space/symbol rejected' [bool](Test-GroupTagName '-bad')
Check 'long rejected' [bool](Test-GroupTagName ('x' * 129))
[void](Add-GroupTag -Name 'Lab-Shared 2026')
Check 'new tag listed' ((Get-GroupTagList) -contains 'Lab-Shared 2026')
[void](Add-GroupTag -Name 'lab-shared 2026')
Check 'case-insensitive dup not added' ((@(Get-GroupTagList) | ? { $_ -ieq 'lab-shared 2026' }).Count -eq 1)
$threw = $false; try { Remove-GroupTag -Name 'AutoPilot-Shared-FacStaff' } catch { $threw = $true }
Check 'built-in tag removal refused' $threw
Remove-GroupTag -Name 'Lab-Shared 2026'
Check 'user tag removed' ((Get-GroupTagList) -notcontains 'Lab-Shared 2026')
$threw = $false; try { Add-GroupTag -Name 'bad,tag' } catch { $threw = $true }
Check 'invalid add throws' $threw

# ---- cleanup path guard
foreach ($c in @(@('HKLM:\SOFTWARE\AirWatch',$true), @('HKLM:\SOFTWARE\WOW6432Node\AirWatch',$true), @('HKLM:\SOFTWARE\Microsoft',$false), @('HKLM:\SOFTWARE\Microsoft\Windows',$false),
                 @('HKLM:\SOFTWARE',$false), @('HKLM:\SYSTEM\CurrentControlSet',$false), @('HKLM:\SOFTWARE\Air*',$false), @('',$false))) {
    Check ("path guard: $($c[0])") ((& $mod { param($p) Test-SafeCleanupPath $p } $c[0]) -eq $c[1])
}

# ---- engine with mocked Windows pieces
& $mod {
    function script:Test-IsAdmin { $true }
    function script:Get-JoinState { [pscustomobject]@{ AzureAdJoined = $script:Mock.Entra; DomainJoined = $script:Mock.Domain; WorkplaceJoined=$false; TenantName='T'; MdmUrl=''; DomainName='corp.local' } }
    function script:Get-LocalAdminCandidate { if ($script:Mock.AdminMade) { @('MigAdmin') } else { @() } }
    function script:Get-PreflightReport { $la = 'Pass'; if (-not $script:Mock.AdminMade) { $la = 'Fail' }; @([pscustomobject]@{Name='x';Status='Pass';Detail='ok'}, [pscustomobject]@{Name='Local administrator exists';Status=$la;Detail='n'}, [pscustomobject]@{Name='Power';Status='Warn';Detail='battery'}) }
    function script:Get-WorkspaceOneInventory { [pscustomobject]@{ Programs=@(1); Appx=@(); Enrollments=@() } }
    function script:Get-AutopilotHardwareInfo { [pscustomobject]@{ Serial='SN1'; ProductId=''; Hash='QUJD' } }
    function script:Get-HashCsvPath { param($OutputFolder) Join-Path $OutputFolder 'SN1_AutoPilotSetup.csv' }
    function script:New-ToolkitLocalAdmin { param($Password) $script:Mock.AdminMade = $true }
    function script:Remove-WorkspaceOne { Set-StepState 'RemoveWS1' 'Done' }
    function script:Remove-SccmClient { if ($script:Mock.SccmFail) { Set-StepState 'RemoveSCCM' 'Failed' 'boom' } else { Set-StepState 'RemoveSCCM' 'Skipped' 'Not present' } }
    function script:Invoke-DomainUnjoin { param($Credential, [switch]$OfflineUnjoin) $script:Mock.UnjoinCalled++; Set-StepState 'UnjoinAD' 'Done' 'Restart required'; $script:Mock.Domain = $false }
    function script:Start-EntraJoin { Set-StepState 'JoinEntra' 'Done' 'T'; $script:Mock.Entra = $true }
    function script:Complete-IntuneVerification { Set-StepState 'VerifyIntune' 'Done' }
    function script:Start-ProfileWizard { Set-StepState 'ProfileWizard' 'Done' }
    function script:Invoke-Debloat { Set-StepState 'Cleanup' 'Done' }
    function script:Remove-ToolkitLocalAdmin { }
    function script:Get-DataAtRiskReport { @([pscustomobject]@{Name='Data at risk';Status='Warn';Detail='x'}) }
    function script:Initialize-BitLockerKey { $script:Mock.BlPrep++; 'ok' }
    function script:New-MigrationReport { 'report.txt' }
    function script:Test-WorkspaceOneRemoval { param([switch]$Clean) if ($script:Mock.Residue) { @([pscustomobject]@{Name='Workspace ONE removal';Status='Fail';Detail='n'}, [pscustomobject]@{Name='Service';Status='Fail';Detail='AWService'}) } else { @([pscustomobject]@{Name='Workspace ONE removal';Status='Pass';Detail='clean'}) } }
    function script:Get-LocalUser { param($Name) $null }
    $script:Mock = @{ BlPrep = 0; Residue = $false; Entra = $false; Domain = $true; SccmFail = $true; UnjoinCalled = 0; AdminMade = $false }
}
$out = Join-Path $tmp 'hash'
$cred = New-Object pscredential('CORP\admin', (ConvertTo-SecureString 'x' -AsPlainText -Force))
$pw = ConvertTo-SecureString 'y' -AsPlainText -Force

# validation: domain joined without creds
Set-ToolkitDryRun $false
$threw = $false; try { Invoke-MigrationRun -Options @{ GroupTag='AutoPilot-Shared-FacStaff'; OutputFolder=$out } } catch { $threw = $_.Exception.Message -like '*domain joined*' }
Check 'refuses domain-joined run without credentials' $threw
$threw = $false; try { Invoke-MigrationRun -Options @{ GroupTag=''; OutputFolder=$out; AdCredential=$cred; AdminPassword=$pw } } catch { $threw = $_.Exception.Message -like '*group tag*' }
Check 'refuses hash capture without a tag' $threw
Check 'no plan saved when validation fails' ($null -eq (Get-RunPlanState))

# run 1: required step (SCCM) fails
$r = Invoke-MigrationRun -Options @{ GroupTag='AutoPilot-Shared-FacStaff'; OutputFolder=$out; AdCredential=$cred; AdminPassword=$pw }
Check 'run1 fails at SCCM' ($r.Status -eq 'Failed' -and $r.NextPhase -eq 1 -and $r.Message -like '*SCCM*')
Check 'unjoin NOT attempted after failure' ($mod.SessionState.PSVariable.Get('Mock').Value.UnjoinCalled -eq 0)
$p = Get-RunPlanState
Check 'plan records failure' ($p.Status -eq 'Failed')
Check 'local admin created before unjoin path' ($mod.SessionState.PSVariable.Get('Mock').Value.AdminMade)

# run 2: fixed -> phase 1 completes, pauses for restart; finished steps not repeated
& $mod { $script:Mock.SccmFail = $false }
$r = Invoke-MigrationRun -Options @{ GroupTag='AutoPilot-Shared-FacStaff'; OutputFolder=$out; AdCredential=$cred; AdminPassword=$pw }
Check 'run2 pauses for restart, next phase 2' ($r.Status -eq 'Paused' -and $r.NextPhase -eq 2 -and $r.RestartNeeded)
Check 'unjoin ran exactly once' ($mod.SessionState.PSVariable.Get('Mock').Value.UnjoinCalled -eq 1)

# run 3: resume with NO credentials -> phase 2 -> pauses for sign-in as new user
$r = Invoke-MigrationRun
Check 'run3 does phase 2 and pauses' ($r.Status -eq 'Paused' -and $r.NextPhase -eq 3)
# run 4: phase 3 completes
$r = Invoke-MigrationRun
Check 'run4 completes' ($r.Status -eq 'Completed')
$p = Get-RunPlanState
Check 'completed plan, all enabled steps finished' ($p.Status -eq 'Completed')
Check 'saved plan holds no secrets' (-not ((Get-Content (Join-Path $tmp 'MigrationToolkit/runplan.json') -Raw) -match 'AdCredential|AdminPassword|CORP\\admin'))

# device lock: plan from another device is ignored
$f = Join-Path $tmp 'MigrationToolkit/runplan.json'
$j = Get-Content $f -Raw | ConvertFrom-Json; $j.Status = 'Paused'; $j.Phase = 2; $j.Device.MachineGuid = 'OTHER-DEVICE'; $j | ConvertTo-Json -Depth 6 | Set-Content $f
& $mod { function script:Get-ToolkitTarget { [pscustomobject]@{ ComputerName='TESTPC'; Serial='SN1'; MachineGuid='THIS-DEVICE'; User='CORP\tech'; NetworkAccount=$true } } }
& $mod { $script:Mock.Domain = $true; $script:Mock.Entra = $false; $script:Mock.UnjoinCalled = 0 }
$r = Invoke-MigrationRun -Options @{ GroupTag='AutoPilot-Shared-FacStaff'; OutputFolder=$out; AdCredential=$cred; AdminPassword=$pw }
Check 'foreign plan ignored: restarts at phase 1' ($r.Status -eq 'Paused' -and $r.NextPhase -eq 2 -and $mod.SessionState.PSVariable.Get('Mock').Value.UnjoinCalled -eq 1)

# dry run walks all three phases, changes nothing
Clear-RunPlanState
& $mod { $script:Mock.Domain = $true; $script:Mock.Entra = $false; $script:Mock.UnjoinCalled = 0; $script:Mock.AdminMade = $false }
Remove-Item (Join-Path $tmp 'MigrationToolkit/state.json') -ErrorAction SilentlyContinue
Set-ToolkitDryRun $true
$r = Invoke-MigrationRun -Options @{ GroupTag='AutoPilot-Shared-FacStaff'; OutputFolder=$out }
Set-ToolkitDryRun $false
Check 'dry run completes all phases' ($r.Status -eq 'Completed')
Check 'dry run made no admin / state' (-not $mod.SessionState.PSVariable.Get('Mock').Value.AdminMade -and -not (Test-Path (Join-Path $tmp 'MigrationToolkit/state.json')))
Check 'dry run does not touch the real plan file' (-not (Test-Path (Join-Path $tmp 'MigrationToolkit/runplan.json')))


# ---- WS1 removal gate in phase 2
Clear-RunPlanState
& $mod { $script:Mock.Domain = $false; $script:Mock.Entra = $false; $script:Mock.Residue = $true; $script:Mock.AdminMade = $false }
Remove-Item (Join-Path $tmp 'MigrationToolkit/state.json') -ErrorAction SilentlyContinue
$r1 = Invoke-MigrationRun -Options @{ GroupTag='AutoPilot-Shared-FacStaff'; OutputFolder=$out }
Check 'not-domain run reaches phase 1 pause' ($r1.Status -eq 'Paused' -and $r1.NextPhase -eq 2)
$r2 = Invoke-MigrationRun
Check 'phase 2 stops when WS1 residue remains' ($r2.Status -eq 'Failed' -and $r2.Message -like '*not fully removed*Service*')
Check 'join not attempted while WS1 remains' (-not $mod.SessionState.PSVariable.Get('Mock').Value.Entra)
& $mod { $script:Mock.Residue = $false }
$r3 = Invoke-MigrationRun
Check 'phase 2 continues once WS1 is clean' ($r3.Status -eq 'Paused' -and $r3.NextPhase -eq 3)
Check 'BitLocker prep ran in phase 1' ($mod.SessionState.PSVariable.Get('Mock').Value.BlPrep -ge 1)

# ---- WS1 program matching by name or publisher
& $mod { function script:Get-InstalledProgram { param($NamePattern)
    @([pscustomobject]@{DisplayName='VMware Workspace ONE Intelligent Hub';Publisher='VMware, Inc.';Version='1'},
      [pscustomobject]@{DisplayName='Omnissa Workspace ONE Intelligent Hub';Publisher='Omnissa, LLC';Version='2'},
      [pscustomobject]@{DisplayName='Agent';Publisher='AirWatch LLC';Version='3'},
      [pscustomobject]@{DisplayName='VMware Tools';Publisher='VMware, Inc.';Version='12'},
      [pscustomobject]@{DisplayName='Google Chrome';Publisher='Google LLC';Version='9'}) } }
$m = @(& $mod { Get-WorkspaceOneProgram } | ForEach-Object { $_.DisplayName })
Check 'matches rebranded Hub and AirWatch-publisher agent' ($m.Count -eq 3 -and $m -contains 'Agent')
Check 'does not match VMware Tools or Chrome' ($m -notcontains 'VMware Tools' -and $m -notcontains 'Google Chrome')


# ---- timing
Check 'default estimate present' ((Get-StepEstimate).RemoveWS1 -eq 300)
Check 'duration format' ((Format-Duration 65) -eq '1:05' -and (Format-Duration 3725) -eq '1:02:05')
& $mod { Save-StepTiming -Id 'RemoveWS1' -Seconds 100; Save-StepTiming -Id 'RemoveWS1' -Seconds 200; Save-StepTiming -Id 'RemoveWS1' -Seconds 400 }
Check 'estimate becomes median of past runs' ((Get-StepEstimate).RemoveWS1 -eq 200)
$p = Get-RunPlanState
Check 'plan records seconds per step' ($null -ne $p.Steps[0].Seconds)

# scope guard
"`nFAILURES: $fails"
Remove-Item $tmp -Recurse -Force
if ($fails -gt 0) { exit 1 }
