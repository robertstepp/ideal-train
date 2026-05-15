# File Checker v5.10

**Author:** Robert Stepp — <robert@robertstepp.ninja>

A PowerShell utility for verifying file integrity across transfers, primarily intended for disc-based archival and chain-of-custody workflows. Run once before a transfer to build a hash listing, then again after to verify nothing changed. Designed with cybersecurity professionals in mind.

---

## Requirements

- Windows PowerShell 5.1 or later
- Windows 10 1803 or later (for built-in `tar.exe`)
- Administrator rights are not required, except that `Mount-DiskImage` (used for ISO enumeration) may fail on Windows Server SKUs without elevation — the script will warn if this is the case

---

## Quick Start

```powershell
# Standard run (GUI-driven)
powershell -File filechecker5_10.ps1

# With CLI arguments
powershell -File filechecker5_10.ps1 -DebugMode
powershell -File filechecker5_10.ps1 -BasePath "D:\Transfer"
powershell -File filechecker5_10.ps1 -BasePath "D:\Transfer" -SkipArchiveContents
```

---

## Parameters

| Parameter | Type | Description |
|---|---|---|
| `-DebugMode` | Switch | Enables verbose debug output and writes a `debug.log` transcript next to the script |
| `-BasePath` | String | Skips the folder picker and uses the specified path as the scan root (initial build) or comparison target (verification) |
| `-SkipArchiveContents` | Switch | Hashes archive files as opaque blobs only; internal contents are not enumerated |

---

## Workflow

### Step 1 — Initial Build

Run the script before the transfer (before burning to disc, copying to media, etc.). When no initial CSV is found next to the script, the build dialog appears.

**Automatic** prompts for a base folder, then recursively hashes every file under it. For supported archive types, the archive itself is hashed and its contents are enumerated individually. Results are written to a dated CSV:

```
20260514_2226-initial.hashes.csv
```

A sidecar integrity file and a manifest log are also written:

```
20260514_2226-initial.hashes.csv.sha512   ← burn this with the CSV
20260514_2226-initial.manifest.log        ← informational only, do not burn
```

**Manual** allows you to type filename and hash pairs individually — useful when pulling files from a known-good source where hashes are published.

> **Burn to disc:** Copy the CSV and the `.sha512` sidecar file to the disc or transfer medium alongside the data. Do **not** burn the manifest log — it is informational only and is not validated.

### Step 2 — Verification

Run the script after the transfer. When an initial CSV is found next to the script, a mode selection dialog appears before the folder picker.

#### Basic mode

Hashes archive files as opaque blobs only, matching the initial build's top-level entries. Archive-internal entries from the initial CSV are skipped (noted in the log header). Fast — suitable for most transfer verification.

#### Comprehensive mode

Re-runs a full scan of the target folder using the same engine as the initial build, including archive enumeration. Writes a dated rescan CSV:

```
20260514_2231-rescan.hashes.csv
```

The two CSVs are then diffed entry by entry. Every file gets a status in the log:

| Status | Meaning |
|---|---|
| `Verified` | Present in both listings with identical hash |
| `Different` | Present in both listings with a changed hash |
| `Missing` | In the initial listing but absent from the rescan |
| `New` | In the rescan but absent from the initial listing |

The log header shows the entry count delta between the two scans. Both CSVs are always kept after a Comprehensive run.

**Use Comprehensive mode when:** the disc contents may have been tampered with at the archive level (e.g. a file added or removed inside a zip), or when a chain-of-custody record is required.

---

## Output Files

All output files are written next to the script, not into the scan folder. They are automatically excluded from scan listings so they never appear as spurious "New" entries on a rescan.

