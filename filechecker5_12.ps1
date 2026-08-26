<#
    Robert Stepp, robert@robertstepp.ninja

    File Checker v5.12

    Usage:
        powershell -File filechecker5_12.ps1
        powershell -File filechecker5_12.ps1 -DebugMode
        powershell -File filechecker5_12.ps1 -BasePath "D:\Transfer"
        powershell -File filechecker5_12.ps1 -DebugMode -SkipArchiveContents

    Changes from v5.11:
      * Fixed: AutoPlay suppression used non-terminating registry calls, so on a
        machine where the HKCU Policies key is locked down the raw errors leaked
        to the console for every ISO instead of being caught. This was the
        "extra error" seen while the ISO still mounted, read, and unmounted.
      * Fixed: a spurious "Not running as admin" archive warning was raised for
        every ISO before the mount was even attempted, so a perfectly successful
        mount/read/dismount still reported a warning. The admin state is now only
        mentioned if the mount actually fails.
      * Fixed: Manual mode wrote a CSV but no .sha512 sidecar, so the verification
        it launched immediately hard-blocked on "No integrity sidecar found".
      * Fixed: a clean Basic verification deleted the CSV but orphaned its sidecar.
      * Changed: Comprehensive mode now discards destination files that were not
        in the initial listing, instead of counting them as differences. Only
        what existed at the source is compared, so verifying into a folder that
        already holds unrelated data (a patching folder) no longer reports it as
        a difference. -ReportExtraFiles restores the previous behaviour. Basic
        mode already worked this way, so the two modes now agree.
      * Changed: the initial build now copies the script into the folder being
        transferred and writes the CSV, sidecar, and manifest next to that copy.
        The folder the script was run from gets nothing added to it (except
        debug.log under -DebugMode, which starts before the folder is chosen).
        Previously all three landed beside the script, so if the script lived
        outside the transfer folder they had to be moved across by hand -- a
        step that gets forgotten, leaving a transfer that cannot be verified.
        The script is copied before the scan, so it is hashed into the listing
        and verified like any other transferred file.
      * Fixed: the folder picker set RootFolder = MyComputer, which roots the
        legacy tree at This PC -- Desktop, Documents and the other Libraries sit
        above This PC in the shell namespace and were unreachable. RootFolder is
        no longer set, the modern shell dialog is used where the host runtime
        has it, and picking a Library (which has no path on disk) now explains
        itself and re-prompts instead of reporting "No folder selected".
      * Changed: the sidecar integrity check (script + CSV) now runs at startup,
        before any workflow dialog. It previously ran after the mode dialog AND
        the folder picker, so a tampered script was only reported once the user
        had answered two prompts. The check never depended on either answer --
        the CSV and .sha512 always sit next to the script, while the folder
        picker chooses the data folder to compare against.
      * Added: an intermediate verification run tags its output filenames --
        "<stamp>-intermediate-fileverification.log" and, in Comprehensive mode,
        "<stamp>-intermediate-rescan.hashes.csv". A final scan is untagged, as
        before. Verification stamps also gained seconds, so back-to-back runs
        against several destinations no longer overwrite each other.
      * Added: "Intermediate scan - keep the initial listing" checkbox on the
        verification mode dialog. On a clean pass the initial CSV and .sha512 are
        consumed; tick this to keep them so the same listing can verify another
        destination. Both modes now honour one shared retention rule -- v5.11 had
        it hardcoded in Basic, absent from Comprehensive, and documented by two
        contradictory comments. Comprehensive therefore now consumes the initial
        listing on a clean final scan, where before it never did. The rescan CSV
        is always kept, and nothing is deleted when differences were found.
      * Added: choice of manifest filename - timestamped (original) or
        Filelist-<scanned folder>.txt.
      * The manifest header counts folders; the listing itself is files only,
        since every folder holding a file is already its path prefix there.
      * Faster scanning: one reusable hash provider, buffered sequential reads,
        and a throttled progress UI instead of a full repaint per file.
#>

#Requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Internal helper functions in a standalone script; ShouldProcess/-WhatIf would add boilerplate with no user benefit.')]
param(
    [switch] $DebugMode,
    [string] $BasePath,
    [switch] $SkipArchiveContents,
    # Comprehensive mode discards destination files that were not in the initial
    # listing. Set this to flag them as differences instead (burn-to-disc case,
    # where an unexpected file on the destination is itself a finding).
    [switch] $ReportExtraFiles
)

