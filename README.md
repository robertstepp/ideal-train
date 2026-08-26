# File Checker v5.12

**Author:** Robert Stepp — <robert@robertstepp.ninja>

A PowerShell utility for verifying file integrity across transfers, primarily intended for disc-based archival and chain-of-custody workflows. Run once before a transfer to build a hash listing, then again after to verify nothing changed. Designed with cybersecurity professionals in mind.

---

## The transfer model (new in v5.12)

Earlier versions wrote the hash listing next to the script. If the script lived outside the folder being burned, you had to remember to copy the listing across — a step that gets forgotten, leaving a transfer that cannot be verified.

**The script now deploys itself into the folder being transferred.** On an initial build it copies itself into the scan folder first, then writes the CSV, sidecar, and manifest next to that copy. The folder you ran it from gets nothing added to it.

```
E:\PS_FileHasher\                    D:\Transfer\
  filechecker5_12.ps1        ──►       filechecker5_12.ps1        (copied in)
                                       20260825_2130-initial.hashes.csv
                                       20260825_2130-initial.hashes.csv.sha512
                                       Filelist-Transfer.txt
                                       ...your data...
```

Burn or copy the **whole folder**. The verification tooling travels with the data, and running the copied script at the destination starts verification automatically. The script is copied *before* the scan, so it is hashed into the listing and verified like any other transferred file.

---

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+ (both supported)
- Windows 10 1803 or later (for built-in `tar.exe`)
- An STA apartment for the dialogs. `powershell.exe` is STA by default; `pwsh.exe` may not be, and the script warns if it is running MTA
- **Administrator rights are not required.** Mounting an ISO works unelevated on client Windows. Elevation is mentioned only if a mount actually fails

---

## Quick Reference

Full-path commands for every task. Substitute your own paths; `E:\PS_FileHasher` is the script's home and `D:\Transfer` is the folder being transferred.

### Build the initial listing (at the source)

Run the script from wherever it lives. It copies itself into the folder you pick.

```powershell
powershell -File "E:\PS_FileHasher\filechecker5_12.ps1"
```

Skip the folder picker by naming the transfer folder directly:

```powershell
powershell -File "E:\PS_FileHasher\filechecker5_12.ps1" -BasePath "D:\Transfer"
```

Hash archives as opaque blobs, without enumerating their contents (much faster on large ISOs and zips):

```powershell
powershell -File "E:\PS_FileHasher\filechecker5_12.ps1" -BasePath "D:\Transfer" -SkipArchiveContents
```

### Verify (at the destination)

Run the **copy that travelled with the data**, not the original. It finds the listing beside itself and goes straight to the verification dialog.

```powershell
powershell -File "D:\Transfer\filechecker5_12.ps1"
```

Verifying a destination that already holds unrelated data (a patching folder), skipping the folder picker:

```powershell
powershell -File "D:\Transfer\filechecker5_12.ps1" -BasePath "D:\Transfer"
```

Flag files present at the destination that were not in the initial listing, instead of ignoring them:

```powershell
powershell -File "D:\Transfer\filechecker5_12.ps1" -ReportExtraFiles
```

### Verify several destinations from one listing

Tick **"Intermediate scan - keep the initial listing"** in the mode dialog for every destination except the last. The listing survives, and its log and rescan files are tagged `-intermediate`. Leave the box unticked on the final destination and the listing is consumed.

```powershell
powershell -File "D:\Transfer\filechecker5_12.ps1" -BasePath "E:\CopyOne"
```

```powershell
powershell -File "D:\Transfer\filechecker5_12.ps1" -BasePath "E:\CopyTwo"
```

### Troubleshoot a run

Writes a full transcript to `debug.log` next to the script that is running:

```powershell
powershell -File "E:\PS_FileHasher\filechecker5_12.ps1" -DebugMode
```

```powershell
powershell -File "E:\PS_FileHasher\filechecker5_12.ps1" -DebugMode -SkipArchiveContents
```

### Verify the listing out of band

The sidecar is standard `sha512sum` format, so it can be checked without running the script at all — on Linux, macOS, or WSL:

```bash
cd /mnt/d/Transfer && sha512sum -c 20260825_2130-initial.hashes.csv.sha512
```

Or in PowerShell, comparing against the sidecar's recorded value:

```powershell
Get-FileHash "D:\Transfer\filechecker5_12.ps1" -Algorithm SHA512 | Format-List
```

### PowerShell 7

Every command above works with `pwsh` in place of `powershell`. PowerShell 7 gets the modern shell folder picker, which handles Libraries, OneDrive, and typed paths; Windows PowerShell 5.1 gets the legacy folder tree.

```powershell
pwsh -File "E:\PS_FileHasher\filechecker5_12.ps1"
```

---

## Parameters

| Parameter | Type | Description |
|---|---|---|
| `-DebugMode` | Switch | Enables verbose debug output and writes a `debug.log` transcript next to the running script |
| `-BasePath` | String | Skips the folder picker and uses the specified path as the scan root (initial build) or comparison target (verification) |
| `-SkipArchiveContents` | Switch | Hashes archive files as opaque blobs only; internal contents are not enumerated |
| `-ReportExtraFiles` | Switch | Comprehensive mode: flags destination files that were not in the initial listing as differences. By default they are discarded |

