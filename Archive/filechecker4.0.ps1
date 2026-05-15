<#
    Robert Stepp, robert@robertstepp.ninja
    Functionality -
        Check hashes for files against a pre-existing file
        Can be run twice, once to build the initial file and again to compare
            the final against initial hashes.
#>

<# Debug settings
    No Debug output = SilentlyContinue
    Debug output = Continue
#>
$DebugPreference = 'Continue'

# Start the transcript
if ($DebugPreference -eq "Continue") {
    $logFile = Join-Path -Path "." -ChildPath "debug.log"
    Start-Transcript -Path $logFile -Append
}
Write-Debug "Debug Preference: $($DebugPreference)"

# Load the necessary .NET assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Hashtable of available hashing algorithms and the lengths
$hashTypes = [ordered]@{
        SHA1    = 40
        SHA256  = 64
        SHA384  = 96
        SHA512  = 128
        MD5     = 32
    }

# Look into script directory for an existing initial file
function Search-InitialFileExists {
    $filePattern = "*-initial.hashes.csv"
    $fileExists = Test-Path -Path (
        Join-Path -Path (Get-ParentScriptFolder) -ChildPath $filePattern)
    if ($fileExists) {
        $existingFile = Join-Path -Path (Get-ParentScriptFolder) -ChildPath (Get-ChildItem -Path (Get-ParentScriptFolder) -Filter $filePattern | Select-Object -ExpandProperty name)
        Write-Debug "Existing CSV file: $($existingFile)"
        return $existingFile
    } else {
        Write-Debug "CSV file not found: $(-not($fileExists))"
        return $fileExists
    }
}

# Get the path to the parent folder
function Get-ParentScriptFolder {
    $scriptPath = $MyInvocation.PSCommandPath
    $myParentFolder = Split-Path -Path $scriptPath
    Write-Debug "Parent Folder: $($myParentFolder)"
    return $myParentFolder
}

# Identify which hash is being used by hash length
function Get-HashType ($inputHash) {
    $thisHashType
    foreach ($key in $hashTypes.Keys) {
        if ($hashTypes[$key] -eq $inputHash.length) {
            $thisHashType = $key
        }
    }
    Write-Debug "Hash type determined: $($thisHashType)"
    return $thisHashType
}

