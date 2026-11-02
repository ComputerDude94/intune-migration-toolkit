# MigrationToolkit.ps1
# Workspace ONE -> Entra ID / Intune migration toolkit. GUI by default; -Action runs one step headless.
#   .\MigrationToolkit.ps1                                   GUI
#   .\MigrationToolkit.ps1 -Action Preflight                 read-only checks
#   .\MigrationToolkit.ps1 -Action RunPhase -DryRun          preview the automatic run (all phases, nothing changes)
#   .\MigrationToolkit.ps1 -Action RunPhase -GroupTag 'AutoPilot-Shared-FacStaff'   run the next phase on THIS device
# Every action changes only the device it runs on. Remote sessions and network locations are refused.
[CmdletBinding()]
param(
    [ValidateSet('Gui', 'Preflight', 'CaptureHash', 'MergeCsv', 'RemoveWS1', 'RemoveSCCM', 'JoinEntra', 'VerifyIntune', 'Debloat', 'DeviceLookup',
                 'RunPhase', 'AddGroupTag', 'RemoveGroupTag', 'ListGroupTags', 'DiscardRunPlan', 'DataAtRisk', 'VerifyWS1Removed', 'BitLockerPrep', 'MigrationReport')]
    [string]$Action = 'Gui',
    [string]$GroupTag = '',
    [string]$Folder = '',
    [string]$Serial = '',
    [ValidateRange(0, 3)][int]$Phase = 0,
    [string]$ExpectSerial = '',
    [switch]$Offline,
    [switch]$SkipHash,
    [switch]$UploadHash,
    [switch]$SkipDebloat,
    [switch]$SkipProfwiz,
    [switch]$RemoveTempAdmin,
    [switch]$Yes,
    [switch]$Restart,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'Modules\MigrationCore.psm1'
Import-Module $modulePath -Force
Initialize-Toolkit

$noAdminNeeded = @('ListGroupTags', 'AddGroupTag', 'RemoveGroupTag', 'MergeCsv')
if (-not (Test-IsAdmin) -and $Action -notin $noAdminNeeded) {
    if ($Action -ne 'Gui') { throw 'Run this from an elevated PowerShell prompt.' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
    exit
}

if ($Action -ne 'Gui') {
    Set-ToolkitDryRun ([bool]$DryRun)
    $p = @{}
    if ($GroupTag)     { $p.GroupTag = $GroupTag }
    if ($Folder)       { $p.Folder = $Folder; $p.OutputFolder = $Folder }
    if ($Serial)       { $p.Serial = $Serial }
    if ($ExpectSerial) { $p.ExpectSerial = $ExpectSerial }
    if ($Action -eq 'MergeCsv' -and -not $Folder) { $p.Folder = Join-Path $PSScriptRoot 'Output\Autopilot' }

    # Anything destructive needs a deliberate confirmation naming this device (skip with -Yes, or use -DryRun).
    if ($Action -in 'RunPhase', 'RemoveWS1', 'RemoveSCCM', 'Debloat' -and -not $DryRun -and -not $Yes) {
        $t = Get-ToolkitTarget
        $typed = Read-Host "This changes THIS device only: $($t.ComputerName) (serial $($t.Serial)). Type the computer name to continue"
        if ($typed -ne $t.ComputerName) { Write-Host 'Name did not match. Nothing was changed.'; exit 1 }
    }

    if ($Action -eq 'RunPhase') {
        $o = @{}
        if ($GroupTag) { $o.GroupTag = $GroupTag }
        if ($Folder)   { $o.OutputFolder = $Folder }
        if ($PSBoundParameters.ContainsKey('SkipHash'))        { $o.CaptureHash = -not $SkipHash }
        if ($PSBoundParameters.ContainsKey('UploadHash'))      { $o.UploadHash = [bool]$UploadHash }
        if ($PSBoundParameters.ContainsKey('SkipDebloat'))     { $o.Debloat = -not $SkipDebloat }
        if ($PSBoundParameters.ContainsKey('SkipProfwiz'))     { $o.LaunchProfwiz = -not $SkipProfwiz }
        if ($PSBoundParameters.ContainsKey('RemoveTempAdmin')) { $o.RemoveTempAdmin = [bool]$RemoveTempAdmin }
        if ($Offline) { $o.Offline = $true }

        $target = Get-ToolkitTarget
        $plan = Get-RunPlanState -Dry:$DryRun
        $effective = $Phase
        if ($effective -le 0) {
            $effective = 1
            if ($plan -and $plan.Status -ne 'Completed' -and $plan.Device.MachineGuid -eq $target.MachineGuid) { $effective = [int]$plan.Phase }
        }
        if ($effective -le 1 -and -not $DryRun -and (Get-JoinState).DomainJoined) {
            if (-not $Offline) {
                $o.AdCredential = Get-Credential -Message "Domain account allowed to remove THIS computer ($($target.ComputerName)) from Active Directory"
                if (-not $o.AdCredential) { throw 'Cancelled.' }
            }
            if (@(Get-LocalAdminCandidate).Count -eq 0) {
                $cfg = Get-ToolkitConfig
                $c = Get-Credential -UserName $cfg.localAdminName -Message "Choose a password for the temporary local admin '$($cfg.localAdminName)' (the name is fixed)"
                if (-not $c) { throw 'Cancelled.' }
                $o.AdminPassword = $c.Password
            }
        }
        $p = @{ Phase = $Phase; Options = $o }
        if ($ExpectSerial) { $p.ExpectSerial = $ExpectSerial }
        $res = @(Invoke-ToolkitAction -Name RunPhase -Params $p) | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'RestartNeeded' } | Select-Object -Last 1
        if ($res -and $res.RestartNeeded) {
            if ($Restart -and -not $DryRun) { Invoke-ToolkitAction -Name Restart -Params @{ Delay = 60 } | Out-Null }
            else { Write-Host "Restart this device, then run the same command again to continue with Phase $($res.NextPhase)." }
        }
        exit
    }

    Invoke-ToolkitAction -Name $Action -Params $p | Out-Null
    exit
}

# ============================================================================ GUI

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Small custom controls (rounded cards, buttons, chips). If they cannot be compiled the GUI falls back to standard controls.
$uiSource = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ToolkitUi
{
    public static class Native
    {
        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();
        public static void EnableDpiAwareness() { try { SetProcessDPIAware(); } catch (Exception) { } }
    }

    public static class Shapes
    {
        public static GraphicsPath Round(Rectangle r, int radius)
        {
            int d = radius * 2;
            GraphicsPath p = new GraphicsPath();
            if (d <= 0 || r.Width < d || r.Height < d) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
    }

    public class Card : Panel
    {
        public int Radius = 12;
        public Color Edge = Color.FromArgb(226, 232, 240);

        public Card()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Color outer = (Parent != null) ? Parent.BackColor : SystemColors.Control;
            g.Clear(outer);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (GraphicsPath path = Shapes.Round(r, Radius))
            using (SolidBrush fill = new SolidBrush(BackColor))
            using (Pen pen = new Pen(Edge))
            {
                g.FillPath(fill, path);
                g.DrawPath(pen, path);
            }
        }
    }

    public class FlatButton : Button
    {
        public Color Fill = Color.FromArgb(79, 70, 229);
        public Color FillHover = Color.FromArgb(67, 56, 202);
        public Color FillDown = Color.FromArgb(55, 48, 163);
        public Color Ink = Color.White;
        public Color Edge = Color.Transparent;
        public int Radius = 8;
        private bool hover;
        private bool down;

        public FlatButton()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Cursor = Cursors.Hand;
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Color outer = (Parent != null) ? Parent.BackColor : SystemColors.Control;
            g.Clear(outer);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Color f = Fill;
            Color ink = Ink;
            if (!Enabled) { f = Color.FromArgb(226, 232, 240); ink = Color.FromArgb(148, 163, 184); }
            else if (down) { f = FillDown; }
            else if (hover) { f = FillHover; }
            Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (GraphicsPath path = Shapes.Round(r, Radius))
            using (SolidBrush b = new SolidBrush(f))
            {
                g.FillPath(b, path);
                if (Enabled && Edge.A > 0)
                {
                    using (Pen p = new Pen(Edge)) { g.DrawPath(p, path); }
                }
            }
            TextFormatFlags flags = TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix;
            TextRenderer.DrawText(g, Text, Font, new Rectangle(0, 0, Width, Height), ink, flags);
        }
    }

    public class Chip : Control
    {
        public Color Fill = Color.FromArgb(241, 245, 249);
        public Color Ink = Color.FromArgb(71, 85, 105);

        public Chip()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Size = new Size(80, 26);
            Margin = new Padding(0, 0, 8, 6);
        }

        public void Fit()
        {
            Size s = TextRenderer.MeasureText(Text, Font);
            Width = s.Width + 24;
            Height = 26;
        }

        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Fit(); Invalidate(); }
        protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); Fit(); Invalidate(); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Color outer = (Parent != null) ? Parent.BackColor : SystemColors.Control;
            g.Clear(outer);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (GraphicsPath path = Shapes.Round(r, Height / 2))
            using (SolidBrush b = new SolidBrush(Fill))
            {
                g.FillPath(b, path);
            }
            TextRenderer.DrawText(g, Text, Font, new Rectangle(0, 0, Width, Height), Ink, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
        }
    }
}
'@

