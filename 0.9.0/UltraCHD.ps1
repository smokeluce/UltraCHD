#region Initialization
# UltraCHD v0.9.0
# Author: Paul Swonger (smokeluce)
# https://github.com/smokeluce/UltraCHD
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ProgressPreference = 'SilentlyContinue'

Set-Location -Path $PSScriptRoot
$Chdman = Join-Path $PSScriptRoot "chdman.exe"

$FailedRoot          = Join-Path $PSScriptRoot "UltraCHD_Failed"
$FailedArchivesDir   = Join-Path $FailedRoot "Archives"
$FailedConversionDir = Join-Path $FailedRoot "Conversion"
$FailedValidationDir = Join-Path $FailedRoot "Validation"

foreach ($path in @($FailedRoot, $FailedArchivesDir, $FailedConversionDir, $FailedValidationDir)) {
    if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
}

$DoneRoot = Join-Path $PSScriptRoot "UltraCHD_Done"
if (-not (Test-Path $DoneRoot)) { New-Item -ItemType Directory -Path $DoneRoot | Out-Null }

$ArchivesRoot = Join-Path $PSScriptRoot "UltraCHD_Archives"
if (-not (Test-Path $ArchivesRoot)) { New-Item -ItemType Directory -Path $ArchivesRoot | Out-Null }

$ExtractDir = Join-Path $PSScriptRoot "UltraCHD_Extract"
#endregion Initialization

#region Utility Functions
function Read-Bytes {
    param(
        [string]$Path,
        [long]$Offset = 0,
        [int]$Count = 4194304  # 4 MB - enough for all header/signature checks
    )
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        if ($Offset -gt 0) { $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin) | Out-Null }
        $buffer = New-Object byte[] $Count
        $read = $fs.Read($buffer, 0, $Count)
        # Return only the bytes actually read (file may be smaller than $Count)
        if ($read -lt $Count) {
            $trimmed = New-Object byte[] $read
            [Array]::Copy($buffer, $trimmed, $read)
            return $trimmed
        }
        return $buffer
    }
    finally {
        $fs.Close()
    }
}

function Move-ToFailureCategory {
    param(
        [string]$Category,   # "Archives", "Conversion", "Validation"
        [string]$GameName,
        [string[]]$FilesToMove
    )
    switch ($Category) {
        "Archives"   { $targetRoot = $FailedArchivesDir }
        "Conversion" { $targetRoot = $FailedConversionDir }
        "Validation" { $targetRoot = $FailedValidationDir }
        default      { $targetRoot = $FailedRoot }
    }
    $gameFolder = Join-Path $targetRoot $GameName
    if (-not (Test-Path $gameFolder)) { New-Item -ItemType Directory -Path $gameFolder | Out-Null }
    foreach ($file in $FilesToMove) {
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        if (Test-Path $file) {
            $dest = Join-Path $gameFolder (Split-Path $file -Leaf)
            try { Move-Item -LiteralPath $file -Destination $dest -Force }
            catch { Write-Host "[WARN] Failed to move '$file': $($_.Exception.Message)" -ForegroundColor DarkYellow }
        }
    }
    Write-Host "[MOVED] Files moved to UltraCHD_Failed\$Category\$GameName" -ForegroundColor DarkYellow
}
#endregion Utility Functions

#region Detection Functions

# Helper: read a string from a byte array at a given offset and length.
function Read-AsciiString {
    param([byte[]]$Data, [int]$Offset, [int]$Length)
    if ($Data.Length -lt ($Offset + $Length)) { return "" }
    return [System.Text.Encoding]::ASCII.GetString($Data[$Offset..($Offset + $Length - 1)])
}

# Helper: check for a signature string at multiple candidate offsets.
# Returns $true if any offset contains the signature.
function Test-SignatureAtOffsets {
    param([byte[]]$Data, [string]$Sig, [int[]]$Offsets)
    $sigBytes = [System.Text.Encoding]::ASCII.GetBytes($Sig)
    $sigLen   = $sigBytes.Length
    foreach ($off in $Offsets) {
        if ($Data.Length -lt ($off + $sigLen)) { continue }
        $match = $true
        for ($i = 0; $i -lt $sigLen; $i++) {
            if ($Data[$off + $i] -ne $sigBytes[$i]) { $match = $false; break }
        }
        if ($match) { return $true }
    }
    return $false
}

