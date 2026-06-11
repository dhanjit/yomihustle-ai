# Claude Plays HUSTLE — Windows Setup

End-to-end runbook for getting Claude to play *Your Only Move Is HUSTLE*
(YOMIH, Steam AppID 2212330) on Windows. Two install paths:

- **Player path** — you own the game on Steam and want Claude to play. No
  Godot editor involved. ~10 minutes.
- **Developer path** — you want to iterate on the mod inside the GodotSteam
  editor against a source clone of the game. ~30–60 minutes the first time.

Both paths also run the **Python bridge**, the localhost process that talks
to the Anthropic API on the mod's behalf.

```
+-------------------+        TCP 127.0.0.1:8765        +------------------+       HTTPS
|  YOMIH (Godot)    | <------------------------------> |  python\bridge.py | <----------> Anthropic API
|  + claude_yomih   |    length-prefixed JSON frames    |  (this repo)      |
|    mod (zip)      |                                   +------------------+
+-------------------+
```

Everything stays on your machine except the bridge's HTTPS calls to
Anthropic. The TCP port is loopback-only by design and authenticated with a
per-run token file.

---

## 1. Prerequisites

| What | Why | Notes |
|---|---|---|
| Windows 10/11, 64-bit | — | This guide is Windows-only (the game ships `tbfg.dll`/`tbfg.so`; no macOS lib). |
| Steam + *Your Only Move Is HUSTLE* | the game | AppID 2212330. |
| Python 3.10+ on PATH | the bridge | 3.13 is what the test suite runs on. `python --version` to check. |
| Git | cloning this repo (and `uzkbwza/hustle` for dev) | |
| Anthropic API key | real Claude play | Skip if you only want `--stub` mode. Get one at console.anthropic.com. |
| Windows PowerShell 5.1 | the build/install scripts | In-box on every Windows 10/11. PowerShell 7 also works. |
| GodotSteam **3.5.1** editor | **dev path only** | Stock Godot will not open the project (Steam classes are compiled into the engine). |

PowerShell may refuse to run scripts depending on your execution policy. All
commands below sidestep that with `-ExecutionPolicy Bypass`; no system-wide
policy change needed.

---

## 2. Player setup (Steam build)

### 2.1 Clone and install Python deps

```powershell
git clone https://github.com/dhanjit/yomihustle-ai.git
cd yomihustle-ai
pip install -r python\requirements.txt    # just `anthropic`; skip if stub-only
```

### 2.2 Build and install the mod ZIP

```powershell
powershell -ExecutionPolicy Bypass -File tools\build.ps1
```

This stages `src\` and writes
`<game install>\mods\yomihustle-ai.zip`. The default game install probed is
`C:\Program Files (x86)\Steam\steamapps\common\Your Only Move Is HUSTLE`
(then the non-x86 `Program Files`). If your Steam library lives elsewhere:

```powershell
powershell -ExecutionPolicy Bypass -File tools\build.ps1 -ExeDir "D:\SteamLibrary\steamapps\common\Your Only Move Is HUSTLE"
```

(Find the folder via Steam → right-click the game → Manage → Browse local
files.)

**Where mods actually load from (corrected):** the game's ModLoader scans
`<folder containing "Your Only Move Is HUSTLE.exe">\mods\` — i.e. **next to
the game executable**. Not `user://mods`, not Documents, not the Workshop
folder (Workshop items load separately). Older guides that say `user://mods`
are wrong.

**ZIP layout matters.** Inside the ZIP, all files must sit in a
`claude_yomih/` subfolder:

```
yomihustle-ai.zip
└── claude_yomih/          <- must match the mod's _metadata "name"
    ├── ModMain.gd         <- never at the ZIP root
    ├── ClaudeLoader.gd
    ├── ClaudeController.gd / .tscn
    ├── ModOptions.gd
    ├── ProtocolEncoder.gd / ProtocolDecoder.gd
    ├── HeuristicShim.gd / LegalMoveEnumerator.gd
    └── _metadata
```

