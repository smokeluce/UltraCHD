#region Initialization

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Set-Location -Path $PSScriptRoot
$Chdman = Join-Path $PSScriptRoot "chdman.exe"

# Root failure/quarantine folder
$FailedRoot = Join-Path $PSScriptRoot "UltraCHD_Failed"
$FailedArchivesDir   = Join-Path $FailedRoot "Archives"
$FailedConversionDir = Join-Path $FailedRoot "Conversion"
$FailedValidationDir = Join-Path $FailedRoot "Validation"

foreach ($path in @($FailedRoot, $FailedArchivesDir, $FailedConversionDir, $FailedValidationDir)) {
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path | Out-Null
    }
}

#endregion Initialization

#region Utility Functions

function Read-Bytes {
    param(
        [string]$Path,
        [int]$Count = 4194304
    )

    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] $Count
        $fs.Read($buffer, 0, $Count) | Out-Null
    }
    finally {
        $fs.Close()
    }
    return $buffer
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
    if (-not (Test-Path $gameFolder)) {
        New-Item -ItemType Directory -Path $gameFolder | Out-Null
    }

    foreach ($file in $FilesToMove) {
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        if (Test-Path $file) {
            $dest = Join-Path $gameFolder (Split-Path $file -Leaf)
            try {
                Move-Item -LiteralPath $file -Destination $dest -Force
            }
            catch {
                Write-Host "[WARN] Failed to move '$file' to '$dest': $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }
    }

    Write-Host "[MOVED] Files moved to UltraCHD_Failed\$Category\$GameName" -ForegroundColor DarkYellow
}

function Get-FileSize {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    return (Get-Item $Path).Length
}

function Test-SectorAlignment {
    param(
        [string]$Path,
        [int[]]$ValidSectorSizes
    )

    $size = Get-FileSize $Path
    if ($size -le 0) { return $false }

    foreach ($sector in $ValidSectorSizes) {
        if ($size % $sector -eq 0) { return $true }
    }
    return $false
}

#endregion Utility Functions

#region Archive Handling

function Extract-Archive {
    param(
        [string]$ArchivePath,
        [string]$OutputDir
    )

    $ext = [System.IO.Path]::GetExtension($ArchivePath).ToLower()

    if ($ext -eq ".zip") {
        Write-Host "[ARC] Extracting ZIP..." -ForegroundColor Yellow
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $OutputDir -Force
        Write-Host "[ARC] Extraction complete." -ForegroundColor Green
        return $true
    }

    if ($ext -in ".7z", ".rar") {
        Write-Host "[ARC] Extracting $ext..." -ForegroundColor Yellow

        $SevenZip = Join-Path $PSScriptRoot "7za.exe"
        & $SevenZip x "$ArchivePath" -o"$OutputDir" -y

        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERR] Extraction failed (7z exit code $LASTEXITCODE)" -ForegroundColor Red
            return $false
        }

        Write-Host "[ARC] Extraction complete." -ForegroundColor Green
        return $true
    }

    return $false
}

function Find-ExtractedGameFile {
    param([string]$TempDir)

    $iso = Get-ChildItem -Path $TempDir -Recurse -File -Filter *.iso | Select-Object -First 1
    if ($iso) { return $iso.FullName }

    $cue = Get-ChildItem -Path $TempDir -Recurse -File -Filter *.cue | Select-Object -First 1
    if ($cue) { return $cue.FullName }

    $bin = Get-ChildItem -Path $TempDir -Recurse -File -Filter *.bin | Select-Object -First 1
    if ($bin) { return $bin.FullName }

    return $null
}

#endregion Archive Handling

#region Detection Functions

function Detect-DVD {
    param([byte[]]$Data)

    for ($offset = 0x8000; $offset -le 0x50000; $offset += 0x800) {
        if ($Data.Length -lt ($offset + 5)) { continue }

        if ($Data[$offset] -eq 0x43 -and
            $Data[$offset+1] -eq 0x44 -and
            $Data[$offset+2] -eq 0x30 -and
            $Data[$offset+3] -eq 0x30 -and
            $Data[$offset+4] -eq 0x31) {
            return $true
        }
    }

    return $false
}

function Detect-UDF {
    param([byte[]]$Data)

    $patterns = @("NSR02", "NSR03")
    $text = [System.Text.Encoding]::ASCII.GetString($Data)

    foreach ($p in $patterns) {
        if ($text.Contains($p)) { return $true }
    }

    return $false
}

function Detect-PS2CD {
    param([byte[]]$Data)

    $sync = @(0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00)
    for ($i = 0; $i -lt 2000; $i++) {
        $match = $true
        for ($j = 0; $j -lt $sync.Length; $j++) {
            if ($Data[$i+$j] -ne $sync[$j]) { $match = $false; break }
        }
        if ($match) { return $true }
    }
    return $false
}

