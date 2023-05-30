#2345678901234567890123456789012345678901234567890123456789012345678901234567890
<#  
    Robert Stepp, robert@robertstepp.ninja
    Functionality - 
        Check hashes for files against a pre-existing file
        Can be run twice, once to build the initial file and again to compare 
            the final against initial hashes.
#>

Import-Module .\variables.ps1

# Look into script directory for an existing initial file
function Search-InitialFileExists {
    $filePattern = "*-initial.hashes.csv"
    $fileExists = Test-Path -Path (Join-Path -Path (Get-ParentScriptFolder) -ChildPath $filePattern)
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

# Hashes files that are passed
# Includes hash function as they can change
function Get-Hashes ($filename, $hashtype) {

}

# Identify which hash is being used by hash length
function Get-HashType ($inputHash) {

}

# Look through script directory for files to hash and builds the initial file
# Will look through all files and folders
function Set-InitialFileAutomatic {

}

# Gets input from the user on what the hashes should be
# Usefule when pulling files fromt the internet/local lan
function Set-InitialFileManual {

}

# Set filename for pretransfer hashes
function Initialize-InitialFilename {    
    $preFilename = (Get-Date -Format yyyyMMdd_HHmm) + "-initial.hashes.csv"
    return $preFilename
}

# Define the initial file with the parent folder
function Initialize-InitialFilePath {
    $parentFolder = Get-ParentScriptFolder
    $initialFilename = Set-InitialFilename
    Join-Path -Path $parentFolder -ChildPath $initialFilename
}

# Main startup
$initialFile = Search-InitialFileExists
if ($initialFile -ne $false) {
    # Check the initial file against files in directory
} else {
    # Build initial file manually/automatically
}

foreach ($key in $hashTypes.Keys) {
    write-host $key + $hashTypes.$key
}
