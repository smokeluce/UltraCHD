# Changelog

All notable changes to UltraCHD are documented here.

---

## [0.9.0] – 2026-03-04

### Added
- **Sega Saturn detection** — `SEGA SEGASATURN` header at sector 0, checked at both cooked (`0x00`) and raw (`0x10`) offsets
- **Sega CD / Mega-CD detection** — `SEGADISCSYSTEM` header at sector 0, cooked and raw offsets
- **Dreamcast CUE/BIN detection** — `SEGA SEGAKATANA` header with sector-walking scan across the first 4 MB to handle multi-track dumps where the signature lives in the high-density area
- **PC Engine CD / TurboGrafx-CD detection** — `PC Engine CD-ROM SYSTEM` at sector 1 payload offset; CUE parser calculates exact byte offset of the data track in single-file concatenated images via MSF timestamp; handles raw (`+0x30`) and cooked (`+0x20`) sector layouts
- **Neo Geo CD detection** — `IPL.TXT` presence in ISO 9660 directory records; unique to Neo Geo CD and reliably present in the first 4 MB of the data track
- **`.img` format support** — added to archive file discovery and detection pipeline for CloneCD-style dumps
- **`.rar` archive support** — via `UnRAR.exe` (freeware, RARlab); script reports a clear error with download URL if `UnRAR.exe` is not present
- **`.7z` archive support** — restored via `7za.exe`; script gracefully reports missing `7za.exe` rather than failing silently
- **Loose source file processing** — Pass 1 of the main loop now handles `.cue`, `.gdi`, `.iso`, `.img`, `.bin`, and `.cdi` files sitting directly in the script folder without an archive wrapper; groups by `BaseName` so CUE/BIN pairs are processed correctly
- **DiscJuggler `.cdi` detection** — identified by footer signature (`0x80000004` v2.0, `0x80000006` v3.x); quarantined with a clear error message explaining the format is unsupported by modern chdman and pointing to a conversion path
- **`UltraCHD_Archives/` folder** — extracted archives are moved here immediately after successful extraction, before conversion
- **Categorized failure folders** — `UltraCHD_Failed/Archives`, `UltraCHD_Failed/Conversion`, `UltraCHD_Failed/Validation` restored so failure type is immediately apparent
- **`Get-CHDCommand` routing** — restored correct `createcd` vs `createdvd` dispatch per system; PS2DVD and PSP now correctly use `createdvd`
- **`Read-Bytes` stream reader** — restored efficient partial file reading (4 MB cap) with optional `$Offset` parameter for seeking into concatenated single-file images
- **`Get-CueSectorOffset` helper** — converts CUE MSF timestamps to byte offsets for single-file image seeking
- **`Test-SignatureAtOffsets` helper** — reusable byte-level signature checker used across all Sega and PCE detection functions
- **Single shared extract directory** — `UltraCHD_Extract/` replaces per-game temp directories; always cleaned up in `finally` block
- **Script renamed** — `convert.ps1` renamed to `UltraCHD.ps1` for consistency with project name
- **Author credit** — Paul Swonger (smokeluce) credited in script header, LICENSE, README, and QUICKSTART
- **MIT License** — project licensed under MIT; `LICENSE` file includes third-party notice for bundled `chdman.exe` (GPL-2.0)
- **System badges** — shields.io badges added to README for all 12 supported systems with platform-accurate brand colors
- **`QUICKSTART.md`** — Quick Start guide converted from `.txt` to `.md` and updated to reflect current script name, archive formats, output structure, and supported systems