# Sega Saturn: "SEGA SEGASATURN " at offset 0x00 (cooked ISO) or 0x10 (raw 2352-byte sector,
# after the 16-byte sync header). Both offsets are checked.
function Detect-Saturn {
    param([byte[]]$Data)
    return (Test-SignatureAtOffsets -Data $Data -Sig "SEGA SEGASATURN " -Offsets @(0x00, 0x10))
}

# Sega CD / Mega-CD: "SEGADISCSYSTEM  " at offset 0x00 (cooked) or 0x10 (raw).
# Also catches "SEGABOOTDISC    ", "SEGADATADISC    ", "SEGADISC        " per the BIOS spec,
# but SEGADISCSYSTEM is the only one used on retail game discs.
function Detect-SegaCD {
    param([byte[]]$Data)
    return (Test-SignatureAtOffsets -Data $Data -Sig "SEGADISCSYSTEM  " -Offsets @(0x00, 0x10))
}

# Dreamcast: "SEGA SEGAKATANA " at offset 0x00 (cooked) or 0x10 (raw).
# GD-ROMs have this in the high-density area (track 3 in CUE dumps).
# Since the CUE entry file is track 1, the katana sig won't be at offset 0 of the first BIN.
# We do a broader scan over the first 4 MB to catch it wherever it lands in multi-track dumps.
function Detect-Dreamcast {
    param([byte[]]$Data)
    # Fast path: check standard offsets first
    if (Test-SignatureAtOffsets -Data $Data -Sig "SEGA SEGAKATANA " -Offsets @(0x00, 0x10)) {
        return $true
    }
    # Broader scan: walk 2352-byte sectors (raw) up to 4 MB looking for the signature
    $sig = [System.Text.Encoding]::ASCII.GetBytes("SEGA SEGAKATANA ")
    for ($off = 0; $off -le ($Data.Length - $sig.Length); $off += 0x930) {
        $match = $true
        for ($i = 0; $i -lt $sig.Length; $i++) {
            if ($Data[$off + $i] -ne $sig[$i]) { $match = $false; break }
        }
        if ($match) { return $true }
        # Also check raw offset (0x10 into each sector)
        $rawOff = $off + 0x10
        if ($rawOff + $sig.Length -le $Data.Length) {
            $match = $true
            for ($i = 0; $i -lt $sig.Length; $i++) {
                if ($Data[$rawOff + $i] -ne $sig[$i]) { $match = $false; break }
            }
            if ($match) { return $true }
        }
    }
    return $false
}

# PC Engine CD / TurboGrafx-CD: "PC Engine CD-ROM SYSTEM" is written at byte 32 (+0x20) of
# sector 1 of the data track. For separate-file CUEs the data file starts at offset 0, so the
# sig is near the top. For single-file CUEs (all tracks concatenated) the sig is at a variable
# byte offset determined by the INDEX position of the data track in the CUE.
# Detect-PCEngineCD therefore takes an optional $DataOffset parameter (default 0) so the caller
# can pass in the pre-calculated byte offset of the data track inside the image file.
function Detect-PCEngineCD {
    param([byte[]]$Data)
    $sig = [System.Text.Encoding]::ASCII.GetBytes("PC Engine CD-ROM SYSTEM")
    $sigLen = $sig.Length
    # The buffer is already seeked to the start of the data track by the caller.
    # The signature sits at byte 32 of the sector DATA payload (after any sync/header bytes).
    # Cooked (2048 b/sector): no sync header, sig at sector1 + 0x20.
    # Raw (2352 b/sector):    16-byte sync + 4-byte header before data, sig at sector1 + 0x30.
    $rawOffset    = 2352 + 0x30   # raw: skip sector 0 (2352), skip 16b sync header, +0x20 payload offset
    $cookedOffset = 2048 + 0x20   # cooked: skip sector 0 (2048), +0x20 payload offset
    foreach ($off in @($rawOffset, $cookedOffset)) {
        if (($off + $sigLen) -gt $Data.Length) { continue }
        $match = $true
        for ($i = 0; $i -lt $sigLen; $i++) {
            if ($Data[$off + $i] -ne $sig[$i]) { $match = $false; break }
        }
        if ($match) { return $true }
    }
    return $false
}