$script:UiKit = $false
try {
    if (-not ('ToolkitUi.Card' -as [type])) {
        Add-Type -TypeDefinition $uiSource -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -ErrorAction Stop
    }
    [ToolkitUi.Native]::EnableDpiAwareness()
    $script:UiKit = $true
} catch { Write-Host "Custom styling unavailable, using standard controls: $($_.Exception.Message)" }
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch {}
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Cfg      = Get-ToolkitConfig
$script:Queue    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:Async    = $null
$script:Shell    = $null
$script:Runspace = $null
$script:JobTag   = $null
$script:Busy     = $false
$script:Snap     = $null
$script:Tick     = 0
$script:JobStart = $null
$script:Est      = Get-StepEstimate
$script:EstKey   = @{ DataAtRisk = 'DataCheck'; VerifyWS1Removed = 'VerifyWS1Gone'; UploadAutopilot = 'UploadHash' }
$script:SyncingTag = $false
$script:ActionButtons = New-Object System.Collections.Generic.List[object]
$script:TagBoxes = New-Object System.Collections.Generic.List[object]
$script:StepRows = @{}
$script:Pages = [ordered]@{}
$script:NavButtons = [ordered]@{}

function Rgb { param([int]$R, [int]$G, [int]$B) [System.Drawing.Color]::FromArgb($R, $G, $B) }

$Pal = @{
    Bg = (Rgb 241 245 249); Card = (Rgb 255 255 255); Edge = (Rgb 226 232 240); Strong = (Rgb 203 213 225)
    Ink = (Rgb 15 23 42); Muted = (Rgb 100 116 139)
    Accent = (Rgb 79 70 229); AccentHover = (Rgb 67 56 202); AccentDown = (Rgb 55 48 163)
    Nav = (Rgb 15 23 42); NavHover = (Rgb 30 41 59); NavActive = (Rgb 67 56 202); NavText = (Rgb 203 213 225); NavMuted = (Rgb 148 163 184)
    Ok = (Rgb 22 163 74); Warn = (Rgb 217 119 6); Bad = (Rgb 220 38 38)
    LogBg = (Rgb 15 23 42); LogInk = (Rgb 226 232 240)
}
$Fnt = @{
    Body  = New-Object System.Drawing.Font('Segoe UI', 9.5)
    Semi  = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    Big   = New-Object System.Drawing.Font('Segoe UI Semibold', 11.5)
    Title = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
    Small = New-Object System.Drawing.Font('Segoe UI', 9)
    Mono  = New-Object System.Drawing.Font('Consolas', 9.5)
}

# ---- control factories ---------------------------------------------------------

function New-Label {
    param([string]$Text, $Font, $Color, $Back)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Font = $Font; $l.ForeColor = $Color; $l.BackColor = $Back; $l.AutoSize = $false
    $l
}

function New-Card {
    if ($script:UiKit) { $c1 = New-Object ToolkitUi.Card } else { $c1 = New-Object System.Windows.Forms.Panel }
    $c1.BackColor = $Pal.Card
    $c1
}

function New-Btn {
    param([string]$Text, [string]$Style = 'Primary', [int]$W = 120, [int]$H = 36)
    if ($script:UiKit) { $b = New-Object ToolkitUi.FlatButton }
    else { $b = New-Object System.Windows.Forms.Button; $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0; $b.Cursor = [System.Windows.Forms.Cursors]::Hand }
    $b.Text = $Text; $b.Size = New-Object System.Drawing.Size($W, $H); $b.Font = $Fnt.Semi
    switch ($Style) {
        'Secondary' { $fill = $Pal.Card; $hov = (Rgb 248 250 252); $dn = (Rgb 226 232 240); $ink = (Rgb 51 65 85); $edge = $Pal.Strong }
        'Danger'    { $fill = $Pal.Bad; $hov = (Rgb 185 28 28); $dn = (Rgb 153 27 27); $ink = [System.Drawing.Color]::White; $edge = [System.Drawing.Color]::Transparent }
        default     { $fill = $Pal.Accent; $hov = $Pal.AccentHover; $dn = $Pal.AccentDown; $ink = [System.Drawing.Color]::White; $edge = [System.Drawing.Color]::Transparent }
    }
    if ($script:UiKit) { $b.Fill = $fill; $b.FillHover = $hov; $b.FillDown = $dn; $b.Ink = $ink; $b.Edge = $edge }
    else {
        $b.BackColor = $fill; $b.ForeColor = $ink
        if ($Style -eq 'Secondary') { $b.FlatAppearance.BorderSize = 1; $b.FlatAppearance.BorderColor = $Pal.Strong }
    }
    $b
}

function New-Chip {
    if ($script:UiKit) { $c2 = New-Object ToolkitUi.Chip }
    else { $c2 = New-Object System.Windows.Forms.Label; $c2.AutoSize = $true; $c2.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4); $c2.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 6) }
    $c2.Font = $Fnt.Small
    $c2
}

function Set-Chip {
    param($Chip, [string]$Text, [string]$Tone = 'neutral')
    switch ($Tone) {
        'ok'   { $f = (Rgb 220 252 231); $i = (Rgb 21 128 61) }
        'warn' { $f = (Rgb 254 243 199); $i = (Rgb 180 83 9) }
        'bad'  { $f = (Rgb 254 226 226); $i = (Rgb 185 28 28) }
        default { $f = (Rgb 241 245 249); $i = (Rgb 71 85 105) }
    }
    $Chip.Text = $Text
    if ($script:UiKit) { $Chip.Fill = $f; $Chip.Ink = $i; $Chip.Invalidate() } else { $Chip.BackColor = $f; $Chip.ForeColor = $i }
}

function Show-Message {
    param([string]$Text, [string]$Title = 'Migration Toolkit', [string]$Buttons = 'OK', [string]$Icon = 'Information')
    [System.Windows.Forms.MessageBox]::Show($script:Form, $Text, $Title, $Buttons, $Icon)
}

