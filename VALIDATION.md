# Validation of RESEARCH.md

Cross-checked the load-bearing claims in `RESEARCH.md` against the actual
upstream source (`uzkbwza/hustle` @ `4450348` and
`TheanMcGarity/MultiHustleGame` @ `9d0ff28`) before writing any code that
assumes them. Verdicts are split into **Confirmed**, **Corrected**, and
**Newly resolved Unknown**.

---

## Confirmed (build on these without further checking)

### The game-hook architecture

| Claim in RESEARCH.md | Status | Evidence |
|---|---|---|
| `signal player_actionable()` on `game.gd` | ✅ Confirmed | `uzkbwza/hustle/game.gd` line ~25 declares it; emitted inside `process_tick()` |
| `target_player.on_action_selected(action, data, extra)` is the submit call | ✅ Confirmed | `game.gd::forfeit()` calls `get_player((id % 2) + 1).on_action_selected("Continue", null, null)`; reference AI uses the same signature |
| `game.copy_to(ghost_game)` exists | ✅ Confirmed | `game.gd::copy_to(game: Game)` — snapshots `p1.chara`, `p2.chara`, hp, objects, fx, camera limits |
| `ghost_game.simulate_one_tick()` exists | ✅ Confirmed | `game.gd::simulate_one_tick()` calls `tick()` then `show_state()` |
| `is_ghost` flag gates ghost behavior | ✅ Confirmed | Used throughout `game.gd` |
| `Network.multiplayer_active` field | ✅ Confirmed | Used in `game.gd` and overridden in `cl_port/Network.gd` |
| `ReplayManager.resimulating` flag | ✅ Confirmed | Toggled around lookahead and replay paths |

### The reference AI in `_AIOpponents/`

| Claim | Status | Evidence |
|---|---|---|
| `ModMain.gd` bootstrap installs `ModOptions.gd` and `AILoader.gd` | ✅ Confirmed verbatim | File matches the quoted snippet (whitespace differs, code identical) |
| `AILoader.gd` is `extends "res://game.gd"`, adds AIController.tscn, calls `._ready()` | ✅ Confirmed verbatim | 6 lines, exactly as quoted |
| `game.connect("player_actionable", self, "_start_decision_thread")` is the actual hook | ✅ Confirmed | `AIController.gd::_ready()` |
| Submit pattern (queued_action / queued_data / queued_extra + on_action_selected + turns_taken + turns_ready + call_deferred("_start_ghost")) | ✅ Confirmed | `AIController.gd::make_move()` matches the quoted block |
| `di_as_percentage_int_vec` returns `{"x": int(round(v.x*100)), "y": int(round(v.y*100))}` | ✅ Confirmed verbatim | Trailing-comma version in source; semantics identical |
| Legal-move enumeration via `main.find_node("P"+str(2-id%2)+"ActionButtons").buttons` | ✅ Confirmed | `AIController.gd::get_best_move()` |
| `states_to_ignore = ["Taunt", "DefensiveBurst"]` | ✅ Confirmed | Top of `AIController.gd` |
| `FRAMES_TO_SIMULATE = 35` | ✅ Confirmed | Top of `AIController.gd` |
| Scoring weights: FRAME_ADVANTAGE_MODIFIER=20, DAMAGE_MODIFIER=1, DISTANCE_MODIFIER=0.1, SUPER_MODIFIER=-0.5 | ✅ Confirmed | All four match exactly |
| State-specific modifiers — Burst / DefensiveBurst / OffensiveBurst penalize negative @ -999999; InstantCancel / WhiffInstantCancel zeroed | ✅ Confirmed | `state_specific_modifiers` dict matches |
| Hard difficulty does one extra opponent-then-self prediction step | ✅ Confirmed | `if difficulty == 3 and target_player.opponent.combo_count <= 0:` branch |
| Frame-advantage gets halved when `distance_closed < 50` | ✅ Confirmed | `frame_advantage_modifier /= 10` (note: **10**, not 2 as "halved" suggests — RESEARCH.md hedged this, source is divide-by-ten) |

