# File Checker v6.0

**Author:** Robert Stepp — <robert@robertstepp.ninja>

A PowerShell utility for verifying file integrity across transfers, primarily intended for disc-based archival and chain-of-custody workflows. Run once before a transfer to build a hash listing, then again after to verify nothing changed. Designed with cybersecurity professionals in mind.

---

## The transfer model

Earlier versions wrote the hash listing next to the script. If the script lived outside the folder being burned, you had to remember to copy the listing across — a step that gets forgotten, leaving a transfer that cannot be verified.

**The script now deploys itself into the folder being transferred.** On an initial build it copies itself into the scan folder first, then writes the CSV, sidecar, and manifest next to that copy. The folder you ran it from gets nothing added to it.

```
E:\PS_FileHasher\                    D:\Transfer\
  filechecker6_0.ps1        ──►       filechecker6_0.ps1        (copied in)
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
powershell -File "E:\PS_FileHasher\filechecker6_0.ps1"
```

Skip the folder picker by naming the transfer folder directly:

```powershell
powershell -File "E:\PS_FileHasher\filechecker6_0.ps1" -BasePath "D:\Transfer"
```

Hash archives as opaque blobs, without enumerating their contents (much faster on large ISOs and zips):

```powershell
powershell -File "E:\PS_FileHasher\filechecker6_0.ps1" -BasePath "D:\Transfer" -SkipArchiveContents
```

### Verify (at the destination)

Run the **copy that travelled with the data**, not the original. It finds the listing beside itself and goes straight to the verification dialog.

```powershell
powershell -File "D:\Transfer\filechecker6_0.ps1"
```

Verifying a destination that already holds unrelated data (a patching folder), skipping the folder picker:

```powershell
powershell -File "D:\Transfer\filechecker6_0.ps1" -BasePath "D:\Transfer"
```

Flag files present at the destination that were not in the initial listing, instead of ignoring them:

```powershell
powershell -File "D:\Transfer\filechecker6_0.ps1" -ReportExtraFiles
```

### Verify several destinations from one listing

Tick **"Intermediate scan - keep the initial listing"** in the mode dialog for every destination except the last. The listing survives, and its log and rescan files are tagged `-intermediate`. Leave the box unticked on the final destination and the listing is consumed.

```powershell
powershell -File "D:\Transfer\filechecker6_0.ps1" -BasePath "E:\CopyOne"
```

```powershell
powershell -File "D:\Transfer\filechecker6_0.ps1" -BasePath "E:\CopyTwo"
```

### Troubleshoot a run

Writes a full transcript to `debug.log` next to the script that is running:

```powershell
powershell -File "E:\PS_FileHasher\filechecker6_0.ps1" -DebugMode
```

```powershell
powershell -File "E:\PS_FileHasher\filechecker6_0.ps1" -DebugMode -SkipArchiveContents
```

### Verify the listing out of band

The sidecar is standard `sha512sum` format, so it can be checked without running the script at all — on Linux, macOS, or WSL:

```bash
cd /mnt/d/Transfer && sha512sum -c 20260825_2130-initial.hashes.csv.sha512
```

Or in PowerShell, comparing against the sidecar's recorded value:

```powershell
Get-FileHash "D:\Transfer\filechecker6_0.ps1" -Algorithm SHA512 | Format-List
```

### PowerShell 7

Every command above works with `pwsh` in place of `powershell`. PowerShell 7 gets the modern shell folder picker, which handles Libraries, OneDrive, and typed paths; Windows PowerShell 5.1 gets the legacy folder tree.

```powershell
pwsh -File "E:\PS_FileHasher\filechecker6_0.ps1"
```

---

## Parameters

