<#
    Robert Stepp, robert@robertstepp.ninja

    File Checker v6.0

    Builds a SHA-512 listing of a folder before it is transferred, then verifies
    that listing at the destination. The script copies itself into the folder it
    scans, so the listing, the integrity sidecar, and the tooling all travel
    with the data.

    Hashing runs in parallel. This process is the parent: it spawns up to
    -Parallel child PowerShell processes running this same file with
    -HashWorker, feeds them file paths, and collects the filename and hash each
    one returns. -Parallel 1 keeps everything in this process, which is what
    every version up to 5.13 did, and is also the automatic fallback if the
    child processes cannot be started.

    See README.md for the workflow, the output files, and the change history.

    Usage:
        powershell -File filechecker6_0.ps1
        powershell -File filechecker6_0.ps1 -DebugMode
        powershell -File filechecker6_0.ps1 -BasePath "D:\Transfer"
        powershell -File filechecker6_0.ps1 -DebugMode -SkipArchiveContents
        powershell -File filechecker6_0.ps1 -ReportExtraFiles
        powershell -File filechecker6_0.ps1 -IncludeSystemFiles
        powershell -File filechecker6_0.ps1 -Parallel 8
        powershell -File filechecker6_0.ps1 -Parallel 1
#>

#Requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Internal helper functions in a standalone script; ShouldProcess/-WhatIf would add boilerplate with no user benefit.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter', 'ReportExtraFiles',
    Justification = 'False positive: the rule only looks inside the declaring scope. This script-level parameter is read in Compare-HashEntryThorough (six times) and Select-VerificationMode.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter', 'Parallel',
    Justification = 'False positive: the rule only looks inside the declaring scope. This script-level parameter is read in Invoke-ParallelFileScan, Get-ParallelVerifyStatus, and Invoke-ParallelHash.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter', 'IncludeSystemFiles',
    Justification = 'False positive: the rule only looks inside the declaring scope. This script-level parameter is read in Invoke-FileScan, twice.')]
param(
    [switch] $DebugMode,
    [string] $BasePath,
    [switch] $SkipArchiveContents,
    # Comprehensive mode discards destination files that were not in the initial
    # listing. Set this to flag them as differences instead (burn-to-disc case,
    # where an unexpected file on the destination is itself a finding).
    [switch] $ReportExtraFiles,
    # How many child processes hash files at once. This process is always the
    # parent: it feeds the children and collects what they return, and never
    # hashes alongside them, so the machine sees at most $Parallel concurrent
    # readers.
    #
    # 1 means no children at all -- the hashing loop runs here, exactly as it
    # did through v5.13. That is the right setting for optical discs and network
    # shares, where several concurrent readers are slower than one, not faster.
    # It is also what the script falls back to on its own if the children cannot
    # be started.
    #
    # The default is deliberately not the full CPU count. SHA-512 is CPU-bound,
    # but this script is pointed at removable media often enough that saturating
    # every core by default would be the wrong trade for the common case.
    [ValidateRange(1, 64)]
    [int] $Parallel = [Math]::Min(4, [Environment]::ProcessorCount),
    # Internal re-entry point. A worker started by Start-HashWorkerPool runs the
    # same file with this switch: it reads work items on stdin, writes results
    # on stdout, shows no UI, and writes nothing to disk. Not for interactive
    # use -- run without it and the script behaves normally.
    [switch] $HashWorker,
    # Hash the volume's own housekeeping files too -- System Volume Information,
    # $RECYCLE.BIN, Thumbs.db, .DS_Store and the rest. They are skipped by
    # default because they are not part of what is being transferred: they pad
    # the listing with the operator's deleted files and thumbnail caches, and on
    # a Comprehensive verify with -ReportExtraFiles the destination volume's own
    # System Volume Information would be reported as a difference on a transfer
    # where nothing went wrong.
    #
    # Pass this for forensic work, where the whole volume is the subject and
    # everything on it is evidence.
    [switch] $IncludeSystemFiles
)

$DebugPreference = if ($DebugMode) { 'Continue' } else { 'SilentlyContinue' }

# A worker shows no UI, so loading WinForms and GDI+ in every child process
# would cost time and handles for nothing. Both Compression assemblies load
# either way: workers are the ones that expand zip archives.
if (-not $HashWorker) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$hashTypes = [ordered]@{ SHA1 = 40; SHA256 = 64; SHA384 = 96; SHA512 = 128; MD5 = 32 }

# .tar.gz first so EndsWith picks the longer match.
$archiveExtensions = @('.tar.gz', '.tgz', '.zip', '.tar', '.iso')

# CSV text encoding, chosen per host so both hosts write identical bytes.
#
# Export-Csv's default is not the same on both: Windows PowerShell 5.1 writes
# ASCII, so every non-ASCII character in a filename is written as "?" and the
# file can no longer be found at verification -- it comes back Missing on a
# transfer where nothing is actually wrong. PowerShell 7 writes BOM-less UTF-8.
# A listing built on one host is routinely verified on the other, so the two
# have to agree.
#
# UTF-8 with a BOM is the form both hosts write and both read unambiguously,
# but they spell it differently: 5.1's 'UTF8' emits the BOM, while 7's 'utf8'
# is BOM-less and needs 'utf8BOM'. The same name is passed to Import-Csv, which
# stays backward compatible -- an ASCII CSV from an older version is valid
# UTF-8 and decodes unchanged.
$script:CsvEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }

# Collected during initial build; written into the manifest log.
$script:ArchiveWarnings = New-Object System.Collections.Generic.List[string]

# Folders seen by the most recent Invoke-FileScan. Manifest listing only --
# folders have no hash and never enter the CSV or the comparison.
$script:LastScanFolders = New-Object System.Collections.Generic.List[string]

# Set only inside a spawned worker. Add-ArchiveWarning routes into
# $script:WorkerWarnings instead of the console when this is on: a worker's
# stdout carries the wire protocol and must stay clean, and its stderr is not
# read until the worker exits, so neither is a place to write to.
# How long the run just finished spent walking the tree and how long it spent
# hashing, reported in the manifest, the verification log, and the closing
# dialogs. Kept apart because they answer different questions: enumeration
# scales with the number of files, hashing with the number of bytes and with
# -Parallel. Enumerate is $null on the Basic verification path, which walks the
# CSV rather than the disk and so never enumerates anything.
$script:LastEnumerateTime = $null
$script:LastHashTime      = $null

$script:IsWorker       = [bool]$HashWorker
$script:WorkerWarnings = New-Object System.Collections.Generic.List[string]

# WinForms requires a single-threaded apartment. Windows PowerShell 5.1 starts
# STA by default; pwsh 7 does not always, and ShowDialog misbehaves under MTA.
if (-not $HashWorker -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Warning ("This host is running MTA, not STA. Dialogs may hang or render " +
                   "incorrectly. Relaunch with:  powershell -STA -File <script>")
}

# =====================================================================
#  Hashing
#
#  One reusable provider plus an explicitly buffered, sequential-scan
#  FileStream. Get-FileHash allocates a new algorithm object and pays
#  full cmdlet parameter binding on every call, which is measurable
#  across thousands of files.
# =====================================================================

$script:Sha512 = [System.Security.Cryptography.SHA512]::Create()

function Get-FileSha512 {
    param([Parameter(Mandatory)][string] $Path)
    $stream = [System.IO.FileStream]::new(
        $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite, 1MB,
        [System.IO.FileOptions]::SequentialScan)
    try {
        return ([BitConverter]::ToString($script:Sha512.ComputeHash($stream))).Replace('-', '')
    } finally {
        $stream.Dispose()
    }
}

# =====================================================================
#  Path / lookup helpers
# =====================================================================

function Get-ParentScriptFolder {
    if ($PSScriptRoot)                 { return $PSScriptRoot }
    if ($MyInvocation.MyCommand.Path)  { return Split-Path -Path $MyInvocation.MyCommand.Path }
    return (Get-Location).Path
}

# Start transcript only after script folder is known. Workers are excluded:
# several processes appending to one debug.log fails, and the transcript would
# be a scan artefact written by a process that is not meant to write anything.
if ($DebugMode -and -not $HashWorker) {
    try { Start-Transcript -Path (Join-Path (Get-ParentScriptFolder) 'debug.log') -Append | Out-Null }
    catch { Write-Warning "Could not start transcript: $_" }
}
Write-Debug "DebugMode=$DebugMode  BasePath=$BasePath  SkipArchiveContents=$SkipArchiveContents"

function Search-InitialFileExistence {
    # Sort descending so the newest timestamped CSV wins deterministically.
    # Get-ChildItem's own order is filesystem-dependent, which meant that with
    # two listings present the script could silently verify against the older.
    # Not $matches: that is the automatic variable -match and switch -regex fill
    # in, and this script uses -match elsewhere. Assigning to it would clobber
    # those results (PSAvoidAssignmentToAutomaticVariable).
    $csvFiles = @(Get-ChildItem -Path (Get-ParentScriptFolder) -Filter "*-initial.hashes.csv" `
                    -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($csvFiles.Count -eq 0) { return $false }
    if ($csvFiles.Count -gt 1) {
        Write-Warning "$($csvFiles.Count) initial CSVs found; using the newest: $($csvFiles[0].Name)"
    }
    return $csvFiles[0].FullName
}

function Initialize-InitialFilePath {
    # Used by Set-InitialFileManual. Set-InitialFileAutomatic generates its
    # own stamp so all three output filenames share the exact same timestamp.
    Join-Path (Get-ParentScriptFolder) ((Get-Date -Format yyyyMMdd_HHmm) + "-initial.hashes.csv")
}

function Get-TransferName {
    # Prompt the user for a Data Transfer Name; returns the entered string
    # or the default if nothing is typed.
    param([string] $Default)
    $form = New-FormControl Form @{
        Text = 'Data Transfer Name'; Size = (New-Sz 420 150); StartPosition = 'CenterScreen'
    }
    $label = New-FormControl Label @{
        Location = (New-Pt 10 15); Size = (New-Sz 390 20)
        Text = 'Enter a name for this transfer (leave blank to use default):'
    }
    $textBox = New-FormControl TextBox @{
        Location = (New-Pt 10 40); Size = (New-Sz 390 20); Text = $Default
    }
    $okBtn = New-FormControl Button @{
        Location = (New-Pt 155 80); Size = (New-Sz 100 28); Text = 'OK'
    }
    $script:transferName = $Default
    $okBtn.Add_Click({
        $val = $textBox.Text.Trim()
        $script:transferName = if ($val -ne '') { $val } else { $Default }
        $form.Close()
    })
    # Allow Enter key to confirm.
    $form.AcceptButton = $okBtn
    $form.Controls.AddRange(@($label, $textBox, $okBtn))
    try { $form.ShowDialog() | Out-Null } finally { $form.Dispose() }
    return $script:transferName
}

function Get-HashType {
    # Guard against null/blank so a malformed CSV row reports BadHashType
    # instead of throwing on .Length.
    param([string] $InputHash)
    if ([string]::IsNullOrWhiteSpace($InputHash)) { return $null }
    $len = $InputHash.Trim().Length
    foreach ($k in $hashTypes.Keys) {
        if ($hashTypes[$k] -eq $len) { return $k }
    }
    return $null
}

function ConvertTo-SafeFileNamePart {
    # Strips characters Windows forbids in filenames so a folder name can be
    # embedded in an output filename safely.
    param([string] $Text)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Text.ToCharArray()) {
        if ($invalid -contains $c) { [void]$sb.Append('_') } else { [void]$sb.Append($c) }
    }
    $clean = $sb.ToString().Trim(' ', '.')
    if ([string]::IsNullOrWhiteSpace($clean)) { return 'Root' }
    return $clean
}

function Get-ScanFolderLabel {
    # Leaf folder name of the scan root, used for Filelist-<folder>.txt.
    # A drive root such as "D:\" has no leaf, so fall back to "D_Drive".
    param([string] $ScanRoot)
    $trimmed = $ScanRoot.TrimEnd('\', '/')
    if ($trimmed -match '^[A-Za-z]:$') { return "$($trimmed.Substring(0,1))_Drive" }
    $leaf = Split-Path -Path $trimmed -Leaf
    if ([string]::IsNullOrWhiteSpace($leaf)) { return 'Root' }
    return (ConvertTo-SafeFileNamePart $leaf)
}

function Get-NonCollidingPath {
    # Filelist names are not timestamped, so a second run in the same folder
    # would overwrite the first. Append _2, _3, ... instead.
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $dir  = Split-Path -Path $Path -Parent
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $ext  = [System.IO.Path]::GetExtension($Path)
    for ($n = 2; $n -lt 1000; $n++) {
        $candidate = Join-Path $dir ("{0}_{1}{2}" -f $base, $n, $ext)
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $Path
}

function Get-ArchiveExtension {
    param([string] $FilePath)
    $lower = $FilePath.ToLowerInvariant()
    foreach ($ext in $archiveExtensions) { if ($lower.EndsWith($ext)) { return $ext } }
    return $null
}

# True if a CSV entry's first path segment names an archive
# (e.g. "build.zip\meta.json"). Used by verify to skip archive internals.
function Test-IsArchiveInternalEntry {
    # Returns $true if the path represents a file inside an archive,
    # e.g. "subfolder\archive.zip\internal\file.txt".
    # Walks every path segment so archives in subdirectories are handled
    # correctly, not just archives at the scan root.
    param([string] $RelativePath)
    $segments = $RelativePath -split '[/\\]'
    # Need at least one segment after the archive for it to be internal.
    for ($i = 0; $i -lt $segments.Count - 1; $i++) {
        if (Get-ArchiveExtension $segments[$i]) { return $true }
    }
    return $false
}

function New-FolderPicker {
    # Builds the folder browser, using the modern shell dialog wherever the host
    # runtime provides it.
    #
    # PowerShell 7 (.NET Core and later) has AutoUpgradeEnabled, so the dialog is
    # the Vista-style IFileOpenDialog, which understands Libraries, OneDrive and
    # typed paths. Windows PowerShell 5.1 (.NET Framework) has no such property
    # and always gets the legacy SHBrowseForFolder tree, so both are handled by
    # feature-detecting each property rather than assuming a host.
    param(
        [string] $Description,
        [string] $InitialPath
    )
    $dlg   = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Description
    $props = $dlg.PSObject.Properties.Name

    if ($props -contains 'AutoUpgradeEnabled') { $dlg.AutoUpgradeEnabled = $true }
    # The Vista dialog has no description label, so without this the prompt text
    # is simply never shown. Setting it puts the prompt in the title bar.
    if ($props -contains 'UseDescriptionForTitle') { $dlg.UseDescriptionForTitle = $true }

    # RootFolder is deliberately NOT set. It used to be 'MyComputer', which roots
    # the legacy tree at This PC -- and Desktop, Documents and the other
    # Libraries sit ABOVE This PC in the shell namespace, so rooting there put
    # them out of reach entirely. The default (Desktop) shows the whole namespace.
    if ($InitialPath -and (Test-Path -LiteralPath $InitialPath)) {
        if ($props -contains 'InitialDirectory') { $dlg.InitialDirectory = $InitialPath }
        $dlg.SelectedPath = $InitialPath
    }
    return $dlg
}

function Resolve-BasePath {
    param([string] $PromptDescription)
    if ($BasePath) {
        if (Test-Path -LiteralPath $BasePath -PathType Container) {
            return (Resolve-Path -LiteralPath $BasePath).Path
        }
        [System.Windows.Forms.MessageBox]::Show(
            "The -BasePath '$BasePath' is not a valid folder. Please pick one.",
            'Invalid -BasePath', 'OK', 'Warning') | Out-Null
    }
    # Named $scriptDir, not $script -- the latter reads like the $script: scope
    # modifier and is easy to misread.
    $scriptDir = Get-ParentScriptFolder

    while ($true) {
        $dlg = New-FolderPicker -Description $PromptDescription -InitialPath $scriptDir
        try {
            if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
            $picked = $dlg.SelectedPath
        } finally { $dlg.Dispose() }

        if (-not [string]::IsNullOrWhiteSpace($picked) -and
            (Test-Path -LiteralPath $picked -PathType Container)) {
            return (Resolve-Path -LiteralPath $picked).Path
        }

        # A Library (Documents, Desktop, Pictures) or another virtual shell
        # folder is not a path on disk, and the legacy dialog hands back an
        # empty or "::{GUID}" SelectedPath when one is chosen. That used to be
        # returned as-is and the caller reported "No folder selected", which
        # reads like the user cancelled rather than like the choice was
        # unusable. Say what actually happened and offer another go.
        $shown = if ([string]::IsNullOrWhiteSpace($picked)) { '(nothing usable)' } else { $picked }
        $again = [System.Windows.Forms.MessageBox]::Show(
            ("That selection is not a folder on disk:`r`n$shown`r`n`r`n" +
             "Libraries such as Documents, Desktop and Pictures are virtual " +
             "shell folders that can span several real locations, so they " +
             "cannot be scanned directly. Pick the actual folder instead, for " +
             "example:`r`n$([Environment]::GetFolderPath('MyDocuments'))" +
             "`r`n`r`nChoose a different folder?"),
            'Not a Folder On Disk',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($again -ne [System.Windows.Forms.DialogResult]::Yes) { return $null }
    }
}

# Best-effort: is the current PowerShell session running elevated?
function Test-IsAdmin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# =====================================================================
#  WinForms helpers
# =====================================================================

function New-FormControl {
    param(
        [Parameter(Mandatory)][string] $Type,
        [hashtable] $Props = @{}
    )
    $ctrl = New-Object ("System.Windows.Forms.$Type")
    foreach ($k in $Props.Keys) { $ctrl.$k = $Props[$k] }
    return $ctrl
}

function New-Pt { param([int]$X,[int]$Y) New-Object System.Drawing.Point($X,$Y) }
function New-Sz { param([int]$W,[int]$H) New-Object System.Drawing.Size($W,$H) }

# Minimum gap between progress repaints, in milliseconds (~12 a second).
#
# Hoisted out of Update-ProgressUI because callers need it too. PowerShell
# evaluates arguments before the call, so a caller that builds an expensive
# -Text string inline pays for it on every pass no matter how hard the function
# throttles the repaint afterwards. The parallel pool checks this itself before
# formatting its worker panel -- see Invoke-ParallelHash.
$script:ProgressRepaintMs = 80

# Height of one worker row in the panel, in pixels, at Consolas 9pt.
$script:PanelRowHeight = 15

function Get-PanelRowCapacity {
    # How many worker rows will fit on this screen.
    #
    # This used to be a flat 12, which meant a -Parallel 16 run showed twelve
    # workers and "... and 4 more" on a display with room for fifty. The limit
    # exists to stop a window growing taller than the screen, so it should be
    # derived from the screen rather than guessed -- at ordinary worker counts
    # nothing is hidden at all now.
    param([Parameter(Mandatory)][int] $Requested)
    # Title bar, header line, blank line, the gap, the progress bar, margins.
    $chrome    = 150
    $available = 900
    try {
        $working = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height
        # Leave a margin so a centred window is never flush against the edges.
        if ($working -gt 0) { $available = $working - 80 }
    } catch { Write-Debug "Could not read the screen working area: $_" }
    $fits = [int](($available - $chrome) / $script:PanelRowHeight)
    # Even on an implausibly short display, show something.
    if ($fits -lt 4) { $fits = 4 }
    return [Math]::Min($Requested, $fits)
}

function New-ProgressUI {
    # $Rows greater than 0 asks for the taller window the parallel pool uses to
    # show a line per worker. Left at 0 -- which is every other caller -- the
    # form is exactly the one this script has always shown.
    param([string] $Title, [int] $Max, [int] $Rows = 0)

    $font = $null
    if ($Rows -gt 0) {
        # Header, blank line, one line per worker, and the "... and N more"
        # line. Get-WorkerPanelText caps the worker lines at the same 12, so a
        # -Parallel 32 run cannot produce a window taller than the screen.
        $shown  = Get-PanelRowCapacity -Requested $Rows
        $labelH = $script:PanelRowHeight * ($shown + 3)
        # Wide enough for the elided path plus the expanding-entry counter
        # without either being clipped.
        $formW  = 820
        $labelW = $formW - 40
        $form = New-FormControl Form @{
            Text = $Title; Size = (New-Sz $formW ($labelH + 110)); StartPosition = 'CenterScreen'
        }
        $bar = New-FormControl ProgressBar @{
            Location = (New-Pt 10 ($labelH + 30)); Size = (New-Sz $labelW 20)
            Minimum = 0; Maximum = [Math]::Max(1, $Max); Value = 0
        }
        # The panel is columnar, and proportional type turns it into a mess.
        # Consolas ships with every supported Windows; if it has been removed,
        # GDI+ substitutes silently and reports the substitute in .Name, so
        # check and fall back to the family that is guaranteed to exist.
        $font = New-Object System.Drawing.Font('Consolas', 9)
        if ($font.Name -ne 'Consolas') {
            $font.Dispose()
            $font = New-Object System.Drawing.Font([System.Drawing.FontFamily]::GenericMonospace, 9)
        }
        $label = New-FormControl Label @{
            Location = (New-Pt 10 15); Size = (New-Sz $labelW $labelH); Font = $font
        }
    } else {
        $shown = 0
        $form = New-FormControl Form @{
            Text = $Title; Size = (New-Sz 500 200); StartPosition = 'CenterScreen'
        }
        $bar = New-FormControl ProgressBar @{
            Location = (New-Pt 10 125); Size = (New-Sz 460 20)
            Minimum = 0; Maximum = [Math]::Max(1, $Max); Value = 0
        }
        $label = New-FormControl Label @{
            Location = (New-Pt 10 20); Size = (New-Sz 460 90)
        }
    }
    $form.Controls.Add($bar)
    $form.Controls.Add($label)
    $form.Show(); $form.Refresh()
    return [pscustomobject]@{
        Form  = $form
        Bar   = $bar
        Label = $label
        Font  = $font
        # The number of worker rows this window was actually sized for. The
        # panel is formatted to the same number, so the two cannot disagree --
        # which they did while both of them hardcoded their own 12.
        Rows  = $shown
        Clock = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

function Update-ProgressUI {
    # Repainting on every file is a synchronous GDI round-trip and dominates
    # the loop on large trees. Repaint at most ~12x/sec; -Force for milestones
    # that must be visible immediately (e.g. "Expanding archive").
    param(
        [Parameter(Mandatory)][pscustomobject] $Ui,
        [int]    $Value,
        [string] $Text,
        [switch] $Force
    )
    if (-not $Force -and $Ui.Clock.ElapsedMilliseconds -lt $script:ProgressRepaintMs) { return }
    $Ui.Clock.Restart()
    if ($PSBoundParameters.ContainsKey('Value')) {
        $Ui.Bar.Value = [Math]::Min([Math]::Max($Value, $Ui.Bar.Minimum), $Ui.Bar.Maximum)
    }
    if ($PSBoundParameters.ContainsKey('Text')) { $Ui.Label.Text = $Text }
    $Ui.Form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

function Close-ProgressUI {
    # Dispose, not just Close -- these forms leak GDI handles across runs.
    param([pscustomobject] $Ui)
    if (-not $Ui) { return }
    try { $Ui.Form.Close(); $Ui.Form.Dispose() } catch { Write-Debug "Progress UI dispose failed: $_" }
    # A control does not own the font assigned to it, so disposing the form
    # alone leaves this handle behind -- and leaked GDI handles are exactly what
    # the note above is about.
    if ($Ui.Font) {
        try { $Ui.Font.Dispose() } catch { Write-Debug "Progress UI font dispose failed: $_" }
    }
}

function Invoke-ProgressLoop {
    param(
        [array]    $Items,
        [string]   $Title,
        [scriptblock] $Body,
        [scriptblock] $StatusText = { param($i) "Processing $i of $($Items.Count)" }
    )
    $ui = New-ProgressUI -Title $Title -Max $Items.Count
    try {
        $i = 0
        foreach ($item in $Items) {
            $i++
            & $Body $item $ui
            # -Force on the final item so the bar visibly completes.
            Update-ProgressUI -Ui $ui -Value $i -Text (& $StatusText $i $item) `
                -Force:($i -eq $Items.Count)
        }
    } finally {
        Close-ProgressUI $ui
    }
}

