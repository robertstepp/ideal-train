# File Verification PowerShell Script

This PowerShell script is designed to verify the integrity of files in a directory by comparing their hashes against a pre-existing file of hashes. It can be run in two stages: first to generate the initial hash file, and second to compare the current hashes against the initial ones.
## Usage
### Stage 1: Building the Initial File

Run the script in the directory you want to monitor. It will ask you whether you want to build the initial file manually or automatically.

>**Automatic:** The script will automatically hash all files in the script directory and subfolders.
>
>**Manual:** You will manually enter each file and its hash.

### Stage 2: Checking After Transfer

Run the script again after the files have been transferred. It will compare the current hashes against the initial ones and output the results to a log file.

>**Local Check:** Will check the local files against the initial hashes file.
>
>**External Check:** Will prompt for an external location (to include non-writable locations) to check against the initial hashes file in the current location. It will provide a comparison log in the local location after completion.

### Debugging

You can use the Write-Debug cmdlet to output debug information. Set `$DebugPreference = 'Continue'` at the top of the script to enable debug output.
### Contact

If you have any questions or issues, please contact Robert Stepp at robert@robertstepp.ninja.