---

## Workflow

### Step 1 — Initial Build

Run the script before the transfer. When no initial CSV is found next to the script, the build dialog appears.

**Automatic** prompts for the folder that is going to be burned or transferred, copies the script into it, then recursively hashes every file under it. For supported archive types the archive itself is hashed and its contents are enumerated individually.

You are then asked how to name the manifest:

| Option | Filename | Notes |
|---|---|---|
| Timestamped | `20260825_2130-initial.manifest.log` | The original convention. Sorts chronologically, never collides |
| Folder name | `Filelist-Transfer.txt` | Named after the scanned folder. A repeat run is saved as `_2`, `_3`, … rather than overwriting |

The CSV and `.sha512` keep their timestamped names either way — verification finds the CSV by the `*-initial.hashes.csv` pattern and pairs the sidecar off that exact name.

**Manual** allows you to type filename and hash pairs individually — useful when pulling files from a known-good source where hashes are published. Manual mode has no folder picker, so its CSV and sidecar are written next to the script rather than into a transfer folder.

### Step 2 — Verification

Run the transferred copy of the script. The sequence is:

1. **Integrity gate.** The script checks itself and the CSV against the sidecar *before any dialog is shown*. A tampered script or a missing sidecar stops the run immediately
2. **Mode dialog.** Basic or Comprehensive, plus the intermediate-scan checkbox
3. **Folder picker.** The folder to verify against

#### Basic mode

Hashes archive files as opaque blobs only, matching the initial build's top-level entries. Archive-internal entries from the initial CSV are skipped (noted in the log header). Fast — suitable for most transfer verification.

#### Comprehensive mode

Re-runs a full scan of the target folder using the same engine as the initial build, including archive enumeration, then diffs the two listings entry by entry.

| Status | Meaning |
|---|---|
| `Verified` | Present in both listings with identical hash |
| `Different` | Present in both listings with a changed hash |
| `Missing` | In the initial listing but absent from the destination |
| `Bad Hash` | The initial listing's hash is not a recognised length |
| `New` | Only with `-ReportExtraFiles`: present at the destination but not in the initial listing |

**Only what existed at the source is compared.** Files already present at the destination that were not in the initial listing are counted and discarded, so verifying into a folder that already holds data does not report them as differences. The log records the count but never the list — a patching folder can hold tens of thousands of unrelated files. Pass `-ReportExtraFiles` to flag them instead.

**Use Comprehensive mode when:** the contents may have been tampered with at the archive level (e.g. a file added or removed inside a zip), or when a chain-of-custody record is required.

#### Intermediate scans

On a clean pass the initial CSV and its sidecar are consumed — the listing has done its job, and leaving it behind means the next run picks it up again. That is wrong when one listing has to verify more than one destination.

Tick **"Intermediate scan - keep the initial listing"** and a clean pass leaves the listing in place for the next destination. The retention rule is shared by both modes:

| Situation | Initial CSV + sidecar | Log line |
|---|---|---|
| Clean pass, final scan (box unticked) | Deleted | `consumed (clean final scan)` |
| Clean pass, intermediate scan (box ticked) | Kept | `kept (intermediate scan)` |
| Any differences found | Kept | `kept (differences found)` |

The rescan CSV from a Comprehensive run is always kept, as the record of what was actually found.

---

## Output Files

**Initial build** writes into the transfer folder, next to the deployed copy of the script:

| File | Description |
|---|---|
| `filechecker5_12.ps1` | The script itself, copied in before the scan and included in the listing |
| `YYYYMMDD_HHMM-initial.hashes.csv` | Full hash listing |
| `YYYYMMDD_HHMM-initial.hashes.csv.sha512` | SHA-512 hashes of the CSV and the `.ps1`, in `sha512sum` format |
| `YYYYMMDD_HHMM-initial.manifest.log` *or* `Filelist-<folder>.txt` | Human-readable listing, plus any archive warnings |

**Verification** writes next to the running script, which at the destination is the transfer folder:

| File | Created | Description |
|---|---|---|
| `YYYYMMDD_HHMMSS-fileverification.log` | Either mode | Per-file results, hash mismatch details, missing file list |
| `YYYYMMDD_HHMMSS-intermediate-fileverification.log` | Either mode, intermediate | As above, tagged as an intermediate run |
| `YYYYMMDD_HHMMSS-rescan.hashes.csv` | Comprehensive | Full rescan listing. Always kept |
| `YYYYMMDD_HHMMSS-intermediate-rescan.hashes.csv` | Comprehensive, intermediate | As above, tagged |
| `debug.log` | `-DebugMode` | Full transcript of the run |

Verification stamps carry seconds so that back-to-back runs against several destinations do not overwrite one another. All of these filenames are excluded from scan listings, so they never appear as spurious entries on a rescan.

> **Note:** verification writes its log into the folder it runs from. If you run the script directly off read-only media, writing the log will fail. Copy the folder to disk first, or verify from a writable copy.

---

