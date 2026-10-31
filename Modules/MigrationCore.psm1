# MigrationCore.psm1
# Core logic for the Workspace ONE -> Entra ID / Intune migration toolkit.
# Everything the GUI and the command line do goes through Invoke-ToolkitAction at the bottom,
# so both entry points run exactly the same code. Targets Windows PowerShell 5.1.

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$script:ToolkitRoot = Split-Path -Parent $PSScriptRoot
$script:DataRoot    = Join-Path $env:ProgramData 'MigrationToolkit'
$script:LogDir      = Join-Path $script:DataRoot 'Logs'
$script:StatePath   = Join-Path $script:DataRoot 'state.json'
$script:LogFile     = $null
$script:LogSink     = $null
$script:DryRun      = $false

# ----------------------------------------------------------------------------- logging / state

function Initialize-Toolkit {
    foreach ($d in @($script:DataRoot, $script:LogDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $script:LogFile = Join-Path $script:LogDir ("toolkit-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

function Set-ToolkitLogSink { param($Queue) $script:LogSink = $Queue }
function Set-ToolkitDryRun  { param([bool]$Enabled) $script:DryRun = $Enabled }
function Get-ToolkitRoot    { $script:ToolkitRoot }
function Get-ToolkitLogDir  { $script:LogDir }

function Write-ToolkitLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogFile) { try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch {} }
    if ($script:LogSink) { $script:LogSink.Enqueue($line) } else { Write-Host $line }
}

function Get-ToolkitConfig {
    $default = @{
        groupTags     = @('AutoPilot-Shared-Student Use', 'AutoPilot-Shared-FacStaff', 'AutoPilot-Individual-FacStaff', 'AutoPilot-Individual-Student Use')
        localAdminName = 'MigAdmin'
        workgroupName = 'WORKGROUP'
        ws1Names      = @('Workspace ONE Intelligent Hub*', 'VMware Workspace ONE Intelligent Hub*', 'AirWatch*', 'VMware AirWatch*', 'Workspace ONE*')
        ws1CleanupPaths = @('HKLM:\SOFTWARE\AirWatch', 'HKLM:\SOFTWARE\WOW6432Node\AirWatch', "$env:ProgramData\AirWatch", "$env:ProgramData\VMware\SetupAssistant")
        debloat       = @('Microsoft.Todos', 'Microsoft.BingWeather', 'Microsoft.ZuneVideo', 'MicrosoftTeams', 'Microsoft.ZuneMusic', 'Microsoft.YourPhone',
                          'Microsoft.MicrosoftOfficeHub', 'Microsoft.GamingApp', 'E0469640.SmartAppearance', 'E046963F.LenovoCompanion',
                          'McAfeeWPSSparsePackage', 'Microsoft.Xbox.TCUI', 'Microsoft.XboxGameOverlay', 'Microsoft.XboxGamingOverlay',
                          'LenovoSettingsforEnterprise', 'E0469649.SmartAppearance')
    }
    $path = Join-Path $script:ToolkitRoot 'Config\toolkit.json'
    if (Test-Path $path) {
        try {
            $json = Get-Content $path -Raw | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) { if (-not $p.Name.StartsWith('_')) { $default[$p.Name] = $p.Value } }
        } catch { Write-ToolkitLog "Config\toolkit.json is invalid, using defaults: $($_.Exception.Message)" 'WARN' }
    }
    [pscustomobject]$default
}

function Get-StepState {
    if (Test-Path $script:StatePath) {
        try { return @(Get-Content $script:StatePath -Raw | ConvertFrom-Json) } catch {}
    }
    @()
}

function Set-StepState {
    param([Parameter(Mandatory)][string]$Step, [Parameter(Mandatory)][ValidateSet('Done', 'Failed', 'Skipped', 'DryRun')][string]$Status, [string]$Detail = '')
    if ($script:DryRun) { return }
    $all = @(Get-StepState | Where-Object { $_.Step -ne $Step })
    $all += [pscustomobject]@{ Step = $Step; Status = $Status; Time = (Get-Date).ToString('s'); Detail = $Detail }
    ConvertTo-Json -InputObject $all -Depth 3 | Set-Content -Path $script:StatePath -Encoding UTF8
}

# Wraps anything that changes the machine so dry-run mode can log instead of act.
function Invoke-Mutation {
    param([Parameter(Mandatory)][string]$Description, [Parameter(Mandatory)][scriptblock]$Action)
    if ($script:DryRun) { Write-ToolkitLog "DRY-RUN: would $Description" 'WARN'; return $null }
    Write-ToolkitLog $Description
    & $Action
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ----------------------------------------------------------------------------- helpers

function Split-CommandLine {
    param([string]$Command)
    $c = $Command.Trim()
    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        return [pscustomobject]@{ Path = $c.Substring(1, $end - 1); ArgText = $c.Substring($end + 1).Trim() }
    }
    if ($c -match '^(.+?\.exe)\s*(.*)$') { return [pscustomobject]@{ Path = $Matches[1]; ArgText = $Matches[2] } }
    [pscustomobject]@{ Path = $c; ArgText = '' }
}

function Start-LoggedProcess {
    param([Parameter(Mandatory)][string]$FilePath, [string]$ArgumentText = '', [int]$TimeoutSec = 900)
    $splat = @{ FilePath = $FilePath; PassThru = $true; WindowStyle = 'Hidden' }
    if ($ArgumentText) { $splat.ArgumentList = $ArgumentText }
    $p = Start-Process @splat
    $null = $p.Handle   # keeps ExitCode readable after exit
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch {}
        throw "Timed out after $TimeoutSec s: $FilePath $ArgumentText"
    }
    $p.ExitCode
}

function Test-TcpPort {
    param([string]$HostName, [int]$Port = 443, [int]$TimeoutMs = 4000)
    $c = New-Object Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($HostName, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $c.Connected) { $c.EndConnect($iar); return $true }
        $false
    } catch { $false } finally { $c.Close() }
}