function Show-InputDialog {
    param([string]$Title, [string]$Prompt, [string]$OkText = 'OK', [string]$Initial = '')
    $lines = 0
    foreach ($ln in ($Prompt -split "`n")) { $lines += [math]::Max(1, [math]::Ceiling($ln.Length / 60)) }
    $textH = [math]::Max(60, 21 * $lines + 6)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.StartPosition = 'CenterParent'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96); $dlg.AutoScaleMode = 'Dpi'
    $dlg.ClientSize = New-Object System.Drawing.Size(480, (20 + $textH + 10 + 28 + 14 + 36 + 20)); $dlg.BackColor = $Pal.Card; $dlg.Font = $Fnt.Body
    $lbl = New-Label $Prompt $Fnt.Body $Pal.Ink $Pal.Card
    $lbl.Location = New-Object System.Drawing.Point(22, 20); $lbl.Size = New-Object System.Drawing.Size(436, $textH)
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(22, (20 + $textH + 10)); $txt.Width = 436; $txt.Text = $Initial
    $by = 20 + $textH + 10 + 28 + 14
    $ok = New-Btn $OkText 'Primary' 130 36;       $ok.Location = New-Object System.Drawing.Point(222, $by); $ok.DialogResult = 'OK'
    $cancel = New-Btn 'Cancel' 'Secondary' 96 36; $cancel.Location = New-Object System.Drawing.Point(362, $by); $cancel.DialogResult = 'Cancel'
    $dlg.Controls.AddRange(@($lbl, $txt, $ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel; $dlg.ActiveControl = $txt
    $answer = $null
    if ($dlg.ShowDialog($script:Form) -eq [System.Windows.Forms.DialogResult]::OK) { $answer = $txt.Text }
    $dlg.Dispose()
    $answer
}

# ---- main window ---------------------------------------------------------------

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'Device Migration Toolkit'
$script:Form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$script:Form.AutoScaleMode = 'Dpi'
$script:Form.ClientSize = New-Object System.Drawing.Size(1240, 820)
$script:Form.MinimumSize = New-Object System.Drawing.Size(1060, 700)
$script:Form.StartPosition = 'CenterScreen'
$script:Form.Font = $Fnt.Body
$script:Form.BackColor = $Pal.Bg

function Add-ToTable {
    param($Table, $Control)
    [void]$Table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $Table.RowCount = $Table.RowStyles.Count
    $Table.Controls.Add($Control, 0, $Table.RowStyles.Count - 1)
}

function New-Page {
    param([string]$Key)
    $page = New-Object System.Windows.Forms.Panel
    $page.Dock = 'Fill'; $page.BackColor = $Pal.Bg; $page.Visible = $false
    $tbl = New-Object System.Windows.Forms.TableLayoutPanel
    $tbl.Dock = 'Fill'; $tbl.AutoScroll = $true; $tbl.ColumnCount = 1; $tbl.RowCount = 0; $tbl.BackColor = $Pal.Bg
    $tbl.Padding = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $page.Controls.Add($tbl)
    $script:Pages[$Key] = $page
    [pscustomobject]@{ Page = $page; Table = $tbl }
}

function Add-Heading {
    param($Table, [string]$Text, [string]$Sub = '')
    $h = New-Object System.Windows.Forms.Panel
    $h.Dock = 'Fill'; $h.BackColor = $Pal.Bg; $h.Height = 28; if ($Sub) { $h.Height = 52 }
    $h.Margin = New-Object System.Windows.Forms.Padding(2, 4, 0, 6)
    $sl = New-Label $Sub $Fnt.Small $Pal.Muted $Pal.Bg; $sl.Dock = 'Fill'
    $tl = New-Label $Text $Fnt.Big $Pal.Ink $Pal.Bg; $tl.Dock = 'Top'; $tl.Height = 26
    if ($Sub) { $h.Controls.Add($sl) }
    $h.Controls.Add($tl)
    Add-ToTable $Table $h
}

$onActionClick = { param($sender, $e) Start-UiAction -Tag $sender.Tag }

function Add-ActionRow {
    param($Table, [string]$Title, [string]$Desc, [hashtable]$Tag, [string]$Verb = 'Run')
    $card = New-Card
    $card.Dock = 'Fill'; $card.Height = 78; $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $card.Padding = New-Object System.Windows.Forms.Padding(18, 10, 12, 10)
    $d = New-Label $Desc $Fnt.Small $Pal.Muted $Pal.Card; $d.Dock = 'Fill'
    $t = New-Label $Title $Fnt.Semi $Pal.Ink $Pal.Card; $t.Dock = 'Top'; $t.Height = 24
    $holder = New-Object System.Windows.Forms.Panel
    $holder.Dock = 'Right'; $holder.Width = 128; $holder.BackColor = $Pal.Card
    $btn = New-Btn $Verb 'Primary' 112 36
    $btn.Location = New-Object System.Drawing.Point(8, 11); $btn.Tag = $Tag; $btn.Add_Click($onActionClick)
    $holder.Controls.Add($btn)
    $card.Controls.Add($d); $card.Controls.Add($t); $card.Controls.Add($holder)
    $script:ActionButtons.Add($btn)
    Add-ToTable $Table $card
}

# ---- group tag controls (shared list, several combo boxes kept in sync) -----------

function New-TagCombo {
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.DropDownStyle = 'DropDown'; $cb.Font = $Fnt.Body
    foreach ($t in (Get-GroupTagList)) { [void]$cb.Items.Add($t) }
    if ($cb.Items.Count -gt 0) { $cb.SelectedIndex = 0 }
    $cb.Add_TextChanged({
        param($sender, $e)
        if ($script:SyncingTag) { return }
        $script:SyncingTag = $true
        foreach ($o in $script:TagBoxes) { if ($o -ne $sender -and $o.Text -ne $sender.Text) { $o.Text = $sender.Text } }
        $script:SyncingTag = $false
    })
    $script:TagBoxes.Add($cb)
    $cb
}

function Sync-TagBox {
    param([string]$Select = '')
    $script:SyncingTag = $true
    $current = $Select
    if (-not $current -and $script:TagBoxes.Count -gt 0) { $current = $script:TagBoxes[0].Text }
    foreach ($cb in $script:TagBoxes) {
        $cb.Items.Clear()
        foreach ($t in (Get-GroupTagList)) { [void]$cb.Items.Add($t) }
        $cb.Text = $current
    }
    $script:SyncingTag = $false
}

function Add-TagFromUi {
    $init = ''
    $name = $null
    while ($true) {
        $name = Show-InputDialog -Title 'New group tag' -Prompt "Name for the new Autopilot group tag.`n`nLetters, numbers, spaces, hyphens, underscores and dots only. It is saved on this toolkit and offered in every list, and it is written into each hardware-hash CSV you capture with it." -OkText 'Add tag' -Initial $init
        if ($null -eq $name) { return $null }
        $err = Test-GroupTagName $name
        if (-not $err) { break }
        Show-Message $err 'Group tag' 'OK' 'Warning' | Out-Null
        $init = $name
    }
    try { $saved = Add-GroupTag -Name $name } catch { Show-Message $_.Exception.Message 'Group tag' 'OK' 'Error' | Out-Null; return $null }
    Sync-TagBox $saved
    Add-LogLine ("{0} [OK] Group tag '{1}' is available." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $saved)
    $saved
}

function Remove-TagFromUi {
    $name = $script:TagBoxes[0].Text.Trim()
    if (-not $name) { return }
    if ((Show-Message "Remove '$name' from your saved group tags?`n`nCSV files already captured keep their tag." 'Remove group tag' 'YesNo' 'Question') -ne 'Yes') { return }
    try { Remove-GroupTag -Name $name; Sync-TagBox } catch { Show-Message $_.Exception.Message 'Group tag' 'OK' 'Warning' | Out-Null }
}

# ---- sidebar -------------------------------------------------------------------

$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Dock = 'Left'; $sidebar.Width = 232; $sidebar.BackColor = $Pal.Nav

$navFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$navFlow.Dock = 'Fill'; $navFlow.FlowDirection = 'TopDown'; $navFlow.WrapContents = $false; $navFlow.BackColor = $Pal.Nav

$brand = New-Object System.Windows.Forms.Panel
$brand.Size = New-Object System.Drawing.Size(232, 92); $brand.BackColor = $Pal.Nav; $brand.Margin = New-Object System.Windows.Forms.Padding(0)
$b1 = New-Label 'Device Migration' $Fnt.Title ([System.Drawing.Color]::White) $Pal.Nav; $b1.Location = New-Object System.Drawing.Point(20, 20); $b1.Size = New-Object System.Drawing.Size(210, 30)
$b2 = New-Label 'Workspace ONE to Intune' $Fnt.Small $Pal.NavMuted $Pal.Nav; $b2.Location = New-Object System.Drawing.Point(22, 54); $b2.Size = New-Object System.Drawing.Size(200, 20)
$brand.Controls.AddRange(@($b1, $b2))
$navFlow.Controls.Add($brand)

function Show-Page {
    param([string]$Key)
    foreach ($k in @($script:Pages.Keys)) { $script:Pages[$k].Visible = ($k -eq $Key) }
    foreach ($k in @($script:NavButtons.Keys)) {
        $nb = $script:NavButtons[$k]
        if ($k -eq $Key) { $nb.BackColor = $Pal.NavActive; $nb.ForeColor = [System.Drawing.Color]::White }
        else { $nb.BackColor = $Pal.Nav; $nb.ForeColor = $Pal.NavText }
    }
    if ($Key -eq 'Status') { Update-StepList }
}

function Add-NavButton {
    param([string]$Key, [string]$Text)
    $nb = New-Object System.Windows.Forms.Button
    $nb.Text = $Text; $nb.Tag = $Key; $nb.Size = New-Object System.Drawing.Size(232, 46); $nb.Margin = New-Object System.Windows.Forms.Padding(0)
    $nb.FlatStyle = 'Flat'; $nb.FlatAppearance.BorderSize = 0; $nb.FlatAppearance.MouseOverBackColor = $Pal.NavHover
    $nb.BackColor = $Pal.Nav; $nb.ForeColor = $Pal.NavText; $nb.Font = $Fnt.Body; $nb.TextAlign = 'MiddleLeft'
    $nb.Padding = New-Object System.Windows.Forms.Padding(22, 0, 0, 0); $nb.Cursor = [System.Windows.Forms.Cursors]::Hand
    $nb.Add_Click({ param($sender, $e) Show-Page $sender.Tag })
    $script:NavButtons[$Key] = $nb
    $navFlow.Controls.Add($nb)
}

Add-NavButton 'Automate'  ([string][char]0x25B6 + '   Automatic run')
Add-NavButton 'Steps'     ([string][char]0x2630 + '   Step by step')
Add-NavButton 'Autopilot' ([string][char]0x2601 + '   Autopilot / Intune')
Add-NavButton 'Maint'     ([string][char]0x2699 + '   Maintenance')
Add-NavButton 'Status'    ([string][char]0x2714 + '   Status')

$sideBottom = New-Object System.Windows.Forms.Panel
$sideBottom.Dock = 'Bottom'; $sideBottom.Height = 128; $sideBottom.BackColor = $Pal.Nav
$script:DryBox = New-Object System.Windows.Forms.CheckBox
$script:DryBox.Text = 'Dry run'; $script:DryBox.Font = $Fnt.Semi; $script:DryBox.ForeColor = [System.Drawing.Color]::White; $script:DryBox.BackColor = $Pal.Nav
$script:DryBox.AutoSize = $true; $script:DryBox.Location = New-Object System.Drawing.Point(20, 14)
$dryNote = New-Label 'Preview every step in the log. Nothing on this device is changed.' $Fnt.Small $Pal.NavMuted $Pal.Nav
$dryNote.Location = New-Object System.Drawing.Point(22, 42); $dryNote.Size = New-Object System.Drawing.Size(196, 40)
$openLogs = New-Object System.Windows.Forms.LinkLabel
$openLogs.Text = 'Open log folder'; $openLogs.LinkColor = (Rgb 165 180 252); $openLogs.ActiveLinkColor = [System.Drawing.Color]::White
$openLogs.BackColor = $Pal.Nav; $openLogs.AutoSize = $true; $openLogs.Location = New-Object System.Drawing.Point(22, 94)
$openLogs.Add_Click({ Start-Process explorer.exe (Get-ToolkitLogDir) })
$sideBottom.Controls.AddRange(@($script:DryBox, $dryNote, $openLogs))

$sidebar.Controls.Add($navFlow)
$sidebar.Controls.Add($sideBottom)

# ---- device header -------------------------------------------------------------

$topWrap = New-Object System.Windows.Forms.Panel
$topWrap.Dock = 'Top'; $topWrap.Height = 112; $topWrap.BackColor = $Pal.Bg; $topWrap.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
$devCard = New-Card
$devCard.Dock = 'Fill'; $devCard.Padding = New-Object System.Windows.Forms.Padding(20, 12, 16, 8)
$script:DevName = New-Label 'Reading device...' $Fnt.Title $Pal.Ink $Pal.Card; $script:DevName.Dock = 'Top'; $script:DevName.Height = 34
$script:DevSub = New-Label '' $Fnt.Small $Pal.Muted $Pal.Card; $script:DevSub.Dock = 'Fill'
$txtPanel = New-Object System.Windows.Forms.Panel
$txtPanel.Dock = 'Fill'; $txtPanel.BackColor = $Pal.Card
$txtPanel.Controls.Add($script:DevSub); $txtPanel.Controls.Add($script:DevName)

$chipFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$chipFlow.Dock = 'Right'; $chipFlow.Width = 500; $chipFlow.BackColor = $Pal.Card; $chipFlow.WrapContents = $true
$chipFlow.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
$script:ChipAd = New-Chip; $script:ChipEntra = New-Chip; $script:ChipIntune = New-Chip; $script:ChipWs1 = New-Chip; $script:ChipSccm = New-Chip
foreach ($chip in @($script:ChipAd, $script:ChipEntra, $script:ChipIntune, $script:ChipWs1, $script:ChipSccm)) { Set-Chip $chip '...' 'neutral'; $chipFlow.Controls.Add($chip) }
$btnRefresh = New-Btn 'Refresh' 'Secondary' 84 26
$btnRefresh.Font = $Fnt.Small; $btnRefresh.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
$btnRefresh.Add_Click({ Update-DeviceCard; Update-AutoView })
$chipFlow.Controls.Add($btnRefresh)
$script:ActionButtons.Add($btnRefresh)
$devCard.Controls.Add($txtPanel); $devCard.Controls.Add($chipFlow)
$topWrap.Controls.Add($devCard)

# ---- activity log --------------------------------------------------------------

$logWrap = New-Object System.Windows.Forms.Panel
$logWrap.Dock = 'Bottom'; $logWrap.Height = 262; $logWrap.BackColor = $Pal.Bg; $logWrap.Padding = New-Object System.Windows.Forms.Padding(0, 12, 0, 0)
$logCard = New-Card
$logCard.Dock = 'Fill'; $logCard.BackColor = $Pal.LogBg; $logCard.Padding = New-Object System.Windows.Forms.Padding(12, 6, 12, 10)
if ($script:UiKit) { $logCard.Edge = $Pal.LogBg }
$script:LogBox = New-Object System.Windows.Forms.RichTextBox
$script:LogBox.Dock = 'Fill'; $script:LogBox.ReadOnly = $true; $script:LogBox.BackColor = $Pal.LogBg; $script:LogBox.ForeColor = $Pal.LogInk
$script:LogBox.Font = $Fnt.Mono; $script:LogBox.BorderStyle = 'None'
$script:LogHead = New-Label 'ACTIVITY' $Fnt.Small $Pal.NavMuted $Pal.LogBg; $script:LogHead.Dock = 'Top'; $script:LogHead.Height = 26; $script:LogHead.TextAlign = 'MiddleLeft'
$script:Progress = New-Object System.Windows.Forms.ProgressBar
$script:Progress.Dock = 'Top'; $script:Progress.Height = 4; $script:Progress.MarqueeAnimationSpeed = 30
$logCard.Controls.Add($script:LogBox); $logCard.Controls.Add($script:LogHead); $logCard.Controls.Add($script:Progress)
$logWrap.Controls.Add($logCard)

# ---- page: automatic run -------------------------------------------------------

$auto = New-Page 'Automate'
$hero = New-Card
$hero.Dock = 'Fill'; $hero.Height = 362; $hero.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12); $hero.Padding = New-Object System.Windows.Forms.Padding(22, 18, 18, 14)
$heroLeft = New-Object System.Windows.Forms.Panel
$heroLeft.Dock = 'Fill'; $heroLeft.BackColor = $Pal.Card
$heroRight = New-Object System.Windows.Forms.Panel
$heroRight.Dock = 'Right'; $heroRight.Width = 212; $heroRight.BackColor = $Pal.Card

