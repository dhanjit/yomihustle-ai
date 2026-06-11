# DESIGN — Claude plays *Your Only Move Is HUSTLE*

Companion to `RESEARCH.md` (architecture-level survey of the game) and
`VALIDATION.md` (audit of those claims against `uzkbwza/hustle@4450348` and
`TheanMcGarity/MultiHustleGame@9d0ff28`). This file is the engineering plan
for the v0 / v1 / v2 ship trajectory. Every load-bearing claim about game
internals is grounded in the upstream source files; identifiers come from
the real scripts (`game.gd`, `_AIOpponents/AIController.gd`,
`modloader/ModLoader.gd`, `ReplayManager.gd`).

---

## 1. Goal & scope

Make Claude play YOMIH against a human, in 1v1 local singleplayer, well
enough that a competent human player feels challenged. Three increasingly
ambitious shipping stages, all behind one mod-option toggle.

**Side constraint.** v1 Claude controls whichever player slot is
non-human (derived from `game.match_data` / `players[*].is_human` at
`_ready` time — see §5.4). In a typical human-vs-Claude match, the human
picks side at character select and Claude takes the other. In
Claude-vs-Claude self-play, only `id=2` is driven by Claude; `id=1`
falls through to Tier 2 heuristic. Multiplayer is excluded by the
`Network.multiplayer_active` guard.

- **v0 — category-picker baseline.** Claude returns a coarse category
  (`Movement / Attack / Special / Super / Defense`) plus a one-sentence
  rationale. GDScript filters the visible action buttons to that category
  and calls the heuristic `get_best_move()` from `_AIOpponents/AIController.gd`
  on the filtered set. v0 exists as an A/B baseline: it isolates whether
  Claude's strategic categorization (cheap, single round-trip) beats pure
  heuristic move selection (no LLM at all), and it's the safety floor if
  v1 regresses.
- **v1 — state-only hybrid (primary target).** Claude sees the full state
  + the heuristic's predicted-opponent move + the pre-computed legal-move
  set with enumerated data permutations. Claude returns a ranked top-3
  with `(action_name, data_index)`. GDScript validates against the legal
  set, then submits the top valid pick. The heuristic runs only as Tier-2
  fallback if Claude returns all-invalid or times out. NO ghost lookahead
  on Claude's picks in v1 — we trust the model's prior over 35-frame
  simulation budget.
- **v2 — post-35-frame adjudication.** GDScript runs the sticky-ghost
  simulator over Claude's K=3 candidates (one data permutation each, the
  one Claude chose) and ships the post-35-frame `{hp_delta, frame_advantage,
  distance_closed, super_delta}` back to Claude with a second TCP round.
  Claude makes the final pick informed by both prior and simulated
  outcome. **We pick adjudication over re-weighting because** re-weighting
  asks Claude to invent eval coefficients (under-determined: how would it
  know `FRAME_ADVANTAGE_MODIFIER` should be 18 not 20 from a single
  state?), while adjudication asks Claude to read a small table of concrete
  predicted outcomes and choose — a task LLMs are demonstrably better at.

**Out of scope (v1 and v2):**

- Multihustle — refuse to attach if `main.has_method("MultiHustle_AddData")`
  returns true. The reference AI handles MH with extra complexity
  (`mh_ai_count`, `selects[2][0]` UI fiddling, per-opponent targeting
  loops) we do not want to inherit.
- Online play — `_AIOpponents/AIController.gd` self-neuters
  (`if Network.multiplayer_active: id = 0; difficulty = 1`). The
  mechanical basis is in `game.gd`: `player_actionable` is only emitted
  when `singleplayer == true`. Multiplayer takes the
  `elif !is_ghost: someones_turn = true` branch and never fires the
  signal. Stronger than the developer-quote justification.
- Mod-on-mod compatibility beyond `_AIOpponents/` — we explicitly handle
  that one because it is bundled into the same MultiHustleGame fork
  modders run; anything else (`YOMIRecord`, Workshop characters) is
  best-effort.
- macOS — repo's `lib/` has `tbfg.dll` and `tbfg.so` but no `.dylib`. Out
  of scope for v1; flagged in §13.

---

## 2. Architecture overview

```
                          GAME (Godot, GDScript, main thread)
  ┌─────────────────────────────────────────────────────────────────────┐
  │                                                                     │
  │   game.gd::process_tick()                                            │
  │      └─ emits signal player_actionable()  ← only when singleplayer  │
  │            (game.gd: signal player_actionable; declared ~line 25,   │
  │             emitted in process_tick when both characters are        │
  │             interruptable & game.singleplayer == true)              │
  │                                                                     │
  │   ClaudeController._start_decision_thread()    [main thread]         │
  │      ├─ ghost-viewport guard:  if game.is_ghost: queue_free; return  │
  │      ├─ multiplayer re-check (defense-in-depth)                      │
  │      ├─ if v0: build_v0_payload (no legal_moves enum)                │
  │      │   else: enumerate_legal_moves UNION                           │
  │      │     (heuristic top-1 + safety set + Claude prior K=3)         │
  │      │     deduped by (action_name, frozen(data_options))            │
  │      ├─ opponent-modelling pre-step:                                 │
  │      │    predicted_opponent = heuristic_get_best_move(opponent_id)  │
  │      │      (mirrors AIController.make_move(): get_best_move(...))   │
  │      ├─ stamp request_id (monotonic) and state_hash (xor digest)     │
  │      ├─ store ALL context on self.pending (decision struct)          │
  │      └─ spawn Thread → _decide_off_thread(payload)                   │
  │                                                                     │
  │   ┌──── Godot Thread ────────────────────────────────────────────┐   │
  │   │  persistent tcp (per-match, opened at _ready)                │   │
  │   │  reconnect on demand with CONNECT_TIMEOUT_MS=2000             │   │
  │   │  big_endian = true (CRITICAL: Godot default is LE)            │   │
  │   │  framed put_data (length + body in one call)                  │   │
  │   │  poll-loop read with READ_TIMEOUT_MS=8000                     │   │
  │   │  bounds check msg_len ≤ MAX_FRAME_SIZE (1 MB)                 │   │
  │   │  call_deferred("_apply_choice", envelope, request_id)         │   │
  │   └──────────────────────────────────────────────────────────────┘   │
  │                          │                                          │
  │                          ▼  (back on main thread, deferred)          │
  │   ClaudeController._apply_choice(envelope, request_id)               │
  │      ├─ ALWAYS join thread first (no leak)                           │
  │      ├─ stale guards: request_id mismatch / resimulating /           │
  │      │                 state_hash mismatch → drop + maybe_redecide   │
  │      ├─ read decision context from self.pending                      │
  │      ├─ TIER 1: validate envelope.outcome+response.ranked            │
  │      │         walk capped(5), pick first with valid                 │
  │      │         (action_name, data_index). action_tier="LLM_V1"       │
  │      ├─ TIER 2: heuristic top-1. action_tier="HEURISTIC"             │
  │      ├─ TIER 3: minimal-safe Continue. action_tier="SAFE_CONTINUE"   │
  │      ├─ log {action_tier, resolution, degradation_reason}            │
  │      └─ on_action_selected + turns_taken + main._start_ghost         │
  │                                                                     │
  └─────────────────────────────────────────────────────────────────────┘

                          ↕  127.0.0.1:8765, length-prefixed JSON

                     PYTHON BRIDGE (asyncio, single-process)
  ┌─────────────────────────────────────────────────────────────────────┐
  │  bridge.py                                                           │
  │    ├─ accepts one TCP connection per match                           │
  │    ├─ on request:                                                    │
  │    │   v0:  call Claude → category enum → return                      │
  │    │   v1:  call Claude → {action, data_index, ...} → return          │
  │    │   v2:  call Claude (round 1) → K candidates                      │
  │    │        receive round-2 request from GDScript with sim results   │
  │    │        call Claude (round 2) → final → return                   │
  │    ├─ system prompt cached (Anthropic prompt cache: stage 1 char     │
  │    │    info JSON + universal mechanics + Cowboy/Ninja frame data)   │
  │    └─ returns {action, data_index, di_override?, feint, reasoning,   │
  │                latency_ms, model_version}                            │
  └─────────────────────────────────────────────────────────────────────┘
```

**v0 branch:** GDScript skips the legal-move enumeration entirely; sends
only `{tick, mode:"v0", state, predicted_opponent, history, character_info,
visible_categories: [ActionType...]}`; Claude returns
`{category: ActionType, reasoning}`; GDScript filters
`action_buttons.buttons` to that category and runs `get_best_move()` on
the filtered set (same call signature as the reference AI, just a smaller
button list).

**v1 branch:** as drawn above. No ghost-eval on Claude's picks.

**v2 branch:** after `_apply_choice` resolves the Tier-1 pick, we **do**
run a sticky ghost-eval over Claude's K=3 (re-using one
`setup_ghost_game()` per turn instead of per-candidate — see §8), and
make a second TCP call with the K predicted outcomes. The second response
is the final action.

---

## 3. Wire protocol (TCP, length-prefixed JSON)

Connection: `StreamPeerTCP` to `127.0.0.1:8765` (or first free port in
`[8765, 8770]` if the default is taken — see §12.5). Framing: 4-byte
**unsigned** big-endian length prefix (max 1 MB body — see §16), then
JSON body (UTF-8). One frame per request and per response.

**Endianness correctness note.** `StreamPeerTCP`'s `big_endian` member
defaults to `false` in Godot 3.5 (i.e. `put_32` writes LITTLE-endian by
default). We MUST call `tcp.set_big_endian(true)` immediately after
constructing the StreamPeerTCP, before any `put_32` / `get_32` use.
Python side uses `struct.pack(">I", n)` (big-endian unsigned 32).
Without `set_big_endian(true)`, the length-prefix bytes will not match
end-to-end and no frame will ever deserialize. Integration tests MUST
include a hand-sent known 4-byte length and assert the parsed value.

**Connection handshake.** On connect, before the first decision request,
mod and bridge exchange a hello frame and a one-byte ready marker:

```
mod → bridge: {"type":"hello","mod_version":"0.1.0","schema_versions_supported":[1]}
bridge → mod: {"type":"hello_ack","bridge_version":"0.1.0","schema_version_selected":1,"git_sha":"abc123"}
mod → bridge: {"type":"hello_auth","auth_token":"...32-byte hex read from %LOCALAPPDATA%/claude_yomih/token..."}
bridge → mod: <single byte 0x01 = ready>
```

If `schema_version_selected` is not in the mod's supported list, or
the auth token does not match, both sides log `PROTO_INCOMPAT` /
`AUTH_FAIL` and the mod marks `bridge_ready = false` (then runs every
decision through Tier 2). See §16 for auth-token details.

ERRATUM (security audit): `hello_ack` MUST NOT carry `auth_token` — the
ack is sent to a still-unauthenticated peer, and echoing the token there
would let any local process authenticate without reading the protected
token file, defeating §16.1's threat model. The mod sources the token
exclusively from `%LOCALAPPDATA%/claude_yomih/token`. On auth failure
the bridge MAY send one `auth_fail` error envelope before closing; the
mod treats any post-`hello_auth` byte other than `0x01` as failure.

**Outcome envelope (canonical, single scheme).** Python ALWAYS returns
the same outer shape on the wire, success or failure:

```json
{"ok": true,  "outcome": "ranked|category", "response": {...}, "schema_version": 1, "git_sha": "..."}
{"ok": false, "outcome": "error", "error_code": "claude_timeout|api_error|parse_failure|empty_ranked|all_invalid|schema_mismatch|auth_fail", "schema_version": 1}
```

GDScript transport-level failures (connect_failed, no_connect, len_read,
body_read, json_parse, client_timeout, write_failed, bad_length) are
synthesized GDScript-side with the same shape but `error_code` prefixed
`transport_` so log telemetry can tell them apart from upstream errors.
`_apply_choice` always checks `raw.ok and raw.outcome != "error"` before
treating `raw.response` as a Tier-1 candidate.

### 3.1 Request from GDScript to Python