function Show-MessageBox ($message) {
    [System.Windows.Forms.MessageBox]::Show($message, 'Help', 'OK', 'Information') | Out-Null
}

# =====================================================================
#  AutoPlay suppression (per-user, no admin required)
#
#  Toggling NoDriveTypeAutoRun under HKCU\...\Policies\Explorer disables
#  AutoPlay for the current user only, so we don't need elevation. We
#  save the previous value (if any) and restore it in a finally.
# =====================================================================

$script:AutoPlayKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
$script:AutoPlayName = 'NoDriveTypeAutoRun'

function Push-AutoPlaySuppression {
    # Every registry call here MUST use -ErrorAction Stop.
    #
    # Without it these are NON-TERMINATING errors: they do not trigger the catch,
    # so the failure is never handled and the raw ErrorRecords go straight to the
    # error stream. On any machine where HKCU\...\CurrentVersion\Policies is
    # ACL-locked (Group Policy managed desktops, which is common) that prints two
    # red errors for every single ISO, even though the mount, read, and dismount
    # all succeed afterwards.
    #
    # Suppressing AutoPlay is a convenience only -- it stops Explorer popping
    # open -- so failure is logged to the debug stream and the scan continues.
    # 'Applied' records whether we actually changed anything, so Pop does not
    # try to undo a change that was never made.
    $state = [pscustomobject]@{ Existed = $false; OriginalValue = $null; Applied = $false }
    try {
        if (-not (Test-Path -LiteralPath $script:AutoPlayKey)) {
            New-Item -Path $script:AutoPlayKey -Force -ErrorAction Stop | Out-Null
        }
        $existing = Get-ItemProperty -LiteralPath $script:AutoPlayKey `
                        -Name $script:AutoPlayName -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            $state.Existed       = $true
            $state.OriginalValue = $existing.($script:AutoPlayName)
        }
        # 0xFF = disable AutoPlay for all drive types.
        Set-ItemProperty -LiteralPath $script:AutoPlayKey `
            -Name $script:AutoPlayName -Value 0xFF -Type DWord -Force -ErrorAction Stop
        $state.Applied = $true
        Write-Debug "AutoPlay suppressed (HKCU). Existed=$($state.Existed) Orig=$($state.OriginalValue)"
    } catch {
        Write-Debug ("Could not suppress AutoPlay (cosmetic only; Explorer may open " +
                     "the mounted ISO): $($_.Exception.Message)")
    }
    return $state
}