function Get-InstalledProgram {
    param([Parameter(Mandatory)][string[]]$NamePattern)
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($item in (Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue)) {
        $name = $item.DisplayName
        if (-not $name) { continue }
        foreach ($pat in $NamePattern) {
            if ($name -like $pat) {
                $out.Add([pscustomobject]@{
                    DisplayName = $name; Version = $item.DisplayVersion; KeyName = $item.PSChildName
                    UninstallString = $item.UninstallString; QuietUninstallString = $item.QuietUninstallString })
                break
            }
        }
    }
    $out.ToArray()
}

function Get-ToolFileInfo {
    param([Parameter(Mandatory)][string]$Path)
    $sig = Get-AuthenticodeSignature -FilePath $Path
    $subject = ''
    if ($sig.SignerCertificate) { $subject = $sig.SignerCertificate.Subject }
    [pscustomobject]@{
        Path = $Path; SignatureStatus = "$($sig.Status)"; Signer = $subject
        Sha256 = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    }
}

# ----------------------------------------------------------------------------- state discovery

function Get-JoinState {
    $o = [ordered]@{ AzureAdJoined = $false; DomainJoined = $false; WorkplaceJoined = $false; TenantName = ''; MdmUrl = ''; DomainName = '' }
    $txt = (& dsregcmd.exe /status 2>&1 | Out-String)
    foreach ($l in ($txt -split "`r?`n")) {
        if ($l -match '^\s*(AzureAdJoined|DomainJoined|WorkplaceJoined)\s*:\s*(\w+)') { $o[$Matches[1]] = ($Matches[2] -eq 'YES') }
        elseif ($l -match '^\s*(TenantName|MdmUrl|DomainName)\s*:\s*(.+?)\s*$') { $o[$Matches[1]] = $Matches[2] }
    }
    $cs = Get-CimInstance Win32_ComputerSystem
    $o.DomainJoined = [bool]$cs.PartOfDomain
    if ($cs.PartOfDomain) { $o.DomainName = $cs.Domain }
    [pscustomobject]$o
}

function Get-MdmEnrollment {
    $root = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
        if ($k.PSChildName -notmatch '^[0-9A-Fa-f-]{36}$') { continue }
        $p = Get-ItemProperty $k.PSPath
        if (-not $p.ProviderID) { continue }
        $kind = 'Other'
        if ($p.ProviderID -match 'AirWatch|Workspace') { $kind = 'WorkspaceONE' }
        elseif ($p.ProviderID -eq 'MS DM Server') { $kind = 'Intune' }
        [pscustomobject]@{ Id = $k.PSChildName; ProviderId = $p.ProviderID; Kind = $kind; UPN = $p.UPN; EnrollmentState = $p.EnrollmentState }
    }
}

function Get-SccmClientStatus {
    $svc = Get-Service -Name CcmExec -ErrorAction SilentlyContinue
    $setup = Join-Path $env:windir 'ccmsetup\ccmsetup.exe'
    [pscustomobject]@{ ServiceInstalled = [bool]$svc; SetupPresent = (Test-Path $setup); SetupPath = $setup }
}

function Get-LocalAdminCandidate {
    # Enabled local user accounts that are members of Administrators (domain / Entra members excluded).
    $res = New-Object System.Collections.Generic.List[string]
    try {
        $grp = [ADSI]"WinNT://$env:COMPUTERNAME/Administrators,group"
        foreach ($m in @($grp.psbase.Invoke('Members'))) {
            $t = $m.GetType()
            $cls  = $t.InvokeMember('Class',  'GetProperty', $null, $m, $null)
            $name = $t.InvokeMember('Name',   'GetProperty', $null, $m, $null)
            $path = $t.InvokeMember('ADsPath', 'GetProperty', $null, $m, $null)
            if ($cls -ne 'User') { continue }
            if ($path -notmatch ('^WinNT://' + [regex]::Escape($env:COMPUTERNAME) + '/[^/]+$')) { continue }
            $u = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
            if ($u -and $u.Enabled) { $res.Add($name) }
        }
    } catch { Write-ToolkitLog "Could not enumerate local administrators: $($_.Exception.Message)" 'WARN' }
    $res.ToArray()
}

function New-Check { param($Name, $Status, $Detail) [pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail } }

function Get-PreflightReport {
    $r = New-Object System.Collections.Generic.List[object]
    $cfg = Get-ToolkitConfig

    $r.Add((New-Check 'Running as administrator' $(if (Test-IsAdmin) { 'Pass' } else { 'Fail' }) 'Required for every migration step'))

    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    $r.Add((New-Check 'Windows version' $(if ($build -ge 19044) { 'Pass' } else { 'Warn' }) "$($os.Caption) build $build (21H2 / build 19044 or newer recommended)"))

    $r.Add((New-Check 'Serial number' 'Info' ((Get-CimInstance Win32_BIOS).SerialNumber.Trim())))

    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($bat) {
        $onAc = (@($bat) | Where-Object { $_.BatteryStatus -eq 2 }).Count -gt 0
        $r.Add((New-Check 'Power' $(if ($onAc) { 'Pass' } else { 'Warn' }) $(if ($onAc) { 'On AC power' } else { 'On battery - plug in before unjoining / rebooting' })))
    }

    $disk = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
    if ($disk) {
        $gb = [math]::Round($disk.Free / 1GB, 1)
        $r.Add((New-Check 'Free disk space' $(if ($gb -ge 10) { 'Pass' } else { 'Warn' }) "$gb GB free on $env:SystemDrive"))
    }

    $net = Test-TcpPort 'login.microsoftonline.com' 443
    $r.Add((New-Check 'Reach Entra sign-in' $(if ($net) { 'Pass' } else { 'Fail' }) 'login.microsoftonline.com:443'))
    $net2 = Test-TcpPort 'graph.microsoft.com' 443
    $r.Add((New-Check 'Reach Microsoft Graph' $(if ($net2) { 'Pass' } else { 'Warn' }) 'graph.microsoft.com:443 (needed for Intune upload only)'))

    $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
               (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    $r.Add((New-Check 'Pending reboot' $(if ($pending) { 'Warn' } else { 'Pass' }) $(if ($pending) { 'Reboot first, then continue' } else { 'None' })))

    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $r.Add((New-Check 'TPM' $(if ($tpm.TpmPresent -and $tpm.TpmReady) { 'Pass' } else { 'Warn' }) "Present=$($tpm.TpmPresent) Ready=$($tpm.TpmReady) (Autopilot / Entra join prefer TPM 2.0)"))
    } catch { $r.Add((New-Check 'TPM' 'Warn' 'Could not query TPM')) }

    try {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        $rp = @($bl.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }).Count
        $r.Add((New-Check 'BitLocker' 'Info' "Protection=$($bl.ProtectionStatus), recovery passwords=$rp. Record or back up the key before changing management."))
    } catch { $r.Add((New-Check 'BitLocker' 'Info' 'Not available or not enabled')) }

    $admins = @(Get-LocalAdminCandidate)
    if ($admins.Count -gt 0) { $r.Add((New-Check 'Local administrator exists' 'Pass' ($admins -join ', '))) }
    else { $r.Add((New-Check 'Local administrator exists' 'Fail' "No enabled local admin. Create one (Maintenance tab) BEFORE unjoining the domain or you can be locked out.")) }

    $js = Get-JoinState
    $r.Add((New-Check 'Active Directory' 'Info' $(if ($js.DomainJoined) { "Joined to $($js.DomainName)" } else { 'Not domain joined' })))
    $r.Add((New-Check 'Entra ID' 'Info' $(if ($js.AzureAdJoined) { "Joined (tenant: $($js.TenantName))" } else { 'Not Entra joined' })))

    $hub = @(Get-InstalledProgram -NamePattern $cfg.ws1Names)
    $enr = @(Get-MdmEnrollment | Where-Object { $_.Kind -eq 'WorkspaceONE' })
    $r.Add((New-Check 'Workspace ONE' 'Info' ("Programs: {0}; MDM enrollments: {1}" -f $hub.Count, $enr.Count)))
    $sc = Get-SccmClientStatus
    $r.Add((New-Check 'SCCM client' 'Info' $(if ($sc.ServiceInstalled -or $sc.SetupPresent) { 'Present' } else { 'Not present' })))
    $intune = @(Get-MdmEnrollment | Where-Object { $_.Kind -eq 'Intune' })
    $r.Add((New-Check 'Intune enrollment' 'Info' $(if ($intune.Count) { 'Enrolled' } else { 'Not enrolled' })))

    $r.ToArray()
}