```json
{
  "schema_version": 1,
  "match_id": "a1b2c3d4-e5f6-7890-abcd-ef0123456789",
  "round_number": 1,
  "round_score_self": 0,
  "round_score_opponent": 0,
  "tick": 1473,
  "mode": "v1",
  "state": {
    "self": {
      "id": 2,
      "character_name": "Cowboy",
      "hp": 1180,
      "max_hp": 1500,
      "super_meter": 42,
      "max_super_meter": 125,
      "bursts_available": 1,
      "air_options_left": 2,
      "position_x": 312,
      "position_y": 180,
      "facing": -1,
      "current_state": "Idle",
      "state_interruptable": true,
      "combo_count": 0,
      "combo_damage": 0,
      "combo_proration": 1.0,
      "in_hitstun": false,
      "feints": 1,
      "penalty": 5
    },
    "opponent": {
      "id": 1,
      "character_name": "Ninja",
      "hp": 1340,
      "max_hp": 1500,
      "super_meter": 18,
      "max_super_meter": 125,
      "bursts_available": 1,
      "air_options_left": 2,
      "position_x": 198,
      "position_y": 180,
      "facing": 1,
      "current_state": "HorizontalSlashRecovery",
      "state_interruptable": false,
      "combo_count": 0,
      "combo_damage": 0,
      "combo_proration": 1.0,
      "in_hitstun": false,
      "feints": 1,
      "penalty": 0
    },
    "game": {
      "current_tick": 1473,
      "time_left": 2940,
      "stage_width": 600,
      "super_active": false,
      "distance": 114
    }
  },
  "predicted_opponent": {
    "action_name": "Continue",
    "data": null,
    "eval_score": 42.7,
    "source": "heuristic_get_best_move"
  },
  "legal_moves": [
    {
      "action_name": "HorizontalSlash",
      "title": "Horizontal Slash",
      "action_type": "Attack",
      "earliest_hitbox": 6,
      "is_guard_break": false,
      "data_options": [{}]
    },
    {
      "action_name": "Grab",
      "title": "Grab",
      "action_type": "Special",
      "earliest_hitbox": 4,
      "is_guard_break": true,
      "data_options": [
        {"Dash": true,  "Direction": {"x": 1,  "y": 0}, "Jump": false},
        {"Dash": true,  "Direction": {"x": -1, "y": 0}, "Jump": false},
        {"Dash": false, "Direction": {"x": 1,  "y": 0}, "Jump": false},
        {"Dash": false, "Direction": {"x": -1, "y": 0}, "Jump": false}
      ]
    },
    {
      "action_name": "ParryHigh",
      "title": "Parry",
      "action_type": "Defense",
      "earliest_hitbox": null,
      "is_guard_break": false,
      "data_options": [
        {"Block Height": {"y": 0}, "Melee Parry Timing": {"count": 4}}
      ]
    }
  ],
  "recent_history": [
    {"tick": 1422, "self": "Idle", "opponent": "HorizontalSlash"},
    {"tick": 1440, "self": "Walk", "opponent": "HorizontalSlash"}
  ],
  "character_info": {
    "self_moves_cached_prompt_id": "cowboy@yomih-1.9.27",
    "opponent_moves_cached_prompt_id": "ninja@yomih-1.9.27"
  }
}
```

Notes:

- `state.self` / `state.opponent` field names mirror `BaseChar.gd`
  members one-to-one (`hp`, `bursts_available`, `combo_count`,
  `combo_proration`, `feints`, `penalty`) so the Python side can copy
  these to the prompt with zero rename. `max_hp` is shipped explicitly
  because `BaseChar.gd` `MAX_HEALTH = 1500` is a const but exposing it
  in the wire keeps Claude robust to future per-character HP changes.
- `predicted_opponent` is the result of running
  `get_best_move(temp_extra, target_player.opponent.id, 0.2, ...)`
  exactly as the reference AI does at the top of `make_move()`. This
  is the **opponent-modelling pre-step** that the audit flagged as
  missing — without it, our self-pick scores against a sandbag (and
  ignores that `eval_move`'s second positional argument is the
  *assumed* opponent move that the simulation feeds in).
- `data_options` is **pre-enumerated** by GDScript via
  `_AIOpponents/AIController.gd::get_option_data() → get_data_structure() →
  split_potential_data()`. We re-use those functions (call them through
  the still-loaded `_AIOpponents` instance, or copy them verbatim) so
  Claude never has to guess that `Grab` needs `{Dash, Direction, Jump}`
  while `ParryHigh` needs `{Block Height, Melee Parry Timing}`.
- **`data_index` reference semantics.** The response (§3.2) returns
  `(action_name, data_index)`. `data_index` is the 0-based index into the
  `data_options` array of the `legal_moves` entry whose `action_name`
  matches the response's `action_name`. Example: for
  `action_name="Grab", data_index=2` the resolved data dict is
  `data_options[2] = {"Dash": false, "Direction": {"x": 1, "y": 0}, "Jump": false}`.
  The validator **dedupes** `legal_moves` by
  `(action_name, frozen(data_options))` before serializing, so a UNION
  that produces duplicates collapses to a single entry — `_find_in_legal_moves`
  cannot match an unintended entry.
- `is_guard_break` source: `button.state.guard_break` if the state script
  exposes that field, else `button.state.hit_type == HitType.GuardBreak`
  if a HitType enum is defined, else `false`. The reference AI does not
  expose this concept; we synthesize it character-by-character at
  enumeration time. If detection cannot be unified across all upstream
  characters (`characters/*/states/*.gd`), drop the field for v1 and
  expose only `action_type`.
- `predicted_opponent.eval_score` is the heuristic's internal `eval`
  field; `ProtocolEncoder.build_predicted_opponent` renames `choice.eval
  → eval_score` to keep wire and code distinct.
- `recent_history` is a ring buffer of the last 8 actionable turns. We
  populate it on each successful submit. Helps Claude detect "the human
  keeps mashing Grab" patterns without us building a separate read model.
- `match_id` is a UUID generated by the mod at match start and re-issued
  on every rematch. Python uses it to reset per-match state (history
  ring buffer, prompt caches) when a new value arrives.

### 3.2 Response from Python to GDScript (v1)

Wrapped in the canonical envelope from §3:

```json
{
  "ok": true,
  "outcome": "ranked",
  "schema_version": 1,
  "git_sha": "abc123",
  "response": {
    "tick": 1473,
    "mode": "v1",
    "ranked": [
      {"action_name": "Grab",        "data_index": 0, "reason": "guard-break vs predicted block; closes distance"},
      {"action_name": "ParryHigh",   "data_index": 0, "reason": "if they read the grab"},
      {"action_name": "HorizontalSlash", "data_index": 0, "reason": "default 6f poke"}
    ],
    "di_override": null,
    "feint": false,
    "reasoning_brief": "Opponent in HorizontalSlashRecovery, mid range, has burst — go for fast grab to corner them; parry as plan B.",
    "latency_ms": 947,
    "model_version": "claude-opus-4-8"
  }
}
```

GDScript walks `response.ranked` in order, picking the first whose
`action_name` appears in `legal_moves` and whose `data_index` indexes
into that entry's `data_options`. The chosen `(action_name, data)` pair
gets written to `target_player.queued_action` / `queued_data` via the
same submit path as the reference AI (§6).

**Cardinality and validation contract.** Claude MUST return
`1 ≤ len(ranked) ≤ 5`. GDScript hard-caps validation to the first 5
entries (slice before walking). If `len(ranked) == 0` or `> 50`, treat
as `parse_error` and degrade to Tier 2 with
`degradation_reason=ranked_cardinality`. If `outcome == "error"`,
`response` is absent and `error_code` is set. If
`response.di_override` is non-null, it MUST be one of the canonical
string enums listed in §11 (`neutral|away|toward|up|opponent-corner|up-left|up-right|down-left|down-right`)
— GDScript drops non-string or unknown values silently. If
`response.ranked[i].data_options` (in `legal_moves`) is `[]` the move
has zero valid invocations and is skipped; if `[{}]` it has one valid
"empty dict" invocation. Length cap on the whole frame is 1 MB; longer
frames are rejected (`bad_length`, transport-tier).

**Tier outcome signaling.** `_apply_choice` computes its OWN
`action_tier` ∈ `{LLM_V1, LLM_V0, HEURISTIC, SAFE_CONTINUE}` and a
`resolution` ∈ `{submitted, stale_dropped, error}`. STALE_TICK and
STALE_RESIM (§7.1) are `resolution=stale_dropped`, not tiers. We also
record `degradation_reason` ∈
`{claude_timeout, all_invalid, mode_mismatch, empty_ranked, parse_error,
schema_mismatch, ranked_cardinality, transport_*}` for telemetry. See
§9 for the full taxonomy.

### 3.3 Response from Python to GDScript (v0)

```json
{
  "ok": true,
  "outcome": "category",
  "schema_version": 1,
  "git_sha": "abc123",
  "response": {
    "tick": 1473,
    "mode": "v0",
    "category": "Attack",
    "reasoning_brief": "Mid range, opponent recovering — pressure now",
    "latency_ms": 412,
    "model_version": "claude-sonnet-4-6"
  }
}
```

GDScript filters `action_buttons.buttons` to those whose `button.state.type`
matches `category` (mapping `Attack → CharState.ActionType.Attack` etc.),
then runs the heuristic `get_best_move()` on that subset.

### 3.4 v2 second-round request

Identical to §3.1 plus a `candidates_evaluated` block (ERRATUM: earlier
prose called this block `ghost_eval_results`; the example below was always
`candidates_evaluated`, which is the pinned wire key — the bridge accepts
both for safety):

```json
{
  "schema_version": 1,
  "tick": 1473,
  "mode": "v2_round2",
  "candidates_evaluated": [
    {
      "action_name": "Grab", "data_index": 0,
      "predicted_self_hp_delta": 0, "predicted_opponent_hp_delta": -80,
      "predicted_frame_advantage": 14, "predicted_distance_closed": 60,
      "predicted_self_super_delta": 0
    },
    {"action_name": "ParryHigh", "data_index": 0, "predicted_self_hp_delta": 0,  "predicted_opponent_hp_delta": 0,    "predicted_frame_advantage": 7,  "predicted_distance_closed": -8, "predicted_self_super_delta": 0},
    {"action_name": "HorizontalSlash", "data_index": 0, "predicted_self_hp_delta": -100, "predicted_opponent_hp_delta": 0, "predicted_frame_advantage": -12, "predicted_distance_closed": 30, "predicted_self_super_delta": 0}
  ],
  "predicted_opponent_assumed": {"action_name": "Continue", "data": null}
}
```

Response: identical to §3.2 envelope and `ranked` schema, but Claude
returns a single picked candidate (i.e. `len(ranked) == 1`).

### 3.5 Per-turn `state` field grounding

Every field in `state.self` and `state.opponent` is sourced directly
from `characters/BaseChar.gd` (the fighter base class) or
`game.gd::get_player()`. `current_state` is `target_player.current_state().get_class()`.
`state_interruptable` is the same flag `eval_move` reads after each
`simulate_one_tick()`. `combo_count`, `combo_damage`, `combo_proration`
are existing fields used by `_AIOpponents/AIController.gd` already.
`distance` is the euclidean
`sqrt(pow(opp_x - self_x, 2) + pow(opp_y - self_y, 2))` the reference AI
computes inline. Because Y is essentially fixed in YOMIH, we additionally
ship `distance_x = abs(opp_x - self_x)` and `distance_y = abs(opp_y -
self_y)` so Claude does not need to reverse-engineer the axis split.
Verify against `_AIOpponents/AIController.gd` at integration time — if
the reference uses `abs(x_delta)` rather than euclidean, match the
reference's formula in the `distance` scalar and keep `distance_x/y` as
explicit components.

---

## 4. Coexistence with `_AIOpponents/`

The audit flagged this as a critical break: both mods extend `game.gd`,
both `_ready()` add a controller, both `_start_decision_thread` connect
to `player_actionable`, and `AIController._edit_queue()` overrides
`queued_action` whenever `action_selected` fires. Last-connected wins
non-deterministically (depends on ModLoader load order, depends on
`_metadata.priority`, depends on script-extension chain order).

**Priority semantics (re-derived from source).** Reading
`modloader/ModLoader.gd::_compareScriptPriority`, the comparator returns
`aPrio < bPrio` and is passed to `Array.sort_custom`. Per Godot 3.5
docs, `sort_custom` puts the element for which the compare returns true
**earlier** — i.e. **lower priority installs EARLIER in time**, becoming
an ancestor in the script-extension chain; **higher priority installs
LATER, becoming the chain leaf**. The leaf is what Godot actually calls
`_ready()` on. So we want to be the leaf, which means we want a **HIGH**
priority number. The previous draft incorrectly stated "priority 0
makes us outermost"; the math accidentally worked because no other mod
sits between `_AIOpponents`'s -10000 and 0, but a third-party mod at
priority > 0 would silently displace us.

**Decision: ClaudeLoader runs at priority 100000.** That's a deliberately
large value to keep us the leaf in practice. The chain ends up
`game.gd → AILoader (-10000) → ClaudeLoader (100000)`. Our `_ready()`
runs, we call `._ready()` (parent — propagates the chain, triggers
`AILoader._ready()` → `AIController.tscn.instance()` gets added as a
child of the running `Game`), then we immediately walk `get_children()`
recursively, **explicitly disconnect** any `player_actionable`/`action_selected`
signal connections, and `queue_free()` any node whose script
`resource_path` matches `_AIOpponents/AIController` or `_AIOpponents/AILoader`.

