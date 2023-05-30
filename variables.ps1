# Hashtable of available hashing algorithms and the lengths
$hashTypes = [ordered]@{
        SHA1    = 40
        SHA256  = 64
        SHA384  = 96
        SHA512  = 128
        MD5     = 32
    }

Write-Debug $hashTypes