# ----------------------------------------------------------------------------- Workspace ONE / SCCM removal

function Remove-MdmEnrollmentArtifact {
    param([Parameter(Mandatory)][string]$EnrollmentId)
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Enrollments\$EnrollmentId",
        "HKLM:\SOFTWARE\Microsoft\Enrollments\Status\$EnrollmentId",
        "HKLM:\SOFTWARE\Microsoft\EnterpriseResourceManager\Tracked\$EnrollmentId",
        "HKLM:\SOFTWARE\Microsoft\PolicyManager\Providers\$EnrollmentId",
        "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\$EnrollmentId",
        "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Logger\$EnrollmentId",
        "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Sessions\$EnrollmentId")
    foreach ($p in $regPaths) {
        if (Test-Path $p) { Invoke-Mutation "remove registry key $p" { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue } | Out-Null }
    }
    $taskPath = "\Microsoft\Windows\EnterpriseMgmt\$EnrollmentId\"
    $tasks = @(Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue)
    if ($tasks.Count -gt 0) {
        Invoke-Mutation "remove $($tasks.Count) scheduled task(s) under $taskPath" {
            $tasks | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
            try { $svc = New-Object -ComObject Schedule.Service; $svc.Connect(); $svc.GetFolder('\Microsoft\Windows\EnterpriseMgmt').DeleteFolder($EnrollmentId, 0) } catch {}
        } | Out-Null
    }
}

