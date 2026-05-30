# Making Claude Play *Your Only Move Is HUSTLE*

Research notes on how to wire Claude (the LLM) up as a player in *Your Only Move
Is HUSTLE* (YOMI Hustle / YOMIH).

> **v2 update.** Verified specifics from a second-pass deep-research dive are
> folded in: the engine version, the native physics library, the concrete
> Match-controller hook, the fighter state schema, the StreamPeerTCP bridge
> pattern, the Delta-V mod loader workflow, and prior-art mods to crib from.
> Items still labeled **(inferred)** mean we have a strong pattern guess but no
> source-level confirmation yet.

## TL;DR — is this feasible?

**Yes, and we now have the concrete hook points.** YOMIH is a turn-based
fighting game built on **a customized Godot 3.5** with a native fixed-point
physics library (`tbfg.dll` / `tbfg.so`) and a Delta-V–based mod loader that
supports runtime script extension (`installScriptExtension`). The game pauses
at every actionable frame for simultaneous double-blind move selection, so
there is no reflex/latency pressure on the agent. Each turn's decision is a
small discrete choice (move + DI/aim vectors), perfect for a structured Claude
call. The clean path is: a mod extends `Match.gd`, hooks the input phase,
serializes state to JSON, blocks on a local TCP socket, and the bridge server
calls Claude.

Community mods that already drive a player slot programmatically — "AI Opponent
| Goon", "General AI", "YOMI Random" — confirm the controller-override pattern
works. "The Hacker" mod (live GDScript injection at runtime) proves direct
mutation of the `p1`/`p2`/`objects` globals during a match is fine.

## Why the game is a good fit for an LLM agent

- **Turn-based with simultaneous lock-in.** At each actionable frame the engine
  pauses, both players pick a move and "Lock In", then the deterministic sim
  runs until the next actionable frame.
- **Deterministic, fixed-point physics.** Same inputs → same outcome across
  platforms. This is what powers the in-game after-image prediction and what
  makes external lookahead possible.
- **Decisions are strategic, not mechanical.** The skill is *which* move, not
  execution speed — exactly the kind of choice an LLM can reason about.
- **No per-turn time limit (offline).** API round-trips of a few seconds are
  fine. (Online netplay is a different story — see Risks.)

## The decision interface, in concrete terms

Per turn, the agent must produce:

- **`action_id`** — one entry from the fighter's currently *legal* moves, which
  are enumerated from the fighter's state-machine children at decision time
  (availability depends on grounded/airborne, hitstun, meter, air_options,
  free_cancels, etc.).
- **`di_vector`** — a `Vector2` for directional influence while being hit /
  movement direction.
- **`aim_vector`** — a `Vector2` for aimed moves (projectiles, dashes).
- Optional resource/extra data for mod-specific mechanics.

Concretely:

```json
{
  "action_id": "HorizontalSlash",
  "modifiers": {
    "di_vector":  {"x": 0.707, "y": -0.707},
    "aim_vector": {"x": 120.4, "y": -34.8},
    "extra_data": {}
  }
}
```

The exact shape of the input payload to the controller is **(inferred)** —
function name / dict keys come from standard Godot-3.x controller patterns and
will be locked once we inspect the decompiled `FighterController.gd`.

## Approaches considered

### A. GDScript mod + local TCP bridge  ← recommended
Decompile the game with GDRE Tools, open in Godot 3.5, write a mod that uses
`installScriptExtension` to hook `Match.gd`'s input phase. At each decision
point the mod serializes state to JSON, opens a length-prefixed `StreamPeerTCP`
to `localhost`, blocks until the bridge returns a chosen action, and applies it
via the fighter's controller. The bridge (Python/Node) builds the prompt and
calls Claude. **Verified path.**

### B. Vision + OS input injection (external bot)
Screen-capture frames, OCR the HUD/move menu, drive mouse/keyboard. **Pros:**
no decompilation. **Cons:** brittle, no exact frame data, no clean access to
the legal-moves list. Only worth it if modding is off the table — it isn't.

### C. Train an RL agent (separate project)
Wrap the deterministic sim as a gym env and train a policy. Not "Claude," but
the same mod-level state hooks are the foundation. Out of scope here.

## Recommended architecture (Approach A) — verified specifics