**Residual hazard.** Any third-party mod that ALSO extends `game.gd`
and ships with priority > 100000 will install after us and silently
become the new leaf. To detect this we extend BOTH `game.gd` and
`_AIOpponents/AILoader.gd` explicitly, so even if our `game.gd` leaf
position is displaced, the chain at `AILoader.gd` is anchored to us.
We also run a first-tick trip-wire (deferred `_process`) that checks
whether a competing controller node is present and fires `push_error`
if so.

```gdscript
# src/ClaudeLoader.gd
extends "res://game.gd"

func _ready():
    # Ghost-viewport guard FIRST. Without this, ClaudeController would
    # spawn inside the ghost game during lookahead and recursively call
    # Python. The actual protection lives in ClaudeController._ready
    # (which self-frees if is_ghost), but stopping the chain here keeps
    # the AILoader instantiation chain from running inside ghosts at all.
    if is_ghost:
        # Still need real game.gd._ready to run (hides ghost, sets flags).
        # Skip AILoader by jumping past the chain via the base script.
        ._ready()
        return

    ._ready()  # propagates to AILoader if it's in the extension chain

    # Tear down the reference AI's controller if it self-installed.
    # We pattern-match by resource_path so we don't depend on the mod
    # being enabled at all (cheap, idempotent). Disconnect signals
    # BEFORE queue_free — queue_free does not synchronously disconnect.
    _purge_other_ai_controllers(self)

    add_child(preload("res://claude_yomih/ClaudeController.tscn").instance())

    # First-tick trip-wire: detect leaf-displacement by a higher-priority
    # third-party mod and warn loudly.
    call_deferred("_chain_leaf_check")

func _purge_other_ai_controllers(node):
    for child in node.get_children():
        var s = child.get_script()
        if s and (s.resource_path.find("_AIOpponents/AIController") != -1
                  or s.resource_path.find("_AIOpponents/AILoader") != -1):
            # Explicit signal disconnect — queue_free is deferred and the
            # signal connection lives until actual free. Without this,
            # one extra `player_actionable` emission could race us.
            if is_connected("player_actionable", child, "_start_decision_thread"):
                disconnect("player_actionable", child, "_start_decision_thread")
            child.queue_free()
        _purge_other_ai_controllers(child)

func _chain_leaf_check():
    # We expect get_script() to be ClaudeLoader at runtime. If a future
    # ModLoader change or a higher-priority mod has displaced us, the
    # leaf script will differ.
    var ls = get_script()
    if ls and ls.resource_path.find("claude_yomih/ClaudeLoader") == -1:
        push_error("ClaudeLoader: chain leaf is not us (%s) — priority inversion?" % ls.resource_path)

func _exit_tree():
    # Fail-loud if our extension order assumption ever inverts: AIController
    # should have been freed in _ready; if it's back, log it.
    for child in get_children():
        var s = child.get_script()
        if s and s.resource_path.find("_AIOpponents/AIController") != -1:
            push_error("ClaudeLoader: _AIOpponents controller survived purge — chain inversion?")
```

Rationale for not just disabling `_AIOpponents`:

1. Keeps the reference AI installed and instantiated, which we **need**
   as the heuristic fallback (Tier 2) and as the opponent-modelling
   pre-step. We just don't want its `AIController` driving the
   `target_player`.
2. Re-using `AIController.get_best_move()`, `eval_move()`,
   `get_data_structure()`, `setup_ghost_game()`, `di_as_percentage_int_vec()`
   means hundreds of lines we don't reimplement. We literally
   `var heuristic = preload("res://_AIOpponents/AIController.gd").new()`
   in our controller's `_ready` (after the purge step has removed the
   *auto-installed* one), then call its methods directly.
3. The opt-in is per-game; the heuristic instance is local to our
   controller, so even if a user disables `_AIOpponents` we still have
   the script class available (ModLoader loads the script regardless of
   whether the parent mod's `_init` installed extensions — script
   classes are global once the file is present on disk).
4. The fail-loud `_exit_tree` check makes silent regressions impossible:
   if some future ModLoader change re-runs `AILoader._ready()` *after*
   ours, our purge will fail; the `push_error` line writes to the editor
   console and prints to stderr in release.

If `_AIOpponents` is not installed at all (release build, vanilla
MultiHustle), the purge is a no-op and we use a vendored copy of the
heuristic at `src/heuristic/`. See §10.

---

## 5. Mod lifecycle

We mirror **`_AIOpponents/`'s** pattern, not YOMIRecord's. The audit
clarified that YOMIRecord uses `_init` for *all* child instantiation via
`load()` (no `_ready`), and the "extensions in `_init`, nodes in
`_ready`" rule is a convention, not enforced by ModLoader. Both work.
We pick the `_AIOpponents` pattern because (a) it's the AI-controller
shape we're swapping, (b) it puts our socket-opening side effects
inside `ClaudeController._ready()` — *after* autoloads are wired — where
they belong.

### 5.1 Files

```
src/
├── ModMain.gd               # _init → installScriptExtension
├── ClaudeLoader.gd          # extends "res://game.gd"; purge + spawn controller
├── ClaudeController.gd      # main controller: socket, thread, decision loop
├── ClaudeController.tscn    # scene wrapping the above
├── ModOptions.gd            # mod-options pane entries (mode toggle, port, etc.)
├── ProtocolEncoder.gd       # state → request JSON serializer
├── ProtocolDecoder.gd       # response JSON → choice deserializer + validator
├── HeuristicShim.gd         # thin wrapper around AIController.gd methods
├── LegalMoveEnumerator.gd   # uses AIController.get_option_data() & filters
├── _metadata
└── README.md                # user-facing
```

### 5.2 `ModMain.gd`

```gdscript
extends Node

func _init(modLoader = ModLoader):
    modLoader.installScriptExtension("res://claude_yomih/ClaudeLoader.gd")
    modLoader.installScriptExtension("res://claude_yomih/ModOptions.gd")
```

Single-line `_init` matching the `_AIOpponents/ModMain.gd` shape. **No
side effects in `_init`** beyond the two `installScriptExtension` calls.
The audit pinned this: `installScriptExtension` calls `childScript.new()`
at load time, so any `_init` side effects (sockets, threads, file
handles) persist for the lifetime of the editor session. We push all
side effects into `ClaudeController._ready()`.

### 5.3 `ClaudeLoader.gd`

See §4. Extends `res://game.gd`, runs purge in `_ready`, adds
`ClaudeController.tscn` as a child of the running `Game` instance.

### 5.4 `ClaudeController.gd::_ready`

```gdscript
extends Node2D

# Single source of truth for the mod folder. Used wherever we preload
# resources owned by this mod. If the mod is repackaged to a different
# subfolder, change only this constant.
const MOD_ROOT = "res://claude_yomih"
const DEFAULT_PORT = 8765

var target_player = null
var id = -1
var game = null
var main = null
var heuristic = null         # HeuristicShim (NOT in scene tree — see below)
var tcp = null               # StreamPeerTCP (persistent per-match)
var decision_thread = null   # Thread
var pending = {}             # Per-decision context — set when spawning the
                             # thread, read in _apply_choice. Holds:
                             # {tick, mode, temp_extra, di, predicted_opponent,
                             #  legal_moves, action_buttons, request_id,
                             #  state_hash}. Cleared on resolution.
var pending_tick = -1        # tick_at_request (mirror of pending.tick)
var request_id_counter = 0   # Monotonic per-controller for stale-detection
var bridge_ready = false     # Set by probe thread on hello_ack
var bridge_port = DEFAULT_PORT

func _ready():
    game = get_parent()
    if game.is_ghost:
        # Critical guard. Without this, ClaudeController gets instantiated
        # inside the ghost game during lookahead and would attempt to open
        # sockets / call Python, recursively triggering more lookaheads.
        # The reference AI does the same check at the top of its _ready.
        queue_free()
        return

    main = find_parent("Main")
    if main == null:
        # Headless test or unexpected parent layout. heuristic.attach()
        # needs main; refuse to attach rather than crash later.
        push_warning("ClaudeController: no Main parent found; refusing to attach.")
        queue_free()
        return

    if Network.multiplayer_active:
        # player_actionable shouldn't fire in multiplayer (§1), but bail
        # loudly so we don't leak signal connections during a session that
        # later transitions to multiplayer.
        queue_free()
        return

    if main.has_method("MultiHustle_AddData"):
        push_warning("Claude controller refusing to attach: MultiHustle present (v1 scope).")
        queue_free()
        return

    # Derive controlled-side id. In singleplayer YOMIH the human controls
    # one side and the AI controls the other. We look at game.match_data
    # / players[*].is_human (mirrors how _AIOpponents/AIController.gd
    # reads ModOptions target_player). For v1 we default to id=2 if the
    # human-side check is ambiguous, and document the constraint:
    #     v1 Claude controls whichever side is non-human; if both sides
    #     are non-human (Claude-vs-Claude self-play), Claude controls
    #     id=2 only and id=1 falls through to Tier 2 heuristic.
    id = _derive_controlled_id(game, main)
    if id < 1:
        push_warning("ClaudeController: could not derive controlled id; refusing to attach.")
        queue_free()
        return
    target_player = game.get_player(id)

    # Resolve bridge port. Python may have fallen back to 8766..8770 if
    # 8765 was bound (§12.5); the chosen port is written to
    # %LOCALAPPDATA%/claude_yomih/port. Default to 8765 if file absent.
    bridge_port = _read_port_file_or_default(DEFAULT_PORT)

    # Heuristic shim must NOT enter the scene tree. If it did, its
    # AIController-derived _ready would re-connect player_actionable
    # and we'd be racing ourselves. Composition only; no add_child.
    heuristic = preload(MOD_ROOT + "/HeuristicShim.gd").new()
    heuristic.attach(game, main, id)
    # NB: NO add_child(heuristic). HeuristicShim's contract is "lives
    # outside the tree" — see §10.

    game.connect("player_actionable", self, "_start_decision_thread")

    # Eager bridge probe — opens persistent TCP, exchanges hello + auth,
    # sets bridge_ready. If bridge is offline, we skip TCP per-turn and
    # go directly to Tier 2 heuristic, then re-probe every 30s.
    _spawn_bridge_probe()

func _exit_tree():
    if game and is_instance_valid(game) and game.is_connected(
            "player_actionable", self, "_start_decision_thread"):
        game.disconnect("player_actionable", self, "_start_decision_thread")
    if decision_thread != null and decision_thread.is_active():
        # Surface error in worker's get_data so it returns promptly.
        if tcp != null:
            tcp.disconnect_from_host()
        decision_thread.wait_to_finish()
    if tcp != null:
        tcp.disconnect_from_host()
    if heuristic != null:
        heuristic.free()  # not a tree node; manual free
```