function Detect-PSP {
    param([byte[]]$Data)
    $text = [System.Text.Encoding]::ASCII.GetString($Data)
    return ($text.Contains("UMD_DATA.BIN") -or $text.Contains("PSP_GAME"))
}

function Detect-3DO {
    param([byte[]]$Data)
    $sig = [System.Text.Encoding]::ASCII.GetString($Data[0x3C..0x40])
    return ($sig -like "*OPERA*")
}

function Get-SystemType {
    param([string]$Path)

    $ext = [System.IO.Path]::GetExtension($Path).ToLower()

    if ($ext -eq ".cue") {
        $cueText = Get-Content -LiteralPath $Path -Raw
        $binName = $null

        if ($cueText -match 'FILE\s+"([^"]+\.bin)"') {
            $binName = $matches[1]
        }

        if (-not $binName) { return "PS1" }

        $binPath = Join-Path (Split-Path $Path) $binName
        if (-not (Test-Path $binPath)) { return "PS1" }

        $data = Read-Bytes $binPath

        if (Detect-3DO $data) { return "3DO" }
        if (Detect-PSP $data) { return "PSP" }
        if (Detect-UDF $data) { return "PS2DVD" }
        if (Detect-DVD $data) { return "PS2DVD" }
        if (Detect-PS2CD $data) { return "PS2CD" }

        return "PS1"
    }

    if ($ext -eq ".gdi") { return "Dreamcast" }

    if ($ext -eq ".iso") {
        $data = Read-Bytes $Path

        if (Detect-3DO $data) { return "3DO" }
        if (Detect-PSP $data) { return "PSP" }
        if (Detect-UDF $data) { return "PS2DVD" }
        if (Detect-DVD $data) { return "PS2DVD" }
        if (Detect-PS2CD $data) { return "PS2CD" }

        return "UnknownISO"
    }

    if ($ext -eq ".bin") {
        $data = Read-Bytes $Path

        if (Detect-3DO $data) { return "3DO" }
        if (Detect-PSP $data) { return "PSP" }
        if (Detect-UDF $data) { return "PS2DVD" }
        if (Detect-DVD $data) { return "PS2DVD" }
        if (Detect-PS2CD $data) { return "PS2CD" }

        return "PS1"
    }

    return "Unknown"
}

function Get-CHDCommand {
    param([string]$System)
    switch ($System) {
        "PS1"       { "createcd" }
        "PS2CD"     { "createcd" }
        "PS2DVD"    { "createdvd" }
        "PSP"       { "createdvd" }
        "Dreamcast" { "createcd" }
        "3DO"       { "create3do" }
        default     { $null }
    }
}

#endregion Detection Functions

#region CHD Validation

function Get-CHDInfo {
    param([string]$ChdPath)

    $info = & $Chdman info -i "$ChdPath" 2>$null
    if (-not $info) { return $null }

    $info = ($info | Out-String)

    # -----------------------------
    # Extract Sector Size (Unit Size)
    # -----------------------------
    $sectorSize = 0

    if ($info -match "Unit\s+Size:\s*([0-9,]+)\s*bytes") {
        $sectorSize = [int]($matches[1] -replace ",","")
    }
    elseif ($info -match "unit\s+bytes:\s*([0-9]+)") {
        $sectorSize = [int]$matches[1]
    }
    elseif ($info -match "hunk\s+bytes:\s*([0-9]+)") {
        # fallback for older CHDMAN
        $sectorSize = [int]$matches[1]
    }

    # -----------------------------
    # Detect CHD Type
    # -----------------------------
    $type = "Unknown"

    # Modern CHDMAN metadata tags (allow trailing spaces)
    if ($info -match "Tag='DVD\s*'") {
        $type = "DVD"
    }
    elseif ($info -match "Tag='CD\s*'") {
        $type = "CD"
    }

    # Legacy MODE1/MODE2 (PS1 / PS2 CD)
    if ($info -match "TYPE:MODE1" -or $info -match "TYPE:MODE2") {
        $type = "CD"
    }

    # System-specific metadata
    if ($info -match "GD-ROM") { $type = "GD" }
    if ($info -match "Opera")  { $type = "3DO" }
    if ($info -match "PSP")    { $type = "PSP" }

    [PSCustomObject]@{
        Raw        = $info
        Type       = $type
        SectorSize = $sectorSize
    }
}