```
┌────────────────────────────────────────┐   length-prefixed JSON over TCP   ┌──────────────────────┐
│  YOMI Hustle (Godot 3.5, modded)        │  ── game state ──────────────▶ │  Bridge server       │
│                                        │                                  │  (Python / Node)     │
│  Mod (Delta-V loader)                  │ ◀── chosen action ───────────── │  - builds prompt     │
│   - installScriptExtension Match.gd    │                                  │  - calls Claude API  │
│   - serializes p1 / p2 / objects        │                                  │  - validates output  │
│   - StreamPeerTCP blocking I/O          │                                  └──────────┬───────────┘
└────────────────────────────────────────┘                                              │ Anthropic API
                                                                                        ▼
                                                                                 Claude (Opus/Sonnet)
```

### Files & globals to know

- `res://Match.gd` (a.k.a. `CurrentGame.gd`) — high-level match coordinator;
  manages frame resolution and the input phase. **Our hook target.**
- `res://Fighter.gd` — node for a physical fighter on the stage. Globals
  `p1` / `p2` reference the two fighters; `objects` references active
  projectiles.
- `res://FighterController.gd` (or `PlayerController.gd`) — abstracts how
  selections map to a fighter; this is what existing AI-opponent mods replace
  per slot.

### Hook (Delta-V script extension)

```gdscript
# res://ExternalBridgeMod/ModMain.gd
extends Node
func _init(modLoader = ModLoader):
    modLoader.installScriptExtension("res://ExternalBridgeMod/extensions/Match.gd")
```

```gdscript
# res://ExternalBridgeMod/extensions/Match.gd
extends "res://Match.gd"

func start_input_phase():
    .start_input_phase()  # let UI + physics update normally
    if is_instance_valid(p2) and p2.controller is ExternalController:
        var state_json = StateSerializer.get_serialized_state(p1, p2, objects)
        var action     = TCPBridge.query_external_agent(state_json)
        p2.controller.submit_action(action.action_id, action.modifiers)
```

Function names `start_input_phase` and `submit_action` are **(inferred)** —
we'll confirm against the decompiled source. The extension *pattern* and the
`installScriptExtension` API are verified Delta-V loader behavior.

### Fighter state schema (verified field names)

| Field                | Access                                  | Notes                                |
|----------------------|------------------------------------------|--------------------------------------|
| Position             | `fighter.get_pos()` → `Vector2`          | absolute stage coords                |
| Velocity             | `fighter.vel`                            |                                      |
| Health               | `fighter.hp`                             | typically out of 10000               |
| Current state        | `fighter.current_state.name`             | active animation / state name        |
| Hitstun              | `fighter.hitstun`                        | frames until actionable              |
| Grounded             | `fighter.is_grounded()`                  | bool                                 |
| Facing               | `fighter.facing`                         | `1` right, `-1` left                 |
| Super meter          | `fighter.super_meter`                    | pips                                 |
| Air options          | `fighter.air_options`                    | jumps + air-dashes left              |
| Free cancels         | `fighter.free_cancels`                   | cancel-into-safe budget              |
| Burst meter          | `fighter.burst_meter`                    | defensive burst                      |
| Legal moves          | iterate `fighter.states.get_children()`  | filter by usability (**inferred**)   |

Projectiles come from the global `objects` array; iterate and emit each one's
id + position (and ideally velocity / owner / hitbox if exposed).

### State serializer

```gdscript
# res://ExternalBridgeMod/StateSerializer.gd
extends Node
static func get_serialized_state(p1, p2, objects) -> String:
    var state = {
        "p1": _fighter(p1),
        "p2": _fighter(p2),
        "projectiles": []
    }
    for obj in objects:
        if is_instance_valid(obj):
            state.projectiles.append({"id": obj.name,
                                      "pos": [obj.get_pos().x, obj.get_pos().y]})
    return JSON.print(state)

static func _fighter(f) -> Dictionary:
    var legal := []
    for st in f.states.get_children():           # (inferred loop shape)
        if st.is_usable_in_current_state(f):
            legal.append({"action_id": st.name,
                          "has_aim":  st.has_method("get_aim_vector"),
                          "has_di":   st.has_method("get_di_vector")})
    return {
        "hp":           f.hp,
        "pos":         [f.get_pos().x, f.get_pos().y],
        "vel":         [f.vel.x, f.vel.y],
        "state_name":   f.current_state.name if f.current_state else "None",
        "hitstun":      f.hitstun,
        "is_grounded":  f.is_grounded(),
        "facing":       f.facing,
        "air_options":  f.air_options,
        "free_cancels": f.free_cancels,
        "super_meter":  f.super_meter,
        "legal_moves":  legal
    }
```