### Changed
- Detection order formalized: Saturn → Sega CD → Dreamcast → CD-i → 3DO → PSP → PC Engine CD → Neo Geo CD → PS2DVD → PS2CD → PS1 — most specific signatures checked first to eliminate false positives
- `Detect-PS2CD` rewritten — replaced unreliable raw sync-byte scan (fired on all Mode 2 CDs including PS1) with `BOOT2` string check from embedded `SYSTEM.CNF` content
- `Detect-DVD` corrected — previous implementation matched `CD001` anywhere in the data; now correctly checks for the full ISO 9660 primary volume descriptor header including the leading `0x01` type byte
- `Detect-3DO` corrected — replaced incorrect ASCII `OPERA` string scan at fixed offset `0x3C` with proper binary check for the Opera filesystem disc label header (`0x01` record type + five `0x5A` sync bytes at offset `0x00` or `0x10`)
- `Detect-NeoGeoCD` simplified — removed fragile `NEO-GEO` offset check at `0x100`/`0x910` (program binary area, not reliably in a 4 MB sector read); `IPL.TXT` alone is the detection signal
- CUE parser rewritten as a line-by-line state machine — correctly identifies the data track file and its INDEX 1 MSF in both single-file and multi-file CUEs; previous regex-based approach grabbed the first FILE entry which is often an audio track
- `.rar` extraction separated from `.7z` — now routed through `UnRAR.exe` instead of `7za.exe` (which does not support RAR decompression due to RARlab licensing)
- `UltraCHD.bat` updated to call `UltraCHD.ps1`
- README overhauled — Features, Requirements, Usage, System Detection, Output Structure, Known Limitations, Versioning, License, and Acknowledgments sections all updated to reflect 0.9.0 state

### Fixed
- 3DO discs incorrectly detected as PS1 — Opera filesystem binary header check now used instead of ASCII string scan
- Neo Geo CD discs incorrectly detected as PS1 — `IPL.TXT` directory scan replaces unreachable program-area offset check
- PC Engine CD discs incorrectly detected as PS1 — CUE MSF offset calculation now seeks to the data track start before reading; raw sector signature offset corrected from `+0x20` to `+0x30` to account for the 16-byte sync header
- Multi-track single-file CUEs (e.g. PC Engine CD, CD-i) where the data track is not the first track were always reading audio data for system detection
- RAR archives silently failing — `7za.exe` does not support RAR; now correctly routed to `UnRAR.exe` with a clear error if not present

### Removed
- Flat `UltraCHD_Failed/` folder replaced by categorized subdirectories
- `UltraCHD_Done/` folder removed — processed archives now live in `UltraCHD_Archives/`

---

## [0.8.0] – 2026-03-03

### Added
- **CD-i detection** — `CD-RTOS` / `CD-I` markers checked across multiple sector offsets (`0x9310`, `0x9318`, `0x9328`, `0x8010`, `0x8000`)
- **CD-i Ready detection** — all-audio CUE sheets with no data tracks classified as CD-i Ready

### Changed
- Major internal rewrite — detection and conversion logic consolidated into a simpler single-file structure
- Archive handling simplified to ZIP-only via `Expand-Archive`

### Removed
- PS2CD, PS2DVD, PSP, Dreamcast, 3DO detection functions lost in rewrite
- `Get-CHDCommand` routing lost — all conversions incorrectly used `createcd` regardless of system
- CHD post-conversion validation lost
- Categorized failure folders replaced with flat `UltraCHD_Failed/`
- `.7z` and `.rar` archive support lost
- `Read-Bytes` stream reader replaced with `ReadAllBytes`

---

## [0.7.0] – Initial Release

### Added
- **PS1 detection** — fallback for CUE/BIN with a data track and no other system markers
- **PS2CD detection** — raw CD sync byte pattern scan
- **PS2DVD detection** — UDF filesystem markers (`NSR02` / `NSR03`) and ISO 9660 volume descriptor scan
- **PSP detection** — `UMD_DATA.BIN` and `PSP_GAME` string presence
- **Dreamcast detection** — `.gdi` file extension
- **3DO detection** — `OPERA` filesystem signature at offset `0x3C`
- **`Get-CHDCommand`** — correct `createcd` / `createdvd` / `create3do` dispatch per detected system
- **CHD post-conversion validation** — `chdman info` parsed after conversion to verify output type and sector size match expected system profile
- **Categorized failure folders** — `UltraCHD_Failed/Archives`, `/Conversion`, `/Validation`
- **`.7z` and `.rar` support** — via `7za.exe`
- **`Read-Bytes` stream reader** — efficient partial file reading capped at 4 MB
- **`Move-ToFailureCategory`** — per-game quarantine folders within each failure category
- **Sector alignment check** — pre-conversion size validation for DVD-like systems (PS2DVD, PSP)
- **Startup and completion beeps** — audio feedback on batch start and successful CHD creation