function Pop-AutoPlaySuppression {
    param([pscustomobject] $State)
    # Nothing was changed, so there is nothing to restore -- attempting it would
    # produce exactly the same error leak the Push fix above removes.
    if (-not $State -or -not $State.Applied) { return }
    try {
        if ($State.Existed) {
            Set-ItemProperty -LiteralPath $script:AutoPlayKey `
                -Name $script:AutoPlayName -Value $State.OriginalValue -Type DWord -Force `
                -ErrorAction Stop
            Write-Debug "AutoPlay restored to original value $($State.OriginalValue)."
        } else {
            Remove-ItemProperty -LiteralPath $script:AutoPlayKey `
                -Name $script:AutoPlayName -ErrorAction SilentlyContinue
            Write-Debug "AutoPlay key value removed (was absent before)."
        }
    } catch {
        Write-Warning "Could not restore the AutoPlay setting: $($_.Exception.Message)"
    }
}

# =====================================================================
#  Archive enumeration
#
#  Each function returns an array of [pscustomobject]@{ FilePath; Hash }
#  for the internal entries (NOT the archive itself; caller hashes that).
#  An empty array is returned on failure; warnings are also added to
#  $script:ArchiveWarnings so they appear in the manifest log.
# =====================================================================

function Add-ArchiveWarning {
    param([string] $Message)
    # In a worker the message has to reach the parent as a W record instead, so
    # it is queued here and drained by Invoke-HashWorker once the current item
    # is finished. Write-Warning is skipped deliberately: a worker's stderr is
    # only read after it exits, so anything written there just sits in a pipe.
    if ($script:IsWorker) {
        [void]$script:WorkerWarnings.Add($Message)
        return
    }
    Write-Warning $Message
    [void]$script:ArchiveWarnings.Add($Message)
}

function Get-ZipContentHash {
    param([string] $ArchivePath, [string] $ArchiveRelativePath)
    $results = New-Object System.Collections.Generic.List[object]
    $sha = [System.Security.Cryptography.SHA512]::Create()
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
        try {
            foreach ($entry in $zip.Entries) {
                # Skip directory entries (zero-length, name ends with /).
                if ($entry.Length -eq 0 -and $entry.FullName.EndsWith('/')) { continue }
                try {
                    $s = $entry.Open()
                    try { $bytes = $sha.ComputeHash($s) } finally { $s.Dispose() }
                    $results.Add([pscustomobject]@{
                        FilePath = Join-Path $ArchiveRelativePath ($entry.FullName -replace '/', '\')
                        Hash     = ([BitConverter]::ToString($bytes)).Replace('-', '')
                    })
                } catch {
                    Add-ArchiveWarning "Zip entry '$($entry.FullName)' in '$ArchivePath' could not be hashed: $_"
                }
            }
        } finally { $zip.Dispose() }
    } catch {
        Add-ArchiveWarning "Failed to open zip '$ArchivePath': $_"
    } finally {
        $sha.Dispose()
    }
    Write-Debug "Zip '$ArchivePath' produced $($results.Count) entries."
    return $results.ToArray()
}

function Get-TarContentHash {
    param([string] $ArchivePath, [string] $ArchiveRelativePath)
    $results = New-Object System.Collections.Generic.List[object]
    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        Add-ArchiveWarning "'tar' not available; skipped enumerating '$ArchivePath'."
        return $results.ToArray()
    }
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("fcv52_" + [IO.Path]::GetRandomFileName())
    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        # Keep stderr: discarding it left "tar exited with code 1" with no
        # indication of why. 2>&1 plus a redirect keeps it out of the pipeline.
        $global:LASTEXITCODE = 0
        $tarErr = (& tar -xf $ArchivePath -C $tempRoot 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            $detail = if ($tarErr) { ": $tarErr" } else { '.' }
            Add-ArchiveWarning "tar exited with code $LASTEXITCODE for '$ArchivePath'$detail"
            return $results.ToArray()
        }
        foreach ($f in Get-ChildItem $tempRoot -File -Recurse -Force -ErrorAction SilentlyContinue) {
            $internal = $f.FullName.Substring($tempRoot.Length).TrimStart('\','/')
            try {
                $results.Add([pscustomobject]@{
                    FilePath = Join-Path $ArchiveRelativePath $internal
                    Hash     = Get-FileSha512 -Path $f.FullName
                })
            } catch {
                Add-ArchiveWarning "Tar entry '$internal' in '$ArchivePath' could not be hashed: $_"
            }
        }
    } catch {
        Add-ArchiveWarning "Failed to enumerate tar '$ArchivePath': $_"
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Debug "Tar '$ArchivePath' produced $($results.Count) entries."
    return $results.ToArray()
}

function Get-IsoContentHash {
    param([string] $ArchivePath, [string] $ArchiveRelativePath)
    $results = New-Object System.Collections.Generic.List[object]
    if (-not (Get-Command Mount-DiskImage -ErrorAction SilentlyContinue)) {
        Add-ArchiveWarning "Mount-DiskImage not available; skipped ISO '$ArchivePath'."
        return $results.ToArray()
    }
    # Do NOT raise an archive warning here just because the session is not
    # elevated. Mounting an ISO does not require elevation on client SKUs, so a
    # pre-emptive warning fires for every ISO on a normal desktop -- polluting
    # the console and the manifest, and triggering an "Archive warnings: 1"
    # popup -- while the mount, read, and dismount all succeed. The elevation
    # state is only worth reporting if the mount actually fails, where it is a
    # real diagnostic.
    $isAdmin = Test-IsAdmin
    Write-Debug "ISO '$ArchivePath': elevated=$isAdmin"

    $autoPlayState = Push-AutoPlaySuppression
    $mounted = $false
    try {
        $image = Mount-DiskImage -ImagePath $ArchivePath -PassThru -ErrorAction Stop
        $mounted = $true
        # Give the volume a moment to settle and get a drive letter.
        $vol = $null
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Milliseconds 250
            $vol = $image | Get-Volume -ErrorAction SilentlyContinue
            # Re-querying by path is more reliable than the -PassThru object on
            # some storage stacks, so fall back to it before giving up.
            if (-not $vol -or -not $vol.DriveLetter) {
                $vol = Get-DiskImage -ImagePath $ArchivePath -ErrorAction SilentlyContinue |
                           Get-Volume -ErrorAction SilentlyContinue
            }
            if ($vol -and $vol.DriveLetter) { break }
        }
        if (-not $vol -or -not $vol.DriveLetter) {
            Add-ArchiveWarning "Mounted ISO '$ArchivePath' but no drive letter was assigned."
            return $results.ToArray()
        }
        $root = "$($vol.DriveLetter):\"
        Write-Debug "ISO mounted at $root"

        foreach ($f in Get-ChildItem $root -File -Recurse -Force -ErrorAction SilentlyContinue) {
            $internal = $f.FullName.Substring($root.Length).TrimStart('\','/')
            try {
                $results.Add([pscustomobject]@{
                    FilePath = Join-Path $ArchiveRelativePath $internal
                    Hash     = Get-FileSha512 -Path $f.FullName
                })
            } catch {
                Add-ArchiveWarning "ISO entry '$internal' in '$ArchivePath' could not be hashed: $_"
            }
        }
    } catch {
        $msg = "Failed to enumerate ISO '$ArchivePath': $_"
        if (-not $isAdmin) {
            $msg += " (session is not elevated; some SKUs and policies require " +
                    "elevation to mount disk images)"
        }
        Add-ArchiveWarning $msg
    } finally {
        if ($mounted) {
            try { Dismount-DiskImage -ImagePath $ArchivePath -ErrorAction SilentlyContinue | Out-Null } catch { Write-Debug "Dismount-DiskImage failed (non-fatal): $_" }
        }
        Pop-AutoPlaySuppression -State $autoPlayState
    }
    Write-Debug "ISO '$ArchivePath' produced $($results.Count) entries."
    return $results.ToArray()
}

function Get-ArchiveContentHash {
    param([string] $ArchivePath, [string] $ArchiveRelativePath, [string] $Extension)
    switch ($Extension) {
        '.zip'    { return (Get-ZipContentHash  -ArchivePath $ArchivePath -ArchiveRelativePath $ArchiveRelativePath) }
        '.tar'    { return (Get-TarContentHash  -ArchivePath $ArchivePath -ArchiveRelativePath $ArchiveRelativePath) }
        '.tar.gz' { return (Get-TarContentHash  -ArchivePath $ArchivePath -ArchiveRelativePath $ArchiveRelativePath) }
        '.tgz'    { return (Get-TarContentHash  -ArchivePath $ArchivePath -ArchiveRelativePath $ArchiveRelativePath) }
        '.iso'    { return (Get-IsoContentHash  -ArchivePath $ArchivePath -ArchiveRelativePath $ArchiveRelativePath) }
        default   { return @() }
    }
}

# =====================================================================
#  Parallel hashing: the wire protocol
#
#  This process is the parent. It starts child PowerShell processes
#  running this same file with -HashWorker, feeds each of them work
#  items on stdin, and reads results back on stdout. One record per
#  line, fields separated by tabs.
#
#  Parent -> worker, one line per work item:
#
#      <index> <TAB> <algorithm> <TAB> <expand 0|1> <TAB> <b64 rel> <TAB> <b64 full>
#
#  Worker -> parent, one or more lines per item, always ending in E:
#
#      H <TAB> <index> <TAB> <hash> <TAB> <b64 rel>    the file's own hash
#      A <TAB> <index> <TAB> <hash> <TAB> <b64 rel>    an archive-internal entry
#      M <TAB> <index>                                 the file was not there
#      W <TAB> <index> <TAB> <b64 message>             archive warning
#      F <TAB> <index> <TAB> <b64 message>             the item could not be hashed
#      E <TAB> <index>                                 end of item
#
#  W and F are kept apart on purpose. W is what Add-ArchiveWarning
#  produces, so the parent both warns and files it into the manifest's
#  archive-warning section; F is a failed hash, which the sequential
#  loop only ever warned about. Folding them together would inflate the
#  manifest's "Archive warnings" count for a reason that has nothing to
#  do with archives.
#
#  Both path fields are Base64 of UTF-8. A Windows filename may legally
#  contain a tab or a newline, either of which would break the line
#  framing, and encoding them also removes every console code page
#  question in one go.
# =====================================================================

# The protocol is line-oriented on "`n" alone. The parent tolerates a trailing
# "`r" when splitting, so a host that insists on CRLF cannot corrupt a record.
$script:WorkerEol     = "`n"
$script:WorkerEolChar = [char]10

function ConvertTo-WireText {
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function ConvertFrom-WireText {
    param([string] $Encoded)
    if ([string]::IsNullOrEmpty($Encoded)) { return '' }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Encoded))
}

function Get-FileHashByAlgorithm {
    # SHA-512 goes through this script's own reusable provider, which is the
    # whole reason Get-FileSha512 exists. Any other algorithm only turns up when
    # an older listing was built with one, which is rare enough that Get-FileHash
    # per call costs nothing worth avoiding.
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Algorithm
    )
    if ($Algorithm -eq 'SHA512') { return (Get-FileSha512 -Path $Path) }
    return (Get-FileHash -Path $Path -Algorithm $Algorithm -ErrorAction Stop).Hash
}

function Invoke-HashWorker {
    # Runs in a child process, started by Start-HashWorkerPool. Reads work items
    # until stdin reaches EOF, which is how the parent says there is no more
    # work -- see Stop-HashWorkerPool.
    #
    # The streams are opened by hand rather than through [Console]::In and Out
    # so both ends are UTF-8 whatever the console code page happens to be. On
    # .NET Framework, assigning [Console]::InputEncoding while stdin is
    # redirected can throw, so it is never touched.
    $stdin  = [IO.StreamReader]::new([Console]::OpenStandardInput(),  [Text.UTF8Encoding]::new($false))
    $stdout = [IO.StreamWriter]::new([Console]::OpenStandardOutput(), [Text.UTF8Encoding]::new($false))
    $stdout.AutoFlush = $true
    $stdout.NewLine   = $script:WorkerEol
    try {
        while ($null -ne ($line = $stdin.ReadLine())) {
            if ($line.Trim() -eq '') { continue }
            $f = $line -split "`t"
            if ($f.Count -lt 5) { continue }
            $index     = $f[0]
            $algorithm = $f[1]
            $expand    = ($f[2] -eq '1')
            $rel       = ConvertFrom-WireText $f[3]
            $full      = ConvertFrom-WireText $f[4]

            $script:WorkerWarnings.Clear()
            try {
                if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                    $stdout.WriteLine("M`t$index")
                } else {
                    $hash = Get-FileHashByAlgorithm -Path $full -Algorithm $algorithm
                    $stdout.WriteLine("H`t$index`t$hash`t$(ConvertTo-WireText $rel)")
                    if ($expand) {
                        $ext = Get-ArchiveExtension $full
                        # An ISO is never sent to a worker -- Invoke-ParallelFileScan
                        # keeps them in the parent -- but guard it here too, so a
                        # future caller cannot start racing disc mounts, drive
                        # letters, and AutoPlay registry writes across processes.
                        if ($ext -and $ext -ne '.iso') {
                            foreach ($e in @(Get-ArchiveContentHash -ArchivePath $full `
                                                -ArchiveRelativePath $rel -Extension $ext)) {
                                if ($null -eq $e) { continue }
                                $stdout.WriteLine("A`t$index`t$($e.Hash)`t$(ConvertTo-WireText $e.FilePath)")
                            }
                        }
                    }
                }
            } catch {
                # One unreadable file must not take the worker down with it: the
                # parent would lose every other item still outstanding on it and
                # have to redo the whole scan sequentially.
                $msg = "Could not hash '$full': $($_.Exception.Message)"
                $stdout.WriteLine("F`t$index`t$(ConvertTo-WireText $msg)")
            }
            foreach ($warning in $script:WorkerWarnings) {
                $stdout.WriteLine("W`t$index`t$(ConvertTo-WireText $warning)")
            }
            # E last, always. It is the only record that tells the parent this
            # item is finished and the worker has room for another.
            $stdout.WriteLine("E`t$index")
        }
    } finally {
        try { $stdout.Flush() } catch { Write-Debug "Worker stdout flush failed: $_" }
    }
}

# =====================================================================
#  Parallel hashing: the worker pool
# =====================================================================

# Work items in flight per worker. Two separate things depend on this number.
#
# Deadlock: the parent must never sit blocked writing to a worker's stdin while
# that same worker sits blocked writing to its stdout. The feed loop drains
# every worker's stdout before feeding any of them, and eight request lines are
# far below the 4 KB pipe buffer, so a write cannot block long enough to matter.
#
# Balance: a small window is what makes the pool level itself. A worker that
# happens to draw eight large files asks for its next item later than one that
# drew eight small files. Nothing is partitioned up front, which is the failure
# mode of splitting the file list into N fixed chunks.
$script:WorkerWindow = 8

# An item taking at least this long is worth a line in the debug log. The panel
# shows what a worker is on right now, but that is gone the moment the item
# finishes, so a run that felt slow leaves no record of which files caused it.
# Only consulted under -DebugMode.
$script:SlowItemSeconds = 5

# Set while a pool is alive, so the tail of the script can guarantee teardown.
$script:ActiveWorkerPool = $null

function Get-PowerShellHostPath {
    # A worker has to be the same host that is running now: a 5.1 parent must
    # not spawn pwsh workers, or vice versa, since the two do not agree on every
    # default and the protocol assumes both ends behave identically.
    try {
        $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exe -and (Test-Path -LiteralPath $exe)) { return $exe }
    } catch { Write-Debug "MainModule lookup failed: $_" }
    if ($PSHOME) {
        foreach ($name in @('pwsh.exe', 'powershell.exe')) {
            $candidate = Join-Path $PSHOME $name
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    return $null
}

function Stop-HashWorkerPool {
    # Closing stdin is the shutdown signal: the worker's ReadLine returns $null,
    # its loop ends, and it exits on its own. The kill is only for one that has
    # wedged -- an orphaned powershell.exe per run would pile up quickly.
    param([object[]] $Workers)
    if (-not $Workers) { $script:ActiveWorkerPool = $null; return }
    # Signal all of them first, then collect. Doing both per worker would make
    # each worker wait out the shutdown of every worker before it.
    foreach ($w in $Workers) {
        if (-not $w -or -not $w.StdIn) { continue }
        try { $w.StdIn.Close() } catch { Write-Debug "Worker stdin close failed: $_" }
    }
    foreach ($w in $Workers) {
        if (-not $w -or -not $w.Proc) { continue }
        try {
            if (-not $w.Proc.WaitForExit(3000)) {
                Write-Debug "Worker $($w.Proc.Id) did not exit on its own; killing it."
                $w.Proc.Kill()
                [void]$w.Proc.WaitForExit(2000)
            }
            # stderr is read only now, once the worker has gone. A worker writes
            # nothing there in normal operation, so anything present is a real
            # failure and worth surfacing.
            $stderr = $w.Proc.StandardError.ReadToEnd()
            if ($stderr -and $stderr.Trim()) {
                Write-Warning "Hashing worker reported: $($stderr.Trim())"
            }
        } catch { Write-Debug "Worker teardown failed: $_" }
        try { $w.Proc.Dispose() } catch { Write-Debug "Worker dispose failed: $_" }
    }
    $script:ActiveWorkerPool = $null
}

function Start-HashWorkerPool {
    # Returns an array of worker records, or $null if no pool could be started.
    # Callers read $null as "hash sequentially instead" -- it is a fallback, not
    # an error, because execution policy, AppLocker, Constrained Language Mode
    # and AV hooks all fail here, and all of them are ordinary on the kind of
    # locked-down desktop this script gets run on.
    param([Parameter(Mandatory)][int] $Count)

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.PSCommandPath }
    $hostExe = Get-PowerShellHostPath
    if (-not $scriptPath -or -not $hostExe) {
        Write-Warning "Cannot locate this script or the PowerShell host; hashing sequentially."
        return $null
    }

    $workers = New-Object System.Collections.Generic.List[object]
    try {
        for ($i = 0; $i -lt $Count; $i++) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $hostExe
            # -NoProfile so a slow or noisy profile cannot corrupt the protocol
            # by printing to stdout, -NonInteractive so nothing can prompt on a
            # stdin that no human is attached to, and -ExecutionPolicy Bypass
            # because the parent is already running: the policy was satisfied
            # once, and re-checking it per worker only adds a way for the pool
            # to fail on a machine where the script itself works.
            $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -HashWorker' -f $scriptPath
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true
            $psi.RedirectStandardInput  = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
            $psi.WorkingDirectory       = (Split-Path -Path $scriptPath -Parent)

            $proc = [Diagnostics.Process]::Start($psi)
            if (-not $proc) { throw 'Process.Start returned nothing.' }

            # .NET Framework has no ProcessStartInfo.StandardInputEncoding -- it
            # is .NET Core only -- so the writer is built by hand to pin UTF-8
            # on the way out as well as on the way back.
            $stdin = [IO.StreamWriter]::new($proc.StandardInput.BaseStream, [Text.UTF8Encoding]::new($false))
            $stdin.AutoFlush = $true
            $stdin.NewLine   = $script:WorkerEol

            [void]$workers.Add([pscustomobject]@{
                Proc        = $proc
                StdIn       = $stdin
                Buffer      = [byte[]]::new(8192)
                Pending     = $null
                # One decoder per worker, kept across reads: a read can land in
                # the middle of a multi-byte character, and the decoder carries
                # the partial sequence over to the next one.
                Decoder     = [Text.UTF8Encoding]::new($false).GetDecoder()
                Partial     = New-Object System.Text.StringBuilder
                Outstanding = 0
                Dead        = $false
                # Items fed to this worker that it has not acknowledged with an
                # E record yet. A worker reads its stdin strictly in order --
                # one line, hash, E, next line -- so the head of this queue is
                # the file it is working on at this moment. Not an estimate:
                # the actual item.
                InFlight    = New-Object System.Collections.Generic.Queue[object]
                # Restarted whenever the head changes, so it reads as time spent
                # on the current file rather than time since the pool started.
                Clock       = [System.Diagnostics.Stopwatch]::StartNew()
            })
        }
    } catch {
        Write-Warning ("Could not start the hashing workers ($($_.Exception.Message)); " +
                       "hashing sequentially in this process instead.")
        Stop-HashWorkerPool -Workers $workers.ToArray()
        return $null
    }
    $script:ActiveWorkerPool = $workers.ToArray()
    Write-Debug "Started $($workers.Count) hashing worker(s): $hostExe"
    return $script:ActiveWorkerPool
}

function Read-WorkerRecord {
    # Files one result line into $Results. Returns $true only for an E record,
    # which is the single record that means an item is finished.
    param(
        [Parameter(Mandatory)][string] $Line,
        [Parameter(Mandatory)][hashtable] $Results
    )
    $f = $Line -split "`t"
    if ($f.Count -lt 2) { Write-Debug "Malformed worker record ignored: $Line"; return $false }
    $index = 0
    if (-not [int]::TryParse($f[1], [ref]$index)) {
        Write-Debug "Worker record with a non-numeric index ignored: $Line"
        return $false
    }
    $slot = $Results[$index]
    if (-not $slot) { Write-Debug "Worker record for unknown index $index discarded."; return $false }
    switch ($f[0]) {
        'H' { [void]$slot.Files.Add(   [pscustomobject]@{ FilePath = (ConvertFrom-WireText $f[3]); Hash = $f[2] }) }
        'A' { [void]$slot.Archives.Add([pscustomobject]@{ FilePath = (ConvertFrom-WireText $f[3]); Hash = $f[2] }) }
        'M' { $slot.Missing = $true }
        'W' { [void]$slot.Warnings.Add((ConvertFrom-WireText $f[2])) }
        'F' { [void]$slot.Failures.Add((ConvertFrom-WireText $f[2])) }
        'E' { return $true }
        default { Write-Debug "Unknown worker record kind '$($f[0])' ignored." }
    }
    return $false
}

# =====================================================================
#  Parallel hashing: the live worker panel
#
#  The parent already knows what every worker is doing -- it chose the
#  work and handed it over -- it just used to throw the item away after
#  counting it. Each worker record now keeps the items it has been fed
#  but not yet acknowledged, and because a worker reads its stdin
#  strictly in order, the head of that queue is the file it is hashing
#  right now.
#
#  That turns the one question the old two-line window could not answer
#  -- "is this hung, or is it three minutes into a 40 GB file?" -- into
#  something you can read off the screen.
# =====================================================================

function Format-ByteSize {
    # Narrow, glanceable size for the panel's fixed-width column. $null means
    # the size is not known, which is the case on the verification path: those
    # work items come from CSV rows, and statting every row in the parent just
    # to fill a display column would be real work on a large listing.
    param($Bytes)
    if ($null -eq $Bytes) { return '-' }
    if ($Bytes -lt 1KB)   { return "$Bytes B" }
    # Reassigning $Bytes itself would coerce the division back to whole bytes.
    $value = [double]$Bytes
    foreach ($unit in @('KB', 'MB', 'GB', 'TB')) {
        $value = $value / 1KB
        if ($value -lt 1KB -or $unit -eq 'TB') { return ('{0:N1} {1}' -f $value, $unit) }
    }
}

function Format-Elapsed {
    param([TimeSpan] $Span)
    if ($Span.TotalHours -ge 1) {
        return ('{0}:{1:00}:{2:00}' -f [int]$Span.TotalHours, $Span.Minutes, $Span.Seconds)
    }
    return ('{0}:{1:00}' -f [int]$Span.TotalMinutes, $Span.Seconds)
}