# Helper: parse a CUE INDEX MSF timestamp (MM:SS:FF) and return the byte offset into a
# single-file binary image. Each frame = 1 sector = 2352 bytes (raw). Used to seek to
# the data track in a concatenated single-file image before signature checks.
function Get-CueSectorOffset {
    param([string]$MSF)
    if ($MSF -notmatch '^(\d+):(\d+):(\d+)$') { return 0 }
    $totalSectors = ([long]$Matches[1] * 60 * 75) + ([long]$Matches[2] * 75) + [long]$Matches[3]
    return $totalSectors * 2352
}

# Neo Geo CD: IPL.TXT is present in the ISO 9660 directory of every NGCD disc and is unique
# to this platform - no other system uses this filename as a boot descriptor.
# We scan for it as an ASCII string in the first 4 MB of the data track, where it will appear
# in the ISO 9660 directory record area. This is the sole detection signal - it is specific
# enough that no corroboration is needed, and avoids false positives from NEO-GEO strings
# that could theoretically appear in game data on other systems.
function Detect-NeoGeoCD {
    param([byte[]]$Data)
    $text = [System.Text.Encoding]::ASCII.GetString($Data)
    return ($text.Contains("IPL.TXT"))
}

# CD-i: checks ISO volume descriptor fields at known sector offsets for CD-RTOS/CD-I markers.
# These offsets are specific to CD-i and do not appear on other systems.
function Detect-CDi {
    param([byte[]]$Data)
    $sectorOffsets = @(0x9310, 0x9318, 0x9328, 0x8010, 0x8000)
    foreach ($base in $sectorOffsets) {
        if ($Data.Length -lt ($base + 0x40)) { continue }
        $appId = [System.Text.Encoding]::ASCII.GetString($Data[($base + 0x28)..($base + 0x37)])
        $sysId = [System.Text.Encoding]::ASCII.GetString($Data[($base + 0x08)..($base + 0x17)])
        if ($appId -match 'CD-?I|CDI' -or $sysId -match 'CD-RTOS|CD-I') { return $true }
    }
    return $false
}

# 3DO: sector 0 of every 3DO disc is a disc label with a fixed header structure.
# Byte 0x00 = 0x01 (record type), bytes 0x01-0x05 = five 0x5A sync bytes.
# This is unique to the 3DO Opera filesystem and does not appear on any other system.
# Checked at offset 0x00 (cooked 2048-byte/sector ISO) and 0x10 (raw 2352-byte/sector BIN).
function Detect-3DO {
    param([byte[]]$Data)
    # Check cooked offset (0x00) and raw offset (0x10)
    foreach ($base in @(0x00, 0x10)) {
        if ($Data.Length -lt ($base + 6)) { continue }
        if ($Data[$base]      -eq 0x01 -and
            $Data[$base + 1]  -eq 0x5A -and
            $Data[$base + 2]  -eq 0x5A -and
            $Data[$base + 3]  -eq 0x5A -and
            $Data[$base + 4]  -eq 0x5A -and
            $Data[$base + 5]  -eq 0x5A) {
            return $true
        }
    }
    return $false
}

# PSP: checks for UMD-specific strings in the binary data.
# UMD_DATA.BIN and PSP_GAME are unique to PSP UMD images.
function Detect-PSP {
    param([byte[]]$Data)
    $text = [System.Text.Encoding]::ASCII.GetString($Data)
    return ($text.Contains("UMD_DATA.BIN") -or $text.Contains("PSP_GAME"))
}