# Look through script directory for files to hash and builds the initial file
# Will look through all files and folders
function Set-InitialFileAutomatic {
    $scriptDirectory = Get-ParentScriptFolder
    [System.Collections.ArrayList]$output = @()

    # Get initial file list excluding tempFiles directory and log files
    $files = Get-ChildItem -Path $scriptDirectory -File -Recurse |
        Where-Object {
            $_.FullName -notlike "*\tempFiles\*" -and
            $_.Extension -ne ".log" -and
            $_.Extension -ne ".csv"
        }

    $progressForm = New-Object System.Windows.Forms.Form
    $progressForm.Text = 'Processing Files'
    $progressForm.Size = New-Object System.Drawing.Size(400,200)
    $progressForm.StartPosition = 'CenterScreen'

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(10,125)
    $progressBar.Size = New-Object System.Drawing.Size(300,20)
    $progressBar.Minimum = 0
    $progressBar.Maximum = $files.Count
    $progressBar.Value = 0
    $progressForm.Controls.Add($progressBar)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Location = New-Object System.Drawing.Point(50,20)
    $statusLabel.Size = New-Object System.Drawing.Size(300,40)
    $progressForm.Controls.Add($statusLabel)

    $progressForm.Show()
    $progressForm.Refresh()

    foreach ($file in $files) {
        $extension = (Split-Path -Path $file.FullName -Leaf).Split('.')[-1].ToLower()
        Write-Debug $extension

        # Process the file first
        $relativePath = $file.FullName.Replace($scriptDirectory, '').TrimStart('\')
        $hash = Get-FileHash -Path $file.FullName -Algorithm SHA512

        $obj = [PSCustomObject]@{
            FilePath = $relativePath
            Hash = $hash.Hash
        }
        [void]$output.Add($obj)

        # Then process archive contents if applicable
        if ($extension -in @('zip', 'tgz', 'iso')) {
            Invoke-ArchiveFile -FilePath $file.FullName -OutputArray $output
        }

        $progressBar.Value++
        $statusLabel.Text = "Processing $($progressBar.Value) of $($progressBar.Maximum): $relativePath"
        $progressForm.Refresh()
    }

    $progressForm.Close()

    # Clean up tempFiles directory and all contents
    $tempPath = Join-Path -Path "." -ChildPath "tempFiles"
    if (Test-Path $tempPath) {
        Remove-Item -Path $tempPath -Recurse -Force
    }

    $output | Export-Csv -Path (Initialize-InitialFilePath) -NoTypeInformation
}

# Gets input from the user on what the hashes should be
# Usefule when pulling files fromt the internet/local lan
function Set-InitialFileManual {

    # Create the form
    $manualForm = New-Object System.Windows.Forms.Form
    $manualForm.Text = 'Enter Filename and Hash'
    $manualForm.Size = New-Object System.Drawing.Size(400,250)
    $manualForm.StartPosition = 'CenterScreen'

    # Create the filename label and textbox
    $filenameLabel = New-Object System.Windows.Forms.Label
    $filenameLabel.Location = New-Object System.Drawing.Point(10,20)
    $filenameLabel.Size = New-Object System.Drawing.Size(280,20)
    $filenameLabel.Text = 'Filename:'
    $manualForm.Controls.Add($filenameLabel)

    $filenameTextBox = New-Object System.Windows.Forms.TextBox
    $filenameTextBox.Location = New-Object System.Drawing.Point(10,40)
    $filenameTextBox.Size = New-Object System.Drawing.Size(360,20) # Increased the width of the text box
    $manualForm.Controls.Add($filenameTextBox)

    # Create the hash label and textbox
    $hashLabel = New-Object System.Windows.Forms.Label
    $hashLabel.Location = New-Object System.Drawing.Point(10,70)
    $hashLabel.Size = New-Object System.Drawing.Size(280,20)
    $hashLabel.Text = 'Hash:'
    $manualForm.Controls.Add($hashLabel)

    $hashTextBox = New-Object System.Windows.Forms.TextBox
    $hashTextBox.Location = New-Object System.Drawing.Point(10,90)
    $hashTextBox.Size = New-Object System.Drawing.Size(360,20) # Increased the width of the text box
    $manualForm.Controls.Add($hashTextBox)

    # Initialize an array to hold the output
    $script:output = @()

    # Create the 'Object added' label
    $addedLabel = New-Object System.Windows.Forms.Label
    $addedLabel.Location = New-Object System.Drawing.Point(10,170)
    $addedLabel.Size = New-Object System.Drawing.Size(280,20)
    $addedLabel.Text = ''
    $manualForm.Controls.Add($addedLabel)

    # Create the 'Add' button
    $addButton = New-Object System.Windows.Forms.Button
    $addButton.Location = New-Object System.Drawing.Point(10,130)
    $addButton.Size = New-Object System.Drawing.Size(75,23)
    $addButton.Text = 'Add'
    $addButton.Add_Click({
        $filename = $filenameTextBox.Text
        $hash = $hashTextBox.Text

        # Check the filename for invalid characters
        if ($filename -match '[<>:"/\\|?*]') {
            # If the filename contains invalid characters, display a message box and return
            $message = "The filename '$filename' contains one or more invalid characters (<, >, :, `", /, \, |, ?, *). Please enter a valid filename."
            [System.Windows.Forms.MessageBox]::Show($message, 'Invalid Filename', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)

            # Clear the filename text box
            $filenameTextBox.Clear()

            return
        }

        # Create a custom object with the file path and hash
        $obj = New-Object PSObject
        $obj | Add-Member -MemberType NoteProperty -Name 'FilePath' -Value $filename
        $obj | Add-Member -MemberType NoteProperty -Name 'Hash' -Value $hash

        # Add the object to the output array
        $script:output += $obj

        # Display the 'Object added' message
        $addedLabel.Text = 'Object added'
        $manualForm.Refresh()

        $filenameTextBox.Clear()
        $hashTextBox.Clear()
    })
    $manualForm.Controls.Add($addButton)

    # Create the 'Done' button
    $doneButton = New-Object System.Windows.Forms.Button
    $doneButton.Location = New-Object System.Drawing.Point(90,130)
    $doneButton.Size = New-Object System.Drawing.Size(75,23)
    $doneButton.Text = 'Done'
    $doneButton.Add_Click({ $manualForm.Close() })
    $manualForm.Controls.Add($doneButton)

    # Add the help button
    $helpButton = New-Object System.Windows.Forms.Button
    $helpButton.Location = New-Object System.Drawing.Point(350,10)
    $helpButton.Size = New-Object System.Drawing.Size(30,23)
    $helpButton.Text = '?'
    $helpButton.Add_Click({
        $message = {
            Step 1: Enter the filename and hash.
            Step 2: Click the Add button to add the file-hash pair.
            Step 3: Repeat steps 1 and 2 for each file.
            Step 4: Click the Done button when finished.
        }
        Show-MessageBox $message
    })
    $manualForm.Controls.Add($helpButton)

    # Add the TextChanged event to the text boxes
    $filenameTextBox.Add_TextChanged({ $addedLabel.Text = '' })
    $hashTextBox.Add_TextChanged({ $addedLabel.Text = '' })

    # Show the form
    $manualForm.ShowDialog() | Out-Null

    # Write the output array to a CSV file
    $script:output | Export-Csv -Path (Initialize-InitialFilePath) -NoTypeInformation

    # Compare files
    Compare-Hashes
}