### TCP bridge (length-prefixed, blocking with cooperative yield)

`HTTPRequest` is async in Godot 3.5; forcing it synchronous via `yield` risks
desyncs and timeouts. The clean pattern is a length-prefixed `StreamPeerTCP`
loop that blocks the main thread with short `OS.delay_msec()` sleeps so the
window manager doesn't mark the app "not responding".

```gdscript
# res://ExternalBridgeMod/TCPBridge.gd
extends Node
const HOST = "127.0.0.1"
const PORT = 42421
var peer := StreamPeerTCP.new()

func query_external_agent(payload: String) -> Dictionary:
    if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
        if peer.connect_to_host(HOST, PORT) != OK:
            return {"action_id": "Wait", "modifiers": {}}

    var bytes := payload.to_utf8()
    peer.put_32(bytes.size())
    peer.put_data(bytes)

    while peer.get_available_bytes() < 4:
        OS.delay_msec(5)
    var resp_size := peer.get_32()

    while peer.get_available_bytes() < resp_size:
        OS.delay_msec(5)
    var ok_and_packet = peer.get_data(resp_size)
    if ok_and_packet[0] != OK:
        return {"action_id": "Wait", "modifiers": {}}

    var parsed = JSON.parse(ok_and_packet[1].get_string_from_utf8())
    if parsed.error != OK:
        return {"action_id": "Wait", "modifiers": {}}
    return parsed.result
```

### Optional: lookahead via deterministic sim
Because physics is deterministic and fixed-point, snapshot → inject hypothetical
moves → step N frames → score → restore is the right shape. The exact entry
points on the native `tbfg` library (save_state / step / restore) are
**unverified** — they live in the compiled DLL/SO and need binary RE or a
GDScript wrapper hint from existing AI mods. AxNoodle's AI work is reported to
use this pattern; we should read whatever they ship.

Note: GDScript is single-threaded in 3.5 — large lookahead sweeps will hitch
the client. Keep depth shallow or push search to the bridge process.

## Mod packaging (Delta-V loader)

Zip layout — no files at the root, everything in a mod-named folder:

```
ExternalBridgeMod.zip
└── ExternalBridgeMod/
    ├── ModMain.gd
    ├── _metadata
    └── extensions/
        └── Match.gd
```

`_metadata` (no extension) fields: `name`, `friendly_name`, `description`,
`author`, `version`, `id`, `requires`, `overwrites`, `client_side`, `priority`.
Two init phases: `_init` (register `installScriptExtension` here, before
autoloads), `_ready` (autoloads/singletons available).

## Toolchain & gotchas

The setup pipeline is finicky in one specific way — the native fixed-point
physics library must be copied into the recovered project or it crashes on
match start.

1. Find `YourOnlyMoveIsHUSTLE.pck` in the Steam install (AppID 2212330).
2. Decompile with **GDRE Tools** (v0.4+).
3. Open the recovered project in **Godot 3.5 stable** (the customized engine
   build YOMIH ships with — not Godot 4.x, which corrupts the project).
4. Create `lib/` in the project root.
5. Copy `tbfg.dll` (Windows) or `tbfg.so` (Linux) from the Steam folder into
   `lib/`. Without this the GDNative import fails and matches crash on start.
6. Optionally install **YH Mod Assistant** for templates + auto-export.

## Designing the Claude agent

- **System prompt (cached):** YOMIH rules, the meaning of each state field,
  frame-data basics (startup/active/recovery, hitstun, DI), the win condition.
- **Per-turn user message:** the JSON state + the *current* `legal_moves`.
- **Structured output:** `{action_id, di_vector, aim_vector, reasoning}`;
  server-side validate `action_id ∈ legal_moves` and reject/retry otherwise.
