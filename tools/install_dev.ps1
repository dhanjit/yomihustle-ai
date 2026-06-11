<#
.SYNOPSIS
    Wire the Claude mod into a cloned uzkbwza/hustle project for in-editor
    iteration -- no ZIP, no <exe-dir>\mods\ round-trip. (DESIGN.md SS12.3)

.DESCRIPTION
    The game's ModLoader only loads ZIPs from next to the running executable
    (OS.get_executable_path().get_base_dir() + "/mods"); when you press F5 in
    the GodotSteam editor that is the EDITOR's folder, so the normal install
    path is useless for iteration. This script instead:

      1. Links  <HustleDir>\claude_yomih  ->  <repo>\src  (directory junction
         by default, so edits in the repo are live in the editor; -Copy for a
         plain copy). The folder name MUST be claude_yomih: every preload in
         the mod is rooted at res://claude_yomih (DESIGN SS12.6).
      2. Writes <HustleDir>\claude_yomih_dev\ClaudeDevLoader.gd -- a debug
         autoload that replicates ModMain.gd's installScriptExtension calls
         at startup (ClaudeLoader always; ModOptions only when SoupModOptions
         is present in the project).
      3. Registers that autoload in <HustleDir>\override.cfg (a standard
         Godot project.godot override; keeps the clone's project.godot
         pristine). If your Godot build ignores override.cfg autoloads, rerun
         with -EditProjectGodot to append the entry to project.godot itself.
      4. Adds the generated paths to the clone's .git\info\exclude so the
         clone stays clean for git.

    VERIFY: on F5 the output console must print the
    "claude_yomih DEV loader active" banner. No banner = the autoload did not
    register (see -EditProjectGodot).

.PARAMETER HustleDir
    Path to the cloned uzkbwza/hustle repo (the folder with project.godot).

.PARAMETER Copy
    Copy src\ instead of creating a junction. Use when junctions are not an
    option; you must re-run this script after every mod edit.

.PARAMETER EditProjectGodot
    Register the dev autoload directly in project.godot's [autoload] section
    (appended last, AFTER ModLoader -- order is load-bearing) instead of
    override.cfg.

.PARAMETER Uninstall
    Remove everything this script created (junction/copy, dev autoload,
    override.cfg / project.godot entries).

.EXAMPLE
    tools\install_dev.ps1 -HustleDir C:\src\hustle

.EXAMPLE
    tools\install_dev.ps1 -HustleDir C:\src\hustle -Uninstall
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$HustleDir,
    [switch]$Copy,
    [switch]$EditProjectGodot,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    Write-Host ""
    Write-Host "INSTALL_DEV FAILED: $Message" -ForegroundColor Red
    exit 1
}
function Info([string]$Message) {
    Write-Host "[install_dev] $Message"
}

$AutoloadKey  = "ClaudeDevLoader"
$AutoloadLine = $AutoloadKey + '="*res://claude_yomih_dev/ClaudeDevLoader.gd"'

