<#
.SYNOPSIS
    Build the "Claude Plays HUSTLE" mod ZIP and install it into the game's
    mods folder. (DESIGN.md SS12.2 / SS12.6)

.DESCRIPTION
    Stages src/ into a temp subfolder named after _metadata's "name" field
    (claude_yomih), zips it, and drops the ZIP into <ExeDir>\mods\.

    CRITICAL ZIP LAYOUT (DESIGN SS12.2): ModMain.gd must live at SUBFOLDER
    level inside the ZIP, never at the root. The game's ModLoader.gd::_loadMods
    and gdunzip derive the mod folder via rsplit('/')[0]; a bare ModMain.gd at
    the ZIP root fails to load silently.

        yomihustle-ai.zip
        +-- claude_yomih/          <- MUST equal _metadata "name" (SS12.6)
            +-- ModMain.gd
            +-- ClaudeLoader.gd
            +-- ... (rest of src/)

    SEPARATOR NORMALIZATION: Windows PowerShell 5.1's Compress-Archive writes
    zip entry names with backslashes ("claude_yomih\ModMain.gd"). gdunzip only
    splits on '/', and Godot res:// paths are '/' -- backslash entries would
    make the mod invisible to the loader. This script rewrites every entry
    name to forward slashes after compression, then verifies the layout.

.PARAMETER ExeDir
    The game install directory (the folder containing
    "Your Only Move Is HUSTLE.exe"). Defaults to the standard Steam paths
    under Program Files (x86) / Program Files. If your Steam library lives
    elsewhere: Steam -> right-click the game -> Manage -> Browse local files,
    and pass that path here.

.PARAMETER OutZip
    Optional. Write the ZIP to this exact path instead of <ExeDir>\mods\.
    Skips the game-install lookup entirely (useful for CI / release builds).

.PARAMETER KeepStaging
    Keep the temp staging folder after the build (debugging aid).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\build.ps1

.EXAMPLE
    tools\build.ps1 -ExeDir "D:\SteamLibrary\steamapps\common\Your Only Move Is HUSTLE"

.EXAMPLE
    tools\build.ps1 -OutZip dist\yomihustle-ai.zip
#>
[CmdletBinding()]
param(
    [string]$ExeDir = "",
    [string]$OutZip = "",
    [switch]$KeepStaging
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    Write-Host ""
    Write-Host "BUILD FAILED: $Message" -ForegroundColor Red
    exit 1
}

function Info([string]$Message) {
    Write-Host "[build] $Message"
}

# ---------------------------------------------------------------------------
# 1. Locate repo + validate src/
# ---------------------------------------------------------------------------
$RepoRoot = Split-Path -Parent $PSScriptRoot
$SrcDir   = Join-Path $RepoRoot "src"

if (-not (Test-Path -LiteralPath $SrcDir -PathType Container)) {
    Fail "src/ not found at '$SrcDir'. Run this script from a full clone of the yomihustle-ai repo (tools\build.ps1 expects ..\src)."
}

# Every file below is load-bearing: ClaudeController preloads them via
# MOD_ROOT = "res://claude_yomih" at runtime. Missing one = broken mod.
$RequiredFiles = @(
    "ModMain.gd",
    "_metadata",
    "ClaudeLoader.gd",
    "ClaudeController.gd",
    "ClaudeController.tscn",
    "ModOptions.gd",
    "ProtocolEncoder.gd",
    "ProtocolDecoder.gd",
    "HeuristicShim.gd",
    "LegalMoveEnumerator.gd"
)
$missing = @()
foreach ($f in $RequiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $SrcDir $f) -PathType Leaf)) { $missing += $f }
}
if ($missing.Count -gt 0) {
    Fail ("src/ is missing required mod file(s): " + ($missing -join ", "))
}