$DebugPreference = if ($DebugMode) { 'Continue' } else { 'SilentlyContinue' }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$hashTypes = [ordered]@{ SHA1 = 40; SHA256 = 64; SHA384 = 96; SHA512 = 128; MD5 = 32 }

# .tar.gz first so EndsWith picks the longer match.
$archiveExtensions = @('.tar.gz', '.tgz', '.zip', '.tar', '.iso')

# Collected during initial build; written into the manifest log.
$script:ArchiveWarnings = New-Object System.Collections.Generic.List[string]

# Folders seen by the most recent Invoke-FileScan. Manifest listing only --
# folders have no hash and never enter the CSV or the comparison.
$script:LastScanFolders = New-Object System.Collections.Generic.List[string]

# WinForms requires a single-threaded apartment. Windows PowerShell 5.1 starts
# STA by default; pwsh 7 does not always, and ShowDialog misbehaves under MTA.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
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

# Start transcript only after script folder is known.
if ($DebugMode) {
    try { Start-Transcript -Path (Join-Path (Get-ParentScriptFolder) 'debug.log') -Append | Out-Null }
    catch { Write-Warning "Could not start transcript: $_" }
}
Write-Debug "DebugMode=$DebugMode  BasePath=$BasePath  SkipArchiveContents=$SkipArchiveContents"

