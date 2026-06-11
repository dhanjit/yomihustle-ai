# claude_yomih/ProtocolDecoder.gd
# DESIGN.md §3.2 / §3.3 / §9.4 / §11 — response validation + choice decoding.
# All functions are static; this script is never instanced.
extends Reference

const RANKED_WALK_CAP = 5    # hard-cap validation to the first 5 entries (§3.2)
const RANKED_REJECT_OVER = 50  # len(ranked) > 50 → ranked_cardinality (§3.2)
const UNION_CLAUDE_K = 3     # at most 3 Claude candidates enter the union pool

# ---------------------------------------------------------------------------
# Envelope validation. Returns null when the envelope is a usable Tier-1
# input for `mode`, else a degradation_reason string from the §9.2 taxonomy.
# ---------------------------------------------------------------------------
static func envelope_degradation(raw, mode):
	if not (raw is Dictionary) or not raw.has("ok"):
		return "transport_json_parse"
	if not raw.ok or raw.get("outcome", "error") == "error":
		return str(raw.get("error_code", "transport_unknown"))
	if int(raw.get("schema_version", -1)) != 1:
		return "schema_mismatch"
	if raw.outcome == "ranked" and mode != "v1":
		return "mode_mismatch"
	if raw.outcome == "category" and mode != "v0":
		return "mode_mismatch"
	if not (raw.get("response") is Dictionary):
		return "parse_error"
	return null

# ---------------------------------------------------------------------------
# legal_moves lookup. legal_moves entries were deduped by
# (action_name, frozen(data_options)) at enumeration time, so action_name is
# a unique key here (§3.1 data_index reference semantics).
# ---------------------------------------------------------------------------
static func find_in_legal_moves(legal_moves, action_name):
	for entry in legal_moves:
		if entry.action_name == action_name:
			return entry
	return null

# Resolve the data payload for (entry, data_index). The enumerator keeps the
# real submit values (including null for "no data UI") in _internal_options,
# parallel to the JSON-friendly data_options shown to Claude.
static func resolve_data(entry, data_index):
	if entry.has("_internal_options"):
		return entry._internal_options[data_index]
	return entry.data_options[data_index]

# ---------------------------------------------------------------------------
# v1: walk response.ranked, collect every candidate that validates against the
# legal set (capped to the first RANKED_WALK_CAP entries, at most
# UNION_CLAUDE_K collected). Returns:
#   {"candidates": [{action_name, data, data_index, reason, source:"claude"}...],
#    "degradation_reason": null | "empty_ranked" | "ranked_cardinality" |
#                          "parse_error" | "all_invalid"}
# candidates[0] is the §6 "first valid" pick for the no-ghost-eval path.
# ---------------------------------------------------------------------------
static func collect_ranked_candidates(resp, legal_moves):
	var out = {"candidates": [], "degradation_reason": null}
	if not (resp.has("ranked") and resp.ranked is Array):
		out.degradation_reason = "parse_error"
		return out
	if resp.ranked.size() == 0:
		out.degradation_reason = "empty_ranked"
		return out
	if resp.ranked.size() > RANKED_REJECT_OVER:
		out.degradation_reason = "ranked_cardinality"
		return out
	var walk = int(min(RANKED_WALK_CAP, resp.ranked.size()))
	for i in range(walk):
		if out.candidates.size() >= UNION_CLAUDE_K:
			break
		var ranked = resp.ranked[i]
		if not (ranked is Dictionary) or not ranked.has("action_name"):
			continue
		var legal_entry = find_in_legal_moves(legal_moves, ranked.action_name)
		if legal_entry == null:
			continue
		# JSON numbers parse as float in Godot 3 — coerce before bounds check.
		var data_index = int(ranked.get("data_index", -1))
		if data_index < 0 or data_index >= legal_entry.data_options.size():
			continue
		out.candidates.append({
			"action_name": ranked.action_name,
			"data": resolve_data(legal_entry, data_index),
			"data_index": data_index,
			"reason": str(ranked.get("reason", "")),
			"source": "claude",
		})
	if out.candidates.size() == 0:
		out.degradation_reason = "all_invalid"
	return out

# ---------------------------------------------------------------------------
# v0: category string → CharacterState.ActionType index, or -1.
# NB: upstream's global class is CharacterState (characters/states/CharState.gd
# declares `class_name CharacterState`); DESIGN's "CharState" identifier does
# not exist in source.
# ---------------------------------------------------------------------------
static func category_to_action_type(category_name):
	var keys = CharacterState.ActionType.keys()
	for i in range(keys.size()):
		if keys[i] == category_name:
			return i
	return -1

# ---------------------------------------------------------------------------
# DI override decode (DESIGN §11). Returns a normalized Vector2 direction, or
# null for unknown/non-string values (dropped silently per §3.2).
# `away` is the default away-from-opponent unit vector (reference AI formula);
# screen up is -y. "opponent-corner" = horizontally toward the wall behind the
# opponent, i.e. the horizontal component of "toward".
# ---------------------------------------------------------------------------
static func decode_di_string(name, away):
	if typeof(name) != TYPE_STRING:
		return null
	var toward = -away
	match name:
		"neutral":
			return Vector2(0, 0)
		"away":
			return away
		"toward":
			return toward
		"up":
			return Vector2(0, -1)
		"opponent-corner":
			var x = 1.0 if toward.x >= 0 else -1.0
			return Vector2(x, 0)
		"up-left":
			return Vector2(-1, -1).normalized()
		"up-right":
			return Vector2(1, -1).normalized()
		"down-left":
			return Vector2(-1, 1).normalized()
		"down-right":
			return Vector2(1, 1).normalized()
	return null