# Set filename for pretransfer hashes
function Initialize-InitialFilename {
    $preFilename = (Get-Date -Format yyyyMMdd_HHmm) + "-initial.hashes.csv"
    Write-Debug "Initial File name: $($preFilename)"
    return $preFilename
}

# Define the initial file with the parent folder
function Initialize-InitialFilePath {
    $parentFolder = Get-ParentScriptFolder
    $initialFilename = Initialize-InitialFilename
    $initialFilePath = Join-Path -Path $parentFolder -ChildPath $initialFilename
    Write-Debug "Initial File Path: $($initialFilePath)"
    return $initialFilePath
}

# Function to process archive files
function Invoke-ArchiveFile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath,
        [Parameter(Mandatory=$true)]
        [System.Collections.ArrayList]$OutputArray
    )

    $tempPath = Join-Path -Path "." -ChildPath "tempFiles"
    $extractPath = Join-Path -Path $tempPath -ChildPath (New-Guid).ToString()

    try {
        if (-not (Test-Path $tempPath)) {
            New-Item -ItemType Directory -Path $tempPath | Out-Null
        }
        New-Item -ItemType Directory -Path $extractPath | Out-Null

        $extension = (Split-Path -Path $FilePath -Leaf).Split('.')[-1].ToLower()
        $archiveFileName = Split-Path -Path $FilePath -Leaf

        switch ($extension) {
            "zip" {
                Write-Debug $extension
                [System.IO.Compression.ZipFile]::ExtractToDirectory($FilePath, $extractPath)
            }
            "tgz" {
                Write-Debug $extension
                tar -xzf $FilePath -C $extractPath
            }
            "iso" {
                $mountResult = Mount-DiskImage -ImagePath $FilePath -PassThru
                try {
                    $driveLetter = ($mountResult | Get-Volume).DriveLetter
                    $isoPath = "${driveLetter}:\"
                    Write-Debug "ISO mounted at: $isoPath"

                    # List all files in ISO for debugging
                    $isoFiles = Get-ChildItem -Path $isoPath -Recurse -Force
                    Write-Debug "Files found in ISO: $($isoFiles.Count)"

                    foreach ($isoFile in $isoFiles) {
                        if (-not $isoFile.PSIsContainer) {
                            # Get relative path from ISO root
                            $relativePath = $isoFile.FullName.Replace($isoPath, "")
                            $destPath = Join-Path $extractPath $relativePath

                            $destDir = Split-Path -Parent $destPath
                            if (-not (Test-Path $destDir)) {

                                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                            }

                            Write-Debug "Copying $($isoFile.FullName) to $destPath"
                            Copy-Item -Path $isoFile.FullName -Destination $destPath -Force

                            # Calculate hash for this file and add to output
                            $hash = Get-FileHash -Path $destPath -Algorithm SHA512
                            $archivePath = $archiveFileName + "\" + $relativePath

                            $fileHash = [PSCustomObject]@{
                                FilePath = $archivePath
                                Hash = $hash.Hash
                            }
                            [void]$OutputArray.Add($fileHash)
                        }
                    }
                }
                finally {
                    Dismount-DiskImage -ImagePath $FilePath
                }
            }
        }

        # Handle regular archive files (zip/tgz)
        if ($extension -in @('zip', 'tgz')) {
            $files = Get-ChildItem -Path $extractPath -File -Recurse -Force
            foreach ($file in $files) {
                $relativePath = $file.FullName.Replace($extractPath, "")
                $hash = Get-FileHash -Path $file.FullName -Algorithm SHA512
                $archivePath = $archiveFileName + "\" + $relativePath

                $fileHash = [PSCustomObject]@{
                    FilePath = $archivePath
                    Hash = $hash.Hash
                }
                [void]$OutputArray.Add($fileHash)
            }
        }
    }
    finally {
        if (Test-Path $extractPath) {
            Remove-Item -Path $extractPath -Recurse -Force
        }
    }
}