function Remove-WorkspaceOne {
    $cfg = Get-ToolkitConfig
    $programs = @(Get-InstalledProgram -NamePattern $cfg.ws1Names)
    if ($programs.Count -eq 0) { Write-ToolkitLog 'No Workspace ONE / AirWatch programs found.' }
    foreach ($p in $programs) {
        Write-ToolkitLog "Uninstalling $($p.DisplayName) $($p.Version)" 'STEP'
        $log = Join-Path $script:LogDir ("uninstall-{0}.log" -f ($p.DisplayName -replace '[^\w\.-]', '_'))
        $code = $null
        if ($p.KeyName -match '^\{[0-9A-Fa-f-]{36}\}$') {
            $code = Invoke-Mutation "msiexec /x $($p.KeyName)" { Start-LoggedProcess -FilePath 'msiexec.exe' -ArgumentText "/x $($p.KeyName) /qn /norestart /l*v `"$log`"" }
        } else {
            $cmd = if ($p.QuietUninstallString) { $p.QuietUninstallString } else { $p.UninstallString }
            if (-not $cmd) { Write-ToolkitLog "No uninstall command registered for $($p.DisplayName)" 'WARN'; continue }
            $sp = Split-CommandLine $cmd
            $argText = $sp.ArgText
            if (-not $p.QuietUninstallString) { $argText = "$argText /silent /norestart".Trim() }
            $code = Invoke-Mutation "run $($sp.Path) $argText" { Start-LoggedProcess -FilePath $sp.Path -ArgumentText $argText }
        }
        if ($null -ne $code) {
            if ($code -in 0, 3010, 1641) { Write-ToolkitLog "$($p.DisplayName) removed (exit $code)." 'OK' }
            else { Write-ToolkitLog "$($p.DisplayName) uninstall returned exit code $code - see $log" 'WARN' }
        }
    }

    $enrollments = @(Get-MdmEnrollment | Where-Object { $_.Kind -eq 'WorkspaceONE' })
    foreach ($e in $enrollments) {
        Write-ToolkitLog "Removing leftover Workspace ONE MDM enrollment $($e.Id)" 'STEP'
        Remove-MdmEnrollmentArtifact -EnrollmentId $e.Id
    }

    foreach ($rawPath in $cfg.ws1CleanupPaths) {
        $path = [Environment]::ExpandEnvironmentVariables($rawPath)
        if (Test-Path $path) { Invoke-Mutation "remove leftover $path" { Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue } | Out-Null }
    }

    if (-not $script:DryRun) {
        $left = @(Get-InstalledProgram -NamePattern $cfg.ws1Names)
        $leftEnr = @(Get-MdmEnrollment | Where-Object { $_.Kind -eq 'WorkspaceONE' })
        $svc = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*AirWatch*' -or $_.DisplayName -like '*Workspace ONE*' })
        if ($left.Count -eq 0 -and $leftEnr.Count -eq 0) {
            Write-ToolkitLog 'Workspace ONE removal verified (no programs, no MDM enrollment).' 'OK'
            if ($svc.Count) { Write-ToolkitLog ("Services still registered until reboot: " + (($svc | ForEach-Object { $_.DisplayName }) -join ', ')) 'WARN' }
            Set-StepState 'RemoveWS1' 'Done'
        } else {
            Write-ToolkitLog "Workspace ONE removal incomplete: $($left.Count) program(s), $($leftEnr.Count) enrollment(s) remain." 'ERROR'
            Set-StepState 'RemoveWS1' 'Failed' 'Leftovers remain'
        }
    }
    Write-ToolkitLog 'Reminder: also delete / retire this device in the Workspace ONE console so it stops showing as managed.' 'WARN'
}

function Remove-SccmClient {
    $sc = Get-SccmClientStatus
    if (-not $sc.ServiceInstalled -and -not $sc.SetupPresent) {
        Write-ToolkitLog 'SCCM client not present.'
        Set-StepState 'RemoveSCCM' 'Skipped' 'Not present'
        return
    }
    if (-not $sc.SetupPresent) { Write-ToolkitLog "CcmExec service exists but $($sc.SetupPath) is missing - cannot uninstall automatically." 'ERROR'; Set-StepState 'RemoveSCCM' 'Failed'; return }
    Write-ToolkitLog 'Uninstalling SCCM client' 'STEP'
    Invoke-Mutation 'run ccmsetup.exe /uninstall' { Start-Process -FilePath $sc.SetupPath -ArgumentList '/uninstall' | Out-Null } | Out-Null
    if ($script:DryRun) { return }
    # ccmsetup /uninstall returns immediately and finishes in the background.
    $deadline = (Get-Date).AddMinutes(10)
    do {
        Start-Sleep -Seconds 5
        $busy = (Get-Process -Name ccmsetup -ErrorAction SilentlyContinue) -or (Get-Service -Name CcmExec -ErrorAction SilentlyContinue)
    } while ($busy -and (Get-Date) -lt $deadline)
    if (Get-Service -Name CcmExec -ErrorAction SilentlyContinue) {
        Write-ToolkitLog 'SCCM client still present after 10 minutes. Check C:\Windows\ccmsetup\Logs\ccmsetup.log' 'ERROR'
        Set-StepState 'RemoveSCCM' 'Failed'
    } else {
        Write-ToolkitLog 'SCCM client removed.' 'OK'
        Set-StepState 'RemoveSCCM' 'Done'
    }
}

# ----------------------------------------------------------------------------- local admin / domain unjoin / restart

function New-ToolkitLocalAdmin {
    param([Parameter(Mandatory)][securestring]$Password)
    $name = (Get-ToolkitConfig).localAdminName
    $u = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    if ($u) {
        Invoke-Mutation "reset password and enable local account '$name'" { Set-LocalUser -Name $name -Password $Password; Enable-LocalUser -Name $name } | Out-Null
    } else {
        Invoke-Mutation "create local administrator '$name'" {
            New-LocalUser -Name $name -Password $Password -PasswordNeverExpires -AccountNeverExpires -Description 'Temporary migration admin (remove after migration)' | Out-Null
            Add-LocalGroupMember -Group 'Administrators' -Member $name
        } | Out-Null
    }
    Write-ToolkitLog "Local admin '$name' ready. Remove it when migration is finished (Maintenance tab)." 'OK'
}

function Remove-ToolkitLocalAdmin {
    $name = (Get-ToolkitConfig).localAdminName
    if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) {
        Invoke-Mutation "delete local account '$name'" { Remove-LocalUser -Name $name } | Out-Null
        Write-ToolkitLog "Local admin '$name' removed." 'OK'
    } else { Write-ToolkitLog "Local account '$name' does not exist." }
}

function Invoke-DomainUnjoin {
    param([pscredential]$Credential, [switch]$OfflineUnjoin)
    $cs = Get-CimInstance Win32_ComputerSystem
    if (-not $cs.PartOfDomain) { Write-ToolkitLog 'Device is not domain joined.'; Set-StepState 'UnjoinAD' 'Skipped' 'Not domain joined'; return }
    $admins = @(Get-LocalAdminCandidate)
    if ($admins.Count -eq 0) { throw 'Refusing to unjoin: no enabled local administrator exists. Create one first (Maintenance tab).' }
    Write-ToolkitLog "Local admin(s) available after unjoin: $($admins -join ', ')"
    if (-not $Credential -and -not $OfflineUnjoin) { throw 'AD credentials are required (or choose offline unjoin).' }

    $js = Get-JoinState
    if ($js.AzureAdJoined) { Invoke-Mutation 'run dsregcmd /leave (hybrid join cleanup)' { & dsregcmd.exe /leave | Out-Null } | Out-Null }

    $wg = (Get-ToolkitConfig).workgroupName
    Write-ToolkitLog "Leaving domain $($cs.Domain)" 'STEP'
    if ($OfflineUnjoin) {
        Write-ToolkitLog 'Offline unjoin: the computer object will remain in AD and must be deleted manually.' 'WARN'
        Invoke-Mutation "Remove-Computer to workgroup $wg (no credentials)" { Remove-Computer -WorkgroupName $wg -Force -ErrorAction Stop } | Out-Null
    } else {
        Invoke-Mutation "Remove-Computer to workgroup $wg" { Remove-Computer -UnjoinDomainCredential $Credential -WorkgroupName $wg -Force -ErrorAction Stop } | Out-Null
    }
    if (-not $script:DryRun) {
        Write-ToolkitLog 'Domain unjoin complete. RESTART REQUIRED, then sign in with the local admin account.' 'OK'
        Set-StepState 'UnjoinAD' 'Done' 'Restart required'
    }
}

function Request-ToolkitRestart {
    param([int]$DelaySeconds = 60)
    Invoke-Mutation "schedule restart in $DelaySeconds seconds" {
        & shutdown.exe /r /t $DelaySeconds /c "Device migration: restarting. Sign in with the local admin account." | Out-Null
    } | Out-Null
    Write-ToolkitLog "Restart scheduled in $DelaySeconds s. Run 'shutdown /a' to cancel."
}

function Stop-ToolkitRestart { & shutdown.exe /a 2>&1 | Out-Null; Write-ToolkitLog 'Pending restart cancelled (if any).' }

# ----------------------------------------------------------------------------- Entra join / Intune enrollment

function Start-EntraJoin {
    param([int]$TimeoutMin = 20)
    $js = Get-JoinState
    if ($js.AzureAdJoined) { Write-ToolkitLog "Already Entra joined (tenant: $($js.TenantName))." 'OK'; Set-StepState 'JoinEntra' 'Done'; return }
    if ($js.DomainJoined) { throw 'Device is still domain joined. Unjoin Active Directory and restart first.' }

    $ppkg = @(Get-ChildItem -Path (Join-Path $script:ToolkitRoot 'Tools') -Filter '*.ppkg' -ErrorAction SilentlyContinue)
    if ($ppkg.Count -gt 0) {
        Write-ToolkitLog "Provisioning package found: $($ppkg[0].Name) - installing silently" 'STEP'
        Invoke-Mutation "install provisioning package $($ppkg[0].Name)" { Install-ProvisioningPackage -PackagePath $ppkg[0].FullName -QuietInstall -ForceInstall -ErrorAction Stop } | Out-Null
    } else {
        Write-ToolkitLog 'Opening Settings > Accounts > Access work or school. Choose Connect, then "Join this device to Microsoft Entra ID" and sign in.' 'STEP'
        Invoke-Mutation 'open ms-settings:workplace' { Start-Process 'ms-settings:workplace' } | Out-Null
    }
    if ($script:DryRun) { return }

    Write-ToolkitLog "Waiting up to $TimeoutMin minutes for Entra join to complete..."
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        $js = Get-JoinState
        if ($js.AzureAdJoined) {
            Write-ToolkitLog "Entra join confirmed (tenant: $($js.TenantName)). Restart, then sign in as the Entra user." 'OK'
            Set-StepState 'JoinEntra' 'Done' $js.TenantName
            return
        }
    }
    Write-ToolkitLog 'Timed out waiting for Entra join. Re-run this step once the join completes.' 'ERROR'
    Set-StepState 'JoinEntra' 'Failed' 'Timed out'
}

function Test-IntuneEnrollment {
    param([switch]$Trigger)
    $js = Get-JoinState
    if (-not $js.AzureAdJoined) { Write-ToolkitLog 'Device is not Entra joined yet.' 'ERROR'; return $false }
    $enr = @(Get-MdmEnrollment | Where-Object { $_.Kind -eq 'Intune' })
    if ($enr.Count -eq 0 -and $Trigger) {
        Write-ToolkitLog 'No Intune enrollment yet - triggering automatic MDM enrollment.' 'STEP'
        Invoke-Mutation 'run deviceenroller.exe /c /AutoEnrollMDM' { & "$env:windir\System32\deviceenroller.exe" /c /AutoEnrollMDM | Out-Null } | Out-Null
        if (-not $script:DryRun) {
            for ($i = 0; $i -lt 12 -and $enr.Count -eq 0; $i++) {
                Start-Sleep -Seconds 10
                $enr = @(Get-MdmEnrollment | Where-Object { $_.Kind -eq 'Intune' })
            }
        }
    }
    if ($enr.Count -gt 0) { Write-ToolkitLog "Intune enrollment present (MDM URL: $($js.MdmUrl))." 'OK'; return $true }
    Write-ToolkitLog 'Not enrolled in Intune. Check Entra > Mobility > Microsoft Intune > MDM user scope, and that the user has an Intune license.' 'WARN'
    $false
}

function Backup-BitLockerToEntra {
    $js = Get-JoinState
    if (-not $js.AzureAdJoined) { throw 'Device must be Entra joined to escrow BitLocker keys to Entra.' }
    $v = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    $kps = @($v.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
    if ($kps.Count -eq 0) { Write-ToolkitLog 'No BitLocker recovery password protector on the OS drive; nothing to back up.' 'WARN'; return }
    foreach ($kp in $kps) {
        Invoke-Mutation "back up BitLocker protector $($kp.KeyProtectorId) to Entra" {
            BackupToAAD-BitLockerKeyProtector -MountPoint $env:SystemDrive -KeyProtectorId $kp.KeyProtectorId | Out-Null
        } | Out-Null
    }
    Write-ToolkitLog 'BitLocker recovery key(s) backed up to Entra ID.' 'OK'
}

function Complete-IntuneVerification {
    $ok = Test-IntuneEnrollment -Trigger
    try { Backup-BitLockerToEntra } catch { Write-ToolkitLog "BitLocker escrow skipped: $($_.Exception.Message)" 'WARN' }
    if ($script:DryRun) { return }
    if ($ok) { Set-StepState 'VerifyIntune' 'Done' } else { Set-StepState 'VerifyIntune' 'Failed' }
}

# ----------------------------------------------------------------------------- profile wizard and tools

function Start-ProfileWizard {
    $tools = Join-Path $script:ToolkitRoot 'Tools'
    $exe = Join-Path $tools 'Profwiz.exe'
    $msi = Join-Path $tools 'Profwiz.msi'
    $installed = Get-ChildItem -Path "${env:ProgramFiles(x86)}\ForensiT", "$env:ProgramFiles\ForensiT" -Filter 'Profwiz.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    $target = $null
    if ($installed) { $target = $installed.FullName }
    elseif (Test-Path $exe) { $target = $exe }
    elseif (Test-Path $msi) {
        # The MSI only extracts Profwiz.exe to its install directory.
        Write-ToolkitLog 'Installing User Profile Wizard from Profwiz.msi' 'STEP'
        Invoke-Mutation 'run Profwiz.msi installer (interactive)' { Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$msi`"" -Wait } | Out-Null
        $installed = Get-ChildItem -Path "${env:ProgramFiles(x86)}\ForensiT", "$env:ProgramFiles\ForensiT" -Filter 'Profwiz.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($installed) { $target = $installed.FullName }
    }
    if (-not $target) { if ($script:DryRun) { Write-ToolkitLog 'DRY-RUN: Profwiz not found yet' 'WARN'; return }; throw "Profwiz.exe / Profwiz.msi not found. Copy them into $tools" }

    $info = Get-ToolFileInfo -Path $target
    Write-ToolkitLog "Profwiz: signature=$($info.SignatureStatus) signer=$($info.Signer) sha256=$($info.Sha256)"
    if ($info.SignatureStatus -ne 'Valid') { Write-ToolkitLog 'Profwiz signature is not Valid - verify the file before continuing.' 'WARN' }
    Write-ToolkitLog 'Launching User Profile Wizard (GUI). Sign in as the new Entra user first, run as administrator, and pick the old domain profile.' 'STEP'
    Invoke-Mutation "launch $target" { Start-Process -FilePath $target -Wait } | Out-Null
    Set-StepState 'ProfileWizard' 'Done' 'Launched; confirm result manually'
}

function Invoke-ToolExecutable {
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path (Join-Path $script:ToolkitRoot 'Tools') $Name
    if (-not (Test-Path $path)) { throw "$Name not found in Tools folder." }
    $info = Get-ToolFileInfo -Path $path
    Write-ToolkitLog "$Name signature=$($info.SignatureStatus) signer=$($info.Signer) sha256=$($info.Sha256)"
    if ($info.SignatureStatus -ne 'Valid') { Write-ToolkitLog "$Name is not validly signed. Not running it." 'ERROR'; return }
    Invoke-Mutation "run $Name (interactive, waits for exit)" { Start-Process -FilePath $path -Wait } | Out-Null
    Write-ToolkitLog "$Name finished." 'OK'
}

function Invoke-Debloat {
    $cfg = Get-ToolkitConfig
    foreach ($n in $cfg.debloat) {
        foreach ($pkg in @(Get-AppxPackage -AllUsers | Where-Object { $_.Name -like "*$n*" -or $_.PackageFamilyName -like "*$n*" })) {
            Invoke-Mutation "remove app package $($pkg.Name) for all users" {
                try { Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop } catch { Write-ToolkitLog "  $($pkg.Name): $($_.Exception.Message)" 'WARN' }
            } | Out-Null
        }
        foreach ($prov in @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "*$n*" })) {
            Invoke-Mutation "remove provisioned package $($prov.DisplayName)" {
                try { Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null } catch { Write-ToolkitLog "  $($prov.DisplayName): $($_.Exception.Message)" 'WARN' }
            } | Out-Null
        }
    }
    Write-ToolkitLog 'Debloat pass finished.' 'OK'
    Set-StepState 'Cleanup' 'Done'
}