function Format-Duration {
    # Run time for the manifest, the verification log, and the closing dialogs.
    # Separate from Format-Elapsed, which is the panel's clock column and has to
    # stay inside a fixed width; this one is read as prose and says its units.
    param($Span)
    if ($null -eq $Span) { return 'n/a' }
    $t = [TimeSpan]$Span
    # Sub-second in milliseconds: enumeration of a small tree is genuinely a few
    # tens of milliseconds, and rounding that to "0.0s" reads like a broken clock.
    if ($t.TotalSeconds -lt 1)  { return ('{0:N0} ms' -f $t.TotalMilliseconds) }
    if ($t.TotalMinutes -lt 1) { return ('{0:N1}s' -f $t.TotalSeconds) }
    if ($t.TotalHours   -lt 1) { return ('{0}m {1:00}s' -f [int]$t.TotalMinutes, $t.Seconds) }
    return ('{0}h {1:00}m {2:00}s' -f [int]$t.TotalHours, $t.Minutes, $t.Seconds)
}

function Format-PanelPath {
    # Trimmed from the LEFT, so the filename -- the part that identifies the
    # file -- is the part that always survives.
    param([string] $Path, [int] $Width = 52)
    if ($null -eq $Path)          { return '' }
    if ($Path.Length -le $Width)  { return $Path }
    return '...' + $Path.Substring($Path.Length - ($Width - 3))
}

function Get-WorkerPanelText {
    # Builds the whole panel in one string. Only ever called behind the repaint
    # throttle -- see the note in Invoke-ParallelHash.
    param(
        [Parameter(Mandatory)][object[]] $Workers,
        [Parameter(Mandatory)][hashtable] $Results,
        [int] $Completed,
        [int] $Total,
        # Passed the row count the window was sized for. The default is only a
        # floor for a caller that does not know it.
        [int] $MaxRows = 12
    )
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add(('Processed {0:N0} of {1:N0}          {2} workers' -f $Completed, $Total, $Workers.Count))
    [void]$lines.Add('')

    $shown = [Math]::Min($Workers.Count, $MaxRows)
    for ($i = 0; $i -lt $shown; $i++) {
        $w = $Workers[$i]
        if ($w.Dead) {
            [void]$lines.Add(('{0,3}  {1,7}  {2,10}  {3}' -f ($i + 1), '-', '-', 'stopped'))
            continue
        }
        if ($w.InFlight.Count -eq 0) {
            [void]$lines.Add(('{0,3}  {1,7}  {2,10}  {3}' -f ($i + 1), '-', '-', 'idle'))
            continue
        }
        $head = $w.InFlight.Peek()
        # The archive's own H record has arrived but its E has not, so the worker
        # is inside Get-ArchiveContentHash now. That is the slowest thing a
        # worker does and the likeliest to be mistaken for a hang, so say so.
        $note = ''
        if ($head.Expand) {
            $slot = $Results[$head.Index]
            if ($slot -and $slot.Files.Count -gt 0) {
                # Count the entries hashed so far, not just the fact of
                # expanding. A number that climbs is proof the worker is making
                # progress; one that sits at 0 says it has not got inside the
                # archive at all yet, which is a different problem entirely and
                # worth being able to tell apart from a slow one.
                $note = '  (expanding: {0} entries)' -f $slot.Archives.Count
            }
        }
        [void]$lines.Add(('{0,3}  {1,7}  {2,10}  {3}{4}' -f ($i + 1),
            (Format-Elapsed $w.Clock.Elapsed),
            (Format-ByteSize $head.Size),
            (Format-PanelPath $head.RelPath),
            $note))
    }
    if ($Workers.Count -gt $shown) {
        [void]$lines.Add(('     ... and {0} more workers' -f ($Workers.Count - $shown)))
    }
    # A WinForms Label wants CRLF between its lines.
    return ($lines -join "`r`n")
}