$hl1 = New-Label 'Automatic migration' $Fnt.Title $Pal.Ink $Pal.Card; $hl1.Location = New-Object System.Drawing.Point(0, 0); $hl1.Size = New-Object System.Drawing.Size(470, 32)
$hl2 = New-Label 'Runs every step it can on THIS device only, in phases. A phase ends where a restart or a new sign-in is needed; progress is saved, so press the button again afterwards. Use Dry run first to preview.' $Fnt.Small $Pal.Muted $Pal.Card
$hl2.Location = New-Object System.Drawing.Point(0, 36); $hl2.Size = New-Object System.Drawing.Size(470, 56)

function New-Check { param([string]$Text, [bool]$On, [int]$Y)
    $ck = New-Object System.Windows.Forms.CheckBox
    $ck.Text = $Text; $ck.Checked = $On; $ck.Font = $Fnt.Body; $ck.ForeColor = $Pal.Ink; $ck.BackColor = $Pal.Card
    $ck.AutoSize = $false; $ck.Size = New-Object System.Drawing.Size(470, 24); $ck.Location = New-Object System.Drawing.Point(0, $Y)
    $ck.Add_CheckedChanged({ Update-AutoView })
    $ck
}
$script:ChkHash   = New-Check 'Capture the Autopilot hardware hash (group tag below)' $true 100
$tagLbl = New-Label 'Group tag' $Fnt.Body $Pal.Muted $Pal.Card; $tagLbl.Location = New-Object System.Drawing.Point(24, 134); $tagLbl.Size = New-Object System.Drawing.Size(70, 24)
$script:TagBoxAuto = New-TagCombo; $script:TagBoxAuto.Location = New-Object System.Drawing.Point(98, 130); $script:TagBoxAuto.Width = 250
$btnNewTagA = New-Btn 'New tag' 'Secondary' 108 30; $btnNewTagA.Location = New-Object System.Drawing.Point(358, 128); $btnNewTagA.Font = $Fnt.Small
$btnNewTagA.Add_Click({ [void](Add-TagFromUi) })
$script:ChkUpload = New-Check 'Upload the hash to Intune Autopilot (asks you to sign in)' $false 168
$script:ChkProf   = New-Check 'Open Profile Wizard in the last phase (you finish it by hand)' $true 196
$script:ChkDebloat = New-Check 'Remove the preinstalled apps listed in Config\toolkit.json' $true 224
$script:ChkTempAdmin = New-Check 'Remove the temporary local admin when finished' $false 252
$note = New-Label 'Only this computer is touched. Remote sessions and network locations are refused. Domain credentials are used once, in memory, to remove this computer from AD.' $Fnt.Small $Pal.Muted $Pal.Card
$note.Location = New-Object System.Drawing.Point(0, 282); $note.Size = New-Object System.Drawing.Size(470, 40)
$heroLeft.Controls.AddRange(@($hl1, $hl2, $script:ChkHash, $tagLbl, $script:TagBoxAuto, $btnNewTagA, $script:ChkUpload, $script:ChkProf, $script:ChkDebloat, $script:ChkTempAdmin, $note))

$script:BtnStart = New-Btn 'Start automatic run' 'Primary' 196 52
$script:BtnStart.Location = New-Object System.Drawing.Point(8, 4); $script:BtnStart.Font = $Fnt.Big
$script:BtnStart.Add_Click({ Start-AutoRun })
$script:AutoStatus = New-Label 'Ready.' $Fnt.Small $Pal.Muted $Pal.Card; $script:AutoStatus.Location = New-Object System.Drawing.Point(8, 66); $script:AutoStatus.Size = New-Object System.Drawing.Size(196, 110)
$script:BtnDiscard = New-Btn 'Discard saved progress' 'Secondary' 196 30; $script:BtnDiscard.Location = New-Object System.Drawing.Point(8, 182); $script:BtnDiscard.Font = $Fnt.Small
$script:BtnDiscard.Add_Click({
    if ((Show-Message 'Forget the saved progress of the automatic run? Nothing on the device is changed; the next run starts at Phase 1.' 'Discard progress' 'YesNo' 'Question') -eq 'Yes') { Clear-RunPlanState; Update-AutoView }
})
$heroRight.Controls.AddRange(@($script:BtnStart, $script:AutoStatus, $script:BtnDiscard))
$script:BtnStop = New-Btn 'Stop waiting' 'Danger' 196 30; $script:BtnStop.Location = New-Object System.Drawing.Point(8, 218); $script:BtnStop.Font = $Fnt.Small; $script:BtnStop.Enabled = $false
$script:BtnStop.Add_Click({ Request-ToolkitStop; Add-LogLine ("{0} [WARN] Stop requested; the current wait will end within a few seconds." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) })
$heroRight.Controls.Add($script:BtnStop)
$script:ActionButtons.Add($script:BtnStart); $script:ActionButtons.Add($script:BtnDiscard); $script:ActionButtons.Add($btnNewTagA)
$hero.Controls.Add($heroLeft); $hero.Controls.Add($heroRight)
Add-ToTable $auto.Table $hero

