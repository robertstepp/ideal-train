# File Verification PowerShell Script

This PowerShell script verifies the integrity of files by generating SHA-512 hashes and comparing them against a saved hash manifest. It runs in two stages: first to build the initial hash manifest, and second to verify files against it. The script uses a graphical Windows Forms interface with progress bars throughout.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Windows OS (uses Windows Forms for the GUI)
- `tar` available on PATH (required only for `.tar` / `.tar.gz` / `.tgz` archive enumeration)
- Administrator rights recommended for ISO enumeration (see [Archive Support](#archive-support))

## Usage

```powershell
powershell -File filechecker5.5.ps1
powershell -File filechecker5.5.ps1 -DebugMode
powershell -File filechecker5.5.ps1 -BasePath "D:\Transfer"
powershell -File filechecker5.5.ps1 -DebugMode -SkipArchiveContents
```

### Parameters

| Parameter | Type | Description |
|---|---|---|
| `-DebugMode` | Switch | Enables verbose debug output and writes a full transcript to `debug.log` in the script folder. |
| `-BasePath <folder>` | String | Pre-selects a folder, skipping the graphical folder picker. If the path is invalid, the picker opens as a fallback. |
| `-SkipArchiveContents` | Switch | Hashes archive files (`.zip`, `.tar`, `.tar.gz`, `.tgz`, `.iso`) as opaque files only, without enumerating their contents. |

---

## Stage 1: Building the Initial Hash Manifest

Run the script in the directory you want to monitor. If no existing `*-initial.hashes.csv` file is found next to the script, you will be prompted to build one.

A **?** help button in the dialog explains both options.

### Automatic

You will be prompted to select a base folder (or the folder is taken from `-BasePath`). The script recursively hashes every file under that folder using SHA-512 and saves the results to a timestamped CSV file (`yyyyMMdd_HHmm-initial.hashes.csv`) next to the script.

For supported archive types, the archive itself is hashed **and** its contents are individually enumerated and hashed (e.g. `build.zip\meta.json`). Use `-SkipArchiveContents` to disable this behaviour.

A companion manifest log (`yyyyMMdd_HHmm-initial.manifest.log`) is also written, listing every hashed entry, the algorithm used, and any archive warnings.

### Manual

A form allows you to enter each filename and its hash individually. Click **Add** after each entry and **Done** when finished. The script validates filenames for illegal characters before accepting them. After completing the form, verification begins immediately.

---

## Stage 2: Verifying Files

If an `*-initial.hashes.csv` file is already present next to the script, the script goes straight to verification. You will be prompted to select the folder to verify (the target location where files were transferred). You can also use `-BasePath` to skip this picker.

The script compares current file hashes against the CSV manifest and produces a timestamped verification log (`yyyyMMdd_HHmm-fileverification.log`) next to the script. A summary window shows the count of verified, different, and total files.

Each file is reported as one of:

- **Verified** — hash matches the manifest
- **Different** — hash does not match
- **Missing** — file not found at the target location
- **Bad Hash** — the stored hash type could not be determined

Archive-internal entries (e.g. `build.zip\file.txt`) stored in the CSV are skipped during verification and counted separately in the log header as informational only.

If all files verify successfully, the CSV is automatically deleted.

---

## Archive Support

When building the initial manifest (Automatic mode, without `-SkipArchiveContents`), the following archive formats are supported:

| Format | Method | Notes |
|---|---|---|
| `.zip` | .NET `ZipFile` | No external tools required |
| `.tar`, `.tar.gz`, `.tgz` | System `tar` command | Requires `tar` on PATH; files extracted to a temp folder, then hashed and cleaned up |
| `.iso` | `Mount-DiskImage` | Mounts the ISO, hashes contents, then dismounts. AutoPlay is temporarily suppressed for the current user (HKCU) — no admin rights needed for suppression, but admin rights may be required for mounting on Server SKUs |

Any archive that cannot be opened or enumerated generates a warning. Warnings are collected and written to the manifest log.

---

## Output Files

All output files are written to the script's own directory.

| File | Created during | Description |
|---|---|---|
| `yyyyMMdd_HHmm-initial.hashes.csv` | Stage 1 | Hash manifest used for verification |
| `yyyyMMdd_HHmm-initial.manifest.log` | Stage 1 (Automatic) | Human-readable listing of all hashed entries and any archive warnings |
| `yyyyMMdd_HHmm-fileverification.log` | Stage 2 | Per-file verification results and summary |
| `debug.log` | Any run with `-DebugMode` | Full PowerShell transcript appended each run |

---

## Debugging

Pass `-DebugMode` at the command line to enable debug output and start a transcript:

```powershell
powershell -File filechecker5_5.ps1 -DebugMode
```

The transcript is written (appended) to `debug.log` in the script folder. You can also set `$DebugPreference = 'Continue'` at the top of the script for inline debug output without a transcript.
