# UltraCHD – Quick Start Guide

UltraCHD is an automated tool for converting disc images into CHD format with safe,
zero-risk cleanup logic and automatic system detection.

## Requirements

- Windows 10/11
- PowerShell 5+ or PowerShell 7+
- `chdman.exe` (from MAME or RetroArch) — required
- `7za.exe` (standalone 7-Zip console binary) — required for `.7z` archives; download from [7-zip.org](https://www.7-zip.org/download.html)
- `UnRAR.exe` (freeware command-line UnRAR by RARlab) — required for `.rar` archives; download from [rarlab.com](https://www.rarlab.com/rar_add.htm) ("UnRAR for Windows")

`.zip` archives work with no additional tools. `7za.exe` and `UnRAR.exe` are only needed if you have archives in those formats.

## Setup

1. Place `UltraCHD.ps1`, `UltraCHD.bat`, and `chdman.exe` in the same directory as your archives.
2. Optionally place `7za.exe` and/or `UnRAR.exe` in the same directory if you have `.7z` or `.rar` archives.
3. Run via the batch launcher or directly in PowerShell:

```bat
UltraCHD.bat
```

```powershell
.\UltraCHD.ps1
```

For each archive in the directory, UltraCHD will:

1. Extract the archive to a temporary working directory
2. Identify the disc image file (`.cue`, `.gdi`, `.iso`, `.img`, or `.bin`)
3. Detect the system automatically from sector-level disc signatures — no manual configuration required
4. Convert the disc image to CHD using the correct CHDMAN command for the detected system
5. Move the source archive to `UltraCHD_Done/` on success, or quarantine it to `UltraCHD_Failed/` on failure
6. Clean up the temporary working directory regardless of outcome

Supported archive formats: `.zip`, `.7z`, `.rar` — one disc per archive. Loose source files (`.cue`, `.gdi`, `.iso`, `.img`, `.bin`) placed directly in the script folder are also processed without an archive wrapper.

## Supported Systems

UltraCHD automatically identifies the system from disc image headers — no manual configuration needed.

| System | Formats |
|---|---|
| PlayStation 1 | `.cue`/`.bin`, `.iso` |
| PlayStation 2 (CD) | `.cue`/`.bin`, `.iso` |
| PlayStation 2 (DVD) | `.cue`/`.bin`, `.iso` |
| PSP | `.iso` |
| Sega Saturn | `.cue`/`.bin`, `.iso` |
| Sega CD / Mega-CD | `.cue`/`.bin`, `.iso` |
| Dreamcast | `.gdi`, `.cue`/`.bin` |
| PC Engine CD / TurboGrafx-CD | `.cue`/`.bin`, `.img` |
| Neo Geo CD | `.cue`/`.bin`, `.img` |
| CD-i | `.cue`/`.bin`, `.iso` |
| CD-i Ready (all-audio) | `.cue` |
| 3DO | `.cue`/`.bin`, `.iso` |

## Output Structure

```
YourFolder/
├── chdman.exe
├── 7za.exe                   ← required for .7z archives
├── UnRAR.exe                 ← required for .rar archives (optional)
├── UltraCHD.ps1
├── UltraCHD.bat
├── GameName.chd              ← converted output
├── UltraCHD_Archives/        ← source archives after successful extraction
└── UltraCHD_Failed/
    ├── Archives/             ← archives that could not be extracted
    ├── Conversion/           ← archives where CHD creation failed
    └── Validation/           ← archives that failed post-conversion checks
```

## Safety Notes

- Source archives are **moved, never deleted** — originals are always preserved in `UltraCHD_Done/` or `UltraCHD_Failed/`.
- Failed archives are automatically quarantined by failure type so you know exactly what went wrong.
- Unrecognized disc images are quarantined rather than blindly converted.
- Temp extraction folders are always cleaned up after each game, success or failure.

## Known Limitations

These archive and disc image structures are not fully supported in 0.9.0. Source archives are never deleted, so nothing is lost — but be aware of the following:

| Situation | Behaviour |
|---|---|
| DiscJuggler `.cdi` image | Detected and quarantined with a clear error — modern chdman cannot convert this format; convert to GDI or BIN/CUE first |
| Archive with more than one level of nested folders | Conversion will fail — CUE and BIN files get separated during flattening |
| Multiple discs packed into a single archive | Only the first disc found will be converted; others are silently skipped |
| ISO + WAV files with no CUE sheet | ISO converts correctly but WAV audio tracks are omitted from the CHD |
| Single BIN with no CUE sheet (multi-track disc) | Audio tracks are omitted — a CUE sheet is required for complete conversion |
| Unquoted CUE FILE reference with spaces in filename | CUE parsing fails — quoted filenames are handled correctly |

**Recommendation:** one disc per archive, files at root or one folder deep, CUE sheet always present for multi-track titles.

## Recommended

- Use Windows Terminal with Cascadia Mono for proper Unicode display.
- Keep archives organized: one game per archive.

UltraCHD is designed for batch processing — point it at a directory and let it work.

---

*UltraCHD is written and maintained by Paul Swonger ([@smokeluce](https://github.com/smokeluce)).*
