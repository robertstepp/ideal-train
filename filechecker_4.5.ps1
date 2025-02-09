<#
    Robert Stepp, robert@robertstepp.ninja
    Functionality -
        Check hashes for files against a pre-existing file
        Can be run twice, once to build the initial file and again to compare
            the final against initial hashes.
        Will mount/extract tar, zip, and iso files to get all of the internal files as well.
#>

<# Debug settings
    No Debug output = SilentlyContinue
    Debug output = Continue
#>

<#  
    Look in the current directory if initial hashes file exists.
    @params - None
    @returns - False if file doesn't exist, otherwise the path to the existing file.
#> 
function Check-InitialFileExists 
{

}

<#
    Get the path to the folder this script is in. Used to remove said path in other functions.
    @params - None
    @returns - Parent path
#>
function Get-ParentFolder
{

}

<#
    Identify the hashtype that is being passed into the script from external files.
    @params - Hash being checked
    @return - Hash type
#>
function Get-HashType
{
    # Hashtable of available hashing algorithms and the lengths
    $hashTypes = [ordered]@{
        SHA1    = 40
        SHA256  = 64
        SHA384  = 96
        SHA512  = 128
        MD5     = 32
    }
}

<#
    
#>
function Build-InitialFileAuto
{
    
}