## Archive Support

The archive file itself is always hashed. Internal entries are listed using the path `archive.zip\internal\path\file.ext`.

| Extension | Method |
|---|---|
| `.zip` | Streamed via `System.IO.Compression.ZipFile` — no extraction to disk |
| `.tar` | Extracted to a temp folder via `tar.exe`, then cleaned up |
| `.tar.gz` / `.tgz` | Same as `.tar` |
| `.iso` | Mounted via `Mount-DiskImage`, enumerated, then dismounted. AutoPlay is suppressed for the duration of the mount (HKCU registry key, no admin required; silently skipped if policy blocks the key) |

If an archive fails to enumerate, a warning is added to the manifest log and the run continues. The archive's own hash is still recorded.

### Nested archives

**Expansion goes one level deep only.** A zip inside a zip, a tar inside a tar, or any other combination is hashed as an opaque file, and its contents are not enumerated:

```
zip-in-zip.zip                       ← hashed
zip-in-zip.zip\inner.zip             ← hashed opaque, not opened
```

This is not a detection gap. Any change to nested content necessarily changes the containing archive's bytes, so it propagates upward and is caught — you lose localisation, not detection. The log will report that `zip-in-zip.zip\inner.zip` differs, not which file inside it changed. Both listings are produced by the same engine at the same depth, so they diff consistently.

---

## CSV Integrity Sidecar

The `.sha512` sidecar protects against tampering with the initial hash listing or the script between the build and the verification run. It uses standard `sha512sum` format, so it can be verified independently on Linux or macOS.

The check runs **at startup, before any dialog is shown**. It never depends on anything the user picks: the CSV and sidecar always sit next to the script, while the folder picker chooses the data folder to compare against.

| Condition | Result |
|---|---|
| Sidecar file not found | **Blocked.** The sidecar must be present alongside the CSV |
| Script (`.ps1`) hash mismatch | **Blocked.** The script may have been modified |
| CSV hash mismatch | **Warning dialog** with Yes/No (default: No). The user may choose to continue with full awareness |
| All hashes match | Verification proceeds normally |

---

## Verification Log Format

```
File verification run  [Comprehensive]
Compared against: D:\Transfer
Initial CSV    : D:\Transfer\20260825_2130-initial.hashes.csv
Rescan CSV     : D:\Transfer\20260825_213045-rescan.hashes.csv
Initial listing: kept (differences found)

Entry count: initial=1240  rescan=1239  delta=-1
Destination also holds 41 file(s) not in the initial listing; discarded (use -ReportExtraFiles to list them).

Verified  - AlmaLinux-9.4-aarch64-boot.iso
Verified  - All the Mods 9-0.3.2.zip
Different - notes.txt
Missing   - NBTExplorer-2.8.0\NBTExplorer.exe

*********************
Hash mismatches:

  File:     notes.txt
    Original: A97330D8...
    Computed: 1F951EB0...

*********************
Missing files:
  NBTExplorer-2.8.0\NBTExplorer.exe
```

Basic mode replaces the rescan and count lines with an `Archive-internal entries skipped` count.

---

## Notes for Cybersecurity Use

- **The sidecar file is the root of trust.** Keep a copy of the `.sha512` somewhere independent of the disc (printed, on a separate system, or committed to a repository) to enable out-of-band verification.
- **The script's self-check is fail-fast integrity, not a security boundary.** The `.ps1` hash is recorded in the sidecar and checked before anything else runs, which catches accidental corruption and unsophisticated tampering. It does **not** defend against a deliberate attacker: a modified script can simply delete its own check. To genuinely establish that the script is untouched, verify it from outside — against an independently held copy of the sidecar — before running it.
- **Comprehensive mode is the paranoid choice.** It will detect a file added inside a zip or ISO after the initial build, which Basic mode cannot catch. Add `-ReportExtraFiles` when an unexpected file at the destination is itself a finding.
- **Hash algorithm:** SHA-512 throughout. No MD5 or SHA-1 is used in any output the script generates; those algorithms appear in the hash-type detection table only for compatibility when reading manually-entered hashes in Manual build mode.

---

## Changes since v5.10

v5.11 and v5.12 between them fixed several defects and changed some defaults. The full annotated list is in the header comment of `filechecker5_12.ps1`. The changes that affect how you use it:

- The script deploys itself into the transfer folder and writes the initial files there, instead of next to wherever it was run from
- Comprehensive mode discards destination files that were not in the initial listing, rather than counting them as differences
- Both modes now share one retention rule for the initial listing, with an intermediate-scan option; previously Basic always deleted it on a clean pass and Comprehensive never did
- The integrity check runs before the dialogs rather than after them
- The manifest can be named `Filelist-<folder>.txt`, lists files only, and counts folders in its header
- Two ISO defects fixed: a spurious "not running as admin" warning, and raw registry errors leaking to the console from the AutoPlay suppression on policy-locked machines
- Manual mode now writes a sidecar; previously the verification it launched always blocked
- A clean Basic pass no longer orphans the sidecar
- The folder picker no longer roots itself at This PC, which had made Libraries such as Documents and Desktop unreachable