$allDefs = @(Get-RunStepDefinition)
foreach ($ph in @(Get-RunPhaseInfo)) {
    $steps = @($allDefs | Where-Object { $_.Phase -eq $ph.Phase })
    $pc = New-Card
    $pc.Dock = 'Fill'; $pc.Height = 82 + 28 * $steps.Count; $pc.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
    $pc.Padding = New-Object System.Windows.Forms.Padding(22, 14, 18, 12)
    $tbl = New-Object System.Windows.Forms.TableLayoutPanel
    $tbl.Dock = 'Fill'; $tbl.ColumnCount = 3; $tbl.RowCount = $steps.Count; $tbl.BackColor = $Pal.Card
    [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 30)))
    [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 56)))
    [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 44)))
    $row = 0
    foreach ($s in $steps) {
        [void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28)))
        $g = New-Label ([string][char]0x25CB) (New-Object System.Drawing.Font('Segoe UI Symbol', 10)) $Pal.Muted $Pal.Card; $g.Dock = 'Fill'; $g.TextAlign = 'MiddleLeft'
        $tt = New-Label $s.Title $Fnt.Body $Pal.Ink $Pal.Card; $tt.Dock = 'Fill'; $tt.TextAlign = 'MiddleLeft'
        $dd = New-Label '' $Fnt.Small $Pal.Muted $Pal.Card; $dd.Dock = 'Fill'; $dd.TextAlign = 'MiddleLeft'; $dd.AutoEllipsis = $true
        $tbl.Controls.Add($g, 0, $row); $tbl.Controls.Add($tt, 1, $row); $tbl.Controls.Add($dd, 2, $row)
        $script:StepRows[$s.Id] = @{ Glyph = $g; Title = $tt; Detail = $dd }
        $row++
    }
    $pn = New-Label $ph.Note $Fnt.Small $Pal.Muted $Pal.Card; $pn.Dock = 'Top'; $pn.Height = 24
    $pt = New-Label ("Phase {0}   {1}" -f $ph.Phase, $ph.Title) $Fnt.Big $Pal.Ink $Pal.Card; $pt.Dock = 'Top'; $pt.Height = 30
    $pc.Controls.Add($tbl); $pc.Controls.Add($pn); $pc.Controls.Add($pt)
    Add-ToTable $auto.Table $pc
}

# ---- page: step by step --------------------------------------------------------

$stepsPage = New-Page 'Steps'
Add-Heading $stepsPage.Table 'Step by step' 'Run one step at a time, in order. Every step re-checks the device, so it is safe to repeat. Each change applies to this computer only.'
Add-ActionRow $stepsPage.Table '1. Pre-flight checks' 'Read-only. Admin rights, local session, network, power, TPM, BitLocker, local admin, and the current WS1 / AD / Entra / Intune state.' @{ Name = 'Preflight' } 'Check'
Add-ActionRow $stepsPage.Table 'Check for data at risk' 'Read-only. Per profile: what is backed up to OneDrive (Known Folder Move) and what exists only on this disk, plus local PST files and folder redirection.' @{ Name = 'DataAtRisk' } 'Check'
Add-ActionRow $stepsPage.Table '2. Remove Workspace ONE' 'Uninstalls Hub / AirWatch agents, unenrolls through Windows, removes leftover tasks and registry, then verifies.' @{ Name = 'RemoveWS1'; Confirm = "Remove all of the above?`n`nTell the device's user first: apps, Wi-Fi, VPN, certificates and policies pushed by WS1 may disappear, and removal can take several minutes (do not power off).`n`nAlso retire the device in the WS1 console afterwards." } 'Remove'
Add-ActionRow $stepsPage.Table 'Verify Workspace ONE is gone' 'Deep check for programs (any version or publisher), Store apps, enrollments, services, tasks, folders, registry, certificates and packages. Removes what it safely can, lists the rest.' @{ Name = 'VerifyWS1Removed' } 'Verify'
Add-ActionRow $stepsPage.Table '3. Remove SCCM client' 'Runs ccmsetup /uninstall and waits until the client is really gone.' @{ Name = 'RemoveSCCM'; Confirm = 'Uninstall the SCCM (ConfigMgr) client?' } 'Remove'
Add-ActionRow $stepsPage.Table '4. Unjoin Active Directory' 'Refuses to run unless an enabled local admin exists. Handles hybrid join, then offers a restart. Create a local admin first if needed (Maintenance).' @{ Name = 'UnjoinAD'; Needs = 'Credential'; Confirm = "Remove this computer from Active Directory?`n`nDomain sign-in stops working after the restart. Make sure you know a LOCAL admin password and have the BitLocker recovery key recorded." } 'Unjoin'
Add-ActionRow $stepsPage.Table '5. Join Entra ID' 'Opens Settings (or installs a .ppkg from Tools\) and waits until dsregcmd confirms the join. Sign in with the user''s work account.' @{ Name = 'JoinEntra' } 'Join'
Add-ActionRow $stepsPage.Table '6. Verify Intune + escrow BitLocker' 'Confirms MDM enrollment (triggers auto-enroll if missing) and backs the BitLocker recovery key up to Entra.' @{ Name = 'VerifyIntune' } 'Verify'
Add-ActionRow $stepsPage.Table '7. Profile migration (Profwiz)' 'Launches ForensiT User Profile Wizard (GUI). Sign in as the new Entra user first; it must be run as admin.' @{ Name = 'ProfileWizard'; Confirm = 'Launch User Profile Wizard now? You still complete the wizard by hand.' } 'Launch'
Add-ActionRow $stepsPage.Table '8. Cleanup (debloat)' 'Removes the configured Appx apps for all users and the provisioned copies (list in Config\toolkit.json).' @{ Name = 'Debloat'; Confirm = 'Remove the configured preinstalled apps?' } 'Clean up'

# ---- page: autopilot / intune --------------------------------------------------