- **Memory:** last N turns (both players' moves + deltas) — the game is
  explicitly about reading opponent habits.
- **Model:** Opus for strongest play; Sonnet/Haiku for cheaper/faster matches.
  Heavy prompt caching on the rules system prompt.

### Frame-data quick reference

- **Advantage** = `defender_hitstun − attacker_recovery` (positive = attacker
  acts first → punish window).
- **DI**: `V_final = V_knockback + D_DI * γ`, where `γ` scales with combo
  length and `D_DI` is the player's normalized 2D input.

## Implementation roadmap

1. **Decompile + run from source.** Verify Godot 3.5, `tbfg` lib copied, vanilla
   match launches cleanly from the editor.
2. **State-dump spike.** Hook `Match.gd`'s input phase; log the JSON state to
   console each turn. Confirm field names match reality, lock down inferred
   ones.
3. **Random/echo bridge.** Stand up a local Python TCP server that returns a
   random legal action. Run a full match.
4. **Claude in the loop.** Replace random with a Claude call (structured output
   + server-side legality check). Play a match end-to-end.
5. **Memory + reasoning.** Add rolling turn history and the cached rules system
   prompt; measure win-rate vs. built-in/heuristic AI.
6. **Lookahead (optional).** Either via the native sim (if the `tbfg` API can
   be reached) or a lightweight bridge-side heuristic search.
7. **Polish.** Slot/character config, model selection, logging of
   state/decision/outcome for eval.

## Risks & remaining unknowns

- **Online netplay desync (unverified).** Blocking the main thread on a local
  socket is fine for local/practice matches; the rollback engine for online may
  not tolerate it. Keep Claude play to local matches until tested.
- **Game updates churn.** `YourOnlyMoveIsHUSTLE.pck` and `tbfg` change with
  patches; class layouts/fields can shift. Pin to a build during development;
  expect maintenance.
- **Native `tbfg` library exports (unverified).** Programmatic
  save/load/step-state functions for lookahead aren't documented; need binary
  RE or borrowed code from AxNoodle's AI mods.
- **Controller `submit_action` shape (inferred).** Exact function name and
  modifier dict keys come from standard Godot patterns; confirm against
  decompiled `FighterController.gd`.
- **Legal-moves enumeration (inferred).** The `states.get_children()` + usability
  filter is a pattern guess; the actual API is in `Fighter.gd`.
- **Stage / projectile / hazard queries (inferred).** Walls, projectile
  hitboxes, Mutant's bubbles etc. live in `Stage.gd` and per-projectile scripts;
  unverified.
- **GDScript single-thread.** Big lookahead sweeps in the mod will hitch the
  game. Push search to the bridge.
- **Legitimacy.** Local/practice/research only — not for ranked online.

## Prior art to study / reuse

- **AI Opponent | Goon, "General AI"** (AxNoodle, Steam Workshop) — the
  controller-override template; closest match for our hook.
- **YOMI Random** (Steam Workshop) — shows querying the legal-actions list and
  programmatically calling the lock-in handler from the move-selection UI.
- **The Hacker** (Steam Workshop) — live GDScript injection at runtime with
  clean `p1` / `p2` / `objects` access; perfect for spike experiments before
  packaging a real mod.
- **Replay+ / YOMIRecord** (Snazzah) — hook the frame-processing loop and
  serialize timeline actions; useful for state-capture patterns.
- **MultiHustle** (uGuardian) — parses simultaneous inputs and drives multiple
  players programmatically.
- **YH Mod Assistant** + **Godot Mod Loader** + the Steam **YomiHustle Modding
  Tutorial Series** — standard toolchain/workflow.

## Sources

- [YH Mod Assistant (GitHub)](https://github.com/Valkarin1029/YHModAssistant)
- [YH Mod Assistant (Godot Asset Library)](https://godotengine.org/asset-library/asset/1908)
- [YOMI Hustle Mod Wiki](https://tiggerbiggo.github.io/YomiHustleModWiki/)
- [Modding scene overview](https://shapes.inc/fandom/your-only-move-is-hustle/modding-scene)
- [AI Mod — Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3112147708)
- [AI Opponent | Goon — Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3293858890)
- [Is there a way to fight AI bots? (Steam Discussion)](https://steamcommunity.com/app/2212330/discussions/0/3758852882973503536/)
- [Decompiling with Godot RE Tools (Godot Mod Loader Wiki)](https://wiki.godotmodding.com/guides/modding/tools/decompile_games/)
- [YomiHustle Modding Tutorial Series (Steam Guide)](https://steamcommunity.com/sharedfiles/filedetails/?id=2940757626)
- [Godot Modding (GitHub org)](https://github.com/GodotModding)
- [Godot RE Tools](https://github.com/kimstars/godotRE)
- [How to play — itch.io thread](https://itch.io/t/2471192/how-to-play)
- [Turn-based deconstruction of the fighting game (PC Gamer)](https://www.pcgamer.com/this-turn-based-deconstruction-of-the-fighting-game-is-blowing-minds/)
- [Your Only Move Is HUSTLE on Steam](https://store.steampowered.com/app/2212330/Your_Only_Move_Is_HUSTLE/)
