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
| Frame-advantage gets halved when `distance_closed < 50` | ⚠️ Confirmed-but-dead-code | `frame_advantage_modifier /= 10` exists in source (note: **10**, not 2 as "halved" suggests). **But see Corrected #7 below** — the local var that gets divided is never read; the eval uses the uppercase export `FRAME_ADVANTAGE_MODIFIER` instead. The line runs but has no effect on score. |

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

### State tag enums and per-character constants (newly verified by audit)

| Claim | Status | Evidence |
|---|---|---|
| `ActionType` enum order: `{Movement=0, Attack=1, Special=2, Super=3, Defense=4, Hurt=5}` | ✅ Confirmed | `characters/states/CharState.gd`. AIController filters with `button.state.type != 0` to exclude Movement-typed buttons from the candidate set. |
| `AirType` enum: `{Grounded, Aerial, Both}` | ✅ Confirmed | `characters/states/CharState.gd` |
| `BusyInterrupt` enum: `{Normal, Hurt, None}` — third state-tag enum, not previously documented | ✅ Confirmed | `characters/states/CharState.gd` |
| `MAX_SUPER_METER = 125` AND `MAX_SUPERS = 9` (distinct concepts the research collapsed into a single super-meter cap) | ✅ Confirmed | `characters/BaseChar.gd` |
| `MIN_PENALTY = -20`, `MAX_PENALTY = 75`, `PENALTY_MIN_DISPLAY = 50` | ✅ Confirmed | `characters/BaseChar.gd` |
| `iasa_at`, `iasa_on_hit`, `iasa_on_hit_on_block`, `interrupt_frames` fields on `CharState` | ✅ Confirmed | `characters/states/CharState.gd` |
| Full `can_interrupt()` body | ✅ Confirmed | Returns true when: `current_tick == iasa_at  or  current_tick in interrupt_frames  or  current_tick == anim_length - 1  or  ((hit_fighter or hit_hit_cancellable_projectile) and current_tick == iasa_on_hit)  or  (was_blocked and iasa_on_hit_on_block and current_tick == iasa_on_hit)`. Five-way disjunction, not the 2-3 cases the research implied. |
| `combo_count`, `combo_damage`, `combo_proration` fields in `BaseChar.state_variables` | ✅ Confirmed | `characters/BaseChar.gd::state_variables` dict |
| `min_di_scaling = "1.0"`, `max_di_scaling = "6.0"` stored as **fixed-point strings** (not floats) | ✅ Confirmed | `BaseChar.gd`. Both processed via `fixed.mul`. **Matters when the bridge serializes state for Claude — must JSON-encode as strings, not unquoted numbers, or downstream fixed-point math will break on the round-trip back into the sim.** |
| `block_hitbox(hitbox, force_parry, force_block, ignore_guard_break, autoblock_armor)` 5-arg signature on `BaseChar` | ✅ Confirmed | `characters/BaseChar.gd::block_hitbox` |
| `can_feint()` on `CharState` returns true when `(has_hitboxes or force_feintable) and (host.feints > 0 or host.get_total_super_meter() >= host.MAX_SUPER_METER)` | ✅ Confirmed | `characters/states/CharState.gd::can_feint`. **Full super meter substitutes for a feint charge** — the research treated feints as a strict resource counter; it's actually meter-fallback-enabled. |
| `state_specific_modifiers` in `AIController.gd` has **6 keys**: `WhiffInstantCancel`, `InstantCancel`, `Roll` (all `{*, 0.5}`), plus `Burst`, `DefensiveBurst`, `OffensiveBurst` (each with BOTH a `{*, 0}` positive branch AND `{+, -999999}` negative branch). The Burst-class entries make burst moves never picked even when their positive eval looks attractive. | ✅ Confirmed | `AIController.gd` top-of-file `state_specific_modifiers` dict. The original VALIDATION row missed `Roll` and didn't note the dual-branch structure for Burst-class. |
| Hard difficulty extra prediction step is gated by `opponent.combo_count <= 0`: `if difficulty == 3 and target_player.opponent.combo_count <= 0` | ✅ Confirmed | `AIController.gd::make_move`. **During opponent combos, Hard difficulty reverts to standard depth** — the extra opponent-then-self ply only runs when the opponent is NOT mid-combo. |
| `queued_extra` feint field is guarded by feint-charge count: `"feint": choice.feint if target_player.feints > 0 else false` | ✅ Confirmed | `AIController.gd::make_move`. Forced false when no feint charges remain, regardless of what the candidate chose. (Note this is the simpler `feints > 0` guard, not the meter-fallback version — the `can_feint()` substitution doesn't propagate up to here.) |

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

**Caveat:** no `.dylib` shipped in `lib/`. The `.DS_Store` suggests the
project was checked in from a Mac, but the macOS binary isn't in the tree.
**Before cloning-and-running**, verify whether the committed `tbfg.dll` and
`tbfg.so` are real binaries or just LFS pointers / symlinks — file sizes
of 1.2 MB and 5.1 MB are *consistent* with real binaries but the GitHub
file listing alone doesn't prove it. **No Linux/Mac builds shipped in the
GitHub repo other than `tbfg.so`** — fine for Windows + Linux dev. (The
macOS `.dylib` intent — forgotten? Steam-only? — is moved to the open
questions list below.)

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

### 3. Mods CANNOT extend `res://Network.gd` (but CAN extend `res://cl_port/Network.gd`)

A security check the research missed entirely:

```gdscript
# ModLoader.gd::installScriptExtension
if parentScript.resource_path != "res://Network.gd" or childScript.resource_path == "res://modloader/ModHashCheck.gd":
    childScript.take_over_path(parentScriptPath)
else:
    print("You can't access network!")
```

Any mod that tries to extend `res://Network.gd` is **logged and skipped**
(ModLoader prints `"You can't access network!"` — not silently rejected as
earlier wording implied; only ModHashCheck is whitelisted).

**Important caveat the original audit row missed:** the check only blocks
`res://Network.gd`. The *actual* autoload is `res://cl_port/Network.gd`,
which itself `extends "res://Network.gd"`. A mod extending
`cl_port/Network.gd` is NOT blocked by this check and would inherit the
full Network API (including everything in the base). So the security
boundary is narrower than the print statement suggests.

**Implication for us:** if the Claude bridge ever needs to inspect or
influence multiplayer state, it has to do it indirectly — but the door is
NOT fully closed at the cl_port layer. Aligns with the local-only stance
we already adopted, but worth pinning down.

### 4. The Mutant character lives in `characters/mutant/`, not "`alien/+mutant/`"

RESEARCH.md §C.1 lists Mutant's folder as "`alien/`+`mutant/`". Actually:

- `name_paths["Mutant"] = "res://characters/mutant/Mutant.tscn"` (single
  folder).
- `Alien` IS in `name_paths` but commented out — it's not in the active
  roster.
- Class is `Mutant extends Fighter`, script at `mutant/Beast.gd`.
- `BeastState` lives under `characters/mutant/states/`.

**Tightened scope rule:** for frame-data extraction (states, hitboxes,
damage values, tag enums), walk `characters/mutant/states/` and
`characters/mutant/Beast.gd` **only**. For **sprite assets**, that
restriction is too tight — grep `Mutant.tscn` for `ExtResource` paths
first, since some sprite resources may still live under
`characters/alien/sprites/` (legacy from when Mutant was Alien). Don't
assume sprite paths follow the state-folder rule.

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

### 7. Frame-advantage distance multiplier is /10, not "halved" — AND it's DEAD CODE

RESEARCH.md §B.1 says "halved if dist < 50". Source says `/= 10`. Small but
real — it makes close-range frame advantage matter ~5× less than the
research suggested.

**BUT** — second look at `eval_move()` shows the `/= 10` line never
actually affects the score. The function declares a local
`frame_advantage_modifier` (lowercase), divides it by 10 when
`distance_closed < 50`, and then the eval expression at the bottom of the
function uses the **uppercase module-level export** `FRAME_ADVANTAGE_MODIFIER`
instead. The two lines that matter, from `AIController.gd`:

```gdscript
# inside eval_move(), distance branch:
if distance_closed < 50:
    frame_advantage_modifier /= 10   # local var — never read again
# ...
# end of eval_move(), the actual score expression:
return frame_advantage * FRAME_ADVANTAGE_MODIFIER + damage_dealt * DAMAGE_MODIFIER + ...
```

The local `frame_advantage_modifier` is computed and discarded. The eval
uses `FRAME_ADVANTAGE_MODIFIER` (constant 20). **So close-range frame
advantage is NOT downweighted in the reference AI** — the downweight is a
bug that the developer almost certainly intended but never wired up.

**Implication for our Claude controller:** when we replicate the eval
function (either as a tier-2 fallback or as part of a v2 hybrid), we have
three choices, each defensible:

- (a) **Replicate the bug** verbatim — match the reference AI's actual
  behavior so A/B comparisons are clean.
- (b) **Fix it** to `frame_advantage * (FRAME_ADVANTAGE_MODIFIER / 10)`
  when `distance_closed < 50` — what the developer presumably meant.
- (c) **Drop the downweight entirely** and just use the flat
  `FRAME_ADVANTAGE_MODIFIER` everywhere — what the reference AI does in
  practice anyway, but explicit.

Recommendation: pick (a) for v1 tier-2 fallback (we want the fallback to
match the reference AI we're A/B-ing against), and revisit if/when v2
introduces re-weighting.

### 8. `player_actionable` is singleplayer-ONLY — stronger basis for AI being SP-only

RESEARCH.md justifies the AI-is-singleplayer-only constraint with a
developer quote. The actual mechanical basis is stronger: in
`game.gd::process_tick()`, the `player_actionable` signal is emitted only
inside the `if singleplayer:` branch. The multiplayer branch is
`elif !is_ghost: someones_turn = true` — **the signal literally does not
fire** in multiplayer. Any AI mod that subscribes to `player_actionable`
will see zero events in MP games, regardless of intent.

This also contradicts the existing VALIDATION row that confirmed
"`signal player_actionable()` is emitted inside `process_tick()`" without
qualification — the emission is gated. Correction: it's declared
unconditionally but emitted ONLY under `singleplayer==true`. Our previous
phrasing was accurate at the declaration level but misleading at the
emission level.

**Implication for the bridge:** no extra defensive code needed to refuse
MP — the hook itself is silent in MP. But for clarity and forward
compatibility, the controller should still early-return on
`!game.singleplayer` if the signal ever does get extended.

### 9. YOMIRecord ModMain.gd lifecycle — RESEARCH §B.4 is wrong

RESEARCH.md §B.4 claims the YOMIRecord `ModMain.gd` follows the convention
"extensions registered in `_init()`, child nodes added in `_ready()`". The
actual file:

- Has **NO `_ready()` method at all**.
- Puts **all** child instantiation inside `_init()`, using `load()` (not
  `preload()`).
- Declares `MOD_NAME` as `var`, not `const`.

The "extensions in `_init`, nodes in `_ready`" split is a convention some
mods follow but it is NOT enforced by ModLoader — both patterns work
because `installScriptExtension` calls `childScript.new()` at extension
time anyway, and `add_child()` works fine from `_init` as long as the
parent is in-tree.

**Implication for our mod:** we can pick either pattern, but must do so
*explicitly* and document the choice. Combined with audit finding around
`installScriptExtension` calling `.new()` at load time (which makes
`_init` side effects persist), the recommendation is:

- Keep `ClaudeLoader.gd` minimal — override `_ready` only, no `_init`
  work.
- Move **all** socket-opening, thread-spawning, and TCP wiring into
  `ClaudeController._ready()`.
- Do this so that if `ClaudeLoader` is ever extended twice (or loaded
  inside a ghost viewport), no side effects fire from `_init`.

### 10. `_editMetaData()` forcibly overwrites `_metadata.id` to "12345" on every load

RESEARCH.md treats `_metadata.id` as a stable unique identifier per mod.
**It is not.** `ModLoader._editMetaData()` rewrites every loaded mod's
`_metadata.id` to the literal string `"12345"` and saves the modified
metadata back to disk on every load. The id field is therefore
non-stable across launches and non-unique across mods. The
`_AIOpponents/_metadata` row in Finding 6 above showing `"id": "12345"`
is not coincidence — every mod ends up with that id.

**Implication for the bridge:** use `_metadata.name` (not `id`) for any
unique-identification logic (e.g., refusing to attach twice, checking for
co-installed mods like `_AIOpponents`). The name field is author-set and
preserved.

### 11. YomiBot frame-data corrections to RESEARCH §C

Spot-checks against the actual state files turned up two RESEARCH §C
errors worth correcting now so we don't bake them into the bridge's
character-knowledge layer:

- **Dive Kick** (Robot, aerial): **12 frames startup** (6f with
  initiative active), **3 aim angles** selectable via XYPlot, **air-only**,
  **600 damage on landing**. RESEARCH §C undercounted aim angles and
  miscategorized as ground-air-both.
- **Cowboy Hustle**: **"+1 meter on completion (interruptible)"** — the
  meter gain is conditional on the state completing, and the state is
  interrupt-frame-eligible mid-animation. RESEARCH §C had this as a flat
  meter gain.

These are illustrative — a full §C frame-data pass against
`characters/{ninja,cowboy,wizard,robo,mutant}/states/*` is the open work
item from RESEARCH §C row 3 below.

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
| 5 | Exact `queued_data` schema per move — verify by round-tripping a handful from the editor once the mod is built. |
| 7 | macOS `.dylib` intent — forgotten? Steam-only distribution? LFS pointer instead of real binary? Verify locally after cloning. |
| 8 | Mutant sprite asset paths — does `Mutant.tscn` reference `characters/alien/sprites/`, or are they all moved under `characters/mutant/`? Grep the `.tscn` for `ExtResource` paths. |
| 9 | Behavior of `queued_extra.prediction` when `!= -1` (reference AI hard-codes `-1`, but the field is read by the sim — what does a real value mean?) |
| 10 | Behavior of `queued_extra.reverse` when `true` (also hard-coded `false` in reference AI; sim behavior under `true` not characterized). |

## Decisions adopted from audit

The audit raised open design questions; the decisions reached (recorded
here as a single source of truth) are:

- **v1 = state-only Claude.** Claude is the move generator. The heuristic
  reference scorer runs only as the **Tier 2 fallback** when Claude's
  response fails validation against the pre-computed legal set. Tier 3
  fallback is the no-op `{action: 'Continue', data: null, extra: {DI:
  away, feint: false, prediction: -1, reverse: false}}`. All three tiers
  log a tier label.
- **v2 = state + ghost scores for Claude's own K candidates only.**
  Claude does not score the heuristic's candidate space wholesale; it
  proposes K=3-5 moves, ghost-evaluates each one, and uses the
  per-candidate ghost output as additional input on its final pick.
- **v0 category-picker baseline ships alongside v1 as an A/B target.**
  Claude returns `{category: <ActionType enum value>, reasoning}`,
  GDScript filters visible buttons to that category, and runs the
  reference `get_best_move` on the filtered set. Gated behind a mode
  option.
- **Multihustle is scope-locked OUT for v1.** If `main.has_method(
  "MultiHustle_AddData")` is true, the ClaudeController refuses to attach.
- **DI selection is gated by hitstun state.** If `state.type == Hurt`,
  Claude picks the DI vector. Otherwise the bridge defaults DI to "away"
  and does not include it in the Claude prompt.
- **Coexistence with `_AIOpponents`** is handled by setting
  `_metadata.priority > -10000` (so we load *after* AxNoodle's AI) and
  calling `queue_free()` on the `AIController` child *after* the
  `._ready()` chain has run on our extension. This sidesteps the
  silently-non-deterministic "both connect to player_actionable, last
  wins" coexistence bug raised in audit finding 2.

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