# PS2DVD: checks for UDF filesystem markers (NSR02/NSR03).
# UDF is used on PS2 DVD-ROMs and is not present on PS1 CD-ROMs.
function Detect-UDF {
    param([byte[]]$Data)
    $text = [System.Text.Encoding]::ASCII.GetString($Data)
    return ($text.Contains("NSR02") -or $text.Contains("NSR03"))
}

# PS2CD: checks for "BOOT2" inside SYSTEM.CNF content embedded in the disc data.
# PS1 discs use "BOOT =" in SYSTEM.CNF; PS2 discs use "BOOT2 =".
function Detect-PS2CD {
    param([byte[]]$Data)
    $text = [System.Text.Encoding]::ASCII.GetString($Data)
    return ($text.Contains("BOOT2"))
}

# Master detection: returns a system string for any supported input file.
# Detection order: most-specific / least-ambiguous signatures are checked first.
# Sega family (Saturn/SegaCD/Dreamcast) checked before generic PS fallbacks.
# PCE checked before PS1 since PCE has no ISO 9660 and won't trigger DVD/UDF checks anyway.
# NeoGeo checked before PS1 for the same reason.
function Get-SystemType {
    param([string]$Path)

    $ext = [System.IO.Path]::GetExtension($Path).ToLower()

    # GDI is unambiguously Dreamcast - no byte reading needed
    if ($ext -eq ".gdi") { return "Dreamcast" }

    if ($ext -eq ".cue") {
        $cueText = Get-Content -LiteralPath $Path -Raw

        # All-audio CUE with no data tracks = CD-i Ready disc
        $hasDataTrack  = $cueText -match 'TRACK\s+\d+\s+MODE'
        $hasAudioTrack = $cueText -match 'TRACK\s+\d+\s+AUDIO'
        if ($hasAudioTrack -and -not $hasDataTrack) {
            Write-Host "[DET] All-audio CUE - CD-i Ready disc" -ForegroundColor DarkGray
            return "CDi"
        }

        # Parse the CUE line-by-line to find the data track and its exact byte offset.
        # This handles both single-file CUEs (all tracks concatenated in one image) and
        # multi-file CUEs (each track in its own file).
        $cueDir         = Split-Path $Path
        $binName        = $null
        $dataByteOffset = 0L

        $currentFile    = $null
        $currentIsData  = $false
        $foundDataTrack = $false

        foreach ($line in ($cueText -split '
?
')) {
            $line = $line.Trim()
            if ($line -match '^FILE\s+"([^"]+)"') {
                $currentFile   = $Matches[1].Trim()
                $currentIsData = $false
            } elseif ($line -match '^FILE\s+(\S+)\s+BINARY') {
                $currentFile   = $Matches[1].Trim()
                $currentIsData = $false
            } elseif ($line -match '^TRACK\s+\d+\s+MODE') {
                $currentIsData = $true
            } elseif ($line -match '^TRACK\s+\d+\s+AUDIO') {
                $currentIsData = $false
            } elseif ($currentIsData -and -not $foundDataTrack -and $line -match '^INDEX\s+0*1\s+(\d+:\d+:\d+)') {
                # Found INDEX 1 of the first MODE data track
                $binName        = $currentFile
                $dataByteOffset = Get-CueSectorOffset $Matches[1]
                $foundDataTrack = $true
            }
        }

        # Fallback: no MODE track found - grab the first FILE entry (should not normally happen)
        if (-not $binName) {
            if      ($cueText -match 'FILE\s+"([^"]+)"')      { $binName = $Matches[1].Trim() }
            elseif  ($cueText -match 'FILE\s+(\S+)\s+BINARY') { $binName = $Matches[1].Trim() }
            $dataByteOffset = 0L
        }

        # For multi-file CUEs the data track file starts at offset 0 regardless of MSF
        # (each file contains exactly one track). Detect this by checking if the data track
        # file is different from the first file listed, or if there are multiple FILE entries.
        $fileCount = ([regex]::Matches($cueText, '(?m)^FILE\s')).Count
        if ($fileCount -gt 1) { $dataByteOffset = 0L }

        if (-not $binName) { return "PS1" }

        $binPath = Join-Path $cueDir $binName
        if (-not (Test-Path -LiteralPath $binPath)) {
            Write-Host "[WARN] Data file referenced in CUE not found: $binName" -ForegroundColor DarkYellow
            return "PS1"
        }

        $sizeMB = [Math]::Round((Get-Item -LiteralPath $binPath).Length / 1MB, 1)
        Write-Host "[DET] Reading data file: $binName ($sizeMB MB)" -ForegroundColor DarkGray

        # For single-file images, seek to the data track offset and read 4 MB from there.
        # For multi-file images, read from offset 0 as normal.
        $data = Read-Bytes -Path $binPath -Offset $dataByteOffset

        # Detection order:
        # 1. Sega family - explicit header strings, very low false positive risk
        if (Detect-Saturn    $data) { return "Saturn"    }
        if (Detect-SegaCD    $data) { return "SegaCD"    }
        if (Detect-Dreamcast $data) { return "Dreamcast" }
        # 2. CD-i - proprietary volume descriptor fields
        if (Detect-CDi       $data) { return "CDi"       }
        # 3. 3DO - OPERA filesystem signature
        if (Detect-3DO       $data) { return "3DO"       }
        # 4. PSP - UMD-specific strings
        if (Detect-PSP       $data) { return "PSP"       }
        # 5. PC Engine CD - pre-ISO-9660 boot signature
        if (Detect-PCEngineCD $data) { return "PCEngineCD" }
        # 6. Neo Geo CD - IPL.TXT + NEO-GEO header (both required)
        if (Detect-NeoGeoCD  $data) { return "NeoGeoCD"  }
        # 7. PS2 - UDF markers (DVD) or BOOT2 in SYSTEM.CNF (CD)
        if (Detect-UDF       $data) { return "PS2DVD"    }
        if (Detect-PS2CD     $data) { return "PS2CD"     }
        # 8. PS1 - final fallback for CUE/BIN with a data track
        return "PS1"
    }

    if ($ext -in ".iso", ".img") {
        $data = Read-Bytes $Path

        if (Detect-Saturn     $data) { return "Saturn"     }
        if (Detect-SegaCD     $data) { return "SegaCD"     }
        if (Detect-Dreamcast  $data) { return "Dreamcast"  }
        if (Detect-CDi        $data) { return "CDi"        }
        if (Detect-3DO        $data) { return "3DO"        }
        if (Detect-PSP        $data) { return "PSP"        }
        if (Detect-PCEngineCD $data) { return "PCEngineCD" }
        if (Detect-NeoGeoCD   $data) { return "NeoGeoCD"   }
        if (Detect-UDF        $data) { return "PS2DVD"     }
        if (Detect-PS2CD      $data) { return "PS2CD"      }
        return "UnknownISO"
    }

    if ($ext -eq ".bin") {
        $data = Read-Bytes $Path

        if (Detect-Saturn     $data) { return "Saturn"     }
        if (Detect-SegaCD     $data) { return "SegaCD"     }
        if (Detect-Dreamcast  $data) { return "Dreamcast"  }
        if (Detect-CDi        $data) { return "CDi"        }
        if (Detect-3DO        $data) { return "3DO"        }
        if (Detect-PSP        $data) { return "PSP"        }
        if (Detect-PCEngineCD $data) { return "PCEngineCD" }
        if (Detect-NeoGeoCD   $data) { return "NeoGeoCD"   }
        if (Detect-UDF        $data) { return "PS2DVD"     }
        if (Detect-PS2CD      $data) { return "PS2CD"      }
        return "PS1"
    }

    # DiscJuggler .cdi - confirmed by reading the version uint32 from the last 4 bytes of the file.
    # CDI stores its header at the END of the file, not the beginning.
    # v2.0 = 0x80000004, v3.x = 0x80000006 (little-endian).
    # Modern chdman cannot convert .cdi - detected here to give a clear error.
    if ($ext -eq ".cdi") {
        try {
            $fs = [System.IO.File]::OpenRead($Path)
            try {
                if ($fs.Length -ge 4) {
                    $fs.Seek(-4, [System.IO.SeekOrigin]::End) | Out-Null
                    $footer = New-Object byte[] 4
                    $fs.Read($footer, 0, 4) | Out-Null
                    $magic = [System.BitConverter]::ToUInt32($footer, 0)
                    if ($magic -eq 0x80000004 -or $magic -eq 0x80000006) {
                        return "CDI-Unsupported"
                    }
                }
            } finally {
                $fs.Close()
            }
        } catch { }
        # Extension matched but footer didn't - not a valid CDI, fall through to Unknown
        return "Unknown"
    }

    return "Unknown"
}

# Maps a detected system to the correct CHDMAN subcommand.
function Get-CHDCommand {
    param([string]$System)
    switch ($System) {
        "CDi"        { return "createcd"  }
        "PS1"        { return "createcd"  }
        "PS2CD"      { return "createcd"  }
        "PS2DVD"     { return "createdvd" }
        "PSP"        { return "createdvd" }
        "Dreamcast"  { return "createcd"  }
        "3DO"        { return "createcd"  }
        "Saturn"     { return "createcd"  }
        "SegaCD"     { return "createcd"  }
        "PCEngineCD" { return "createcd"  }
        "NeoGeoCD"   { return "createcd"  }
        default      { return $null }
    }
}
#endregion Detection Functions

#region Archive Handling
function Extract-Archive {
    param(
        [string]$ArchivePath,
        [string]$OutputDir
    )
    $ext = [System.IO.Path]::GetExtension($ArchivePath).ToLower()

    if ($ext -eq ".zip") {
        Write-Host "[ARC] Extracting ZIP..." -ForegroundColor Yellow
        try {
            Expand-Archive -LiteralPath $ArchivePath -DestinationPath $OutputDir -Force
            Write-Host "[ARC] Extraction complete." -ForegroundColor Green
            return $true
        } catch {
            Write-Host "[ERR] Expand-Archive failed: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }

    if ($ext -eq ".7z") {
        Write-Host "[ARC] Extracting .7z..." -ForegroundColor Yellow
        $SevenZip = Join-Path $PSScriptRoot "7za.exe"
        if (-not (Test-Path $SevenZip)) {
            Write-Host "[ERR] 7za.exe not found - cannot extract .7z archives." -ForegroundColor Red
            return $false
        }
        & $SevenZip x "$ArchivePath" -o"$OutputDir" -y
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERR] 7za extraction failed (exit code $LASTEXITCODE)" -ForegroundColor Red
            return $false
        }
        Write-Host "[ARC] Extraction complete." -ForegroundColor Green
        return $true
    }

    if ($ext -eq ".rar") {
        Write-Host "[ARC] Extracting .rar..." -ForegroundColor Yellow
        # 7za.exe does not support RAR extraction due to RARlab licensing restrictions.
        # UnRAR.exe (freeware, from https://www.rarlab.com/rar_add.htm) must be placed
        # in the same folder as this script to enable RAR support.
        $UnRar = Join-Path $PSScriptRoot "UnRAR.exe"
        if (-not (Test-Path $UnRar)) {
            Write-Host "[ERR] UnRAR.exe not found - RAR extraction requires UnRAR.exe from https://www.rarlab.com/rar_add.htm" -ForegroundColor Red
            return $false
        }
        & $UnRar x "$ArchivePath" "$OutputDir\" -y
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERR] UnRAR extraction failed (exit code $LASTEXITCODE)" -ForegroundColor Red
            return $false
        }
        Write-Host "[ARC] Extraction complete." -ForegroundColor Green
        return $true
    }

    Write-Host "[ERR] Unsupported archive format: $ext" -ForegroundColor Red
    return $false
}

