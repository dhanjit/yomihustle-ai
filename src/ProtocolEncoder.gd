# claude_yomih/ProtocolEncoder.gd
# DESIGN.md §3 / §7 — wire framing + request payload assembly.
#
# Framing: 4-byte UNSIGNED BIG-ENDIAN length prefix, then UTF-8 JSON body.
# StreamPeerTCP.big_endian defaults to FALSE in Godot 3.5; the socket owner
# (ClaudeController._reconnect) MUST call tcp.set_big_endian(true) right
# after construction. We additionally build the length prefix by hand inside
# one PoolByteArray so a single put_data covers prefix+body (no partial-write
# window) and so this code is correct even if set_big_endian were forgotten.
#
# All functions are static; this script is never instanced. Transport errors
# are returned as the canonical envelope with error_code prefixed "transport_"
# (DESIGN §3) — callers always receive a Dictionary, never null.
extends Reference

const MAX_FRAME_SIZE = 1048576  # 1 MB (DESIGN §16.3)

# ---------------------------------------------------------------------------
# Framing primitives
# ---------------------------------------------------------------------------

static func _transport_error(code):
	return {"ok": false, "outcome": "error", "error_code": code, "schema_version": 1}

static func write_frame(tcp, body_dict):
	# Returns OK / "transport_*" string.
	var body = JSON.print(body_dict).to_utf8()
	if body.size() > MAX_FRAME_SIZE:
		return "transport_oversize_request"
	var framed = PoolByteArray()
	framed.append((body.size() >> 24) & 0xFF)
	framed.append((body.size() >> 16) & 0xFF)
	framed.append((body.size() >> 8) & 0xFF)
	framed.append(body.size() & 0xFF)
	framed.append_array(body)
	if tcp.put_data(framed) != OK:
		return "transport_write_failed"
	return OK

# Reads exactly n bytes with a shared wall-clock deadline (t0 + timeout_ms).
# Returns {"ok": true, "bytes": PoolByteArray} or {"ok": false, "error_code": ...}.
# get_partial_data poll loop instead of blocking get_data so we can enforce
# the deadline and survive partial frames (DESIGN §7).
static func _read_exact(tcp, n, t0, timeout_ms):
	var buf = PoolByteArray()
	while buf.size() < n:
		if OS.get_ticks_msec() - t0 > timeout_ms:
			return {"ok": false, "error_code": "transport_read_timeout"}
		var avail = tcp.get_available_bytes()
		if avail > 0:
			var pkt = tcp.get_partial_data(int(min(avail, n - buf.size())))
			if pkt[0] != OK:
				return {"ok": false, "error_code": "transport_body_read"}
			buf.append_array(pkt[1])
		elif tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			# Drain buffered bytes before declaring the peer dead — Windows
			# can report disconnected while response bytes are still queued.
			return {"ok": false, "error_code": "transport_body_read"}
		else:
			OS.delay_msec(2)
	return {"ok": true, "bytes": buf}

# Reads one length-prefixed JSON frame. Returns the parsed Dictionary or a
# transport error envelope.
static func read_frame(tcp, timeout_ms):
	var t0 = OS.get_ticks_msec()
	var len_res = _read_exact(tcp, 4, t0, timeout_ms)
	if not len_res.ok:
		var code = len_res.error_code
		if code == "transport_body_read":
			code = "transport_len_read"
		return _transport_error(code)
	var len_buf = len_res.bytes
	# Big-endian unsigned decode by hand (independent of tcp.big_endian).
	var msg_len = (int(len_buf[0]) << 24) \
			| (int(len_buf[1]) << 16) \
			| (int(len_buf[2]) << 8) \
			| int(len_buf[3])
	# Bounds check: guards against a malformed prefix and against OOM from a
	# giant prefix (DESIGN §16.3).
	if msg_len <= 0 or msg_len > MAX_FRAME_SIZE:
		tcp.disconnect_from_host()
		return _transport_error("transport_bad_length")
	var body_res = _read_exact(tcp, msg_len, t0, timeout_ms)
	if not body_res.ok:
		if body_res.error_code == "transport_read_timeout":
			tcp.disconnect_from_host()
		return _transport_error(body_res.error_code)
	var parsed = JSON.parse(body_res.bytes.get_string_from_utf8())
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		return _transport_error("transport_json_parse")
	return parsed.result