A `ModMain.gd` at the ZIP root silently fails to load (the loader derives
the mod folder by splitting entry paths on `/`), and renaming the subfolder
breaks every `res://claude_yomih/...` preload in the mod. `build.ps1`
enforces both invariants and also fixes a PowerShell 5.1 quirk where
`Compress-Archive` writes backslash entry names that the game's unzipper
cannot read. **Do not hand-zip `src\`** — use the script.

### 2.3 Enable mods (modded.json)

ModLoader reads `%APPDATA%\YourOnlyMoveIsHUSTLE\modded.json`:

```json
{ "modsEnabled": true }
```

- The file is **auto-created with mods enabled** the first time the modded
  game boots — most people never touch it.
- The in-game **mod toggle** writes this file, but ModLoader reads it **once
  at startup**: after toggling you must **restart the game**.
- If mods mysteriously don't load, check this file first.

### 2.4 Start the bridge

Real Claude:

```powershell
$env:ANTHROPIC_API_KEY = "sk-ant-..."       # or setx for persistence (new shells only)
python python\bridge.py
```

No API key / offline (deterministic stub decisions, full protocol):

```powershell
python python\bridge.py --stub
```

You should see `bridge 0.1.0 listening on 127.0.0.1:8765`. Useful flags:
`--model` / `--model-v0` (defaults `claude-opus-4-8` / `claude-sonnet-4-6`),
`--verbose`, `--data-dir`. The bridge:

- binds **127.0.0.1 only**, port 8765 (scans up to 8770 if taken) and writes
  the chosen port plus an auth token to `%LOCALAPPDATA%\claude_yomih\`
  (`port`, `token`, `bridge.pid`) — the mod reads those files;
- logs every decision to `%LOCALAPPDATA%\claude_yomih\logs\decisions.jsonl`;
- exits on its own after 15 idle minutes with no open connection, otherwise
  runs until **you stop it with Ctrl+C** — quitting the game does **not**
  stop the bridge.

### 2.5 Launch the game

Start YOMIH from Steam. The mod list (main menu) should show **“Claude Plays
HUSTLE”**. Now play your first match — see section 3.

---

## 3. First-match walkthrough

1. Bridge running (`python python\bridge.py` or `--stub`), game launched.
2. (Optional) Options → Mod Options → **Claude Plays HUSTLE** pane:
   - **Mode**: `v1` — Claude picks moves (default) · `v0` — Claude picks a
     category, heuristic picks the move · `v_none` — heuristic only, no
     bridge traffic.
   - **Claude player**: Auto (default; the non-human side, P2 when
     ambiguous), or pin Player 1 / Player 2.
   - **Bridge port (fallback)**: only used if the bridge's port file is
     missing.
   - **Fallback only / Disable ghost-eval verification / fix frame-adv
     divisor**: leave at defaults.
   - The pane only exists if the **SoupModOptions** mod is installed
     (drop its ZIP in the same `mods\` folder). Without it the mod
     silently uses the defaults above.
3. Start a **local, offline** match (online play and 3+ player MultiHustle
   are explicitly unsupported — the mod refuses to drive those). Pick both
   characters; Claude drives its side from the first turn.
4. What you should observe per turn:
   - The bridge console prints
     `[match=... tick=... mode=v1] outcome=ranked latency_ms=...`.
   - The chosen move plays out in game. Claude has a strict time budget; if
     it blows the budget or returns garbage, a built-in heuristic
     (the vendored reference AI) takes that turn instead — the game never
     stalls.
   - If the bridge is down you get a persistent HUD line
     “Claude bridge offline — using heuristic”; the mod re-probes every 30 s
     and recovers automatically once you start the bridge.
5. Want receipts? Per-turn decision snapshots (full request, response,
   reasoning, latency):
   - mod side: `%APPDATA%\YourOnlyMoveIsHUSTLE\claude_yomih\turns\<match>\`
     plus a summary log `%APPDATA%\YourOnlyMoveIsHUSTLE\claude_yomih.log`
   - bridge side: `%LOCALAPPDATA%\claude_yomih\logs\decisions.jsonl`

---

## 4. Developer setup (in-editor iteration)

The Steam ZIP round-trip is the wrong loop for development: when you press
F5 in the editor, ModLoader scans for ZIPs **next to the editor
executable**, not your project. The dev path bypasses ZIPs entirely.

### 4.1 Game source

```powershell
git clone https://github.com/uzkbwza/hustle.git
```

Note on native libs: the clone already ships `lib\tbfg.dll` — a **real
PE32+ x86-64 DLL** (the native simulation core), verified in-tree, plus
`vcruntime140.dll` and the Linux `tbfg.so`. You do **not** need to copy
anything out of your Steam install, despite what older decompile-route
guides say.

### 4.2 GodotSteam 3.5.1 editor

1. Download the **GodotSteam 3.5.1** Windows **editor** zip from
   https://github.com/CoaguCo-Industries/GodotSteam/releases (the 3.5.1 tag;
   GodotSteam is a Godot build with Steamworks compiled in — stock Godot
   3.5 cannot run this project).
2. Unzip anywhere; create **`steam_appid.txt`** next to the editor exe
   containing exactly:

   ```
   2212330
   ```

3. Have the **Steam client running and logged in** (Steamworks init needs
   it).

### 4.3 Wire the mod into the clone

```powershell
cd yomihustle-ai
powershell -ExecutionPolicy Bypass -File tools\install_dev.ps1 -HustleDir C:\src\hustle
```

This creates a directory junction `C:\src\hustle\claude_yomih` → this repo's
`src\` (edits are live), generates a `ClaudeDevLoader.gd` debug autoload
that replays the mod's `installScriptExtension` calls at startup, registers
it in `override.cfg`, and shields all of it from git via `.git\info\exclude`.

Flags: `-Copy` (plain copy instead of junction), `-EditProjectGodot` (write
the autoload into `project.godot` if your build ignores `override.cfg`
autoloads), `-Uninstall` (remove everything it created).

### 4.4 Run

1. Open the hustle project in the GodotSteam editor. The **first import
   takes several minutes** (sprite/audio re-encode) — let it finish once.
2. Start a bridge — for iteration the stub is ideal (no API key, no cost,
   deterministic): `python python\bridge.py --stub`.
3. Press **F5**. The output console **must** print
   `claude_yomih DEV loader active`. No banner → re-run `install_dev.ps1`
   with `-EditProjectGodot`.
4. Start a local match as in section 3.

If you want SoupModOptions or `_AIOpponents` present during editor runs,
drop their ZIPs into `<editor-exe-folder>\mods\` (that is the mods dir the
editor-run game scans).

### 4.5 Failure-injection testing (tools\stub_bridge.py)

A scenario-driven stub server (DESIGN §14.2) for exercising the mod's
degradation tiers end-to-end, no API key:

```powershell
python tools\stub_bridge.py                          # happy path: valid ranked picks
python tools\stub_bridge.py --scenario all_invalid   # every pick illegal -> mod must fall to heuristic
python tools\stub_bridge.py --scenario empty_ranked  # empty ranking -> heuristic
python tools\stub_bridge.py --scenario timeout       # 10s stall (once) -> mod's 8s budget fires, then recovers
python tools\stub_bridge.py --scenario disconnect    # drops connection mid-reply (once), mod must recover
python tools\stub_bridge.py --scenario schema_mismatch  # replies schema_version=2
python tools\stub_bridge.py --scenario auth_fail     # rejects the mod's token
python tools\stub_bridge.py --script turns.json      # scripted decisions, one per request (JSON; YAML with PyYAML)
```

`--times N` controls how many requests a scenario sabotages (timeout /
disconnect default to 1, then behave normally). Run **either** the stub
**or** the real bridge, never both — they share the port file the mod reads.

---

## 5. Tool reference

| Tool | Purpose | Key parameters |
|---|---|---|
| `tools\build.ps1` | Stage `src\` → verified mod ZIP → `<ExeDir>\mods\yomihustle-ai.zip` | `-ExeDir <game folder>` (default: standard Steam paths) · `-OutZip <path>` (write ZIP elsewhere, e.g. CI/release; game install untouched) · `-KeepStaging` |
| `tools\install_dev.ps1` | Editor workflow: junction + debug autoload into a hustle clone | `-HustleDir <clone>` (required) · `-Copy` · `-EditProjectGodot` · `-Uninstall` |
| `tools\stub_bridge.py` | Canned/sabotaged bridge for mod testing | `--scenario` · `--script` · `--times` · `--sleep` · `--port` · `--data-dir` · `--snapshots` |
| `python\bridge.py` | The real bridge | `--stub` · `--model` · `--model-v0` · `--port` · `--data-dir` · `--fixture <json>` (one-shot, no socket) · `--claude-timeout` · `--idle-exit` |

---

## 6. File and folder map

| Path | What lives there |
|---|---|
| `<game install>\mods\yomihustle-ai.zip` | the installed mod (player path) |
| `%APPDATA%\YourOnlyMoveIsHUSTLE\modded.json` | mods on/off switch, read once at startup |
| `%APPDATA%\YourOnlyMoveIsHUSTLE\claude_yomih.log` | mod-side per-turn summary log |
| `%APPDATA%\YourOnlyMoveIsHUSTLE\claude_yomih\turns\…` | mod-side decision snapshots (authoritative) |
| `%LOCALAPPDATA%\claude_yomih\port` / `token` / `bridge.pid` | bridge runtime files the mod reads (port + auth) |
| `%LOCALAPPDATA%\claude_yomih\logs\decisions.jsonl` | bridge-side decision log (rotated at 50 MB) |
| `<hustle clone>\claude_yomih` (junction) + `claude_yomih_dev\` + `override.cfg` | dev-path artifacts, removed by `-Uninstall` |

---

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Mod missing from the in-game mod list | ZIP in the wrong place, or wrong internal layout | The ZIP must be `<folder with the game .exe>\mods\yomihustle-ai.zip`, with everything under a `claude_yomih/` subfolder. Always rebuild with `tools\build.ps1` (it verifies layout and fixes the PS 5.1 backslash-entry quirk); never hand-zip. |
| Toggled mods in-game, nothing changed | `modded.json` is read **once at startup** | Toggle, then **restart the game**. The bridge is a separate process: it does not restart or stop with the game — stop it yourself with Ctrl+C when you're done. |
| HUD says “Claude bridge offline — using heuristic” | Bridge not running, or a stale `port` file from a hard-killed bridge | Start `python python\bridge.py` (or `--stub`). The mod re-probes every 30 s. If it persists, delete `%LOCALAPPDATA%\claude_yomih\port` and restart the bridge (it rewrites the file; a clean exit removes it). |
| Antivirus / firewall flags the game or `python.exe` making network connections | The mod↔bridge link is plain TCP on `127.0.0.1:8765–8770`, which some AVs surface | Expected and harmless: the bridge binds loopback **only** — this traffic never leaves your machine. Allow loopback for `python.exe`. Only the bridge's outbound HTTPS to `api.anthropic.com` touches the network (absent in `--stub`). |
| `_AIOpponents` (reference AI mod) is also installed — conflict? | Both mods extend `game.gd` | Supported by design: `claude_yomih` loads last (priority 100000) and **frees the reference AIController at match start**, so Claude drives. Keep both installed if you like; no uninstall needed. Check the game log for “chain inversion” warnings if a third mod fights for the same hook. |
| No “Claude Plays HUSTLE” pane in Mod Options | SoupModOptions mod not installed | Install SoupModOptions into the same `mods\` folder, or just play on defaults (mode v1, player Auto, port 8765). |
| `bridge: could not initialise the Anthropic client` | No `ANTHROPIC_API_KEY`, or `anthropic` package missing | `$env:ANTHROPIC_API_KEY="sk-ant-..."` and `pip install -r python\requirements.txt` — or run `--stub`. |
| Bridge console: `AUTH_FAIL` | Mod and bridge disagree on the token file (bridge restarted mid-session, or different `--data-dir`) | Restart the bridge, then leave and re-enter the match (the mod re-reads the token file when it reconnects). Use the same `--data-dir` on both stub and bridge runs. |
| Bridge says it wrote `%LOCALAPPDATA%\claude_yomih\` but that folder is empty | **Microsoft Store Python** virtualizes AppData writes into its package sandbox (`...\Packages\PythonSoftwareFoundation...\LocalCache\Local\`) | Nothing to do — the bridge detects Store Python and writes to `%USERPROFILE%\.claude_yomih\` instead (it logs which dir it chose); the mod probes both locations. Prefer python.org Python for the standard location. |
| Logs show `error_code=schema_mismatch` | Mod ZIP and bridge come from different repo versions (or you're running the `schema_mismatch` stub scenario) | Rebuild the ZIP and pull the repo so both sides speak `schema_version: 1`. |
| `build.ps1`: “mods folder is NOT writable” | Game under `Program Files` + restrictive ACLs | Re-run from an elevated PowerShell, or create `mods\` once by hand and grant your user write access. |
| Two bridges fighting / mod talks to the wrong one | Port scan 8765→8770 plus a shared port file | Run exactly one of `bridge.py` / `stub_bridge.py` at a time. The mod follows whichever process wrote `%LOCALAPPDATA%\claude_yomih\port` last. |
| (dev) F5 prints no `claude_yomih DEV loader active` banner | `override.cfg` autoload not honored by your build | `tools\install_dev.ps1 -HustleDir <clone> -EditProjectGodot` (writes the autoload into `project.godot`; `-Uninstall` cleans both). |
| (dev) “GDNative not found” / missing `Steam` class / crash at match start | Stock Godot editor, or Steamworks didn't init | Use the **GodotSteam 3.5.1** editor; `steam_appid.txt` containing `2212330` next to the editor exe; Steam client running. |
| (dev) editor's first open hangs 10+ minutes | `.import\` cache regenerating | Wait it out once; later opens are fast. |
| (dev) told to copy `tbfg.dll` out of the Steam install | Outdated decompile-route advice | Not needed: the `uzkbwza/hustle` clone ships `lib\tbfg.dll`, a verified real PE32+ x86-64 binary (plus `vcruntime140.dll`). Copying applies only to GDRE-decompiled projects. |
| Replay of a Claude match shows identical moves but you want the “why” | By design: game replays are action-only and byte-stable | Claude's reasoning isn't re-executed in replays — read the per-turn snapshots under `%APPDATA%\YourOnlyMoveIsHUSTLE\claude_yomih\turns\`. |

---

## 8. Uninstall

- **Player:** delete `<game install>\mods\yomihustle-ai.zip`. Optionally
  delete the data dirs: `%LOCALAPPDATA%\claude_yomih\` and
  `%APPDATA%\YourOnlyMoveIsHUSTLE\claude_yomih*`. Stop any running bridge
  (Ctrl+C).
- **Developer:** `tools\install_dev.ps1 -HustleDir <clone> -Uninstall`.