function Find-GameFile {
    param([string]$Dir)
    # Priority: CUE > GDI > ISO > IMG > BIN
    # CUE is always preferred as it carries multi-track structure information.
    # GDI is unambiguously Dreamcast.
    # ISO and IMG are standalone single-track images.
    # BIN as a last resort (no CUE present - rare but possible for single-track discs).
    $cue = Get-ChildItem -Path $Dir -Recurse -File -Filter *.cue | Select-Object -First 1
    if ($cue) { return $cue }
    $gdi = Get-ChildItem -Path $Dir -Recurse -File -Filter *.gdi | Select-Object -First 1
    if ($gdi) { return $gdi }
    $iso = Get-ChildItem -Path $Dir -Recurse -File -Filter *.iso | Select-Object -First 1
    if ($iso) { return $iso }
    $img = Get-ChildItem -Path $Dir -Recurse -File -Filter *.img | Select-Object -First 1
    if ($img) { return $img }
    $bin = Get-ChildItem -Path $Dir -Recurse -File -Filter *.bin | Select-Object -First 1
    if ($bin) { return $bin }
    # .cdi (DiscJuggler) is found but not convertible - detected here so we can give a clear error.
    # Footer signature is verified in Get-SystemType before treating it as CDI-Unsupported.
    $cdi = Get-ChildItem -Path $Dir -Recurse -File -Filter *.cdi | Select-Object -First 1
    if ($cdi) { return $cdi }
    return $null
}
#endregion Archive Handling