$ap = New-Page 'Autopilot'
Add-Heading $ap.Table 'Group tags and hardware hash' 'The group tag decides which Autopilot profile a device gets. Create new tags here; they are saved and offered everywhere.'
$tagCard = New-Card
$tagCard.Dock = 'Fill'; $tagCard.Height = 150; $tagCard.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10); $tagCard.Padding = New-Object System.Windows.Forms.Padding(18, 14, 18, 10)
$tl1 = New-Label 'Group tag' $Fnt.Body $Pal.Muted $Pal.Card; $tl1.Location = New-Object System.Drawing.Point(0, 6); $tl1.Size = New-Object System.Drawing.Size(80, 24)
$script:TagBoxAp = New-TagCombo; $script:TagBoxAp.Location = New-Object System.Drawing.Point(84, 3); $script:TagBoxAp.Width = 280
$btnNewTag = New-Btn 'New tag' 'Primary' 100 30; $btnNewTag.Location = New-Object System.Drawing.Point(376, 1); $btnNewTag.Font = $Fnt.Small
$btnNewTag.Add_Click({ [void](Add-TagFromUi) })
$btnDelTag = New-Btn 'Delete tag' 'Secondary' 100 30; $btnDelTag.Location = New-Object System.Drawing.Point(486, 1); $btnDelTag.Font = $Fnt.Small
$btnDelTag.Add_Click({ Remove-TagFromUi })
$tl2 = New-Label 'CSV folder' $Fnt.Body $Pal.Muted $Pal.Card; $tl2.Location = New-Object System.Drawing.Point(0, 56); $tl2.Size = New-Object System.Drawing.Size(80, 24)
$script:OutBox = New-Object System.Windows.Forms.TextBox
$script:OutBox.Location = New-Object System.Drawing.Point(84, 53); $script:OutBox.Width = 400; $script:OutBox.Font = $Fnt.Body
$script:OutBox.Text = Join-Path $PSScriptRoot 'Output\Autopilot'
$btnBrowse = New-Btn 'Browse' 'Secondary' 90 30; $btnBrowse.Location = New-Object System.Drawing.Point(496, 51); $btnBrowse.Font = $Fnt.Small
$btnBrowse.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    if (Test-Path $script:OutBox.Text) { $d.SelectedPath = $script:OutBox.Text }
    if ($d.ShowDialog() -eq 'OK') { $script:OutBox.Text = $d.SelectedPath }
})
$tl3 = New-Label 'Files are named <serial>_AutoPilotSetup.csv and carry the tag. A USB drive is fine; a network share is allowed but flagged in the log.' $Fnt.Small $Pal.Muted $Pal.Card
$tl3.Location = New-Object System.Drawing.Point(0, 94); $tl3.Size = New-Object System.Drawing.Size(640, 36)
$tagCard.Controls.AddRange(@($tl1, $script:TagBoxAp, $btnNewTag, $btnDelTag, $tl2, $script:OutBox, $btnBrowse, $tl3))
$script:ActionButtons.Add($btnNewTag); $script:ActionButtons.Add($btnDelTag); $script:ActionButtons.Add($btnBrowse)
Add-ToTable $ap.Table $tagCard
Add-ActionRow $ap.Table 'Capture this device''s hash' 'Reads the hash from WMI (no internet or gallery module needed) and writes <serial>_AutoPilotSetup.csv with the group tag above.' @{ Name = 'CaptureHash'; Needs = 'GroupTag' } 'Capture'
Add-ActionRow $ap.Table 'Merge CSVs in folder' 'Validates, de-duplicates by serial and writes one Consolidated<timestamp>.csv. Ignores earlier Consolidated* files.' @{ Name = 'MergeCsv'; Needs = 'Folder' } 'Merge'
Add-Heading $ap.Table 'Intune (Microsoft Graph)' 'Only the devices in the CSV you pick are sent to your tenant.'
Add-ActionRow $ap.Table 'Sign in to Intune' 'Interactive sign-in. Needs an Intune Administrator account and the Graph module (Maintenance).' @{ Name = 'GraphSignIn' } 'Sign in'
Add-ActionRow $ap.Table 'Upload CSV to Autopilot' 'Imports every device in a CSV, skips ones already registered, and waits for Intune to report each result.' @{ Name = 'UploadAutopilot'; Needs = 'CsvFile'; Confirm = 'Upload the selected CSV to your Intune tenant?' } 'Upload'
Add-ActionRow $ap.Table 'Sync Autopilot service' 'Asks Intune to refresh its Autopilot device list now.' @{ Name = 'AutopilotSync' } 'Sync'
$serCard = New-Card
$serCard.Dock = 'Fill'; $serCard.Height = 56; $serCard.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10); $serCard.Padding = New-Object System.Windows.Forms.Padding(18, 12, 18, 8)
$sl1 = New-Label 'Serial to look up (blank = this device)' $Fnt.Body $Pal.Muted $Pal.Card; $sl1.Location = New-Object System.Drawing.Point(0, 4); $sl1.Size = New-Object System.Drawing.Size(250, 24)
$script:SerialBox = New-Object System.Windows.Forms.TextBox; $script:SerialBox.Location = New-Object System.Drawing.Point(254, 1); $script:SerialBox.Width = 240; $script:SerialBox.Font = $Fnt.Body
$serCard.Controls.AddRange(@($sl1, $script:SerialBox))
Add-ToTable $ap.Table $serCard
Add-ActionRow $ap.Table 'Look up device in Intune' 'Shows the Autopilot registration (group tag, profile status) and the Intune managed device (compliance, last sync). Read-only.' @{ Name = 'DeviceLookup'; Needs = 'Serial' } 'Look up'

# ---- page: maintenance ---------------------------------------------------------

$mt = New-Page 'Maint'
Add-Heading $mt.Table 'Local admin safety net' 'Created only if needed. The toolkit will not modify or delete a local account it did not create.'
Add-ActionRow $mt.Table 'Create temporary local admin' 'Creates / re-enables the account named in Config\toolkit.json so you are not locked out after the domain unjoin.' @{ Name = 'CreateLocalAdmin'; Needs = 'LocalAdminPw'; Confirm = 'Create (or reset) the temporary local administrator account?' } 'Create'
Add-ActionRow $mt.Table 'Remove temporary local admin' 'Deletes that account once migration is finished.' @{ Name = 'RemoveLocalAdmin'; Confirm = 'Delete the temporary local admin account?' } 'Remove'
Add-Heading $mt.Table 'Intune / Entra helpers'
Add-ActionRow $mt.Table 'Force Intune enrollment' 'Runs deviceenroller /AutoEnrollMDM if the device is Entra joined but not yet enrolled.' @{ Name = 'IntuneSyncNow' } 'Enroll'
Add-ActionRow $mt.Table 'Prepare BitLocker recovery key' 'Makes sure a recovery password exists and escrows it to Active Directory while the device is still joined. The key is never logged or saved to disk.' @{ Name = 'BitLockerPrep' } 'Prepare'
Add-ActionRow $mt.Table 'Save migration report' 'Writes a plain-text summary (join state, Intune, Workspace ONE leftovers, BitLocker, step results) to Output\Reports.' @{ Name = 'MigrationReport' } 'Save'
Add-ActionRow $mt.Table 'Back up BitLocker key to Entra' 'Escrows the OS-drive recovery password to Entra ID.' @{ Name = 'BackupBitLocker' } 'Back up'
Add-ActionRow $mt.Table 'Install Graph module' 'Installs Microsoft.Graph.Authentication for the current user from PSGallery (needed for Intune upload).' @{ Name = 'InstallGraph'; Confirm = 'Download and install Microsoft.Graph.Authentication from the PowerShell Gallery?' } 'Install'
Add-Heading $mt.Table 'Tools and power'
Add-ActionRow $mt.Table 'Run McAfee removal (MCPR)' 'Runs Tools\MCPR.exe after checking its digital signature; refuses an unsigned file.' @{ Name = 'RunMCPR'; Confirm = 'Run the McAfee Consumer Product Removal tool?' } 'Run'
Add-ActionRow $mt.Table 'Restart in 60 seconds' 'Schedules a restart you can cancel below.' @{ Name = 'Restart'; Needs = 'Restart'; Confirm = 'Restart this device in 60 seconds?' } 'Restart'
Add-ActionRow $mt.Table 'Cancel pending restart' 'Runs shutdown /a.' @{ Name = 'CancelRestart' } 'Cancel'

# ---- page: status --------------------------------------------------------------

$st = New-Page 'Status'
Add-Heading $st.Table 'Step results' 'Saved on this device in C:\ProgramData\MigrationToolkit\state.json and kept across restarts.'
function New-ListCard {
    param([int]$Height, $Columns)
    $card = New-Card
    $card.Dock = 'Fill'; $card.Height = $Height; $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12); $card.Padding = New-Object System.Windows.Forms.Padding(10)
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.BorderStyle = 'None'; $lv.Dock = 'Fill'; $lv.Font = $Fnt.Body
    $lv.HeaderStyle = 'Nonclickable'; $lv.HideSelection = $false; $lv.BackColor = $Pal.Card
    foreach ($col in $Columns) { [void]$lv.Columns.Add($col[0], $col[1]) }
    $card.Controls.Add($lv)
    [pscustomobject]@{ Card = $card; List = $lv }
}
$sl = New-ListCard 230 @(@('Step', 230), @('Status', 90), @('When', 150), @('Detail', 380))
$script:StepList = $sl.List
Add-ToTable $st.Table $sl.Card
Add-Heading $st.Table 'Check results' 'Filled in by Pre-flight, Data at risk and Verify Workspace ONE.'
$cl = New-ListCard 360 @(@('Result', 70), @('Check', 230), @('Detail', 560))
$script:CheckList = $cl.List
Add-ToTable $st.Table $cl.Card

# ---- assemble ------------------------------------------------------------------

$pagesHost = New-Object System.Windows.Forms.Panel
$pagesHost.Dock = 'Fill'; $pagesHost.BackColor = $Pal.Bg
foreach ($k in @($script:Pages.Keys)) { $pagesHost.Controls.Add($script:Pages[$k]) }

$content = New-Object System.Windows.Forms.Panel
$content.Dock = 'Fill'; $content.BackColor = $Pal.Bg; $content.Padding = New-Object System.Windows.Forms.Padding(22, 18, 18, 18)
$content.Controls.Add($pagesHost); $content.Controls.Add($logWrap); $content.Controls.Add($topWrap)

# Fill control first, then the docked edges (WinForms docks later-added controls first).
$script:Form.Controls.Add($content)
$script:Form.Controls.Add($sidebar)

# ---- behaviour -----------------------------------------------------------------

function Set-UiBusy {
    param([bool]$Busy)
    $script:Busy = $Busy
    $script:Progress.Style = if ($Busy) { 'Marquee' } else { 'Continuous' }
    $script:Progress.Value = 0
    foreach ($b in $script:ActionButtons) { $b.Enabled = -not $Busy }
    $script:BtnStop.Enabled = $Busy
    $script:DryBox.Enabled = -not $Busy
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
        if ($status -eq 'Done') { $item.ForeColor = $Pal.Ok }
        elseif ($status -eq 'Failed') { $item.ForeColor = $Pal.Bad }
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
            'Pass' { $item.ForeColor = $Pal.Ok }
            'Warn' { $item.ForeColor = $Pal.Warn }
            'Fail' { $item.ForeColor = $Pal.Bad }
        }
        [void]$script:CheckList.Items.Add($item)
    }
}