function Validate-CHDForSystem {
    param(
        [string]$ChdPath,
        [string]$System
    )

    $info = Get-CHDInfo $ChdPath
    if (-not $info) { return $false }
    
    Write-Host "[DBG] CHD Info: Type=$($info.Type) SectorSize=$($info.SectorSize)"

    switch ($System) {
        "PS2DVD"   { return ($info.Type -eq "DVD" -and $info.SectorSize -eq 2048) }
        "PS2CD"    { return ($info.Type -eq "CD" -and $info.SectorSize -in @(2448, 2352)) }
        "PS1"      { return ($info.Type -eq "CD") }
        "PSP"      { return ($info.Type -eq "DVD" -and $info.SectorSize -eq 2048) }
        "Dreamcast"{ return ($info.Type -eq "GD" -or $info.Type -eq "CD") }
        "3DO"      { return ($info.Type -eq "3DO") }
        default    { return $false }
    }
}

#endregion CHD Validation

#region Game Processing

function Process-Game {
   param(
    [string]$SourcePath,
    [string]$OutputPath,
    [string]$BaseName
)

    $dir = $SourcePath
    $name = $BaseName

    $isoFile = Get-ChildItem -LiteralPath $dir -Filter "$name.iso" -ErrorAction SilentlyContinue
    $cueFile = Get-ChildItem -LiteralPath $dir -Filter "$name.cue" -ErrorAction SilentlyContinue
    $binFile = Get-ChildItem -LiteralPath $dir -Filter "$name.bin" -ErrorAction SilentlyContinue
    $gdiFile = Get-ChildItem -LiteralPath $dir -Filter "$name.gdi" -ErrorAction SilentlyContinue
    $chdFile = Get-ChildItem -LiteralPath $dir -Filter "$name.chd" -ErrorAction SilentlyContinue

    Write-Host "`n=== Processing: $name ===" -ForegroundColor Cyan

    $sourcePath = $null
    $system     = $null

    if ($cueFile) {
        $sourcePath = $cueFile.FullName
        $system = Get-SystemType $sourcePath
        Write-Host "[SRC] Found CUE → System = $system" -ForegroundColor Gray
    }
    elseif ($gdiFile) {
        $sourcePath = $gdiFile.FullName
        $system = Get-SystemType $sourcePath
        Write-Host "[SRC] Found GDI → System = $system" -ForegroundColor Gray
    }
    elseif ($isoFile) {
        $sourcePath = $isoFile.FullName
        $system = Get-SystemType $sourcePath
        Write-Host "[SRC] Found ISO → System = $system" -ForegroundColor Gray
    }
    elseif ($binFile) {
        $sourcePath = $binFile.FullName
        $system = Get-SystemType $sourcePath
        Write-Host "[SRC] Found BIN → System = $system" -ForegroundColor Gray
    }

    if (-not $sourcePath) {
        Write-Host "[ERR] No valid source file found for $name" -ForegroundColor Red
        return
    }

    if (-not $chdFile) {
        Write-Host "[NEW] No CHD found → Creating new CHD..." -ForegroundColor Yellow
        $cmd = Get-CHDCommand $system

        if (-not $cmd) {
            Write-Host "[ERR] No CHDMAN command for system '$system' → Quarantining source." -ForegroundColor Red
            Move-ToFailureCategory -Category "Conversion" -GameName $name -FilesToMove @($sourcePath)
            return
        }

        # Basic sector alignment sanity check for DVD-like systems
        if ($system -in @("PS2DVD","PSP")) {
            if (-not (Test-SectorAlignment -Path $sourcePath -ValidSectorSizes @(2048))) {
                Write-Host "[ERR] Source size not divisible by 2048 for DVD-like system → Quarantining." -ForegroundColor Red
                Move-ToFailureCategory -Category "Validation" -GameName $name -FilesToMove @($sourcePath)
                return
            }
        }

        $outputChd = Join-Path $OutputPath "$name.chd"

        & $Chdman $cmd -i "$sourcePath" -o "$outputChd"
        $exit = $LASTEXITCODE

        if ($exit -ne 0) {
            Write-Host "[ERR] CHD creation failed (exit code $exit) → Quarantining source/partial CHD." -ForegroundColor Red
            Move-ToFailureCategory -Category "Conversion" -GameName $name -FilesToMove @($sourcePath, $outputChd)
            return
        }

        if (-not (Test-Path $outputChd) -or (Get-Item $outputChd).Length -lt 10000) {
            Write-Host "[ERR] CHD file missing or too small after creation → Quarantining." -ForegroundColor Red
            Move-ToFailureCategory -Category "Conversion" -GameName $name -FilesToMove @($sourcePath, $outputChd)
            return
        }

        # Validate CHD against expected system
        if (-not (Validate-CHDForSystem -ChdPath $outputChd -System $system)) {
            Write-Host "[ERR] CHD validation failed for system '$system' → Quarantining CHD and source." -ForegroundColor Red
            Move-ToFailureCategory -Category "Validation" -GameName $name -FilesToMove @($sourcePath, $outputChd)
            return
        }

        Write-Host "[DONE] CHD created and validated." -ForegroundColor Green

        [console]::beep(440,120)
        [console]::beep(440,120)

        $chdFile = Get-ChildItem -LiteralPath $dir -Filter "$name.chd"

        # Only delete source files after successful, validated CHD creation
        if ($cueFile) { Remove-Item -LiteralPath $cueFile.FullName -Force }
        if ($binFile) { Remove-Item -LiteralPath $binFile.FullName -Force -ErrorAction SilentlyContinue }
        if ($isoFile) { Remove-Item -LiteralPath $isoFile.FullName -Force }
        if ($gdiFile) { Remove-Item -LiteralPath $gdiFile.FullName -Force -ErrorAction SilentlyContinue }
    }
    else {
        # Optional: validate existing CHD
        Write-Host "[CHK] Existing CHD found → Validating..." -ForegroundColor DarkCyan
        if (-not (Validate-CHDForSystem -ChdPath $chdFile.FullName -System $system)) {
            Write-Host "[ERR] Existing CHD failed validation → Quarantining CHD." -ForegroundColor Red
            Move-ToFailureCategory -Category "Validation" -GameName $name -FilesToMove @($chdFile.FullName)
        }
        else {
            Write-Host "[OK] Existing CHD is valid for $system." -ForegroundColor Green
        }
    }
}

