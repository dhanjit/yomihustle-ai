# Making Claude Play *Your Only Move Is HUSTLE*

Research notes on how to wire Claude (the LLM) up as a player in *Your Only Move
Is HUSTLE* (YOMI Hustle / YOMIH).

## TL;DR — is this feasible?

**Yes, and the game is unusually well-suited to it.** YOMI Hustle is a
*turn-based* fighting game built in **Godot 3.x / GDScript** with a mature
modding ecosystem. Unlike a real-time fighter, the game **pauses at every
decision point**, so there is no reflex or latency pressure — an LLM has
effectively unlimited time to "think" between moves. The decision an agent
makes each turn is small and discrete (pick one move from a menu + a
directional input), which maps cleanly onto a structured LLM call.

The recommended path is a **GDScript mod that hooks the move-selection step,
serializes the game state to JSON, sends it to a small local HTTP bridge, and
the bridge calls the Claude API and returns the chosen move.** Community
"AI opponent" mods already prove that a player slot can be driven
programmatically — we are replacing their hand-written heuristic with Claude.

## Why the game is a good fit for an LLM agent

- **Turn-based with simultaneous execution.** The game pauses whenever either
  player can begin a new move (or after ~10 frames). Both players secretly
  select a move and "Lock In"; the engine then simulates deterministically
  until someone can act again.
- **Deterministic simulation.** Same inputs → same outcome. This makes a
  built-in **prediction/after-image system** possible (the game shows you how
  the next turn plays out given chosen moves). That same determinism lets an
  agent do lookahead/simulation if we expose it.
- **Decisions are strategic, not mechanical.** "Everything is frame-perfect as
  you planned it" — the skill is *which* move, not execution speed. That is
  exactly the kind of choice an LLM can reason about.
- **No time limit per decision.** We can spend an API round-trip (seconds) per
  turn without affecting gameplay.

## What "a move" actually is (the decision interface)

Each turn the agent must produce roughly:

- **A move/action** chosen from the character's currently *available* moves
  (the buttons shown in the move menu — e.g. jab, dash, special, jump, block,
  parry, item). Availability depends on the current state (grounded/airborne,
  hitstun, resources/meter, cooldowns).
- **A directional input** — movement direction and/or **DI** (directional
  influence) applied while being hit, plus aim direction for projectile/aimed
  moves.
- Occasionally **resource decisions** (meter spend, mod-specific mechanics).

So the agent's output per turn is small and enumerable, which is ideal for a
constrained, schema-validated LLM response.

## Approaches considered

### A. GDScript mod + local API bridge  ← recommended
Decompile the game, add a mod that overrides the controller for one player
slot. At each decision point the mod reads structured game state, POSTs it to
`localhost`, and a small Python/Node bridge calls the Claude API and returns
the chosen action. **Pros:** full, exact, structured state; no vision noise;
deterministic; unlimited think time; can also expose the engine's own
prediction for lookahead. **Cons:** requires decompiling + working in the
correct Godot version; mod must keep up with game updates.

### B. Vision + OS input injection (external bot)
Screen-capture the game, feed frames to Claude's vision, and inject
mouse/keyboard. **Pros:** no decompilation; engine-agnostic. **Cons:** brittle
OCR/vision of HUD and move menus, fragile coordinate clicking, no exact frame
data, and it throws away the clean structured interface the mod approach gives
for free. Only worth it if modding is off the table.

### C. Train an RL agent (not "Claude", but related)
Wrap the deterministic sim as a gym-style environment and train a policy. This
is a different project (no LLM, long training), but the same mod-level state
hooks built for A are the foundation for it. Out of scope for "make *Claude*
play," but worth noting the state-extraction work is shared.

## Recommended architecture (Approach A) in detail

```
┌─────────────────────────────┐        HTTP (localhost)        ┌──────────────────────┐
│  YOMI Hustle (Godot, modded) │  ── game state (JSON) ───────▶ │  Bridge server       │
│                             │                                │  (Python / Node)     │
│  ClaudeController (GDScript)│ ◀── chosen action (JSON) ────  │  - builds prompt     │
│   - hooks P2 move-selection │                                │  - calls Claude API  │
│   - serializes state        │                                │  - validates output  │
│   - applies returned action │                                └──────────┬───────────┘
└─────────────────────────────┘                                           │ Anthropic API
                                                                          ▼
                                                                   Claude (Opus/Sonnet)
```

**1. Get a moddable build.** Decompile the shipped `.pck` with **GDRE Tools**
(Godot RE Tools) → "Recover Project", open in the *exact* Godot version GDRE
reports (3.x). Optionally install **YHMod Assistant** (Godot plugin: templates +
auto-export on debug run) and use the **Godot Mod Loader** (the game uses a
Delta-V–based loader) so the mod loads as a Steam Workshop-style add-on rather
than a hard fork.