#region Main Logic

# --- Pass 1: Loose source files (no archive) ---
# Handles .cue, .gdi, .iso, .img, .bin, .cdi sitting directly in the script folder.
# Groups by BaseName so a .cue and its .bin siblings are treated as one game.
# Priority within a group mirrors Find-GameFile: cue > gdi > iso > img > bin > cdi.
$LooseExts    = @(".cue", ".gdi", ".iso", ".img", ".bin", ".cdi")
$LooseFiles   = Get-ChildItem -Path $PSScriptRoot -File | Where-Object { $_.Extension.ToLower() -in $LooseExts }
$LooseGroups  = $LooseFiles | Group-Object { $_.BaseName }

foreach ($Group in $LooseGroups) {
    # Pick the best entry file from the group using priority order
    $EntryFile = $null
    foreach ($ext in $LooseExts) {
        $EntryFile = $Group.Group | Where-Object { $_.Extension.ToLower() -eq $ext } | Select-Object -First 1
        if ($EntryFile) { break }
    }
    if (-not $EntryFile) { continue }

    # Skip BIN/IMG files that have a paired CUE in the same group - the CUE will handle them
    $entryExt = $EntryFile.Extension.ToLower()
    if ($entryExt -in ".bin", ".img") {
        $hasCue = $Group.Group | Where-Object { $_.Extension.ToLower() -eq ".cue" }
        if ($hasCue) { continue }
    }

    $GameName = $EntryFile.BaseName
    Write-Host "`n=== Processing (loose): $GameName ===" -ForegroundColor Cyan
    Write-Host "[DET] Entry file: $($EntryFile.Name)" -ForegroundColor DarkGray

    $System = Get-SystemType -Path $EntryFile.FullName
    Write-Host "[DET] System: $System" -ForegroundColor Yellow

    $ChdCmd = Get-CHDCommand -System $System
    if (-not $ChdCmd) {
        if ($System -eq "CDI-Unsupported") {
            Write-Host "[ERR] .cdi (DiscJuggler) format is not supported by modern chdman." -ForegroundColor Red
            Write-Host "[ERR] Convert to GDI or BIN/CUE first, then re-run. Skipping." -ForegroundColor Red
        } else {
            Write-Host "[ERR] No CHDMAN command for system '$System' - skipping." -ForegroundColor Red
        }
        continue
    }

    $OutFile = Join-Path $PSScriptRoot "$GameName.chd"

    Push-Location $PSScriptRoot
    try {
        Write-Host "[CMD] Running: chdman $ChdCmd -i `"$($EntryFile.Name)`" -o `"$OutFile`" --force" -ForegroundColor Gray
        & $Chdman $ChdCmd -i "$($EntryFile.Name)" -o "$OutFile" --force
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[SUCCESS] CHD created: $GameName.chd" -ForegroundColor Green
        } else {
            Write-Host "[ERR] chdman failed (exit code $LASTEXITCODE)" -ForegroundColor Red
        }
    } finally {
        Pop-Location
    }
}

