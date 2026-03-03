#region Initialization
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ProgressPreference = 'SilentlyContinue'

Set-Location -Path $PSScriptRoot
$Chdman = Join-Path $PSScriptRoot "chdman.exe"

$FailedRoot = Join-Path $PSScriptRoot "UltraCHD_Failed"
if (-not (Test-Path $FailedRoot)) { New-Item -ItemType Directory -Path $FailedRoot | Out-Null }

$DoneRoot = Join-Path $PSScriptRoot "UltraCHD_Done"
if (-not (Test-Path $DoneRoot)) { New-Item -ItemType Directory -Path $DoneRoot | Out-Null }
#endregion Initialization

#region Detection Logic
function Detect-CDi {
    param([byte[]]$Data)
    $sectorOffsets = @(0x9310, 0x9318, 0x9328, 0x8010, 0x8000)
    foreach ($base in $sectorOffsets) {
        if ($Data.Length -lt ($base + 0x40)) { continue }
        $appId = [System.Text.Encoding]::ASCII.GetString($Data[($base + 0x28)..($base + 0x37)])
        $sysId = [System.Text.Encoding]::ASCII.GetString($Data[($base + 0x08)..($base + 0x17)])
        Write-Host "[DBG] @ 0x$('{0:X}' -f $base) sysId='$($sysId.Trim())' appId='$($appId.Trim())'" -ForegroundColor DarkGray
        if ($appId -match 'CD-?I|CDI' -or $sysId -match 'CD-RTOS|CD-I') { return $true }
    }
    return $false
}
#endregion Detection Logic

#region Main Logic
$Archives = Get-ChildItem -Path $PSScriptRoot -Filter *.zip
foreach ($Archive in $Archives) {
    $GameName = $Archive.BaseName
    $TempDir = Join-Path $PSScriptRoot "CHD_Temp"

    Write-Host "`n=== Processing: $GameName ===" -ForegroundColor Cyan
    if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $TempDir | Out-Null

    Write-Host "[ARC] Extracting..." -ForegroundColor Yellow
    try {
        Expand-Archive -LiteralPath $Archive.FullName -DestinationPath $TempDir -Force
    } catch {
        Write-Host "[ERR] Expand-Archive failed: $($_.Exception.Message)" -ForegroundColor Red
        continue
    }

    Get-ChildItem -Path $TempDir -Recurse -File | ForEach-Object {
        $dest = Join-Path $TempDir $_.Name
        if ($_.FullName -ne $dest) { Move-Item -LiteralPath $_.FullName -Destination $dest -Force }
    }

    $GameFile = Get-ChildItem -Path $TempDir -Recurse -Include *.cue | Select-Object -First 1
    if (-not $GameFile) { $GameFile = Get-ChildItem -Path $TempDir -Recurse -Include *.iso | Select-Object -First 1 }
    if (-not $GameFile) { $GameFile = Get-ChildItem -Path $TempDir -Recurse -Include *.bin | Select-Object -First 1 }

    if (-not $GameFile) {
        Write-Host "[ERR] No game files found in ZIP." -ForegroundColor Red
        Copy-Item -LiteralPath $Archive.FullName -Destination (Join-Path $FailedRoot $Archive.Name) -Force
        continue
    }

    Write-Host "[DET] Entry file: $($GameFile.Name)" -ForegroundColor DarkGray

    $System = "Unknown"
    if ($GameFile.Extension -eq ".cue") {
        $cueText = Get-Content -LiteralPath $GameFile.FullName -Raw
        $hasDataTrack = $cueText -match 'TRACK\s+\d+\s+MODE'
        $hasAudioTrack = $cueText -match 'TRACK\s+\d+\s+AUDIO'

        if ($hasAudioTrack -and -not $hasDataTrack) {
            Write-Host "[DET] All-audio CUE -- CD-i Ready disc" -ForegroundColor DarkGray
            $System = "CDi"
        } elseif ($cueText -match 'FILE\s+"?([^"]+?)"?\s+BINARY') {
            $binName = $Matches[1].Trim()
            $binPath = Join-Path $TempDir $binName
            if (Test-Path -LiteralPath $binPath) {
                $sizeMB = [Math]::Round((Get-Item -LiteralPath $binPath).Length / 1MB, 1)
                Write-Host "[DET] Reading BIN: $binName ($sizeMB MB)" -ForegroundColor DarkGray
                $bytes = [System.IO.File]::ReadAllBytes($binPath)
                if (Detect-CDi $bytes) { $System = "CDi" } else { $System = "PS1" }
            } else {
                Write-Host "[WARN] BIN referenced in CUE not found: $binName" -ForegroundColor DarkYellow
            }
        }
    } elseif ($GameFile.Extension -eq ".iso") {
        $bytes = [System.IO.File]::ReadAllBytes($GameFile.FullName)
        if (Detect-CDi $bytes) { $System = "CDi" } else { $System = "PS1" }
    }

    $OutFile = Join-Path $PSScriptRoot "$GameName.chd"
    Write-Host "[DET] System: $System" -ForegroundColor Yellow

    Push-Location $TempDir
    try {
        Write-Host "[CMD] Converting..." -ForegroundColor Gray
        & $Chdman createcd -i "$($GameFile.Name)" -o "$OutFile" --force
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[SUCCESS] CHD Created." -ForegroundColor Green
            Move-Item -LiteralPath $Archive.FullName -Destination (Join-Path $DoneRoot $Archive.Name) -Force
        } else {
            Write-Host "[ERR] chdman failed with exit code $LASTEXITCODE" -ForegroundColor Red
            Copy-Item -LiteralPath $Archive.FullName -Destination (Join-Path $FailedRoot $Archive.Name) -Force
        }
    } finally {
        Pop-Location
        Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "`n*** Done ***" -ForegroundColor Cyan
#endregion Main Logic