# ----------------------------------------------------------------------------- Autopilot hash capture / CSV tools

$script:CsvHeaders = @('Device Serial Number', 'Windows Product ID', 'Hardware Hash', 'Group Tag')

function Get-AutopilotHardwareInfo {
    # Same WMI source Get-WindowsAutopilotInfo reads; needs no internet or gallery module.
    $serial = (Get-CimInstance Win32_BIOS).SerialNumber.Trim()
    $d = Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' -ClassName MDM_DevDetail_Ext01 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'" -ErrorAction SilentlyContinue
    if (-not $d -or -not $d.DeviceHardwareData) {
        throw 'Hardware hash is not available via WMI (MDM_DevDetail_Ext01). Run as administrator on a Windows 10/11 Pro/Enterprise/Education device.'
    }
    [pscustomobject]@{ Serial = $serial; ProductId = ''; Hash = $d.DeviceHardwareData }
}

function Save-AutopilotRow {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Info, [string]$GroupTag = '')
    $rows = New-Object System.Collections.Generic.List[object]
    if (Test-Path $Path) { foreach ($r in (Import-Csv $Path)) { if ($r.'Device Serial Number' -ne $Info.Serial) { $rows.Add($r) } } }
    $rows.Add([pscustomobject][ordered]@{
        'Device Serial Number' = $Info.Serial; 'Windows Product ID' = $Info.ProductId
        'Hardware Hash' = $Info.Hash; 'Group Tag' = $GroupTag })
    $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding ASCII
}