function Invoke-ParallelHash {
    # Feeds $Items to a pool of child processes and returns a hashtable keyed on
    # each item's Index, each value holding Files, Archives, Warnings, Failures
    # and Missing for that item.
    #
    # Returns $null to mean "the caller should do this sequentially instead":
    # either there is not enough work to be worth a pool, or no pool could be
    # started, or a worker died part-way through.
    #
    # $Items are [pscustomobject] with Index, RelPath, FullPath, Algorithm and
    # Expand. Index is the item's position in the caller's ordered list, and is
    # what puts the results back into that order at the end.
    param(
        [Parameter(Mandatory)][object[]] $Items,
        [string] $ProgressTitle = 'Hashing Files',
        [int]    $WorkerCount
    )
    if ($Items.Count -eq 0) { return @{} }
    if (-not $PSBoundParameters.ContainsKey('WorkerCount')) { $WorkerCount = $Parallel }
    # Never start more workers than there are items for them to hash.
    $WorkerCount = [Math]::Min($WorkerCount, $Items.Count)
    if ($WorkerCount -lt 2) { return $null }

    $workers = Start-HashWorkerPool -Count $WorkerCount
    if (-not $workers) { return $null }

    $results = @{}
    $queue   = New-Object System.Collections.Generic.Queue[object]
    foreach ($item in $Items) {
        $results[$item.Index] = [pscustomobject]@{
            Files    = New-Object System.Collections.Generic.List[object]
            Archives = New-Object System.Collections.Generic.List[object]
            Warnings = New-Object System.Collections.Generic.List[string]
            Failures = New-Object System.Collections.Generic.List[string]
            Missing  = $false
        }
        $queue.Enqueue($item)
    }

    $tab         = "`t"
    $outstanding = 0
    $completed   = 0
    $failed      = $false
    $ui = New-ProgressUI -Title $ProgressTitle -Max $Items.Count -Rows $WorkerCount
    try {
        while ($queue.Count -gt 0 -or $outstanding -gt 0) {
            $didWork = $false
            foreach ($w in $workers) {
                if ($w.Dead) { continue }

                # DRAIN FIRST, ALWAYS. Feeding a worker whose stdout has not been
                # emptied is the one way this loop could deadlock.
                #
                # The read is asynchronous and event-free on purpose.
                # Register-ObjectEvent handlers only fire when the PowerShell
                # engine is idle, which a feed loop never is, so an
                # OutputDataReceived handler would simply never run. Polling
                # BeginRead/IsCompleted/EndRead works the same on 5.1 and 7.
                if ($null -eq $w.Pending) {
                    $w.Pending = $w.Proc.StandardOutput.BaseStream.BeginRead(
                        $w.Buffer, 0, $w.Buffer.Length, $null, $null)
                }
                if ($w.Pending.IsCompleted) {
                    $read = $w.Proc.StandardOutput.BaseStream.EndRead($w.Pending)
                    $w.Pending = $null
                    if ($read -le 0) {
                        # stdout closed: the worker has exited. Nothing asked it
                        # to, so it died, and whatever it still owed is gone.
                        $w.Dead = $true
                        if ($w.Outstanding -gt 0 -or $queue.Count -gt 0) {
                            Write-Warning ("A hashing worker exited unexpectedly; redoing this " +
                                           "scan sequentially in this process.")
                            $failed = $true
                            break
                        }
                        continue
                    }
                    $didWork = $true
                    $chars = [char[]]::new($w.Decoder.GetCharCount($w.Buffer, 0, $read))
                    [void]$w.Decoder.GetChars($w.Buffer, 0, $read, $chars, 0)
                    [void]$w.Partial.Append($chars)

                    # A read can also land mid-line, so only whole lines are
                    # consumed here and the remainder stays in Partial.
                    $text = $w.Partial.ToString()
                    $cut  = $text.LastIndexOf($script:WorkerEolChar)
                    if ($cut -ge 0) {
                        [void]$w.Partial.Remove(0, $cut + 1)
                        foreach ($line in $text.Substring(0, $cut).Split($script:WorkerEolChar)) {
                            $record = $line.TrimEnd("`r")
                            if ($record -eq '') { continue }
                            if (Read-WorkerRecord -Line $record -Results $results) {
                                $w.Outstanding--
                                $outstanding--
                                $completed++
                                # The item is finished, so the next one in the
                                # queue becomes what this worker is doing. The
                                # dequeue belongs here and not in
                                # Read-WorkerRecord, which is handed a line and
                                # the results table and has no idea which worker
                                # sent it.
                                if ($w.InFlight.Count -gt 0) {
                                    $finished = $w.InFlight.Dequeue()
                                    # Guarded on $DebugMode as well as the
                                    # threshold: the message is built before
                                    # Write-Debug is called, so an unguarded
                                    # format would be paid for on every item
                                    # whether anything reads it or not.
                                    if ($DebugMode -and
                                        $w.Clock.Elapsed.TotalSeconds -ge $script:SlowItemSeconds) {
                                        Write-Debug ("Slow item: '{0}' ({1}, expand={2}) took {3}" -f
                                            $finished.RelPath, (Format-ByteSize $finished.Size),
                                            $finished.Expand, (Format-Duration $w.Clock.Elapsed))
                                    }
                                }
                                $w.Clock.Restart()
                            }
                        }
                    }
                }

                # THEN FEED -- one item per worker per pass, never a whole
                # window at once. Filling worker 1's window before looking at
                # worker 2 leaves the later workers with nothing whenever there
                # are fewer items than workers times window: 24 files across 4
                # workers went 8, 8, 8, 0, so a quarter of the pool sat idle for
                # the entire scan. Handing out one at a time fills every window
                # evenly, and the loop comes back round immediately.
                if ($w.Outstanding -lt $script:WorkerWindow -and $queue.Count -gt 0) {
                    $item = $queue.Dequeue()
                    $expandFlag = if ($item.Expand) { '1' } else { '0' }
                    $request = @(
                        $item.Index
                        $item.Algorithm
                        $expandFlag
                        (ConvertTo-WireText $item.RelPath)
                        (ConvertTo-WireText $item.FullPath)
                    ) -join $tab
                    $w.StdIn.WriteLine($request)
                    $w.InFlight.Enqueue($item)
                    # Nothing was in flight, so this item is now the current one
                    # and its clock starts here rather than at the last E.
                    if ($w.InFlight.Count -eq 1) { $w.Clock.Restart() }
                    $w.Outstanding++
                    $outstanding++
                    $didWork = $true
                }
            }
            if ($failed) { return $null }
            # Deliberately gated here rather than left to Update-ProgressUI.
            # PowerShell evaluates arguments before the call, so passing the
            # panel inline would format it on every pass of this loop --
            # thousands a second -- and throw nearly all of them away, however
            # hard the function throttles the repaint afterwards. Checking the
            # same clock first means the panel is built at most ~12 times a
            # second, which is less work than the Base64 decoding this loop
            # already does per record.
            if ($ui.Clock.ElapsedMilliseconds -ge $script:ProgressRepaintMs) {
                Update-ProgressUI -Ui $ui -Value $completed -Text (
                    Get-WorkerPanelText -Workers $workers -Results $results `
                        -Completed $completed -Total $Items.Count -MaxRows $ui.Rows)
            }
            # Every worker is busy and none has answered yet. Without this the
            # parent would spin a core doing nothing but polling.
            if (-not $didWork) { Start-Sleep -Milliseconds 5 }
        }
        # Everything is done and every worker is idle, so the panel has nothing
        # left to say; close on the total.
        Update-ProgressUI -Ui $ui -Value $completed `
            -Text "Processed $completed of $($Items.Count)" -Force
    } finally {
        Close-ProgressUI $ui
        Stop-HashWorkerPool -Workers $workers
    }
    return $results
}

# =====================================================================
#  Shared scan engine
#  Scans ScanRoot recursively, hashes every file, expands archives.
#  Returns a Generic.List[object] of [pscustomobject]@{FilePath;Hash}.
#  $script:ArchiveWarnings is populated as a side-effect.
# =====================================================================

# Filename patterns for files produced by this script that should never
# be included in a scan (they will always appear as New on a rescan).
$script:ScriptOutputPatterns = @(
    '*-initial.hashes.csv',
    '*-initial.hashes.csv.sha512',
    '*-initial.manifest.log',
    '*-rescan.hashes.csv',
    '*-fileverification.log',
    'Filelist-*.txt',          # default manifest name
    'debug.log'
)

# =====================================================================
#  System / OS housekeeping exclusions
#
#  Volume-level clutter that no transfer is ever about: Windows' own
#  per-volume folders, the recycle bins, and the thumbnail and metadata
#  files Windows, macOS and Linux scatter across removable media.
#  Skipped unless -IncludeSystemFiles is given.
#
#  Two reasons this is not merely cosmetic. A listing padded out with
#  someone's Recycle Bin is not a record of what was transferred. And on
#  a Comprehensive verify with -ReportExtraFiles, the destination
#  volume's own System Volume Information -- which every formatted NTFS
#  volume has -- would be reported as a difference on a transfer where
#  nothing whatever went wrong.
#
#  Deliberately conservative: anything that could plausibly BE the
#  payload is left alone. bootmgr, autorun.inf, EFI and boot are real
#  content on bootable media that people genuinely transfer, so none of
#  them appear here.
# =====================================================================

# Matched against every directory segment of a path, so the whole subtree
# under one of these is skipped rather than just a file that happens to share
# the name. A HashSet because this is checked once per segment per file, and
# on a large tree that is the one place a linear walk would be felt.
$script:SystemFolderNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in @(
    'System Volume Information',   # every NTFS volume root; normally ACL-locked
    '$RECYCLE.BIN',                # current recycle bin
    'RECYCLER',                    # its pre-Vista predecessor
    'Config.Msi',                  # Windows Installer rollback state
    '$WinREAgent',                 # recovery scratch
    '$SysReset',                   # reset-this-PC scratch
    '$Windows.~BT',                # in-place upgrade staging
    '$Windows.~WS',
    '$GetCurrent',
    'lost+found',                  # ext2/3/4
    '.Trashes',                    # macOS trash on removable media
    '.Spotlight-V100',             # macOS search index
    '.fseventsd',                  # macOS filesystem event log
    '.TemporaryItems',
    '.DocumentRevisions-V100'
)) { [void]$script:SystemFolderNames.Add($name) }

# The handful that need wildcards, kept apart from the set above so the common
# case stays an O(1) lookup instead of a walk down a pattern list.
$script:SystemFolderPatterns = @(
    '.Trash-*',      # .Trash-1000 and friends, one per uid
    'found.???'      # chkdsk salvage: found.000, found.001, ...
)

$script:SystemFilePatterns = @(
    'Thumbs.db',                   # Windows thumbnail cache
    'ehthumbs.db',                 # ... and the Media Center one
    'IconCache.db',
    'desktop.ini',                 # per-folder shell settings
    'pagefile.sys',                # never readable, never meaningful to copy
    'hiberfil.sys',
    'swapfile.sys',
    'DumpStack.log',
    'DumpStack.log.tmp',
    '.DS_Store',                   # macOS folder metadata
    '._*',                         # macOS AppleDouble resource forks
    '.apdisk'
)

function Test-IsSystemPath {
    # $RelativePath is relative to the scan root, so a System Volume Information
    # sitting three folders down is caught as surely as one at the root.
    #
    # Directory segments are tested against the folder lists and the final
    # segment of a file path against the file list. -Directory says the path
    # names a folder, in which case its last segment is a folder too.
    param(
        [Parameter(Mandatory)][string] $RelativePath,
        [switch] $Directory
    )
    $segments = $RelativePath -split '[/\\]'
    $folderCount = if ($Directory) { $segments.Count } else { $segments.Count - 1 }
    for ($i = 0; $i -lt $folderCount; $i++) {
        $segment = $segments[$i]
        if ($script:SystemFolderNames.Contains($segment)) { return $true }
        foreach ($pattern in $script:SystemFolderPatterns) {
            if ($segment -like $pattern) { return $true }
        }
    }
    if (-not $Directory) {
        $leaf = $segments[$segments.Count - 1]
        foreach ($pattern in $script:SystemFilePatterns) {
            if ($leaf -like $pattern) { return $true }
        }
    }
    return $false
}

function Test-IsScriptOutput {
    param([string] $FileName)
    foreach ($pattern in $script:ScriptOutputPatterns) {
        if ($FileName -like $pattern) { return $true }
    }
    return $false
}

# =====================================================================
#  CSV integrity sidecar
#  Written at build time; validated before any verification run.
#  Format (sha512sum-compatible, one entry per line):
#      <SHA-512 hex>  <bare filename>
# =====================================================================

function Get-SidecarPath {
    # Returns the full path of the sidecar for a given CSV path.
    param([string] $CsvPath)
    return "$CsvPath.sha512"
}

function New-SidecarFile {
    # Hashes the CSV and the script itself, writes the sidecar.
    param(
        [string] $CsvPath,
        [string] $ScriptPath   # the deployed copy; defaults to the running script
    )
    # $ScriptPath names the copy that will travel with the data. It matters
    # which one is recorded: the sidecar's script entry is resolved at the
    # destination relative to the script running there, so the entry has to
    # describe the deployed copy, not the one that happened to build it.
    # (Both are byte-identical, so the hash is the same either way -- hashing
    # the deployed file also confirms the copy actually landed intact.)
    #
    # $PSCommandPath is this script directly; $MyInvocation.PSCommandPath is
    # the *caller's* script, which is only incidentally the same file.
    $scriptPath = $ScriptPath
    if (-not $scriptPath) { $scriptPath = $PSCommandPath }
    if (-not $scriptPath) { $scriptPath = $MyInvocation.PSCommandPath }
    if (-not $scriptPath) {
        Write-Warning "Cannot determine the script path; sidecar not written."
        return $null
    }
    $sidecarPath = Get-SidecarPath $CsvPath
    try {
        $csvHash = (Get-FileHash -Path $CsvPath    -Algorithm SHA512 -ErrorAction Stop).Hash
        $ps1Hash = (Get-FileHash -Path $scriptPath -Algorithm SHA512 -ErrorAction Stop).Hash
        $csvName = Split-Path -Leaf $CsvPath
        $ps1Name = Split-Path -Leaf $scriptPath
        # sha512sum-compatible format: hash, two spaces, bare filename.
        "$csvHash  $csvName" | Out-File -FilePath $sidecarPath -Encoding ascii
        "$ps1Hash  $ps1Name" | Out-File -FilePath $sidecarPath -Encoding ascii -Append
        Write-Debug "Sidecar written: $sidecarPath"
        return $sidecarPath
    } catch {
        Write-Warning "Could not write sidecar file: $_"
        return $null
    }
}

# Integrity results for this run, keyed on CSV path. Only passes are recorded.
$script:IntegrityValidated = @{}

function Test-SidecarFile {
    # Memoising wrapper. Main runs this before any workflow UI, and the
    # Compare-* functions still call it as a safety net -- without the cache
    # that would hash both files twice and, on a CSV mismatch, put the same
    # Yes/No question to the user two times.
    #
    # Only a pass is cached. A failure is re-evaluated if it is somehow reached
    # again, which is the safe direction to err in.
    param([string] $CsvPath)
    if ($script:IntegrityValidated.ContainsKey($CsvPath)) {
        Write-Debug "Integrity already validated this run for: $CsvPath"
        return $true
    }
    $result = Invoke-SidecarCheck -CsvPath $CsvPath
    if ($result) { $script:IntegrityValidated[$CsvPath] = $true }
    return $result
}

function Invoke-SidecarCheck {
    # Validates the CSV and PS1 against the sidecar.
    # Returns $true to proceed, $false to abort.
    # Missing sidecar: hard block (workflow error — sidecar was not burned).
    # Hash mismatch:   warn with Yes/No — the CSV or script may be compromised.
    param([string] $CsvPath)
    $sidecarPath = Get-SidecarPath $CsvPath

    if (-not (Test-Path -LiteralPath $sidecarPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "No integrity sidecar found.`r`n`r`n" +
            "Expected alongside the CSV:`r`n$sidecarPath`r`n`r`n" +
            "The .sha512 file must be burned to disc with the CSV. " +
            "Verification is blocked until it is present.",
            'Sidecar Not Found', 'OK', 'Error') | Out-Null
        return $false
    }

    # Parse sidecar: each line is "<hash>  <filename>" (sha512sum format).
    $expected = @{}
    foreach ($line in (Get-Content -LiteralPath $sidecarPath -ErrorAction Stop)) {
        if ($line.Trim() -eq '') { continue }
        $parts = $line -split '  ', 2
        if ($parts.Count -eq 2) {
            $expected[$parts[1].Trim()] = $parts[0].Trim().ToUpper()
        }
    }

    # Separate script failures (hard block) from CSV failures (warn + ask).
    $scriptFailures = New-Object System.Collections.Generic.List[string]
    $csvFailures    = New-Object System.Collections.Generic.List[string]

    $csvName = Split-Path -Leaf $CsvPath
    # Each sidecar entry is resolved against the folder that file actually lives
    # in, which is not the same folder for both. The CSV is resolved to the path
    # we were handed; the script entry is resolved against the script's own
    # folder. Resolving the script against the CSV's directory (as an earlier
    # tempting) is only correct while the two sit together -- if the CSV ever
    # lives elsewhere, the .ps1 would not be found there and the run would
    # hard-block with "Script Tampered", which would be a false accusation.
    $scriptDir = Get-ParentScriptFolder

    foreach ($entry in $expected.GetEnumerator()) {
        $name     = $entry.Key
        $expHash  = $entry.Value
        $isCsv    = ($name -eq $csvName)
        $fullPath = if ($isCsv) { $CsvPath } else { Join-Path $scriptDir $name }

        if (-not (Test-Path -LiteralPath $fullPath)) {
            if ($isCsv) { [void]$csvFailures.Add("File not found: $name") }
            else        { [void]$scriptFailures.Add("File not found: $name") }
            continue
        }
        $actual = (Get-FileHash -Path $fullPath -Algorithm SHA512 -ErrorAction Stop).Hash.ToUpper()
        if ($actual -ne $expHash) {
            $detail = "HASH MISMATCH: $name`r`n  Expected: $expHash`r`n  Actual  : $actual"
            if ($isCsv) { [void]$csvFailures.Add($detail) }
            else        { [void]$scriptFailures.Add($detail) }
        }
    }

    # Script mismatch: hard block — malicious code may have been injected.
    if ($scriptFailures.Count -gt 0) {
        $msg  = "CRITICAL: The script file has been tampered with.`r`n`r`n"
        $msg += "The hash of this .ps1 file does not match the sidecar recorded "
        $msg += "at build time. Malicious code may have been added. "
        $msg += "Verification is blocked.`r`n`r`n"
        $msg += ($scriptFailures -join "`r`n`r`n")
        [System.Windows.Forms.MessageBox]::Show(
            $msg, 'Script Tampered — Verification Blocked', 'OK', 'Error') | Out-Null
        return $false
    }

    # CSV mismatch: warn and ask — it is a text file and may have a benign explanation.
    if ($csvFailures.Count -gt 0) {
        $msg  = "WARNING: The initial CSV does not match the sidecar.`r`n`r`n"
        $msg += "The hash file recorded at build time does not match the current "
        $msg += "CSV. The initial hash listing may have been modified or corrupted.`r`n`r`n"
        $msg += ($csvFailures -join "`r`n`r`n")
        $msg += "`r`n`r`nDo you want to continue with verification anyway?"
        $result = [System.Windows.Forms.MessageBox]::Show(
            $msg, 'CSV Integrity Warning',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
    }

    Write-Debug "Sidecar integrity check passed for $CsvPath"
    return $true
}

function Invoke-FileScan {
    # Owns its own progress UI directly to avoid double-closure scoping issues.
    # (Passing $result into Invoke-ProgressLoop's -Body scriptblock loses the
    # reference because the body runs in a nested scope; .Add() calls on the
    # inner $result silently no-op and the list comes back empty.)
    param(
        [Parameter(Mandatory)][string] $ScanRoot,
        [string] $ProgressTitle = 'Scanning Files'
    )
    # Normalise once: a scan root of "D:\" and one of "D:\Data" differ by a
    # trailing separator, and the Substring below depends on getting it right.
    $rootPrefix = $ScanRoot.TrimEnd('\', '/') + '\'

    # Walking the tree is its own cost and worth reporting separately: on a
    # listing with a lot of files it can be a visible part of the run, and
    # unlike hashing it is not something -Parallel makes any faster.
    $enumClock = [System.Diagnostics.Stopwatch]::StartNew()

    $files  = @(Get-ChildItem -Path $ScanRoot -File -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object {
                    if (Test-IsScriptOutput $_.Name) { return $false }
                    if ($IncludeSystemFiles) { return $true }
                    $relative = $_.FullName.Substring($rootPrefix.Length).TrimStart('\', '/')
                    if (Test-IsSystemPath -RelativePath $relative) {
                        # Not recorded anywhere the operator reads: these files
                        # are not part of the transfer, so a manifest section
                        # counting them would be noise about noise. The debug
                        # stream is there for when you need to know.
                        if ($DebugMode) { Write-Debug "Skipped system file: $relative" }
                        return $false
                    }
                    return $true
                })
    $result = New-Object System.Collections.Generic.List[object]

    # Folders are recorded separately for the manifest listing only. They have
    # no hash, so they never enter the CSV or the comparison.
    $script:LastScanFolders = New-Object System.Collections.Generic.List[string]
    foreach ($d in (Get-ChildItem -Path $ScanRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue)) {
        $relativeDir = $d.FullName.Substring($rootPrefix.Length).TrimStart('\','/')
        # Skipped from the count as well as the listing. Reporting "Folders: 4"
        # when three of them are System Volume Information and its children
        # would be worse than not counting at all.
        if (-not $IncludeSystemFiles -and (Test-IsSystemPath -RelativePath $relativeDir -Directory)) {
            if ($DebugMode) { Write-Debug "Skipped system folder: $relativeDir" }
            continue
        }
        [void]$script:LastScanFolders.Add($relativeDir)
    }

    $enumClock.Stop()
    $script:LastEnumerateTime = $enumClock.Elapsed

    # Everything from here is hashing. Worker startup and archive expansion are
    # inside this clock deliberately -- both are time the operator spends
    # waiting on the hash, so leaving them out would report a number smaller
    # than the wait it is supposed to describe.
    $hashClock = [System.Diagnostics.Stopwatch]::StartNew()

    # Parallel first. $null back means the pool was not usable -- too little
    # work to be worth one, none could be started, or a worker died part-way --
    # and the loop below runs instead. That loop is the v5.13 one, untouched, so
    # it is both the -Parallel 1 behaviour and the fallback.
    $parallel = Invoke-ParallelFileScan -Files $files -RootPrefix $rootPrefix `
                    -ProgressTitle $ProgressTitle
    if ($null -ne $parallel) {
        $script:LastHashTime = $hashClock.Elapsed
        return $parallel
    }

    $ui = New-ProgressUI -Title $ProgressTitle -Max $files.Count
    try {
        $i = 0
        foreach ($file in $files) {
            $i++
            $rel = $file.FullName.Substring($rootPrefix.Length).TrimStart('\','/')
            try {
                $result.Add([pscustomobject]@{ FilePath = $rel; Hash = (Get-FileSha512 -Path $file.FullName) })
            } catch {
                Write-Warning "Could not hash '$($file.FullName)': $_"
            }
            if (-not $SkipArchiveContents) {
                $ext = Get-ArchiveExtension $file.Name
                if ($ext) {
                    # -Force: archive expansion can take minutes, so this label
                    # must appear immediately rather than wait for the throttle.
                    Update-ProgressUI -Ui $ui -Text "Expanding archive: $rel" -Force
                    $inner = @(Get-ArchiveContentHash -ArchivePath $file.FullName `
                                  -ArchiveRelativePath $rel -Extension $ext)
                    foreach ($e in $inner) { if ($null -ne $e) { $result.Add($e) } }
                }
            }
            Update-ProgressUI -Ui $ui -Value $i -Text "Processed $i of $($files.Count):`r`n$rel" `
                -Force:($i -eq $files.Count)
        }
    } finally {
        Close-ProgressUI $ui
    }
    $script:LastHashTime = $hashClock.Elapsed
    return $result
}

function Invoke-ParallelFileScan {
    # The parallel counterpart to the loop in Invoke-FileScan. Returns a
    # Generic.List[object] of @{FilePath;Hash} in exactly the order the
    # sequential loop would have produced, or $null to say the caller should run
    # that loop instead.
    param(
        [object[]] $Files,
        [Parameter(Mandatory)][string] $RootPrefix,
        [string] $ProgressTitle = 'Scanning Files'
    )
    if ($Parallel -le 1 -or $null -eq $Files -or $Files.Count -lt 2) { return $null }

    # Work items in enumeration order. Archive expansion is handed to the
    # workers for the zip and tar families only. An ISO needs Mount-DiskImage, a
    # drive letter, and the HKCU AutoPlay push/pop -- all machine-global state
    # that several processes would race on, mounting over each other and
    # restoring AutoPlay out from under one another. Those stay with the parent,
    # one at a time, below.
    $items    = New-Object System.Collections.Generic.List[object]
    $isoItems = New-Object System.Collections.Generic.List[object]
    $index    = 0
    foreach ($file in $Files) {
        $rel = $file.FullName.Substring($RootPrefix.Length).TrimStart('\', '/')
        $ext = if ($SkipArchiveContents) { $null } else { Get-ArchiveExtension $file.Name }
        $isIso = ($ext -eq '.iso')
        [void]$items.Add([pscustomobject]@{
            Index     = $index
            RelPath   = $rel
            FullPath  = $file.FullName
            Algorithm = 'SHA512'
            Expand    = ($null -ne $ext -and -not $isIso)
            Size      = $file.Length
        })
        if ($isIso) {
            [void]$isoItems.Add([pscustomobject]@{
                Index = $index; RelPath = $rel; FullPath = $file.FullName
            })
        }
        $index++
    }

    # Feed order is not output order. Results come back keyed on Index and are
    # flattened in index order further down, so the queue can be arranged purely
    # for speed without moving a single row in the CSV.
    #
    # Longest job first. Fed in enumeration order, the heavy items land wherever
    # they happen to sit in the tree, and a scan can sit at 90% with every
    # remaining worker on a multi-gigabyte file and the rest of the pool idle --
    # the whole point of the pool lost in the last stretch of the run. Starting
    # the heavy items first overlaps them with the thousands of small ones, so
    # the run ends when the last small file finishes instead of when the largest
    # one does.
    #
    # Archives go first whatever their size, because their cost is their
    # *expanded* contents and nothing here can know that before opening them. An
    # item of unknown cost is precisely the one not to discover at the end.
    $feedOrder = @($items | Sort-Object `
        -Property @{ Expression = 'Expand'; Descending = $true },
                  @{ Expression = 'Size';   Descending = $true })

    $results = Invoke-ParallelHash -Items $feedOrder -ProgressTitle $ProgressTitle
    if ($null -eq $results) { return $null }

    # ISOs now, in this process, one at a time. Their entries are filed against
    # the owning item's index rather than appended, so the finished listing
    # keeps the sequential order -- each archive's contents directly after the
    # archive itself. That is what makes the CSV, and therefore the .sha512
    # written over it, identical between -Parallel 1 and -Parallel 4.
    if ($isoItems.Count -gt 0) {
        $ui = New-ProgressUI -Title $ProgressTitle -Max $isoItems.Count
        try {
            $n = 0
            foreach ($iso in $isoItems) {
                $n++
                Update-ProgressUI -Ui $ui -Value $n -Text "Expanding archive: $($iso.RelPath)" -Force
                foreach ($e in @(Get-ArchiveContentHash -ArchivePath $iso.FullPath `
                                    -ArchiveRelativePath $iso.RelPath -Extension '.iso')) {
                    if ($null -ne $e) { [void]$results[$iso.Index].Archives.Add($e) }
                }
            }
        } finally { Close-ProgressUI $ui }
    }

    # Flatten by index. Warnings are replayed here rather than in the read loop
    # so they come out in file order too, and so a W lands in
    # $script:ArchiveWarnings exactly as Add-ArchiveWarning would have put it
    # there sequentially. An F was only ever warned about, never counted as an
    # archive warning, so it stays out of that list.
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $items.Count; $i++) {
        $slot = $results[$i]
        if (-not $slot) { continue }
        foreach ($f in $slot.Failures) { Write-Warning $f }
        foreach ($w in $slot.Warnings) {
            Write-Warning $w
            [void]$script:ArchiveWarnings.Add($w)
        }
        foreach ($e in $slot.Files)    { [void]$out.Add($e) }
        foreach ($e in $slot.Archives) { [void]$out.Add($e) }
    }
    Write-Debug "Parallel scan: $($out.Count) entries from $($items.Count) files, $($isoItems.Count) ISO(s) in the parent."
    return $out
}

# =====================================================================
#  Initial file builders
# =====================================================================

function Get-ManifestFileName {
    # Free-text manifest filename, prefilled with Filelist-<scanned folder>.txt.
    #
    # This replaced a two-option radio dialog (timestamped vs folder-named):
    # people wanted to name the file themselves rather than pick between two
    # fixed conventions. Typing a timestamped name still gets the old result.
    #
    # Only the human-readable manifest is affected -- the CSV and its .sha512
    # keep their timestamped names, because verification finds the CSV by the
    # '*-initial.hashes.csv' glob and pairs the sidecar off that exact name.
    #
    # Returns a bare filename, never a path.
    param([Parameter(Mandatory)][string] $DefaultName)

    # Title bar credits the coworker who asked for the free-text box.
    $form = New-FormControl Form @{
        Text = 'Sean mode'; Size = (New-Sz 470 220); StartPosition = 'CenterScreen'
    }
    $label = New-FormControl Label @{
        Location = (New-Pt 15 12); Size = (New-Sz 425 20)
        Text = 'Name for the manifest (the readable file listing):'
    }
    $textBox = New-FormControl TextBox @{
        Location = (New-Pt 15 36); Size = (New-Sz 425 22); Text = $DefaultName
    }
    $hint = New-FormControl Label @{
        Location = (New-Pt 15 68); Size = (New-Sz 425 76)
        Text = "Written into the transfer folder next to the CSV and .sha512." +
               "`r`n`r`nIf no extension is given, .txt is added. Characters that " +
               "cannot appear in a filename are replaced with _. If the name is " +
               "already taken, _2, _3, ... is appended rather than overwriting."
    }

    # Pre-seeded so closing the form with the X still yields a usable name.
    $script:manifestFileName = $DefaultName

    $okBtn = New-FormControl Button @{
        Location = (New-Pt 175 152); Size = (New-Sz 100 28); Text = 'Continue'
    }
    $okBtn.Add_Click({
        $val = $textBox.Text.Trim()
        if ($val -eq '') { $val = $DefaultName }
        # Strips any path separators too -- this must stay a bare filename, so
        # a typed path cannot redirect the manifest out of the transfer folder.
        $val = ConvertTo-SafeFileNamePart $val
        if (-not [System.IO.Path]::GetExtension($val)) { $val += '.txt' }
        $script:manifestFileName = $val
        $form.Close()
    })
    $form.AcceptButton = $okBtn
    $form.Controls.AddRange(@($label, $textBox, $hint, $okBtn))
    try {
        $textBox.Select()
        $form.ShowDialog() | Out-Null
    } finally { $form.Dispose() }
    return $script:manifestFileName
}

function Copy-ScriptToTransferFolder {
    # Deploys this .ps1 into the folder that is about to be transferred.
    #
    # The script, the CSV, and the sidecar are useless apart: verification at the
    # destination needs all three, and leaving it to the operator to remember to
    # copy the tooling across is a step that gets forgotten. So the script puts
    # itself into the payload, and the initial files are then written next to
    # that copy rather than next to wherever the script happened to be run from.
    #
    # The filename is taken from the running script, so version bumps carry over
    # on their own -- nothing here assumes a particular name.
    #
    # Returns the deployed path, or $null if the copy could not be made.
    param([Parameter(Mandatory)][string] $ScanRoot)

    $sourcePath = $PSCommandPath
    if (-not $sourcePath) { $sourcePath = $MyInvocation.PSCommandPath }
    if (-not $sourcePath) {
        Write-Warning "Cannot determine the running script's path; nothing deployed."
        return $null
    }
    $leaf   = Split-Path -Leaf $sourcePath
    $target = Join-Path $ScanRoot $leaf

    try {
        # Already running from inside the transfer folder: nothing to do. Copying
        # a file onto itself throws, and can truncate it.
        if ([System.IO.Path]::GetFullPath($sourcePath) -ieq [System.IO.Path]::GetFullPath($target)) {
            Write-Debug "Script is already in the transfer folder: $target"
            return $target
        }
        if (Test-Path -LiteralPath $target) {
            # Same bytes already there -- skip, so the timestamp is not disturbed.
            if ((Get-FileSha512 -Path $sourcePath) -eq (Get-FileSha512 -Path $target)) {
                Write-Debug "An identical copy is already present: $target"
                return $target
            }
            Write-Debug "Replacing a different copy of '$leaf' in the transfer folder."
        }
        Copy-Item -LiteralPath $sourcePath -Destination $target -Force -ErrorAction Stop
        Write-Debug "Script deployed to: $target"
        return $target
    } catch {
        Write-Warning "Could not copy the script into '$ScanRoot': $_"
        return $null
    }
}

function Set-InitialFileAutomatic {
    $scanRoot = Resolve-BasePath -PromptDescription "Select the base folder to scan (initial build)"
    if (-not $scanRoot) {
        Show-MessageBox "No folder selected. Initial build cancelled."
        return
    }

    # Deploy the script into the transfer folder first, before the scan, so it
    # is hashed as part of the payload like any other file being transferred.
    $deployedScript = Copy-ScriptToTransferFolder -ScanRoot $scanRoot
    if (-not $deployedScript) {
        [System.Windows.Forms.MessageBox]::Show(
            "The script could not be copied into:`r`n$scanRoot`r`n`r`n" +
            "The initial files are written next to that copy, so the transfer " +
            "folder has to be writable. Nothing was written.",
            'Cannot Write To Transfer Folder', 'OK', 'Error') | Out-Null
        return
    }

    # Prompt for transfer name before the scan starts (user isn't waiting).
    $defaultName = "Initial hash listing"
    $transferName = Get-TransferName -Default $defaultName

    # Single timestamp so CSV, sidecar, and manifest share identical names.
    #
    # Output goes to the transfer folder, NOT to the folder the script was run
    # from -- the originating folder gets nothing added to it. At the
    # destination the script sits beside the CSV, which is exactly what
    # Search-InitialFileExistence and the sidecar check expect.
    $stamp       = Get-Date -Format yyyyMMdd_HHmm
    $outputDir   = $scanRoot
    $csvPath     = Join-Path $outputDir ($stamp + "-initial.hashes.csv")
    $sidecarPath = Join-Path $outputDir ($stamp + "-initial.hashes.csv.sha512")

    # Manifest name: whatever the user types, defaulting to Filelist-<folder>.txt.
    $defaultManifestName = "Filelist-$(Get-ScanFolderLabel $scanRoot).txt"
    $manifestName = Get-ManifestFileName -DefaultName $defaultManifestName
    $manifestLog  = Get-NonCollidingPath (Join-Path $outputDir $manifestName)
    Write-Debug "Manifest name='$manifestName' -> $manifestLog"

    # Bare filenames for the manifest listing (the files to burn).
    $csvName     = Split-Path -Leaf $csvPath
    $sidecarName = Split-Path -Leaf $sidecarPath

    $script:ArchiveWarnings.Clear()
    $output = Invoke-FileScan -ScanRoot $scanRoot -ProgressTitle 'Building Initial Hash Listing'

    if ($output.Count -eq 0) {
        Show-MessageBox "No files were found under '$scanRoot'. Nothing was written."
        return
    }

    $output | Export-Csv -Path $csvPath -NoTypeInformation -Encoding $script:CsvEncoding

    # Write integrity sidecar (CSV + script hashes) — burn this with the CSV.
    # A null return means the sidecar could not be written; verification would
    # then hard-block, so say so here rather than at verify time.
    $writtenSidecar = New-SidecarFile -CsvPath $csvPath -ScriptPath $deployedScript
    Write-Debug "Sidecar: $writtenSidecar"
    if ($writtenSidecar) { $sidecarPath = $writtenSidecar }

    # Write manifest: header, file listing (no algorithm prefix), transfer
    # files, and any archive warnings.
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add($transferName)
    [void]$lines.Add("Built     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$lines.Add("Scan root : $scanRoot")
    # Entries = rows in the CSV (hashed). Listed = lines in the Files section,
    # which is two longer because the CSV and .sha512 are named there but are
    # not themselves hashed entries.
    [void]$lines.Add("Entries   : $($output.Count)  (hashed, in the CSV)")
    [void]$lines.Add("Listed    : $($output.Count + 2)  (files below)")
    [void]$lines.Add("Skip arc. : $SkipArchiveContents")
    [void]$lines.Add("Folders   : $($script:LastScanFolders.Count)")
    [void]$lines.Add("Enumerate : $(Format-Duration $script:LastEnumerateTime)")
    [void]$lines.Add("Hash time : $(Format-Duration $script:LastHashTime)")
    [void]$lines.Add("")

    # Folders are counted in the header but not listed: every folder that holds
    # a file already appears as that file's path prefix in the listing below, so
    # a separate section just repeats the same information. (The count is the
    # only trace of a folder that contains no files at all.)
    # Every file that ends up in the transfer folder, in one listing.
    #
    # The scan covers the payload and the deployed .ps1 (copied in before the
    # scan, so it is hashed like any other file). The CSV and .sha512 are
    # written after the scan and so cannot be scan results -- they are appended
    # here by name. They carry no hash in this listing: the CSV cannot contain
    # its own hash, and the .sha512 is what records the CSV's.
    #
    # The manifest itself is deliberately not listed. It is the file being read,
    # and it is still written into the transfer folder regardless.
    [void]$lines.Add(("=" * 21))
    [void]$lines.Add("Files:")
    foreach ($e in $output) {
        [void]$lines.Add("  $($e.FilePath)")
    }
    [void]$lines.Add("  $csvName")
    [void]$lines.Add("  $sidecarName")
    if ($script:ArchiveWarnings.Count -gt 0) {
        [void]$lines.Add("")
        [void]$lines.Add(("=" * 21))
        [void]$lines.Add("Archive warnings ($($script:ArchiveWarnings.Count)):")
        foreach ($w in $script:ArchiveWarnings) {
            [void]$lines.Add("  - $w")
        }
    }
    $lines | Out-File -FilePath $manifestLog -Encoding utf8

    $popupMsg  = "Initial listing built.`r`nEntries: $($output.Count)"
    $popupMsg += "`r`nFolders: $($script:LastScanFolders.Count)"
    $popupMsg += "`r`nEnumerate: $(Format-Duration $script:LastEnumerateTime)"
    $popupMsg += "`r`nHash time: $(Format-Duration $script:LastHashTime)"
    $popupMsg += "`r`n`r`nEverything was written into the transfer folder:`r`n$outputDir"
    $popupMsg += "`r`n  $(Split-Path -Leaf $deployedScript)   (script)"
    $popupMsg += "`r`n  $(Split-Path -Leaf $csvPath)"
    $popupMsg += "`r`n  $(Split-Path -Leaf $sidecarPath)"
    $popupMsg += "`r`n  $(Split-Path -Leaf $manifestLog)"
    $popupMsg += "`r`n`r`nBurn or copy the whole folder — the script travels with " +
                 "the data, so verification can be run at the destination."
    $icon = 'Information'
    if (-not $writtenSidecar) {
        $popupMsg += "`r`n`r`nWARNING: the .sha512 sidecar could not be written. " +
                     "Verification will refuse to run without it."
        $icon = 'Warning'
    }
    if ($script:ArchiveWarnings.Count -gt 0) {
        $popupMsg += "`r`n`r`nArchive warnings: $($script:ArchiveWarnings.Count) (see manifest log)."
        $icon = 'Warning'
    }
    [System.Windows.Forms.MessageBox]::Show($popupMsg, 'Done', 'OK', $icon) | Out-Null
}

function Set-InitialFileManual {
    $form = New-FormControl Form @{
        Text = 'Enter Filename and Hash'; Size = (New-Sz 400 250); StartPosition = 'CenterScreen'
    }

    $filenameLabel   = New-FormControl Label   @{ Location=(New-Pt 10 20);  Size=(New-Sz 280 20); Text='Filename:' }
    $filenameTextBox = New-FormControl TextBox @{ Location=(New-Pt 10 40);  Size=(New-Sz 360 20) }
    $hashLabel       = New-FormControl Label   @{ Location=(New-Pt 10 70);  Size=(New-Sz 280 20); Text='Hash:'    }
    $hashTextBox     = New-FormControl TextBox @{ Location=(New-Pt 10 90);  Size=(New-Sz 360 20) }
    $addedLabel      = New-FormControl Label   @{ Location=(New-Pt 10 170); Size=(New-Sz 280 20); Text='' }
    $addButton       = New-FormControl Button  @{ Location=(New-Pt 10 130); Size=(New-Sz 75 23);  Text='Add' }
    $doneButton      = New-FormControl Button  @{ Location=(New-Pt 90 130); Size=(New-Sz 75 23);  Text='Done' }
    $helpButton      = New-FormControl Button  @{ Location=(New-Pt 350 10); Size=(New-Sz 30 23);  Text='?' }

    $script:output = @()

    $addButton.Add_Click({
        $filename = $filenameTextBox.Text
        if ($filename -match '[<>:"/\\|?*]') {
            [System.Windows.Forms.MessageBox]::Show(
                "The filename '$filename' contains one or more invalid characters (<, >, :, `", /, \, |, ?, *). Please enter a valid filename.",
                'Invalid Filename', 'OK', 'Error') | Out-Null
            $filenameTextBox.Clear(); return
        }
        $script:output += [pscustomobject]@{ FilePath = $filename; Hash = $hashTextBox.Text }
        $addedLabel.Text = 'Object added'; $form.Refresh()
        $filenameTextBox.Clear(); $hashTextBox.Clear()
    })
    $doneButton.Add_Click({ $form.Close() })
    $helpButton.Add_Click({
        Show-MessageBox @"
Step 1: Enter the filename and hash.
Step 2: Click the Add button to add the file-hash pair.
Step 3: Repeat steps 1 and 2 for each file.
Step 4: Click the Done button when finished.
"@
    })
    $filenameTextBox.Add_TextChanged({ $addedLabel.Text = '' })
    $hashTextBox.Add_TextChanged({ $addedLabel.Text = '' })

    $form.Controls.AddRange(@(
        $filenameLabel, $filenameTextBox, $hashLabel, $hashTextBox,
        $addedLabel, $addButton, $doneButton, $helpButton))

    try { $form.ShowDialog() | Out-Null } finally { $form.Dispose() }

    # The sidecar MUST be written here. Without it the verification run started
    # two lines below hard-blocks on "No integrity sidecar found" and Manual
    # mode cannot complete end to end.
    if (@($script:output).Count -eq 0) {
        Show-MessageBox "No file/hash pairs were entered. Nothing was written."
        return
    }
    $manualCsv = Initialize-InitialFilePath
    $script:output | Export-Csv -Path $manualCsv -NoTypeInformation -Encoding $script:CsvEncoding
    if (-not (New-SidecarFile -CsvPath $manualCsv)) {
        Show-MessageBox ("The CSV was written to`r`n$manualCsv`r`n`r`nbut its .sha512 " +
                         "sidecar could not be created, so verification cannot run.")
        return
    }

    $choice = Select-VerificationMode
    if ($choice.Mode -eq 'Comprehensive') {
        Compare-HashEntryThorough -KeepInitialListing:$choice.KeepListing
    } elseif ($choice.Mode -eq 'Basic') {
        Compare-HashEntry -KeepInitialListing:$choice.KeepListing
    }
}

# =====================================================================
#  Verification
# =====================================================================

function Test-OneEntry {
    param([pscustomobject] $Pair, [string] $CompareRoot)

    $hashType = Get-HashType $Pair.Hash
    if ([string]::IsNullOrWhiteSpace($hashType)) {
        return [pscustomobject]@{ Status='BadHashType'; Pair=$Pair; ComputedHash=$null }
    }
    $thisPath = Join-Path $CompareRoot $Pair.FilePath
    if (-not (Test-Path -LiteralPath $thisPath)) {
        return [pscustomobject]@{ Status='Missing'; Pair=$Pair; ComputedHash=$null }
    }
    try {
        $h = Get-FileHash -Path $thisPath -Algorithm $hashType -ErrorAction Stop
        if ($h.Hash -eq $Pair.Hash) {
            return [pscustomobject]@{ Status='Verified';  Pair=$Pair; ComputedHash=$h.Hash }
        }
        return [pscustomobject]@{ Status='Different';   Pair=$Pair; ComputedHash=$h.Hash }
    } catch {
        return [pscustomobject]@{ Status='Different';   Pair=$Pair; ComputedHash=$null }
    }
}

function Write-VerificationLog {
    param(
        [string] $LogFilePath,
        [string] $CompareRoot,
        [string] $CsvFile,
        [int]    $Skipped,
        [array]  $Output,            # array of "Status - Path" strings
        [array]  $DifferenceOutput,  # array of [pscustomobject]@{FilePath; Original; Computed}
        [array]  $MissingFiles,      # array of bare file paths
        [array]  $IncorrectHash,     # array of bare file paths
        [array]  $NewFiles,          # array of bare file paths (Comprehensive mode only)
        [int]    $DifferentFiles,
        [string] $Mode = 'Basic',    # 'Basic' or 'Comprehensive'
        [string] $RescanCsv  = '',   # path to rescan CSV (Comprehensive mode)
        [string] $ListingDisposition = '',  # what happened to the initial CSV
        # TimeSpans, or $null to leave the line out. Basic verification never
        # walks the tree, so it has no enumeration time to report.
        $EnumerateTime = $null,
        $HashTime      = $null
    )
    $sep = '*' * 21
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("File verification run  [$Mode]")
    [void]$lines.Add("Compared against: $CompareRoot")
    [void]$lines.Add("Initial CSV    : $CsvFile")
    if ($Mode -eq 'Comprehensive' -and $RescanCsv) {
        [void]$lines.Add("Rescan CSV     : $RescanCsv")
    }
    if ($ListingDisposition) {
        [void]$lines.Add("Initial listing: $ListingDisposition")
    }
    if ($null -ne $EnumerateTime) {
        [void]$lines.Add("Enumerate      : $(Format-Duration $EnumerateTime)")
    }
    if ($null -ne $HashTime) {
        [void]$lines.Add("Hash time      : $(Format-Duration $HashTime)")
    }
    if ($Mode -eq 'Basic') {
        [void]$lines.Add("Archive-internal entries skipped: $Skipped (informational only)")
    }
    [void]$lines.Add("")
    foreach ($l in $Output) { [void]$lines.Add($l) }

    if ($DifferentFiles -gt 0) {
        # Hash mismatches: one block per file with labelled hashes.
        if ($DifferenceOutput -and $DifferenceOutput.Count -gt 0) {
            [void]$lines.Add("")
            [void]$lines.Add($sep)
            [void]$lines.Add("Hash mismatches:")
            foreach ($d in $DifferenceOutput) {
                [void]$lines.Add("")
                [void]$lines.Add("  File:     $($d.FilePath)")
                [void]$lines.Add("    Original: $($d.Original)")
                [void]$lines.Add("    Computed: $($d.Computed)")
            }
        }
        # Missing files: short recap section.
        if ($MissingFiles -and $MissingFiles.Count -gt 0) {
            [void]$lines.Add("")
            [void]$lines.Add($sep)
            [void]$lines.Add("Missing files:")
            foreach ($p in $MissingFiles) { [void]$lines.Add("  $p") }
        }
        # New files (present in rescan but not in initial): Thorough mode only.
        if ($NewFiles -and $NewFiles.Count -gt 0) {
            [void]$lines.Add("")
            [void]$lines.Add($sep)
            [void]$lines.Add("New files (not in initial listing):")
            foreach ($p in $NewFiles) { [void]$lines.Add("  $p") }
        }
        # Unrecognised hash types: short recap section.
        if ($IncorrectHash -and $IncorrectHash.Count -gt 0) {
            [void]$lines.Add("")
            [void]$lines.Add($sep)
            [void]$lines.Add("Unrecognised hash types:")
            foreach ($p in $IncorrectHash) { [void]$lines.Add("  $p") }
        }
    }
    $lines | Out-File -FilePath $LogFilePath -Encoding utf8
}

function Get-ParallelVerifyStatus {
    # Hashes each CSV row's file in the worker pool and returns one status
    # record per row, in the same order, or $null to say the caller should
    # verify sequentially instead.
    #
    # The verdict is deliberately not made here. Workers report only what they
    # found -- a hash, or that the file was absent -- and the
    # Verified/Different decision stays with the caller, in the one place, so
    # the parallel and sequential paths cannot come to different conclusions.
    param(
        [object[]] $Pairs,
        [Parameter(Mandatory)][string] $CompareRoot
    )
    if ($Parallel -le 1 -or $null -eq $Pairs -or $Pairs.Count -lt 2) { return $null }

    $items    = New-Object System.Collections.Generic.List[object]
    $statuses = [object[]]::new($Pairs.Count)
    for ($i = 0; $i -lt $Pairs.Count; $i++) {
        $hashType = Get-HashType $Pairs[$i].Hash
        if ([string]::IsNullOrWhiteSpace($hashType)) {
            # A hash whose length matches no known algorithm is settled here:
            # there is nothing to tell a worker to compute.
            $statuses[$i] = [pscustomobject]@{ Status = 'BadHashType'; ComputedHash = $null }
            continue
        }
        [void]$items.Add([pscustomobject]@{
            Index     = $i
            RelPath   = $Pairs[$i].FilePath
            FullPath  = (Join-Path $CompareRoot $Pairs[$i].FilePath)
            Algorithm = $hashType
            Expand    = $false
            # A CSV row carries no size, and statting every row here purely to
            # fill a display column would be real work on a large listing. The
            # panel prints '-' and the elapsed clock still answers the question.
            Size      = $null
        })
    }
    if ($items.Count -eq 0) { return $statuses }

    $results = Invoke-ParallelHash -Items $items.ToArray() -ProgressTitle 'Verifying Files'
    if ($null -eq $results) { return $null }

    foreach ($item in $items) {
        $slot = $results[$item.Index]
        foreach ($f in $slot.Failures) { Write-Warning $f }
        if ($slot.Missing) {
            $statuses[$item.Index] = [pscustomobject]@{ Status = 'Missing'; ComputedHash = $null }
        } elseif ($slot.Files.Count -gt 0) {
            $computed = $slot.Files[0].Hash
            $verdict  = if ($computed -eq $Pairs[$item.Index].Hash) { 'Verified' } else { 'Different' }
            $statuses[$item.Index] = [pscustomobject]@{ Status = $verdict; ComputedHash = $computed }
        } else {
            # Present but unreadable. Test-OneEntry's catch calls that Different
            # with no computed hash, so this does the same.
            $statuses[$item.Index] = [pscustomobject]@{ Status = 'Different'; ComputedHash = $null }
        }
    }
    return $statuses
}

function Compare-HashEntry {
    # $KeepInitialListing: intermediate scan -- do not consume the initial CSV
    # and sidecar on a clean pass, so they can verify another destination.
    param([switch] $KeepInitialListing)
    $compareRoot = Resolve-BasePath -PromptDescription "Select the folder to verify against"
    if (-not $compareRoot) { Show-MessageBox "No folder selected. Verification cancelled."; return }

    $csvFile = Search-InitialFileExistence
    if (-not $csvFile) {
        [System.Windows.Forms.MessageBox]::Show(
            "No initial CSV found next to the script.", 'Missing CSV', 'OK', 'Error') | Out-Null
        return
    }
    # Validate CSV integrity before trusting any of its contents.
    if (-not (Test-SidecarFile -CsvPath $csvFile)) { return }

    $pairs = Import-Csv -Path $csvFile -Encoding $script:CsvEncoding

    # Drop any blank rows that crept in from earlier versions.
    $pairs = @($pairs | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.FilePath) -and
        -not [string]::IsNullOrWhiteSpace($_.Hash)
    })

    # Separate archive-internal (skipped) from direct entries.
    $direct  = @($pairs | Where-Object { -not (Test-IsArchiveInternalEntry $_.FilePath) })
    $skipped = $pairs.Count - $direct.Count
    Write-Debug "Direct=$($direct.Count) Skipped=$skipped"

    # Mutable containers (lists + a single object for counters) so the
    # scriptblock passed to Invoke-ProgressLoop can mutate them through
    # method/property access. Using '+=' or '++' on plain locals would
    # silently create scriptblock-local copies and lose all updates --
    # that was the v5.3 bug where the verification log body came out empty.
    $output            = New-Object System.Collections.Generic.List[string]
    $differenceOutput  = New-Object System.Collections.Generic.List[object]   # structured records
    $missingFiles      = New-Object System.Collections.Generic.List[string]   # bare file paths
    $incorrectHash     = New-Object System.Collections.Generic.List[string]   # bare file paths
    $counts = [pscustomobject]@{ Verified = 0; Different = 0; Total = 0 }

    # Both paths classify a result identically, so the classification lives in
    # one scriptblock rather than being written out twice where the two copies
    # could drift. It reads $counts, $output and the three lists from the
    # enclosing scope, which is why those are lists and a [pscustomobject] --
    # see the note above.
    $classify = {
        param([pscustomobject] $Pair, [string] $Status, [string] $ComputedHash)
        $counts.Total++
        switch ($Status) {
            'Verified' {
                [void]$output.Add("Verified  - $($Pair.FilePath)")
                $counts.Verified++
            }
            'Different' {
                [void]$output.Add("Different - $($Pair.FilePath)")
                [void]$differenceOutput.Add([pscustomobject]@{
                    FilePath = $Pair.FilePath
                    Original = $Pair.Hash
                    Computed = $ComputedHash
                })
                $counts.Different++
            }
            'Missing' {
                [void]$output.Add("Missing   - $($Pair.FilePath)")
                [void]$missingFiles.Add($Pair.FilePath)
                $counts.Different++
            }
            'BadHashType' {
                [void]$output.Add("Bad Hash  - $($Pair.FilePath)")
                [void]$incorrectHash.Add($Pair.FilePath)
                $counts.Different++
            }
        }
    }

    # This path walks the CSV rather than the disk, so there is no tree to
    # enumerate and no enumeration time to report. Cleared rather than left
    # alone, so a figure from an earlier run in the same session cannot be
    # picked up and reported as if it belonged to this one.
    $script:LastEnumerateTime = $null
    $hashClock = [System.Diagnostics.Stopwatch]::StartNew()

    # Statuses come back in CSV order regardless of the order the workers
    # finished in, so the verification log reads the same either way.
    $statuses = Get-ParallelVerifyStatus -Pairs $direct -CompareRoot $compareRoot
    if ($null -ne $statuses) {
        for ($i = 0; $i -lt $direct.Count; $i++) {
            & $classify $direct[$i] $statuses[$i].Status $statuses[$i].ComputedHash
        }
    } else {
        Invoke-ProgressLoop -Items $direct -Title 'Verifying Files' `
            -StatusText { param($i,$item) "Processing $i of $($direct.Count):`r`n$($item.FilePath)" } `
            -Body {
                param($pair)
                $r = Test-OneEntry -Pair $pair -CompareRoot $compareRoot
                & $classify $pair $r.Status $r.ComputedHash
            }
    }
    $script:LastHashTime = $hashClock.Elapsed

    $logFilePath = Join-Path (Get-ParentScriptFolder) `
        ((Get-VerificationStamp) +
         (Get-VerificationTag -KeepInitialListing ([bool]$KeepInitialListing)) +
         "-fileverification.log")

    Write-VerificationLog -LogFilePath $logFilePath -CompareRoot $compareRoot -CsvFile $csvFile `
        -Skipped $skipped `
        -Output           $output.ToArray() `
        -DifferenceOutput $differenceOutput.ToArray() `
        -MissingFiles     $missingFiles.ToArray() `
        -IncorrectHash    $incorrectHash.ToArray() `
        -NewFiles         @() `
        -DifferentFiles   $counts.Different `
        -Mode             "Basic" `
        -ListingDisposition (Get-ListingDisposition -CleanPass ($counts.Different -eq 0) `
                                -KeepInitialListing ([bool]$KeepInitialListing)) `
        -EnumerateTime    $script:LastEnumerateTime `
        -HashTime         $script:LastHashTime

    Publish-FileTotal -Verified $counts.Verified -Different $counts.Different -Total $counts.Total `
        -EnumerateTime $script:LastEnumerateTime -HashTime $script:LastHashTime

    Remove-InitialListing -CsvPath $csvFile -CleanPass ($counts.Different -eq 0) `
        -KeepInitialListing:$KeepInitialListing
}

function Remove-InitialListing {
    # Consumes the initial CSV and its sidecar after a clean final scan.
    # Shared by both modes so the retention rule is stated once, in one place,
    # rather than duplicated per mode where the two copies can drift apart.
    param(
        [Parameter(Mandatory)][string] $CsvPath,
        [Parameter(Mandatory)][bool]   $CleanPass,
        [switch] $KeepInitialListing
    )
    if (-not $CleanPass) {
        Write-Debug "Initial listing kept: differences were found."
        return
    }
    if ($KeepInitialListing) {
        Write-Debug "Initial listing kept: intermediate scan."
        return
    }
    # Remove the sidecar WITH the CSV. Deleting only the CSV leaves a stale
    # .sha512 referencing a file that no longer exists.
    Remove-Item -LiteralPath $CsvPath -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Get-SidecarPath $CsvPath) -ErrorAction SilentlyContinue
    Write-Debug "Initial listing consumed (clean final scan): $CsvPath"
}

function Get-VerificationStamp {
    # Seconds, not just minutes, for verification artefacts.
    #
    # The build stamp stays at minute resolution -- one build per folder is the
    # norm. Verification is different: checking several destinations in a row
    # (which is exactly what the intermediate-scan option is for) can easily put
    # two runs in the same minute, and at minute resolution the second silently
    # overwrote the first one's log. Labelling a run intermediate is not much
    # use if the file it names gets replaced by the next run.
    #
    # Seconds go before the tag and suffix, so '*-fileverification.log' and
    # '*-rescan.hashes.csv' still match and the files stay out of later scans.
    return (Get-Date -Format yyyyMMdd_HHmmss)
}

function Get-VerificationTag {
    # Filename infix marking a run as an intermediate verification, so a folder
    # holding several runs shows at a glance which was the final one.
    #
    # It goes BEFORE the "-fileverification.log" / "-rescan.hashes.csv" suffix,
    # not after the dot, because $script:ScriptOutputPatterns matches on those
    # exact suffixes to keep the script's own output from being picked up as
    # data on a later scan. "...-intermediate.fileverification.log" would not
    # match '*-fileverification.log' -- the pattern needs the dash -- and the
    # file would then be hashed into the next listing as if it were payload.
    param([bool] $KeepInitialListing)
    if ($KeepInitialListing) { return '-intermediate' }
    return ''
}

function Get-ListingDisposition {
    # One line for the verification log recording what happened to the listing.
    param([bool] $CleanPass, [bool] $KeepInitialListing)
    if (-not $CleanPass)      { return 'kept (differences found)' }
    if ($KeepInitialListing)  { return 'kept (intermediate scan)' }
    return 'consumed (clean final scan)'
}

# =====================================================================
#  Thorough verification
#  Re-scans the chosen folder completely (same as initial build),
#  writes a second CSV, then diffs the two CSVs by FilePath key.
# =====================================================================

function Compare-HashEntryThorough {
    # $KeepInitialListing: see Compare-HashEntry. Comprehensive honours this
    # exactly as Basic does, so the two modes cannot disagree about when the
    # initial listing is consumed. The rescan CSV is always kept either way, as
    # the record of what was actually found.
    param([switch] $KeepInitialListing)
    $compareRoot = Resolve-BasePath -PromptDescription "Select the folder to verify against (Comprehensive)"
    if (-not $compareRoot) { Show-MessageBox "No folder selected. Verification cancelled."; return }

    $initialCsvFile = Search-InitialFileExistence
    if (-not $initialCsvFile) {
        [System.Windows.Forms.MessageBox]::Show(
            "No initial CSV found next to the script.", "Missing CSV", "OK", "Error") | Out-Null
        return
    }

    # Validate CSV integrity before trusting any of its contents.
    if (-not (Test-SidecarFile -CsvPath $initialCsvFile)) { return }

    # Load initial CSV, drop any blank rows from older script versions.
    $initialPairs = @(Import-Csv -Path $initialCsvFile -Encoding $script:CsvEncoding | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.FilePath) -and
        -not [string]::IsNullOrWhiteSpace($_.Hash)
    })

    # Run a full scan of the target folder — same engine as initial build.
    $script:ArchiveWarnings.Clear()
    $rescanList = Invoke-FileScan -ScanRoot $compareRoot -ProgressTitle "Comprehensive Verification Scan"

    # One stamp for both the rescan CSV and the log below. They used to call
    # Get-Date separately, so a run crossing a minute boundary produced a pair
    # of files whose names disagreed about when the run happened.
    $runStamp = Get-VerificationStamp
    $runTag   = Get-VerificationTag -KeepInitialListing ([bool]$KeepInitialListing)

    # Save rescan to a dated CSV.
    $rescanCsvPath = Join-Path (Get-ParentScriptFolder) `
        ($runStamp + $runTag + "-rescan.hashes.csv")
    $rescanList | Export-Csv -Path $rescanCsvPath -NoTypeInformation -Encoding $script:CsvEncoding

    # Build lookup tables keyed on FilePath for O(1) diff.
    # PowerShell hashtables are case-insensitive, so two entries differing only
    # by case silently collapse into one and the survivor's hash wins. That is
    # correct for NTFS but would hide a genuine duplicate, so report it.
    $initialLookup = @{}
    foreach ($p in $initialPairs) {
        if ($initialLookup.ContainsKey($p.FilePath)) {
            Write-Warning "Duplicate path in initial CSV (last one wins): $($p.FilePath)"
        }
        $initialLookup[$p.FilePath] = $p.Hash
    }
    $rescanLookup  = @{}
    foreach ($p in $rescanList) {
        if ($rescanLookup.ContainsKey($p.FilePath)) {
            Write-Warning "Duplicate path in rescan (last one wins): $($p.FilePath)"
        }
        $rescanLookup[$p.FilePath] = $p.Hash
    }

    $output           = New-Object System.Collections.Generic.List[string]
    $differenceOutput = New-Object System.Collections.Generic.List[object]
    $missingFiles     = New-Object System.Collections.Generic.List[string]
    $newFiles         = New-Object System.Collections.Generic.List[string]
    $incorrectHash    = New-Object System.Collections.Generic.List[string]
    $counts = [pscustomobject]@{ Verified = 0; Different = 0; Total = 0 }

    # Entries in initial: Verified / Different / Missing.
    foreach ($path in ($initialLookup.Keys | Sort-Object)) {
        $counts.Total++
        $origHash = $initialLookup[$path]
        $hashType = Get-HashType $origHash
        if ([string]::IsNullOrWhiteSpace($hashType)) {
            [void]$output.Add("Bad Hash  - $path")
            [void]$incorrectHash.Add($path)
            $counts.Different++
        } elseif (-not $rescanLookup.ContainsKey($path)) {
            [void]$output.Add("Missing   - $path")
            [void]$missingFiles.Add($path)
            $counts.Different++
        } elseif ($rescanLookup[$path] -eq $origHash) {
            [void]$output.Add("Verified  - $path")
            $counts.Verified++
        } else {
            [void]$output.Add("Different - $path")
            [void]$differenceOutput.Add([pscustomobject]@{
                FilePath = $path
                Original = $origHash
                Computed = $rescanLookup[$path]
            })
            $counts.Different++
        }
    }

    # Entries only in the destination.
    #
    # These are DISCARDED from the comparison by default. The destination may
    # legitimately already hold unrelated data -- a patching folder being topped
    # up, for example -- and pre-existing content is not evidence that the
    # transfer went wrong. Only what existed at the source is compared, which
    # also makes Comprehensive agree with Basic (Basic walks the CSV, so it has
    # always ignored extras).
    #
    # -ReportExtraFiles restores the old behaviour for the burn-to-disc case,
    # where an unexpected file on the destination is itself a finding.
    $extraCount = 0
    foreach ($path in ($rescanLookup.Keys | Sort-Object)) {
        if (-not $initialLookup.ContainsKey($path)) {
            $extraCount++
            if ($ReportExtraFiles) {
                [void]$output.Add("New       - $path")
                [void]$newFiles.Add($path)
                $counts.Different++
                $counts.Total++
            }
        }
    }
    Write-Debug "Extra files in destination: $extraCount (reported=$ReportExtraFiles)"

    # Compare like with like: when extras are discarded the raw rescan total is
    # not a meaningful counterpart to the source total, so net them out.
    $comparableRescanCount = if ($ReportExtraFiles) { $rescanList.Count }
                             else { $rescanList.Count - $extraCount }
    $countDelta = $comparableRescanCount - $initialPairs.Count

    $logFilePath = Join-Path (Get-ParentScriptFolder) `
        ($runStamp + $runTag + "-fileverification.log")

    # Prepend the count summary to the output list before writing.
    $countLine = "Entry count: initial=$($initialPairs.Count)  rescan=$comparableRescanCount  delta=$(if($countDelta -ge 0){"+$countDelta"}else{"$countDelta"})"
    $header = New-Object System.Collections.Generic.List[string]
    [void]$header.Add($countLine)
    if (-not $ReportExtraFiles -and $extraCount -gt 0) {
        # Report the count, never the list: a patching folder can hold tens of
        # thousands of unrelated files and enumerating them would bury the log.
        [void]$header.Add("Destination also holds $extraCount file(s) not in the initial " +
                          "listing; discarded (use -ReportExtraFiles to list them).")
    }
    [void]$header.Add("")
    $outputArr = $header.ToArray() + $output.ToArray()

    Write-VerificationLog `
        -LogFilePath      $logFilePath `
        -CompareRoot      $compareRoot `
        -CsvFile          $initialCsvFile `
        -Skipped          0 `
        -Output           $outputArr `
        -DifferenceOutput $differenceOutput.ToArray() `
        -MissingFiles     $missingFiles.ToArray() `
        -IncorrectHash    $incorrectHash.ToArray() `
        -NewFiles         $newFiles.ToArray() `
        -DifferentFiles   $counts.Different `
        -Mode             "Comprehensive" `
        -RescanCsv        $rescanCsvPath `
        -ListingDisposition (Get-ListingDisposition -CleanPass ($counts.Different -eq 0) `
                                -KeepInitialListing ([bool]$KeepInitialListing)) `
        -EnumerateTime    $script:LastEnumerateTime `
        -HashTime         $script:LastHashTime

    Publish-FileTotal -Verified $counts.Verified -Different $counts.Different -Total $counts.Total `
        -EnumerateTime $script:LastEnumerateTime -HashTime $script:LastHashTime

    # The rescan CSV is always kept -- it is the record of what was actually
    # found at the destination. The initial listing follows the same rule as
    # Basic: consumed only on a clean final scan.
    Remove-InitialListing -CsvPath $initialCsvFile -CleanPass ($counts.Different -eq 0) `
        -KeepInitialListing:$KeepInitialListing

    if ($script:ArchiveWarnings.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Comprehensive scan completed.`r`n" +
            "Differences: $($counts.Different)`r`n" +
            "Archive warnings: $($script:ArchiveWarnings.Count) (see log).",
            "Verification Complete", "OK", "Warning") | Out-Null
    }
}

# =====================================================================
#  Mode-selection dialog  (shown when a verification run starts)
# =====================================================================

function Select-VerificationMode {
    # Returns @{ Mode; KeepListing }. Mode is 'Basic', 'Comprehensive', or
    # $null when cancelled. KeepListing is the intermediate-scan checkbox.
    $form = New-FormControl Form @{
        Text = 'Select Verification Mode'
        Size = (New-Sz 450 320)
        StartPosition = 'CenterScreen'
    }

    $standardRb = New-FormControl RadioButton @{
        Location = (New-Pt 15 15); Size = (New-Sz 380 20)
        Text = 'Basic'; Checked = $true
    }
    $thoroughRb = New-FormControl RadioButton @{
        Location = (New-Pt 15 40); Size = (New-Sz 380 20)
        Text = 'Comprehensive'
    }

    $descLabel = New-FormControl Label @{
        Location = (New-Pt 15 68); Size = (New-Sz 400 84)
        Text = "Archives are compared as opaque files. Internal " +
               "entries from the initial listing are skipped. Fast."
    }

    $basicDesc = "Archives are compared as opaque files. Internal " +
                 "entries from the initial listing are skipped. Fast."
    $comprehensiveDesc = if ($ReportExtraFiles) {
        "Re-scans the folder completely, enumerating archive contents, then " +
        "diffs both full listings. Detects removed and altered files, and " +
        "flags files present here but not in the initial listing. " +
        "The rescan CSV is always kept."
    } else {
        "Re-scans the folder completely, enumerating archive contents, then " +
        "diffs both full listings. Detects removed and altered files, " +
        "including inside archives. Files already in this folder that were " +
        "not in the initial listing are ignored. The rescan CSV is always kept."
    }

    $standardRb.Add_CheckedChanged({
        if ($standardRb.Checked) { $descLabel.Text = $basicDesc }
    })
    $thoroughRb.Add_CheckedChanged({
        if ($thoroughRb.Checked) { $descLabel.Text = $comprehensiveDesc }
    })

    # Intermediate-scan checkbox.
    #
    # On a clean pass the initial CSV and its .sha512 are consumed, because the
    # listing has done its job and leaving it behind means the next run picks it
    # up again. That is wrong when the same listing has to verify more than one
    # destination -- a staging hop, or several copies of the same media. Tick
    # this and a clean pass leaves the listing in place for the next one.
    #
    # Unchecked (a final scan) is the default, so the behaviour is unchanged
    # unless the box is ticked. Nothing is ever deleted when differences were
    # found, in either state.
    $keepCb = New-FormControl CheckBox @{
        Location = (New-Pt 15 158); Size = (New-Sz 400 20)
        Text = 'Intermediate scan - keep the initial listing'; Checked = $false
    }
    $keepDesc = New-FormControl Label @{
        Location = (New-Pt 32 180); Size = (New-Sz 390 46)
        Text = "Ticked: a clean pass keeps the initial CSV and .sha512 so they can " +
               "verify another destination. Unticked (final scan): a clean pass " +
               "deletes them. Differences always keep everything."
    }

    $script:verifyMode   = $null
    $script:verifyKeep   = $false

    $okBtn = New-FormControl Button @{
        Location = (New-Pt 95 240); Size = (New-Sz 100 28); Text = 'Continue'
    }
    $cancelBtn = New-FormControl Button @{
        Location = (New-Pt 210 240); Size = (New-Sz 100 28); Text = 'Cancel'
    }
    $okBtn.Add_Click({
        $script:verifyMode = if ($thoroughRb.Checked) { 'Comprehensive' } else { 'Basic' }
        $script:verifyKeep = $keepCb.Checked
        $form.Close()
    })
    $cancelBtn.Add_Click({ $form.Close() })

    $form.Controls.AddRange(@($standardRb, $thoroughRb, $descLabel, $keepCb, $keepDesc, $okBtn, $cancelBtn))
    try { $form.ShowDialog() | Out-Null } finally { $form.Dispose() }
    # Mode is $null when cancelled.
    return [pscustomobject]@{ Mode = $script:verifyMode; KeepListing = $script:verifyKeep }
}

# =====================================================================
#  Totals form
# =====================================================================

function Publish-FileTotal {
    param(
        [Parameter(Mandatory)][int] $Verified,
        [Parameter(Mandatory)][int] $Different,
        [Parameter(Mandatory)][int] $Total,
        # TimeSpans, or $null to leave the timing line off the form entirely.
        $EnumerateTime = $null,
        $HashTime      = $null
    )

    $form = New-FormControl Form @{
        Text='File Verification'; Size=(New-Sz 300 200); StartPosition='CenterScreen'
    }

    $columns = @(
        @{ X=10;  Title='Verified Files';  Value=$Verified  },
        @{ X=100; Title='Different Files'; Value=$Different },
        @{ X=190; Title='Total Files';     Value=$Total     }
    )
    foreach ($c in $columns) {
        $h = New-FormControl Label @{ Location=(New-Pt $c.X 20); Size=(New-Sz 75 20); Text=$c.Title }
        $h.Font = New-Object System.Drawing.Font($h.Font, [System.Drawing.FontStyle]::Underline)
        $form.Controls.Add($h)
        $form.Controls.Add(
            (New-FormControl Label @{ Location=(New-Pt $c.X 50); Size=(New-Sz 75 20); Text=[string]$c.Value }))
    }

    # Sits in the gap between the counts and the Close button, so the form does
    # not need to grow. Left off entirely when there is no timing to show.
    if ($null -ne $HashTime) {
        $timing = "Hash time: $(Format-Duration $HashTime)"
        if ($null -ne $EnumerateTime) {
            $timing += "   (enumerate: $(Format-Duration $EnumerateTime))"
        }
        $form.Controls.Add(
            (New-FormControl Label @{ Location=(New-Pt 10 88); Size=(New-Sz 270 20); Text=$timing }))
    }

    $closeBtn = New-FormControl Button @{
        Location=(New-Pt 100 120); Size=(New-Sz 100 23); Text='Close'
    }
    $closeBtn.Add_Click({ $form.Close() })
    $form.Controls.Add($closeBtn)

    try { $form.ShowDialog() | Out-Null } finally { $form.Dispose() }
}

# =====================================================================
#  Worker entry point
#
#  A child process started by Start-HashWorkerPool lands here and never
#  reaches Main: no dialogs, no scan, no output files, nothing written
#  to disk at all. Everything above this point is either a function
#  definition or a variable, so the whole toolset is available by now.
# =====================================================================

if ($HashWorker) {
    Invoke-HashWorker
    if ($script:Sha512) { $script:Sha512.Dispose() }
    exit 0
}

# =====================================================================
#  Main
# =====================================================================

$initialFile = Search-InitialFileExistence
Write-Debug "Initial File [Main]: $initialFile"

# Search-InitialFileExistence returns a path or $false. Comparing a string to
# $false coerces the boolean to "False" and happens to work; test truthiness.
if ($initialFile) {
    # Integrity gate, before any workflow UI is shown.
    #
    # This can run first because nothing the user picks later affects which
    # files are checked: Search-InitialFileExistence looks in the script's own
    # folder, and the .sha512 sits beside the CSV there. The folder picker in
    # the Compare-* functions chooses the DATA folder to verify against, which
    # is a different location and irrelevant to this check.
    #
    # So a tampered script or a corrupted listing is now reported immediately,
    # instead of after the user has picked a mode and browsed to a folder.
    #
    # Note this is a fail-fast integrity check, not a security boundary: a
    # script that has actually been modified could simply remove this code. To
    # genuinely establish that the .ps1 is untouched, check it from outside
    # against the burned .sha512 before running it.
    if (Test-SidecarFile -CsvPath $initialFile) {
        $choice = Select-VerificationMode
        if ($choice.Mode -eq 'Comprehensive') {
            Compare-HashEntryThorough -KeepInitialListing:$choice.KeepListing
        } elseif ($choice.Mode -eq 'Basic') {
            Compare-HashEntry -KeepInitialListing:$choice.KeepListing
        }
        # $null = user cancelled; do nothing.
    }
} else {
    $form = New-FormControl Form @{
        Text='Build Initial Listing'; Size=(New-Sz 370 200); StartPosition='CenterScreen'
    }
    $label = New-FormControl Label @{
        Location=(New-Pt 10 20); Size=(New-Sz 290 40); Text='How to build initial listing:'
    }
    $autoBtn = New-FormControl Button @{
        Location=(New-Pt 10 70); Size=(New-Sz 150 23); Text='Automatic'
    }
    $manBtn = New-FormControl Button @{
        Location=(New-Pt 190 70); Size=(New-Sz 150 23); Text='Manual'
    }
    $helpBtn = New-FormControl Button @{
        Location=(New-Pt 310 10); Size=(New-Sz 30 23); Text='?'
    }

    $autoBtn.Add_Click({ $form.Hide(); Set-InitialFileAutomatic; $form.Close() })
    $manBtn.Add_Click({  $form.Hide(); Set-InitialFileManual;    $form.Close() })
    $helpBtn.Add_Click({
        Show-MessageBox @"
Choose how to build the initial listing:

  Automatic: You will be prompted for a base folder — the folder that is
             going to be burned or transferred.

             The script copies ITSELF into that folder first, then writes
             the CSV, the .sha512 sidecar, and the manifest next to that
             copy. Nothing is added to the folder you ran the script from.
             Burn or copy the whole folder and the verification tooling
             travels with the data — there is nothing to remember to
             bring along, and running the copied script at the
             destination starts verification automatically.

             It will recursively hash every file under the folder. For
             .zip, .tar, .tar.gz, .tgz, and .iso files, the archive
             itself is hashed AND its contents are enumerated
             (archive.zip\file.ext).

             For ISOs, AutoPlay is temporarily disabled (HKCU only,
             no admin needed) so File Explorer does not pop open.
             Mounting an ISO does not require elevation on client
             Windows; elevation is only reported if a mount fails.

             You will be asked to name the manifest (the readable
             listing of every file). The box is prefilled with
             Filelist-<scanned folder>.txt and can be edited freely;
             .txt is added if you leave off an extension. The CSV and
             .sha512 always keep their timestamped names.

  Manual:    You will manually enter each file and its hash.

Verification compares only what existed at the source. Files already
present in the destination that were not in the initial listing are
ignored, so verifying into a folder that already holds data (a patching
folder) does not report them as differences.

CLI arguments:
  -DebugMode              Enable debug output + transcript.
  -BasePath <folder>      Skip the folder picker.
  -SkipArchiveContents    Hash archives only as opaque files.
  -ReportExtraFiles       Comprehensive mode: flag destination files that
                          were not in the initial listing as differences.
  -IncludeSystemFiles     Hash the volume's housekeeping files too:
                          System Volume Information, $RECYCLE.BIN,
                          Thumbs.db, desktop.ini, .DS_Store and the
                          like. Skipped by default.
  -Parallel <n>           How many child processes hash files at once.
                          Default: 4, or the CPU count if that is lower.
                          1 hashes in this process only -- use it for
                          optical discs and network shares, where several
                          concurrent readers are slower, not faster.
"@
    })

    $form.Controls.AddRange(@($label, $autoBtn, $manBtn, $helpBtn))
    try { $form.ShowDialog() | Out-Null } finally { $form.Dispose() }
}

# Belt and braces. A pool cannot normally outlive Invoke-ParallelHash, which
# tears its own down in a finally, but a worker process left running would be
# invisible and would accumulate one per run, so check here as well.
if ($script:ActiveWorkerPool) { Stop-HashWorkerPool -Workers $script:ActiveWorkerPool }

if ($script:Sha512) { $script:Sha512.Dispose() }

if ($DebugMode) {
    try { Stop-Transcript | Out-Null } catch { Write-Debug "Stop-Transcript failed (non-fatal): $_" }
}
