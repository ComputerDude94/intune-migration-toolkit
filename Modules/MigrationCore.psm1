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
    # Standard users must not be able to edit the saved plan or logs: administrators/SYSTEM full control, users read only.
    $mark = Join-Path $script:DataRoot '.secured'
    if (-not (Test-Path $mark) -and (Test-IsAdmin)) {
        try {
            & icacls.exe $script:DataRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
            Set-Content -Path $mark -Value 'permissions restricted' -ErrorAction SilentlyContinue
        } catch {}
    }
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
        ws1Names      = @('*Workspace ONE*', '*AirWatch*', '*Intelligent Hub*')
        ws1Publishers = @('AirWatch*')
        trustedToolHashes = @()
        ws1AppxNames  = @('*WorkspaceONE*', '*Workspace ONE*', '*AirWatch*')
        ws1CleanupPaths = @('HKLM:\SOFTWARE\AirWatch', 'HKLM:\SOFTWARE\WOW6432Node\AirWatch', "$env:ProgramData\AirWatch", "$env:ProgramData\VMware\SetupAssistant", "$env:ProgramFiles\AirWatch", "${env:ProgramFiles(x86)}\AirWatch")
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

function Clear-StepState {
    param([Parameter(Mandatory)][string]$Step)
    if ($script:DryRun) { return }
    $all = @(Get-StepState | Where-Object { $_.Step -ne $Step })
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
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

# ----------------------------------------------------------------------------- device scope guard
# The toolkit only ever changes the computer it is running on. No function here takes a computer name, opens a
# remote session or touches another machine, so a signed-in network account is never used to reach beyond this device.
# These helpers make that explicit and refuse contexts that could blur it.

function Test-NetworkPath {
    param([string]$Path)
    if ($Path -like '\\*') { return $true }
    try {
        $root = [IO.Path]::GetPathRoot($Path)
        if ($root -match '^([A-Za-z]:)\\?$') {
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($Matches[1])'" -ErrorAction Stop
            return ($disk.DriveType -eq 4)
        }
    } catch {}
    $false
}

function Assert-LocalScope {
    if (Get-Variable -Name PSSenderInfo -Scope Global -ErrorAction SilentlyContinue) {
        throw 'Refusing to run: this is a remote PowerShell session. The toolkit only changes the device it runs on, so run it locally on that device.'
    }
    if (Test-NetworkPath $script:ToolkitRoot) {
        throw "Refusing to make changes while running from a network location ($($script:ToolkitRoot)). Copy the toolkit to a local drive (for example C:\MigrationToolkit) and run it from there."
    }
}

function Get-ToolkitTarget {
    $serial = ''; $guid = ''
    try { $serial = "$((Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber)".Trim() } catch {}
    try { $guid = "$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid)" } catch {}
    [pscustomobject]@{
        ComputerName   = $env:COMPUTERNAME
        Serial         = $serial
        MachineGuid    = $guid
        User           = "$env:USERDOMAIN\$env:USERNAME"
        NetworkAccount = [bool]($env:USERDOMAIN -and $env:USERDOMAIN -ne $env:COMPUTERNAME -and $env:USERDOMAIN -notin 'AzureAD', 'NT AUTHORITY')
    }
}

# ----------------------------------------------------------------------------- group tags
# Tags come from Config\toolkit.json (built in) plus any the user adds (Config\grouptags.user.json,
# or ProgramData when the toolkit folder is read-only).

$script:AdminMarker = 'Temporary migration admin (remove after migration)'

function Get-UserTagPath {
    @((Join-Path $script:ToolkitRoot 'Config\grouptags.user.json'), (Join-Path $script:DataRoot 'grouptags.user.json'))
}

function Read-UserGroupTag {
    $tags = New-Object System.Collections.Generic.List[string]
    foreach ($p in (Get-UserTagPath)) {
        if (-not (Test-Path $p)) { continue }
        try {
            $j = Get-Content $p -Raw | ConvertFrom-Json
            foreach ($t in @($j.tags)) { $s = "$t".Trim(); if ($s -and ($tags -notcontains $s)) { $tags.Add($s) } }
        } catch { Write-ToolkitLog "Ignoring unreadable tag file $p" 'WARN' }
    }
    $tags.ToArray()
}

function Get-GroupTagList {
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($t in (@((Get-ToolkitConfig).groupTags) + @(Read-UserGroupTag))) {
        $s = "$t".Trim()
        if ($s -and ($all -notcontains $s)) { $all.Add($s) }
    }
    $all.ToArray()
}

# Returns an error message, or an empty string when the name is acceptable.
function Test-GroupTagName {
    param([string]$Name)
    $n = "$Name".Trim()
    if (-not $n) { return 'Enter a group tag.' }
    if ($n.Length -gt 128) { return 'A group tag can be at most 128 characters.' }
    if ($n -notmatch '^[A-Za-z0-9][A-Za-z0-9 _.\-]*$') { return 'Use letters, numbers, spaces, hyphens, underscores and dots only (start with a letter or number).' }
    ''
}

function Save-UserGroupTag {
    param([string[]]$Tags)
    $json = ConvertTo-Json -InputObject @{ tags = @($Tags) } -Depth 3
    foreach ($p in (Get-UserTagPath)) {
        try {
            $dir = Split-Path $p
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Set-Content -Path $p -Value $json -Encoding UTF8
            return $p
        } catch {}
    }
    throw 'Could not save the group tag (no writable location).'
}

function Add-GroupTag {
    param([Parameter(Mandatory)][string]$Name)
    $n = $Name.Trim()
    $err = Test-GroupTagName $n
    if ($err) { throw "Invalid group tag '$n': $err" }
    $existing = @(Get-GroupTagList | Where-Object { $_ -ieq $n })
    if ($existing.Count -gt 0) { Write-ToolkitLog "Group tag '$($existing[0])' already exists."; return $existing[0] }
    $where = Save-UserGroupTag (@(Read-UserGroupTag) + $n)
    Write-ToolkitLog "Group tag '$n' saved ($where)." 'OK'
    $n
}

function Remove-GroupTag {
    param([Parameter(Mandatory)][string]$Name)
    $n = $Name.Trim()
    if (@((Get-ToolkitConfig).groupTags | Where-Object { $_ -ieq $n }).Count -gt 0) { throw "'$n' is a built-in tag from Config\toolkit.json. Edit that file to remove it." }
    $removed = $false
    foreach ($p in (Get-UserTagPath)) {
        if (-not (Test-Path $p)) { continue }
        try {
            $keep = @((Get-Content $p -Raw | ConvertFrom-Json).tags | Where-Object { $_ -and $_ -ine $n })
            ConvertTo-Json -InputObject @{ tags = $keep } -Depth 3 | Set-Content -Path $p -Encoding UTF8
            $removed = $true
        } catch {}
    }
    if ($removed) { Write-ToolkitLog "Group tag '$n' removed from your saved tags. CSV files already written keep their tag." 'OK' }
    else { Write-ToolkitLog "Group tag '$n' was not in your saved tags." 'WARN' }
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
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.WaitForExit(15000)) {
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
            try { $p.Kill() } catch {}
            throw "Timed out after $TimeoutSec s: $FilePath $ArgumentText"
        }
        Write-ToolkitLog ("  still running ({0}s)..." -f [int]$sw.Elapsed.TotalSeconds)
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
                    DisplayName = $name; Publisher = $item.Publisher; Version = $item.DisplayVersion; KeyName = $item.PSChildName
                    UninstallString = $item.UninstallString; QuietUninstallString = $item.QuietUninstallString })
                break
            }
        }
    }
    $out.ToArray()
}