# ---------------------------------------------------------------------------
# 2. Read the mod folder name from _metadata (DESIGN SS12.6 coupling:
#    the ZIP subfolder MUST equal _metadata "name"; every preload in
#    ClaudeController.gd is rooted at res://<that name>).
# ---------------------------------------------------------------------------
$MetaPath = Join-Path $SrcDir "_metadata"
try {
    $meta = Get-Content -LiteralPath $MetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Fail "src\_metadata is not valid JSON: $($_.Exception.Message)"
}
$ModName = $null
if ($meta -ne $null -and $meta.PSObject.Properties["name"] -ne $null) {
    $ModName = [string]$meta.name
}
if ([string]::IsNullOrWhiteSpace($ModName)) {
    Fail "src\_metadata has no usable `"name`" field; cannot derive the ZIP subfolder (SS12.6)."
}
if ($ModName -match '[\\/:*?"<>|]') {
    Fail "_metadata name '$ModName' contains characters illegal in a folder name."
}
Info "mod folder name (from _metadata): $ModName"

# ---------------------------------------------------------------------------
# 3. Resolve the destination ZIP path
# ---------------------------------------------------------------------------
if ($OutZip -ne "") {
    $DestZip = $OutZip
    if (-not [System.IO.Path]::IsPathRooted($DestZip)) {
        $DestZip = Join-Path (Get-Location).Path $DestZip
    }
    $destParent = Split-Path -Parent $DestZip
    if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
        New-Item -ItemType Directory -Force -Path $destParent | Out-Null
    }
    Info "output mode: -OutZip -> $DestZip (game install not touched)"
} else {
    # Probe the standard Steam locations when -ExeDir was not given.
    # The install folder is "YourOnlyMoveIsHUSTLE" (no spaces) on current
    # Steam builds; older docs assumed a spaced name. Probe both, in every
    # Steam library listed in libraryfolders.vdf.
    $folderNames = @("YourOnlyMoveIsHUSTLE", "Your Only Move Is HUSTLE")
    $candidates = @()
    if ($ExeDir -ne "") {
        $candidates += $ExeDir
    } else {
        $steamRoots = @()
        $pf86 = ${env:ProgramFiles(x86)}
        if ($pf86) { $steamRoots += (Join-Path $pf86 "Steam") }
        if ($env:ProgramFiles) { $steamRoots += (Join-Path $env:ProgramFiles "Steam") }
        # Every additional Steam library is listed as "path" in libraryfolders.vdf.
        foreach ($root in @($steamRoots)) {
            $vdf = Join-Path $root "steamapps\libraryfolders.vdf"
            if (Test-Path -LiteralPath $vdf -PathType Leaf) {
                foreach ($line in (Get-Content -LiteralPath $vdf)) {
                    if ($line -match '"path"\s+"([^"]+)"') {
                        $steamRoots += ($Matches[1] -replace '\\\\', '\')
                    }
                }
            }
        }
        foreach ($root in ($steamRoots | Select-Object -Unique)) {
            foreach ($name in $folderNames) {
                $candidates += (Join-Path $root (Join-Path "steamapps\common" $name))
            }
        }
    }
    $resolvedExeDir = $null
    foreach ($cand in $candidates) {
        if (Test-Path -LiteralPath $cand -PathType Container) { $resolvedExeDir = $cand; break }
    }
    if ($null -eq $resolvedExeDir) {
        Fail ("game install folder not found. Tried:`n    " + ($candidates -join "`n    ") + "`n" +
              "If the game lives in another Steam library, pass it explicitly:`n" +
              "    tools\build.ps1 -ExeDir `"D:\SteamLibrary\steamapps\common\Your Only Move Is HUSTLE`"`n" +
              "(Steam -> right-click the game -> Manage -> Browse local files)")
    }
    # The Steam build ships as YourOnlyMoveIsHUSTLE.exe (no spaces); older
    # docs assumed a spaced name. Accept either.
    $exeNames = @("YourOnlyMoveIsHUSTLE.exe", "Your Only Move Is HUSTLE.exe")
    $exeFound = $false
    foreach ($exeName in $exeNames) {
        if (Test-Path -LiteralPath (Join-Path $resolvedExeDir $exeName) -PathType Leaf) { $exeFound = $true; break }
    }
    if (-not $exeFound) {
        Write-Warning "'$resolvedExeDir' exists but no game exe ($($exeNames -join ' / ')) was found in it. Continuing anyway -- double-check -ExeDir if the mod doesn't load."
    }
    Info "game install: $resolvedExeDir"

    $ModsDir = Join-Path $resolvedExeDir "mods"
    if (-not (Test-Path -LiteralPath $ModsDir -PathType Container)) {
        try {
            New-Item -ItemType Directory -Force -Path $ModsDir | Out-Null
            Info "created mods folder: $ModsDir"
        } catch {
            Fail ("could not create '$ModsDir': $($_.Exception.Message)`n" +
                  "The game is under a protected folder (e.g. Program Files). Either:`n" +
                  "  - re-run this script from an elevated (Administrator) PowerShell, or`n" +
                  "  - create the 'mods' folder once by hand and grant your user write access.")
        }
    }

    # Explicit writability probe so the failure is a clear message, not a
    # cryptic Compress-Archive exception halfway through.
    $probe = Join-Path $ModsDir (".write_probe_" + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [System.IO.File]::WriteAllText($probe, "probe")
        Remove-Item -LiteralPath $probe -Force
    } catch {
        Fail ("the mods folder is NOT writable: $ModsDir`n" +
              "Error: $($_.Exception.Message)`n" +
              "Fix: re-run from an elevated (Administrator) PowerShell, or grant your user`n" +
              "write access to that folder (Properties -> Security), then re-run.")
    }

    $DestZip = Join-Path $ModsDir "yomihustle-ai.zip"
}