# Compare the initial file to the final hashes
function Compare-Hashes {
    # Import the CSV file
    $csvFile = Search-InitialFileExists
    $fileHashPairs = Import-Csv -Path $csvFile

    # Initialize totals
    $verifiedFiles = 0
    $differentFiles = 0
    $totalFiles = 0

    # Initialize an array to hold the output
    $output = @()

    # Initialize an array to hold missing files
    $missingFiles = @()

    # Initialize an array to hold incorrect hash types
    $incorrectHash = @()

    #Initialize an array to hold file listing for different files
    $differenceOutput = @()

    # Create the progress bar form
    $progressForm = New-Object System.Windows.Forms.Form
    $progressForm.Text = 'Processing Files'
    $progressForm.Size = New-Object System.Drawing.Size(400,200)
    $progressForm.StartPosition = 'CenterScreen'

    # Create the progress bar
    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(10,125)
    $progressBar.Size = New-Object System.Drawing.Size(300,20)
    $progressBar.Minimum = 0
    $progressBar.Maximum = $fileHashPairs.Count
    $progressBar.Value = 0
    $progressForm.Controls.Add($progressBar)

    # Create the status label
    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Location = New-Object System.Drawing.Point(50,20)
    $statusLabel.Size = New-Object System.Drawing.Size(300,40)
    $progressForm.Controls.Add($statusLabel)

    # Show the progress bar form
    $progressForm.Show()
    $progressForm.Refresh()

    # Add header to missing file array
    $missingFiles += "Missing Files:`n"

    # Add header to incorrect hash array
    $incorrectHash += "Incorrect Hash:`n"

    # Add variable to tell if there is an error
    $errorCondition = $false

    # Loop through each file-hash pair
    foreach ($pair in $fileHashPairs) {
        # Get the hash type
        [String] $hashType = Get-HashType $pair.Hash
        $hashType = $hashType.TrimStart()
        Write-Debug "Hash type for $($pair.FilePath): $($hashType)"

        # Check if the hash type is recognized
        if ($null -eq $hashType -or '' -eq $hashType.Trim()) {
            Write-Debug "Unrecognized hash type for file: $($pair.FilePath)"
            $incorrectHash += "`t$($pair.FilePath)`n"
            $differentFiles++
            $errorCondition = $true
            continue
        }

        # Create path of the file
        $thisPath = (Join-Path -Path (Get-ParentScriptFolder) -ChildPath $pair.FilePath)

        # Check if the file exists
        if (-not (Test-Path -Path $thisPath)) {
            Write-Debug "File not found: $($thisPath)"
            $missingFiles += "`t$($pair.FilePath)`n"
            $differentFiles++
            $errorCondition = $true
            continue
        }

        Write-Debug "Is there an error condition: $($errorCondition)"
        # Compute the hash of the file
        if ($errorCondition -ne $true) {
            Write-Debug "Computing hash for file: $($thisPath)"
            $hash = Get-FileHash -Path $thisPath -Algorithm $hashType
            Write-Debug "Computed hash: $($hash.Hash)"
        }

        $errorCondition = $false
        # Compare the new hash against the imported hash
        if ($hash.Hash -eq $pair.Hash) {
            $output += "Verified  - " + $pair.FilePath
            $verifiedFiles++
        } else {
            $output += "Different - " + $pair.FilePath
            $differenceOutput += $differenceOutput += $pair.FilePath + "`n`t" + $hash.Hash + "`n`t" + $pair.Hash
            $differentFiles++
        }
        $totalFiles++
        # Update the progress bar and status label
        $progressBar.Value++
        $statusLabel.Text = "Processing $($progressBar.Value) of $($progressBar.Maximum): $thisPath"
        $progressForm.Refresh()
    }

    # Close the progress bar form
    $progressForm.Close()

    # Write the output array to a log file
    $logFile = (Get-Date -Format yyyyMMdd_HHmm) + "-fileverification.log"
    $logFilePath = Join-Path -Path (Get-ParentScriptFolder) -ChildPath $logFile
    $output | Out-File -FilePath $logFilePath

    Publish-FileTotals -Verified $verifiedFiles -Different $differentFiles -Total $totalFiles

    if ($differentFiles -eq 0 ) {
        Remove-Item $csvFile
    } else {
        $i = 0
        "" | Out-File -FilePath $logFilePath -Append
        while ($i -lt 21) {
            "*" | Out-File $logFilePath -Append -NoNewline
            $i++
        }
        "" | Out-File -FilePath $logFilePath -Append
        "FilePath `n`t Original Hash `n`t New Hash" | Out-File -FilePath $logFilePath -Append
        $differenceOutput | Out-File -FilePath $logFilePath -Append
        $j = 0
        "" | Out-File -FilePath $logFilePath -Append
        while ($j -lt 21) {
            "*" | Out-File $logFilePath -Append -NoNewline
            $j++
        }
        "" | Out-File -FilePath $logFilePath -Append
        $missingFiles | Out-File -FilePath $logFilePath -Append
        $incorrectHash | Out-File -FilePath $logFilePath -Append
    }
}