function Add-LogLine {
    param([string]$Line)
    $color = $Pal.LogInk
    if ($Line -match '\[ERROR\]') { $color = (Rgb 248 113 113) }
    elseif ($Line -match '\[WARN\]') { $color = (Rgb 251 191 36) }
    elseif ($Line -match '\[OK\]') { $color = (Rgb 74 222 128) }
    elseif ($Line -match '\[STEP\]') { $color = (Rgb 129 140 248) }
    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.SelectionLength = 0
    $script:LogBox.SelectionColor = $color
    $script:LogBox.AppendText($Line + [Environment]::NewLine)
    $script:LogBox.ScrollToCaret()
}

function Update-DeviceCard {
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { $s = Get-DeviceSnapshot }
    catch { Add-LogLine ("{0} [WARN] Could not read device state: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message); return }
    finally { $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default }
    $script:Snap = $s
    $script:DevName.Text = $s.ComputerName
    $script:DevSub.Text = "Serial $($s.Serial)     Signed in as $($s.User)"
    if ($s.AdJoined) { Set-Chip $script:ChipAd "Active Directory: $($s.AdName)" 'warn' } else { Set-Chip $script:ChipAd 'Active Directory: not joined' 'neutral' }
    if ($s.EntraJoined) { Set-Chip $script:ChipEntra 'Entra ID: joined' 'ok' } else { Set-Chip $script:ChipEntra 'Entra ID: not joined' 'neutral' }
    if ($s.Intune) { Set-Chip $script:ChipIntune 'Intune: enrolled' 'ok' } else { Set-Chip $script:ChipIntune 'Intune: not enrolled' 'neutral' }
    if ($s.WorkspaceOne) { Set-Chip $script:ChipWs1 'Workspace ONE: present' 'warn' } else { Set-Chip $script:ChipWs1 'Workspace ONE: none' 'ok' }
    if ($s.Sccm) { Set-Chip $script:ChipSccm 'SCCM: present' 'warn' } else { Set-Chip $script:ChipSccm 'SCCM: none' 'ok' }
}

function Get-AutoOption {
    @{
        GroupTag = $script:TagBoxAuto.Text.Trim(); OutputFolder = $script:OutBox.Text.Trim()
        CaptureHash = $script:ChkHash.Checked; UploadHash = $script:ChkUpload.Checked
        LaunchProfwiz = $script:ChkProf.Checked; Debloat = $script:ChkDebloat.Checked; RemoveTempAdmin = $script:ChkTempAdmin.Checked
    }
}

function Get-OwnPlan {
    $plan = Get-RunPlanState -Dry:$script:DryBox.Checked
    if (-not $plan) { return $null }
    if ($script:Snap -and $script:Snap.MachineGuid -and $plan.Device.MachineGuid -and $plan.Device.MachineGuid -ne $script:Snap.MachineGuid) { return $null }
    $plan
}

function Update-AutoView {
    $o = Get-AutoOption
    $plan = Get-OwnPlan
    $recs = @{}
    if ($plan) { foreach ($r in @($plan.Steps)) { $recs[$r.Id] = $r } }
    $curPhase = 1; if ($plan -and $plan.Status -ne 'Completed') { $curPhase = [int]$plan.Phase }
    $remain = 0; $spent = 0
    foreach ($d in @(Get-RunStepDefinition -Options $o)) {
        $row = $script:StepRows[$d.Id]
        if (-not $row) { continue }
        $status = 'Pending'; $detail = ''
        if ($recs.ContainsKey($d.Id)) { $status = [string]$recs[$d.Id].Status; $detail = [string]$recs[$d.Id].Detail }
        if (-not $d.Enabled -and $status -in 'Pending', 'Skipped') { $status = 'Off'; $detail = 'Turned off' }
        switch ($status) {
            'Done'    { $g = 0x2713; $col = $Pal.Ok }
            'DryRun'  { $g = 0x2713; $col = $Pal.Warn }
            'Running' { $g = 0x25CF; $col = $Pal.Accent }
            'Failed'  { $g = 0x2715; $col = $Pal.Bad }
            'Skipped' { $g = 0x2013; $col = $Pal.Muted }
            'Off'     { $g = 0x2013; $col = $Pal.Muted }
            default   { $g = 0x25CB; $col = $Pal.Muted }
        }
        $estSec = 0; if ($script:Est.ContainsKey($d.Id)) { $estSec = $script:Est[$d.Id] }
        $estText = ''; if ($estSec) { $estText = Format-Duration $estSec }
        $took = 0; $since = 0
        if ($recs.ContainsKey($d.Id)) { $took = [int]$recs[$d.Id].Seconds; if ($status -eq 'Running' -and $recs[$d.Id].Time) { try { $since = ((Get-Date) - [datetime]$recs[$d.Id].Time).TotalSeconds } catch {} } }
        switch ($status) {
            'Pending' { if ($estText) { $detail = "about $estText" } }
            'Running' { $detail = "running $(Format-Duration $since)"; if ($estText) { $detail += " of about $estText" } }
            { $_ -in 'Done', 'DryRun' } { if ($took -gt 0) { $detail = ("took $(Format-Duration $took)  " + $detail).Trim() } }
        }
        if ($d.Phase -eq $curPhase -and $d.Enabled) {
            if ($status -eq 'Pending') { $remain += $estSec }
            elseif ($status -eq 'Running') { $remain += [math]::Max(0, $estSec - $since); $spent += $since }
            elseif ($took -gt 0) { $spent += $took }
        }
        $row.Glyph.Text = [string][char]$g; $row.Glyph.ForeColor = $col
        $row.Title.ForeColor = $(if ($status -in 'Off', 'Skipped') { $Pal.Muted } else { $Pal.Ink })
        $row.Detail.Text = $detail
        $row.Detail.ForeColor = $(if ($status -eq 'Failed') { $Pal.Bad } else { $Pal.Muted })
    }
    $text = 'Press the button to begin with Phase 1.'
    $label = 'Start automatic run'
    if ($plan -and $plan.Status -ne 'Completed') {
        $label = "Continue: Phase $($plan.Phase)"
        if ($plan.Message) { $text = [string]$plan.Message } else { $text = "Phase $($plan.Phase) is next." }
        if ($plan.Status -eq 'Failed') { $text = "Stopped: $($plan.Message)" }
    } elseif ($plan) { $text = 'All phases finished on this device.'; $label = 'Run again from Phase 1' }
    if ($remain -gt 0 -or $spent -gt 0) { $text += "`nPhase $curPhase time: $(Format-Duration $spent) so far, about $(Format-Duration $remain) left" }
    if ($script:DryBox.Checked) { $text = "DRY RUN: nothing will change.`n$text" }
    $script:BtnStart.Text = $label
    $script:AutoStatus.Text = $text
}

# Collects whatever input an action needs on the UI thread. Returns $null if the user cancels.
function Get-UiParam {
    param([hashtable]$Tag)
    $p = @{}
    switch ($Tag.Needs) {
        'Credential' {
            $ans = Show-Message "Unjoin needs a domain account that is allowed to remove THIS computer from AD.`n`nYes = enter AD credentials (used once, kept only in memory)`nNo = offline unjoin (no credentials; the AD computer object stays and must be deleted manually)`nCancel = stop" 'Active Directory unjoin' 'YesNoCancel' 'Question'
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
            $tag = $script:TagBoxAp.Text.Trim()
            if ($tag) {
                $err = Test-GroupTagName $tag
                if ($err) { Show-Message $err 'Group tag' 'OK' 'Warning' | Out-Null; return $null }
                if ((Get-GroupTagList) -notcontains $tag) {
                    $a = Show-Message "'$tag' is a new group tag. Save it to the list so you can pick it next time?" 'New group tag' 'YesNoCancel' 'Question'
                    if ($a -eq 'Cancel') { return $null }
                    if ($a -eq 'Yes') { try { [void](Add-GroupTag -Name $tag); Sync-TagBox $tag } catch { Show-Message $_.Exception.Message 'Group tag' 'OK' 'Error' | Out-Null; return $null } }
                }
            } elseif ((Show-Message 'No group tag is selected, so the device is captured with an empty tag and gets no tag-based profile. Continue?' 'No group tag' 'YesNo' 'Warning') -ne 'Yes') { return $null }
            $p.GroupTag = $tag
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

function Start-UiJob {
    param([hashtable]$Tag, [hashtable]$Params)
    $script:JobTag = $Tag
    $script:JobStart = Get-Date
    Set-UiBusy $true
    $dry = $script:DryBox.Checked
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
    }).AddArgument($modulePath).AddArgument($script:Queue).AddArgument($dry).AddArgument($Tag.Name).AddArgument($Params)
    $script:Async = $script:Shell.BeginInvoke()
}

function Update-JobClock {
    if (-not $script:JobStart -or -not $script:JobTag) { return }
    $name = $script:JobTag.Name
    $el = ((Get-Date) - $script:JobStart).TotalSeconds
    $text = "ACTIVITY     $name   elapsed $(Format-Duration $el)"
    $key = $name; if ($script:EstKey.ContainsKey($name)) { $key = $script:EstKey[$name] }
    if ($name -ne 'RunPhase' -and $script:Est.ContainsKey($key)) { $text += "   (usually about $(Format-Duration $script:Est[$key]))" }
    $script:LogHead.Text = $text
}

function Get-DevicePrefix {
    if ($script:Snap) { "Device: $($script:Snap.ComputerName) (serial $($script:Snap.Serial))`nOnly this computer is changed.`n`n" } else { '' }
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
        $r = Show-Message ((Get-DevicePrefix) + $Tag.Confirm) 'Confirm' 'YesNo' 'Warning'
        if ($r -ne 'Yes') { return }
    }
    $params = Get-UiParam -Tag $Tag
    if ($null -eq $params) { return }
    if ($script:Snap -and $script:Snap.Serial) { $params.ExpectSerial = $script:Snap.Serial }
    Start-UiJob -Tag $Tag -Params $params
}

function Start-AutoRun {
    if ($script:Busy) { Show-Message 'Another action is still running.' | Out-Null; return }
    $dry = $script:DryBox.Checked
    Update-DeviceCard
    if (-not $script:Snap) { return }
    $snap = $script:Snap
    $o = Get-AutoOption
    $plan = Get-OwnPlan
    $phase = 1
    if ($plan -and $plan.Status -ne 'Completed') { $phase = [int]$plan.Phase }

    if ($phase -le 1 -and $o.CaptureHash) {
        $err = Test-GroupTagName $o.GroupTag
        if ($err) { Show-Message "Choose or create a group tag first (or untick the hash capture).`n`n$err" 'Group tag' 'OK' 'Warning' | Out-Null; return }
        if ((Get-GroupTagList) -notcontains $o.GroupTag) {
            $a = Show-Message "'$($o.GroupTag)' is a new group tag. Save it to the list?" 'New group tag' 'YesNoCancel' 'Question'
            if ($a -eq 'Cancel') { return }
            if ($a -eq 'Yes') { try { [void](Add-GroupTag -Name $o.GroupTag); Sync-TagBox $o.GroupTag } catch { Show-Message $_.Exception.Message 'Group tag' 'OK' 'Error' | Out-Null; return } }
        }
    }

    $todo = @(Get-RunStepDefinition -Options $o | Where-Object { $_.Phase -eq $phase -and $_.Enabled } | ForEach-Object { "  - $($_.Title)" })
    $info = @(Get-RunPhaseInfo | Where-Object { $_.Phase -eq $phase })[0]
    $summary = "Phase $phase of 3: $($info.Title)`n`n$($todo -join "`n")`n`n$($info.Note)"
    if (-not $dry) {
        if ($phase -le 1) {
            $prompt = "This runs on THIS device only:`n`n    $($snap.ComputerName)   (serial $($snap.Serial))`n`n$summary`n`nTell the device's user first. Type the computer name to continue."
            $typed = Show-InputDialog -Title 'Confirm automatic run' -Prompt $prompt -OkText 'Start' -Initial ''
            if ($null -eq $typed -or $typed.Trim() -ne $snap.ComputerName) { if ($null -ne $typed) { Show-Message 'The name did not match, so nothing was started.' 'Not started' 'OK' 'Information' | Out-Null }; return }
        } else {
            if ((Show-Message ((Get-DevicePrefix) + $summary + "`n`nStart this phase?") 'Confirm phase' 'YesNo' 'Question') -ne 'Yes') { return }
        }
        if ($phase -le 1 -and $snap.AdJoined) {
            $cp = Get-UiParam @{ Needs = 'Credential' }
            if ($null -eq $cp) { return }
            if ($cp.Credential) { $o.AdCredential = $cp.Credential } else { $o.Offline = $true }
            if (@(Get-LocalAdminCandidate).Count -eq 0) {
                $ap2 = Get-UiParam @{ Needs = 'LocalAdminPw' }
                if ($null -eq $ap2) { return }
                $o.AdminPassword = $ap2.Password
            }
        }
    }
    Add-LogLine ("{0} [STEP] Starting phase {1} on {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $phase, $snap.ComputerName)
    Start-UiJob -Tag @{ Name = 'RunPhase' } -Params @{ Phase = $phase; Options = $o; ExpectSerial = $snap.Serial }
}

function Complete-UiJob {
    $tag = $script:JobTag
    $results = $null
    try { $results = $script:Shell.EndInvoke($script:Async) } catch { Add-LogLine ("{0} [ERROR] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message) }
    $script:Shell.Dispose(); $script:Runspace.Dispose()
    $script:Shell = $null; $script:Runspace = $null; $script:Async = $null
    Set-UiBusy $false
    if ($script:JobStart) { $script:LogHead.Text = "ACTIVITY     last: $($tag.Name) took $(Format-Duration (((Get-Date) - $script:JobStart).TotalSeconds))" }
    $script:Est = Get-StepEstimate
    $dry = $script:DryBox.Checked
    Update-StepList
    Update-AutoView
    if ($tag.Name -notin 'Preflight', 'DeviceLookup', 'Restart', 'CancelRestart') { Update-DeviceCard }
    if ($tag.Name -in 'Preflight', 'DataAtRisk', 'VerifyWS1Removed' -and $results) { Update-CheckList $results; Show-Page 'Status' }
    if ($tag.Name -eq 'RunPhase') {
        $res = @($results) | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'RestartNeeded' } | Select-Object -Last 1
        if ($res) {
            if ($res.Status -eq 'Failed') {
                Show-Message "The run stopped.`n`n$($res.Message)`n`nFix the problem and press the button again. Steps that already finished are not repeated." 'Run stopped' 'OK' 'Warning' | Out-Null
            } elseif ($res.RestartNeeded -and -not $dry) {
                $r = Show-Message "$($res.Message)`n`nRestart in 60 seconds?" 'Restart needed' 'YesNo' 'Question'
                if ($r -eq 'Yes') { Start-UiAction @{ Name = 'Restart'; Needs = 'Restart' } }
            } elseif ($res.Status -eq 'Completed') {
                Show-Message 'All phases finished on this device.' 'Done' 'OK' 'Information' | Out-Null
            }
        }
        return
    }
    if ($tag.Name -eq 'RemoveWS1' -and -not $dry) {
        $s = @(Get-StepState) | Where-Object { $_.Step -eq 'RemoveWS1' } | Select-Object -First 1
        if ($s -and $s.Status -eq 'Done') {
            $r = Show-Message "Workspace ONE removal was verified. A restart is recommended before the next step.`n`nRestart in 60 seconds?" 'Restart recommended' 'YesNo' 'Question'
            if ($r -eq 'Yes') { Start-UiAction @{ Name = 'Restart'; Needs = 'Restart' } }
        }
    }
    if ($tag.Name -eq 'UnjoinAD' -and -not $dry) {
        $s = @(Get-StepState) | Where-Object { $_.Step -eq 'UnjoinAD' } | Select-Object -First 1
        if ($s -and $s.Status -eq 'Done') {
            $r = Show-Message "The device left the domain. A restart is required.`n`nSign in afterwards with the local admin account, then continue with 'Join Entra ID'.`n`nRestart in 60 seconds?" 'Restart required' 'YesNo' 'Question'
            if ($r -eq 'Yes') { Start-UiAction @{ Name = 'Restart'; Needs = 'Restart' } }
        }
    }
}

$script:DryBox.Add_CheckedChanged({
    $script:Form.Text = $(if ($script:DryBox.Checked) { 'Device Migration Toolkit  -  DRY RUN' } else { 'Device Migration Toolkit' })
    Update-AutoView
})

# ---- timer / lifecycle ---------------------------------------------------------

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    $line = $null
    while ($script:Queue.TryDequeue([ref]$line)) { Add-LogLine $line }
    if ($script:Async -and $script:Async.IsCompleted) {
        $line = $null
        while ($script:Queue.TryDequeue([ref]$line)) { Add-LogLine $line }
        Complete-UiJob
    } elseif ($script:Busy) {
        Update-JobClock
        $script:Tick++
        if ($script:Tick % 6 -eq 0 -and $script:JobTag -and $script:JobTag.Name -eq 'RunPhase') { Update-AutoView }
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
    Show-Page 'Automate'
    Update-StepList
    Update-DeviceCard
    Update-AutoView
    Add-LogLine ("{0} [INFO] Ready. Logs: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), (Get-ToolkitLogDir))
    $plan = Get-OwnPlan
    if ($plan -and $plan.Status -in 'Paused', 'Failed', 'InProgress') {
        Add-LogLine ("{0} [WARN] An automatic run is in progress on this device: Phase {1} is next. {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $plan.Phase, $plan.Message)
    }
})

try { [void]$script:Form.ShowDialog() }
catch { Show-Message "Fatal error: $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'Migration Toolkit' 'OK' 'Error' | Out-Null }
finally { $timer.Stop(); $timer.Dispose() }
