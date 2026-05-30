# Making Claude Play *Your Only Move Is HUSTLE*

Comprehensive technical reference for wiring Claude up as a player in
*Your Only Move Is HUSTLE* (YOMIH), Steam AppID 2212330 by ivysly (GitHub
`uzkbwza`).

> **v3 update — deep research.** The most important finding of the second
> research pass is that **the game's source is public on GitHub at
> [`uzkbwza/hustle`](https://github.com/uzkbwza/hustle)**. We don't need to
> decompile a `.pck`; we can clone and read the actual scripts. As a result,
> every architectural assumption from v1 (`Match.gd`, `submit_action`,
> "inferred" field names) has been replaced with verbatim source-level facts.
> v3 also includes a full first-class reference implementation of an AI
> opponent — the dev's own `_AIOpponents/AIController.gd` in
> [`TheanMcGarity/MultiHustleGame`](https://github.com/TheanMcGarity/MultiHustleGame),
> which is the template we should mirror.

---

## TL;DR

**The hook is `res://game.gd`, the signal is `player_actionable`, the submit
call is `target_player.on_action_selected(action, data, extra)`, the
deterministic lookahead is `game.copy_to(ghost_game)` + `ghost_game.simulate_one_tick()`,
and the entire mod-loading system is in `res://modloader/ModLoader.gd`.** All
of that is readable in the open-source repo today.

**Recommended slice:**
1. Clone `uzkbwza/hustle`, install GodotSteam 3.5.1 in Godot 3.5.x, run a
   match from the editor.
2. Copy the structure of `_AIOpponents/` into a new mod folder; replace
   `AIController.gd`'s scoring/evaluation with a TCP call to a local bridge.
3. Bridge calls the Claude API with structured output; returns
   `{action, data, extra}`.
4. Stay on **local matches** — the AI mod itself documents that simultaneous
   move selection with an AI is "basically impossible," so online is out of
   scope.

---

## A. Decompile / run-from-source checklist (revised)

### A.0 The shortcut: you may not need to decompile at all

The original developer (`uzkbwza` on GitHub, `ivysly` on Steam/itch) maintains
the game's source publicly:

- **Repo:** https://github.com/uzkbwza/hustle (101★, 21 forks, default branch
  `main`, 96.7% GDScript)
- **Internal version string (from `Global.gd`):** `"1.9.27-steam-unstable"`
- **Engine requirement (in README):** "requires godotsteam 3.5.1"
- **Configured resolution:** `Vector2(640, 360)`, borderless, viewport stretch
- **Main scene (from `project.godot`):** `res://Main.tscn`

The actively-maintained fork that most modders work against is
[`TheanMcGarity/MultiHustleGame`](https://github.com/TheanMcGarity/MultiHustleGame),
which tracks the same tree and adds the `_AIOpponents/` mod folder.

**Implication:** if you can build **GodotSteam 3.5.1** (a custom Godot 3.5
build with Steam SDK linked), you can open the repo and run vanilla matches
without ever touching GDRE Tools.

### A.1 GodotSteam 3.5.1 — the engine you actually need

GodotSteam is a custom Godot fork with Steamworks compiled into the editor.
The project requires the 3.5.1 release specifically (later 3.5.x builds may
work but are not guaranteed). Get it from:

- GodotSteam releases: https://github.com/CoaguCo-Industries/GodotSteam (find
  the 3.5.1 tag / Steam-enabled editor binary for your OS)

You'll need the **editor build that includes Steam**, not stock Godot 3.5.1,
because `project.godot` registers `SteamHustle` (`res://SteamY.gd`),
`SteamLobby`, and a workshop uploader as autoloads — stock Godot can't
resolve the `Steam` GDNative singleton.

**Why opening in Godot 4 corrupts the project (Verified):** `project.godot`
syntax and the `extends "res://game.gd"` / signal-connect APIs target Godot
3.x. Godot 4 will attempt to convert the project and will mangle GDScript
syntax, `yield`/coroutines, signal API differences, scene format, and the
GDNative bindings that GodotSteam provides as a GDExtension only in 4.x.

### A.2 GDRE Tools — only if you can't get GodotSteam

If you choose the decompile route anyway (e.g., to match a public release
exactly):

- **Tool:** GDRETools/gdsdecomp (latest tagged release, currently 0.6.x for
  3.x project recovery). https://github.com/GDRETools/gdsdecomp
- **Known limit (Verified):** GDRE cannot decompile GDNative/GDExtension/GDMono
  binaries. That means `tbfg.dll` / `tbfg.so` (the native physics library, if
  the shipping build still uses one) won't be recovered — you must copy the
  binary from your Steam install.
- **Steps:** RE Tools → Recover Project → point at
  `YourOnlyMoveIsHUSTLE.pck` → output to an empty directory → note the
  reported Godot version → open in the matching editor.

### A.3 Steam install layout

Standard layout on Windows:

```
C:\Program Files (x86)\Steam\steamapps\common\Your Only Move Is HUSTLE\
├── Your Only Move Is HUSTLE.exe          # GodotSteam editor + game shell
├── Your Only Move Is HUSTLE.pck          # game data + scripts (for decompile route)
├── steam_api.dll / libsteam_api.so       # Steamworks
└── (any GDNative/GDExtension binaries the build ships)
```

User data (not the install dir):

```
%APPDATA%\YourOnlyMoveIsHUSTLE\          # configured custom_user_dir_name
├── playerdata.json
└── modded.json                          # ModLoader reads this to enable/disable mods
```

### A.4 Recovered-project layout (if you decompile)

After GDRE recovery you should see the same tree as `uzkbwza/hustle`:

```
project.godot
Main.tscn, Game.tscn
game.gd, main.gd, Global.gd, SteamY.gd
addons/  assets/  bin/  characters/  framework/  fx/  lib/
mechanics/  modloader/  networking/  obj/  projectile/  ui/  ...
Server.py                                # UDP hole-punch server (not used at runtime)
```

If the build ships native libs not recovered by GDRE, drop them in `lib/` (or
wherever the corresponding `.gdnlib` references) and let Godot regenerate the
`.import/` cache on first open.

### A.5 Step-by-step Windows checklist

> **Do this in a fresh Windows session.** Estimated 30–60 min end-to-end.

1. **Install Steam → install YOMIH** (you need the `.pck`, native libs, and a
   Steam login if you want Workshop access).
2. **Install GodotSteam 3.5.1 editor**
   (https://github.com/CoaguCo-Industries/GodotSteam → 3.5.1 release tag →
   the `godotsteam-...-windows-editor` zip).
3. **Place `steam_appid.txt`** containing `2212330` next to the editor exe so
   Steam can authenticate it in dev mode.
4. **Clone the source:** `git clone https://github.com/uzkbwza/hustle.git`
   (or fork
   [TheanMcGarity/MultiHustleGame](https://github.com/TheanMcGarity/MultiHustleGame)
   if you want the `_AIOpponents/` template included).
5. **Open the project** in GodotSteam editor → let it regenerate `.import/`
   (first import takes a few minutes — sprite/audio re-encoding).
6. **If the editor complains about missing GDNative `.dll`s** for things
   beyond Steam, copy the corresponding files out of your Steam install's
   game folder into the project (usually next to a `.gdnlib`).
7. **Hit Play.** The Main scene (`Main.tscn`) should boot to the main menu.
   Start a local match (Singleplayer or two-keyboard).
8. **Verify modloader is alive:** the dev console (`F12`) and the modloader
   menu in options should both work; the ModLoader autoload is registered in
   `project.godot`.

### A.6 Known failure modes

| Symptom                                                    | Cause                                              | Fix                                                                 |
|------------------------------------------------------------|----------------------------------------------------|---------------------------------------------------------------------|
| "Failed to load script ... GDNative not found"             | Stock Godot 3.5.1 instead of GodotSteam            | Switch editor to GodotSteam 3.5.1                                   |
| Crash on match start, missing class `Steam`                | Steam SDK didn't initialize                        | Put `steam_appid.txt` next to editor; launch from Steam-aware shell |
| Long first-open hang (10+ min)                             | `.import/` regenerating                            | Wait it out once; subsequent opens are fast                         |
| Editor opens but scenes look broken                        | Opened in Godot 4                                  | Throw away the conversion, reopen in 3.5.1                          |
| `tbfg` / native-lib import errors (decompile route only)   | Native binary not present in recovered project     | Copy from Steam install into `lib/` (or per the `.gdnlib` path)     |
| Mods don't appear in editor playtest                       | Mods live in `user://mods/`, not the project       | Use the modloader menu to install, or `modded.json` to enable        |

**Confidence labels:** the GodotSteam requirement, scripts, autoloads,
character roster, and modloader files are **Verified** from the open-source
tree. The exact list of GDNative `.dll`s shipped in the public build is
**Unknown** until inspected locally — most of the heavy lifting is plain
GDScript, so this may be a non-issue.

---

## B. Reusable mod source code (concrete templates)

### B.1 The reference AI: `_AIOpponents/`

Lives in the MultiHustleGame fork:
`https://github.com/TheanMcGarity/MultiHustleGame/tree/master/_AIOpponents`.
Files:

```
AICheckableUIData.tscn      # template for matching UI element types
AIController.gd             # the AI brain (≈400 lines of GDScript)
AIController.tscn           # scene node that hosts the controller
AILoader.gd                 # extends res://game.gd, adds the AIController node
ModMain.gd                  # registers script extensions with ModLoader
ModOptions.gd               # adds the AI difficulty / target slot to mod options
README.md                   # user-facing docs
_metadata                   # mod manifest
```

#### The bootstrap (Verified, verbatim)

```gdscript
# _AIOpponents/ModMain.gd
extends Node

func _init(modLoader = ModLoader):
    modLoader.installScriptExtension("res://_AIOpponents/ModOptions.gd")
    modLoader.installScriptExtension("res://_AIOpponents/AILoader.gd")
    # modLoader.installScriptExtension("res://_AIOpponents/ExperimentalChange.gd")

func _ready():
    pass
```

```gdscript
# _AIOpponents/AILoader.gd
extends "res://game.gd"

func _ready():
    add_child(preload("res://_AIOpponents/AIController.tscn").instance())
    ._ready()
```

**This is the entire game-hook pattern.** `AILoader` extends `game.gd` via the
ModLoader's script extension API, then in `_ready()` it instantiates a
controller and calls the parent `_ready()`. Our Claude controller will be the
direct replacement for `AIController.tscn`.

#### The decision loop (Verified, from `AIController.gd`)

The controller subscribes to the game's `player_actionable` signal — that is
the actual hook for the input phase, not a `start_input_phase()` method:

```gdscript
game.connect("player_actionable", self, "_start_decision_thread")
```

When the signal fires, the controller writes its choice into the player slot
and announces it:

```gdscript
target_player.queued_action = choice.action     # String: name of the chosen state/move
target_player.queued_data   = choice.data       # Dict: move-specific parameters
target_player.queued_extra  = {                 # Dict: DI, feint, etc.
    "DI":         di_as_percentage_int_vec(dir_to_opponent),
    "feint":      can_feint_this_turn,
    "prediction": -1,
    "reverse":    false
}
target_player.on_action_selected(queued_action, queued_data, queued_extra)
game.turns_taken[target_player.id] = true
Network.turns_ready[target_player.id] = true
main.call_deferred("_start_ghost")
```

**This is the verbatim submit_action shape** — replace the v1/v2 "(inferred)"
notes with this.

`di_as_percentage_int_vec` is exactly:

```gdscript
func di_as_percentage_int_vec(vec2: Vector2):
    return {"x": int(round(vec2.x * 100)), "y": int(round(vec2.y * 100))}
```

#### Legal-moves enumeration (Verified)

The list of currently legal moves is **the visible buttons in the action
UI** — not an iteration over the fighter's child states:

```gdscript
var action_buttons = main.find_node("P" + str(2 - id % 2) + "ActionButtons")
for button in action_buttons.buttons:
    if button.is_visible() and ... :
        # button.action_name : String   → use as queued_action
        # button.state       : CharState → has .type (ActionType enum), .data_ui_scene
        ...
```

Each button has `.action_name` (the move ID we'd send to Claude),
`.is_visible()` (the legality filter), and `.state` which is the `CharState`
node (with `.type` from the `ActionType` enum: Movement / Attack / Special /
Super / Defense / Hurt). The reference AI skips `"Taunt"` and
`"DefensiveBurst"` via a `states_to_ignore` array; we should expose taunts to
Claude but it should usually skip them too.

#### Deterministic lookahead (Verified)

Critical correction to v2: lookahead is **fully accessible from GDScript** —
no native `tbfg` API needed. The reference AI uses it:

```gdscript
func setup_ghost_game():
    if ghost_game and is_instance_valid(ghost_game):
        ghost_game.free()
    var gg_scene = load("res://Game.tscn")
    ghost_game = gg_scene.instance()
    ghost_game.is_ghost  = true
    ghost_game.visible   = false
    ghost_viewport.add_child(ghost_game)    # main.find_node("GhostViewport")
    ghost_game.start_game(true, main.match_data)
    ghost_game.ghost_speed  = 100
    ghost_game.ghost_freeze = false
    game.copy_to(ghost_game)                # snapshot current real state
```

Then to evaluate a hypothetical move pair:

```gdscript
evaluee.queued_action = action          # our move
opponent.queued_action = opponent_action # assumed opponent move
for tick in range(1, FRAMES_TO_SIMULATE + 1):
    ghost_game.simulate_one_tick()
    # read evaluee.hp, opponent.hp, .state_interruptable, etc.
```

The reference AI simulates **35 frames** (`FRAMES_TO_SIMULATE = 35`) and
scores on:

```
eval = (frame_advantage * 20)        # FRAME_ADVANTAGE_MODIFIER, halved if dist < 50
     + (damage          *  1)        # DAMAGE_MODIFIER
     + (distance_closed *  0.1)      # DISTANCE_MODIFIER, flips sign if taking damage
     + (super_levels    * -0.5)      # SUPER_MODIFIER
```

…with state-specific overrides (Burst, OffensiveBurst, DefensiveBurst get
massively penalized when negative; InstantCancel/WhiffInstantCancel zeroed).
Hard difficulty does one extra step of opponent-then-self prediction.

We can either feed scored shortlists to Claude, or expose the ghost-game step
function to Claude as a tool call so it reasons over predicted states.

### B.2 The ModLoader itself (Verified)

`res://modloader/ModLoader.gd` ("ModLoader V1.1"):

- Reads `user://modded.json` to know which mods are enabled.
- Scans zips in the game directory and Steam Workshop subscriptions for
  `ModMain.gd` files.
- Validates each mod's `_metadata` JSON.
- `_dependencyCheck()` honors `requires`.
- Loads in priority order; instantiates `ModMain` via Godot's resource
  system.
- MD5-hashes mod files for integrity / online-compat checks.
- Supports asset overwrites (textures, animations, sounds) including the
  character-specific multi-sprite handling for Cowboy / Wizard / Robot.

Adjacent files in `modloader/`:

```
ModLoader.gd, MLMainHook.gd, MLStateSounds.gd, ModHashCheck.gd,
ModLoaderCredits.gd / .tscn, ModLoaderMenu.gd / .tscn, ModLoaderWindow.gd / .tscn,
ModdedRichText.gd, BBFx/, gdunzip/, workshop_uploader/, _metadata-template, README.md
```

### B.3 `_metadata` (Verified, verbatim from YOMIRecord)

```json
{
  "author": "Snazzah",
  "client_side": true,
  "description": "Screenshot and record replays",
  "friendly_name": "Your Only Move Is Record",
  "id": "12345",
  "link": "https://github.com/Snazzah/YOMIRecord",
  "name": "YOMIRecord",
  "overwrites": false,
  "priority": -9000,
  "requires": [""],
  "version": "1.3.2"
}
```

Field semantics (Verified from ModLoader.gd behavior):

| Field           | Type    | Effect                                                                  |
|-----------------|---------|-------------------------------------------------------------------------|
| `name`          | string  | internal mod ID, used by `requires` of other mods                       |
| `friendly_name` | string  | shown in UI                                                             |
| `description`   | string  | shown in UI                                                             |
| `author`        | string  | attribution                                                             |
| `version`       | string  | display only (no strict semver enforcement)                             |
| `link`          | string  | external link (often GitHub / Workshop)                                 |
| `id`            | string  | unique identifier (often the Workshop ID)                               |
| `overwrites`    | bool    | true if the mod replaces raw assets (textures/sounds/anims)             |
| `client_side`   | bool    | true means safe-ish to mismatch with the opponent in multiplayer        |
| `priority`      | int     | lower loads earlier; YOMIRecord uses `-9000` to load very early         |
| `requires`      | array   | other mod `name`s that must load first                                  |

### B.4 YOMIRecord — minimal hook scaffold (Verified)

`ModMain.gd` skeleton (paraphrased from the repo):

```gdscript
extends Node2D

var recorder: Node
var options: Node
var ffmpeg: Node
const MOD_NAME = "Your Only Move Is Record"

func _init(modLoader = ModLoader):
    modLoader.installScriptExtension("res://YOMIRecord/MLMainHook.gd")
    # conditional script extensions for inter-mod compat
    # e.g. if SoupModOptions / DiscordRichPresence are present

func _ready():
    options  = preload("res://YOMIRecord/Options.gd").new()
    ffmpeg   = preload("res://YOMIRecord/FFmpeg.gd").new()
    recorder = preload("res://YOMIRecord/Recorder.gd").new()
    add_child(options); add_child(ffmpeg); add_child(recorder)
```

`MLMainHook.gd` extends `res://modloader/MLMainHook.gd`, uses
`call_deferred("_yomirecord_init")`, and injects UI subtrees into
`res://YOMIRecord/ui/...`. Pattern to copy for any client-side mod that needs
UI surface.

### B.5 YH Mod Assistant (Verified)

[Valkarin1029/YHModAssistant](https://github.com/Valkarin1029/YHModAssistant)
— Godot editor plugin under GPL-3.0, ships three templates: **Blank**,
**Character**, **Overwrite**. Installs into the `addons/` folder of the
recovered project (or the cloned source); adds an editor dock for auto-export
on debug run and zip packaging. Don't clone — download the release zip
(cloning the repo errors out per the README).

### B.6 Names worth noting but lower priority

- **MultiHustleGame** (uGuardian → currently TheanMcGarity): not just a fork
  of the source — it's the platform that hosts the reference `_AIOpponents/`
  mod and adds 4-player support, custom multiplayer input handling, replay
  manager, Steam lobbies / workshop integration.
- **YomiBot** (Monocly-Man): Discord frame-data bot with per-character JSONs
  (`cowboy.json`, `ninja.json`, …) keyed by Move with Startup/IASA/Active/
  Damage/Resource/Proration/Notes. This is the de-facto frame-data dataset to
  feed Claude's system prompt — see Section C.
- **The Hacker** mod (Steam Workshop): live GDScript injection at runtime
  exposing `p1` / `p2` / `objects`. We could not locate a public source
  repository — **Unknown**. Useful for ad-hoc experiments only.
- **AxNoodle's "AI Opponent | Goon"** (Steam Workshop): publicly described
  as an AI mod targeting a specific character; **likely** a thin wrapper or
  successor to the `_AIOpponents/` reference AI. No public source located —
  **Unknown** whether it diverges materially.

---

## C. Game-strategy knowledge for Claude's cached system prompt

### C.1 Verified base-game roster (from `Global.gd`)

Five base characters, with internal folder names in `characters/`:

| Display name | Folder        | Role / hook                                                        |
|--------------|---------------|--------------------------------------------------------------------|
| **Ninja**    | `stickman/`   | speed, mobility, NunChuk + SWAY stances, shuriken & sticky bomb    |
| **Cowboy**   | `swordandgun/`| Quickdraw + Gun + Lasso stances, teleports for whiff-punish        |
| **Wizard**   | `wizard/`     | zoner with projectiles and area-control magic                      |
| **Robot**    | `robo/`       | resource/charge gimmicks, heavy hitter                              |
| **Mutant**   | `alien/`+`mutant/` | "extremely fast melee" glass cannon (per community summary)   |

(Names like Samurai / Skelly / Dancer that appeared in v1's prompt are
**not** in the base roster — those are popular Workshop mods and should not
be in Claude's system prompt unless we explicitly load them.)

### C.2 Universal mechanics (Verified from `BaseChar.gd` and `CharState.gd`)

- **`MAX_HEALTH = 1500`** per fighter (v1's "10000" was wrong).
- **Super meter** capped at 125; gained from damage dealt/taken.
- **Burst meter** for defensive options (Burst / OffensiveBurst /
  DefensiveBurst).
- **Air option bar** — tracks remaining aerial movement (jumps/dashes).
- **Combo system:** `combo_count`, `combo_damage`, `combo_proration` with
  staling on repeated moves; **DI scaling** runs from `min_di_scaling` to
  `max_di_scaling` and grows with combo count.
- **Penalty system** (`penalty` ∈ [-20, 75]): increases when a player runs
  away, affects super gain and damage output — anti-runaway tax. Claude must
  not turtle.
- **Action types** (`CharState.ActionType` enum): Movement, Attack, Special,
  Super, Defense, Hurt — useful tags for the prompt.
- **Air type** (`CharState.AirType` enum): Grounded, Aerial, Both — gates
  legality.
- **Interrupt timing:** every state has `iasa_at` (interrupt-as-soon-as) and
  `interrupt_frames`; the actionable signal fires when
  `state_interruptable || state_hit_cancellable || dummy_interruptable`.
- **Frame advantage** = `opponent_actionable_tick − self_actionable_tick`.
  The reference AI weights this 20× — frame advantage is the dominant
  decision factor.
- **Parry:** correct-timing block; `block_hitbox()` handles parry vs block.
- **Feint:** can cancel a move if `can_feint()`; AI uses feints when
  evaluated frame advantage is negative.

### C.3 Frame-data fields (Verified from YomiBot character JSONs)

YomiBot character files (e.g. `cowboy.json`) consistently use:

```
{ "Move", "Startup", "IASA", "Active", "Damage", "Resource", "Proration", "Notes" }
```

- **Startup**: frames before active.
- **IASA**: interrupt-as-soon-as; how soon you become actionable.
- **Active**: frames the hitbox is live.
- **Damage**: per-hit damage (note: total HP = 1500 → 100 damage is ~6.7%).
- **Resource**: meter / bullet / gun / air-option cost.
- **Proration**: combo scaling tag (lower = combo-starter friendly).
- **Notes**: situational flags ("Air OK", "QD only", "Low", "Unparriable",
  etc.).

### C.4 Sample frame data (Verified, Cowboy from `cowboy.json`)

| Move                 | Startup | IASA           | Active | Damage      | Resource | Proration | Notes                                          |
|----------------------|---------|----------------|--------|-------------|----------|-----------|------------------------------------------------|
| Walk                 | ?       | ?              | –      | –           | –        | –         | –                                              |
| Teleport             | 5–19    | 10–30          | –      | –           | –        | –         | startup/recovery scale with distance, QD OK    |
| Instant Teleport     | 5       | 8              | –      | –           | 1 meter  | –         | Air OK                                         |
| Pommel               | 4       | 14             | 2      | 40          | –        | 1         | great for restanding in combos                 |
| Horizontal Slash     | 6       | 16             | 2      | 100         | –        | 1         | –                                              |
| Vertical Slash       | 11      | 17             | 2      | 115         | –        | –         | 9f with initiative                             |
| Upwards Slash        | 8       | 23             | 4      | 70          | –        | –         | launches                                       |
| Downwards Cleave     | 9       | 4 after land   | until land | 70      | –        | –         | air only                                       |
| Lightning Slice      | 9, 6    | 17, 17         | 1      | 110, 60     | –        | 3         | followups can't aim                            |
| 3 Combo Up           | 8,13,25 | 38             | 2,2,3  | 40,50,160   | air opt  | –         | Air OK                                         |
| Ankle Cutter         | 7       | 23             | 2      | 70          | –        | –         | low                                            |
| Stinger              | 11      | 21             | 2      | 120         | –        | -1        | inf hitstun                                    |
| Impale               | 7–?     | 41             | 4      | 50, 145     | –        | –         | teleports to opponent, hitgrab                 |
| Lasso → Pull         | 9 / –   | 22 / 9         | until cancel / 1 | – / 40 | –        | –         | Lasso stance, Air OK                           |
| Lasso → Izuna Drop   | –       | 42 after hit   | –      | 190         | –        | –         | Air OK, Lasso only                             |
| Gun Throw            | 9       | 19             | until land | 800     | Gun      | –         | 3 aim angles, Air OK, QD OK                    |
| Quickdraw            | 9       | –              | –      | –           | –        | –         | enters QD stance, Air OK                       |
| QD → Shoot           | 5(14),6 | –              | 2      | 90–60 (150) | Bullet   | –         | HKD, QD only                                   |
| QD → Temporal Round  | 5(14),32| 10             | –      | 90–36       | 1 meter  | –         | QD only or right after Shoot                   |
| 1000 Cuts            | 5,7     | 12             | 2      | 50          | 3 meter  | –         | kills projectiles, Air OK, QD OK               |
| Hustle               | ~21     | 61             | 1      | 20          | +1 meter | –         | QD OK                                          |

Cowboy is a stance fighter: **Gun** (single-use projectile, huge damage),
**Lasso** (grab/Izuna), **Quickdraw** (Shoot/Temporal/1000 Cuts). Teleport
threatens whiff-punish at all ranges.

### C.5 Ninja highlights (Verified, from `ninja.json`)

Stance-based (NunChuk, SWAY). Tools include Punch / Kick / Sweep / Air
variants, Dive Kick (3 aim angles, air only with initiative), Uppercut,
Shuriken & Sticky Bomb projectiles, Store/Release momentum, Substitution
(uses projectiles), Backsway (9f invuln), Palm Strike (200dmg SWAY only),
Caltrops (3 meter, "High in air, Low on ground, Unparriable on ground"),
Hustle for meter gain, Quick Slash (1 meter).

Mutant / Wizard / Robot frame data isn't in YomiBot but the JSON schema is
the same — when Claude is in a session, we should ship the matching
`<char>.json` if available.

### C.6 Core concepts Claude needs in its system prompt

1. **Turn structure.** Game pauses on every actionable frame. Both players
   simultaneously pick `{action, data, extra}`. Then a deterministic
   simulation runs until either player is actionable again. The agent has
   unlimited think time per turn.
2. **Frame advantage is king.** The reference AI weights it 20× over damage.
   Always prefer moves that leave you actionable before the opponent —
   especially after blocking or trading.
3. **Damage scaling / proration.** Combos scale; finishers in a long combo
   do little. Pick combo-starters with low proration to enable longer chains.
4. **DI mechanics.** Defender's `extra.DI` is a 360° vector applied during
   hitstun. Scaling grows with combo length so late-combo DI matters less.
   `DI` is serialized as `{x: int(round(v.x*100)), y: int(round(v.y*100))}`.
5. **Neutral / spacing.** Stay just outside opponent's longest poke; whiff
   punish on recovery. The "penalty" system taxes runaway play, so don't
   sit in pure defense.
6. **Oki / wakeup.** After knockdown, attacker chooses meaty timings
   vs grab vs ambiguous setup; defender picks parry / wakeup
   reversal (Burst / DP-style) / delayed get-up.
7. **Resource economy.** Super meter (cap 125), Burst meter, air options
   refill on land. Bursts are emergency-only — the reference AI heavily
   penalizes them when ahead and lets them swing big when behind.
8. **Stance characters (Cowboy / Ninja).** Track which stance you're in;
   inputs change. Quickdraw → Shoot / Temporal / 1000 Cuts; Lasso → Pull /
   Izuna.

### C.7 Universal patterns

- **Anti-air:** uppercut-class moves (Vertical / Upwards Slash for Cowboy,
  Uppercut for Ninja).
- **Whiff punish:** stay just out of range, dash in on recovery, use the
  fastest startup move that reaches.
- **Combo from launcher:** Upwards Slash / launch → Air Horizontal Slash →
  reset / Lasso → Izuna Drop family.
- **Don't burst at >50% HP unless out of options** (mirrors the AI's
  `state_specific_modifiers` for Burst).

---

## D. Delta-V / godot-mod-loader + Godot 3.5 deep dive

### D.1 `installScriptExtension(path: String)` — Verified

The standard Godot Mod Loader exposes it via the `ModLoader` autoload. It:

1. Loads the script at `path`.
2. Reads the `extends "res://..."` line to find the target.
3. Calls `take_over_path(target)` on the loaded script so any new
   `load("res://target.gd")` returns the extended subclass.
4. Chains gracefully if multiple mods extend the same target; chain order is
   driven by `manifest.json` fields `dependencies`, `optional_dependencies`,
   `load_before` (and YOMIH's `_metadata` field `priority` / `requires`).

In overridden methods, call the parent via the bare-dot syntax in GDScript
3.x:

```gdscript
extends "res://game.gd"
func _ready():
    ._ready()              # calls the original
    add_child(MyController.new())
```

**Caveats:** the editor can't run extensions before the runtime loads (the
`installScriptExtension` call requires the running ModLoader autoload), so
in-editor F6 of a mod scene won't apply the override. Test via running the
game with mods loaded.

### D.2 Mod packaging (Verified from ModLoader.gd behavior)

- Mods are distributed as `.zip` files.
- **Folder layout:** all files inside a single top-level directory named to
  match the mod (no files at the zip root).
- The top-level dir must contain `ModMain.gd` and `_metadata`.
- ModLoader scans both the game-install dir and Steam Workshop subscriptions
  for matching zips.
- Whether mods are enabled is read from `user://modded.json`.

### D.3 Lifecycle (Verified)

- **`_init(modLoader = ModLoader)` on `ModMain.gd`** — fires *before*
  autoloads are fully wired. Register all script extensions here.
- **`_ready()`** — autoloads (`Global`, `Network`, `ReplayManager`,
  `SteamHustle`, `SteamLobby`, `Custom`, `ModOverride`, `ModLoader`) are
  available; add child nodes, attach signals.

### D.4 Autoloads YOMIH ships (Verified, from `project.godot`)

| Autoload      | Script             | Purpose                                          |
|---------------|--------------------|--------------------------------------------------|
| `Global`      | `Global.gd`        | version, player data, options                    |
| `SteamHustle` | `SteamY.gd`        | Steam SDK wrapper                                |
| `ReplayManager` | (in repo)        | replay loading/saving, `resimulating` flag        |
| `Network`     | (in repo)         | multiplayer state, `multiplayer_active`, `turns_ready` |
| `ModLoader`   | `modloader/ModLoader.gd` | mod discovery + activation                 |
| `SteamLobby`  | (in repo)         | Steam lobby management                            |
| `Custom`      | (in repo)         | custom character / asset registry                 |
| `ModOverride` | (in repo)         | asset override system                             |

### D.5 Steam Workshop publishing

YH Mod Assistant adds an auto-export-on-debug feature; the modloader's
`workshop_uploader/` handles publishing zipped mods through Steam. We don't
need this until we want to share the Claude controller publicly.

### D.6 Godot 3.5 GDScript gotchas relevant to the bridge

- **`StreamPeerTCP` API** (Verified):
  `connect_to_host(host, port)`, `get_status()` returning
  `STATUS_NONE / STATUS_CONNECTING / STATUS_CONNECTED / STATUS_ERROR`,
  `put_data(bytes)`, `put_32(int)`, `get_available_bytes()`,
  `get_data(bytes)` returning `[err, PoolByteArray]`. Blocking by design once
  connected — perfect for a turn-locked bridge.
- **HTTPRequest is async**; using `yield(httpr, "request_completed")` inside
  the input phase will yield back to the main loop. Combined with the
  `Network` autoload's tick logic, this risks races with `turns_ready`. Use
  `StreamPeerTCP` instead.
- **GDScript is single-threaded.** `OS.delay_msec()` blocks the main loop
  including input/render. Using small (1–5 ms) sleeps in a poll loop is the
  standard pattern; the game window will appear "thinking" but not crash —
  Windows shouldn't flag it as Not Responding under a few seconds.
- **`Thread` / `Mutex`** exist if you want to run the TCP I/O off the main
  thread; sending the result back via `call_deferred` lets you write to the
  player state on the main thread safely. The reference AI does
  `main.call_deferred("_start_ghost")` after submitting — same idiom.
- **GDNative calls** from GDScript can block; if anything beyond pure
  GDScript runs in the simulation step (e.g., a fixed-point math native lib),
  you cannot interrupt mid-call.
- **Determinism caveat:** the game uses RNG seeding for deterministic
  replays. If we ever want to log/replay matches Claude played, log the seed.

---

## E. Online netplay desync risk

### E.1 What we know (Verified)

- The game ships a Python UDP **hole-punch server** (`Server.py`, Twisted)
  for NAT traversal — confirms **peer-to-peer** networking, not a central
  authority.
- `Network` autoload exposes `turns_ready[player_id]` flags that the
  controller writes when it submits a move; matches advance once both flags
  are set.
- `ReplayManager.resimulating` is set during ghost simulations and is
  toggled off when committing real moves — the same code path is used for
  replay playback and lookahead.

### E.2 What the reference AI says (Verified)

The `_AIOpponents/` README explicitly states that **the AI cannot select
moves simultaneously with the player due to a technical constraint the
developer describes as "basically impossible."** Concretely, the reference
implementation pauses, picks the player's move first (assumes it), then
picks its own — i.e. it gets a non-blind step. That's incompatible with
double-blind online play.

In `AIController.gd`, the controller does pre-`make_move()`:

```gdscript
if Network.multiplayer_active:
    id = 0
    difficulty = 1
```

It deliberately neuters itself in multiplayer.

### E.3 Implication for Claude

- **Local-only.** Treat Claude as Player 2 in singleplayer / two-keyboard /
  spectated local. Don't try to use the same hook in online matches.
- **If we did want online**, Claude would have to commit blind (no peeking at
  opponent input) and finish within the network's input deadline. The
  deadline is **Unknown** from the public docs — we'd need to instrument
  `Network.gd` to find it, and it's almost certainly less than a sane Claude
  API round-trip.
- **No anti-cheat / kick-on-mod evidence found.** Steam discussions show
  modded characters being filtered out of default lobbies (post 1.9.19) and
  general desync complaints, but no targeted ban on AI mods.

### E.4 Practical mitigation if someone insists on online play

- Run Claude with a tight token budget on Haiku for speed; have the bridge
  pre-warm and cache the system prompt.
- Pre-decide a fallback move (e.g., `Continue` / safe block) and submit it if
  Claude doesn't return within ~250 ms.
- Disable the lookahead ghost game (no peeking).
- Accept that it will be much weaker than the offline version.

This is **Inferred** — we have not built or tested it.

---

## Top remaining unknowns to resolve in the Windows session

1. **Exact GodotSteam 3.5.1 binary that works.** The CoaguCo-Industries
   releases list is large; the right tag for the editor build needs
   confirmation by running it against `project.godot`. **(Unknown)**
2. **Any GDNative `.dll`s ship in the public build beyond Steam.** If the
   game still uses a native physics library, identify it, drop it into
   `lib/`, and confirm scenes load. **(Unknown — possibly not needed if
   physics is pure GDScript in the current build)**
3. **Full character roster JSONs.** YomiBot has Cowboy & Ninja public;
   Wizard / Robot / Mutant frame data likely lives in the source's
   per-character scripts (`characters/wizard/`, `characters/robo/`,
   `characters/alien/` + `mutant/`). Extract the frame data from those
   scripts and emit Claude-friendly JSONs. **(Reachable from source)**
4. **`game.gd` input-deadline / turn-timeout constants for online.** The
   numeric tolerance for `Network.turns_ready` propagation isn't in any
   public docs. **(Reachable from source: search `Network.gd` for
   timeouts.)**
5. **Whether `target_player.queued_data` schema matches exactly what
   `on_action_selected` validates** for every move type. The reference AI
   builds data via `get_data_structure()` from the move's `data_ui_scene` —
   we should round-trip a few moves to confirm the dict shape Claude must
   emit. **(Spike from the editor.)**
6. **Public source for "The Hacker" and "AI Opponent | Goon"** — if they
   exist on GitHub, they're worth folding in; otherwise we crib from
   `_AIOpponents/` alone. **(Steam Workshop pages don't include source —
   search the YOMIH modding Discord.)**

---

## Sources

- Game source: [uzkbwza/hustle](https://github.com/uzkbwza/hustle)
- AI reference mod: [MultiHustleGame/_AIOpponents](https://github.com/TheanMcGarity/MultiHustleGame/tree/master/_AIOpponents)
- Hook & UI mod example: [Snazzah/YOMIRecord](https://github.com/Snazzah/YOMIRecord)
- Editor templates: [Valkarin1029/YHModAssistant](https://github.com/Valkarin1029/YHModAssistant)
- Mod-wiki repo: [tiggerbiggo/YomiHustleModWiki](https://github.com/tiggerbiggo/YomiHustleModWiki)
- Frame-data bot + JSONs: [Monocly-Man/YomiBot](https://github.com/Monocly-Man/YomiBot)
- Godot Mod Loader (general): [GodotModding/godot-mod-loader 3.x](https://github.com/GodotModding/godot-mod-loader/tree/3.x)
- Script Extensions docs: [Godot Mod Loader Wiki](https://wiki.godotmodding.com/guides/modding/script_extensions/)
- Mod Files docs: [Godot Mod Loader Wiki](https://wiki.godotmodding.com/guides/modding/mod_files/)
- GodotSteam: [CoaguCo-Industries/GodotSteam](https://github.com/CoaguCo-Industries/GodotSteam)
- GDRE Tools: [GDRETools/gdsdecomp](https://github.com/GDRETools/gdsdecomp)
- Mod Compatibility / Crash Fix: [Steam News](https://store.steampowered.com/news/app/2212330/view/4168717862243878207)
- Patch 1.9.19 notes: [Steam News](https://store.steampowered.com/news/app/2212330/view/4264427597921360014)
- Web port (reference for asset structure): [burga117/your-only-move-is-HUSTLE](https://github.com/burga117/your-only-move-is-HUSTLE)
- Workshop modding hub: [Steam Workshop for YOMIH](https://steamcommunity.com/app/2212330/workshop/)
- Steam guide: [YOMI HUSTLE COMMON ISSUES FAQ](https://steamcommunity.com/sharedfiles/filedetails/?id=3376307130)
- Itch.io thread: [HOW TO PLAY](https://itch.io/t/2471192/how-to-play)
- Yomi Hustle Fandom Wiki: [yomi-hustle.fandom.com](https://yomi-hustle.fandom.com/wiki/Your_Only_Move_is_Hustle)
- TV Tropes: [Characters/YourOnlyMoveIsHustle](https://tvtropes.org/pmwiki/pmwiki.php/Characters/YourOnlyMoveIsHustle)
