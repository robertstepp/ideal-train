function SetPreFilename {
    $preFilename = (Get-Date -Format yyyyMMdd_HHmm) + "-Pretransfer.hashes.txt"
    return $preFilename
}
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

Function CheckPreFile {
    if (Test-Path -Path $file -PathType Leaf) {
        FileList('pre_transfer')
    } else {
        Filelist('post_transfer')
    }
}

function FileList ($preOrPost_Transfer) {
    $folderPath = Get-ParentScriptFolder

    $fileList = Get-ChildItem -Path $folderPath -File

    foreach ($file in $fileList) {
        Write-host $file ~ (ComputeHash($folderPath + "\" + $file))
    }
}

# Call the function
$parentFolder = Get-ParentScriptFolder
$file = "$parentFolder\" + (SetPreFilename)

CheckPreFile

 