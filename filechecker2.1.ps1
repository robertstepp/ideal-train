#2345678901234567890123456789012345678901234567890123456789012345678901234567890
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
        $existingFile = Join-Path -Path (Get-ParentScriptFolder) -ChildPath `
            (Get-ChildItem -Path $scriptPath -Recurse -Filter $filePattern | `
            Select-Object -ExpandProperty name)
            Write-Debug $existingFile
        return $existingFile
    } else {
        Write-Debug $fileExists
        return $fileExists
    }
}

# Get the path to the parent folder
function Get-ParentScriptFolder {
    $scriptPath = $MyInvocation.PSCommandPath
    $myParentFolder = Split-Path -Path $scriptPath
    Write-Debug $myParentFolder
    return $myParentFolder
}

# Hashes files that are passed
# Includes hash function as they can change
function Get-Hashes ($filename, $hashtype) {
    $thisFileHash = Get-FileHash -Path $filename -Algorithm $hashtype
    Write-Debug $thisFileHash
    return $thisFileHash
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

}

# Gets input from the user on what the hashes should be
# Usefule when pulling files fromt the internet/local lan
function Set-InitialFileManual {
    # Load the necessary .NET assemblies
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # Set the initial filename
    $initialFilename = Initialize-InitialFilePath
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

    # Create the 'Add' button
    $addButton = New-Object System.Windows.Forms.Button
    $addButton.Location = New-Object System.Drawing.Point(10,120)
    $addButton.Size = New-Object System.Drawing.Size(75,23)
    $addButton.Text = 'Add'
    $addButton.Add_Click({
        $filename = $filenameTextBox.Text
        $hash = $hashTextBox.Text
        $output = "$filename,$hash"
        Add-Content -Path $initialFilename -Value $output
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

    # Show the form
    $manualForm.ShowDialog()
}

# Set filename for pretransfer hashes
function Initialize-InitialFilename {    
    $preFilename = (Get-Date -Format yyyyMMdd_HHmm) + "-initial.hashes.csv"
    Write-Debug $preFilename
    return $preFilename
}

# Define the initial file with the parent folder
function Initialize-InitialFilePath {
    $parentFolder = Get-ParentScriptFolder
    $initialFilename = Initialize-InitialFilename
    $initialFilePath = Join-Path -Path $parentFolder -ChildPath $initialFilename
    Write-Debug $initialFilePath
    return $initialFilePath
}

# Main startup
$initialFile = Search-InitialFileExists
if ($initialFile -ne $false) {
    # Stage 2 checking after transfer
    # Check the initial file against files in directory
    Set-InitialFileManual
} else {
    # Stage 1 building the initial fiie
    # Build initial file manually/automatically
    
    # Load the necessary .NET assemblies
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

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