### The ModLoader system

| Claim | Status | Evidence |
|---|---|---|
| "ModLoader V1.1" at `res://modloader/ModLoader.gd` | ✅ Confirmed | Line 3: `# MODLOADER V1.1` |
| Reads `user://modded.json` for enable/disable | ✅ Confirmed | `_init()` creates default and reads `modsEnabled` |
| MD5 hash via `File.get_md5()` | ✅ Confirmed | `_hash_file()` |
| `installScriptExtension(path)` uses `take_over_path` | ✅ Confirmed | `installScriptExtension()` body |
| Honors `requires`/dependency order via `_dependencyCheck` | ✅ Confirmed | Function exists with the documented logic |
| Loads from Steam Workshop subscriptions via `Steam.getSubscribedItems()` | ✅ Confirmed | `_loadMods()` iterates subscribed items |
| `_metadata` schema validated against fixed field list | ✅ Confirmed | `_verifyMetadata` schema list |

### Game state and constants

| Claim | Status | Evidence |
|---|---|---|
| Version `"1.9.27-steam-unstable"` | ✅ Confirmed | `Global.gd` line 5 |
| Resolution `Vector2(640, 360)` | ✅ Confirmed | `Global.gd` const |
| 5 base characters: Ninja / Cowboy / Wizard / Robot / Mutant | ✅ Confirmed | `Global.gd::name_paths` |
| Main scene `res://Main.tscn` | ✅ Confirmed | `project.godot::application/run/main_scene` |
| Custom user dir `YourOnlyMoveIsHUSTLE` | ✅ Confirmed | `project.godot::application/config/custom_user_dir_name` |
| All 8 autoloads (Global, SteamHustle, ReplayManager, Network, ModLoader, SteamLobby, Custom, ModOverride) | ✅ Confirmed | `project.godot::[autoload]` |
| `MAX_HEALTH = 1500` (correcting v1's "10000") | ✅ Confirmed | `characters/BaseChar.gd::var MAX_HEALTH = 1500` |
| `Server.py` UDP hole-punch (Twisted) | ✅ Confirmed | Exists at repo root, uses `DatagramProtocol` |

---

## Corrected (RESEARCH.md is wrong on these — fix before relying on them)

### 1. The build is NOT pure GDScript — there are native libs (`tbfg.dll` / `tbfg.so`)

RESEARCH.md §A.6 says native libs are "**Unknown** until inspected locally —
most of the heavy lifting is plain GDScript, so this may be a non-issue."

**Reality:** the repo ships GDNative scripts and the corresponding native
libs **in-tree**:

- `bin/FGCharacter.gdns`, `bin/FGObject.gdns`, `bin/FixedMath.gdns`,
  `bin/Simulation.gdns`, `bin/NativeMethods.gdns`, `bin/HelloWorld.gdns`
  (all NativeScript, registered as `_global_script_classes` in
  `project.godot`).
- All `.gdns` resources point at `res://lib/lib.tres` (single
  `GDNativeLibrary` resource).
- `lib/tbfg.dll` (1.2 MB) and `lib/tbfg.so` (5.1 MB) are committed to the
  repo. Also `lib/vcruntime140.dll`.

**Implication:** the fixed-point math and simulation core run in **native
code**. We do NOT need to copy these out of the Steam install (RESEARCH.md
§A.5 step 6 / §A.6 row "tbfg / native-lib import errors"). They're already
there.

**Caveat:** the macOS `.dylib` is missing from `lib/`. The `.DS_Store`
suggests the project was checked in from a Mac that didn't commit the
`.dylib`. Mac users will need to build `tbfg` from source or grab it from
the Mac Steam install. **No Linux/Mac builds shipped in the GitHub repo
other than `tbfg.so`** — fine for Windows + Linux dev.

### 2. Mods load from the EXECUTABLE directory, not `user://mods/`

RESEARCH.md §A.6 says "Mods don't appear in editor playtest" because they
"live in `user://mods/`". **Wrong.** `ModLoader._loadMods()` does:

```gdscript
var gameInstallDirectory = OS.get_executable_path().get_base_dir()
var modPathPrefix = gameInstallDirectory.plus_file("mods")
_load_mods_in_folder(modPathPrefix)
```

So mods come from **`<executable-dir>/mods/`**, not `user://`. Plus Steam
Workshop subscriptions. When developing in the editor, this resolves to
**next to the Godot editor binary** (since that's `get_executable_path()`),
which is awkward. Easier dev path is to add your dev mod as a folder in the
project tree (no zip) and load it directly via a debug autoload.

### 3. Mods CANNOT extend `res://Network.gd`

A security check the research missed entirely:

```gdscript
# ModLoader.gd::installScriptExtension
if parentScript.resource_path != "res://Network.gd" or childScript.resource_path == "res://modloader/ModHashCheck.gd":
    childScript.take_over_path(parentScriptPath)
else:
    print("You can't access network!")
```

Any mod that tries to extend `res://Network.gd` is silently rejected (only
ModHashCheck is allowed). **Implication for us:** if the Claude bridge ever
needs to inspect or influence multiplayer state, it has to do it indirectly
(e.g., extend the AI controller, not Network.gd). Aligns with the
local-only stance we already adopted, but worth pinning down.

### 4. The Mutant character lives in `characters/mutant/`, not "`alien/+mutant/`"

RESEARCH.md §C.1 lists Mutant's folder as "`alien/`+`mutant/`". Actually:

- `name_paths["Mutant"] = "res://characters/mutant/Mutant.tscn"` (single
  folder).
- `Alien` IS in `name_paths` but commented out — it's not in the active
  roster.
- Class is `Mutant extends Fighter`, script at `mutant/Beast.gd`.
- `BeastState` lives under `characters/mutant/states/`.

So when extracting Mutant's frame data, walk **only** `characters/mutant/`.

### 5. The `Network` autoload is at `res://cl_port/Network.gd`, which extends a parent at `res://Network.gd`

Subtle but matters for any future mod work:

```ini
# project.godot
Network="*res://cl_port/Network.gd"
```

```gdscript
# cl_port/Network.gd
extends "res://Network.gd"
```

There's a **two-layer Network**: a base script at `res://Network.gd` and an
extending script at `res://cl_port/Network.gd` that's the actual autoload.
The cl_port layer handles per-player mod-hash tracking
(`player1_hashes`, `_compare_checksum`, `update_diffList`, etc). Future
network introspection must target the right layer.

### 6. The `_AIOpponents/_metadata` example in the repo is "AI Opponent" by **AxNoodle**, not YOMIRecord

This isn't an error, but a clarification with strategic consequences:

```json
{
  "author": "AxNoodle",
  "client_side": true,
  "description": "General AI Opponent",
  "friendly_name": "AI Opponent",
  "id": "12345",
  "link": "",
  "name": "AI Opponent",
  "overwrites": false,
  "priority": -10000,
  "requires": [""],
  "version": "1.1.1"
}
```

RESEARCH.md §B.6 lists AxNoodle's "AI Opponent | Goon" as **Unknown** —
"No public source located — Unknown whether it diverges materially."

**Resolved:** AxNoodle's "AI Opponent" mod IS the `_AIOpponents/` source in
MultiHustleGame. Same author, same metadata, version 1.1.1. So the
reference AI source is more current than the research implied, and there is
no separate "Goon" variant to hunt down.

(Also: the metadata schema verifier does NOT actually require
`client_side` — only the 10 fields name/friendly_name/description/author/
version/link/id/overwrites/requires/priority. `client_side` is consumed
elsewhere, so include it but don't expect ModLoader to bounce mods missing
it.)

### 7. Frame-advantage distance multiplier is /10, not "halved"

RESEARCH.md §B.1 says "halved if dist < 50". Source says `/= 10`. Small but
real — it makes close-range frame advantage matter ~5× less than the
research suggested.

---

## Newly resolved Unknowns

Items from RESEARCH.md "Top remaining unknowns":

| # | RESEARCH.md status | Resolution |
|---|---|---|
| 2 | "Any GDNative `.dll`s ship in the public build beyond Steam... (Unknown — possibly not needed if physics is pure GDScript)" | **Resolved.** `bin/*.gdns` + `lib/tbfg.{dll,so}` + `lib/vcruntime140.dll` ship in-tree. macOS users need to source `.dylib` themselves. |
| 6 | "Public source for 'The Hacker' and 'AI Opponent / Goon'... Unknown" | **Half-resolved.** "AI Opponent" by AxNoodle IS `_AIOpponents/` in MultiHustleGame — same author, version 1.1.1. "The Hacker" remains Unknown. |

Still open:

| # | Issue |
|---|---|
| 1 | Exact GodotSteam 3.5.1 binary tag — needs a local test run. |
| 3 | Wizard / Robot / Mutant frame data — must walk `characters/{wizard,robo,mutant}/states/` and emit JSON. |
| 4 | `Network.gd` input-deadline / turn-timeout constants for online play — reachable from source. |
| 5 | Exact `queued_data` schema per move — verify by round-tripping a handful from the editor. |

---

## What this means for the next slice

The hook architecture and the reference AI's submit path are real,
verbatim, and unchanged. We can build directly on:

- **Hook:** subscribe to `game.player_actionable` in a class that extends
  `res://game.gd` via `ModLoader.installScriptExtension`.
- **Submit:** write into `target_player.queued_*` and call
  `target_player.on_action_selected(action, data, extra)`, then set
  `game.turns_taken[id] = true`, `Network.turns_ready[id] = true`, and
  `main.call_deferred("_start_ghost")`.
- **Lookahead (optional, can defer):** instantiate `res://Game.tscn` as a
  child of the GhostViewport with `is_ghost = true`, then
  `game.copy_to(ghost)` + `ghost.simulate_one_tick()` in a loop. Note the
  simulation runs in **native code** via `bin/Simulation.gdns` —
  deterministic, fast.
- **Legal moves:** enumerate `main.find_node("P{2-id%2}ActionButtons").buttons`
  and filter on `button.is_visible()`.
- **DI / extra:** `{"DI": di_as_percentage_int_vec(...), "feint": bool, "prediction": -1, "reverse": false}`.

Open question to settle before writing the mod: do we want the bridge to
**replace `eval_move`** (Claude scores each candidate move, deterministic
lookahead stays), or **replace the whole `make_move`** (Claude sees state
and picks freely)? The first is a smaller, more verifiable surface; the
second is what the research is implicitly suggesting.

Either way, the bridge protocol is the same: send `{state, legal_moves}` to
a local Python TCP server, receive `{action, data, extra}`. The mod skeleton
and the Python server can be built independently.

---

## Source revisions audited

- `uzkbwza/hustle` — default branch `main` @ commit `4450348` (latest as of audit).
- `TheanMcGarity/MultiHustleGame` — `_AIOpponents/` tree @ `9d0ff28`.

Files read in full or via targeted search:

- `game.gd`, `Global.gd`, `project.godot`, `Server.py`, `modloader/ModLoader.gd`, `cl_port/Network.gd`, `bin/FixedMath.gdns`, `lib/` listing.
- `_AIOpponents/ModMain.gd`, `_AIOpponents/AILoader.gd`, `_AIOpponents/_metadata`, `_AIOpponents/AIController.gd`.
- `characters/BaseChar.gd` (via code search for `MAX_HEALTH`).