# One request/response roundtrip on an already-connected socket.
# Returns the canonical envelope (DESIGN §3) — upstream's on success, a
# synthesized transport_* envelope on failure.
static func send_and_recv(tcp, payload, read_timeout_ms):
	if tcp == null or tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return _transport_error("transport_no_connect")
	var werr = write_frame(tcp, payload)
	if werr != OK:
		return _transport_error(werr)
	var raw = read_frame(tcp, read_timeout_ms)
	if raw.has("ok") and raw.get("outcome", "") == "error":
		var code = str(raw.get("error_code", ""))
		# A timed-out or mis-parsed stream is desynced mid-frame; drop the
		# connection so the next decision reconnects cleanly instead of
		# reading a stale half-frame.
		if code == "transport_read_timeout" or code == "transport_json_parse":
			tcp.disconnect_from_host()
	return raw

# Hello / auth handshake (DESIGN §3 + §16.1). Returns true when the bridge
# answered hello_ack with a supported schema, accepted our token, and sent the
# single 0x01 ready byte. auth_token is the contents of
# %LOCALAPPDATA%/claude_yomih/token ("" when unreadable — bridge will reject).
static func do_handshake(tcp, mod_version, auth_token, timeout_ms):
	var werr = write_frame(tcp, {
		"type": "hello",
		"mod_version": mod_version,
		"schema_versions_supported": [1],
	})
	if werr != OK:
		return false
	var ack = read_frame(tcp, timeout_ms)
	if ack.get("outcome", "") == "error":
		return false
	if ack.get("type", "") != "hello_ack" or int(ack.get("schema_version_selected", -1)) != 1:
		push_warning("claude_yomih: PROTO_INCOMPAT — hello_ack %s" % JSON.print(ack))
		return false
	if write_frame(tcp, {"type": "hello_auth", "auth_token": auth_token}) != OK:
		return false
	var t0 = OS.get_ticks_msec()
	var ready = _read_exact(tcp, 1, t0, timeout_ms)
	if not ready.ok or ready.bytes[0] != 0x01:
		push_warning("claude_yomih: AUTH_FAIL — bridge did not send ready byte")
		return false
	return true

# ---------------------------------------------------------------------------
# Payload assembly (DESIGN §3.1 / §3.5 / §10)
# ---------------------------------------------------------------------------

# Fixed-point passthrough: hp/meter/positions are ints, but di_scaling and
# some velocity values are fixed-point STRINGS ("1.0", "6.0") in game state.
# Anything that is already a String stays a String — never coerce to float.
static func _passthrough(v):
	return v

static func _state_name_of(player):
	var cs = player.current_state()
	if cs == null:
		return "?"
	# StateInterface: onready var state_name = name. DESIGN §3.5 says
	# get_class(), but upstream defines no get_class override — the node name
	# (== state_name) is the real action identifier (cf. ActionButtons.gd
	# fighter.current_state().name). Grounded deviation.
	if cs.get("state_name") != null:
		return str(cs.state_name)
	return str(cs.name)

static func _char_name_of(game, player):
	var md = game.match_data
	if md != null and md.has("selected_characters") and md.selected_characters.has(player.id):
		var sc = md.selected_characters[player.id]
		if sc is Dictionary and sc.has("name"):
			return str(sc["name"])
	return str(player.name)

