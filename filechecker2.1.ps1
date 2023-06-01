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
        $existingFile = Join-Path -Path (Get-ParentScriptFolder) -ChildPath (Get-ChildItem -Path $scriptPath -Recurse -Filter $filePattern | Select-Object -ExpandProperty name)
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
    }

    # Write the output array to a CSV file
    $output | Export-Csv -Path (Initialize-InitialFilePath) -NoTypeInformation
}

# Gets input from the user on what the hashes should be
# Usefule when pulling files fromt the internet/local lan
function Set-InitialFileManual {

    # Create the form
    $manualForm = New-Object System.Windows.Forms.Form
    $manualForm.Text = 'Enter Filename and Hash'
    $manualForm.Size = New-Object System.Drawing.Size(350,200)
    $manualForm.StartPosition = 'CenterScreen'

    # Create the filename label and textbox
    $filenameLabel = New-Object System.Windows.Forms.Label
    $filenameLabel.Location = New-Object System.Drawing.Point(10,20)
    $filenameLabel.Size = New-Object System.Drawing.Size(280,20)
    $filenameLabel.Text = 'Filename:'
    $manualForm.Controls.Add($filenameLabel)

    $filenameTextBox = New-Object System.Windows.Forms.TextBox
    $filenameTextBox.Location = New-Object System.Drawing.Point(10,40)
    $filenameTextBox.Size = New-Object System.Drawing.Size(260,20)
    $manualForm.Controls.Add($filenameTextBox)

    # Create the hash label and textbox
    $hashLabel = New-Object System.Windows.Forms.Label
    $hashLabel.Location = New-Object System.Drawing.Point(10,70)
    $hashLabel.Size = New-Object System.Drawing.Size(280,20)
    $hashLabel.Text = 'Hash:'
    $manualForm.Controls.Add($hashLabel)

    $hashTextBox = New-Object System.Windows.Forms.TextBox
    $hashTextBox.Location = New-Object System.Drawing.Point(10,90)
    $hashTextBox.Size = New-Object System.Drawing.Size(260,20)
    $manualForm.Controls.Add($hashTextBox)

    # Initialize an array to hold the output
    $script:output = @()

    # Create the 'Object added' label
    $addedLabel = New-Object System.Windows.Forms.Label
    $addedLabel.Location = New-Object System.Drawing.Point(10,150)
    $addedLabel.Size = New-Object System.Drawing.Size(280,20)
    $addedLabel.Text = ''
    $manualForm.Controls.Add($addedLabel)

    # Create the 'Add' button
    $addButton = New-Object System.Windows.Forms.Button
    $addButton.Location = New-Object System.Drawing.Point(10,120)
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
    $doneButton.Location = New-Object System.Drawing.Point(90,120)
    $doneButton.Size = New-Object System.Drawing.Size(75,23)
    $doneButton.Text = 'Done'
    $doneButton.Add_Click({ $manualForm.Close() })
    $manualForm.Controls.Add($doneButton)
    # Add the TextChanged event to the text boxes
    $filenameTextBox.Add_TextChanged({ $addedLabel.Text = '' })
    $hashTextBox.Add_TextChanged({ $addedLabel.Text = '' })

    # Show the form
    $manualForm.ShowDialog()

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

    # Initialize an array to hold the output
    $output = @()

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
        } else {
            $output += "Different- " + $pair.FilePath
        }
    }

    # Write the output array to a log file
    $logFile = (Get-Date -Format yyyyMMdd_HHmm) + "-fileverification.log"
    $output | Out-File -FilePath $logFile
    
    Remove-Item $csvFile
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
    $autoManualForm.Size = New-Object System.Drawing.Size(300,200)
    $autoManualForm.StartPosition = 'CenterScreen'

    # Create the label
    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(10,20)
    $label.Size = New-Object System.Drawing.Size(280,40)
    $label.Text = 'How to build initial listing:'
    $autoManualForm.Controls.Add($label)

    # Create the 'Automatic' button
    $automaticButton = New-Object System.Windows.Forms.Button
    $automaticButton.Location = New-Object System.Drawing.Point(10,70)
    $automaticButton.Size = New-Object System.Drawing.Size(75,23)
    $automaticButton.Text = 'Automatic'
    $automaticButton.Add_Click({
        Set-InitialFileAutomatic
        $autoManualForm.Close()
    })
    $autoManualForm.Controls.Add($automaticButton)

    # Create the 'Manual' button
    $manualButton = New-Object System.Windows.Forms.Button
    $manualButton.Location = New-Object System.Drawing.Point(90,70)
    $manualButton.Size = New-Object System.Drawing.Size(75,23)
    $manualButton.Text = 'Manual'
    $manualButton.Add_Click({
        Set-InitialFileManual
        $autoManualForm.Close()
    })
    $autoManualForm.Controls.Add($manualButton)

    # Show the form
    $autoManualForm.ShowDialog()
}