**HeuristicShim placement.** HeuristicShim is a thin composition wrapper
around the vendored `_AIOpponents/AIController.gd`. It MUST NOT enter the
scene tree because `AIController._ready` self-installs as a
`player_actionable` decision driver and re-creates the very last-connected-wins
race §4 was written to prevent. Two concrete options, we use (a):

  (a) **Composition.** HeuristicShim holds an `AIController` instance as a
      member (not a child). It never calls `add_child(ai_instance)`. To
      let methods like `setup_ghost_game()` and `eval_move()` work
      outside the tree, the shim's `attach(game, main, id)` injects
      `game`, `main`, and the GhostViewport reference into the inner AI
      so its tree-relative `find_node` calls are short-circuited. The
      shim owns the sticky ghost (§8) and frees it on `_exit_tree`-
      equivalent (`free()` from the controller's `_exit_tree`).
  (b) Alternative: extend `AIController` and override `_ready` to no-op
      (no `._ready()` call). Inferior because we'd still inherit
      lifecycle expectations the controller never satisfies.

The shim contract: never enters the scene tree, never connects to
`player_actionable`, never sets `id` from `ModOptions`.

### 5.5 `_metadata`

```json
{
  "name": "claude_yomih",
  "friendly_name": "Claude Plays HUSTLE",
  "description": "TCP bridge between game and a local Python server that calls the Claude API.",
  "author": "Dhanjit Das",
  "version": "0.1.0",
  "link": "https://github.com/dhanjit/yomihustle-ai",
  "id": "<overwritten by ModLoader at load — do not rely on>",
  "overwrites": false,
  "priority": 100000,
  "client_side": true,
  "requires": [""]
}
```

- `client_side: true` is **documented hygiene**. The audit's strongest
  source-level claim is that `_metadata` schema verifier doesn't reject
  missing `client_side`. Whether `Network._get_hashes` actually folds
  the mod hash into `Global.VERSION` via `append_hash()` when
  `client_side` is absent is a downstream consequence in upstream code
  we have not directly cited. Since v1 is local-only the practical
  impact is zero either way, but we set it true to avoid surprising
  future maintainers if matchmaking is ever revisited.
- `priority: 100000` — deliberately large so we are the leaf in the
  script-extension chain (`game.gd → AILoader(-10000) → ClaudeLoader(100000)`).
  Lower priority installs EARLIER in time and becomes an ancestor;
  higher priority installs LATER and becomes the leaf whose `_ready()`
  Godot actually calls. See §4 for the priority-semantics derivation.
  Any third-party mod with priority > 100000 that also extends
  `game.gd` will silently displace us; the §4 trip-wire detects this.
- `name: "claude_yomih"` is the stable internal ID. The audit pinned
  that `ModLoader._editMetaData()` forcibly overwrites `_metadata.id`
  to `"12345"` on every load — `id` is unreliable for identifying the
  mod in code; we use `name` everywhere (telemetry tags, option-store
  keys, log paths). After first load, the `_metadata` file on disk
  will have `id == "12345"` rewritten by ModLoader. Do not
  version-control the mutated copy; ship the source from `src/_metadata`
  and let ModLoader rewrite the deployed copy.

---

## 6. Per-turn flow

Pseudocode for one `player_actionable` signal, v1 mode. Every named
function maps to an existing or new GDScript symbol; quoted strings are
verbatim from the source. Variable scope rules:

- **All decision context** built in the actionable handler MUST be
  stored on `self.pending` (a Dictionary) before spawning the worker
  thread. `_apply_choice` runs in a different stack frame (deferred
  callback), so locals from the handler do NOT exist there. Read from
  `self.pending` in `_apply_choice` and null it out on resolution.

```
on signal player_actionable:

    # On the MAIN thread, synchronous, fast.

    if pending_tick != -1:
        # We already have a decision in flight for an earlier signal.
        # The game shouldn't re-fire actionable until a turn resolves,
        # but stomp on stale request as a safety net.
        push_warning("Claude: actionable fired while pending; ignoring stale.")
        return

    # Defense-in-depth: multiplayer can flip mid-session.
    if Network.multiplayer_active:
        return

    pending_tick = game.current_tick

    # Opponent-modelling pre-step. Mirrors AIController.make_move() lines:
    #   choice = get_best_move(temp_extra, target_player.opponent.id, 0.2,
    #                          difficulty>=2, true, false)
    # We use leeway=0.2, allow_leeway=true, randomise_burst=false to match
    # the reference's "predict their move" call exactly.
    var ai_pos = target_player.get_pos()
    var opp_pos = target_player.opponent.get_pos()
    var di = heuristic.di_as_percentage_int_vec(
        Vector2(ai_pos.x - opp_pos.x, ai_pos.y - opp_pos.y).normalized())
    var temp_extra = {"DI": di, "feint": false, "prediction": -1, "reverse": false}

    # Defensive pre-step: if the heuristic itself errors (ghost setup
    # failure, missing opponent), default predicted_opponent to Continue
    # rather than letting the whole turn die.
    var predicted_opponent = {"action_name": "Continue", "data": null, "eval_score": 0.0}
    if target_player.bursts_available > 0 or target_player.opponent.combo_count <= 0:
        var raw_choice = heuristic.get_best_move(
            temp_extra, target_player.opponent.id,
            0.2, true, false, false)
        if raw_choice != null and raw_choice.has("action"):
            predicted_opponent = {
                "action_name": raw_choice.action,
                "data":        raw_choice.data,
                "eval_score":  raw_choice.get("eval", 0.0),
            }
        else:
            log_tier_event("PREDICTED_OPP_FALLBACK_CONTINUE", pending_tick, "")

    var mode = "v1"
    if main.has_node("ModOptions"):
        mode = main.get_node("ModOptions").get_setting("claude_yomih", "mode")

    # Mode branching at payload construction. v0 skips legal-move
    # enumeration entirely (cheaper).
    var action_buttons = main.find_node("P" + str(2 - id%2) + "ActionButtons")
    var legal_moves = []
    var payload = null
    if mode == "v0":
        payload = _build_v0_payload(predicted_opponent, di, action_buttons)
    else:
        # UNION strategy: heuristic top-1 + safety set + Claude's prior K=3
        legal_moves = enumerate_legal_moves(
            action_buttons = action_buttons,
            di = di,
            opponent_action = predicted_opponent.action_name,
            opponent_data = predicted_opponent.data,
            include_heuristic_top1 = true,
            include_safety_set = true,
            include_claude_prior_K = 3)
        # LegalMoveEnumerator dedupes by (action_name, frozen(data_options))
        # before returning, so a UNION that produces duplicates collapses
        # to a single entry. See §3.1 data_index semantics.
        payload = _build_v1_payload(predicted_opponent, di, legal_moves)

    # Stamp a monotonic request_id and a cheap state hash so the apply
    # path can detect "tick number happens to match but state is
    # different" (e.g. undo + redo lands on same tick number with a
    # different state vector).
    request_id_counter += 1
    var state_hash = _hash_state(target_player, target_player.opponent)

    # Promote per-decision context to self.pending so _apply_choice (a
    # deferred callback in a different stack frame) can read it.
    self.pending = {
        "tick": pending_tick,
        "request_id": request_id_counter,
        "state_hash": state_hash,
        "mode": mode,
        "temp_extra": temp_extra,
        "di": di,
        "predicted_opponent": predicted_opponent,
        "legal_moves": legal_moves,
        "action_buttons": action_buttons,
    }

    # If bridge is offline, skip TCP entirely and go straight to Tier 2.
    if not bridge_ready:
        log_tier_event("BRIDGE_OFFLINE_SKIP", pending_tick, "")
        call_deferred("_apply_choice",
            {"ok": false, "outcome": "error", "error_code": "transport_bridge_offline"},
            request_id_counter)
        return

    decision_thread = Thread.new()
    decision_thread.start(self, "_decide_off_thread", payload)


# OFF MAIN THREAD:
func _decide_off_thread(payload):
    # See §7 for full sock implementation with deadlines.
    var raw = ProtocolEncoder.send_and_recv(payload, tcp, bridge_port)
    call_deferred("_apply_choice", raw, self.pending.request_id)


# BACK ON MAIN THREAD:
func _apply_choice(raw, request_id):
    # ALWAYS join the worker thread first, regardless of stale outcome.
    # Otherwise Thread objects leak (is_active stays true until
    # wait_to_finish, even if the function body already returned).
    if decision_thread != null and decision_thread.is_active():
        decision_thread.wait_to_finish()
    decision_thread = null

    # Stale-response guards. We check three things:
    #   (1) request_id mismatch — a newer request was issued
    #   (2) ReplayManager.resimulating — undo/redo cycle running
    #   (3) state_hash mismatch — same tick number but different state
    if request_id != self.pending.get("request_id", -1):
        log_tier_event("STALE_REQUEST_ID", request_id, "")
        return  # pending already moved on
    if ReplayManager.resimulating:
        log_tier_event("STALE_RESIM", self.pending.tick, "")
        _clear_pending()
        call_deferred("_maybe_redecide")  # see "Stale re-fire" below
        return
    var current_hash = _hash_state(target_player, target_player.opponent)
    if current_hash != self.pending.state_hash:
        log_tier_event("STALE_STATE_HASH", self.pending.tick, "")
        _clear_pending()
        call_deferred("_maybe_redecide")
        return

    # Read decision context from self.pending. Capture into locals so
    # the rest of this function reads cleanly.
    var mode = self.pending.mode
    var temp_extra = self.pending.temp_extra
    var di = self.pending.di
    var predicted_opponent = self.pending.predicted_opponent
    var legal_moves = self.pending.legal_moves
    var tick_at_request = self.pending.tick

    var action_name = null
    var data = null
    var feint = false
    var action_tier = null
    var degradation_reason = null

    # Schema-version handshake. If the bridge ships a frame at an
    # unexpected schema, degrade to Tier 2 with a labelled reason.
    if raw.ok and raw.get("schema_version", -1) != 1:
        degradation_reason = "schema_mismatch"
    elif raw.ok and raw.outcome == "ranked" and mode != "v1":
        degradation_reason = "mode_mismatch"
    elif raw.ok and raw.outcome == "category" and mode != "v0":
        degradation_reason = "mode_mismatch"

    # TIER 1: Claude LLM
    if raw.ok and raw.outcome != "error" and degradation_reason == null:
        var resp = raw.response
        if mode == "v0":
            # v0: cache heuristic call (it runs setup_ghost_game per
            # button — calling twice doubles cost).
            var best = _heuristic_topk_for_category(resp.category, predicted_opponent, temp_extra)
            if best != null and best.action != null:
                action_name = best.action
                data        = best.data
                feint       = best.feint and target_player.feints > 0
                action_tier = "LLM_V0"
            else:
                degradation_reason = "v0_filter_empty"
        else:
            # v1: walk ranked, take first that validates.
            if not (resp.has("ranked") and resp.ranked is Array):
                degradation_reason = "parse_error"
            elif resp.ranked.size() == 0:
                degradation_reason = "empty_ranked"
            elif resp.ranked.size() > 50:
                degradation_reason = "ranked_cardinality"
            else:
                # Hard-cap to first 5 entries; reject if all invalid.
                var capped = resp.ranked.slice(0, min(5, resp.ranked.size()) - 1)
                for ranked in capped:
                    var legal_entry = _find_in_legal_moves(legal_moves, ranked.action_name)
                    if legal_entry == null:
                        continue
                    if ranked.data_index < 0 or ranked.data_index >= legal_entry.data_options.size():
                        continue
                    action_name = ranked.action_name
                    data        = legal_entry.data_options[ranked.data_index]
                    feint       = bool(resp.get("feint", false))
                    action_tier = "LLM_V1"
                    break
                if action_name == null:
                    degradation_reason = "all_invalid"
    elif not raw.ok or raw.outcome == "error":
        degradation_reason = raw.get("error_code", "transport_unknown")

    # TIER 2: heuristic top-1. Confirm the argument order against the
    # actual get_best_move signature in _AIOpponents/AIController.gd at
    # integration time. Leeway 0.01 is chosen tight on purpose: Tier 2
    # is a fallback, we want a deterministic pick, no exploration.
    # (Reference uses 0.2 for SELF picks; we deliberately deviate.)
    if action_name == null:
        var h = heuristic.get_best_move(
            temp_extra, id,
            0.01, true, true, true,
            predicted_opponent.action_name, predicted_opponent.data)
        if h and h.action != null:
            action_name = h.action
            data        = h.data
            feint       = h.feint and target_player.feints > 0
            action_tier = "HEURISTIC"

    # TIER 3: minimal-safe Continue
    if action_name == null:
        action_name = "Continue"
        data        = null
        feint       = false
        action_tier = "SAFE_CONTINUE"

    # DI: default to away. If self is in hitstun (state.type ==
    # CharState.ActionType.Hurt) and Claude returned a di_override, accept it.
    var final_di = di
    if raw.ok and raw.outcome != "error" \
       and raw.response.get("di_override") != null \
       and target_player.current_state() != null \
       and target_player.current_state().type == CharState.ActionType.Hurt:
        var override = _decode_di_string(raw.response.di_override)
        if override != null:
            final_di = override

    target_player.queued_action = action_name
    target_player.queued_data   = data
    target_player.queued_extra  = {
        "DI": final_di,
        "feint": (feint if target_player.feints > 0 else false),
        "prediction": -1,
        "reverse": false,
    }
    target_player.on_action_selected(action_name, data, target_player.queued_extra)
    game.turns_taken[target_player.id] = true
    # Mirrored from _AIOpponents/AIController.make_move for parity; the
    # Network.turns_ready write is no-op in singleplayer because
    # Network is not authoritative.
    Network.turns_ready[target_player.id] = true
    log_decision(action_tier, "submitted", degradation_reason, tick_at_request, action_name)
    _clear_pending()
    main.call_deferred("_start_ghost")


func _clear_pending():
    self.pending = {}
    pending_tick = -1


func _maybe_redecide():
    # After a STALE drop, the game has either rewound or its state has
    # diverged. game.gd::process_tick re-emits player_actionable on the
    # next state transition, which usually fires within a tick. If for
    # some reason we sit idle (e.g. undo landed us exactly back at an
    # actionable boundary), kick a fresh decision after a one-frame
    # delay so the signal pump has time to fire first.
    if pending_tick != -1:
        return  # someone already started a new decision
    if game.turns_taken.get(target_player.id, false):
        return  # turn already resolved
    if not (target_player.state_interruptable):
        return  # game will re-emit naturally
    # Idle at an actionable boundary with no new signal → kick.
    call_deferred("_start_decision_thread")
```

### 6.1 v2 two-round flow

v2 adds a second TCP round after a synchronous K-candidate ghost-eval.
The state machine:

1. `player_actionable` → build v1-style payload (mode field is `"v2_round1"`
   on the wire), set `self.pending`, spawn **Thread_A**, Thread_A does
   round-1 TCP, `call_deferred("_v2_round1_complete", raw, request_id)`.
2. Main thread `_v2_round1_complete`: join Thread_A
   (`decision_thread.wait_to_finish()`), check stale guards (same as
   `_apply_choice`). Set `ReplayManager.resimulating = true`. Run sticky-ghost
   K-loop synchronously (fast — see §8 budget). Build round-2 payload
   (`mode: "v2_round2"`, includes `candidates_evaluated`). Set
   `resimulating = false`.
3. Spawn **Thread_B** with the round-2 payload, Thread_B does round-2
   TCP, `call_deferred("_apply_choice", raw, request_id)`.
4. `_apply_choice` unchanged.

Thread_A is fully joined in `_v2_round1_complete` BEFORE spawning
Thread_B. We never have two worker threads alive at once. The
`self.pending` dict gains a `v2_round1_response` field between round 1
and round 2 so the round-2 payload encoder can reach Claude's K
candidates.

Notes on the per-turn flow:

- The 8th line of the predicted-opponent step (`bursts_available > 0 or
  target_player.opponent.combo_count <= 0`) is exactly the reference AI's
  gate — without it, the heuristic re-decides opponent's move during an
  opponent combo, which corrupts predictions.
- `_AIOpponents/AIController.gd::_edit_queue` exists to **re-stomp**
  `queued_*` after `action_selected` fires. We do **not** install
  `_edit_queue`. Our purge step in §4 removed the controller, so
  nothing else is connected to `action_selected` for `target_player`.
- The DI gate (state.type == Hurt) uses `CharState.ActionType.Hurt`
  (named enum, no hard-coded integer). If `CharState` is not in scope
  at controller load, cache the enum value in a const at controller
  `_ready`: `const ACTION_TYPE_HURT = CharState.ActionType.Hurt`.
- The feint-guard `(feint if target_player.feints > 0 else false)`
  replicates `AIController.make_move`'s
  `"feint": choice.feint if target_player.feints > 0 else false`.
- All `ModOptions.get_setting(...)` calls go through
  `main.get_node("ModOptions").get_setting(...)`. There is no bare
  `ModOptions` autoload; `ModOptions.gd` extends
  `res://SoupModOptions/ModOptions.gd` and is registered as a child of
  Main by the SoupModOptions modloader. If SoupModOptions is absent
  (`main.get_node_or_null("ModOptions") == null`), default mode to `"v1"`
  and log once.

---

## 7. Threading model

The reference AI runs `make_move` synchronously on the main thread.
That works because the heuristic runs in ~milliseconds (it's a fixed
number of 35-tick ghost sims through native `Simulation.gdns`). Claude
takes 500ms–5s. Blocking the main thread that long freezes input,
render, and the Steam overlay.

**Decision: TCP roundtrip runs on a Godot `Thread`. Main thread
ships the request, parks, and receives the result via `call_deferred`.
Connection is opened once per match in `_spawn_bridge_probe()` (called
from `_ready`) and re-used per turn.** Per-turn reconnect adds ~3 RTT
of TCP handshake on loopback (1–5ms) plus an asyncio task on the Python
side; reusing a persistent connection avoids that and lets the bridge
keep prompt-cache state warm.

**Hard deadlines (mod side, in addition to Python's 6s Claude timeout).**

- CONNECT_TIMEOUT_MS = 2000. `connect_to_host` can stay in CONNECTING
  for OS-level TCP timeout (21–75s on Windows) if the listener never
  accepts. We poll status with a wall-clock budget and bail out.
- READ_TIMEOUT_MS = 8000. Python's hard Claude budget is 6s plus
  overhead; we add 2s slack. If the read exceeds the budget we
  `disconnect_from_host()` and return `transport_read_timeout`.
- MAX_FRAME_SIZE = 1_048_576 (1 MB). A bad bridge could ship a giant
  length prefix; reading 2GB into PoolByteArray would OOM.

```gdscript
const CONNECT_TIMEOUT_MS = 2000
const READ_TIMEOUT_MS = 8000
const MAX_FRAME_SIZE = 1_048_576  # 1 MB

func _decide_off_thread(payload):
    # tcp is the persistent per-match StreamPeerTCP, opened in
    # _spawn_bridge_probe(). If status drops, reconnect once before
    # giving up.
    if tcp == null or tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
        if not _reconnect():
            call_deferred("_apply_choice",
                {"ok": false, "outcome": "error", "error_code": "transport_no_connect"},
                self.pending.request_id)
            return

    var p = ProtocolEncoder.serialize(payload)
    var body = JSON.print(p).to_utf8()
    if body.size() > MAX_FRAME_SIZE:
        # Defensive — should never happen, but a malformed legal_moves
        # could blow past the cap.
        call_deferred("_apply_choice",
            {"ok": false, "outcome": "error", "error_code": "transport_oversize_request"},
            self.pending.request_id)
        return

    # Build one PoolByteArray (length prefix + body) and send in a
    # single put_data call — avoids partial-write window between
    # put_32 and put_data.
    var framed = PoolByteArray()
    framed.append((body.size() >> 24) & 0xFF)
    framed.append((body.size() >> 16) & 0xFF)
    framed.append((body.size() >> 8) & 0xFF)
    framed.append(body.size() & 0xFF)
    framed.append_array(body)
    if tcp.put_data(framed) != OK:
        call_deferred("_apply_choice",
            {"ok": false, "outcome": "error", "error_code": "transport_write_failed"},
            self.pending.request_id)
        return

    # Read length prefix with deadline. Use get_partial_data in a poll
    # loop instead of blocking get_data so we can enforce a wall clock.
    var t0 = OS.get_ticks_msec()
    var len_buf = PoolByteArray()
    while len_buf.size() < 4:
        if OS.get_ticks_msec() - t0 > READ_TIMEOUT_MS:
            tcp.disconnect_from_host()
            call_deferred("_apply_choice",
                {"ok": false, "outcome": "error", "error_code": "transport_read_timeout"},
                self.pending.request_id)
            return
        var avail = tcp.get_available_bytes()
        if avail > 0:
            var pkt = tcp.get_partial_data(min(avail, 4 - len_buf.size()))
            if pkt[0] != OK:
                call_deferred("_apply_choice",
                    {"ok": false, "outcome": "error", "error_code": "transport_len_read"},
                    self.pending.request_id)
                return
            len_buf.append_array(pkt[1])
        else:
            OS.delay_msec(2)

    # Big-endian unsigned decode. We could also use a StreamPeerBuffer
    # with big_endian = true and call get_u32(); equivalent.
    var msg_len = (int(len_buf[0]) << 24) \
                | (int(len_buf[1]) << 16) \
                | (int(len_buf[2]) << 8) \
                |  int(len_buf[3])
    # Bounds check. Guards against negative msg_len from a malformed
    # prefix and against OOM from a giant prefix.
    if msg_len <= 0 or msg_len > MAX_FRAME_SIZE:
        tcp.disconnect_from_host()
        call_deferred("_apply_choice",
            {"ok": false, "outcome": "error", "error_code": "transport_bad_length"},
            self.pending.request_id)
        return

    var body_buf = PoolByteArray()
    while body_buf.size() < msg_len:
        if OS.get_ticks_msec() - t0 > READ_TIMEOUT_MS:
            tcp.disconnect_from_host()
            call_deferred("_apply_choice",
                {"ok": false, "outcome": "error", "error_code": "transport_read_timeout"},
                self.pending.request_id)
            return
        var avail = tcp.get_available_bytes()
        if avail > 0:
            var pkt = tcp.get_partial_data(min(avail, msg_len - body_buf.size()))
            if pkt[0] != OK:
                call_deferred("_apply_choice",
                    {"ok": false, "outcome": "error", "error_code": "transport_body_read"},
                    self.pending.request_id)
                return
            body_buf.append_array(pkt[1])
        else:
            OS.delay_msec(2)

    var parsed = JSON.parse(body_buf.get_string_from_utf8())
    if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
        call_deferred("_apply_choice",
            {"ok": false, "outcome": "error", "error_code": "transport_json_parse"},
            self.pending.request_id)
        return

    # parsed.result is the canonical envelope: {ok, outcome, response?,
    # error_code?, schema_version}. Pass through unchanged.
    call_deferred("_apply_choice", parsed.result, self.pending.request_id)


func _reconnect():
    if tcp != null:
        tcp.disconnect_from_host()
    tcp = StreamPeerTCP.new()
    tcp.set_no_delay(true)
    tcp.set_big_endian(true)  # CRITICAL: defaults to little-endian (§3)
    var err = tcp.connect_to_host("127.0.0.1", bridge_port)
    if err != OK:
        return false
    var t0 = OS.get_ticks_msec()
    while tcp.get_status() == StreamPeerTCP.STATUS_CONNECTING:
        if OS.get_ticks_msec() - t0 > CONNECT_TIMEOUT_MS:
            tcp.disconnect_from_host()
            return false
        OS.delay_msec(5)
    if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
        return false
    return _do_handshake()  # see §3 hello / auth exchange
```

### 7.1 `ReplayManager.resimulating` interaction

The audit pinned this as a race condition. `ReplayManager.gd::undo()`
opens with:

```gdscript
func undo(cut=true):
    if resimulating:
        return
```

The reference AI sets `ReplayManager.resimulating = true` at the start of
`make_move` and false at the end:

```gdscript
ReplayManager.resimulating = true # Not strictly necessary but stops Godot errors
...
ReplayManager.resimulating = false
```

If we do the same around the TCP call, **any undo the user attempts
during the 500ms–5s window is silently swallowed**. If we don't, a
user-triggered undo during the call rewinds game state, and when our
response arrives we write `queued_action` into stale player slots.
Worse, an undo + redo could land the game back on the same tick number
but with a different state vector.

**Decision: do not set `ReplayManager.resimulating` around the TCP
call.** Instead, use a **three-part stale guard**:

1. **Monotonic request_id.** `request_id_counter` increments on every
   decision spawn. `_apply_choice` rejects any response whose
   `request_id` does not match `self.pending.request_id` — i.e. a newer
   decision has already superseded this one.
2. **ReplayManager.resimulating flag.** If true at apply time, undo/redo
   is in progress; drop the response.
3. **State hash.** A cheap fingerprint
   (`xor` of `hp_self, hp_opp, pos_self, pos_opp, current_state_self,
   current_state_opp`) computed at request time and again at apply
   time. If mismatched, the state vector has changed even if the tick
   number hasn't — drop.

When any guard fires, `_apply_choice` clears `self.pending` and
calls `_maybe_redecide` via `call_deferred`. `_maybe_redecide` checks
whether the game is sitting at an actionable boundary with no new
signal pending and kicks a fresh decision if so. (Normally
`game.gd::process_tick` re-emits `player_actionable` on the next state
transition; the kick is the safety net for "undo landed us exactly back
at an actionable boundary with no pending edge.")

**Hook into ReplayManager.undo to abandon in-flight workers.**
Specifically: if `ReplayManager` exposes an `undo_started` signal (or we
monkey-patch via `installScriptExtension`), connect it to a slot that
sets `self.pending.request_id = -1` so the in-flight worker's response
is rejected the moment it arrives. If we cannot patch ReplayManager,
the state-hash guard catches it on apply.

**Only** set `resimulating = true` around the optional v2 ghost-eval
step (§8) — which is fast (K=3 × 35 ticks of native sim ≈ low ms) and
worth blocking undo for.

Trade-off accepted: a user undo during the long TCP window means
Claude's response is wasted (one API call's worth of latency + tokens).
That's strictly better than the alternative (silently swallowing undos
or writing into stale state), and the cost is one extra API call per
ill-timed undo.

### 7.2 Thread teardown

`Thread.wait_to_finish()` is **ALWAYS** called as the first thing in
`_apply_choice`, regardless of stale-guard outcome. Skipping it leaks
the Thread Object (per Godot 3.5 docs, `is_active()` returns true until
joined; repeatedly spawning without joining leaks Thread handles and
native pthread IDs).

If the controller is freed mid-flight (e.g., user exits to menu),
`_exit_tree` calls `tcp.disconnect_from_host()` (surfaces an error in
the worker's read loop) and then `decision_thread.wait_to_finish()`.

---

## 8. Ghost-eval verification

This section is v2-specific. v1 ships without it.

The audit identified the cost model the reference AI gets wrong:
`setup_ghost_game()` is the expensive primitive (it frees the prior
ghost game and re-instantiates `Game.tscn` — full scene-tree teardown
plus restart), not `simulate_one_tick()`. The reference AI calls
`setup_ghost_game()` **once per (action, data, opponent_action,
opponent_data) tuple**: `get_best_move()` iterates buttons, calls
`evaluate_button()`, which calls `eval_move()`, which calls
`setup_ghost_game()` at line 1. With ~10 visible buttons × ~3 data
permutations each + `evaluate_button` extra inner loops, you get
30–90 ghost teardown-rebuild cycles per turn. The 35-tick sim per
cycle is the cheap part (native code).

**Decision (v2): sticky ghost.** Instantiate `Game.tscn` once when the
controller starts (or lazily on first v2 turn). Before each candidate,
just call `game.copy_to(ghost_game)` (the same one-shot snapshot the
reference does at the *end* of its `setup_ghost_game()`). Don't free
the ghost between candidates. Free only on controller tear-down or
match end.

```gdscript
# HeuristicShim.gd — composition wrapper. NOT a Node in the scene tree.
# Holds sticky_ghost as the SOLE owner; the controller never touches it
# directly.
var sticky_ghost = null
var sticky_match_data_id = null  # invalidation token

func ensure_ghost():
    # Invalidate if match_data has changed (rematch / character select).
    if sticky_ghost != null and is_instance_valid(sticky_ghost) \
       and sticky_match_data_id == main.match_data.get_instance_id():
        return
    if sticky_ghost != null and is_instance_valid(sticky_ghost):
        sticky_ghost.queue_free()
    sticky_ghost = preload("res://Game.tscn").instance()
    sticky_ghost.is_ghost = true
    sticky_ghost.visible = false
    main.find_node("GhostViewport").add_child(sticky_ghost)
    sticky_ghost.start_game(true, main.match_data)
    sticky_ghost.ghost_speed = 100
    sticky_ghost.ghost_freeze = false
    sticky_match_data_id = main.match_data.get_instance_id()

func eval_candidate(action, data, opponent_action, opponent_data):
    ensure_ghost()
    game.copy_to(sticky_ghost)
    # copy_to is documented to snapshot game state but does NOT
    # necessarily preserve runtime flags like ghost_speed / ghost_freeze.
    # Re-apply defensively after every copy_to.
    sticky_ghost.ghost_speed = 100
    sticky_ghost.ghost_freeze = false
    var evaluee  = sticky_ghost.get_player(id)
    var opponent = sticky_ghost.get_player(evaluee.opponent.id)
    opponent.is_ghost = true
    opponent.queued_action = opponent_action
    opponent.queued_data = opponent_data
    # Set queued_extra for the OPPONENT too. The reference AI does this
    # implicitly via _edit_queue; we don't have _edit_queue, so we set
    # explicitly. Defaults match AIController.make_move's defaults.
    opponent.queued_extra = {
        "DI": _away_di_for(opponent),
        "feint": false,
        "prediction": -1,
        "reverse": false,
    }
    evaluee.is_ghost = true
    evaluee.queued_action = action
    evaluee.queued_data = data
    evaluee.queued_extra = {
        "DI": _di_for(evaluee, opponent),
        "feint": false,
        "prediction": -1,
        "reverse": false,
    }

    var self_hp0 = evaluee.hp
    var opp_hp0  = opponent.hp
    var self_super0 = evaluee.super_meter
    var d0 = sqrt(pow(opponent.get_pos().x - evaluee.get_pos().x, 2) + \
                  pow(opponent.get_pos().y - evaluee.get_pos().y, 2))
    var self_ready = null
    var opp_ready  = null

    var loop_t0 = OS.get_ticks_msec()
    for i in range(1, 36):  # FRAMES_TO_SIMULATE = 35
        # Hard budget: if the K-loop is taking too long, abort the
        # candidate. We bound aggregate K-loop wall clock at 50ms; per
        # candidate budget is 50ms / K.
        if OS.get_ticks_msec() - loop_t0 > 16:  # ~16ms per candidate
            return null  # caller drops this candidate
        sticky_ghost.simulate_one_tick()
        if self_ready == null and (evaluee.state_interruptable or evaluee.dummy_interruptable or evaluee.state_hit_cancellable):
            self_ready = i
        if opp_ready == null and (opponent.state_interruptable or opponent.dummy_interruptable or opponent.state_hit_cancellable):
            opp_ready = i
        if self_ready != null and opp_ready != null:
            break

    if self_ready == null: self_ready = 35
    if opp_ready  == null: opp_ready  = 35
    var d1 = sqrt(pow(opponent.get_pos().x - evaluee.get_pos().x, 2) + \
                  pow(opponent.get_pos().y - evaluee.get_pos().y, 2))

    return {
        "predicted_self_hp_delta":     evaluee.hp - self_hp0,
        "predicted_opponent_hp_delta": opponent.hp - opp_hp0,
        "predicted_frame_advantage":   opp_ready - self_ready,
        "predicted_distance_closed":   d0 - d1,
        "predicted_self_super_delta":  evaluee.super_meter - self_super0,
    }

func _exit_tree_equivalent():
    # Called from ClaudeController._exit_tree (via heuristic.free()).
    if sticky_ghost != null and is_instance_valid(sticky_ghost):
        sticky_ghost.queue_free()
    sticky_ghost = null
```

**v2 budget:** K=3 candidates × 35 ticks of native sim ≈ a few ms total
once the sticky ghost is hot. We set `ReplayManager.resimulating = true`
around `ensure_ghost()` and the K-loop and back to false after.
Aggregate K-loop wall clock is hard-bounded at 50ms; per-candidate
budget is ~16ms. If the budget is exceeded, the candidate's eval result
is null and we submit the remaining candidates to Claude (round 2) with
fewer entries. Undo is blocked for ≤ 50ms.

**Ghost determinism verification.** v2 assumes
`game.copy_to(ghost)` + identical inputs produces identical outputs
(RNG state included). We do not know whether `copy_to` snapshots RNG
state. To detect divergence: at controller `_ready`, run a one-shot
`verify_ghost_determinism()` test that calls `eval_candidate(Continue,
null, Continue, null)` twice and asserts identical results. If the
results differ, disable v2 for the session, log
`GHOST_NONDETERMINISTIC`, and fall back to v1.

**Tier 2 heuristic and the sticky ghost.** Tier 2 calls
`heuristic.get_best_move()` which uses the reference AI's
`setup_ghost_game()` (NOT our sticky ghost) — different code path.
Tier 2 therefore pays the full ~90 ghost teardown-rebuild cycles per
call. We leave this as-is for v1: Tier 2 is the fallback, not the hot
path. v2-style vendoring of the heuristic onto our sticky ghost is an
open question (§13).

### 8.1 v2 decision: post-35-frame adjudication

The audit gave two v2 options:
- (a) Claude re-weights `FRAME_ADVANTAGE_MODIFIER` etc. per state.
- (b) Claude sees ghost-eval outputs PLUS post-35-frame state and adjudicates.

**We pick (b).** Re-weighting (a) asks Claude to invent eval coefficients
from a single state — under-determined and hard to evaluate offline.
Adjudication (b) gives Claude a small table (K rows × ~6 columns of
concrete predicted outcomes), which is the format LLMs handle well, and
it's directly auditable post-hoc by comparing chosen-vs-not chosen rows.
If v2 underperforms v1 in playtest, falling back to v1 is a single config
flag.

---

## 9. Failure modes & fallbacks

Telemetry splits into TWO orthogonal dimensions:

- **action_tier** ∈ `{LLM_V1, LLM_V0, HEURISTIC, SAFE_CONTINUE}` — which
  code path produced the submitted action.
- **resolution** ∈ `{submitted, stale_dropped, error}` — whether the
  decision was actually submitted, dropped as stale, or terminated in
  error. `STALE_TICK`, `STALE_RESIM`, `STALE_STATE_HASH`,
  `STALE_REQUEST_ID` are all `resolution=stale_dropped`.

| action_tier | Condition | Latency budget | Source-side cost |
|-------------|-----------|----------------|------------------|
| `LLM_V1` / `LLM_V0` | Python returns valid response in time, validator accepts | 0.5–5s (network + Claude) | one Claude API call |
| `HEURISTIC` | Claude all-invalid, socket error, schema mismatch, bridge offline | ≤ 200ms typical (Tier 2 budget) | up to ~90 ghost-game cycles (reference cost) |
| `SAFE_CONTINUE` | heuristic also errors (instance freed, ghost setup fails, etc.) | < 1ms | submit `{action:"Continue", data:null}` + default `extra` |

### 9.1 Latency budget matrix

| Phase | Budget | Action on overrun |
|-------|--------|-------------------|
| TCP connect (`connect_to_host` + status poll) | 2000ms | Treat as `transport_no_connect`, Tier 2 fallback |
| Frame write (`put_data` of length + body) | 100ms | Treat as `transport_write_failed`, Tier 2 |
| Frame read (length + body) | 8000ms | Treat as `transport_read_timeout`, Tier 2 |
| Python Claude call (Anthropic API, internal) | 6000ms | Python returns `error_code=claude_timeout` |
| Anthropic SDK retries | DISABLED (`max_retries=0`) | All retry logic is mod-side |
| Tier 2 heuristic | 200ms target, log if exceeded | If `OS.get_ticks_msec()` overrun, still complete (no preempt) but log `HEURISTIC_SLOW` |
| Tier 3 SAFE_CONTINUE | <1ms | n/a |
| v2 ghost-eval K-loop | 50ms aggregate, 16ms/candidate | Skip remaining candidates, submit partial round 2 |
| Total decision wall clock | 8000ms hard ceiling | If reached, force SAFE_CONTINUE — never let the game freeze |

### 9.2 Degradation-reason taxonomy

Every non-LLM-V1 outcome logs a `degradation_reason`. Values:

| reason | source | meaning |
|--------|--------|---------|
| `claude_timeout` | Python | Claude API call exceeded 6s |
| `api_error` | Python | Claude API returned a non-200 status |
| `parse_failure` | Python | Claude's text response did not parse as JSON |
| `empty_ranked` | Python or mod | `ranked: []` in response |
| `all_invalid` | Python or mod | Every entry in a non-empty `ranked` failed validation (the bridge pre-validates and returns it as an `error_code`; the mod's own walk can also conclude it) |
| `mode_mismatch` | mod | Response `outcome` does not match request `mode` |
| `schema_mismatch` | mod or Python | `schema_version` not 1 |
| `ranked_cardinality` | mod | `len(ranked) > 50` |
| `v0_filter_empty` | mod | v0 category filter yielded zero buttons |
| `transport_no_connect` | mod | TCP connect timed out or refused |
| `transport_read_timeout` | mod | TCP read exceeded 8s |
| `transport_write_failed` | mod | `put_data` returned non-OK |
| `transport_json_parse` | mod | Body wasn't valid JSON |
| `transport_bad_length` | mod | Length prefix was 0, negative, or > 1 MB |
| `transport_oversize_request` | mod | Our own request body > 1 MB |
| `transport_bridge_offline` | mod | Probe failed at `_ready`, no per-turn TCP attempted |
| `auth_fail` | Python or mod | Token did not match |
| `PREDICTED_OPP_FALLBACK_CONTINUE` | mod | Heuristic pre-step errored; predicted_opponent defaulted to Continue |

### 9.3 Bridge-offline UX

If `_spawn_bridge_probe` fails (`bridge_ready = false`), we do NOT
attempt per-turn TCP — every decision goes straight to Tier 2. A small
persistent HUD indicator reads "Claude bridge offline — using heuristic".
We re-probe every 30s; on success, flip `bridge_ready = true` and clear
the indicator. Without this, the first 5 seconds of round 1 would
silently run the heuristic and the user would assume Claude was active.

### 9.4 Validation of Claude's response against legal set

Per §6:

- `action_name in legal_moves` (after dedupe by `(action_name, frozen(data_options))`)
- `0 <= data_index < legal_moves[action_name].data_options.size()`
- For each entry in `resp.ranked` (capped to first 5), walk down and
  pick the first that validates. If none, set `degradation_reason =
  all_invalid` and fall to Tier 2.

### 9.5 Logging

Every turn writes one **summary line** to `user://claude_yomih.log`:

```
[match=a1b2c3d4 tick=1473 req=412] tier=LLM_V1 resolution=submitted latency_ms=947 action=Grab data_idx=0 predicted_opp=Continue
[match=a1b2c3d4 tick=1490 req=413] tier=HEURISTIC resolution=submitted reason=all_invalid action=HorizontalSlash
[match=a1b2c3d4 tick=1503 req=414] tier=- resolution=stale_dropped reason=STALE_REQUEST_ID
[match=a1b2c3d4 tick=1520 req=415] tier=SAFE_CONTINUE resolution=submitted reason=claude_timeout action=Continue
```

And a **per-turn detail snapshot** as JSON at
`user://claude_yomih/turns/<match_id>/<tick>.json` containing:

- Full request payload (state, legal_moves, predicted_opponent, history)
- Full response payload (including `reasoning_brief` and per-entry
  `reason` text)
- All tier transitions tried (LLM → Heuristic → Safe; with reasons)
- Latency breakdown (connect, send, recv, parse, heuristic)
- `model_version`, `bridge_version`, `git_sha`, `schema_version`
- Final chosen `(action_name, data, queued_extra)` tuple

Snapshots are gzipped and rotated (keep last 100 matches). Snapshots
make "why did Claude pick X" diffable, replayable through
`tools/replay_decisions.py`, and shareable post-mortem.

---

## 10. v0 category-picker baseline

v0 is a separate code path enabled via `ModOptions.get_setting("claude_yomih", "mode") == "v0"`.

GDScript side:

```gdscript
func _build_v0_payload():
    var visible_categories = {}
    for button in action_buttons.buttons:
        if button.is_visible() and button.state != null:
            visible_categories[CharState.ActionType.keys()[button.state.type]] = true
    return {
        "schema_version": 1,
        "tick": pending_tick,
        "mode": "v0",
        "state": ProtocolEncoder.snapshot_state(game, target_player),
        "predicted_opponent": predicted_opponent,
        "recent_history": RecentHistory.last_n(8),
        "character_info": ProtocolEncoder.character_info(target_player, target_player.opponent),
        "visible_categories": visible_categories.keys(),
    }
```

On response:

```gdscript
func _heuristic_topk_for_category(category_name, predicted_opponent, temp_extra):
    var enum_idx = _category_name_to_action_type_int(category_name)  # "Attack" → 2
    var filtered = []
    for button in self.pending.action_buttons.buttons:
        if button.is_visible() and button.state != null and button.state.type == enum_idx:
            filtered.append(button)
    # Mini get_best_move loop using AIController.evaluate_button on filtered set.
    var best = {"action": null, "data": null, "feint": false, "eval": -INF}
    for button in filtered:
        var ev = heuristic.evaluate_button(button, temp_extra, id,
                                           predicted_opponent.action_name,
                                           predicted_opponent.data)
        if ev.eval > best.eval:
            best = {"action": ev.action, "data": ev.data, "feint": ev.feint, "eval": ev.eval}
    return best
```

**Call once per turn.** `_heuristic_topk_for_category` is expensive —
each `evaluate_button` invocation runs `setup_ghost_game()` (the
expensive primitive). In `_apply_choice` we cache its result:
`var best = _heuristic_topk_for_category(...)`; `action_name =
best.action`; `data = best.data`. Calling twice in a row (once for
action, once for data) doubles cost; do not regress this.

The category enum exposed to Claude is exactly
`CharState.ActionType.keys()` — i.e. `["Movement", "Attack", "Special",
"Super", "Defense", "Hurt"]` (we filter `Hurt` from `visible_categories`
since it's a passive state, not a button). Claude's response schema in
§3.3 keys to those literal strings.

**Feint policy in v0.** v0 respects the heuristic's `feint` suggestion
gated by `target_player.feints > 0`, matching v1 and Tier 2. Do not
hardcode `feint = false` in v0.

**Why ship v0 alongside v1:** v0 is the cheapest possible Claude
involvement (single category + tiny prompt). If it materially beats
pure-heuristic play (`mode: "v_none"`, AKA running `_AIOpponents` raw),
that's a strong signal that strategic understanding helps. If v1 also
beats v0 by a similar margin, that's the case for the LLM doing concrete
move selection. The mod-options pane has three radio buttons:
`v_none` / `v0` / `v1` (v2 added once landed).

**Heuristic configuration parity for A/B.** The audit pinned a dead-code
bug in the reference AI's `eval_move`: the local `frame_advantage_modifier`
is computed but never read, and the eval expression uses the uppercase
`FRAME_ADVANTAGE_MODIFIER` export. We vendor a fix as a config flag
`HEURISTIC_FIX_FRAME_ADV_DIVISOR`. For v0/v1 A/B comparisons against the
`v_none` baseline, lock the heuristic to ONE configuration (recommend
`fix-off`, i.e. match the public `_AIOpponents` experience). The fix is
exposed as a separate ModOptions toggle for experimentation, not the
default.

---

## 11. DI selection

The reference AI hard-codes DI to "away from opponent" via
`Vector2(ai_pos.x - opp_pos.x, ai_pos.y - opp_pos.y).normalized()`. We
default to the same. The audit flagged that DI is only meaningful in
hitstun — the field is set on every turn but only affects gameplay
during a hit.

**Decision: gate Claude's `di_override` by `state.type == Hurt`.** When
the controller's own `target_player.current_state().type` is the Hurt
enum index, we accept Claude's `di_override` if present; otherwise we
write the default-away vector regardless of what Claude says about DI.

```gdscript
const ACTION_TYPE_HURT = CharState.ActionType.Hurt  # cache at _ready time

var final_di = _default_di_away_from(target_player, target_player.opponent)
if raw.ok and raw.outcome != "error" \
   and raw.response.get("di_override") != null \
   and target_player.current_state() != null \
   and target_player.current_state().type == ACTION_TYPE_HURT:
    var override = _decode_di_string(raw.response.di_override)  # string → Vector2
    if override != null:
        final_di = heuristic.di_as_percentage_int_vec(override)
```

DI override allowed values (Python side validates before forwarding):
`{neutral, away, toward, up, opponent-corner, up-left, up-right,
down-left, down-right}` → each mapped to a `Vector2` then percentage-int
via `di_as_percentage_int_vec` exactly as the reference does.

**Feint** is forced false when `target_player.feints == 0`, replicating
`AIController.make_move`'s `"feint": choice.feint if target_player.feints
> 0 else false`. Claude may suggest feinting but we drop it if the
fighter has no feints remaining.

---

## 12. Build & distribution

### 12.1 Repo layout

```
yomihustle-ai/
├── DESIGN.md              ← this file
├── RESEARCH.md
├── VALIDATION.md
├── README.md
├── src/                   ← mod source (gets zipped)
│   ├── ModMain.gd
│   ├── ClaudeLoader.gd
│   ├── ClaudeController.gd
│   ├── ClaudeController.tscn
│   ├── ModOptions.gd
│   ├── ProtocolEncoder.gd
│   ├── ProtocolDecoder.gd
│   ├── HeuristicShim.gd
│   ├── LegalMoveEnumerator.gd
│   └── _metadata
├── python/                ← TCP bridge
│   ├── bridge.py
│   ├── prompts/
│   │   ├── system_v0.txt
│   │   ├── system_v1.txt
│   │   ├── characters/cowboy.json
│   │   └── characters/ninja.json
│   ├── requirements.txt
│   └── README.md
└── tools/
    ├── build.ps1
    └── install_dev.ps1
```

### 12.2 `tools/build.ps1`

ZIP `src/` into `<exe-dir>/mods/yomihustle-ai.zip`. **Critical:** the
ZIP must contain `ModMain.gd` at *subfolder* level, not at the root.
The audit pinned this: `ModLoader.gd::_loadMods` and `gdunzip` walk
`rsplit('/')[0]` to find the mod directory; a bare `ModMain.gd` at the
ZIP root would parse as having `rsplit` result `""` and fail to load.
The ZIP structure we produce:

```
yomihustle-ai.zip
└── claude_yomih/
    ├── ModMain.gd
    ├── ClaudeLoader.gd
    ├── ClaudeController.gd
    ├── ClaudeController.tscn
    ├── ModOptions.gd
    ├── ProtocolEncoder.gd
    ├── ProtocolDecoder.gd
    ├── HeuristicShim.gd
    ├── LegalMoveEnumerator.gd
    └── _metadata
```

`build.ps1` (sketch):

```powershell
param([string]$ExeDir = "$env:ProgramFiles\Steam\steamapps\common\Your Only Move Is HUSTLE")

$src = Resolve-Path "$PSScriptRoot\..\src"
$staging = New-Item -ItemType Directory -Force -Path "$env:TEMP\claude_yomih_build\claude_yomih"
Copy-Item -Recurse -Force "$src\*" $staging.FullName
$out = "$ExeDir\mods\yomihustle-ai.zip"
if (Test-Path $out) { Remove-Item -Force $out }
Compress-Archive -Path "$($staging.Parent.FullName)\claude_yomih" -DestinationPath $out
Remove-Item -Recurse -Force $staging.Parent.FullName
Write-Output "Wrote $out"
```

### 12.3 Dev path

The audit clarified that ModLoader reads
`OS.get_executable_path().get_base_dir().plus_file("mods")`. There is
no environment variable that redirects this to a project-relative
folder. In the editor, `get_executable_path()` returns the GodotSteam
editor binary's path. Two dev workflows:

1. **In-editor (preferred for iteration):** add an editor-only debug
   autoload that calls `installScriptExtension` on absolute paths under
   the cloned `hustle/` repo, bypassing the ZIP-from-`<exe-dir>/mods/`
   path entirely. `tools/install_dev.ps1` does this by writing a debug
   autoload entry to a local `project.godot` override.
2. **Steam build (for end-users):** `tools/build.ps1` produces the ZIP
   and drops it in the Steam install's `mods/` folder.

### 12.4 Distribution

**v1 ships as a manual GitHub Release zip drop**, not Workshop. Reasons:

- Workshop publishing routes through `modloader/workshop_uploader/`,
  which depends on a Steam SDK login flow we don't want to bake into
  the v1 dev loop.
- Mod requires running a separate Python process; Workshop users would
  hit a confusing "AI not responding" if they forgot to start the
  bridge. GitHub readme + install script is friendlier.

### 12.5 Network exposure

**TCP is hardcoded to 127.0.0.1.** Bridge binds `socket.bind(("127.0.0.1",
PORT))` — never `0.0.0.0`. Mod readme calls this out:

> Claude Plays HUSTLE talks to a Python process on your own machine
> only. It never exposes a network port. If you need to run the bridge
> on a different machine, you'll have to fork.

**Port discovery.** Default port is 8765. If the bind fails with
`EADDRINUSE` (another instance of the bridge, leftover process from a
crashed game), Python retries `port+1` up to 8770. The chosen port is
written to `%LOCALAPPDATA%/claude_yomih/port` as a single ASCII integer.
The mod reads that file at `_ready` time; if absent or unreadable, it
defaults to 8765. The mod's bridge probe will then either succeed (file
matched) or fail and surface "bridge offline" UX (§9.3).

### 12.6 Build script — folder name & path coupling

All mod-internal preload paths go through `const MOD_ROOT =
"res://claude_yomih"` in `ClaudeController.gd` and are concatenated at
load time. Renaming the ZIP subfolder breaks every preload. Safer
alternatives:

- (a) Centralize the constant (current design) and document that the
  ZIP subfolder MUST equal `_metadata.name` (`claude_yomih`).
- (b) Derive paths at runtime via
  `get_script().resource_path.get_base_dir()`. More robust but adds
  indirection.

We pick (a) for v1. `build.ps1` asserts that the ZIP contains a folder
matching `_metadata.name` and fails if not.

---

## 13. Open questions

Deferred to v2 / v3:

1. **macOS support.** Repo `lib/` ships `tbfg.dll` (Windows) and
   `tbfg.so` (Linux) but no `.dylib`. Mac users have to build it from
   source or copy it out of the Mac Steam install. Out of scope for
   v1 — flag in README.
2. **Multihustle (3+ players).** Reference AI has explicit 3+ player
   support via `mh_ai_count`, per-opponent targeting, `selects[2][0]`
   UI fiddling. Lots of edge cases. v1 explicitly refuses if MH detected.
3. **Online play.** `player_actionable` is singleplayer-gated; even if
   we wired Claude into the multiplayer branch, the input deadline is
   sub-second per `Network.gd`'s undocumented constants. Strict offline.
4. **Mod-on-mod compatibility beyond `_AIOpponents/`.** YOMIRecord
   probably works (it hooks `MLMainHook` not `game.gd`). Workshop
   characters that add new buttons should "just work" because we
   enumerate via `action_buttons.buttons` not a hard-coded list. Custom
   characters with novel `data_ui_scene` shapes are an open question —
   our pre-enumeration relies on `get_data_structure()` handling the
   five known UIElement types (XYPlot, 8Way, Slider, CountOption,
   OptionButton, CheckButton). If a Workshop character ships a custom
   `UIElement` subclass, `get_data_structure()` returns null and we
   silently degrade to Tier 2 heuristic.
5. **Prompt-caching strategy.** Anthropic prompt cache is great for the
   long static prefix (character frame data + universal mechanics).
   Open question: do we cache per-character (5 cache entries) or per
   matchup (25 entries)? v1 caches per-character; v2 may benefit from
   per-matchup if we ship opponent move lookups in the prefix.
6. **Eval-weight tuning.** The reference AI uses
   `FRAME_ADVANTAGE_MODIFIER = 20`. The audit also pinned that the
   close-range divisor (`/= 10` when `distance_closed < 50`) is dead
   code in the source (declared but never used in the eval expression
   — the eval uses `FRAME_ADVANTAGE_MODIFIER` directly). When we vendor
   `AIController.gd` we **fix the dead code bug** by making the eval
   read `frame_advantage_modifier` instead of `FRAME_ADVANTAGE_MODIFIER`.
   Whether this makes the heuristic stronger or weaker is an open
   playtest question.
7. **Replay determinism — two tiers.** YOMIH uses seeded RNG for
   replays. Our mod adds non-deterministic LLM output. We resolve this
   with a two-tier replay strategy:
   - (a) **Game-side replay**: existing `ReplayManager` records the
     *chosen actions* only. Replays of recorded matches are
     byte-stable because seeded RNG advances identically given the same
     action queue — Claude's reasoning need not re-execute. Playable
     replays work as expected.
   - (b) **Decision-side replay**: per-turn JSON snapshots (§9.5) hold
     the request/response pairs. `tools/replay_decisions.py` re-runs
     the recorded requests through Claude (with `temperature=0` and the
     same `model_version` pinned) and reports drift. This is best-effort
     even with `temperature=0` because Anthropic does not guarantee
     bit-stable sampling.

   **README copy.** "Claude replays: game actions replay byte-stable,
   but Claude's reasoning is best-effort. If you record a match Claude
   played and play it back, the game will show the exact same moves —
   but if you ask Claude offline to re-explain why it picked what it
   picked, the answer may differ."
8. **`tbfg` native sim and `simulate_one_tick` recursion.** If
   `Simulation.gdns` ever calls back into GDScript that touches our
   socket, threading goes bad fast. v1 trusts the native sim is
   self-contained; v2 may need a re-entrancy guard.
9. **Tier 2 vendoring onto sticky ghost.** v1 ships Tier 2 (heuristic
   fallback) using the reference AI's `setup_ghost_game()` — the
   ~90-cycle cost. Vendoring `get_best_move` onto our sticky ghost
   would reduce Tier 2 to single-digit ms but introduces a second
   parallel codepath that diverges from upstream. Deferred to v2.

---

## 14. Testing strategy

A correctness story for the bridge, the mod, and the integration. Three
layers; we own all three.

### 14.1 Python bridge unit tests (`python/tests/`)

- `pytest` harness. Twenty+ recorded `player_actionable` payloads
  serialized as JSON fixtures.
- Each fixture has a known-good Claude response (recorded with
  `temperature=0` against a pinned model version) plus a "stub" mode
  that lets the test drive bridge logic without touching the API.
- `bridge.py --fixture <file>` reads a fixture and exercises the full
  request→response codepath (state validation, prompt assembly,
  response parsing, error envelope) without a live game.
- Coverage targets: prompt encoder, response decoder, schema-version
  handshake, auth handshake, fallback paths, per-character data-shape
  validation (Grab returns 4 permutations, ParryHigh returns 1).

### 14.2 GDScript-side stub bridge (`tools/stub_bridge.py`)

A deterministic server that returns canned responses (configurable via
YAML per request). Used to drive the mod end-to-end without a live
Claude API. Test scenarios:

- Happy path (return valid `ranked` of 3, verify mod submits top-valid).
- All-invalid path (return `ranked` with action_names not in legal_moves,
  verify Tier 2).
- Timeout path (server sleeps 10s, verify mod hits `transport_read_timeout`
  and falls to Tier 2 inside 8s).
- Mid-call disconnect (server drops connection mid-frame, verify mod
  recovers on next request).
- Schema-mismatch path (server returns `schema_version: 2`, verify
  `degradation_reason=schema_mismatch`).
- Authentication failure (server returns wrong token, verify
  `auth_fail`).

### 14.3 GDScript scene tests (`tools/test_legal_enum.gd` etc.)

Headless Godot scenes invoked via `godot --headless --script
test_legal_enum.gd`:

- Instantiate a real `Game.tscn` with a known character matchup. Walk
  every visible button, call `enumerate_legal_moves()`, assert known
  cardinalities: Cowboy.Grab → 4 permutations, Ninja.ParryHigh → varies
  by frame count, Continue → 1 (`null` data).
- Ghost-eval verification: snapshot game state, run `eval_candidate()`
  100 times with identical inputs, assert all 100 results are
  bit-identical. Property test for `verify_ghost_determinism()`.
- DI-decoder test: feed every `di_override` string enum from §11,
  assert each maps to the expected `Vector2`.
- Validator test: feed crafted responses with malformed `ranked`
  (empty, oversize, missing fields), assert correct
  `degradation_reason`.

### 14.4 Integration smoke (`tools/smoke_run.ps1`)

A scripted run that launches the bridge in stub mode, launches a fresh
match, plays 50 turns with deterministic stub responses, and asserts no
crashes, no Tier 3 fallbacks, no leaked Thread handles. Verifies the
end-to-end pipeline.

### 14.5 Heuristic-only smoke

Mod with `mode = "v_none"` runs 100 rounds without Python attached.
Verifies controller doesn't deadlock, no socket attempts, Tier 2
correctness against the reference AI.

---

## 15. Observability

### 15.1 Decision snapshots

Per §9.5, every turn writes a JSON snapshot at
`user://claude_yomih/turns/<match_id>/<tick>.json`. These are the source
of truth for "why did Claude pick X." They include the full request,
full response, validation outcomes, latency breakdown, model and bridge
versions.

### 15.2 Commentary mode (optional)

ModOptions toggle `commentary_enabled`. When on:

- During the decision wait (TCP roundtrip), render a small overlay:
  "Claude is thinking…" with elapsed time.
- After the move is submitted, display `reasoning_brief` for 2s in a
  HUD corner.
- Use Godot's existing overlay/HUD system; never intercept input.

### 15.3 Replay viewer (`tools/replay_match.py`)

Ingests a match's JSON snapshot directory and produces an HTML
transcript: per turn, the state, Claude's options, what it picked, its
reasoning. Critical for sharing replays + reasoning artifacts on social
media (project goal). Includes `model_version` and `git_sha` on every
turn so post-hoc audits can pin context.

### 15.4 Metrics summary

After each match, a single summary written to
`user://claude_yomih/metrics/<match_id>.json`:

- Tier counts: `{LLM_V1: 42, HEURISTIC: 7, SAFE_CONTINUE: 0}`
- Resolution counts: `{submitted: 49, stale_dropped: 3, error: 0}`
- Degradation reason histogram
- Median / p95 / p99 latency per tier
- Total Claude API calls + estimated cost

---

## 16. Security

The bridge talks over a localhost TCP socket. Even though it's
`127.0.0.1`-only, any user-mode process on the same machine can
attempt to connect. Three protections:

### 16.1 Token authentication

On Python start, the bridge generates a 32-byte random token
(`secrets.token_hex(32)`) and writes it to
`%LOCALAPPDATA%/claude_yomih/token` (or `~/.local/share/claude_yomih/token`
on Linux). The file is created with `os.chmod(0o600)` on POSIX; on
Windows, the bridge applies a restrictive ACL via `icacls` or sets
hidden+system attributes (best-effort, Windows local security is
limited).

ERRATUM (live pre-flight, 2026-06-11): **Microsoft Store Python
virtualizes AppData** — files written under `%LOCALAPPDATA%` land in
`%LOCALAPPDATA%/Packages/PythonSoftwareFoundation.…/LocalCache/Local/`
where the game cannot read them, so the handshake would always
`auth_fail`. The bridge detects Store Python (`WindowsApps` in
`sys.executable`) and writes its runtime files to `~/.claude_yomih`
instead (home dirs are not virtualized); the mod probes
`%LOCALAPPDATA%/claude_yomih` first, then `~/.claude_yomih`, then
`user://claude_yomih`. The token-file trust model is unchanged — both
locations are user-owned.

The mod reads the same path and includes the token in the
`hello_auth` frame (§3). If the token doesn't match, the bridge
closes the connection and logs `auth_fail`. The mod surfaces
"Claude bridge auth failed — using heuristic" UX.

### 16.2 PID isolation

The bridge writes its PID to
`%LOCALAPPDATA%/claude_yomih/bridge.pid` on startup. The mod reads it
and checks `OS.execute("tasklist /FI \"PID eq <pid>\"")` (or
`ps -p <pid>` on Linux) to verify the listening process is alive AND
was started by the current user. If the PID belongs to a different
user, the mod refuses to connect and logs `PID_USER_MISMATCH`.

### 16.3 Frame-size cap

`MAX_FRAME_SIZE = 1_048_576` (1 MB) on both sides. A malicious or
buggy peer sending a giant length prefix cannot OOM us — we reject
with `transport_bad_length` before allocating the buffer. Same cap
on our outgoing requests prevents accidentally shipping a 10 MB
legal_moves table.

### 16.4 Rate limit

Bridge enforces max 5 requests/second per connection. The mod
naturally throttles via its `pending_tick` guard (one decision in
flight at a time), so this is a defense against a misbehaving mod
or a malicious client.

### 16.5 Connection lifecycle

One connection per match. New match → new connection (re-handshake).
A crashing/restarting Python process does NOT see request floods
because the mod's bridge probe will not succeed until the new bridge
is fully ready (auth handshake completes).

---

## Verbatim source references

Every claim that hinges on game internals points to the upstream file
and the exact identifier. Pinned commits are in `VALIDATION.md`:
`uzkbwza/hustle@4450348`, `TheanMcGarity/MultiHustleGame@9d0ff28`.

| Claim | File | Identifier |
|-------|------|------------|
| signal we hook | `game.gd` | `signal player_actionable()` |
| submit call | `_AIOpponents/AIController.gd` | `target_player.on_action_selected(queued_action, queued_data, queued_extra)` |
| turn-ready flags | `_AIOpponents/AIController.gd` | `game.turns_taken[id] = true`, `Network.turns_ready[id] = true` |
| start-ghost call | `_AIOpponents/AIController.gd` | `main.call_deferred("_start_ghost")` |
| ghost setup | `_AIOpponents/AIController.gd` | `setup_ghost_game()` (frees prior, reloads `Game.tscn`, copies state) |
| ghost step | `game.gd` | `simulate_one_tick()` |
| ghost snapshot | `game.gd` | `copy_to(game: Game)` |
| ghost-viewport guard | `_AIOpponents/AIController.gd::_ready` | `if game.is_ghost: self.queue_free()` |
| heuristic eval coeffs | `_AIOpponents/AIController.gd` | `FRAMES_TO_SIMULATE = 35`, `FRAME_ADVANTAGE_MODIFIER = 20`, `DAMAGE_MODIFIER = 1`, `DISTANCE_MODIFIER = 0.1`, `SUPER_MODIFIER = -0.5` |
| state-specific modifiers (6 keys) | `_AIOpponents/AIController.gd` | `state_specific_modifiers` dict (`WhiffInstantCancel`, `InstantCancel`, `Roll`, `Burst`, `DefensiveBurst`, `OffensiveBurst`) |
| DI helper | `_AIOpponents/AIController.gd` | `di_as_percentage_int_vec(vec2: Vector2)` |
| legal-moves enumeration | `_AIOpponents/AIController.gd` | `main.find_node("P" + str(2 - id%2) + "ActionButtons")` → `action_buttons.buttons` |
| data-shape pre-enumeration | `_AIOpponents/AIController.gd` | `get_option_data()` → `get_data_structure()` → `split_potential_data()` |
| opponent-modelling pre-step | `_AIOpponents/AIController.gd::make_move` | `choice = get_best_move(temp_extra, target_player.opponent.id, 0.2, difficulty>=2, true, false)` |
| undo race fence | `ReplayManager.gd::undo` | `if resimulating: return` |
| install path | `modloader/ModLoader.gd::_loadMods` | `OS.get_executable_path().get_base_dir().plus_file("mods")` |
| extension API | `modloader/ModLoader.gd` | `installScriptExtension(path)` → `take_over_path` |
| `Network.gd` rejection | `modloader/ModLoader.gd::installScriptExtension` | `if parentScript.resource_path != "res://Network.gd" or ... ModHashCheck...: take_over_path else print "You can't access network!"` |
| `_metadata.id` overwrite | `modloader/ModLoader.gd::_editMetaData` | forced to `"12345"` |
| HP const | `characters/BaseChar.gd` | `MAX_HEALTH = 1500` |
| singleplayer gate | `game.gd::process_tick` | `if game.singleplayer: emit_signal("player_actionable")` / `elif !is_ghost: someones_turn = true` |
| reference AI multiplayer self-neuter | `_AIOpponents/AIController.gd::_ready` | `if Network.multiplayer_active: id = 0; difficulty = 1` |

All other claims reduce to combinations of these.