function Invoke-AutopilotCapture {
    param([string]$GroupTag = '', [string]$OutputFolder)
    if (-not $OutputFolder) { $OutputFolder = Join-Path $script:ToolkitRoot 'Output\Autopilot' }
    if (-not $GroupTag) { Write-ToolkitLog 'No group tag selected - the device will be captured with an empty tag.' 'WARN' }
    $info = Get-AutopilotHardwareInfo
    $file = Join-Path $OutputFolder ("{0}_AutoPilotSetup.csv" -f ($info.Serial -replace '[^\w-]', '_'))
    Invoke-Mutation "write hardware hash for serial $($info.Serial) to $file" {
        if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }
        Save-AutopilotRow -Path $file -Info $info -GroupTag $GroupTag
    } | Out-Null
    Write-ToolkitLog "Captured $($info.Serial) (hash length $($info.Hash.Length), tag '$GroupTag')." 'OK'
    $file
}

function Test-AutopilotRow {
    param([Parameter(Mandatory)]$Row, [string[]]$KnownGroupTags = @())
    $problems = New-Object System.Collections.Generic.List[string]
    $serial = "$($Row.'Device Serial Number')".Trim()
    $hash = "$($Row.'Hardware Hash')".Trim()
    if (-not $serial) { $problems.Add('missing serial') }
    if (-not $hash) { $problems.Add('missing hardware hash') }
    else { try { [void][Convert]::FromBase64String($hash) } catch { $problems.Add('hardware hash is not valid base64') } }
    $tag = "$($Row.'Group Tag')".Trim()
    if (-not $tag) { $problems.Add('no group tag (device gets no tag-based profile)') }
    elseif ($KnownGroupTags.Count -gt 0 -and $KnownGroupTags -notcontains $tag) { $problems.Add("group tag '$tag' is not in the configured list") }
    $problems.ToArray()
}