# --- Pass 2: Archives ---
$Archives = Get-ChildItem -Path $PSScriptRoot -File | Where-Object {
    $_.Extension.ToLower() -in ".zip", ".7z", ".rar"
}

foreach ($Archive in $Archives) {
    $GameName = $Archive.BaseName

    Write-Host "`n=== Processing: $GameName ===" -ForegroundColor Cyan

    # Always start with a clean extract directory
    if (Test-Path $ExtractDir) { Remove-Item $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $ExtractDir | Out-Null

    # Extract
    if (-not (Extract-Archive -ArchivePath $Archive.FullName -OutputDir $ExtractDir)) {
        Move-ToFailureCategory -Category "Archives" -GameName $GameName -FilesToMove @($Archive.FullName)
        Remove-Item $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        continue
    }

    # Archive extracted successfully - move it to UltraCHD_Archives immediately
    $ArchivedPath = Join-Path $ArchivesRoot $Archive.Name
    Move-Item -LiteralPath $Archive.FullName -Destination $ArchivedPath -Force
    Write-Host "[ARC] Archive moved to UltraCHD_Archives." -ForegroundColor DarkGray

    # Flatten any subdirectory nesting
    Get-ChildItem -Path $ExtractDir -Recurse -File | ForEach-Object {
        $dest = Join-Path $ExtractDir $_.Name
        if ($_.FullName -ne $dest) { Move-Item -LiteralPath $_.FullName -Destination $dest -Force }
    }

    # Find game file
    $GameFile = Find-GameFile -Dir $ExtractDir
    if (-not $GameFile) {
        Write-Host "[ERR] No game files found in archive." -ForegroundColor Red
        Move-ToFailureCategory -Category "Archives" -GameName $GameName -FilesToMove @($ArchivedPath)
        Remove-Item $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        continue
    }

    Write-Host "[DET] Entry file: $($GameFile.Name)" -ForegroundColor DarkGray

    # Detect system
    $System = Get-SystemType -Path $GameFile.FullName
    Write-Host "[DET] System: $System" -ForegroundColor Yellow

    # Bail on unrecognized systems
    $ChdCmd = Get-CHDCommand -System $System
    if (-not $ChdCmd) {
        if ($System -eq "CDI-Unsupported") {
            Write-Host "[ERR] .cdi (DiscJuggler) format is not supported by modern chdman." -ForegroundColor Red
            Write-Host "[ERR] Convert to GDI or BIN/CUE first, then re-run. Quarantining archive." -ForegroundColor Red
        } else {
            Write-Host "[ERR] No CHDMAN command for system '$System' - quarantining." -ForegroundColor Red
        }
        Move-ToFailureCategory -Category "Conversion" -GameName $GameName -FilesToMove @($ArchivedPath)
        Remove-Item $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        continue
    }

    $OutFile = Join-Path $PSScriptRoot "$GameName.chd"

    # Convert
    Push-Location $ExtractDir
    try {
        Write-Host "[CMD] Running: chdman $ChdCmd -i `"$($GameFile.Name)`" -o `"$OutFile`" --force" -ForegroundColor Gray
        & $Chdman $ChdCmd -i "$($GameFile.Name)" -o "$OutFile" --force
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[SUCCESS] CHD created: $GameName.chd" -ForegroundColor Green
        } else {
            Write-Host "[ERR] chdman failed (exit code $LASTEXITCODE)" -ForegroundColor Red
            Move-ToFailureCategory -Category "Conversion" -GameName $GameName -FilesToMove @($ArchivedPath)
        }
    } finally {
        Pop-Location
        Remove-Item $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n*** Done ***" -ForegroundColor Cyan
#endregion Main Logic