# ---------------------------------------------------------------------------
# 4. Stage src/ -> %TEMP%\claude_yomih_build\<ModName>\
#    (fresh every build: a stale staging dir would smuggle deleted files
#    into the ZIP)
# ---------------------------------------------------------------------------
$StagingRoot = Join-Path $env:TEMP "claude_yomih_build"
if (Test-Path -LiteralPath $StagingRoot) {
    Remove-Item -LiteralPath $StagingRoot -Recurse -Force
}
$Staging = New-Item -ItemType Directory -Force -Path (Join-Path $StagingRoot $ModName)
Copy-Item -Path (Join-Path $SrcDir "*") -Destination $Staging.FullName -Recurse -Force

# Scrub OS/editor droppings that must never ship.
Get-ChildItem -LiteralPath $Staging.FullName -Recurse -Force -File |
    Where-Object { $_.Name -in @("Thumbs.db", "desktop.ini", ".DS_Store") -or $_.Extension -eq ".tmp" } |
    Remove-Item -Force

if (-not (Test-Path -LiteralPath (Join-Path $Staging.FullName "ModMain.gd") -PathType Leaf)) {
    Fail "staging sanity check failed: ModMain.gd is not at the subfolder level ($($Staging.FullName))."
}
$stagedCount = @(Get-ChildItem -LiteralPath $Staging.FullName -Recurse -File).Count
Info "staged $stagedCount file(s) under $($Staging.FullName)"

# ---------------------------------------------------------------------------
# 5. Compress. -Path points at the SUBFOLDER so the ZIP root contains
#    '<ModName>/' (never bare ModMain.gd -- see header comment).
# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $DestZip) {
    Remove-Item -LiteralPath $DestZip -Force
}
Compress-Archive -Path (Join-Path $StagingRoot $ModName) -DestinationPath $DestZip
Info "compressed -> $DestZip"

# ---------------------------------------------------------------------------
# 6. Normalize entry separators to '/'.
#    Windows PowerShell 5.1 Compress-Archive emits 'claude_yomih\ModMain.gd';
#    gdunzip's rsplit('/') and Godot's res:// resolution need '/'.
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

$archive = [System.IO.Compression.ZipFile]::Open($DestZip, [System.IO.Compression.ZipArchiveMode]::Update)
try {
    $badEntries = @($archive.Entries | Where-Object { $_.FullName.Contains("\") })
    foreach ($entry in $badEntries) {
        $fixedName = $entry.FullName.Replace("\", "/")
        $newEntry = $archive.CreateEntry($fixedName, [System.IO.Compression.CompressionLevel]::Optimal)
        $newEntry.LastWriteTime = $entry.LastWriteTime
        $src = $entry.Open()
        try {
            $dst = $newEntry.Open()
            try { $src.CopyTo($dst) } finally { $dst.Dispose() }
        } finally {
            $src.Dispose()
        }
        $entry.Delete()
    }
    if ($badEntries.Count -gt 0) {
        Info "normalized $($badEntries.Count) zip entry name(s) from '\' to '/' (PS 5.1 Compress-Archive quirk)"
    }
} finally {
    $archive.Dispose()
}

# ---------------------------------------------------------------------------
# 7. Verify the final ZIP (DESIGN SS12.6: every entry under '<ModName>/';
#    ModMain.gd present at subfolder level; nothing at the root).
# ---------------------------------------------------------------------------
$verify = [System.IO.Compression.ZipFile]::OpenRead($DestZip)
try {
    $entryNames = @($verify.Entries | ForEach-Object { $_.FullName })
} finally {
    $verify.Dispose()
}
if ($entryNames.Count -eq 0) {
    Fail "produced ZIP is empty: $DestZip"
}
$expectedPrefix = "$ModName/"
$strays = @($entryNames | Where-Object { -not $_.StartsWith($expectedPrefix) })
if ($strays.Count -gt 0) {
    Fail ("ZIP layout check failed (SS12.6): these entries are not under '$expectedPrefix':`n    " +
          ($strays -join "`n    ") + "`nThe game's ModLoader would not load this ZIP.")
}
if ($entryNames -notcontains ($expectedPrefix + "ModMain.gd")) {
    Fail "ZIP layout check failed: '$expectedPrefix" + "ModMain.gd' entry not found."
}
if ($entryNames | Where-Object { $_.Contains("\") }) {
    Fail "ZIP layout check failed: backslash entry names survived normalization."
}
Info "verified: $($entryNames.Count) entries, all under '$expectedPrefix', ModMain.gd at subfolder level"

# ---------------------------------------------------------------------------
# 8. Cleanup + summary
# ---------------------------------------------------------------------------
if (-not $KeepStaging) {
    Remove-Item -LiteralPath $StagingRoot -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Info "staging kept at $StagingRoot (-KeepStaging)"
}

Write-Host ""
Write-Host "BUILD OK  ->  $DestZip" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Start the Python bridge:   python python\bridge.py        (or --stub for no-API-key testing)"
Write-Host "  2. Launch the game from Steam. The mod list should show 'Claude Plays HUSTLE'."
Write-Host "  3. If you toggled mods on/off in-game, RESTART the game (modded.json is read once at startup)."
exit 0