# ---------------------------------------------------------------------------
# Helpers: remove a directory that might be a junction. Remove-Item -Recurse
# on a junction in PS 5.1 can traverse INTO the target (our src/!), so
# reparse points are unlinked with rmdir, which removes only the link.
# ---------------------------------------------------------------------------
function Remove-DirSafe([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        cmd /c rmdir "$Path" | Out-Null
        if (Test-Path -LiteralPath $Path) { Fail "could not remove junction: $Path" }
    } else {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

# Insert/replace $line inside the [autoload] section of a Godot .cfg/.godot
# file. The line is appended at the END of the section so the dev autoload
# instantiates AFTER ModLoader (ClaudeDevLoader._init calls the ModLoader
# singleton; autoload order = property order).
function Set-AutoloadLine([string]$FilePath, [string]$Line, [string]$Key) {
    $text = ""
    if (Test-Path -LiteralPath $FilePath) {
        $text = Get-Content -LiteralPath $FilePath -Raw
    }
    $lines = @()
    if ($text -ne "") { $lines = $text -split "`r?`n" }

    # Drop any previous copy of our entry, then re-insert.
    $lines = @($lines | Where-Object { $_ -notmatch ("^\s*" + [regex]::Escape($Key) + "\s*=") })

    $sectionIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq "[autoload]") { $sectionIdx = $i; break }
    }
    if ($sectionIdx -lt 0) {
        if ($lines.Count -gt 0 -and ($lines[$lines.Count - 1]).Trim() -ne "") { $lines += "" }
        $lines += "[autoload]"
        $lines += ""
        $lines += $Line
    } else {
        # Find the end of the [autoload] section (next section header or EOF).
        $endIdx = $lines.Count
        for ($i = $sectionIdx + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -match '^\[.+\]$') { $endIdx = $i; break }
        }
        # Walk back over blank padding so our line lands with the other entries.
        $insertAt = $endIdx
        while ($insertAt -gt ($sectionIdx + 1) -and ($lines[$insertAt - 1]).Trim() -eq "") { $insertAt-- }
        $before = @(); if ($insertAt -gt 0) { $before = $lines[0..($insertAt - 1)] }
        $after  = @(); if ($insertAt -lt $lines.Count) { $after = $lines[$insertAt..($lines.Count - 1)] }
        $lines = $before + @($Line) + $after
    }
    # Godot's ConfigFile parser is fine with LF or CRLF; write UTF-8 no BOM
    # (project.godot upstream is BOM-less; a BOM would corrupt the first key).
    $out = ($lines -join "`n")
    if (-not $out.EndsWith("`n")) { $out += "`n" }
    [System.IO.File]::WriteAllText($FilePath, $out, (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-AutoloadLine([string]$FilePath, [string]$Key) {
    if (-not (Test-Path -LiteralPath $FilePath)) { return }
    $text = Get-Content -LiteralPath $FilePath -Raw
    $lines = @($text -split "`r?`n" | Where-Object { $_ -notmatch ("^\s*" + [regex]::Escape($Key) + "\s*=") })
    $remaining = @($lines | Where-Object { $_.Trim() -ne "" -and $_.Trim() -ne "[autoload]" })
    if ($remaining.Count -eq 0) {
        Remove-Item -LiteralPath $FilePath -Force   # file held only our entry
        return
    }
    $out = ($lines -join "`n")
    if (-not $out.EndsWith("`n")) { $out += "`n" }
    [System.IO.File]::WriteAllText($FilePath, $out, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
$RepoRoot = Split-Path -Parent $PSScriptRoot
$SrcDir   = Join-Path $RepoRoot "src"
if (-not (Test-Path -LiteralPath $SrcDir -PathType Container)) {
    Fail "src/ not found at '$SrcDir' -- run from a full clone of yomihustle-ai."
}
if (-not (Test-Path -LiteralPath $HustleDir -PathType Container)) {
    Fail "-HustleDir '$HustleDir' does not exist."
}
$HustleDir = (Resolve-Path -LiteralPath $HustleDir).Path
$ProjectGodot = Join-Path $HustleDir "project.godot"
if (-not (Test-Path -LiteralPath $ProjectGodot -PathType Leaf)) {
    Fail "'$HustleDir' has no project.godot -- point -HustleDir at a clone of https://github.com/uzkbwza/hustle"
}
if (-not (Test-Path -LiteralPath (Join-Path $HustleDir "modloader\ModLoader.gd") -PathType Leaf)) {
    Fail "'$HustleDir' has no modloader\ModLoader.gd -- the dev loader needs the game's ModLoader autoload (is this really the hustle repo?)."
}
$projText = Get-Content -LiteralPath $ProjectGodot -Raw
if ($projText -notmatch 'config/name="Your Only Move Is HUSTLE"') {
    Write-Warning "project.godot's config/name is not 'Your Only Move Is HUSTLE' -- continuing, but double-check -HustleDir."
}

$LinkPath    = Join-Path $HustleDir "claude_yomih"        # = MOD_ROOT (SS12.6)
$DevDir      = Join-Path $HustleDir "claude_yomih_dev"
$DevScript   = Join-Path $DevDir "ClaudeDevLoader.gd"
$OverrideCfg = Join-Path $HustleDir "override.cfg"

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if ($Uninstall) {
    Remove-DirSafe $LinkPath
    Info "removed $LinkPath"
    if (Test-Path -LiteralPath $DevDir) {
        Remove-Item -LiteralPath $DevDir -Recurse -Force
        Info "removed $DevDir"
    }
    Remove-AutoloadLine $OverrideCfg $AutoloadKey
    Info "cleaned override.cfg"
    # Also clean project.godot in case a previous run used -EditProjectGodot.
    if ((Get-Content -LiteralPath $ProjectGodot -Raw) -match [regex]::Escape($AutoloadKey)) {
        Remove-AutoloadLine $ProjectGodot $AutoloadKey
        Info "cleaned project.godot"
    }
    Write-Host ""
    Write-Host "DEV UNINSTALL OK -- the hustle clone no longer loads the Claude mod." -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------------------
# 1. Link (or copy) src/ -> <HustleDir>\claude_yomih
# ---------------------------------------------------------------------------
Remove-DirSafe $LinkPath
if ($Copy) {
    New-Item -ItemType Directory -Force -Path $LinkPath | Out-Null
    Copy-Item -Path (Join-Path $SrcDir "*") -Destination $LinkPath -Recurse -Force
    Info "copied src\ -> $LinkPath  (re-run after every mod edit; junctions are nicer: omit -Copy)"
} else {
    try {
        New-Item -ItemType Junction -Path $LinkPath -Target $SrcDir | Out-Null
    } catch {
        Fail ("could not create junction '$LinkPath' -> '$SrcDir': $($_.Exception.Message)`n" +
              "Junctions need an NTFS local volume. Re-run with -Copy to copy the files instead.")
    }
    Info "junction $LinkPath -> $SrcDir  (live: repo edits appear in the editor instantly)"
}

# ---------------------------------------------------------------------------
# 2. Dev autoload script. Replicates ModMain.gd's _init without the ZIP path.
#    GDScript bodies are TAB-indented (repo style); single-quoted here-string
#    so nothing interpolates.
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $DevDir | Out-Null
$gd = @'
# ClaudeDevLoader.gd -- GENERATED by yomihustle-ai/tools/install_dev.ps1.
# DO NOT COMMIT to the hustle clone (install_dev.ps1 adds it to .git/info/exclude).
#
# DESIGN.md SS12.3 dev path: when running from the GodotSteam editor, ModLoader
# scans <editor-exe-dir>/mods -- not the project -- so the shipped ZIP never
# loads. This autoload (registered AFTER ModLoader; order matters) replicates
# claude_yomih/ModMain.gd's installScriptExtension calls at startup. The
# extension chain it builds is identical to the ZIP install, so everything
# downstream (ClaudeLoader ghost guard, controller, options) behaves the same.
extends Node

func _init():
	print("=================================================")
	print("claude_yomih DEV loader active (editor workflow)")
	print("  game.gd extension: res://claude_yomih/ClaudeLoader.gd")
	print("=================================================")
	ModLoader.installScriptExtension("res://claude_yomih/ClaudeLoader.gd")
	var f = File.new()
	if f.file_exists("res://SoupModOptions/ModOptions.gd"):
		ModLoader.installScriptExtension("res://claude_yomih/ModOptions.gd")
	else:
		# Without SoupModOptions the options pane is skipped; ClaudeController
		# logs once and falls back to defaults (mode=v1, port=8765).
		print("claude_yomih dev: SoupModOptions not in project - options pane skipped (defaults apply)")
'@
# Normalize to LF; Godot is happy either way but the repo's .gd files are LF.
$gd = $gd -replace "`r`n", "`n"
if (-not $gd.EndsWith("`n")) { $gd += "`n" }
[System.IO.File]::WriteAllText($DevScript, $gd, (New-Object System.Text.UTF8Encoding($false)))
Info "wrote $DevScript"

# ---------------------------------------------------------------------------
# 3. Register the autoload
# ---------------------------------------------------------------------------
if ($EditProjectGodot) {
    Set-AutoloadLine $ProjectGodot $AutoloadLine $AutoloadKey
    Remove-AutoloadLine $OverrideCfg $AutoloadKey   # don't double-register
    Info "registered autoload in project.godot ($AutoloadKey, appended after ModLoader)"
} else {
    Set-AutoloadLine $OverrideCfg $AutoloadLine $AutoloadKey
    Info "registered autoload in override.cfg ($AutoloadKey)"
}

# ---------------------------------------------------------------------------
# 4. Keep the clone clean for git
# ---------------------------------------------------------------------------
$gitInfoDir = Join-Path $HustleDir ".git\info"
if (Test-Path -LiteralPath (Join-Path $HustleDir ".git")) {
    if (-not (Test-Path -LiteralPath $gitInfoDir)) {
        New-Item -ItemType Directory -Force -Path $gitInfoDir | Out-Null
    }
    $excludePath = Join-Path $gitInfoDir "exclude"
    $excludeBlock = @("/claude_yomih/", "/claude_yomih_dev/", "/override.cfg")
    $existing = ""
    if (Test-Path -LiteralPath $excludePath) { $existing = Get-Content -LiteralPath $excludePath -Raw }
    $added = @()
    foreach ($entry in $excludeBlock) {
        if ($existing -notmatch [regex]::Escape($entry)) { $added += $entry }
    }
    if ($added.Count -gt 0) {
        $nl = [Environment]::NewLine
        $payload = $nl + "# added by yomihustle-ai/tools/install_dev.ps1" + $nl + ($added -join $nl) + $nl
        [System.IO.File]::AppendAllText($excludePath, $payload)
        Info "added $($added.Count) entr(ies) to .git\info\exclude"
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "DEV INSTALL OK" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Open '$HustleDir' in the GodotSteam 3.5.1 editor (steam_appid.txt with 2212330"
Write-Host "     next to the editor exe; Steam client running). First import takes a while."
Write-Host "  2. Start the bridge:  python python\bridge.py --stub     (or without --stub + ANTHROPIC_API_KEY)"
Write-Host "  3. Press F5. The output console MUST print 'claude_yomih DEV loader active'."
Write-Host "     If it doesn't, your build ignores override.cfg autoloads -- re-run with -EditProjectGodot."
Write-Host "  4. Other mods in dev (SoupModOptions, _AIOpponents) load from <editor-exe-dir>\mods, not the project."
exit 0