function Merge-AutopilotCsv {
    param([Parameter(Mandatory)][string]$Folder, [string]$OutputPath)
    if (-not (Test-Path $Folder)) { throw "Folder not found: $Folder" }
    $tags = @((Get-ToolkitConfig).groupTags)
    $byKey = [ordered]@{}
    $files = @(Get-ChildItem -Path $Folder -Filter '*.csv' | Where-Object { $_.Name -notlike 'Consolidated*' })
    if ($files.Count -eq 0) { throw "No source CSV files in $Folder (files named Consolidated* are ignored)." }
    $dupes = 0; $bad = 0
    foreach ($f in $files) {
        foreach ($row in (Import-Csv $f.FullName)) {
            if (-not ($row.PSObject.Properties.Name -contains 'Device Serial Number')) { Write-ToolkitLog "$($f.Name): not an Autopilot CSV, skipped." 'WARN'; break }
            $problems = @(Test-AutopilotRow -Row $row -KnownGroupTags $tags)
            $hard = @($problems | Where-Object { $_ -like 'missing*' -or $_ -like '*base64*' })
            if ($hard.Count -gt 0) { $bad++; Write-ToolkitLog "$($f.Name) / '$($row.'Device Serial Number')': $($problems -join '; ') - skipped." 'ERROR'; continue }
            foreach ($p in $problems) { Write-ToolkitLog "$($f.Name) / $($row.'Device Serial Number'): $p" 'WARN' }
            $key = "$($row.'Device Serial Number')".Trim()
            if ($byKey.Contains($key)) { $dupes++ }
            $byKey[$key] = [pscustomobject][ordered]@{
                'Device Serial Number' = $key; 'Windows Product ID' = "$($row.'Windows Product ID')"
                'Hardware Hash' = "$($row.'Hardware Hash')".Trim(); 'Group Tag' = "$($row.'Group Tag')".Trim() }
        }
    }
    if ($byKey.Count -eq 0) { throw 'No valid devices found.' }
    if (-not $OutputPath) { $OutputPath = Join-Path $Folder ("Consolidated{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss')) }
    Invoke-Mutation "write $($byKey.Count) devices to $OutputPath" { $byKey.Values | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding ASCII } | Out-Null
    Write-ToolkitLog "Consolidated $($byKey.Count) unique device(s) from $($files.Count) file(s); $dupes duplicate(s) merged, $bad invalid row(s) skipped." 'OK'
    if ($byKey.Count -gt 500) { Write-ToolkitLog 'More than 500 devices: Intune portal CSV upload is limited to 500 per file. Use the Graph upload instead.' 'WARN' }
    $OutputPath
}

# ----------------------------------------------------------------------------- Intune via Microsoft Graph

function Install-GraphModule {
    Write-ToolkitLog 'Installing Microsoft.Graph.Authentication for the current user (from PSGallery)' 'STEP'
    Invoke-Mutation 'install NuGet provider and Microsoft.Graph.Authentication' {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
    } | Out-Null
}

function Connect-IntuneGraph {
    param([string[]]$Scopes = @('DeviceManagementServiceConfig.ReadWrite.All', 'DeviceManagementManagedDevices.Read.All'))
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) { throw 'Microsoft.Graph.Authentication is not installed. Use "Install Graph module" (Maintenance tab).' }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $ctx = Get-MgContext
    $have = @(); if ($ctx) { $have = @($ctx.Scopes) }
    $missing = @($Scopes | Where-Object { $have -notcontains $_ })
    if (-not $ctx -or $missing.Count -gt 0) {
        Write-ToolkitLog 'Opening Microsoft sign-in (use an account with Intune Administrator rights)...' 'STEP'
        Connect-MgGraph -Scopes $Scopes -ErrorAction Stop | Out-Null
        $ctx = Get-MgContext
    }
    Write-ToolkitLog "Signed in to Graph as $($ctx.Account) (tenant $($ctx.TenantId))." 'OK'
}

function Import-AutopilotToIntune {
    param([Parameter(Mandatory)][string]$CsvPath, [int]$TimeoutMin = 20)
    if (-not (Test-Path $CsvPath)) { throw "CSV not found: $CsvPath" }
    $rows = @(Import-Csv $CsvPath)
    $tags = @((Get-ToolkitConfig).groupTags)
    foreach ($row in $rows) {
        $p = @(Test-AutopilotRow -Row $row -KnownGroupTags $tags)
        if ($p | Where-Object { $_ -like 'missing*' -or $_ -like '*base64*' }) { throw "Invalid row for '$($row.'Device Serial Number')': $($p -join '; ')" }
    }
    Connect-IntuneGraph
    $base = 'https://graph.microsoft.com/beta/deviceManagement'
    $results = New-Object System.Collections.Generic.List[object]
    $pending = @{}

    foreach ($row in $rows) {
        $serial = "$($row.'Device Serial Number')".Trim()
        $q = $serial -replace "'", "''"
        $existing = Invoke-MgGraphRequest -Method GET -Uri ($base + "/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$q')")
        if (@($existing.value).Count -gt 0) {
            Write-ToolkitLog "$serial already registered in Autopilot - skipped." 'WARN'
            $results.Add([pscustomobject]@{ Serial = $serial; Result = 'AlreadyRegistered'; Detail = '' }); continue
        }
        $tag = "$($row.'Group Tag')".Trim()
        $body = @{
            '@odata.type'      = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
            serialNumber       = $serial
            productKey         = "$($row.'Windows Product ID')"
            hardwareIdentifier = "$($row.'Hardware Hash')".Trim()
            groupTag           = $tag
            state              = @{ '@odata.type' = 'microsoft.graph.importedWindowsAutopilotDeviceIdentityState'; deviceImportStatus = 'pending'; deviceRegistrationId = ''; deviceErrorCode = 0; deviceErrorName = '' }
        }
        $resp = Invoke-Mutation "upload $serial (tag '$tag') to Intune" {
            Invoke-MgGraphRequest -Method POST -Uri ($base + '/importedWindowsAutopilotDeviceIdentities') -Body ($body | ConvertTo-Json -Depth 5) -ContentType 'application/json'
        }
        if ($resp -and $resp.id) { $pending[$resp.id] = $serial }
    }

    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        foreach ($id in @($pending.Keys)) {
            $s = Invoke-MgGraphRequest -Method GET -Uri ($base + "/importedWindowsAutopilotDeviceIdentities/$id")
            $status = "$($s.state.deviceImportStatus)"
            if ($status -in 'complete', 'error', 'partial') {
                $ok = ($status -eq 'complete')
                $detail = "$($s.state.deviceErrorName)"
                Write-ToolkitLog "$($pending[$id]): import $status $detail" $(if ($ok) { 'OK' } else { 'ERROR' })
                $results.Add([pscustomobject]@{ Serial = $pending[$id]; Result = $status; Detail = $detail })
                $pending.Remove($id)
            }
        }
        if ($pending.Count -gt 0) { Write-ToolkitLog "Waiting for Intune to process $($pending.Count) device(s)..." }
    }
    foreach ($id in $pending.Keys) { $results.Add([pscustomobject]@{ Serial = $pending[$id]; Result = 'TimedOut'; Detail = 'Still processing; check the portal later' }) }
    $results.ToArray()
}