static func snapshot_fighter(game, player):
	var opp = player.opponent
	var pos = player.get_pos()
	return {
		# Field names mirror BaseChar.gd members one-to-one (DESIGN §3.1).
		"id": player.id,
		"character_name": _char_name_of(game, player),
		"hp": int(player.hp),
		"max_hp": int(player.MAX_HEALTH),
		"super_meter": int(player.super_meter),
		"max_super_meter": int(player.MAX_SUPER_METER),
		"bursts_available": int(player.bursts_available),
		"air_options_left": int(player.air_movements_left),
		"position_x": _passthrough(pos.x),
		"position_y": _passthrough(pos.y),
		"facing": player.get_facing_int(),
		"current_state": _state_name_of(player),
		"state_interruptable": bool(player.state_interruptable),
		"combo_count": int(player.combo_count),
		"combo_damage": int(player.combo_damage),
		"combo_proration": _passthrough(player.combo_proration),
		# eval_move semantics: "I am being hit" == my opponent's combo counter
		# is running (AIController.gd: evaluee_is_hit = opponent.combo_count > 0).
		"in_hitstun": opp != null and opp.combo_count > 0,
		"feints": int(player.feints),
		"penalty": int(player.penalty),
	}

static func snapshot_state(game, target_player):
	var opp = target_player.opponent
	var sp = target_player.get_pos()
	var op = opp.get_pos()
	# Reference formula is euclidean (AIController.gd inline dist); ship the
	# axis split too so Claude doesn't reverse-engineer it (DESIGN §3.5).
	var distance = sqrt(pow(op.x - sp.x, 2) + pow(op.y - sp.y, 2))
	return {
		"self": snapshot_fighter(game, target_player),
		"opponent": snapshot_fighter(game, opp),
		"game": {
			"current_tick": int(game.current_tick),
			"time_left": int(game.get_ticks_left()),
			"stage_width": int(game.stage_width),
			"super_active": bool(game.super_active),
			"distance": distance,
			"distance_x": abs(op.x - sp.x),
			"distance_y": abs(op.y - sp.y),
		},
	}

# choice is the heuristic's {action, data, eval, feint}; rename eval →
# eval_score to keep wire and code distinct (DESIGN §3.1 note).
static func build_predicted_opponent(choice):
	if choice == null or not (choice is Dictionary) or not choice.has("action"):
		return {"action_name": "Continue", "data": null, "eval_score": 0.0, "source": "fallback_continue"}
	return {
		"action_name": choice.action,
		"data": choice.data,
		"eval_score": float(choice.get("eval", 0.0)),
		"source": "heuristic_get_best_move",
	}

# Strip enumerator-internal keys (leading "_") from legal_moves entries.
static func clean_legal_moves(legal_moves):
	var out = []
	for entry in legal_moves:
		var clean = {}
		for k in entry.keys():
			if not str(k).begins_with("_"):
				clean[k] = entry[k]
		out.append(clean)
	return out

static func character_info(game, target_player):
	var game_version = str(Global.get("VERSION")) if Global.get("VERSION") != null else "unknown"
	return {
		"self_moves_cached_prompt_id": "%s@yomih-%s" % [_char_name_of(game, target_player).to_lower(), game_version],
		"opponent_moves_cached_prompt_id": "%s@yomih-%s" % [_char_name_of(game, target_player.opponent).to_lower(), game_version],
	}

static func build_common(ctx):
	# ctx: {game, target_player, match_id, round_number, round_score_self,
	#       round_score_opponent, tick, mode, predicted_opponent, recent_history}
	return {
		"schema_version": 1,
		"match_id": ctx.match_id,
		"round_number": ctx.round_number,
		"round_score_self": ctx.round_score_self,
		"round_score_opponent": ctx.round_score_opponent,
		"tick": ctx.tick,
		"mode": ctx.mode,
		"state": snapshot_state(ctx.game, ctx.target_player),
		"predicted_opponent": ctx.predicted_opponent,
		"recent_history": ctx.recent_history,
		"character_info": character_info(ctx.game, ctx.target_player),
	}

static func build_v1_payload(ctx, legal_moves):
	var payload = build_common(ctx)
	payload["legal_moves"] = clean_legal_moves(legal_moves)
	return payload

static func build_v0_payload(ctx, visible_categories):
	var payload = build_common(ctx)
	payload["visible_categories"] = visible_categories
	return payload
