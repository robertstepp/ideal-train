# Set filename for pretransfer hashes
function SetPreFilename {    
    $preFilename = (Get-Date -Format yyyyMMdd_HHmm) + "-Pretransfer.hashes.csv"
    return $preFilename
}

# Get the path to the parent folder
function Get-ParentScriptFolder {
    $scriptPath = $MyInvocation.PSCommandPath
    $myParentFolder = Split-Path -Path $scriptPath
    return $myParentFolder
}

# Compute the hash of a file
Function ComputeHash ($filePath) {
    # Load the System.Security.Cryptography library
    [System.Reflection.Assembly]::LoadWithPartialName("System.Security.Cryptography") | Out-Null
    # Create a new instance of the SHA256CryptoServiceProvider class
    $sha512 = New-Object System.Security.Cryptography.SHA512CryptoServiceProvider
    # Open the file and compute its hash
    $stream = [System.IO.File]::OpenRead($filePath)
    $hash = [System.BitConverter]::ToString($sha512.ComputeHash($stream))
    # Close the file stream
    $stream.Close()
    # Return the computed hash
    return $hash.replace("-","")
}

# Check if the pretransfer file exists and calls ComputeHash via FileList function
Function CheckPreFile($filePre) {
    $preFile = [String](Get-ParentScriptFolder)+[String]"\"+[String](SetPreFilename)
    try {
        $scriptDirectory = Split-Path -Path $PSScriptRoot -Parent
        $filePattern = "*-Pretransfer.hashes.csv"
        $fileExists = Test-Path -Path (Join-Path -Path $scriptDirectory -ChildPath $filePattern)
        Write-Host $fileExists
    }
    finally {
        if ($fileExists) {        
            FileList 'post_transfer' $existingFile
        } else {        
            New-Item ($preFile) | Out-Null
            Filelist 'pre_transfer' $preFile
        }
    }
}

# Gets list of all files in the parent folder
function FileList ($preOrPost_Transfer, $myFileName) {
    $folderPath = Get-ParentScriptFolder
    $fileList = Get-ChildItem -Path $folderPath -File
    if ($preOrPost_Transfer -eq 'pre_transfer') {
        "filename,hash">>$myFileName
        foreach ($file in $fileList) {
            $myHash = (ComputeHash($folderPath + "\" + $file))
            $outString = [String]$file+[String]"~"+[String]$myHash
            $outString >> $myFileName
        }
    }
    elseif ($preOrPost_Transfer -eq 'post_transfer') {
        Import-FileObjects $myFileName
        #Write-host $file ~(ComputeHash($folderPath + "\" + $file))
    }
    
}

# Import saved CSV
function Import-FileObjects ($csvFile) {
    $fileHashPairs = @{}
    Import-Csv -Path $csvFile -Delimiter "~" | ForEach-Object {
        $filename = $_.filename
        $hash = $_.hash
        $fileHashPairs[$filename] = $hash
    }
}

# Call the function
$parentFolder = Get-ParentScriptFolder
$file = "$parentFolder\" + (SetPreFilename)

CheckPreFile($file)

 