# Matches by product name OR publisher, so older AirWatch agents and rebranded Hub builds are both found.
function Get-WorkspaceOneProgram {
    $cfg = Get-ToolkitConfig
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($p in @(Get-InstalledProgram -NamePattern '*')) {
        $hit = $false
        foreach ($n in $cfg.ws1Names) { if ($p.DisplayName -like $n) { $hit = $true; break } }
        if (-not $hit -and $p.Publisher) { foreach ($pub in $cfg.ws1Publishers) { if ($p.Publisher -like $pub) { $hit = $true; break } } }
        if ($hit) { $out.Add($p) }
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

    $tg = Get-ToolkitTarget
    $r.Add((New-Check 'Target device' 'Info' "$($tg.ComputerName), serial $($tg.Serial). Every change is made to this device only."))

    $remote = [bool](Get-Variable -Name PSSenderInfo -Scope Global -ErrorAction SilentlyContinue)
    $r.Add((New-Check 'Local session' $(if ($remote) { 'Fail' } else { 'Pass' }) $(if ($remote) { 'Remote PowerShell session: run the toolkit on the device itself' } else { 'Not a remote session' })))
    $onNet = Test-NetworkPath $script:ToolkitRoot
    $r.Add((New-Check 'Toolkit location' $(if ($onNet) { 'Fail' } else { 'Pass' }) $(if ($onNet) { "Running from a network path ($($script:ToolkitRoot)); copy it to a local drive first" } else { $script:ToolkitRoot })))
    if ($tg.NetworkAccount) {
        $r.Add((New-Check 'Signed-in account' 'Warn' "$($tg.User) is a network (domain) account. Its profile will not be usable once the device leaves the domain; plan to continue with the local admin."))
    } else {
        $r.Add((New-Check 'Signed-in account' 'Info' $tg.User))
    }

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

    $hub = @(Get-WorkspaceOneProgram)
    $enr = @(Get-MdmEnrollment | Where-Object { $_.Kind -eq 'WorkspaceONE' })
    $r.Add((New-Check 'Workspace ONE' 'Info' ("Programs: {0}; MDM enrollments: {1}" -f $hub.Count, $enr.Count)))
    $sc = Get-SccmClientStatus
    $r.Add((New-Check 'SCCM client' 'Info' $(if ($sc.ServiceInstalled -or $sc.SetupPresent) { 'Present' } else { 'Not present' })))
    $intune = @(Get-MdmEnrollment | Where-Object { $_.Kind -eq 'Intune' })
    $r.Add((New-Check 'Intune enrollment' 'Info' $(if ($intune.Count) { 'Enrolled' } else { 'Not enrolled' })))

    $r.ToArray()
}

# ----------------------------------------------------------------------------- Workspace ONE / SCCM removal

function Test-SafeCleanupPath {
    param([string]$Path)
    if (-not $Path -or $Path -match '[\*\?]') { return $false }
    $deny = 'Microsoft', 'Windows', 'Classes', 'Policies', 'WOW6432Node', 'Clients', 'RegisteredApplications', 'Common Files', 'WindowsApps', 'Package Cache', 'Packages', 'Microsoft Corporation'
    if ($Path -like 'HKLM:*') {
        if ($Path -match '^HKLM:\\SOFTWARE\\(?:WOW6432Node\\)?(?<k>[^\\]+)(\\.*)?$') { return ($Matches['k'] -notin $deny) }
        return $false
    }
    try { $full = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)).TrimEnd('\') } catch { return $false }
    foreach ($root in @($env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $root) { continue }
        $r = $root.TrimEnd('\') + '\'
        if ($full.StartsWith($r, [StringComparison]::OrdinalIgnoreCase) -and $full.Length -gt $r.Length) {
            return ($full.Substring($r.Length).Split('\')[0] -notin $deny)
        }
    }
    $false
}

function Remove-MdmEnrollmentArtifact {
    param([Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f-]{36}$')][string]$EnrollmentId)
    $provider = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments\$EnrollmentId" -ErrorAction SilentlyContinue).ProviderID
    if ($provider -eq 'MS DM Server') { throw "Refusing to remove enrollment ${EnrollmentId}: it is the Intune enrollment." }
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

function Get-WorkspaceOneAppx {
    $cfg = Get-ToolkitConfig
    $out = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($pkg in (Get-AppxPackage -AllUsers -ErrorAction Stop)) {
            foreach ($pat in $cfg.ws1AppxNames) {
                if ($pkg.Name -like $pat -or $pkg.PackageFamilyName -like $pat) { $out.Add($pkg); break }
            }
        }
    } catch { Write-ToolkitLog "Could not enumerate Store apps: $($_.Exception.Message)" 'WARN' }
    $out.ToArray()
}

function Get-WorkspaceOneInventory {
    $cfg = Get-ToolkitConfig
    [pscustomobject]@{
        Programs    = @(Get-WorkspaceOneProgram)
        Appx        = @(Get-WorkspaceOneAppx)
        Enrollments = @(Get-MdmEnrollment | Where-Object { $_.Kind -eq 'WorkspaceONE' })
    }
}

# Everything Workspace ONE / AirWatch can leave behind. Fix = 'auto' (the toolkit removes it) or 'manual' (reported only).
function Get-WorkspaceOneResidue {
    $cfg = Get-ToolkitConfig
    $out = New-Object System.Collections.Generic.List[object]
    $add = { param($Cat, $Item, $Detail, $Fix) $out.Add([pscustomobject]@{ Category = $Cat; Item = $Item; Detail = $Detail; Fix = $Fix }) }

    foreach ($x in @(Get-WorkspaceOneProgram)) { & $add 'Program' $x.DisplayName "$($x.Version) ($($x.Publisher))" 'auto' }
    foreach ($x in @(Get-WorkspaceOneAppx)) { & $add 'Store app' $x.Name $x.PackageFullName 'auto' }
    foreach ($x in @(Get-MdmEnrollment | Where-Object { $_.Kind -eq 'WorkspaceONE' })) { & $add 'MDM enrollment' $x.Id $x.ProviderId 'auto' }

    try {
        foreach ($sv in @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.Name -match 'AirWatch|AWService|Workspace ?ONE' -or $_.DisplayName -match 'AirWatch|Workspace ONE' -or $_.PathName -match 'AirWatch|Workspace ?ONE' })) {
            & $add 'Service' $sv.Name "$($sv.State); $($sv.PathName)" 'auto'
        }
    } catch {}
    try {
        foreach ($pr in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -match 'AirWatch|Workspace ?ONE' })) { & $add 'Process' "$($pr.ProcessName) ($($pr.Id))" $pr.Path 'auto' }
    } catch {}
    try {
        $liveIds = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
        foreach ($tk in @(Get-ScheduledTask -ErrorAction Stop)) {
            $orphan = ($tk.TaskPath -match 'EnterpriseMgmt\\([0-9A-Fa-f-]{36})\\' -and $liveIds -notcontains $Matches[1])
            if ($orphan -or $tk.TaskPath -match 'AirWatch|Workspace ?ONE' -or $tk.TaskName -match 'AirWatch|Workspace ?ONE') { & $add 'Scheduled task' "$($tk.TaskPath)$($tk.TaskName)" '' 'auto' }
        }
    } catch {}
    foreach ($raw in $cfg.ws1CleanupPaths) {
        if (-not (Test-SafeCleanupPath $raw)) { continue }
        $path = [Environment]::ExpandEnvironmentVariables($raw)
        if (Test-Path $path) { & $add $(if ($raw -like 'HKLM:*') { 'Registry key' } else { 'Folder' }) $path '' 'auto' }
    }
    try {
        foreach ($c in @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop | Where-Object { $_.Issuer -match 'AirWatch|Workspace ONE' -or $_.Subject -match 'AirWatch' })) { & $add 'Device certificate' $c.Thumbprint $c.Subject 'auto' }
        foreach ($c in @(Get-ChildItem Cert:\LocalMachine\Root, Cert:\LocalMachine\CA -ErrorAction Stop | Where-Object { $_.Subject -match 'AirWatch|Workspace ONE' })) { & $add 'CA certificate' $c.Thumbprint $c.Subject 'manual' }
    } catch {}
    try {
        foreach ($pk in @(Get-ProvisioningPackage -AllInstalledPackages -ErrorAction Stop | Where-Object { $_.PackageName -match 'AirWatch|Workspace|WS1' })) { & $add 'Provisioning package' $pk.PackageName $pk.PackageId 'manual' }
    } catch {}
    try {
        foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Classes\Installer\Products' -ErrorAction Stop)) {
            $pn = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).ProductName
            if ($pn -match 'AirWatch|Workspace ONE') { & $add 'Orphan installer record' $pn $k.PSChildName 'manual' }
        }
    } catch {}
    try {
        foreach ($d in @(Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction Stop)) {
            foreach ($sub in 'AppData\Local\AirWatch', 'AppData\Roaming\AirWatch') { $pp = Join-Path $d.FullName $sub; if (Test-Path $pp) { & $add 'User data folder' $pp '' 'manual' } }
        }
    } catch {}
    $out.ToArray()
}