function Search-InitialFileExistence {
    # Sort descending so the newest timestamped CSV wins deterministically.
    # Get-ChildItem's own order is filesystem-dependent, which meant that with
    # two listings present the script could silently verify against the older.
    $matches = @(Get-ChildItem -Path (Get-ParentScriptFolder) -Filter "*-initial.hashes.csv" `
                    -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($matches.Count -eq 0) { return $false }
    if ($matches.Count -gt 1) {
        Write-Warning "$($matches.Count) initial CSVs found; using the newest: $($matches[0].Name)"
    }
    return $matches[0].FullName
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

function New-ProgressUI {
    param([string] $Title, [int] $Max)
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
    $form.Controls.Add($bar)
    $form.Controls.Add($label)
    $form.Show(); $form.Refresh()
    return [pscustomobject]@{
        Form  = $form
        Bar   = $bar
        Label = $label
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
    if (-not $Force -and $Ui.Clock.ElapsedMilliseconds -lt 80) { return }
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
    # v5.12 fix: every registry call here now uses -ErrorAction Stop.
    #
    # Without it these are NON-TERMINATING errors. They do not trigger the
    # catch, so the "Could not suppress AutoPlay" warning never fired and the
    # raw ErrorRecords were written straight to the error stream instead. On any
    # machine where HKCU\...\CurrentVersion\Policies is ACL-locked (Group Policy
    # managed desktops, which is common) that printed two red errors for every
    # single ISO, even though the mount/read/dismount all succeeded afterwards.
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
    # NOTE (v5.12): this used to raise an archive warning up front whenever the
    # session was not elevated. Mounting an ISO does not require elevation on
    # client SKUs, so every ISO on a normal desktop produced a warning in the
    # console and the manifest -- and a "Archive warnings: 1" popup -- while the
    # mount, read, and dismount all succeeded. The elevation state is now only
    # reported if the mount actually fails, where it is a real diagnostic.
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
    'Filelist-*.txt',          # v5.12 manifest naming option
    'debug.log'
)

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
    # Memoising wrapper. As of v5.12 Main runs this before any workflow UI, and
    # the Compare-* functions still call it as a safety net -- without the cache
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
    # v5.12 edit did) is only correct while the two sit together -- if the CSV
    # ever lives elsewhere, the .ps1 would not be found there and the run would
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

    $files  = @(Get-ChildItem -Path $ScanRoot -File -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-IsScriptOutput $_.Name) })
    $result = New-Object System.Collections.Generic.List[object]

    # Folders are recorded separately for the manifest listing only. They have
    # no hash, so they never enter the CSV or the comparison.
    $script:LastScanFolders = New-Object System.Collections.Generic.List[string]
    foreach ($d in (Get-ChildItem -Path $ScanRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue)) {
        [void]$script:LastScanFolders.Add($d.FullName.Substring($rootPrefix.Length).TrimStart('\','/'))
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
    return $result
}

# =====================================================================
#  Initial file builders
# =====================================================================

function Select-ManifestNaming {
    # Returns 'Timestamp' (original convention) or 'Filelist'.
    # Only the human-readable manifest is affected -- the CSV and its .sha512
    # keep their timestamped names, because verification finds the CSV by the
    # '*-initial.hashes.csv' glob and pairs the sidecar off that exact name.
    param([Parameter(Mandatory)][string] $TimestampName,
          [Parameter(Mandatory)][string] $FilelistName)

    $form = New-FormControl Form @{
        Text = 'Manifest File Name'; Size = (New-Sz 470 260); StartPosition = 'CenterScreen'
    }
    $label = New-FormControl Label @{
        Location = (New-Pt 15 12); Size = (New-Sz 420 20)
        Text = 'Choose the filename for the manifest (the readable file listing):'
    }
    $stampRb = New-FormControl RadioButton @{
        Location = (New-Pt 15 40); Size = (New-Sz 420 20)
        Text = "Timestamped:  $TimestampName"; Checked = $true
    }
    $listRb = New-FormControl RadioButton @{
        Location = (New-Pt 15 65); Size = (New-Sz 420 20)
        Text = "Folder name:  $FilelistName"
    }
    $descLabel = New-FormControl Label @{
        Location = (New-Pt 32 92); Size = (New-Sz 400 70)
    }
    $stampDesc = "The original convention. Sorts chronologically and never " +
                 "collides, so repeated runs against the same folder each keep " +
                 "their own manifest."
    $listDesc  = "Named after the folder that was scanned. Easier to identify at " +
                 "a glance. A repeat run of the same folder is saved as " +
                 "_2, _3, ... rather than overwriting."
    $descLabel.Text = $stampDesc

    $stampRb.Add_CheckedChanged({ if ($stampRb.Checked) { $descLabel.Text = $stampDesc } })
    $listRb.Add_CheckedChanged({  if ($listRb.Checked)  { $descLabel.Text = $listDesc  } })

    $script:manifestNaming = 'Timestamp'
    $okBtn = New-FormControl Button @{
        Location = (New-Pt 175 180); Size = (New-Sz 100 28); Text = 'Continue'
    }
    $okBtn.Add_Click({
        $script:manifestNaming = if ($listRb.Checked) { 'Filelist' } else { 'Timestamp' }
        $form.Close()
    })
    $form.AcceptButton = $okBtn
    $form.Controls.AddRange(@($label, $stampRb, $listRb, $descLabel, $okBtn))
    try { $form.ShowDialog() | Out-Null } finally { $form.Dispose() }
    return $script:manifestNaming
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

    # Manifest name: original timestamped convention, or Filelist-<folder>.txt.
    $timestampManifestName = $stamp + "-initial.manifest.log"
    $filelistManifestName  = "Filelist-$(Get-ScanFolderLabel $scanRoot).txt"
    $naming = Select-ManifestNaming -TimestampName $timestampManifestName `
                                    -FilelistName  $filelistManifestName
    $manifestLog = if ($naming -eq 'Filelist') {
        Get-NonCollidingPath (Join-Path $outputDir $filelistManifestName)
    } else {
        Join-Path $outputDir $timestampManifestName
    }
    Write-Debug "Manifest naming=$naming -> $manifestLog"

    # Bare filenames for the manifest listing (the files to burn).
    $csvName     = Split-Path -Leaf $csvPath
    $sidecarName = Split-Path -Leaf $sidecarPath

    $script:ArchiveWarnings.Clear()
    $output = Invoke-FileScan -ScanRoot $scanRoot -ProgressTitle 'Building Initial Hash Listing'

    if ($output.Count -eq 0) {
        Show-MessageBox "No files were found under '$scanRoot'. Nothing was written."
        return
    }

    $output | Export-Csv -Path $csvPath -NoTypeInformation

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
    [void]$lines.Add("Entries   : $($output.Count)")
    [void]$lines.Add("Skip arc. : $SkipArchiveContents")
    [void]$lines.Add("Folders   : $($script:LastScanFolders.Count)")
    [void]$lines.Add("")

    # Folders are counted in the header but not listed: every folder that holds
    # a file already appears as that file's path prefix in the listing below, so
    # a separate section just repeats the same information. (The count is the
    # only trace of a folder that contains no files at all.)
    [void]$lines.Add(("=" * 21))
    [void]$lines.Add("Files:")
    foreach ($e in $output) {
        [void]$lines.Add("  $($e.FilePath)")
    }
    [void]$lines.Add("")
    [void]$lines.Add(("=" * 21))
    # Only the two files that are written after the scan and are therefore NOT
    # in the listing above. Deliberately excluded:
    #   - this manifest, which is the file being read (self-referential), and
    #   - the script, which was copied in before the scan and so already appears
    #     in the listing above and is verified like any other transferred file.
    # Both are still written into the transfer folder; they just do not need
    # calling out as something to carry across.
    [void]$lines.Add("Transfer files (written after the scan, so not in the listing above):")
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

    # v5.11 wrote the CSV but never wrote a sidecar, so the verification run
    # started two lines below always hard-blocked on "No integrity sidecar
    # found" and Manual mode could not complete end to end.
    if (@($script:output).Count -eq 0) {
        Show-MessageBox "No file/hash pairs were entered. Nothing was written."
        return
    }
    $manualCsv = Initialize-InitialFilePath
    $script:output | Export-Csv -Path $manualCsv -NoTypeInformation
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
        [string] $ListingDisposition = ''   # what happened to the initial CSV
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

    $pairs = Import-Csv -Path $csvFile

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

    Invoke-ProgressLoop -Items $direct -Title 'Verifying Files' `
        -StatusText { param($i,$item) "Processing $i of $($direct.Count):`r`n$($item.FilePath)" } `
        -Body {
            param($pair)
            $r = Test-OneEntry -Pair $pair -CompareRoot $compareRoot
            $counts.Total++
            switch ($r.Status) {
                'Verified' {
                    [void]$output.Add("Verified  - $($pair.FilePath)")
                    $counts.Verified++
                }
                'Different' {
                    [void]$output.Add("Different - $($pair.FilePath)")
                    [void]$differenceOutput.Add([pscustomobject]@{
                        FilePath = $pair.FilePath
                        Original = $pair.Hash
                        Computed = $r.ComputedHash
                    })
                    $counts.Different++
                }
                'Missing' {
                    [void]$output.Add("Missing   - $($pair.FilePath)")
                    [void]$missingFiles.Add($pair.FilePath)
                    $counts.Different++
                }
                'BadHashType' {
                    [void]$output.Add("Bad Hash  - $($pair.FilePath)")
                    [void]$incorrectHash.Add($pair.FilePath)
                    $counts.Different++
                }
            }
        }

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
                                -KeepInitialListing ([bool]$KeepInitialListing))

    Publish-FileTotal -Verified $counts.Verified -Different $counts.Different -Total $counts.Total

    Remove-InitialListing -CsvPath $csvFile -CleanPass ($counts.Different -eq 0) `
        -KeepInitialListing:$KeepInitialListing
}

function Remove-InitialListing {
    # Consumes the initial CSV and its sidecar after a clean final scan.
    # Shared by both modes so the retention rule is stated once. v5.11 had this
    # hardcoded in Basic, absent from Comprehensive, and described by two
    # contradictory comments -- the rule was never actually pinned down.
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
    # Remove the sidecar with the CSV. v5.11 deleted only the CSV, leaving a
    # stale .sha512 that referenced a file that no longer existed.
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
    # $KeepInitialListing: see Compare-HashEntry. As of v5.12 Comprehensive
    # honours this too -- it previously never consumed the initial listing,
    # which made the two modes disagree for no stated reason. The rescan CSV
    # is always kept either way, as the record of what was actually found.
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
    $initialPairs = @(Import-Csv -Path $initialCsvFile | Where-Object {
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
    $rescanList | Export-Csv -Path $rescanCsvPath -NoTypeInformation

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
                                -KeepInitialListing ([bool]$KeepInitialListing))

    Publish-FileTotal -Verified $counts.Verified -Different $counts.Different -Total $counts.Total

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
        [Parameter(Mandatory)][int] $Total
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

    $closeBtn = New-FormControl Button @{
        Location=(New-Pt 100 120); Size=(New-Sz 100 23); Text='Close'
    }
    $closeBtn.Add_Click({ $form.Close() })
    $form.Controls.Add($closeBtn)

    try { $form.ShowDialog() | Out-Null } finally { $form.Dispose() }
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

             You will be asked how to name the manifest (the readable
             listing of every folder and file):
               20260825_1430-initial.manifest.log   (timestamped)
               Filelist-<scanned folder>.txt        (folder name)
             The CSV and .sha512 keep their timestamped names either way.

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
"@
    })

    $form.Controls.AddRange(@($label, $autoBtn, $manBtn, $helpBtn))
    try { $form.ShowDialog() | Out-Null } finally { $form.Dispose() }
}

if ($script:Sha512) { $script:Sha512.Dispose() }

if ($DebugMode) {
    try { Stop-Transcript | Out-Null } catch { Write-Debug "Stop-Transcript failed (non-fatal): $_" }
}