# Compare the initial file to the final hashes but at an external location.
function Compare-HashesExternal {

    Write-Debug "External Chosen"
    # Create and configure the folder browser dialog
    $folderBrowserDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowserDialog.Description = "Select the external location for comparison"
    $folderBrowserDialog.RootFolder = "MyComputer" # Start at My Computer

    # Show the folder browser dialog
    $dialogResult = $folderBrowserDialog.ShowDialog()
    if ($dialogResult -ne "OK") {
        Write-Host "No external location selected. Exiting comparison."
        return
    }

    $externalPath = $folderBrowserDialog.SelectedPath
    Write-Debug $externalPath

    # Ensure the path is valid
    if (-not (Test-Path -Path $externalPath)) {
        Write-Host "Invalid path: $externalPath"
        return
    }

    # Import the CSV file
    $csvFile = Search-InitialFileExists
    $fileHashPairs = Import-Csv -Path $csvFile

    # Import the CSV file
    $csvFile = Search-InitialFileExists
    $fileHashPairs = Import-Csv -Path $csvFile

    # Initialize totals
    $verifiedFiles = 0
    $differentFiles = 0
    $totalFiles = 0

    # Initialize an array to hold the output
    $output = @()

    # Initialize an array to hold missing files
    $missingFiles = @()

    # Initialize an array to hold incorrect hash types
    $incorrectHash = @()

    #Initialize an array to hold file listing for different files
    $differenceOutput = @()

    # Create the progress bar form
    $progressForm = New-Object System.Windows.Forms.Form
    $progressForm.Text = 'Processing Files'
    $progressForm.Size = New-Object System.Drawing.Size(400,200)
    $progressForm.StartPosition = 'CenterScreen'

    # Create the progress bar
    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(10,125)
    $progressBar.Size = New-Object System.Drawing.Size(300,20)
    $progressBar.Minimum = 0
    $progressBar.Maximum = $fileHashPairs.Count
    $progressBar.Value = 0
    $progressForm.Controls.Add($progressBar)

    # Create the status label
    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Location = New-Object System.Drawing.Point(50,20)
    $statusLabel.Size = New-Object System.Drawing.Size(300,40)
    $progressForm.Controls.Add($statusLabel)

    # Show the progress bar form
    $progressForm.Show()
    $progressForm.Refresh()

    # Add header to missing file array
    $missingFiles += "Missing Files:`n"

    # Add header to incorrect hash array
    $incorrectHash += "Incorrect Hash:`n"

    # Add variable to tell if there is an error
    $errorCondition = $false

    # Loop through each file-hash pair
    foreach ($pair in $fileHashPairs) {
        # Get the hash type
        [String] $hashType = Get-HashType $pair.Hash
        $hashType = $hashType.TrimStart()
        Write-Debug "Hash type for $($pair.FilePath): $($hashType)"

        # Check if the hash type is recognized
        if ($null -eq $hashType -or '' -eq $hashType.Trim()) {
            Write-Debug "Unrecognized hash type for file: $($pair.FilePath)"
            $incorrectHash += "`t$($pair.FilePath)`n"
            $differentFiles++
            $errorCondition = $true
            continue
        }

        # Create path of the file
        $thisPath = Join-Path -Path $externalPath -ChildPath $pair.FilePath

        # Check if the file exists
        if (-not (Test-Path -Path $thisPath)) {
            Write-Debug "File not found: $($thisPath)"
            $missingFiles += "`t$($pair.FilePath)`n"
            $differentFiles++
            $errorCondition = $true
            continue
        }

        Write-Debug "Is there an error condition: $($errorCondition)"
        # Compute the hash of the file
        if ($errorCondition -ne $true) {
            Write-Debug "Computing hash for file: $($thisPath)"
            $hash = Get-FileHash -Path $thisPath -Algorithm $hashType
            Write-Debug "Computed hash: $($hash.Hash)"
        }

        $errorCondition = $false
        # Compare the new hash against the imported hash
        if ($hash.Hash -eq $pair.Hash) {
            $output += "Verified  - " + $pair.FilePath
            $verifiedFiles++
        } else {
            $output += "Different - " + $pair.FilePath
            $differenceOutput += $differenceOutput += $pair.FilePath + "`n`t" + $hash.Hash + "`n`t" + $pair.Hash
            $differentFiles++
        }
        $totalFiles++
        # Update the progress bar and status label
        $progressBar.Value++
        $statusLabel.Text = "Processing $($progressBar.Value) of $($progressBar.Maximum): $thisPath"
        $progressForm.Refresh()
    }

    # Close the progress bar form
    $progressForm.Close()

    # Write the output array to a log file
    $logFile = (Get-Date -Format yyyyMMdd_HHmm) + "-fileverification.log"
    $logFilePath = Join-Path -Path (Get-ParentScriptFolder) -ChildPath $logFile
    $output | Out-File -FilePath $logFilePath

    Publish-FileTotals -Verified $verifiedFiles -Different $differentFiles -Total $totalFiles

    if ($differentFiles -eq 0 ) {
        Remove-Item $csvFile
    } else {
        $i = 0
        "" | Out-File -FilePath $logFilePath -Append
        while ($i -lt 21) {
            "*" | Out-File $logFilePath -Append -NoNewline
            $i++
        }
        "" | Out-File -FilePath $logFilePath -Append
        "FilePath `n`t Original Hash `n`t New Hash" | Out-File -FilePath $logFilePath -Append
        $differenceOutput | Out-File -FilePath $logFilePath -Append
        $j = 0
        "" | Out-File -FilePath $logFilePath -Append
        while ($j -lt 21) {
            "*" | Out-File $logFilePath -Append -NoNewline
            $j++
        }
        "" | Out-File -FilePath $logFilePath -Append
        $missingFiles | Out-File -FilePath $logFilePath -Append
        $incorrectHash | Out-File -FilePath $logFilePath -Append
    }
}