# Removes the residue the toolkit can safely remove (services, processes, tasks, device certificates).
function Remove-WorkspaceOneResidue {
    foreach ($r in @(Get-WorkspaceOneResidue)) {
        switch ($r.Category) {
            'Process' { $id = [int](($r.Item -replace '^.*\((\d+)\)$', '$1')); Invoke-Mutation "stop process $($r.Item)" { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } | Out-Null }
            'Service' { $nm = $r.Item; Invoke-Mutation "stop and delete service $nm" { Stop-Service -Name $nm -Force -ErrorAction SilentlyContinue; & sc.exe delete $nm | Out-Null } | Out-Null }
            'Scheduled task' {
                $full = $r.Item
                Invoke-Mutation "remove scheduled task $full" {
                    $tp = $full.Substring(0, $full.LastIndexOf('\') + 1); $tn = $full.Substring($full.LastIndexOf('\') + 1)
                    Unregister-ScheduledTask -TaskPath $tp -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
                } | Out-Null
            }
            'Device certificate' { $th = $r.Item; Invoke-Mutation "remove device certificate $th from LocalMachine\My" { Remove-Item "Cert:\LocalMachine\My\$th" -Force -ErrorAction SilentlyContinue } | Out-Null }
        }
    }
}

# The "is it really gone" check. Returns check rows for the GUI; -Clean first removes what the toolkit can.
function Test-WorkspaceOneRemoval {
    param([switch]$Clean)
    if ($Clean) { Remove-WorkspaceOneResidue }
    $res = @(Get-WorkspaceOneResidue)
    $auto = @($res | Where-Object { $_.Fix -eq 'auto' })
    $manual = @($res | Where-Object { $_.Fix -eq 'manual' })
    $rows = New-Object System.Collections.Generic.List[object]
    if ($res.Count -eq 0) {
        Write-ToolkitLog 'Workspace ONE is completely gone: no programs, Store apps, enrollments, services, tasks, folders, registry keys or certificates found.' 'OK'
        $rows.Add((New-Check 'Workspace ONE removal' 'Pass' 'Nothing left on this device'))
    } else {
        $verdict = 'Warn'; if ($auto.Count -gt 0) { $verdict = 'Fail' }
        $rows.Add((New-Check 'Workspace ONE removal' $verdict ("{0} item(s) still present ({1} removable by the toolkit, {2} to check by hand). A restart may release locked items." -f $res.Count, $auto.Count, $manual.Count)))
        foreach ($r in $res) {
            $lvl = 'ERROR'; $st = 'Fail'; if ($r.Fix -eq 'manual') { $lvl = 'WARN'; $st = 'Warn' }
            Write-ToolkitLog ("Left behind - {0}: {1} {2}" -f $r.Category, $r.Item, $r.Detail) $lvl
            $rows.Add((New-Check $r.Category $st ("$($r.Item) $($r.Detail)").Trim()))
        }
    }
    $rows.ToArray()
}

# Asks Windows itself to unenroll (mdmregistration.dll). Returns the HRESULT, or -1 if the call could not be made.
function Invoke-MdmUnenroll {
    param([Parameter(Mandatory)][string]$EnrollmentId)
    try {
        if (-not ('Toolkit.MdmNative' -as [type])) {
            Add-Type -Namespace Toolkit -Name MdmNative -MemberDefinition '[System.Runtime.InteropServices.DllImport("mdmregistration.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern int UnregisterDeviceWithManagement(string enrollmentID);'
        }
        [Toolkit.MdmNative]::UnregisterDeviceWithManagement($EnrollmentId)
    } catch {
        Write-ToolkitLog "UnregisterDeviceWithManagement could not be called: $($_.Exception.Message)" 'WARN'
        -1
    }
}

function Remove-WorkspaceOne {
    $cfg = Get-ToolkitConfig
    $programs = @(Get-WorkspaceOneProgram)
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

    foreach ($pkg in @(Get-WorkspaceOneAppx)) {
        Write-ToolkitLog "Removing Store app $($pkg.Name)" 'STEP'
        Invoke-Mutation "remove app package $($pkg.PackageFullName) for all users" {
            try { Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop } catch { Write-ToolkitLog "  $($_.Exception.Message)" 'WARN' }
        } | Out-Null
    }

    $enrollments = @(Get-MdmEnrollment | Where-Object { $_.Kind -eq 'WorkspaceONE' })
    foreach ($e in $enrollments) {
        Write-ToolkitLog "Unenrolling Workspace ONE MDM enrollment $($e.Id) through Windows" 'STEP'
        $hr = Invoke-Mutation "call UnregisterDeviceWithManagement for $($e.Id)" { Invoke-MdmUnenroll -EnrollmentId $e.Id }
        if ($null -ne $hr) {
            Write-ToolkitLog ("  UnregisterDeviceWithManagement returned 0x{0:X8}" -f [int]$hr)
            Start-Sleep -Seconds 5
        }
        $still = @(Get-MdmEnrollment | Where-Object { $_.Id -eq $e.Id })
        if ($script:DryRun -or $still.Count -gt 0) {
            if (-not $script:DryRun) { Write-ToolkitLog 'Enrollment still present; falling back to registry cleanup (policies pushed by WS1 may linger).' 'WARN' }
            Remove-MdmEnrollmentArtifact -EnrollmentId $e.Id
        }
    }

    foreach ($rawPath in $cfg.ws1CleanupPaths) {
        $path = [Environment]::ExpandEnvironmentVariables($rawPath)
        if (-not (Test-SafeCleanupPath $rawPath)) { Write-ToolkitLog "Skipping cleanup path outside the allowed areas: $rawPath" 'WARN'; continue }
        if (Test-Path $path) { Invoke-Mutation "remove leftover $path" { Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue } | Out-Null }
    }

    Remove-WorkspaceOneResidue

    if (-not $script:DryRun) {
        $left = @(Get-WorkspaceOneProgram)
        $leftEnr = @(Get-MdmEnrollment | Where-Object { $_.Kind -eq 'WorkspaceONE' })
        $leftAppx = @(Get-WorkspaceOneAppx)
        $svc = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*AirWatch*' -or $_.DisplayName -like '*Workspace ONE*' })
        if ($left.Count -eq 0 -and $leftEnr.Count -eq 0 -and $leftAppx.Count -eq 0) {
            Write-ToolkitLog 'Workspace ONE removal verified (no programs, Store apps or MDM enrollment). A restart is recommended before the next step.' 'OK'
            if ($svc.Count) { Write-ToolkitLog ("Services still registered until reboot: " + (($svc | ForEach-Object { $_.DisplayName }) -join ', ')) 'WARN' }
            Set-StepState 'RemoveWS1' 'Done'
        } else {
            Write-ToolkitLog "Workspace ONE removal incomplete: $($left.Count) program(s), $($leftAppx.Count) Store app(s), $($leftEnr.Count) enrollment(s) remain." 'ERROR'
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

function Get-ToolkitAdminName {
    $n = "$((Get-ToolkitConfig).localAdminName)".Trim()
    if ($n -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,19}$' -or $n -in 'Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount', 'SYSTEM') {
        throw "localAdminName '$n' in Config\toolkit.json is not allowed. Use a new account name such as MigAdmin."
    }
    $n
}

function New-ToolkitLocalAdmin {
    param([Parameter(Mandatory)][securestring]$Password)
    $name = Get-ToolkitAdminName
    $u = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    if ($u -and $u.Description -ne $script:AdminMarker) {
        throw "A local account named '$name' already exists and was not created by this toolkit, so it will not be changed. Pick another localAdminName in Config\toolkit.json."
    }
    if ($u) {
        Invoke-Mutation "reset password and enable local account '$name'" { Set-LocalUser -Name $name -Password $Password; Enable-LocalUser -Name $name } | Out-Null
    } else {
        Invoke-Mutation "create local administrator '$name'" {
            New-LocalUser -Name $name -Password $Password -PasswordNeverExpires -AccountNeverExpires -Description $script:AdminMarker | Out-Null
            Add-LocalGroupMember -Group 'Administrators' -Member $name
        } | Out-Null
    }
    Write-ToolkitLog "Local admin '$name' ready. Remove it when migration is finished (Maintenance tab)." 'OK'
}

function Remove-ToolkitLocalAdmin {
    $name = Get-ToolkitAdminName
    $u = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    if (-not $u) { Write-ToolkitLog "Local account '$name' does not exist."; return }
    if ($u.Description -ne $script:AdminMarker) { throw "Local account '$name' was not created by this toolkit, so it will not be deleted." }
    Invoke-Mutation "delete local account '$name'" { Remove-LocalUser -Name $name } | Out-Null
    Write-ToolkitLog "Local admin '$name' removed." 'OK'
}

function Invoke-DomainUnjoin {
    param([pscredential]$Credential, [switch]$OfflineUnjoin)
    $cs = Get-CimInstance Win32_ComputerSystem
    if (-not $cs.PartOfDomain) { Write-ToolkitLog 'Device is not domain joined.'; Set-StepState 'UnjoinAD' 'Skipped' 'Not domain joined'; return }
    $admins = @(Get-LocalAdminCandidate)
    if ($admins.Count -eq 0) { throw 'Refusing to unjoin: no enabled local administrator exists. Create one first (Maintenance tab).' }
    Write-ToolkitLog "Local admin(s) available after unjoin: $($admins -join ', ')"
    $hasCred = [bool]($Credential -and $Credential.UserName)
    if (-not $hasCred -and -not $OfflineUnjoin) { throw 'AD credentials are required (or choose offline unjoin).' }
    # Remove-Computer is called without -ComputerName on purpose: it can only act on this device.
    # The domain credential is used for that one call (to delete this computer's own AD object) and is not kept.

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

$script:StopFlag = Join-Path $script:DataRoot 'stop.flag'
function Request-ToolkitStop { Set-Content -Path $script:StopFlag -Value (Get-Date).ToString('s') -ErrorAction SilentlyContinue }

# True when Windows has recorded an Entra join (a JoinInfo subkey exists); dsregcmd then confirms.
function Test-EntraJoinHint {
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo'
    (Test-Path $k) -and (@(Get-ChildItem $k -ErrorAction SilentlyContinue).Count -gt 0)
}

function Start-EntraJoin {
    param([int]$TimeoutMin = 10)
    $js = Get-JoinState
    if ($js.AzureAdJoined) { Write-ToolkitLog "Already Entra joined (tenant: $($js.TenantName))." 'OK'; Set-StepState 'JoinEntra' 'Done'; return }
    if ($js.DomainJoined) { throw 'Device is still domain joined. Unjoin Active Directory and restart first.' }
    if (-not (Test-TcpPort 'login.microsoftonline.com' 443)) { throw 'Cannot reach login.microsoftonline.com:443. Fix the network connection before joining Entra ID.' }

    $ppkg = @(Get-ChildItem -Path (Join-Path $script:ToolkitRoot 'Tools') -Filter '*.ppkg' -ErrorAction SilentlyContinue)
    if ($ppkg.Count -gt 1) { Write-ToolkitLog "More than one .ppkg in Tools\ - using $($ppkg[0].Name). Remove the others to be sure which tenant you join." 'WARN' }
    $ppkgHash = ''; if ($ppkg.Count -gt 0) { $ppkgHash = (Get-FileHash -Path $ppkg[0].FullName -Algorithm SHA256).Hash }
    $ppkgTrusted = ($ppkg.Count -gt 0) -and (Test-ToolTrusted ([pscustomobject]@{ SignatureStatus = 'n/a'; Sha256 = $ppkgHash }))
    if ($ppkg.Count -gt 0 -and -not $ppkgTrusted) { Write-ToolkitLog "Provisioning package $($ppkg[0].Name) is NOT in trustedToolHashes, so it will not be installed silently (a package can join any tenant). SHA-256: $ppkgHash. Add the hash to Config\toolkit.json if it is yours; using the manual join instead." 'WARN' }
    if ($ppkgTrusted) {
        Write-ToolkitLog "Provisioning package found: $($ppkg[0].Name) sha256=$((Get-FileHash -Path $ppkg[0].FullName -Algorithm SHA256).Hash) - installing silently" 'STEP'
        Invoke-Mutation "install provisioning package $($ppkg[0].Name)" { Install-ProvisioningPackage -PackagePath $ppkg[0].FullName -QuietInstall -ForceInstall -ErrorAction Stop } | Out-Null
    } else {
        Write-ToolkitLog 'Opening Settings > Accounts > Access work or school. Choose Connect, then "Join this device to Microsoft Entra ID" and sign in.' 'STEP'
        Invoke-Mutation 'open ms-settings:workplace' { Start-Process 'ms-settings:workplace' } | Out-Null
    }
    if ($script:DryRun) { return }

    Write-ToolkitLog "Waiting for you to finish the sign-in. Checking every 3 seconds; this ends the moment the join completes (gives up after $TimeoutMin minutes, or press Stop)." 'STEP'
    if (Test-Path $script:StopFlag) { Remove-Item $script:StopFlag -Force -ErrorAction SilentlyContinue }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastNote = 0; $lastCheck = 0
    while ($sw.Elapsed.TotalMinutes -lt $TimeoutMin) {
        Start-Sleep -Seconds 3
        if (Test-Path $script:StopFlag) {
            Remove-Item $script:StopFlag -Force -ErrorAction SilentlyContinue
            Write-ToolkitLog 'Stopped by you. Run this step again when you are ready.' 'WARN'
            Set-StepState 'JoinEntra' 'Failed' 'Stopped by user'
            return
        }
        # Cheap registry check first; dsregcmd (about a second) only confirms when it looks joined.
        # The registry hint is only a shortcut: dsregcmd is also checked every 15 seconds regardless, so a wrong hint can never miss a join.
        $dueCheck = ($sw.Elapsed.TotalSeconds - $lastCheck) -ge 15
        if (-not $dueCheck -and -not (Test-EntraJoinHint)) {
            if ($sw.Elapsed.TotalSeconds - $lastNote -ge 30) { $lastNote = $sw.Elapsed.TotalSeconds; Write-ToolkitLog ("  still waiting for the join ({0}s)..." -f [int]$sw.Elapsed.TotalSeconds) }
            continue
        }
        $lastCheck = $sw.Elapsed.TotalSeconds
        $js = Get-JoinState
        if ($js.AzureAdJoined) {
            Write-ToolkitLog "Entra join confirmed (tenant: $($js.TenantName)). Restart, then sign in as the Entra user." 'OK'
            Set-StepState 'JoinEntra' 'Done' $js.TenantName
            return
        }
    }
    Write-ToolkitLog "No Entra join detected after $TimeoutMin minutes. Re-run this step once the join completes." 'ERROR'
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

# Optional: wait until Intune shows this device as compliant (signs in to Graph; read-only).
function Wait-IntuneReady {
    param([int]$TimeoutMin = 15)
    Connect-IntuneGraph
    $serial = (Get-ToolkitTarget).Serial
    $q = $serial -replace "'", "''"
    $base = 'https://graph.microsoft.com/v1.0/deviceManagement'
    $ap = Invoke-MgGraphRequest -Method GET -Uri ($base + "/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$q')")
    $mine = @($ap.value | Where-Object { $_.serialNumber -eq $serial })
    if ($mine.Count -gt 0) { Write-ToolkitLog "Autopilot: groupTag='$($mine[0].groupTag)', profile status '$($mine[0].deploymentProfileAssignmentStatus)'." }
    else { Write-ToolkitLog 'This serial is not registered in Autopilot (fine for an in-place join).' }
    $sw = [Diagnostics.Stopwatch]::StartNew(); $last = -30
    if (Test-Path $script:StopFlag) { Remove-Item $script:StopFlag -Force -ErrorAction SilentlyContinue }
    while ($sw.Elapsed.TotalMinutes -lt $TimeoutMin) {
        $md = Invoke-MgGraphRequest -Method GET -Uri ($base + "/managedDevices?`$filter=serialNumber%20eq%20'$q'")
        $dev = @($md.value)[0]
        if ($dev) {
            if ($dev.complianceState -eq 'compliant') { Write-ToolkitLog "Intune reports '$($dev.deviceName)' as compliant (last sync $($dev.lastSyncDateTime))." 'OK'; return 'compliant' }
            if ($sw.Elapsed.TotalSeconds - $last -ge 30) { $last = $sw.Elapsed.TotalSeconds; Write-ToolkitLog "Intune sees the device; compliance is '$($dev.complianceState)'. Waiting..." }
        } elseif ($sw.Elapsed.TotalSeconds - $last -ge 30) { $last = $sw.Elapsed.TotalSeconds; Write-ToolkitLog 'Device not visible in Intune yet. Waiting...' }
        if (Test-Path $script:StopFlag) { Remove-Item $script:StopFlag -Force -ErrorAction SilentlyContinue; throw 'Stopped by you.' }
        Start-Sleep -Seconds 10
    }
    throw "Intune did not report the device as compliant within $TimeoutMin minutes (it may still be applying policy)."
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
        $mi = Get-ToolFileInfo -Path $msi
        Write-ToolkitLog "Profwiz.msi: signature=$($mi.SignatureStatus) sha256=$($mi.Sha256)"
        if (-not (Test-ToolTrusted $mi)) { throw "Profwiz.msi is not validly signed and its hash is not in trustedToolHashes (Config\toolkit.json). SHA-256: $($mi.Sha256)" }
        Write-ToolkitLog 'Installing User Profile Wizard from Profwiz.msi' 'STEP'
        Invoke-Mutation 'run Profwiz.msi installer (interactive)' { Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$msi`"" -Wait } | Out-Null
        $installed = Get-ChildItem -Path "${env:ProgramFiles(x86)}\ForensiT", "$env:ProgramFiles\ForensiT" -Filter 'Profwiz.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($installed) { $target = $installed.FullName }
    }
    if (-not $target) { if ($script:DryRun) { Write-ToolkitLog 'DRY-RUN: Profwiz not found yet' 'WARN'; return }; throw "Profwiz.exe / Profwiz.msi not found. Copy them into $tools" }

    $info = Get-ToolFileInfo -Path $target
    Write-ToolkitLog "Profwiz: signature=$($info.SignatureStatus) signer=$($info.Signer) sha256=$($info.Sha256)"
    if (-not (Test-ToolTrusted $info)) {
        $msg = "Profwiz is not validly signed and its hash is not in trustedToolHashes (Config\toolkit.json). SHA-256: $($info.Sha256). If you verified this file yourself, add that hash to the list."
        if ($script:DryRun) { Write-ToolkitLog "DRY-RUN: $msg" 'WARN' } else { throw $msg }
    }
    Write-ToolkitLog 'Launching User Profile Wizard (GUI). Sign in as the new Entra user first, run as administrator, and pick the old domain profile.' 'STEP'
    Invoke-Mutation "launch $target" { Start-Process -FilePath $target -Wait } | Out-Null
    Set-StepState 'ProfileWizard' 'Done' 'Launched; confirm result manually'
}

# A tool runs elevated, so it must be validly signed or its SHA-256 must be listed in Config\toolkit.json (trustedToolHashes).
function Test-ToolTrusted {
    param([Parameter(Mandatory)]$Info)
    if ($Info.SignatureStatus -eq 'Valid') { return $true }
    $trusted = @((Get-ToolkitConfig).trustedToolHashes | ForEach-Object { "$_".Trim().ToUpper() })
    $trusted -contains "$($Info.Sha256)".ToUpper()
}

function Invoke-ToolExecutable {
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path (Join-Path $script:ToolkitRoot 'Tools') $Name
    if (-not (Test-Path $path)) { throw "$Name not found in Tools folder." }
    $info = Get-ToolFileInfo -Path $path
    Write-ToolkitLog "$Name signature=$($info.SignatureStatus) signer=$($info.Signer) sha256=$($info.Sha256)"
    if (-not (Test-ToolTrusted $info)) { Write-ToolkitLog "$Name is not validly signed and its hash is not in trustedToolHashes (Config\toolkit.json). Not running it. SHA-256: $($info.Sha256)" 'ERROR'; return }
    Invoke-Mutation "run $Name (interactive, waits for exit)" { Start-Process -FilePath $path -Wait } | Out-Null
    Write-ToolkitLog "$Name finished." 'OK'
}

function Invoke-Debloat {
    $cfg = Get-ToolkitConfig
    $protected = '^(Microsoft\.WindowsStore|Microsoft\.StorePurchaseApp|Microsoft\.DesktopAppInstaller|Microsoft\.SecHealthUI|Microsoft\.AAD\.BrokerPlugin|Microsoft\.Windows\.|MicrosoftWindows\.|windows\.|Microsoft\.UI\.Xaml|Microsoft\.VCLibs|Microsoft\.NET\.|Microsoft\.WindowsAppRuntime|Microsoft\.LockApp|Microsoft\.Win32WebViewHost|MicrosoftEdge)'
    foreach ($n in $cfg.debloat) {
        # A too-short or wildcard entry would match half of Windows, so it is skipped; system, framework and protected packages are never removed.
        if ("$n".Trim().Length -lt 6 -or "$n" -match '[\*\?]') { Write-ToolkitLog "Skipping debloat entry '$n': it must be at least 6 characters with no wildcards." 'WARN'; continue }
        foreach ($pkg in @(Get-AppxPackage -AllUsers | Where-Object { ($_.Name -like "*$n*" -or $_.PackageFamilyName -like "*$n*") -and -not $_.IsFramework -and $_.SignatureKind -ne 'System' -and $_.Name -notmatch $protected })) {
            Invoke-Mutation "remove app package $($pkg.Name) for all users" {
                try { Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop } catch { Write-ToolkitLog "  $($pkg.Name): $($_.Exception.Message)" 'WARN' }
            } | Out-Null
        }
        foreach ($prov in @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "*$n*" -and $_.DisplayName -notmatch $protected })) {
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

function Get-HashCsvPath {
    param([string]$OutputFolder)
    if (-not $OutputFolder) { $OutputFolder = Join-Path $script:ToolkitRoot 'Output\Autopilot' }
    $serial = (Get-CimInstance Win32_BIOS).SerialNumber.Trim()
    Join-Path $OutputFolder ("{0}_AutoPilotSetup.csv" -f ($serial -replace '[^\w-]', '_'))
}

function Invoke-AutopilotCapture {
    param([string]$GroupTag = '', [string]$OutputFolder)
    if (-not $OutputFolder) { $OutputFolder = Join-Path $script:ToolkitRoot 'Output\Autopilot' }
    $GroupTag = "$GroupTag".Trim()
    if (-not $GroupTag) { Write-ToolkitLog 'No group tag selected - the device will be captured with an empty tag.' 'WARN' }
    else {
        $err = Test-GroupTagName $GroupTag
        if ($err) { throw "Group tag '$GroupTag' is not valid: $err" }
        if ((Get-GroupTagList) -notcontains $GroupTag) { Write-ToolkitLog "Group tag '$GroupTag' is not in your saved list (use Add group tag to keep it)." 'WARN' }
    }
    if (Test-NetworkPath $OutputFolder) { Write-ToolkitLog "Output folder $OutputFolder is a network location; the file is written with the signed-in account's network access." 'WARN' }
    $info = Get-AutopilotHardwareInfo
    $file = Get-HashCsvPath -OutputFolder $OutputFolder
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
    $tags = @(Get-GroupTagList)
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

function Disconnect-IntuneGraph {
    try { if ((Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue) -and (Get-MgContext)) { Disconnect-MgGraph | Out-Null; Write-ToolkitLog 'Signed out of Microsoft Graph.' } } catch {}
}

function Import-AutopilotToIntune {
    param([Parameter(Mandatory)][string]$CsvPath, [int]$TimeoutMin = 20)
    if (-not (Test-Path $CsvPath)) { throw "CSV not found: $CsvPath" }
    $rows = @(Import-Csv $CsvPath)
    $tags = @(Get-GroupTagList)
    foreach ($row in $rows) {
        $p = @(Test-AutopilotRow -Row $row -KnownGroupTags $tags)
        if ($p | Where-Object { $_ -like 'missing*' -or $_ -like '*base64*' }) { throw "Invalid row for '$($row.'Device Serial Number')': $($p -join '; ')" }
    }
    Connect-IntuneGraph
    $base = 'https://graph.microsoft.com/v1.0/deviceManagement'
    $results = New-Object System.Collections.Generic.List[object]
    $pending = @{}

    foreach ($row in $rows) {
        $serial = "$($row.'Device Serial Number')".Trim()
        $q = $serial -replace "'", "''"
        $existing = Invoke-MgGraphRequest -Method GET -Uri ($base + "/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$q')")
        if (@($existing.value | Where-Object { $_.serialNumber -eq $serial }).Count -gt 0) {
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
    $base = 'https://graph.microsoft.com/v1.0/deviceManagement'
    $ap = Invoke-MgGraphRequest -Method GET -Uri ($base + "/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$q')")
    $md = Invoke-MgGraphRequest -Method GET -Uri ($base + "/managedDevices?`$filter=serialNumber%20eq%20'$q'")
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($d in @($ap.value | Where-Object { $_.serialNumber -eq $Serial })) {
        $out.Add([pscustomobject]@{ Source = 'Autopilot'; Serial = $d.serialNumber; Detail = "groupTag=$($d.groupTag); profile=$($d.deploymentProfileAssignmentStatus); lastContact=$($d.lastContactedDateTime)" })
    }
    foreach ($d in @($md.value)) {
        $out.Add([pscustomobject]@{ Source = 'Intune'; Serial = $d.serialNumber; Detail = "name=$($d.deviceName); compliance=$($d.complianceState); lastSync=$($d.lastSyncDateTime); user=$($d.userPrincipalName)" })
    }
    if ($out.Count -eq 0) { Write-ToolkitLog "Serial $Serial not found in Autopilot or Intune." 'WARN' }
    foreach ($o in $out) { Write-ToolkitLog "[$($o.Source)] $($o.Serial) $($o.Detail)" }
    $out.ToArray()
}

# ----------------------------------------------------------------------------- data at risk / OneDrive / BitLocker prep

function Get-FolderSize {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    [long](Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
}

function Format-Size { param([long]$Bytes) if ($Bytes -ge 1GB) { '{0:N1} GB' -f ($Bytes / 1GB) } elseif ($Bytes -ge 1MB) { '{0:N0} MB' -f ($Bytes / 1MB) } else { '{0:N0} KB' -f ($Bytes / 1KB) } }

# Read-only. Shows, per local profile, what exists only on this disk (not in OneDrive) so nothing is lost by a wipe or a bad profile move.
function Get-DataAtRiskReport {
    $rows = New-Object System.Collections.Generic.List[object]
    $risk = $false
    $profiles = @()
    try { $profiles = @(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object { -not $_.Special -and $_.LocalPath -like "$env:SystemDrive\Users\*" }) } catch {}
    if ($profiles.Count -eq 0) { $rows.Add((New-Check 'Local profiles' 'Info' 'No user profiles found')) }
    foreach ($pr in $profiles) {
        $path = $pr.LocalPath; $name = Split-Path $path -Leaf
        Write-ToolkitLog "Scanning profile $name (Desktop, Documents, Pictures, Downloads, Outlook)..."
        $od = @(Get-ChildItem -LiteralPath $path -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue)
        $local = 0L; $kfm = New-Object System.Collections.Generic.List[string]; $notKfm = New-Object System.Collections.Generic.List[string]
        foreach ($f in 'Desktop', 'Documents', 'Pictures') {
            $inCloud = ($od | Where-Object { Test-Path (Join-Path $_.FullName $f) }).Count -gt 0
            $size = Get-FolderSize (Join-Path $path $f)
            if ($inCloud -and $size -eq 0) { $kfm.Add($f) } else { $notKfm.Add($f); $local += $size }
        }
        $downloads = Get-FolderSize (Join-Path $path 'Downloads')
        $pst = @(Get-ChildItem -LiteralPath $path -Recurse -Force -File -Include '*.pst', '*.ost' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\OneDrive' })
        $pstPst = @($pst | Where-Object { $_.Extension -ieq '.pst' })
        $detail = "OneDrive-backed: {0}; local only: {1} ({2}); Downloads {3}" -f $(if ($kfm.Count) { $kfm -join ', ' } else { 'none' }), $(if ($notKfm.Count) { $notKfm -join ', ' } else { 'none' }), (Format-Size $local), (Format-Size $downloads)
        $status = 'Pass'
        if ($local -gt 0 -or $pstPst.Count -gt 0) { $status = 'Warn'; $risk = $true }
        $rows.Add((New-Check "Profile $name" $status $detail))
        foreach ($f in $pstPst) { $rows.Add((New-Check "  PST file ($name)" 'Warn' ("{0} ({1}) is local only - copy it somewhere safe" -f $f.FullName, (Format-Size $f.Length)))) }
    }
    try {
        foreach ($dk in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | Where-Object { $_.DeviceID -ne $env:SystemDrive })) {
            $used = [long]($dk.Size - $dk.FreeSpace)
            $rows.Add((New-Check "Other drive $($dk.DeviceID)" $(if ($used -gt 100MB) { 'Warn' } else { 'Info' }) ("{0} used. Data on a second drive is not in any profile or OneDrive backup; check it before a wipe." -f (Format-Size $used))))
            if ($used -gt 100MB) { $risk = $true }
        }
    } catch {}
    if ($profiles.Count -gt 0) {
        if (Get-Process -Name OneDrive -ErrorAction SilentlyContinue) { $rows.Add((New-Check 'OneDrive client' 'Info' 'Running. Before cutover, confirm its tray icon says "Up to date" - this tool cannot see pending uploads.')) }
        else { $rows.Add((New-Check 'OneDrive client' 'Warn' 'Not running, so nothing is syncing right now.')) }
    }
    $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' -ErrorAction SilentlyContinue
    if ($pol -and ($pol.KFMSilentOptIn -or $pol.KFMOptInWithWizard)) { $rows.Add((New-Check 'OneDrive Known Folder Move policy' 'Pass' 'Configured on this device')) }
    else { $rows.Add((New-Check 'OneDrive Known Folder Move policy' 'Info' 'No KFM policy found. Turn it on in Intune before cutover so Desktop, Documents and Pictures are backed up.')) }
    $acct = Get-ItemProperty 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1' -ErrorAction SilentlyContinue
    if ($acct -and $acct.UserEmail) { $rows.Add((New-Check 'OneDrive (signed-in user)' 'Info' "Signed in as $($acct.UserEmail)")) }
    $ush = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
    if ($ush -and (@($ush.PSObject.Properties | Where-Object { "$($_.Value)" -like '\\*' }).Count -gt 0)) { $rows.Add((New-Check 'Folder redirection' 'Warn' 'The signed-in user has folders redirected to a network share; that data is not on this disk.')) ; $risk = $true }
    $summary = if ($risk) { New-Check 'Data at risk' 'Warn' 'Some data exists only on this disk. Back it up (OneDrive Known Folder Move, USMT or a copy) before continuing.' } else { New-Check 'Data at risk' 'Pass' 'Nothing found that exists only on this disk' }
    foreach ($r in (@($summary) + $rows.ToArray())) {
        $lvl = 'INFO'; if ($r.Status -eq 'Warn') { $lvl = 'WARN' }
        Write-ToolkitLog ("{0,-5} {1}: {2}" -f $r.Status.ToUpper(), $r.Name, $r.Detail) $lvl
    }
    @($summary) + $rows.ToArray()
}

# Makes sure a BitLocker recovery key exists before the device changes management, and escrows it to AD while still domain joined.
# (The Entra copy is made in the Intune step.) The key itself is never logged or written to disk.
function Initialize-BitLockerKey {
    try { $v = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop } catch { Write-ToolkitLog 'BitLocker is not available on this device; nothing to prepare.'; return 'Not available' }
    if ($v.ProtectionStatus -ne 'On' -and "$($v.VolumeStatus)" -notmatch 'Encrypted') { Write-ToolkitLog 'OS drive is not encrypted; nothing to prepare.'; return 'Not encrypted' }
    $kps = @($v.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
    if ($kps.Count -eq 0) {
        Invoke-Mutation 'add a BitLocker recovery password protector' { Add-BitLockerKeyProtector -MountPoint $env:SystemDrive -RecoveryPasswordProtector | Out-Null } | Out-Null
        if (-not $script:DryRun) { $kps = @((Get-BitLockerVolume -MountPoint $env:SystemDrive).KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }) }
    }
    if (-not $script:DryRun -and $kps.Count -eq 0) { throw 'The OS drive is encrypted but no recovery password could be created.' }
    if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
        foreach ($kp in $kps) {
            Invoke-Mutation "escrow BitLocker protector $($kp.KeyProtectorId) to Active Directory" {
                try { Backup-BitLockerKeyProtector -MountPoint $env:SystemDrive -KeyProtectorId $kp.KeyProtectorId | Out-Null } catch { Write-ToolkitLog "  AD escrow skipped: $($_.Exception.Message)" 'WARN' }
            } | Out-Null
        }
    }
    Write-ToolkitLog ("BitLocker: {0} recovery password protector(s) present. The key will be backed up to Entra ID after the join." -f $kps.Count) 'OK'
    "$($kps.Count) recovery protector(s)"
}

# ----------------------------------------------------------------------------- migration report

function New-MigrationReport {
    $t = Get-ToolkitTarget; $js = Get-JoinState
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Migration report - $($t.ComputerName)"); $lines.Add("Generated: $((Get-Date).ToString('s'))"); $lines.Add("Serial: $($t.Serial)"); $lines.Add("Signed in as: $($t.User)"); $lines.Add('')
    $lines.Add("Active Directory joined : $($js.DomainJoined) $($js.DomainName)")
    $lines.Add("Entra ID joined         : $($js.AzureAdJoined) $($js.TenantName)")
    $lines.Add("Intune enrolled         : $(@(Get-MdmEnrollment | Where-Object { $_.Kind -eq 'Intune' }).Count -gt 0)")
    $res = @(Get-WorkspaceOneResidue)
    $left = 'none (clean)'
    if ($res.Count -gt 0) { $left = "$($res.Count) item(s): " + ((@($res | ForEach-Object { $_.Category }) | Sort-Object -Unique) -join ', ') }
    $lines.Add("Workspace ONE leftovers : $left")
    $lines.Add("SCCM client present     : $((Get-SccmClientStatus).ServiceInstalled)")
    try { $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop; $lines.Add("BitLocker               : protection $($bl.ProtectionStatus), recovery passwords $(@($bl.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }).Count)") } catch { $lines.Add('BitLocker               : not available') }
    $adm = $false; try { $adm = [bool](Get-LocalUser -Name (Get-ToolkitAdminName) -ErrorAction SilentlyContinue) } catch {}
    $lines.Add("Temporary local admin   : $(if ($adm) { 'STILL PRESENT - remove it, or manage local admins with Windows LAPS' } else { 'not present' })")
    if ($adm) { Write-ToolkitLog 'The temporary local admin still exists. Remove it when no longer needed (a shared password across devices is a risk).' 'WARN' }
    $lines.Add(''); $lines.Add('Step results:')
    foreach ($st in @(Get-StepState)) { $lines.Add(("  {0,-14} {1,-8} {2}  {3}" -f $st.Step, $st.Status, $st.Time, $st.Detail)) }
    $dir = Join-Path $script:ToolkitRoot 'Output\Reports'
    $file = Join-Path $dir ("{0}_{1}.txt" -f ($t.Serial -replace '[^\w-]', '_'), (Get-Date -Format 'yyyyMMdd-HHmm'))
    Invoke-Mutation "write migration report to $file" {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $file -Value $lines -Encoding UTF8
    } | Out-Null
    if (-not $script:DryRun) {
        $failed = (@(Get-StepState | Where-Object { $_.Status -eq 'Failed' } | ForEach-Object { $_.Step }) -join ' ')
        $intuneOn = (@(Get-MdmEnrollment | Where-Object { $_.Kind -eq 'Intune' }).Count -gt 0)
        [pscustomobject][ordered]@{ Time = (Get-Date).ToString('s'); ComputerName = $t.ComputerName; Serial = $t.Serial; AdJoined = $js.DomainJoined; EntraJoined = $js.AzureAdJoined
            Tenant = $js.TenantName; IntuneEnrolled = $intuneOn; Ws1Clean = ($res.Count -eq 0); FailedSteps = $failed } |
            Export-Csv -Path (Join-Path $dir 'fleet.csv') -Append -NoTypeInformation -Encoding ASCII
        Write-ToolkitLog "Migration report saved: $file (one-line summary added to fleet.csv)" 'OK'
    }
    $file
}

# ----------------------------------------------------------------------------- device snapshot (header chips in the GUI)

function Get-DeviceSnapshot {
    $t = Get-ToolkitTarget
    $js = Get-JoinState
    $cfg = Get-ToolkitConfig
    $ws1 = @(Get-WorkspaceOneProgram).Count + @(Get-MdmEnrollment | Where-Object { $_.Kind -eq 'WorkspaceONE' }).Count
    $sc = Get-SccmClientStatus
    [pscustomobject]@{
        ComputerName = $t.ComputerName; Serial = $t.Serial; User = $t.User; MachineGuid = $t.MachineGuid
        AdJoined = $js.DomainJoined; AdName = $js.DomainName; EntraJoined = $js.AzureAdJoined; Tenant = $js.TenantName
        Intune = (@(Get-MdmEnrollment | Where-Object { $_.Kind -eq 'Intune' }).Count -gt 0)
        WorkspaceOne = ($ws1 -gt 0); Sccm = [bool]($sc.ServiceInstalled -or $sc.SetupPresent)
    }
}

# ----------------------------------------------------------------------------- automated run (phases)
# One click runs everything it can on this device, phase by phase. A phase ends where a restart or a new sign-in is
# needed; progress is saved (runplan.json) so the next click continues with the next phase. Secrets (AD credential,
# local admin password) live in memory for one run and are never written to disk. The saved plan is tied to this
# device's MachineGuid and is ignored on any other device.

$script:RunPath    = Join-Path $script:DataRoot 'runplan.json'
$script:RunPathDry = Join-Path $script:DataRoot 'runplan.dryrun.json'
$script:RunOutcome = $null

function Get-RunPhaseInfo {
    @(
        [pscustomobject]@{ Phase = 1; Title = 'Prepare and leave the old environment'; Note = 'Checks, hardware hash, remove Workspace ONE and SCCM, leave Active Directory. Ends with a restart.' }
        [pscustomobject]@{ Phase = 2; Title = 'Join Entra ID and enroll in Intune'; Note = 'After the restart, signed in with the local admin. Ends with signing in as the new user.' }
        [pscustomobject]@{ Phase = 3; Title = 'Finish'; Note = 'Signed in as the new Entra user: move the profile, tidy up, remove the temporary admin.' }
    )
}

# ---- time estimates: built-in guesses, replaced by the median of this device's own past runs once there are some.
$script:TimingPath = Join-Path $script:DataRoot 'timings.json'

function Get-StepEstimate {
    $est = @{
        LocalAdmin = 10; IntuneReady = 300; Preflight = 30; DataCheck = 90; BitLockerPrep = 20; CaptureHash = 15; UploadHash = 180; RemoveWS1 = 300; RemoveSCCM = 180
        UnjoinAD = 45; VerifyWS1Gone = 30; JoinEntra = 180; VerifyIntune = 120; ProfileWizard = 600; Debloat = 90; RemoveTempAdmin = 10; Report = 10
    }
    if (Test-Path $script:TimingPath) {
        try {
            $hist = Get-Content $script:TimingPath -Raw | ConvertFrom-Json
            foreach ($prop in $hist.PSObject.Properties) {
                $v = @($prop.Value | Where-Object { $_ -gt 0 } | Sort-Object)
                if ($v.Count -gt 0) { $est[$prop.Name] = [int]$v[[int][math]::Floor(($v.Count - 1) / 2)] }
            }
        } catch {}
    }
    $est
}

function Save-StepTiming {
    param([string]$Id, [int]$Seconds)
    if ($script:DryRun -or $Seconds -le 0) { return }
    $hist = @{}
    if (Test-Path $script:TimingPath) {
        try { foreach ($prop in (Get-Content $script:TimingPath -Raw | ConvertFrom-Json).PSObject.Properties) { $hist[$prop.Name] = @($prop.Value) } } catch {}
    }
    $list = @(); if ($hist.ContainsKey($Id)) { $list = @($hist[$Id]) }
    $hist[$Id] = @(($list + $Seconds) | Select-Object -Last 9)
    try { ConvertTo-Json -InputObject $hist -Depth 3 | Set-Content -Path $script:TimingPath -Encoding UTF8 } catch {}
}

function Format-Duration { param([double]$Seconds) $t = [timespan]::FromSeconds([math]::Max(0, $Seconds)); if ($t.TotalHours -ge 1) { '{0}:{1:00}:{2:00}' -f [int]$t.TotalHours, $t.Minutes, $t.Seconds } else { '{0}:{1:00}' -f [int]$t.TotalMinutes, $t.Seconds } }

function Resolve-RunOption {
    param($Saved, [hashtable]$New = @{})
    $o = @{
        GroupTag = ''; OutputFolder = (Join-Path $script:ToolkitRoot 'Output\Autopilot')
        CaptureHash = $true; UploadHash = $false; Offline = $false
        Debloat = $true; LaunchProfwiz = $true; RemoveTempAdmin = $false; CheckCompliance = $false
    }
    if ($Saved) { foreach ($k in @($o.Keys)) { if ($Saved.PSObject.Properties.Name -contains $k -and $null -ne $Saved.$k) { $o[$k] = $Saved.$k } } }
    foreach ($k in @($o.Keys)) { if ($New.ContainsKey($k) -and $null -ne $New[$k]) { $o[$k] = $New[$k] } }
    foreach ($k in 'AdCredential', 'AdminPassword') { if ($New.ContainsKey($k)) { $o[$k] = $New[$k] } }
    $o
}

function Get-RunStepDefinition {
    param([hashtable]$Options = @{})
    $o = Resolve-RunOption -New $Options
    $d = @(
        @{ Phase = 1; Id = 'LocalAdmin';       Title = 'Temporary local admin (only if none exists)'; Optional = $false; Enabled = $true }
        @{ Phase = 1; Id = 'Preflight';        Title = 'Pre-flight checks';                            Optional = $false; Enabled = $true }
        @{ Phase = 1; Id = 'DataCheck';        Title = 'Check for data that exists only on this disk';  Optional = $true;  Enabled = $true }
        @{ Phase = 1; Id = 'BitLockerPrep';    Title = 'Make sure a BitLocker recovery key exists';     Optional = $false; Enabled = $true }
        @{ Phase = 1; Id = 'CaptureHash';      Title = 'Capture Autopilot hardware hash';              Optional = $true;  Enabled = [bool]$o.CaptureHash }
        @{ Phase = 1; Id = 'UploadHash';       Title = 'Upload hash to Intune Autopilot';              Optional = $true;  Enabled = ([bool]$o.CaptureHash -and [bool]$o.UploadHash) }
        @{ Phase = 1; Id = 'RemoveWS1';        Title = 'Remove Workspace ONE';                         Optional = $false; Enabled = $true }
        @{ Phase = 1; Id = 'RemoveSCCM';       Title = 'Remove SCCM client';                           Optional = $false; Enabled = $true }
        @{ Phase = 1; Id = 'UnjoinAD';         Title = 'Leave Active Directory';                       Optional = $false; Enabled = $true }
        @{ Phase = 2; Id = 'VerifyWS1Gone';    Title = 'Confirm Workspace ONE is completely gone';      Optional = $false; Enabled = $true }
        @{ Phase = 2; Id = 'JoinEntra';        Title = 'Join Entra ID';                                Optional = $false; Enabled = $true }
        @{ Phase = 2; Id = 'VerifyIntune';     Title = 'Verify Intune enrollment and back up BitLocker key'; Optional = $false; Enabled = $true }
        @{ Phase = 2; Id = 'IntuneReady';      Title = 'Wait for Intune to report the device compliant'; Optional = $true;  Enabled = [bool]$o.CheckCompliance }
        @{ Phase = 3; Id = 'ProfileWizard';    Title = 'Profile migration (Profile Wizard, finish by hand)'; Optional = $true; Enabled = [bool]$o.LaunchProfwiz }
        @{ Phase = 3; Id = 'Debloat';          Title = 'Remove preinstalled apps';                     Optional = $true;  Enabled = [bool]$o.Debloat }
        @{ Phase = 3; Id = 'RemoveTempAdmin';  Title = 'Remove temporary local admin';                 Optional = $true;  Enabled = [bool]$o.RemoveTempAdmin }
        @{ Phase = 3; Id = 'Report';           Title = 'Save a migration report';                       Optional = $true;  Enabled = $true }
    )
    foreach ($s in $d) { [pscustomobject]$s }
}

function Get-RunPlanState {
    param([switch]$Dry)
    $path = $script:RunPath; if ($Dry) { $path = $script:RunPathDry }
    if (Test-Path $path) { try { return (Get-Content $path -Raw | ConvertFrom-Json) } catch {} }
    $null
}

function Clear-RunPlanState {
    foreach ($p in @($script:RunPath, $script:RunPathDry)) { if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue } }
    Write-ToolkitLog 'Saved automatic-run progress cleared.' 'OK'
}

function Save-RunPlan {
    param([Parameter(Mandatory)][hashtable]$Plan)
    $path = $script:RunPath; if ($script:DryRun) { $path = $script:RunPathDry }
    $Plan.Updated = (Get-Date).ToString('s')
    ConvertTo-Json -InputObject $Plan -Depth 6 | Set-Content -Path $path -Encoding UTF8
}

function Set-RunOutcome { param([string]$Status, [string]$Detail = '') $script:RunOutcome = @{ Status = $Status; Detail = $Detail } }

function New-RunResult {
    param([string]$Status, [int]$NextPhase, [bool]$RestartNeeded, [string]$Message)
    [pscustomobject]@{ Status = $Status; NextPhase = $NextPhase; RestartNeeded = $RestartNeeded; Message = $Message }
}

# Turns the record a legacy step wrote into state.json into this run's outcome (and throws if it failed).
function Resolve-StateOutcome {
    param([Parameter(Mandatory)][string]$Key)
    if ($script:DryRun) { Set-RunOutcome 'DryRun'; return }
    $s = @(Get-StepState) | Where-Object { $_.Step -eq $Key } | Select-Object -First 1
    if (-not $s) { throw 'The step finished without recording a result.' }
    if ($s.Status -eq 'Failed') { if ($s.Detail) { throw $s.Detail } else { throw 'The step failed; see the log above.' } }
    Set-RunOutcome $s.Status $s.Detail
}

function Test-RunPrerequisite {
    param([int]$FromPhase, [hashtable]$Options)
    if (-not (Test-IsAdmin)) { throw 'Run as administrator.' }
    if ($FromPhase -le 1 -and $Options.CaptureHash) {
        $e = Test-GroupTagName $Options.GroupTag
        if ($e) { throw "Hardware hash capture is turned on but the group tag is not usable: $e" }
    }
    if ($FromPhase -le 1 -and -not $script:DryRun) {
        if ((Get-JoinState).DomainJoined) {
            $hasCred = [bool]($Options.AdCredential -and $Options.AdCredential.UserName)
            if (-not $hasCred -and -not $Options.Offline) { throw 'This device is domain joined: supply AD credentials, or choose offline unjoin.' }
            if (@(Get-LocalAdminCandidate).Count -eq 0 -and -not $Options.AdminPassword) { throw 'No enabled local administrator exists. Supply a password for a temporary local admin before leaving the domain.' }
        }
    }
}

function Invoke-RunStep {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][hashtable]$Options)
    switch ($Id) {
        'LocalAdmin' {
            if (-not (Get-JoinState).DomainJoined) { Set-RunOutcome 'Skipped' 'Not domain joined, so there is no lock-out risk'; return }
            if (@(Get-LocalAdminCandidate).Count -gt 0) { Set-RunOutcome 'Skipped' 'An enabled local admin already exists'; return }
            $name = Get-ToolkitAdminName
            if ($script:DryRun) { Write-ToolkitLog "DRY-RUN: would create local admin '$name'" 'WARN'; Set-RunOutcome 'DryRun'; return }
            New-ToolkitLocalAdmin -Password $Options.AdminPassword
            Set-RunOutcome 'Done' $name
        }
        'Preflight' {
            $rep = @(Get-PreflightReport)
            $domain = (Get-JoinState).DomainJoined
            foreach ($c in $rep) {
                $lvl = 'INFO'; if ($c.Status -eq 'Fail') { $lvl = 'ERROR' } elseif ($c.Status -eq 'Warn') { $lvl = 'WARN' }
                Write-ToolkitLog ("{0,-5} {1}: {2}" -f $c.Status.ToUpper(), $c.Name, $c.Detail) $lvl
            }
            $blocking = @($rep | Where-Object { $_.Status -eq 'Fail' -and -not ($_.Name -eq 'Local administrator exists' -and (-not $domain -or $script:DryRun)) })
            if ($blocking.Count -gt 0) { throw ('blocking problem(s): ' + (($blocking | ForEach-Object { $_.Name }) -join ', ')) }
            Set-RunOutcome 'Done' ("{0} warning(s)" -f @($rep | Where-Object { $_.Status -eq 'Warn' }).Count)
        }
        'DataCheck' {
            $rep = @(Get-DataAtRiskReport)
            $w = @($rep | Where-Object { $_.Status -eq 'Warn' }).Count
            Set-RunOutcome 'Done' $(if ($w) { "$w item(s) need attention - see the log" } else { 'Nothing at risk' })
        }
        'BitLockerPrep' { $d = Initialize-BitLockerKey; $st = 'Done'; if ($script:DryRun) { $st = 'DryRun' }; Set-RunOutcome $st ([string]$d) }
        'VerifyWS1Gone' {
            $rows = @(Test-WorkspaceOneRemoval -Clean:(-not $script:DryRun))
            $bad = @($rows | Where-Object { $_.Status -eq 'Fail' -and $_.Name -ne 'Workspace ONE removal' })
            if ($script:DryRun) { Set-RunOutcome 'DryRun'; return }
            if ($bad.Count -gt 0) {
                $kinds = (@($bad | ForEach-Object { $_.Name }) | Sort-Object -Unique) -join ', '
                throw "Workspace ONE is not fully removed ($kinds). Restart and run again, or remove the items by hand."
            }
            $m = @($rows | Where-Object { $_.Status -eq 'Warn' }).Count
            Set-RunOutcome 'Done' $(if ($m) { "clean, $m item(s) to check by hand" } else { 'completely clean' })
        }
        'IntuneReady' {
            if ($script:DryRun) { Write-ToolkitLog 'DRY-RUN: would sign in to Graph and wait for Intune compliance' 'WARN'; Set-RunOutcome 'DryRun'; return }
            try { $ready = Wait-IntuneReady } finally { Disconnect-IntuneGraph }
            Set-RunOutcome 'Done' $ready
        }
        'Report' { $f = New-MigrationReport; $st = 'Done'; if ($script:DryRun) { $st = 'DryRun' }; Set-RunOutcome $st ([string]$f) }
        'CaptureHash' {
            $file = Invoke-AutopilotCapture -GroupTag $Options.GroupTag -OutputFolder $Options.OutputFolder
            $st = 'Done'; if ($script:DryRun) { $st = 'DryRun' }
            Set-RunOutcome $st ([string]$file)
        }
        'UploadHash' {
            $file = Get-HashCsvPath -OutputFolder $Options.OutputFolder
            if ($script:DryRun) { Write-ToolkitLog "DRY-RUN: would upload $file to Intune Autopilot" 'WARN'; Set-RunOutcome 'DryRun'; return }
            if (-not (Test-Path $file)) { throw "Hardware hash file not found: $file" }
            $res = @(Import-AutopilotToIntune -CsvPath $file)
            foreach ($x in $res) { Write-ToolkitLog "RESULT $($x.Serial): $($x.Result) $($x.Detail)" }
            $bad = @($res | Where-Object { $_.Result -notin 'complete', 'AlreadyRegistered' })
            if ($bad.Count -gt 0) { throw "Autopilot upload did not complete: $(($bad | ForEach-Object { "$($_.Serial) $($_.Result)" }) -join '; ')" }
            Disconnect-IntuneGraph
            Set-RunOutcome 'Done' (($res | ForEach-Object { $_.Result }) -join ', ')
        }
        'RemoveWS1' {
            $inv = Get-WorkspaceOneInventory
            if ($inv.Programs.Count + $inv.Appx.Count + $inv.Enrollments.Count -eq 0) { Set-RunOutcome 'Skipped' 'Nothing found'; return }
            Clear-StepState 'RemoveWS1'; Remove-WorkspaceOne; Resolve-StateOutcome 'RemoveWS1'
        }
        'RemoveSCCM' { Clear-StepState 'RemoveSCCM'; Remove-SccmClient; Resolve-StateOutcome 'RemoveSCCM' }
        'UnjoinAD' {
            Clear-StepState 'UnjoinAD'
            $a = @{ OfflineUnjoin = [bool]$Options.Offline }
            if ($Options.AdCredential) { $a.Credential = $Options.AdCredential }
            Invoke-DomainUnjoin @a
            $Options.AdCredential = $null
            Resolve-StateOutcome 'UnjoinAD'
        }
        'JoinEntra' {
            if ($script:DryRun -and (Get-JoinState).DomainJoined) { Write-ToolkitLog 'DRY-RUN: the device would already have left the domain at this point; Entra join not simulated.' 'WARN'; Set-RunOutcome 'DryRun'; return }
            Clear-StepState 'JoinEntra'; Start-EntraJoin; Resolve-StateOutcome 'JoinEntra'
        }
        'VerifyIntune' {
            if ($script:DryRun -and -not (Get-JoinState).AzureAdJoined) { Write-ToolkitLog 'DRY-RUN: the device is not Entra joined yet; Intune check not simulated.' 'WARN'; Set-RunOutcome 'DryRun'; return }
            Clear-StepState 'VerifyIntune'; Complete-IntuneVerification; Resolve-StateOutcome 'VerifyIntune'
        }
        'ProfileWizard' {
            $name = ''; try { $name = Get-ToolkitAdminName } catch {}
            if ($name -and $env:USERNAME -ieq $name) { Write-ToolkitLog "You are signed in as the temporary admin '$name'. Profile Wizard should be run while signed in as the NEW Entra user (elevated)." 'WARN' }
            Clear-StepState 'ProfileWizard'; Start-ProfileWizard; Resolve-StateOutcome 'ProfileWizard'
        }
        'Debloat' { Clear-StepState 'Cleanup'; Invoke-Debloat; Resolve-StateOutcome 'Cleanup' }
        'RemoveTempAdmin' {
            $name = Get-ToolkitAdminName
            if (-not (Get-LocalUser -Name $name -ErrorAction SilentlyContinue)) { Set-RunOutcome 'Skipped' 'No such account'; return }
            if (-not (Get-JoinState).AzureAdJoined) { Set-RunOutcome 'Skipped' 'Not Entra joined; keeping the admin so you are not locked out'; return }
            if ($env:USERNAME -ieq $name) { Set-RunOutcome 'Skipped' 'Currently signed in as this account'; return }
            Remove-ToolkitLocalAdmin
            $st = 'Done'; if ($script:DryRun) { $st = 'DryRun' }
            Set-RunOutcome $st $name
        }
        default { throw "Unknown run step '$Id'" }
    }
}

function Invoke-MigrationRun {
    param([int]$FromPhase = 0, [hashtable]$Options = @{})

    $target = Get-ToolkitTarget
    Write-ToolkitLog ("Automatic run on THIS device only: {0} (serial {1}), signed in as {2}" -f $target.ComputerName, $target.Serial, $target.User) 'STEP'

    $saved = Get-RunPlanState -Dry:$script:DryRun
    if ($saved -and $saved.Device.MachineGuid -and $target.MachineGuid -and $saved.Device.MachineGuid -ne $target.MachineGuid) {
        Write-ToolkitLog 'A saved run plan belongs to a different device and is being ignored.' 'WARN'
        $saved = $null
    }
    if ($saved -and $saved.Status -eq 'Completed') { $saved = $null }

    $savedOptions = $null; if ($saved) { $savedOptions = $saved.Options }
    $opt = Resolve-RunOption -Saved $savedOptions -New $Options
    if ($FromPhase -le 0) { $FromPhase = 1; if ($saved) { $FromPhase = [int]$saved.Phase } }
    if ($FromPhase -lt 1 -or $FromPhase -gt 3) { throw "Phase must be 1, 2 or 3." }
    Test-RunPrerequisite -FromPhase $FromPhase -Options $opt

    $defs = @(Get-RunStepDefinition -Options $opt)
    $keep = @{}
    if ($saved -and [int]$saved.Phase -eq $FromPhase) { foreach ($s in @($saved.Steps)) { $keep[$s.Id] = $s } }
    $plan = @{
        Version = 1; Created = (Get-Date).ToString('s'); Updated = ''; Phase = $FromPhase; Status = 'InProgress'; Message = ''
        Device = @{ ComputerName = $target.ComputerName; Serial = $target.Serial; MachineGuid = $target.MachineGuid }
        Options = @{ GroupTag = $opt.GroupTag; OutputFolder = $opt.OutputFolder; CaptureHash = [bool]$opt.CaptureHash; UploadHash = [bool]$opt.UploadHash
                     Offline = [bool]$opt.Offline; Debloat = [bool]$opt.Debloat; LaunchProfwiz = [bool]$opt.LaunchProfwiz; RemoveTempAdmin = [bool]$opt.RemoveTempAdmin; CheckCompliance = [bool]$opt.CheckCompliance }
        Steps = (New-Object System.Collections.ArrayList)
    }
    foreach ($d in $defs) {
        $rec = @{ Id = $d.Id; Phase = $d.Phase; Status = 'Pending'; Detail = ''; Time = ''; Seconds = 0 }
        if ($d.Phase -lt $FromPhase) { $rec.Status = 'Skipped'; $rec.Detail = 'Earlier phase' }
        elseif (-not $d.Enabled) { $rec.Status = 'Skipped'; $rec.Detail = 'Turned off' }
        elseif ($keep.ContainsKey($d.Id) -and $keep[$d.Id].Status -in 'Done', 'Skipped') { $rec.Status = [string]$keep[$d.Id].Status; $rec.Detail = [string]$keep[$d.Id].Detail }
        [void]$plan.Steps.Add($rec)
    }
    Save-RunPlan $plan
    $phaseInfo = @(Get-RunPhaseInfo)

    for ($ph = $FromPhase; $ph -le 3; $ph++) {
        $plan.Phase = $ph; $plan.Status = 'InProgress'; Save-RunPlan $plan
        Write-ToolkitLog ("PHASE {0} of 3: {1}" -f $ph, ($phaseInfo | Where-Object { $_.Phase -eq $ph }).Title) 'STEP'

        foreach ($def in @($defs | Where-Object { $_.Phase -eq $ph })) {
            $rec = @($plan.Steps | Where-Object { $_.Id -eq $def.Id })[0]
            if ($rec.Status -ne 'Pending') { continue }
            $rec.Status = 'Running'; $rec.Time = (Get-Date).ToString('s'); Save-RunPlan $plan
            $stepClock = [Diagnostics.Stopwatch]::StartNew()
            Write-ToolkitLog ("Phase {0}: {1}" -f $ph, $def.Title) 'STEP'
            try {
                $script:RunOutcome = $null
                Invoke-RunStep -Id $def.Id -Options $opt | Out-Null
                $out = $script:RunOutcome
                if (-not $out) { $out = @{ Status = 'Done'; Detail = '' } }
                $rec.Status = $out.Status; $rec.Detail = $out.Detail
                $rec.Seconds = [int]$stepClock.Elapsed.TotalSeconds
                if ($out.Status -eq 'Done') { Save-StepTiming -Id $def.Id -Seconds $rec.Seconds }
                $doneText = ("{0}: {1} {2} (took {3})" -f $def.Title, $out.Status, $out.Detail, (Format-Duration $stepClock.Elapsed.TotalSeconds)).TrimEnd()
                Write-ToolkitLog $doneText 'OK'
            } catch {
                $rec.Status = 'Failed'; $rec.Detail = $_.Exception.Message; $rec.Seconds = [int]$stepClock.Elapsed.TotalSeconds
                Write-ToolkitLog ("{0} failed: {1}" -f $def.Title, $_.Exception.Message) 'ERROR'
                if (-not $def.Optional) {
                    $plan.Status = 'Failed'; $plan.Message = "$($def.Title): $($_.Exception.Message)"; Save-RunPlan $plan
                    Write-ToolkitLog 'Run stopped. Fix the problem, then start again: finished steps are not repeated.' 'ERROR'
                    return (New-RunResult 'Failed' $ph $false $plan.Message)
                }
                Write-ToolkitLog 'This step is optional, so the run continues.' 'WARN'
            }
            Save-RunPlan $plan
        }

        if ($ph -ge 3) { break }
        $status = @{}; foreach ($r in $plan.Steps) { $status[$r.Id] = $r.Status }
        if ($ph -eq 1) { $restart = ($status.UnjoinAD -eq 'Done' -or $status.RemoveWS1 -eq 'Done' -or $status.RemoveSCCM -eq 'Done') }
        else { $restart = ($status.JoinEntra -eq 'Done') }
        $plan.Phase = $ph + 1
        if ($restart -and $script:DryRun) { Write-ToolkitLog 'DRY-RUN: a restart would be needed here; continuing the preview.' 'WARN' }
        elseif ($restart) {
            if ($ph -eq 1) { $msg = 'Phase 1 is complete. Restart the device, sign in (with the temporary local admin if the device left the domain) and continue with Phase 2.' }
            else { $msg = 'Phase 2 is complete. Restart, then sign in as the NEW Entra user and continue with Phase 3.' }
            $plan.Status = 'Paused'; $plan.Message = $msg; Save-RunPlan $plan
            Write-ToolkitLog $msg 'OK'
            return (New-RunResult 'Paused' ($ph + 1) $true $msg)
        }
    }
    $plan.Status = 'Completed'; $plan.Phase = 3; $plan.Message = 'All phases finished.'; Save-RunPlan $plan
    Write-ToolkitLog 'All phases finished on this device.' 'OK'
    New-RunResult 'Completed' 3 $false $plan.Message
}

# ----------------------------------------------------------------------------- single dispatcher for GUI + CLI

# Actions that change this device. They are refused in a remote session or when the toolkit runs from a network path.
$script:LocalChangeAction = @('RemoveWS1', 'RemoveSCCM', 'CreateLocalAdmin', 'RemoveLocalAdmin', 'UnjoinAD', 'Restart', 'JoinEntra', 'VerifyIntune',
    'IntuneSyncNow', 'BackupBitLocker', 'BitLockerPrep', 'ProfileWizard', 'Debloat', 'RunMCPR', 'RunPhase')

function Invoke-ToolkitAction {
    param([Parameter(Mandatory)][string]$Name, [hashtable]$Params = @{})
    Write-ToolkitLog "=== $Name ===" 'STEP'
    if ($script:DryRun) { Write-ToolkitLog 'DRY-RUN mode: no changes will be made.' 'WARN' }
    try {
        if ($Name -in $script:LocalChangeAction) {
            Assert-LocalScope
            $t = Get-ToolkitTarget
            if ($Params.ExpectSerial -and $t.Serial -ne $Params.ExpectSerial) { throw "Serial mismatch: this device is '$($t.Serial)' but '$($Params.ExpectSerial)' was expected. Nothing was changed." }
            Write-ToolkitLog ("Scope: this device only - {0} (serial {1}), signed in as {2}" -f $t.ComputerName, $t.Serial, $t.User)
        }
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
            'DataAtRisk'       { return (Get-DataAtRiskReport) }
            'VerifyWS1Removed' { return (Test-WorkspaceOneRemoval -Clean:(-not $script:DryRun)) }
            'BitLockerPrep'    { [void](Initialize-BitLockerKey) }
            'MigrationReport'  { [void](New-MigrationReport) }
            'RunPhase'         { $ro = $Params.Options; if (-not $ro) { $ro = @{} }; return (Invoke-MigrationRun -FromPhase ([int]$Params.Phase) -Options $ro) }
            'AddGroupTag'      { if ($script:DryRun) { Write-ToolkitLog "DRY-RUN: would save group tag '$($Params.GroupTag)'" 'WARN' } else { [void](Add-GroupTag -Name $Params.GroupTag) } }
            'RemoveGroupTag'   { if ($script:DryRun) { Write-ToolkitLog "DRY-RUN: would remove group tag '$($Params.GroupTag)'" 'WARN' } else { Remove-GroupTag -Name $Params.GroupTag } }
            'ListGroupTags'    { foreach ($t in (Get-GroupTagList)) { Write-ToolkitLog "  $t" } }
            'DiscardRunPlan'   { Clear-RunPlanState }
            'GraphSignOut'     { Disconnect-IntuneGraph }
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
    Get-ToolkitConfig, Get-StepState, Test-IsAdmin, Invoke-ToolkitAction, Get-WorkspaceOneInventory,
    Get-ToolkitTarget, Get-DeviceSnapshot, Get-WorkspaceOneResidue, Get-JoinState, Get-LocalAdminCandidate,
    Get-GroupTagList, Test-GroupTagName, Add-GroupTag, Remove-GroupTag,
    Request-ToolkitStop, Get-StepEstimate, Format-Duration, Get-RunPhaseInfo, Get-RunStepDefinition, Get-RunPlanState, Clear-RunPlanState