**2. Hook a player slot.** Replace/extend the controller for one player with a
`ClaudeController`. Reference existing "AI Opponent" workshop mods for exactly
where the move-selection hook lives — they already select a move and apply DI
for P2; we swap their heuristic for a call to the bridge.

**3. Serialize state to JSON.** At each pause, emit something like:

```json
{
  "frame": 1420,
  "stage": { "width": 1920, "left_wall": -960, "right_wall": 960 },
  "self":     { "char": "Wizard", "pos": [120, 0], "vel": [0, 0],
                "hp": 540, "state": "idle", "grounded": true, "meter": 2,
                "available_moves": ["jab","dash","fireball","jump","block","parry"] },
  "opponent": { "char": "Samurai", "pos": [430, 0], "vel": [-30, 0],
                "hp": 610, "state": "dash_attack_startup", "frames_until_active": 3,
                "grounded": true, "distance": 310 },
  "last_turn": { "self_move": "block", "opp_move": "dash_attack" }
}
```

**4. Bridge calls Claude.** The bridge sends the state + the game rules + the
*current* `available_moves` and asks Claude to return a single JSON action. Use
**tool use / structured output** so Claude must return a valid choice; reject &
retry if the move isn't in `available_moves`.

```json
{ "move": "parry", "direction": "toward_opponent", "aim": null,
  "reasoning": "they committed to dash_attack, 3f until active — parry beats it" }
```

**5. Apply the action.** The GDScript controller maps the returned `move` to the
in-engine button/state and locks in. Done — loop to next turn.

### Optional: give Claude lookahead
Because the sim is deterministic, the mod can expose the engine's existing
**prediction** ("if I do X and they do Y, here's the resulting state"). Letting
Claude request a few hypotheticals before committing turns it from a reactive
picker into a shallow game-tree reasoner — a big strength boost for little cost.

## Designing the Claude agent

- **System prompt:** explain YOMI Hustle rules, the meaning of each state field,
  frame-data basics (startup/active/recovery, hitstun, DI, neutral/okizeme),
  and the win condition. Keep it stable to maximize prompt caching.
- **Per-turn user message:** the JSON state + the enumerated legal moves.
- **Structured output:** require `{move, direction, aim, reasoning}`; validate
  `move ∈ available_moves` server-side.
- **Memory:** include the last N turns (what each side did + outcomes) so Claude
  can "read" the opponent — the game is explicitly about reading habits.
- **Model choice:** Opus for strongest play; Sonnet/Haiku if you want faster,
  cheaper turns. Cache the rules system prompt across turns.

## Implementation roadmap

1. **Spike (state dump).** Decompile, get the game running from source in Godot,
   and log the move-selection hook + a JSON state dump to console each turn.
2. **Random/echo bridge.** Stand up the local HTTP bridge returning a *random
   legal move*; confirm the full loop (state out → action in → applied) works
   end-to-end against the in-game CPU or a human.
3. **Claude in the loop.** Swap random for a Claude API call with structured
   output + validation/retry. Play a full match.
4. **Memory + reasoning.** Add rolling turn history and the rules system prompt;
   measure win-rate vs. the built-in/heuristic AI.
5. **Lookahead (optional).** Expose deterministic prediction so Claude can probe
   hypotheticals before locking in.
6. **Polish.** Config for which slot Claude controls, model selection, logging
   of state/decision/outcome for debugging and eval.

## Challenges & risks

- **Decompilation + Godot version match** is the main setup hurdle; use the
  version GDRE reports exactly.
- **Game updates** can shift internal class/field names — the mod's state hook
  may need maintenance. Pin to a game build during development.
- **Action-space correctness:** the menu of legal moves is state-dependent;
  always drive Claude's choices from the engine's *actual* `available_moves`,
  never a hardcoded list, and validate before applying.
- **Cost/latency:** one API call per decision point; a match has many turns.
  Caching the rules prompt and using a cheaper model for trivial states helps.
- **Determinism for online play:** if used against the netcode, an external
  bridge introduces a non-deterministic actor — keep Claude play to
  local/practice matches to avoid desyncs.
- **Legitimacy:** this is for local/practice/research, not for cheating in
  ranked online lobbies.

## Prior art to study before building

- **Community "AI Opponent" / "Goon" mods** (Steam Workshop) — show exactly how
  a player slot is driven programmatically; the cleanest template for our hook.
- **A "learning AI" mod** (~late 2025) that adapts to your habits — useful for
  ideas on opponent-modeling and what state is worth tracking.
- **YHMod Assistant** + **Godot Mod Loader** + the Steam **YomiHustle Modding
  Tutorial Series** — the standard toolchain/workflow for building and loading
  the mod.

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
