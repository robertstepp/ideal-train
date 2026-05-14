<#
    Robert Stepp, robert@robertstepp.ninja


    Usage:
        powershell -File filechecker5_5.ps1
        powershell -File filechecker5_5.ps1 -DebugMode
        powershell -File filechecker5_5.ps1 -BasePath "D:\Transfer"
        powershell -File filechecker5_5.ps1 -DebugMode -SkipArchiveContents
#>

[CmdletBinding()]
param(
    [switch] $DebugMode,
    [string] $BasePath,
    [switch] $SkipArchiveContents
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

function Search-InitialFileExists {
    $match = Get-ChildItem -Path (Get-ParentScriptFolder) -Filter "*-initial.hashes.csv" `
                -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($match) { return $match.FullName }
    return $false
}

function Initialize-InitialFilePath {
    Join-Path (Get-ParentScriptFolder) ((Get-Date -Format yyyyMMdd_HHmm) + "-initial.hashes.csv")
}

function Get-HashType {
    param([string] $InputHash)
    foreach ($k in $hashTypes.Keys) {
        if ($hashTypes[$k] -eq $InputHash.Length) { return $k }
    }
    return $null
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
    param([string] $RelativePath)
    $sep = $RelativePath.IndexOfAny(@('\','/'))
    if ($sep -le 0) { return $false }
    return [bool] (Get-ArchiveExtension $RelativePath.Substring(0, $sep))
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
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $PromptDescription
    $dlg.RootFolder  = 'MyComputer'
    $script = Get-ParentScriptFolder
    if (Test-Path -LiteralPath $script) { $dlg.SelectedPath = $script }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
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
    return [pscustomobject]@{ Form = $form; Bar = $bar; Label = $label }
}

function Invoke-ProgressLoop {
    param(
        [array]    $Items,
        [string]   $Title,
        [scriptblock] $Body,
        [scriptblock] $StatusText = { param($i,$item) "Processing $i of $($Items.Count)" }
    )
    $ui = New-ProgressUI -Title $Title -Max $Items.Count
    try {
        $i = 0
        foreach ($item in $Items) {
            $i++
            & $Body $item $ui
            $ui.Bar.Value = [Math]::Min($i, $ui.Bar.Maximum)
            $ui.Label.Text = (& $StatusText $i $item)
            $ui.Form.Refresh()
        }
    } finally {
        $ui.Form.Close()
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
    $state = [pscustomobject]@{ Existed = $false; OriginalValue = $null }
    try {
        if (-not (Test-Path -LiteralPath $script:AutoPlayKey)) {
            New-Item -Path $script:AutoPlayKey -Force | Out-Null
        }
        $existing = Get-ItemProperty -LiteralPath $script:AutoPlayKey `
                        -Name $script:AutoPlayName -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            $state.Existed       = $true
            $state.OriginalValue = $existing.($script:AutoPlayName)
        }
        # 0xFF = disable AutoPlay for all drive types.
        Set-ItemProperty -LiteralPath $script:AutoPlayKey `
            -Name $script:AutoPlayName -Value 0xFF -Type DWord -Force
        Write-Debug "AutoPlay suppressed (HKCU). Existed=$($state.Existed) Orig=$($state.OriginalValue)"
    } catch {
        Write-Warning "Could not suppress AutoPlay: $_"
    }
    return $state
}

function Pop-AutoPlaySuppression {
    param([pscustomobject] $State)
    if (-not $State) { return }
    try {
        if ($State.Existed) {
            Set-ItemProperty -LiteralPath $script:AutoPlayKey `
                -Name $script:AutoPlayName -Value $State.OriginalValue -Type DWord -Force
            Write-Debug "AutoPlay restored to original value $($State.OriginalValue)."
        } else {
            Remove-ItemProperty -LiteralPath $script:AutoPlayKey `
                -Name $script:AutoPlayName -ErrorAction SilentlyContinue
            Write-Debug "AutoPlay key value removed (was absent before)."
        }
    } catch {
        Write-Warning "Could not restore AutoPlay setting: $_"
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

function Get-ZipContentHashes {
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

function Get-TarContentHashes {
    param([string] $ArchivePath, [string] $ArchiveRelativePath)
    $results = New-Object System.Collections.Generic.List[object]
    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        Add-ArchiveWarning "'tar' not available; skipped enumerating '$ArchivePath'."
        return $results.ToArray()
    }
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("fcv52_" + [IO.Path]::GetRandomFileName())
    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        & tar -xf $ArchivePath -C $tempRoot 2>$null
        if ($LASTEXITCODE -ne 0) {
            Add-ArchiveWarning "tar exited with code $LASTEXITCODE for '$ArchivePath'."
            return $results.ToArray()
        }
        foreach ($f in Get-ChildItem $tempRoot -File -Recurse -Force -ErrorAction SilentlyContinue) {
            $internal = $f.FullName.Substring($tempRoot.Length).TrimStart('\','/')
            $results.Add([pscustomobject]@{
                FilePath = Join-Path $ArchiveRelativePath $internal
                Hash     = (Get-FileHash $f.FullName -Algorithm SHA512).Hash
            })
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

function Get-IsoContentHashes {
    param([string] $ArchivePath, [string] $ArchiveRelativePath)
    $results = New-Object System.Collections.Generic.List[object]
    if (-not (Get-Command Mount-DiskImage -ErrorAction SilentlyContinue)) {
        Add-ArchiveWarning "Mount-DiskImage not available; skipped ISO '$ArchivePath'."
        return $results.ToArray()
    }
    if (-not (Test-IsAdmin)) {
        Add-ArchiveWarning "Not running as admin; ISO mount of '$ArchivePath' may fail on Server SKUs."
    }

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
            $results.Add([pscustomobject]@{
                FilePath = Join-Path $ArchiveRelativePath $internal
                Hash     = (Get-FileHash $f.FullName -Algorithm SHA512).Hash
            })
        }
    } catch {
        Add-ArchiveWarning "Failed to enumerate ISO '$ArchivePath': $_"
    } finally {
        if ($mounted) {
            try { Dismount-DiskImage -ImagePath $ArchivePath -ErrorAction SilentlyContinue | Out-Null } catch {}
        }
        Pop-AutoPlaySuppression -State $autoPlayState
    }
    Write-Debug "ISO '$ArchivePath' produced $($results.Count) entries."
    return $results.ToArray()
}

function Get-ArchiveContentHashes {
    param([string] $ArchivePath, [string] $ArchiveRelativePath, [string] $Extension)
    switch ($Extension) {
        '.zip'    { return (Get-ZipContentHashes  -ArchivePath $ArchivePath -ArchiveRelativePath $ArchiveRelativePath) }
        '.tar'    { return (Get-TarContentHashes  -ArchivePath $ArchivePath -ArchiveRelativePath $ArchiveRelativePath) }
        '.tar.gz' { return (Get-TarContentHashes  -ArchivePath $ArchivePath -ArchiveRelativePath $ArchiveRelativePath) }
        '.tgz'    { return (Get-TarContentHashes  -ArchivePath $ArchivePath -ArchiveRelativePath $ArchiveRelativePath) }
        '.iso'    { return (Get-IsoContentHashes  -ArchivePath $ArchivePath -ArchiveRelativePath $ArchiveRelativePath) }
        default   { return @() }
    }
}

# =====================================================================
#  Initial file builders
# =====================================================================

function Set-InitialFileAutomatic {
    $scanRoot = Resolve-BasePath -PromptDescription "Select the base folder to scan (initial build)"
    if (-not $scanRoot) {
        Show-MessageBox "No folder selected. Initial build cancelled."
        return
    }

    $files  = @(Get-ChildItem -Path $scanRoot -File -Recurse -Force -ErrorAction SilentlyContinue)
    $output = New-Object System.Collections.Generic.List[object]
    $script:ArchiveWarnings.Clear()

    Invoke-ProgressLoop -Items $files -Title 'Building Initial Hash Listing' `
        -StatusText { param($i,$item) "Processed $i of $($files.Count):`r`n$($item.FullName.Substring($scanRoot.Length).TrimStart('\','/'))" } `
        -Body {
            param($file, $ui)
            $rel = $file.FullName.Substring($scanRoot.Length).TrimStart('\','/')
            try {
                $h = Get-FileHash -Path $file.FullName -Algorithm SHA512 -ErrorAction Stop
                $output.Add([pscustomobject]@{ FilePath = $rel; Hash = $h.Hash })
            } catch {
                Write-Warning "Could not hash '$($file.FullName)': $_"
            }
            if (-not $SkipArchiveContents) {
                $ext = Get-ArchiveExtension $file.Name
                if ($ext) {
                    $ui.Label.Text = "Expanding archive: $rel"; $ui.Form.Refresh()
                    # Materialise into an array so we never iterate a null/empty
                    # result as if it were a single element.
                    $inner = @(Get-ArchiveContentHashes -ArchivePath $file.FullName `
                                  -ArchiveRelativePath $rel -Extension $ext)
                    foreach ($e in $inner) {
                        if ($null -ne $e) { $output.Add($e) }
                    }
                }
            }
        }

    $csvPath = Initialize-InitialFilePath
    $output | Export-Csv -Path $csvPath -NoTypeInformation

    # Write a real manifest: the file listing plus a summary and warnings.
    $manifestLog = Join-Path (Get-ParentScriptFolder) `
        ((Get-Date -Format yyyyMMdd_HHmm) + "-initial.manifest.log")

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("Initial hash listing")
    [void]$lines.Add("Built     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$lines.Add("Scan root : $scanRoot")
    [void]$lines.Add("Entries   : $($output.Count)")
    [void]$lines.Add("Skip arc. : $SkipArchiveContents")
    [void]$lines.Add("CSV       : $csvPath")
    [void]$lines.Add("")
    [void]$lines.Add(("=" * 21))
    [void]$lines.Add("Files:")
    foreach ($e in $output) {
        $algo = Get-HashType $e.Hash
        [void]$lines.Add(("  [{0}] {1}" -f $algo, $e.FilePath))
    }
    if ($script:ArchiveWarnings.Count -gt 0) {
        [void]$lines.Add("")
        [void]$lines.Add(("=" * 21))
        [void]$lines.Add("Archive warnings ($($script:ArchiveWarnings.Count)):")
        foreach ($w in $script:ArchiveWarnings) {
            [void]$lines.Add("  - $w")
        }
    }
    $lines | Out-File -FilePath $manifestLog -Encoding utf8

    $popupMsg = "Initial listing built.`r`nEntries: $($output.Count)`r`nCSV: $csvPath"
    if ($script:ArchiveWarnings.Count -gt 0) {
        $popupMsg += "`r`n`r`nArchive warnings: $($script:ArchiveWarnings.Count) (see manifest log)."
    }
    [System.Windows.Forms.MessageBox]::Show($popupMsg, 'Done', 'OK', 'Information') | Out-Null
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

    $form.ShowDialog() | Out-Null

    $script:output | Export-Csv -Path (Initialize-InitialFilePath) -NoTypeInformation
    Compare-Hashes
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
        [int]    $DifferentFiles
    )
    $sep = '*' * 21
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("File verification run")
    [void]$lines.Add("Compared against: $CompareRoot")
    [void]$lines.Add("Initial CSV    : $CsvFile")
    [void]$lines.Add("Archive-internal entries skipped: $Skipped (informational only)")
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

function Compare-Hashes {
    $compareRoot = Resolve-BasePath -PromptDescription "Select the folder to verify against"
    if (-not $compareRoot) { Show-MessageBox "No folder selected. Verification cancelled."; return }

    $csvFile = Search-InitialFileExists
    if (-not $csvFile) {
        [System.Windows.Forms.MessageBox]::Show(
            "No initial CSV found next to the script.", 'Missing CSV', 'OK', 'Error') | Out-Null
        return
    }
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
            param($pair, $ui)
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
        ((Get-Date -Format yyyyMMdd_HHmm) + "-fileverification.log")

    Write-VerificationLog -LogFilePath $logFilePath -CompareRoot $compareRoot -CsvFile $csvFile `
        -Skipped $skipped `
        -Output           $output.ToArray() `
        -DifferenceOutput $differenceOutput.ToArray() `
        -MissingFiles     $missingFiles.ToArray() `
        -IncorrectHash    $incorrectHash.ToArray() `
        -DifferentFiles   $counts.Different

    Publish-FileTotals -Verified $counts.Verified -Different $counts.Different -Total $counts.Total

    if ($counts.Different -eq 0) {
        Remove-Item -LiteralPath $csvFile -ErrorAction SilentlyContinue
    }
}

# =====================================================================
#  Totals form
# =====================================================================

function Publish-FileTotals {
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
            (New-FormControl Label @{ Location=(New-Pt $c.X 50); Size=(New-Sz 75 20); Text=$c.Value }))
    }

    $closeBtn = New-FormControl Button @{
        Location=(New-Pt 100 120); Size=(New-Sz 100 23); Text='Close'
    }
    $closeBtn.Add_Click({ $form.Close() })
    $form.Controls.Add($closeBtn)

    $form.ShowDialog() | Out-Null
}

# =====================================================================
#  Main
# =====================================================================

$initialFile = Search-InitialFileExists
Write-Debug "Initial File [Main]: $initialFile"

if ($initialFile -ne $false) {
    Compare-Hashes
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

  Automatic: You will be prompted for a base folder. The script will
             recursively hash every file under it. For .zip, .tar,
             .tar.gz, .tgz, and .iso files, the archive itself is
             hashed AND its contents are enumerated (archive.zip\file.ext).

             For ISOs, AutoPlay is temporarily disabled (HKCU only,
             no admin needed) so File Explorer does not pop open.

  Manual:    You will manually enter each file and its hash.

CLI arguments:
  -DebugMode              Enable debug output + transcript.
  -BasePath <folder>      Skip the folder picker.
  -SkipArchiveContents    Hash archives only as opaque files.
"@
    })

    $form.Controls.AddRange(@($label, $autoBtn, $manBtn, $helpBtn))
    $form.ShowDialog() | Out-Null
}

if ($DebugMode) {
    try { Stop-Transcript | Out-Null } catch {}
}
