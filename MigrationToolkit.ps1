# MigrationToolkit.ps1
# Workspace ONE -> Entra ID / Intune migration toolkit. GUI by default; -Action runs one step headless.
#   .\MigrationToolkit.ps1                         GUI
#   .\MigrationToolkit.ps1 -Action Preflight       read-only checks
#   .\MigrationToolkit.ps1 -Action RemoveWS1 -DryRun
[CmdletBinding()]
param(
    [ValidateSet('Gui', 'Preflight', 'CaptureHash', 'MergeCsv', 'RemoveWS1', 'RemoveSCCM', 'JoinEntra', 'VerifyIntune', 'Debloat', 'DeviceLookup')]
    [string]$Action = 'Gui',
    [string]$GroupTag = '',
    [string]$Folder = '',
    [string]$Serial = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'Modules\MigrationCore.psm1'
Import-Module $modulePath -Force
Initialize-Toolkit

if (-not (Test-IsAdmin)) {
    if ($Action -ne 'Gui') { throw 'Run this from an elevated PowerShell prompt.' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
    exit
}

if ($Action -ne 'Gui') {
    Set-ToolkitDryRun ([bool]$DryRun)
    $p = @{}
    if ($GroupTag) { $p.GroupTag = $GroupTag }
    if ($Folder)   { $p.Folder = $Folder; $p.OutputFolder = $Folder }
    if ($Serial)   { $p.Serial = $Serial }
    if ($Action -eq 'MergeCsv' -and -not $Folder) { $p.Folder = Join-Path $PSScriptRoot 'Output\Autopilot' }
    Invoke-ToolkitAction -Name $Action -Params $p | Out-Null
    exit
}

# ============================================================================ GUI

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Cfg      = Get-ToolkitConfig
$script:Queue    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:Async    = $null
$script:Shell    = $null
$script:Runspace = $null
$script:JobTag   = $null
$script:Busy     = $false

$ink     = [System.Drawing.Color]::FromArgb(31, 41, 55)
$accent  = [System.Drawing.Color]::FromArgb(37, 99, 235)
$muted   = [System.Drawing.Color]::FromArgb(107, 114, 128)
$fontUi  = New-Object System.Drawing.Font('Segoe UI', 9)
$fontBold = New-Object System.Drawing.Font('Segoe UI Semibold', 9)

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'Device Migration Toolkit'
$script:Form.Size = New-Object System.Drawing.Size(1020, 780)
$script:Form.MinimumSize = New-Object System.Drawing.Size(900, 640)
$script:Form.StartPosition = 'CenterScreen'
$script:Form.Font = $fontUi

# ---- helpers ---------------------------------------------------------------

function Show-Message {
    param([string]$Text, [string]$Title = 'Migration Toolkit', [string]$Buttons = 'OK', [string]$Icon = 'Information')
    [System.Windows.Forms.MessageBox]::Show($Text, $Title, $Buttons, $Icon)
}

function Set-UiBusy {
    param([bool]$Busy)
    $script:Busy = $Busy
    $script:Progress.Style = if ($Busy) { 'Marquee' } else { 'Continuous' }
    $script:Progress.Value = 0
    $script:Tabs.Enabled = -not $Busy
}

function Update-StepList {
    $script:StepList.Items.Clear()
    $labels = [ordered]@{
        RemoveWS1 = 'Remove Workspace ONE'; RemoveSCCM = 'Remove SCCM client'; UnjoinAD = 'Unjoin Active Directory'
        JoinEntra = 'Join Entra ID'; VerifyIntune = 'Verify Intune enrollment'; ProfileWizard = 'Profile migration'; Cleanup = 'Cleanup / debloat' }
    $state = @(Get-StepState)
    foreach ($k in $labels.Keys) {
        $s = $state | Where-Object { $_.Step -eq $k } | Select-Object -First 1
        $item = New-Object System.Windows.Forms.ListViewItem($labels[$k])
        if ($s) { [void]$item.SubItems.Add($s.Status); [void]$item.SubItems.Add($s.Time); [void]$item.SubItems.Add($s.Detail) }
        else    { [void]$item.SubItems.Add('Not run'); [void]$item.SubItems.Add(''); [void]$item.SubItems.Add('') }
        $status = $item.SubItems[1].Text
        if ($status -eq 'Done') { $item.ForeColor = [System.Drawing.Color]::FromArgb(22, 128, 61) }
        elseif ($status -eq 'Failed') { $item.ForeColor = [System.Drawing.Color]::FromArgb(185, 28, 28) }
        [void]$script:StepList.Items.Add($item)
    }
}

function Update-CheckList {
    param($Checks)
    $script:CheckList.Items.Clear()
    foreach ($c in @($Checks)) {
        if (-not ($c.PSObject.Properties.Name -contains 'Status')) { continue }
        $item = New-Object System.Windows.Forms.ListViewItem($c.Status)
        [void]$item.SubItems.Add($c.Name); [void]$item.SubItems.Add($c.Detail)
        switch ($c.Status) {
            'Pass' { $item.ForeColor = [System.Drawing.Color]::FromArgb(22, 128, 61) }
            'Warn' { $item.ForeColor = [System.Drawing.Color]::FromArgb(180, 83, 9) }
            'Fail' { $item.ForeColor = [System.Drawing.Color]::FromArgb(185, 28, 28) }
        }
        [void]$script:CheckList.Items.Add($item)
    }
}

function Add-LogLine {
    param([string]$Line)
    $color = $ink
    if ($Line -match '\[ERROR\]') { $color = [System.Drawing.Color]::FromArgb(185, 28, 28) }
    elseif ($Line -match '\[WARN\]') { $color = [System.Drawing.Color]::FromArgb(180, 83, 9) }
    elseif ($Line -match '\[OK\]') { $color = [System.Drawing.Color]::FromArgb(22, 128, 61) }
    elseif ($Line -match '\[STEP\]') { $color = $accent }
    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.SelectionLength = 0
    $script:LogBox.SelectionColor = $color
    $script:LogBox.AppendText($Line + [Environment]::NewLine)
    $script:LogBox.ScrollToCaret()
}

# Collects whatever input an action needs on the UI thread. Returns $null if the user cancels.
function Get-UiParams {
    param([hashtable]$Tag)
    $p = @{}
    switch ($Tag.Needs) {
        'Credential' {
            $ans = Show-Message "Unjoin needs a domain account that is allowed to remove this computer from AD.`n`nYes = enter AD credentials`nNo = offline unjoin (no credentials; the AD computer object stays and must be deleted manually)`nCancel = stop" 'Active Directory unjoin' 'YesNoCancel' 'Question'
            if ($ans -eq 'Cancel') { return $null }
            if ($ans -eq 'Yes') {
                $cred = Get-Credential -Message 'Domain credentials with rights to remove this computer'
                if (-not $cred) { return $null }
                $p.Credential = $cred
            } else { $p.Offline = $true }
        }
        'LocalAdminPw' {
            $cred = Get-Credential -UserName $script:Cfg.localAdminName -Message "Choose a password for the temporary local admin '$($script:Cfg.localAdminName)' (the user name is fixed)"
            if (-not $cred) { return $null }
            $p.Password = $cred.Password
        }
        'GroupTag' {
            $p.GroupTag = $script:TagBox.Text.Trim()
            $p.OutputFolder = $script:OutBox.Text.Trim()
        }
        'Folder' { $p.Folder = $script:OutBox.Text.Trim() }
        'CsvFile' {
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Filter = 'Autopilot CSV (*.csv)|*.csv'
            if (Test-Path $script:OutBox.Text) { $dlg.InitialDirectory = $script:OutBox.Text }
            if ($dlg.ShowDialog() -ne 'OK') { return $null }
            $p.CsvPath = $dlg.FileName
        }
        'Serial' { $p.Serial = $script:SerialBox.Text.Trim() }
        'Restart' { $p.Delay = 60 }
    }
    $p
}

function Start-UiAction {
    param([hashtable]$Tag)
    if ($script:Busy) { Show-Message 'Another action is still running.' | Out-Null; return }
    $dry = $script:DryBox.Checked
    if ($Tag.Name -eq 'RemoveWS1') {
        $inv = Get-WorkspaceOneInventory
        if ($inv.Programs.Count + $inv.Appx.Count + $inv.Enrollments.Count -eq 0) {
            Show-Message 'No Workspace ONE programs, Store apps or MDM enrollments were found on this device.' | Out-Null
            return
        }
        $found = New-Object System.Collections.Generic.List[string]
        foreach ($x in $inv.Programs) { $found.Add("  Program: $($x.DisplayName) $($x.Version)") }
        foreach ($x in $inv.Appx) { $found.Add("  Store app: $($x.Name)") }
        foreach ($x in $inv.Enrollments) { $found.Add("  MDM enrollment: $($x.Id) ($($x.ProviderId))") }
        $Tag = @{ Name = $Tag.Name; Confirm = "Found on this device:`n$($found -join "`n")`n`n$($Tag.Confirm)" }
    }
    if ($Tag.Confirm -and -not $dry) {
        $r = Show-Message $Tag.Confirm 'Confirm' 'YesNo' 'Warning'
        if ($r -ne 'Yes') { return }
    }
    $params = Get-UiParams -Tag $Tag
    if ($null -eq $params) { return }

    $script:JobTag = $Tag
    Set-UiBusy $true
    $script:Runspace = [runspacefactory]::CreateRunspace()
    $script:Runspace.ApartmentState = 'STA'
    $script:Runspace.ThreadOptions = 'ReuseThread'
    $script:Runspace.Open()
    $script:Shell = [powershell]::Create()
    $script:Shell.Runspace = $script:Runspace
    [void]$script:Shell.AddScript({
        param($ModulePath, $Queue, $DryRun, $Name, $Params)
        Import-Module $ModulePath -Force
        Initialize-Toolkit
        Set-ToolkitLogSink $Queue
        Set-ToolkitDryRun ([bool]$DryRun)
        Invoke-ToolkitAction -Name $Name -Params $Params
    }).AddArgument($modulePath).AddArgument($script:Queue).AddArgument($dry).AddArgument($Tag.Name).AddArgument($params)
    $script:Async = $script:Shell.BeginInvoke()
}

function Complete-UiJob {
    $tag = $script:JobTag
    $results = $null
    try { $results = $script:Shell.EndInvoke($script:Async) } catch { Add-LogLine ("{0} [ERROR] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message) }
    $script:Shell.Dispose(); $script:Runspace.Dispose()
    $script:Shell = $null; $script:Runspace = $null; $script:Async = $null
    Set-UiBusy $false
    Update-StepList
    if ($tag.Name -eq 'Preflight' -and $results) { Update-CheckList $results; $script:Tabs.SelectedTab = $script:TabStatus }
    if ($tag.Name -eq 'RemoveWS1' -and -not $script:DryBox.Checked) {
        $s = @(Get-StepState) | Where-Object { $_.Step -eq 'RemoveWS1' } | Select-Object -First 1
        if ($s -and $s.Status -eq 'Done') {
            $r = Show-Message "Workspace ONE removal was verified. A restart is recommended before the next step.`n`nRestart in 60 seconds?" 'Restart recommended' 'YesNo' 'Question'
            if ($r -eq 'Yes') { Start-UiAction @{ Name = 'Restart'; Needs = 'Restart' } }
        }
    }
    if ($tag.Name -eq 'UnjoinAD' -and -not $script:DryBox.Checked) {
        $s = @(Get-StepState) | Where-Object { $_.Step -eq 'UnjoinAD' } | Select-Object -First 1
        if ($s -and $s.Status -eq 'Done') {
            $r = Show-Message "The device left the domain. A restart is required.`n`nSign in afterwards with the local admin account, then continue with 'Join Entra ID'.`n`nRestart in 60 seconds?" 'Restart required' 'YesNo' 'Question'
            if ($r -eq 'Yes') { Start-UiAction @{ Name = 'Restart'; Needs = 'Restart' } }
        }
    }
}

$onActionClick = { param($sender, $e) Start-UiAction -Tag $sender.Tag }

function Add-Row {
    param($Flow, [string]$Title, [string]$Desc, [hashtable]$Tag)
    $row = New-Object System.Windows.Forms.Panel
    $row.Size = New-Object System.Drawing.Size(900, 48)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Title; $btn.Tag = $Tag
    $btn.Size = New-Object System.Drawing.Size(250, 36); $btn.Location = New-Object System.Drawing.Point(0, 4)
    $btn.FlatStyle = 'Flat'; $btn.BackColor = $accent; $btn.ForeColor = [System.Drawing.Color]::White; $btn.Font = $fontBold
    $btn.FlatAppearance.BorderSize = 0; $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.Add_Click($onActionClick)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Desc; $lbl.ForeColor = $muted
    $lbl.Location = New-Object System.Drawing.Point(262, 4); $lbl.Size = New-Object System.Drawing.Size(620, 40)
    $lbl.TextAlign = 'MiddleLeft'
    $row.Controls.AddRange(@($btn, $lbl))
    $Flow.Controls.Add($row)
}

function New-TabFlow {
    param([string]$Title)
    $page = New-Object System.Windows.Forms.TabPage($Title)
    $page.BackColor = [System.Drawing.Color]::White
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'; $flow.FlowDirection = 'TopDown'; $flow.WrapContents = $false; $flow.AutoScroll = $true
    $flow.Padding = New-Object System.Windows.Forms.Padding(14, 12, 14, 8)
    $page.Controls.Add($flow)
    [pscustomobject]@{ Page = $page; Flow = $flow }
}

function Add-Heading {
    param($Flow, [string]$Text)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Font = $fontBold; $l.ForeColor = $ink; $l.AutoSize = $true
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 4)
    $Flow.Controls.Add($l)
}

# ---- tabs ------------------------------------------------------------------

$script:Tabs = New-Object System.Windows.Forms.TabControl
$script:Tabs.Dock = 'Fill'

# Migration
$mig = New-TabFlow 'Migration'
Add-Heading $mig.Flow 'Run in order. Each step re-checks the machine, so it is safe to repeat.'
Add-Row $mig.Flow '1. Pre-flight checks' 'Read-only. Admin rights, network, power, TPM, BitLocker, local admin, current WS1 / AD / Entra / Intune state.' @{ Name = 'Preflight' }
Add-Row $mig.Flow '2. Remove Workspace ONE' 'Uninstalls Hub / AirWatch agents, removes the leftover MDM enrollment, scheduled tasks and registry, then verifies.' @{ Name = 'RemoveWS1'; Confirm = "Remove all of the above?`n`nTell the device's user first: apps, Wi-Fi, VPN, certificates and policies pushed by WS1 may disappear, and removal can take several minutes (do not power off).`n`nAlso retire the device in the WS1 console afterwards." }
Add-Row $mig.Flow '3. Remove SCCM client' 'Runs ccmsetup /uninstall and waits until the client is really gone.' @{ Name = 'RemoveSCCM'; Confirm = 'Uninstall the SCCM (ConfigMgr) client?' }
Add-Row $mig.Flow '4. Unjoin Active Directory' 'Refuses to run unless an enabled local admin exists. Handles hybrid join, then offers a restart. Create a local admin first if needed (Maintenance tab).' @{ Name = 'UnjoinAD'; Needs = 'Credential'; Confirm = "Remove this computer from Active Directory?`n`nDomain sign-in stops working after the restart. Make sure you know a LOCAL admin password and have the BitLocker recovery key recorded." }
Add-Row $mig.Flow '5. Join Entra ID' 'Opens Settings (or installs a .ppkg from Tools\) and waits until dsregcmd confirms the join. Sign in with the user''s work account.' @{ Name = 'JoinEntra' }
Add-Row $mig.Flow '6. Verify Intune + escrow BitLocker' 'Confirms MDM enrollment (triggers auto-enroll if missing) and backs the BitLocker recovery key up to Entra.' @{ Name = 'VerifyIntune' }
Add-Row $mig.Flow '7. Profile migration (Profwiz)' 'Launches ForensiT User Profile Wizard (GUI). Sign in as the new Entra user first; it must be run as admin.' @{ Name = 'ProfileWizard'; Confirm = 'Launch User Profile Wizard now? You still complete the wizard by hand.' }
Add-Row $mig.Flow '8. Cleanup (debloat)' 'Removes the configured Appx apps for all users and the provisioned copies (list in Config\toolkit.json).' @{ Name = 'Debloat'; Confirm = 'Remove the configured preinstalled apps?' }

# Autopilot / Intune
$ap = New-TabFlow 'Autopilot / Intune'
Add-Heading $ap.Flow 'Capture hardware hash (run on each device)'
$inputRow = New-Object System.Windows.Forms.Panel
$inputRow.Size = New-Object System.Drawing.Size(900, 34)
$l1 = New-Object System.Windows.Forms.Label; $l1.Text = 'Group tag'; $l1.Location = New-Object System.Drawing.Point(0, 8); $l1.AutoSize = $true
$script:TagBox = New-Object System.Windows.Forms.ComboBox; $script:TagBox.Location = New-Object System.Drawing.Point(62, 4); $script:TagBox.Width = 250
foreach ($t in $script:Cfg.groupTags) { [void]$script:TagBox.Items.Add($t) }
if ($script:TagBox.Items.Count -gt 0) { $script:TagBox.SelectedIndex = 0 }
$l2 = New-Object System.Windows.Forms.Label; $l2.Text = 'CSV folder'; $l2.Location = New-Object System.Drawing.Point(330, 8); $l2.AutoSize = $true
$script:OutBox = New-Object System.Windows.Forms.TextBox; $script:OutBox.Location = New-Object System.Drawing.Point(398, 4); $script:OutBox.Width = 380
$script:OutBox.Text = Join-Path $PSScriptRoot 'Output\Autopilot'
$browse = New-Object System.Windows.Forms.Button; $browse.Text = '...'; $browse.Location = New-Object System.Drawing.Point(784, 3); $browse.Width = 36
$browse.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    if (Test-Path $script:OutBox.Text) { $d.SelectedPath = $script:OutBox.Text }
    if ($d.ShowDialog() -eq 'OK') { $script:OutBox.Text = $d.SelectedPath }
})
$inputRow.Controls.AddRange(@($l1, $script:TagBox, $l2, $script:OutBox, $browse))
$ap.Flow.Controls.Add($inputRow)
Add-Row $ap.Flow 'Capture this device''s hash' 'Reads the hash from WMI (no internet or gallery module needed) and writes <serial>_AutoPilotSetup.csv with the group tag.' @{ Name = 'CaptureHash'; Needs = 'GroupTag' }
Add-Row $ap.Flow 'Merge CSVs in folder' 'Validates, de-duplicates by serial and writes one Consolidated<timestamp>.csv. Ignores earlier Consolidated* files.' @{ Name = 'MergeCsv'; Needs = 'Folder' }
Add-Heading $ap.Flow 'Intune (Microsoft Graph)'
Add-Row $ap.Flow 'Sign in to Intune' 'Interactive sign-in. Needs an Intune Administrator account and the Graph module (Maintenance tab).' @{ Name = 'GraphSignIn' }
Add-Row $ap.Flow 'Upload CSV to Autopilot' 'Imports every device in a CSV, skips ones already registered, and waits for Intune to report each result.' @{ Name = 'UploadAutopilot'; Needs = 'CsvFile'; Confirm = 'Upload the selected CSV to your Intune tenant?' }
Add-Row $ap.Flow 'Sync Autopilot service' 'Asks Intune to refresh its Autopilot device list now.' @{ Name = 'AutopilotSync' }
$lookupRow = New-Object System.Windows.Forms.Panel; $lookupRow.Size = New-Object System.Drawing.Size(900, 30)
$l3 = New-Object System.Windows.Forms.Label; $l3.Text = 'Serial (blank = this device)'; $l3.Location = New-Object System.Drawing.Point(0, 7); $l3.AutoSize = $true
$script:SerialBox = New-Object System.Windows.Forms.TextBox; $script:SerialBox.Location = New-Object System.Drawing.Point(170, 3); $script:SerialBox.Width = 200
$lookupRow.Controls.AddRange(@($l3, $script:SerialBox))
$ap.Flow.Controls.Add($lookupRow)
Add-Row $ap.Flow 'Look up device in Intune' 'Shows Autopilot registration (group tag, profile status) and the Intune managed device (compliance, last sync).' @{ Name = 'DeviceLookup'; Needs = 'Serial' }

# Maintenance
$mt = New-TabFlow 'Maintenance'
Add-Heading $mt.Flow 'Local admin safety net'
Add-Row $mt.Flow 'Create temporary local admin' 'Creates / re-enables the account named in Config\toolkit.json so you are not locked out after the domain unjoin.' @{ Name = 'CreateLocalAdmin'; Needs = 'LocalAdminPw'; Confirm = 'Create (or reset) the temporary local administrator account?' }
Add-Row $mt.Flow 'Remove temporary local admin' 'Deletes that account once migration is finished.' @{ Name = 'RemoveLocalAdmin'; Confirm = 'Delete the temporary local admin account?' }
Add-Heading $mt.Flow 'Intune / Entra helpers'
Add-Row $mt.Flow 'Force Intune enrollment' 'Runs deviceenroller /AutoEnrollMDM if the device is Entra joined but not yet enrolled.' @{ Name = 'IntuneSyncNow' }
Add-Row $mt.Flow 'Back up BitLocker key to Entra' 'Escrows the OS-drive recovery password to Entra ID.' @{ Name = 'BackupBitLocker' }
Add-Row $mt.Flow 'Install Graph module' 'Installs Microsoft.Graph.Authentication for the current user from PSGallery (needed for Intune upload).' @{ Name = 'InstallGraph'; Confirm = 'Download and install Microsoft.Graph.Authentication from the PowerShell Gallery?' }
Add-Heading $mt.Flow 'Tools and power'
Add-Row $mt.Flow 'Run McAfee removal (MCPR)' 'Runs Tools\MCPR.exe after checking its digital signature; refuses an unsigned file.' @{ Name = 'RunMCPR'; Confirm = 'Run the McAfee Consumer Product Removal tool?' }
Add-Row $mt.Flow 'Restart in 60 seconds' 'Schedules a restart you can cancel below.' @{ Name = 'Restart'; Needs = 'Restart'; Confirm = 'Restart this device in 60 seconds?' }
Add-Row $mt.Flow 'Cancel pending restart' 'Runs shutdown /a.' @{ Name = 'CancelRestart' }

# Status
$script:TabStatus = New-Object System.Windows.Forms.TabPage('Status')
$script:TabStatus.BackColor = [System.Drawing.Color]::White
$script:StepList = New-Object System.Windows.Forms.ListView
$script:StepList.View = 'Details'; $script:StepList.FullRowSelect = $true; $script:StepList.GridLines = $true
$script:StepList.Dock = 'Top'; $script:StepList.Height = 190
foreach ($c in @(@('Step', 220), @('Status', 90), @('When', 150), @('Detail', 400))) { [void]$script:StepList.Columns.Add($c[0], $c[1]) }
$script:CheckList = New-Object System.Windows.Forms.ListView
$script:CheckList.View = 'Details'; $script:CheckList.FullRowSelect = $true; $script:CheckList.GridLines = $true; $script:CheckList.Dock = 'Fill'
foreach ($c in @(@('Result', 70), @('Check', 230), @('Detail', 620))) { [void]$script:CheckList.Columns.Add($c[0], $c[1]) }
$script:TabStatus.Controls.Add($script:CheckList)
$script:TabStatus.Controls.Add($script:StepList)

$script:Tabs.TabPages.AddRange(@($mig.Page, $ap.Page, $mt.Page, $script:TabStatus))

# ---- log pane + header -----------------------------------------------------

$logPanel = New-Object System.Windows.Forms.Panel
$logPanel.Dock = 'Bottom'; $logPanel.Height = 230
$script:Progress = New-Object System.Windows.Forms.ProgressBar
$script:Progress.Dock = 'Top'; $script:Progress.Height = 6; $script:Progress.MarqueeAnimationSpeed = 30
$script:LogBox = New-Object System.Windows.Forms.RichTextBox
$script:LogBox.Dock = 'Fill'; $script:LogBox.ReadOnly = $true; $script:LogBox.BackColor = [System.Drawing.Color]::FromArgb(249, 250, 251)
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 9); $script:LogBox.BorderStyle = 'None'
$logPanel.Controls.Add($script:LogBox)
$logPanel.Controls.Add($script:Progress)

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 52; $header.BackColor = $ink
$title = New-Object System.Windows.Forms.Label
$title.Text = 'Device Migration Toolkit'; $title.ForeColor = [System.Drawing.Color]::White
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14); $title.Location = New-Object System.Drawing.Point(14, 12); $title.AutoSize = $true
$script:DryBox = New-Object System.Windows.Forms.CheckBox
$script:DryBox.Text = 'Dry run (log only, change nothing)'; $script:DryBox.ForeColor = [System.Drawing.Color]::White
$script:DryBox.AutoSize = $true; $script:DryBox.Anchor = 'Top,Right'; $script:DryBox.Location = New-Object System.Drawing.Point(740, 16)
$openLogs = New-Object System.Windows.Forms.LinkLabel
$openLogs.Text = 'Open log folder'; $openLogs.LinkColor = [System.Drawing.Color]::FromArgb(147, 197, 253); $openLogs.AutoSize = $true
$openLogs.Location = New-Object System.Drawing.Point(330, 20)
$openLogs.Add_Click({ Start-Process explorer.exe (Get-ToolkitLogDir) })
$header.Controls.AddRange(@($title, $openLogs, $script:DryBox))

# Fill control first, then the docked edges (WinForms docks later-added controls first).
$script:Form.Controls.Add($script:Tabs)
$script:Form.Controls.Add($logPanel)
$script:Form.Controls.Add($header)

# ---- timer / lifecycle -----------------------------------------------------

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    $line = $null
    while ($script:Queue.TryDequeue([ref]$line)) { Add-LogLine $line }
    if ($script:Async -and $script:Async.IsCompleted) {
        $line = $null
        while ($script:Queue.TryDequeue([ref]$line)) { Add-LogLine $line }
        Complete-UiJob
    }
})
$timer.Start()

$script:Form.Add_FormClosing({
    param($sender, $e)
    if ($script:Busy) {
        $r = Show-Message 'An action is still running. Closing now can leave the device half-migrated. Close anyway?' 'Action running' 'YesNo' 'Warning'
        if ($r -ne 'Yes') { $e.Cancel = $true }
    }
})

$script:Form.Add_Shown({
    Update-StepList
    Add-LogLine ("{0} [INFO] Ready. Logs: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), (Get-ToolkitLogDir))
})

try { [void]$script:Form.ShowDialog() }
catch { Show-Message "Fatal error: $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'Migration Toolkit' 'OK' 'Error' | Out-Null }
finally { $timer.Stop(); $timer.Dispose() }