#endregion Game Processing

#region Main Loop

# Startup beep
[console]::beep(880,150)
[console]::beep(988,150)
[console]::beep(1046,200)

Write-Host "Starting CHD conversion & repair..." -ForegroundColor Cyan

$files = Get-ChildItem -File | Where-Object {
    $_.Extension.ToLower() -in ".iso", ".cue", ".gdi", ".chd", ".zip", ".7z", ".rar"
}

$groups = $files | Group-Object { $_.BaseName }

foreach ($group in $groups) {

    $first = $group.Group[0]
    $ext = $first.Extension.ToLower()

       if ($ext -in ".zip", ".7z", ".rar") {

        Write-Host "`n=== Processing Archive: $($first.Name) ===" -ForegroundColor Cyan

        $currentDir = $first.DirectoryName

        # Create a unique temp extraction folder per archive
        $tempDirName = "_UltraCHD_Extract_$($first.BaseName)"
        $tempDir     = Join-Path $currentDir $tempDirName

        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path $tempDir | Out-Null

        if (-not (Extract-Archive $first.FullName $tempDir)) {
            Write-Host "[FAIL] Extraction failed → moving to UltraCHD_Failed\Archives..." -ForegroundColor Red
            Move-ToFailureCategory -Category "Archives" -GameName $first.BaseName -FilesToMove @($first.FullName)
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            continue
        }

        $gamePath = Find-ExtractedGameFile $tempDir

        if (-not $gamePath) {
            Write-Host "[FAIL] No ISO/BIN/CUE found in extracted contents → moving archive to UltraCHD_Failed\Archives..." -ForegroundColor Red
            Move-ToFailureCategory -Category "Archives" -GameName $first.BaseName -FilesToMove @($first.FullName)
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            continue
        }

        $base = [System.IO.Path]::GetFileNameWithoutExtension($gamePath)
        $dir  = [System.IO.Path]::GetDirectoryName($gamePath)

        Write-Host "[ARC] Found extracted game file: $gamePath" -ForegroundColor Cyan

        Process-Game -SourcePath $dir -OutputPath $currentDir -BaseName $base

        $chdPath = Join-Path $currentDir "$base.chd"

        if (Test-Path $chdPath) {
            Write-Host "[CLEAN] CHD created successfully → deleting archive..." -ForegroundColor DarkYellow
            Remove-Item $first.FullName -Force
        }
        else {
            Write-Host "[CLEAN] CHD not created → moving archive to UltraCHD_Failed\Archives." -ForegroundColor Yellow
            Move-ToFailureCategory -Category "Archives" -GameName $first.BaseName -FilesToMove @($first.FullName)
        }

        # Always clean up the temp extraction folder
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

        continue
    }

    Process-Game -SourcePath $first.DirectoryName -OutputPath $first.DirectoryName -BaseName $group.Name
}

Write-Host "All conversions and repairs complete!" -ForegroundColor Cyan

[console]::beep(1318,150)
[console]::beep(1567,150)
[console]::beep(2093,250)
[console]::beep(1760,200)
[console]::beep(2093,300)

#endregion Main Loop