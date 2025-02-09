<#
    Robert Stepp, robert@robertstepp.ninja
    Functionality -
        Check hashes for files against a pre-existing file
        Can be run twice, once to build the initial file and again to compare
            the final against initial hashes.
        Will mount/extract tar, zip, and iso files to get all of the internal files as well.
#>

<# 
    Debug settings
    No Debug output = SilentlyContinue
    Debug output = Continue
#>
$DebugPreference = 'Continue'

# Start the transcript for debugging purposes
if ($DebugPreference -eq "Continue") 
{
    $logFile = Join-Path -Path (Get-ParentScriptFolder) -ChildPath "debug.log"
    Start-Transcript -Path $logFile -Append
}

# Load the necessary .NET assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

<#  
    Look in the current directory if initial hashes file exists.
    @params - None
    @returns - False if file doesn't exist, otherwise the path to the existing file.
#> 
function Test-InitialFileExists 
{
    $filePattern = "*-initial.hashes.csv"
    $fileExists = Test-Path -Path (
        Join-Path -Path (Get-ParentScriptFolder) -ChildPath $filePattern)
    if ($fileExists) 
    {
        $existingFile = Join-Path -Path (Get-ParentScriptFolder) -ChildPath (Get-ChildItem -Path (Get-ParentScriptFolder) -Filter $filePattern | Select-Object -ExpandProperty name)
        Write-Debug "Existing CSV file: $($existingFile)"
        return $existingFile
    } else {
        Write-Debug "CSV file not found: $(-not($fileExists))"
        return $fileExists
    }
}

<#
    Get the path to the folder this script is in. Used to remove said path in other functions.
    @params - None
    @returns - Parent path
#>
function Get-ParentFolder
{
    return $PSScriptRoot
    Write-Debug "Parent Folder: $($myParentFolder)"
}

<#
    Identify the hashtype that is being passed into the script from external files.
    @params - Hash being checked
    @return - Hash type
#>
function Get-HashType
{
    param(
        [Parameter(Mandatory=$true)]
        [string]$inputHash
    )

    # Hashtable of available hashing algorithms and the lengths
    $hashTypes = 
    [ordered]@{
        SHA1    = 40
        SHA256  = 64
        SHA384  = 96
        SHA512  = 128
        MD5     = 32
    }

    foreach ($key in $hashTypes.Keys) 
    {
        if ($hashTypes[$key] -eq $inputHash.length) {
            return $key
            Write-Debug "Hash type determined: $($thisHashType)"
        } else {
            Write-Debug "Hash type not found"
        }
    }
}

<#
    
#>
function Build-InitialFileAuto
{
    
}

<#

#>
function Show-AutoForm
{

}

<#

#>
function Build-InitialFileManual
{

}

<#

#>
function Show-ManualForm
{

}

<#

#>
function Initialize-InitialFilename
{

}

<#

#>
function Initialize-InitialFilePath
{

}

<#

#>
function ConvertFrom-ArchiveFile
{

}

<#

#>
function ConvertFrom-IsoFile
{

}

<#

#>
function ConvertFrom-TarFile
{

}

<#

#>
function Compare-Hashes
{

}

<#

#>
function Show-ComparisonForm
{

}

<#

#>
function Compare-HashesExternal
{

}

<#

#>
function Show-ComparisonFormExternal
{

}

<#

#>
function Show-FileTotals
{

}

<#

#>
function Show-MessageBox
{

}

<#
    Main function
#>