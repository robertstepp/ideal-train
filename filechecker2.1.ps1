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
$DebugPreference = 'SilentlyContinue'

# Load the necessary .NET assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
        $existingFile = Join-Path -Path (Get-ParentScriptFolder) -ChildPath (Get-ChildItem -Path (Get-ParentScriptFolder) -Recurse -Filter $filePattern | Select-Object -ExpandProperty name)
        return $existingFile
    } else {
        return $fileExists
    }
}

# Get the path to the parent folder
function Get-ParentScriptFolder {
    $scriptPath = $MyInvocation.PSCommandPath
    $myParentFolder = Split-Path -Path $scriptPath
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
    return $thisHashType
}

# Look through script directory for files to hash and builds the initial file
# Will look through all files and folders
function Set-InitialFileAutomatic {
    # Get the script directory
    $scriptDirectory = Get-ParentScriptFolder

    # Get all files in the script directory and subfolders
    $files = Get-ChildItem -Path $scriptDirectory -File -Recurse

    # Initialize an array to hold the output
    $output = @()

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
    $progressBar.Maximum = $files.Count
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

    # Loop through each file
    foreach ($file in $files) {
        # Compute the hash of the file
        $hash = Get-FileHash -Path $file.FullName -Algorithm SHA512

        # Remove the script directory from the file path
        $relativePath = $file.FullName.Replace($scriptDirectory, '')

        # Create a custom object with the file path and hash
        $obj = New-Object PSObject
        $obj | Add-Member -MemberType NoteProperty -Name 'FilePath' -Value $relativePath
        $obj | Add-Member -MemberType NoteProperty -Name 'Hash' -Value $hash.Hash

        # Add the object to the output array
        $output += $obj

        # Update the progress bar and status label
        $progressBar.Value++
        $statusLabel.Text = "Processing $($progressBar.Value) of $($progressBar.Maximum): $relativePath"
        $progressForm.Refresh()
    }

    # Close the progress bar form
    $progressForm.Close()

    # Write the output array to a CSV file
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
        $message = 'Step 1: Enter the filename and hash.' + [Environment]::NewLine +
                   'Step 2: Click the Add button to add the file-hash pair.' + [Environment]::NewLine +
                   'Step 3: Repeat steps 1 and 2 for each file.' + [Environment]::NewLine +
                   'Step 4: Click the Done button when finished.'
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
    return $preFilename
}

# Define the initial file with the parent folder
function Initialize-InitialFilePath {
    $parentFolder = Get-ParentScriptFolder
    $initialFilename = Initialize-InitialFilename
    $initialFilePath = Join-Path -Path $parentFolder -ChildPath $initialFilename
    return $initialFilePath
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

    # Loop through each file-hash pair
    foreach ($pair in $fileHashPairs) {
        # Get the hash type
        [String] $hashType = Get-HashType $pair.Hash
        $hashType = $hashType.TrimStart()

        # Compute the hash of the file
        $thisPath = (Join-Path -Path (Get-ParentScriptFolder) -ChildPath $pair.FilePath)
        $hash = Get-FileHash -Path $thisPath -Algorithm $hashType

        # Compare the new hash against the imported hash
        if ($hash.Hash -eq $pair.Hash) {
            $output += "Verified - " + $pair.FilePath
            $verifiedFiles++
            $totalFiles++
        } else {
            $output += "Different- " + $pair.FilePath
            $differenceOutput += $pair.FilePath + " || " + $hash.Hash + " || " + $pair.Hash
            $differentFiles++
            $totalFiles++
        }

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
    $output | Out-File -FilePath $logFile
    Publish-FileTotals $verifiedFiles $differentFiles $totalFiles
    
    if ($differentFiles -eq 0 ) {
        Remove-Item $csvFile
    } else {
        $i = 0
        while ($i -lt 21) {
            "*" | Out-File $logFilePath -Append -NoNewline
            $i++
        }
        "" | Out-File -FilePath $logFilePath -Append
        "FilePath || Original Hash || New Hash" | Out-File -FilePath $logFilePath -Append
        $differenceOutput | Out-File -FilePath $logFilePath -Append
    }
}

# Display totals output
function Publish-FileTotals ($verified, $different, $total) {
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
if ($initialFile -ne $false) {
    # Stage 2 checking after transfer
    # Check the initial file against files in directory
    Compare-Hashes
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
        $message = 'Choose how to build the initial listing:' + [Environment]::NewLine +
                'Automatic: The script will automatically hash all files in the script directory and subfolders.' + [Environment]::NewLine +
                'Manual: You will manually enter each file and its hash.'
        Show-MessageBox $message
    })
    $autoManualForm.Controls.Add($helpButton)

    # Show the form
    $autoManualForm.ShowDialog() | Out-Null
}