# Display totals output
function Publish-FileTotals {
    param(
        [Parameter(Mandatory=$true)]
        [int]
        $Verified,

        [Parameter(Mandatory=$true)]
        [int]
        $Different,

        [Parameter(Mandatory=$true)]
        [int]
        $Total
    )
    # Create the form
    $totalForm = New-Object System.Windows.Forms.Form
    $totalForm.Text = 'File Verification'
    $totalForm.Size = New-Object System.Drawing.Size(300,200)
    $totalForm.StartPosition = 'CenterScreen'

    # Create the column title labels
    $verifiedLabel = New-Object System.Windows.Forms.Label
    $verifiedLabel.Location = New-Object System.Drawing.Point(10,20)
    $verifiedLabel.Size = New-Object System.Drawing.Size(75,20)
    $verifiedLabel.Text = 'Verified Files'
    $verifiedLabel.Font = New-Object System.Drawing.Font($verifiedLabel.Font, [System.Drawing.FontStyle]::Underline)
    $totalForm.Controls.Add($verifiedLabel)

    $differentLabel = New-Object System.Windows.Forms.Label
    $differentLabel.Location = New-Object System.Drawing.Point(100,20)
    $differentLabel.Size = New-Object System.Drawing.Size(75,20)
    $differentLabel.Text = 'Different Files'
    $differentLabel.Font = New-Object System.Drawing.Font($differentLabel.Font, [System.Drawing.FontStyle]::Underline)
    $totalForm.Controls.Add($differentLabel)

    $totalLabel = New-Object System.Windows.Forms.Label
    $totalLabel.Location = New-Object System.Drawing.Point(190,20)
    $totalLabel.Size = New-Object System.Drawing.Size(75,20)
    $totalLabel.Text = 'Total Files'
    $totalLabel.Font = New-Object System.Drawing.Font($TotalLabel.Font, [System.Drawing.FontStyle]::Underline)
    $totalForm.Controls.Add($totalLabel)

    # Create the variable labels
    $verifiedVarLabel = New-Object System.Windows.Forms.Label
    $verifiedVarLabel.Location = New-Object System.Drawing.Point(10,50)
    $verifiedVarLabel.Size = New-Object System.Drawing.Size(75,20)
    $verifiedVarLabel.Text = $verified
    $totalForm.Controls.Add($verifiedVarLabel)

    $differentVarLabel = New-Object System.Windows.Forms.Label
    $differentVarLabel.Location = New-Object System.Drawing.Point(100,50)
    $differentVarLabel.Size = New-Object System.Drawing.Size(75,20)
    $differentVarLabel.Text = $different
    $totalForm.Controls.Add($differentVarLabel)

    $totalVarLabel = New-Object System.Windows.Forms.Label
    $totalVarLabel.Location = New-Object System.Drawing.Point(190,50)
    $totalVarLabel.Size = New-Object System.Drawing.Size(75,20)
    $totalVarLabel.Text = $total
    $totalForm.Controls.Add($totalVarLabel)

    # Create the 'Close' button
    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Location = New-Object System.Drawing.Point(100,120)
    $closeButton.Size = New-Object System.Drawing.Size(100,23)
    $closeButton.Text = 'Close'
    $closeButton.Add_Click({ $totalForm.Close() })
    $totalForm.Controls.Add($closeButton)

    # Show the form
    $totalForm.ShowDialog() | Out-Null
}