| File | Created | Description |
|---|---|---|
| `YYYYMMDD_HHMM-initial.hashes.csv` | Initial build | Full hash listing. Burn to disc with the data. |
| `YYYYMMDD_HHMM-initial.hashes.csv.sha512` | Initial build | SHA-512 hashes of the CSV and the `.ps1` script in `sha512sum` format. Burn to disc with the CSV. |
| `YYYYMMDD_HHMM-initial.manifest.log` | Initial build | Human-readable listing of all hashed files with algorithm tags. Archive warnings are included. Do not burn. |
| `YYYYMMDD_HHMM-rescan.hashes.csv` | Comprehensive verify | Full rescan listing. Kept permanently. |
| `YYYYMMDD_HHMM-fileverification.log` | Either verify mode | Per-file results, hash mismatch details, missing and new file lists. |
| `debug.log` | When `-DebugMode` is set | Full transcript of the run. |

---

## Archive Support

The following archive types are supported during the initial build and Comprehensive verification scans. The archive file itself is always hashed. Internal entries are listed using the path `archive.zip\internal\path\file.ext`.

| Extension | Method |
|---|---|
| `.zip` | Streamed via `System.IO.Compression.ZipFile` — no extraction to disk |
| `.tar` | Extracted to a temp folder via `tar.exe`, then cleaned up |
| `.tar.gz` / `.tgz` | Same as `.tar` |
| `.iso` | Mounted via `Mount-DiskImage`, enumerated, then dismounted. AutoPlay is suppressed for the duration of the mount (HKCU registry key, no admin required). |

If an archive fails to enumerate, a warning is added to the manifest log and the run continues. The archive's own hash is still recorded.

---

## CSV Integrity Sidecar

The `.sha512` sidecar file protects against tampering with the initial hash listing or the script itself between the build and the verification run. It uses standard `sha512sum` format and can be verified independently on Linux or macOS:

```bash
sha512sum -c 20260514_2226-initial.hashes.csv.sha512
```

### Behaviour at verification time

| Condition | Result |
|---|---|
| Sidecar file not found | **Blocked.** The sidecar must be present alongside the CSV. |
| Script (`.ps1`) hash mismatch | **Blocked.** The script may have had malicious code added. |
| CSV hash mismatch | **Warning dialog** with Yes/No (default: No). The CSV may have been modified or corrupted; the user may choose to continue with full awareness. |
| All hashes match | Verification proceeds normally. |

---

## Verification Log Format

```
File verification run  [Basic]
Compared against: D:\disc
Initial CSV    : D:\disc\20260514_2226-initial.hashes.csv
Archive-internal entries skipped: 1160 (informational only)

Verified  - AlmaLinux-9.4-aarch64-boot.iso
Verified  - All the Mods 9-0.3.2.zip
Different - filechecker5_10.ps1
Missing   - NBTExplorer-2.8.0\NBTExplorer.exe
Verified  - NBTExplorer-2.8.0\NBTUtil.exe

*********************
Hash mismatches:

  File:     filechecker5_10.ps1
    Original: A97330D8...
    Computed: 1F951EB0...

*********************
Missing files:
  NBTExplorer-2.8.0\NBTExplorer.exe
```

Comprehensive mode adds a `Rescan CSV` header line, an entry count delta line, and a `New files` section if files were found in the rescan that were absent from the initial listing.

---

## Notes for Cybersecurity Use

- **The sidecar file is the root of trust.** Keep a copy of the `.sha512` file somewhere independent of the disc (printed, in a separate system, or committed to a repository) to enable out-of-band verification.
- **Comprehensive mode is the paranoid choice.** It will detect a file added to the inside of a zip or ISO after the initial build — something Basic mode cannot catch.
- **The script covers itself.** The `.ps1` file's hash is recorded in the sidecar. If the script is replaced with a malicious version that skips the integrity check, it will fail its own hash before any verification runs.
- **Hash algorithm:** SHA-512 throughout. No MD5 or SHA-1 is used in any output the script generates; those algorithms appear in the hash-type detection table only for compatibility when reading manually-entered hashes in the Manual build mode.