function Sync-AutopilotService {
    Connect-IntuneGraph
    try {
        Invoke-Mutation 'request Autopilot sync' { Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotSettings/sync' } | Out-Null
        Write-ToolkitLog 'Autopilot sync requested (the service allows this roughly every 10 minutes).' 'OK'
    } catch { Write-ToolkitLog "Autopilot sync failed or was throttled: $($_.Exception.Message)" 'WARN' }
}

function Get-IntuneDeviceReport {
    param([string]$Serial)
    if (-not $Serial) { $Serial = (Get-CimInstance Win32_BIOS).SerialNumber.Trim() }
    Connect-IntuneGraph
    $q = $Serial -replace "'", "''"
    $base = 'https://graph.microsoft.com/beta/deviceManagement'
    $ap = Invoke-MgGraphRequest -Method GET -Uri ($base + "/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$q')")
    $md = Invoke-MgGraphRequest -Method GET -Uri ($base + "/managedDevices?`$filter=serialNumber%20eq%20'$q'")
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($d in @($ap.value)) {
        $out.Add([pscustomobject]@{ Source = 'Autopilot'; Serial = $d.serialNumber; Detail = "groupTag=$($d.groupTag); profile=$($d.deploymentProfileAssignmentStatus); lastContact=$($d.lastContactedDateTime)" })
    }
    foreach ($d in @($md.value)) {
        $out.Add([pscustomobject]@{ Source = 'Intune'; Serial = $d.serialNumber; Detail = "name=$($d.deviceName); compliance=$($d.complianceState); lastSync=$($d.lastSyncDateTime); user=$($d.userPrincipalName)" })
    }
    if ($out.Count -eq 0) { Write-ToolkitLog "Serial $Serial not found in Autopilot or Intune." 'WARN' }
    foreach ($o in $out) { Write-ToolkitLog "[$($o.Source)] $($o.Serial) $($o.Detail)" }
    $out.ToArray()
}

# ----------------------------------------------------------------------------- single dispatcher for GUI + CLI

function Invoke-ToolkitAction {
    param([Parameter(Mandatory)][string]$Name, [hashtable]$Params = @{})
    Write-ToolkitLog "=== $Name ===" 'STEP'
    if ($script:DryRun) { Write-ToolkitLog 'DRY-RUN mode: no changes will be made.' 'WARN' }
    try {
        switch ($Name) {
            'Preflight'        { $rep = Get-PreflightReport; foreach ($c in $rep) { Write-ToolkitLog ("{0,-5} {1}: {2}" -f $c.Status.ToUpper(), $c.Name, $c.Detail) $(if ($c.Status -eq 'Fail') { 'ERROR' } elseif ($c.Status -eq 'Warn') { 'WARN' } else { 'INFO' }) }; return $rep }
            'RemoveWS1'        { Remove-WorkspaceOne }
            'RemoveSCCM'       { Remove-SccmClient }
            'CreateLocalAdmin' { New-ToolkitLocalAdmin -Password $Params.Password }
            'RemoveLocalAdmin' { Remove-ToolkitLocalAdmin }
            'UnjoinAD'         { Invoke-DomainUnjoin -Credential $Params.Credential -OfflineUnjoin:([bool]$Params.Offline) }
            'Restart'          { Request-ToolkitRestart -DelaySeconds ([int]$Params.Delay) }
            'CancelRestart'    { Stop-ToolkitRestart }
            'JoinEntra'        { Start-EntraJoin }
            'VerifyIntune'     { Complete-IntuneVerification }
            'IntuneSyncNow'    { [void](Test-IntuneEnrollment -Trigger) }
            'BackupBitLocker'  { Backup-BitLockerToEntra }
            'ProfileWizard'    { Start-ProfileWizard }
            'Debloat'          { Invoke-Debloat }
            'RunMCPR'          { Invoke-ToolExecutable -Name 'MCPR.exe' }
            'CaptureHash'      { [void](Invoke-AutopilotCapture -GroupTag $Params.GroupTag -OutputFolder $Params.OutputFolder) }
            'MergeCsv'         { [void](Merge-AutopilotCsv -Folder $Params.Folder) }
            'InstallGraph'     { Install-GraphModule }
            'GraphSignIn'      { Connect-IntuneGraph }
            'UploadAutopilot'  { $res = Import-AutopilotToIntune -CsvPath $Params.CsvPath; foreach ($x in $res) { Write-ToolkitLog "RESULT $($x.Serial): $($x.Result) $($x.Detail)" } }
            'AutopilotSync'    { Sync-AutopilotService }
            'DeviceLookup'     { [void](Get-IntuneDeviceReport -Serial $Params.Serial) }
            default            { throw "Unknown action '$Name'" }
        }
        Write-ToolkitLog "=== $Name finished ===" 'STEP'
    } catch {
        Write-ToolkitLog "$Name FAILED: $($_.Exception.Message)" 'ERROR'
        $stateKey = if ($Name -eq 'Debloat') { 'Cleanup' } else { $Name }
        if ($stateKey -in 'RemoveWS1', 'RemoveSCCM', 'UnjoinAD', 'JoinEntra', 'VerifyIntune', 'ProfileWizard', 'Cleanup') { Set-StepState $stateKey 'Failed' $_.Exception.Message }
    }
}

Export-ModuleMember -Function Initialize-Toolkit, Set-ToolkitLogSink, Set-ToolkitDryRun, Get-ToolkitRoot, Get-ToolkitLogDir, Write-ToolkitLog,
    Get-ToolkitConfig, Get-StepState, Test-IsAdmin, Invoke-ToolkitAction