| Parameter | Type | Description |
|---|---|---|
| `-DebugMode` | Switch | Enables verbose debug output and writes a `debug.log` transcript next to the running script |
| `-BasePath` | String | Skips the folder picker and uses the specified path as the scan root (initial build) or comparison target (verification) |
| `-SkipArchiveContents` | Switch | Hashes archive files as opaque blobs only; internal contents are not enumerated |
| `-ReportExtraFiles` | Switch | Comprehensive mode: flags destination files that were not in the initial listing as differences. By default they are discarded |
| `-IncludeSystemFiles` | Switch | Hashes the volume's own housekeeping files as well — `System Volume Information`, `$RECYCLE.BIN`, `Thumbs.db`, `desktop.ini`, `.DS_Store` and the like. They are skipped by default. See [System Files](#system-files) |
| `-Parallel` | Int | How many child processes hash files at once. Default: 4, or the CPU count if that is lower. `1` hashes in the running process only. See [Parallel Hashing](#parallel-hashing) |
| `-HashWorker` | Switch | Internal. Marks a child process started by the parent; it reads work on stdin and writes results on stdout. Not for interactive use |

---

## Parallel Hashing

Hashing is the slow part of a transfer, and SHA-512 is CPU-bound, so v6.0 spreads
it across processes.

The script you launch is the **parent**. It walks the folder, then starts up to
`-Parallel` **child PowerShell processes** — the same `.ps1`, run with
`-HashWorker` — and feeds them file paths one at a time over stdin. Each child
hashes what it is given and writes the filename and hash back over stdout. The
parent collects everything and writes the CSV, the sidecar, the manifest, and the
logs exactly as before. The parent never hashes alongside the children, so the
machine sees at most `-Parallel` concurrent readers.

Work is handed out as children ask for it rather than split up front, so one child
that draws a run of large files simply asks for its next file later than the
others. Nothing sits idle waiting for a fixed share to finish.

Heavy items are handed out **first**: archives before plain files, and larger
before smaller. Fed in folder order instead, a scan tends to finish with a
handful of workers grinding through whatever large files happened to sort last
while the rest of the pool sits idle — the bar stuck at 90% with the run's worth
of parallelism thrown away in the final stretch. Starting the heavy items first
overlaps them with the thousands of small ones. Archives lead regardless of size,
because a zip's real cost is its expanded contents and nothing can know that
before opening it, so it is the last thing you want to discover at the end. None
of this changes the listing: results are put back into scan order before anything
is written.

```powershell
powershell -File "E:\PS_FileHasher\filechecker6_0.ps1" -Parallel 8
```

**The default is `4`, or the CPU count if that is lower.** It is deliberately not
the full CPU count: this script is pointed at discs and removable media often
enough that saturating every core by default would be the wrong trade for the
common case.

**Use `-Parallel 1` for optical discs and network shares.** Several concurrent
readers on that kind of media are slower than one, not faster. `-Parallel 1` skips
the children entirely and hashes in the running process, which is exactly what
every version up to v5.13 did.

```powershell
powershell -File "D:\Transfer\filechecker6_0.ps1" -Parallel 1
```

Both verification modes benefit. Basic verification hashes the files named in the
CSV through the same pool, in whatever algorithm each row records; Comprehensive
gets it through the rescan, which is the same scan engine as the initial build.

### Watching a run

The progress window shows a line per worker: what it is hashing, how big that
file is, and how long it has been on it.

```
Processed 412 of 2,317          8 workers

  1     0:03     14.2 MB  Media\video-04.mkv
  2     0:00      1.1 MB  Docs\report.pdf
  3     2:47      9.5 MB  build\bundle.zip  (expanding: 94 entries)
  4     0:12     38.0 MB  ...\deepest\longlonglonglong\archive-part-07.bin
  5  1:01:11     40.0 GB  Media\disc-master.iso
  6     0:00       812 B  Docs
otes.txt
  7        -           -  idle
```

The point of it is the question a bar alone cannot answer: **is this hung, or is
one worker three minutes into a 40 GB file?** A stalled bar with a clock ticking
against a large filename is a run doing its job.

`(expanding: N entries)` means the archive's own hash is done and the worker is
enumerating what is inside it — the slowest thing a worker does, and the most
likely to look like a hang. **The count is the useful part.** A number that
climbs is proof the worker is working. A number stuck at `0` for minutes means
something else: the worker has not got inside the archive at all, which points at
the storage rather than at the archive — a cloud-synced placeholder being
rehydrated, an antivirus scanner holding the file open, or a slow network share.
The size column is the archive's *compressed* size, so it is not a guide to how
long expanding it should take.

`idle` means that worker has run out of work because the scan is nearly finished.

Under `-DebugMode`, any single item that took five seconds or more is written to
`debug.log` with its path, size, and duration, so a run that felt slow leaves a
record of which files caused it rather than just a memory of the progress bar
sitting still.

The parent knows this without asking: it chose the work, handed it over, and a
worker reads its input strictly in order, so the oldest item it has not
acknowledged is the one it is on. Nothing is polled and the children send nothing
extra. The panel is rebuilt about twelve times a second, the same rate the window
already repainted at.

Paths longer than the column are trimmed from the left, so the filename always
survives. Sizes are not shown during Basic verification — those work items come
from CSV rows, and statting every row just to fill a column would be real work on
a large listing. Every worker gets a row: the window grows to fit them, up to
whatever the screen has room for, and only past that point are the remainder
summarised as a count. At `-Parallel 16` or `-Parallel 32` on an ordinary display,
nothing is hidden.

A few things are worth knowing:

- **The listing is identical either way.** Results are put back into scan order
  before anything is written, so the CSV — and therefore the `.sha512` taken over
  it — is byte-for-byte the same at `-Parallel 1` and `-Parallel 8`
- **Starting the children costs about half a second.** On a small folder that is
  more than parallel hashing saves, so `-Parallel 1` can finish first. The gain
  shows up on the large transfers the script exists for: roughly 2.3× on a 2 GB
  set at the default, and about 2.5× at `-Parallel 8`
- **ISO files are always expanded by the parent, one at a time.** Mounting a disc
  image needs a drive letter and the AutoPlay setting, which are machine-wide;
  several processes mounting at once would trip over each other. `.zip`, `.tar`,
  `.tar.gz`, and `.tgz` are expanded by the children
- **It falls back on its own.** If the children cannot be started — execution
  policy, AppLocker, Constrained Language Mode, an antivirus hook — or if one dies
  mid-scan, the script warns and hashes sequentially instead. It does not fail
- **Nothing is left behind.** Children are shut down when the pool is finished
  with, including when a scan is cancelled or errors out

---

## Workflow

### Step 1 — Initial Build

Run the script before the transfer. When no initial CSV is found next to the script, the build dialog appears.

**Automatic** prompts for the folder that is going to be burned or transferred, copies the script into it, then recursively hashes every file under it. For supported archive types the archive itself is hashed and its contents are enumerated individually.

You are then asked to name the manifest. The box is prefilled with `Filelist-<scanned folder>.txt` — for a folder called `Transfer` that is `Filelist-Transfer.txt` — and can be edited freely:

- If you leave off an extension, `.txt` is added
- Characters that cannot appear in a filename are replaced with `_`, and any path is stripped, so the manifest always lands in the transfer folder
- If the name is already taken, `_2`, `_3`, … is appended rather than overwriting
- Leaving the box empty uses the prefilled default

The CSV and `.sha512` always keep their timestamped names — verification finds the CSV by the `*-initial.hashes.csv` pattern and pairs the sidecar off that exact name.

> **If you use a custom manifest name,** be aware that only the default `Filelist-*.txt` and `*-initial.manifest.log` names are recognised as script output and kept out of later scans. A manifest called something else that is left in the folder will be hashed as ordinary payload if you rebuild that folder, and will show up as an extra file on a Comprehensive verify (discarded by default). Delete or move old manifests before rebuilding if that matters to you.

The manifest's `Files:` section lists **every file in the transfer folder** — the payload, the deployed `.ps1`, the CSV, and the `.sha512`. The CSV and sidecar are written after the scan, so they are named in the listing but carry no hash of their own: the CSV cannot contain its own hash, and the `.sha512` is what records the CSV's. The manifest does not list itself.

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
| `filechecker6_0.ps1` | The script itself, copied in before the scan and included in the listing |
| `YYYYMMDD_HHMM-initial.hashes.csv` | Full hash listing |
| `YYYYMMDD_HHMM-initial.hashes.csv.sha512` | SHA-512 hashes of the CSV and the `.ps1`, in `sha512sum` format |
| `Filelist-<folder>.txt`, or whatever you name it | Human-readable listing of every file in the folder, plus any archive warnings |

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

## System Files

Every volume carries housekeeping that has nothing to do with the data on it, and
none of it is part of a transfer. It is skipped by default.

**Folders**, along with everything beneath them, wherever they appear in the tree
— not only at the root:

`System Volume Information` · `$RECYCLE.BIN` · `RECYCLER` · `Config.Msi` ·
`$WinREAgent` · `$SysReset` · `$Windows.~BT` · `$Windows.~WS` · `$GetCurrent` ·
`lost+found` · `.Trashes` · `.Trash-<uid>` · `.Spotlight-V100` · `.fseventsd` ·
`.TemporaryItems` · `.DocumentRevisions-V100` · `found.000` and its siblings

**Files**:

`Thumbs.db` · `ehthumbs.db` · `IconCache.db` · `desktop.ini` · `pagefile.sys` ·
`hiberfil.sys` · `swapfile.sys` · `DumpStack.log` · `.DS_Store` · `._*`
(macOS resource forks) · `.apdisk`

They are skipped from the folder count as well as the file listing, so a folder
total is a total of folders that hold data.

This is not only tidiness. On a Comprehensive verify with `-ReportExtraFiles`,
every formatted NTFS volume has its own `System Volume Information` — which would
otherwise be reported as a difference on a transfer where nothing at all went
wrong.

The list is deliberately conservative. Anything that could plausibly *be* the
payload is left alone: `bootmgr`, `autorun.inf`, `EFI`, and `boot` are real
content on bootable media people genuinely transfer, so none of them are on it.
Matching is exact, not fuzzy — a folder called `Recycler Parts`, a file called
`Thumbs.db.bak`, and a `found.0000` that no `chkdsk` created are all kept.

```powershell
powershell -File "E:\PS_FileHasher\filechecker6_0.ps1" -IncludeSystemFiles
```

`-IncludeSystemFiles` hashes everything, for forensic work where the volume
itself is the subject and its housekeeping is evidence.

Nothing about the exclusions appears in the manifest or the verification log:
these files are not part of the transfer, so a section counting them would be a
record of what was never being described. Under `-DebugMode`, every skipped path
is written to `debug.log`.

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

## Change History

This is the canonical change log — the script itself does not carry one. Earlier releases are kept in `Archive/`.

Versions 4.1–4.4, 5.0–5.4, and 5.6 are not in the archive, so there are no entries for them. The notes for 5.7, 5.8, and 5.9 come from change logs those versions carried in their own headers; the rest are derived by comparing the archived scripts against each other.

### v6.0

- **Hashing runs in parallel across child processes.** The script is now the
  parent: it starts up to `-Parallel` copies of itself with `-HashWorker`, feeds
  each of them file paths over stdin, and collects the filename and hash they
  return over stdout. The default is 4, or the CPU count if that is lower;
  `-Parallel 1` hashes in the running process and is byte-for-byte the v5.13
  behaviour. See [Parallel Hashing](#parallel-hashing)
- Work is fed to the children as they ask for it rather than split up front, so a
  child that draws several large files does not hold up the rest of the pool
- **Run times are recorded.** The manifest header, the verification log header,
  and the closing dialogs of both the build and a verification run report how
  long the run spent walking the tree and how long it spent hashing, as two
  separate figures. They answer different questions: enumeration scales with the
  number of files and is unaffected by `-Parallel`, hashing scales with the
  number of bytes and is what `-Parallel` changes. Basic verification walks the
  CSV rather than the disk, so it reports a hash time and no enumeration time
- **The volume's own system files are skipped** — `System Volume Information`,
  `$RECYCLE.BIN`, `Thumbs.db`, `desktop.ini`, `.DS_Store` and the rest, along
  with the whole subtree under a system folder wherever it appears in the tree.
  They are excluded from the folder count as well as the listing.
  `-IncludeSystemFiles` hashes them anyway. Beyond the tidiness, this stops a
  Comprehensive verify with `-ReportExtraFiles` reporting the destination
  volume's own `System Volume Information` as a difference. See
  [System Files](#system-files)
- **Heavy items are hashed first** — archives before plain files, larger before
  smaller — so a scan no longer ends with most of the pool idle while a few
  workers finish off whatever large files happened to sort last. Feed order and
  output order are independent, so the CSV is unchanged
- The worker panel lists **every** worker. It previously stopped at twelve and
  summarised the rest, so a `-Parallel 16` run hid four workers on a display with
  room for fifty. The window now grows to fit the pool, bounded by the screen
  rather than by a fixed number, and the window and the panel are sized from the
  same figure instead of each hardcoding its own
- **The expanding marker carries a live entry count**, and `-DebugMode` records
  any item taking five seconds or more to `debug.log` with its path, size, and
  duration. Between them these separate "this archive is big" from "this archive
  is not being read at all", which the compressed size in the panel cannot
- **The progress window lists what every worker is on**, with the file's size and
  how long that worker has been on it, so a stalled bar can be told apart from a
  hang. `(expanding)` marks a worker enumerating an archive's contents; `idle`
  marks one that has run out of work. The parent derives all of this from what it
  already handed out — no extra traffic from the children — and builds the panel
  only when a repaint is due, about twelve times a second
- Both verification modes use the pool. Basic verification hashes the files named
  in the CSV, in whatever algorithm each row records; Comprehensive gets it
  through the rescan
- `.zip`, `.tar`, `.tar.gz`, and `.tgz` are expanded inside the children. `.iso`
  files stay with the parent and are mounted one at a time, because a drive letter
  and the AutoPlay setting are machine-wide and concurrent mounts would race
- Results are put back into scan order before anything is written, so the CSV and
  its `.sha512` are identical at every `-Parallel` setting
- The script falls back to sequential hashing, with a warning, if the children
  cannot be started or one exits early. Execution policy, AppLocker, Constrained
  Language Mode, and antivirus hooks all land here, and none of them now stop a run
- **Filenames with non-ASCII characters survive the CSV.** Both listings and the
  Comprehensive rescan are written as UTF-8 with a BOM, and read back the same
  way, rather than taking whatever the host defaults to. Windows PowerShell 5.1's
  `Export-Csv` defaults to ASCII, so `café.txt` went into the CSV as `caf?.txt`
  and verification then reported it Missing on a transfer where nothing was
  wrong. The defect is not new in v6.0 — it is in v5.13 and every version before
  it, and only ever bit on 5.1, since PowerShell 7 already wrote UTF-8. The
  encoding is named per host (`UTF8` on 5.1, `utf8BOM` on 7 — the same bytes
  either way, verified identical) because a listing built on one host is
  routinely verified on the other, and the `.sha512` has to match on both. CSVs
  from older versions still read correctly; the `?` in them was substituted when
  they were written and cannot be recovered
- Renamed to `filechecker6_0.ps1`; v5.13 is in `Archive/`

### v5.13

- The manifest filename is typed into a free-text box prefilled with `Filelist-<scanned folder>.txt`, replacing the earlier choice between two fixed conventions. `.txt` is appended if no extension is given, invalid characters and any path are stripped, and an existing name gets `_2`, `_3`, … rather than being overwritten
- The manifest's `Files:` section lists every file in the transfer folder, the CSV and `.sha512` included. Those two are written after the scan, so they are named in the listing but carry no hash of their own. The separate "Transfer files" section is gone — its entries are now in the main listing
- Removed the change log from the script header; it lives here instead

### v5.12

**Behaviour changes**

- The initial build copies the script into the folder being transferred and writes the CSV, sidecar, and manifest next to that copy. The folder the script was run from gets nothing added to it, except `debug.log` under `-DebugMode`, which starts before the folder is chosen. The script is copied before the scan, so it is hashed into the listing and verified like any other transferred file
- Comprehensive mode discards destination files that were not in the initial listing instead of counting them as differences, so verifying into a folder that already holds unrelated data (a patching folder) no longer reports it as a difference. `-ReportExtraFiles` restores the previous behaviour. Basic mode already worked this way, so the two modes now agree
- Both modes share one retention rule for the initial listing, with an **"Intermediate scan - keep the initial listing"** checkbox on the mode dialog. Previously this was hardcoded in Basic, absent from Comprehensive, and described by two contradictory comments. Comprehensive therefore now consumes the initial listing on a clean final scan, where before it never did. The rescan CSV is always kept, and nothing is deleted when differences were found
- The sidecar integrity check (script + CSV) runs at startup, before any dialog. It previously ran after both the mode dialog and the folder picker, even though it never depended on either answer
- An intermediate verification tags its output filenames — `<stamp>-intermediate-fileverification.log` and `<stamp>-intermediate-rescan.hashes.csv`. Verification stamps also gained seconds, so back-to-back runs against several destinations no longer overwrite each other
- The manifest header counts folders; the listing itself is files only, since every folder holding a file already appears as that file's path prefix

**Fixes**

- AutoPlay suppression used non-terminating registry calls, so on a machine where the HKCU Policies key is locked down the raw errors leaked to the console for every ISO instead of being caught. This was the "extra error" seen while the ISO still mounted, read, and unmounted
- A spurious "Not running as admin" archive warning was raised for every ISO before the mount was even attempted, so a successful mount/read/dismount still reported a warning. The elevation state is now mentioned only if a mount actually fails
- Manual mode wrote a CSV but no `.sha512` sidecar, so the verification it launched immediately hard-blocked on "No integrity sidecar found"
- A clean Basic verification deleted the CSV but orphaned its sidecar
- The folder picker set `RootFolder = MyComputer`, which roots the legacy tree at This PC — Desktop, Documents, and the other Libraries sit above This PC in the shell namespace and were unreachable. Picking a Library, which has no path on disk, now explains itself and re-prompts instead of reporting "No folder selected"
- With two initial CSVs present, the older one could be selected; the newest is now chosen deterministically
- Faster scanning: one reusable hash provider, buffered sequential reads, and a throttled progress UI instead of a full repaint per file

### v5.11

- Added a **Data Transfer Name** prompt at the start of an automatic build. The name entered becomes the first line of the manifest, so a listing can be identified by job rather than by timestamp alone
- The CSV, sidecar, and manifest are generated from a single timestamp so all three filenames match exactly. Previously each called `Get-Date` separately, and a build crossing a minute boundary produced names that disagreed

### v5.10

- Housekeeping release, no behaviour change. Functions were renamed to satisfy PowerShell naming conventions, chiefly singular nouns: `Get-ZipContentHashes` → `Get-ZipContentHash`, `Publish-FileTotals` → `Publish-FileTotal`, `Compare-Hashes` → `Compare-HashEntry`, `Compare-HashesThorough` → `Compare-HashEntryThorough`, `Search-InitialFileExists` → `Search-InitialFileExistence`, and the remaining archive readers likewise
- The accumulated per-version notes were dropped from the script header, which is why the 5.10 file is shorter than 5.9 despite doing the same work

### v5.9 — CSV integrity sidecar

- An automatic build now writes a sidecar next to the CSV in `sha512sum` format, holding SHA-512 hashes of two files: the CSV itself and the `.ps1`. Burn it to disc with the CSV
- Every verification run rehashes both and compares them against the recorded values before trusting the listing
- Missing sidecar: blocked outright, treated as a workflow error — the sidecar was not burned
- Script hash mismatch: hard block, on the grounds that the script may have been modified
- CSV hash mismatch: warning dialog explaining the listing may have been altered or corrupted, Yes/No to continue, defaulting to No
- `*.sha512` added to the script-output exclusions so sidecars never appear in a scan listing

### v5.8

- `Invoke-FileScan` skips files matching the script's own output patterns before hashing them — `*-initial.hashes.csv`, `*-initial.manifest.log`, `*-rescan.hashes.csv`, `*-fileverification.log`, `debug.log`. These sit next to the script and would otherwise always appear as `New` on a Comprehensive rescan whenever the script folder was the scan target
- Fixed: `rescanLookup` was built by calling `.ToArray()` on an already-unwrapped `object[]`, which returned `$null`; it now iterates the rescan list directly

### v5.7 — Basic / Comprehensive modes

- A mode-selection dialog now appears when a verification run starts, before the folder picker:
  - **Basic** — the previous behaviour. Archives are compared as opaque files and archive-internal entries from the initial CSV are skipped. Fast
  - **Comprehensive** — a full re-scan of the chosen folder, identical to an initial build, written to a second dated CSV. The two listings are then diffed by path, giving every file a status of `Verified`, `Different`, `Missing`, or `New`, with the entry-count delta noted in the log header

### v5.5 — rewrite

The script was restructured rather than extended, ending up about a sixth shorter than 4.0 while doing considerably more.

- Proper `param()` block: `-DebugMode`, `-BasePath`, and `-SkipArchiveContents`. Debug output became opt-in again, and `-BasePath` skips the folder picker
- Archive handling split into one reader per format — `Get-ZipContentHashes`, `Get-TarContentHashes`, `Get-IsoContentHashes` — behind a single dispatcher, adding `.tar`, `.tar.gz`, and `.tgz` alongside the existing `.zip` and `.iso`. Zip entries are hashed from their streams instead of being extracted to disk
- Archive failures collect into a warnings list surfaced in the manifest, rather than aborting the run
- A dated **manifest log** is written next to the CSV: a readable record of the build, its scan root, and any archive warnings
- AutoPlay is suppressed for the duration of an ISO mount through a per-user registry key, so File Explorer does not pop open. No elevation required
- WinForms code consolidated into helpers (`New-FormControl`, `New-ProgressUI`, `Invoke-ProgressLoop`), and the verification log moved into `Write-VerificationLog`. Every non-skipped file now gets an aligned status line, with labelled Original/Computed hashes per mismatch
- Fixed a scoping bug where `.Add()` calls and counter increments inside a scriptblock mutated a nested-scope copy, leaving the verification log body empty
- The separate **External** comparison mode was dropped. `Resolve-BasePath` always asks which folder to compare against, which covers the same case without a second code path

### v4.0

- Added archive support: `.zip` is extracted through `System.IO.Compression.FileSystem` and `.iso` is mounted with `Mount-DiskImage`, so the files inside them are hashed individually instead of the container being treated as one opaque blob
- Debug output was left switched on in this release — `$DebugPreference` is hardcoded to `Continue` — and the transcript is written to the working directory rather than the script folder

### v3.1

- Fixed the External comparison mode, which ignored the folder you selected. It built each file path from the script's own folder instead of the chosen external path, so it compared the wrong location and would report everything missing when run against a disc

### v3.0 — earliest archived version

The starting point: build a CSV of file hashes, then re-run to compare against it.

- GUI-driven throughout, with a progress bar during hashing
- Automatic build (pick a folder, hash everything under it) or Manual build (type filename and hash pairs by hand)
- Comparison against either the local folder or a nominated External location, the latter intended for read-only media
- Hash type inferred from the recorded hash's length, so listings using MD5, SHA-1, SHA-256, SHA-384, or SHA-512 can all be read
- Output: a dated `*-initial.hashes.csv` and a dated `*-fileverification.log`

### Not archived

`Archive/filechecker_4.5.ps1` is a scaffold rather than a release — eighteen function declarations with empty bodies and placeholder doc comments, sketching a refactor that landed in a different shape in 5.5. It will not run.