# Used to pop up informational messages
function Show-MessageBox ($message) {
    [System.Windows.Forms.MessageBox]::Show($message, 'Help', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

# Main startup
$initialFile = Search-InitialFileExists
Write-Debug "Initial File [Main]: $($initialFile)"
if ($initialFile -ne $false) {
    # Stage 2 checking after transfer
    # Create the form
    $comparisonForm = New-Object System.Windows.Forms.Form
    $comparisonForm.Text = 'Select Comparison Type'
    $comparisonForm.Size = New-Object System.Drawing.Size(370,200)
    $comparisonForm.StartPosition = 'CenterScreen'

    # Create the 'Local' button
    $localButton = New-Object System.Windows.Forms.Button
    $localButton.Location = New-Object System.Drawing.Point(10,70)
    $localButton.Size = New-Object System.Drawing.Size(150,23)
    $localButton.Text = 'Local'
    $localButton.Add_Click({
        Compare-Hashes
        $comparisonForm.Close()
    })
    $comparisonForm.Controls.Add($localButton)

    # Create the 'External' button
    $externalButton = New-Object System.Windows.Forms.Button
    $externalButton.Location = New-Object System.Drawing.Point(190,70)
    $externalButton.Size = New-Object System.Drawing.Size(150,23)
    $externalButton.Text = 'External'
    $externalButton.Add_Click({
            # External comparison
            Compare-HashesExternal
            $comparisonForm.Close()
    })
    $comparisonForm.Controls.Add($externalButton)

    # Create the 'Help' button
    $helpButton = New-Object System.Windows.Forms.Button
    $helpButton.Location = New-Object System.Drawing.Point(310,10)
    $helpButton.Size = New-Object System.Drawing.Size(30,23)
    $helpButton.Text = '?'
    $helpButton.Add_Click({
        $message = "Local: Compare files in the current directory with the initial file." + [Environment]::NewLine +
                       "External: Compare files in a specified external location (e.g., a non-writable disk) with the initial file. The log file will be saved locally."
        Show-MessageBox $message
    })
    $comparisonForm.Controls.Add($helpButton)

    # Show the form
    $comparisonForm.ShowDialog() | Out-Null
    #read-host -Prompt "Press Enter"
} else {
    # Stage 1 building the initial fiie
    # Build initial file manually/automatically
    # Create the form
    $autoManualForm = New-Object System.Windows.Forms.Form
    $autoManualForm.Text = 'Build Initial Listing'
    $autoManualForm.Size = New-Object System.Drawing.Size(370,200)
    $autoManualForm.StartPosition = 'CenterScreen'

    # Create the label
    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(10,20)
    $label.Size = New-Object System.Drawing.Size(290,40)
    $label.Text = 'How to build initial listing:'
    $autoManualForm.Controls.Add($label)

    # Create the 'Automatic' button
    $automaticButton = New-Object System.Windows.Forms.Button
    $automaticButton.Location = New-Object System.Drawing.Point(10,70)
    $automaticButton.Size = New-Object System.Drawing.Size(150,23)
    $automaticButton.Text = 'Automatic'
    $automaticButton.Add_Click({
        Set-InitialFileAutomatic
        $autoManualForm.Close()
    })
    $autoManualForm.Controls.Add($automaticButton)

    # Create the 'Manual' button
    $manualButton = New-Object System.Windows.Forms.Button
    $manualButton.Location = New-Object System.Drawing.Point(190,70)
    $manualButton.Size = New-Object System.Drawing.Size(150,23)
    $manualButton.Text = 'Manual'
    $manualButton.Add_Click({
        Set-InitialFileManual
        $autoManualForm.Close()
    })
    $autoManualForm.Controls.Add($manualButton)

    # Add the help button
    $helpButton = New-Object System.Windows.Forms.Button
    $helpButton.Location = New-Object System.Drawing.Point(310,10)
    $helpButton.Size = New-Object System.Drawing.Size(30,23)
    $helpButton.Text = '?'
    $helpButton.Add_Click({
        $message = {
            Choose how to build the initial listing:
            -Automatic: The script will automatically hash all
            files in the script directory and subfolders.
            -Manual: You will manually enter each file and its
            hash.
        }
        Show-MessageBox $message
    })
    $autoManualForm.Controls.Add($helpButton)

    # Show the form
    $autoManualForm.ShowDialog() | Out-Null
}
if ($DebugPreference -eq "Continue") {
    # Stop the transcript
    Stop-Transcript
}
