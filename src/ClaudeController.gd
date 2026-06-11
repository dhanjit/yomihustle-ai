# claude_yomih/ClaudeController.gd
# DESIGN.md §5.4 (lifecycle), §6 (per-turn flow), §7 (threading + stale
# guards), §9 (tiers + degradation taxonomy), §10 (v0), §11 (DI).
#
# Threading contract (§7):
#   * The TCP roundtrip runs on a Godot Thread; the result returns to the
#     main thread via call_deferred("_apply_choice", ...). The main thread is
#     NEVER blocked on the bridge.
#   * Thread.wait_to_finish() is ALWAYS the first thing _apply_choice does,
#     regardless of stale outcome (leak prevention, §7.2).
#   * ReplayManager.resimulating is set ONLY around synchronous ghost-eval
#     sections (heuristic passes, union-pool eval) — NEVER around the TCP
#     window (§7.1 / audit fix #9). Stale responses are caught by the
#     request_id / resimulating / tick / state-hash guard chain instead.
extends Node2D

# Single source of truth for the mod folder (§12.6). The build ZIP's
# subfolder MUST equal _metadata.name ("claude_yomih"); res:// paths inside
# the mounted zip resolve under this root.
const MOD_ROOT = "res://claude_yomih"
const MOD_VERSION = "0.1.0"
const DEFAULT_PORT = 8765

const CONNECT_TIMEOUT_MS = 2000   # §9.1
const READ_TIMEOUT_MS = 8000      # §9.1 — Python's 6s Claude budget + 2s slack
const HANDSHAKE_TIMEOUT_MS = 3000
const REPROBE_INTERVAL_S = 30     # §9.3

# ModOptions "mode" dropdown index → mode name (index 0 is the default
# selection, so a fresh install runs v1 — DESIGN §6 default).
const MODE_NAMES = ["v1", "v0", "v_none"]

var PE = null  # ProtocolEncoder script (static funcs)
var PD = null  # ProtocolDecoder script (static funcs)

var target_player = null
var id = -1
var game = null
var main = null
var heuristic = null          # HeuristicShim (plain Object, NOT in tree — §5.4)
var enumerator = null         # LegalMoveEnumerator (Reference)
var tcp = null                # StreamPeerTCP, persistent per match
var decision_thread = null    # Thread (one in flight max)
var probe_thread = null       # Thread for the bridge probe
var reprobe_timer = null      # Timer child, §9.3

# Per-decision context (§6): everything _apply_choice needs lives here —
# the handler and the deferred callback are different stack frames.
var pending = {}
var pending_tick = -1
var request_id_counter = 0    # monotonic; stale guard #1
var bridge_ready = false
var bridge_port = DEFAULT_PORT

var match_id = ""
var recent_history = []       # ring buffer, last 8 actionable turns (§3.1)
var last_claude_actions = []  # Claude prior K≤3 for next turn's UNION (§6)

var current_mode = "v1"
var ghost_verify = true       # union-pool ghost-eval (audit fix #10)
# §8 ghost-determinism one-shot: checked lazily before the first sticky-ghost
# eval of the session (not at _ready — the sticky ghost needs a fully started
# match to copy from). A failed check latches ghost_verify off for the whole
# session; _read_options must not re-enable it.
var ghost_determinism_checked = false
var ghost_verify_forced_off = false
# CharacterState.ActionType.Hurt == 5 (CharState.gd: Movement=0..Defense=4,
# Hurt=5). Re-cached from the enum in _ready; the literal must stay 5 so the
# DI hitstun gate cannot silently regress to Defense(4) if that line is lost.
var action_type_hurt = 5
var _modoptions_warned = false
# §9.3 persistent HUD indicator, visible while the bridge is unreachable.
var offline_label = null

# ---------------------------------------------------------------------------
# Lifecycle (§5.4)
# ---------------------------------------------------------------------------

func _ready():
	game = get_parent()
	if game.is_ghost:
		# Critical guard, FIRST — before any socket/thread/heuristic setup.
		# Without it this controller gets instantiated inside the ghost game
		# during lookahead and recursively opens sockets / calls Python.
		queue_free()
		return

	main = find_parent("Main")
	if main == null:
		push_warning("ClaudeController: no Main parent found; refusing to attach.")
		queue_free()
		return

	if Network.multiplayer_active:
		# player_actionable shouldn't fire in multiplayer (§1), but bail
		# loudly so we don't leak signal connections.
		queue_free()
		return

	if main.has_method("MultiHustle_AddData"):
		push_warning("Claude controller refusing to attach: MultiHustle present (v1 scope).")
		queue_free()
		return

	id = _derive_controlled_id()
	if id < 1:
		push_warning("ClaudeController: could not derive controlled id; refusing to attach.")
		queue_free()
		return
	target_player = game.get_player(id)
	if target_player == null:
		push_warning("ClaudeController: no player at slot %d; refusing to attach." % id)
		queue_free()
		return

	action_type_hurt = CharacterState.ActionType.Hurt

	PE = load(MOD_ROOT + "/ProtocolEncoder.gd")
	PD = load(MOD_ROOT + "/ProtocolDecoder.gd")

	# Heuristic shim + enumerator are composition-only: NEVER add_child —
	# the vendored AIController machinery must not self-install as a
	# player_actionable driver (§5.4 / §8).
	heuristic = load(MOD_ROOT + "/HeuristicShim.gd").new()
	enumerator = load(MOD_ROOT + "/LegalMoveEnumerator.gd").new()
	enumerator.attach(game, main, id, heuristic, self)
	heuristic.attach(game, main, id, enumerator)

	randomize()
	match_id = "%08x-%04x-%d" % [randi(), randi() % 0x10000, OS.get_unix_time()]

	_read_options()

	game.connect("player_actionable", self, "_start_decision_thread")

	reprobe_timer = Timer.new()
	reprobe_timer.one_shot = true
	add_child(reprobe_timer)
	reprobe_timer.connect("timeout", self, "_spawn_bridge_probe")

	_setup_offline_hud()

	# Eager bridge probe (§9.3): persistent TCP + hello/auth handshake on a
	# worker thread. While offline, every decision skips TCP and goes
	# straight to Tier 2; we re-probe every 30s.
	_spawn_bridge_probe()

func _exit_tree():
	if game != null and is_instance_valid(game) \
			and game.is_connected("player_actionable", self, "_start_decision_thread"):
		game.disconnect("player_actionable", self, "_start_decision_thread")
	# Join workers FIRST, then touch the socket. StreamPeerTCP is not
	# thread-safe: disconnecting here while a worker is inside put_data /
	# get_partial_data / get_status (or while _reconnect reassigns self.tcp
	# off-thread) is a real crash window. Workers are self-terminating — every
	# socket loop runs under a wall-clock deadline (CONNECT 2s / HANDSHAKE 3s /
	# READ 8s) — so the worst-case teardown stall is ~READ_TIMEOUT_MS when
	# quitting mid-decision; the common case is instant.
	if decision_thread != null and decision_thread.is_active():
		decision_thread.wait_to_finish()
	decision_thread = null
	if probe_thread != null and probe_thread.is_active():
		probe_thread.wait_to_finish()
	probe_thread = null
	if tcp != null:
		tcp.disconnect_from_host()
		tcp = null
	if heuristic != null:
		heuristic.teardown()  # frees both ghost lifecycles (§8)
		heuristic.free()      # plain Object — manual free (§5.4)
		heuristic = null

# v1 controls whichever side is non-human; ModOptions can pin a slot.
# "Auto" resolves to id=2: vanilla upstream exposes no readable "which side
# is human" flag (no is_human property exists anywhere — verified by grep),
# so auto-detection is impossible and DESIGN §5.4 documents the P2 default.
# Only the ModOptions "Claude player" dropdown can drive P1.
func _derive_controlled_id():
	var slot = int(_opt_num("target_player", 0))
	if slot == 1 or slot == 2:
		return slot
	return 2

# ---------------------------------------------------------------------------
# Options / environment
# ---------------------------------------------------------------------------

func _opt(key, default_value):
	if main == null:
		return default_value
	var mo = main.get_node_or_null("ModOptions")
	if mo == null or not mo.has_method("get_setting"):
		if not _modoptions_warned:
			_modoptions_warned = true
			push_warning("claude_yomih: SoupModOptions absent — defaulting mode=v1, port=%d." % DEFAULT_PORT)
		return default_value
	var v = mo.get_setting("claude_yomih", key)
	if v == null:
		return default_value
	return v

func _opt_num(key, default_value):
	var v = _opt(key, default_value)
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_REAL or typeof(v) == TYPE_BOOL:
		return float(v)
	return float(default_value)

func _read_options():
	var mode_idx = int(_opt_num("mode", 0))
	current_mode = MODE_NAMES[mode_idx] if mode_idx >= 0 and mode_idx < MODE_NAMES.size() else "v1"
	if bool(_opt("fallback_only", false)):
		current_mode = "v_none"
	ghost_verify = not bool(_opt("disable_ghost_verify", false))
	if ghost_verify_forced_off:
		ghost_verify = false  # GHOST_NONDETERMINISTIC latch (§8) wins over options
	if heuristic != null:
		heuristic.fix_frame_adv_divisor = bool(_opt("fix_frame_adv", false))
	var file_port = _read_port_file()
	if file_port > 0:
		bridge_port = file_port
	else:
		var opt_port = int(_opt_num("port", DEFAULT_PORT))
		bridge_port = opt_port if opt_port >= 1024 and opt_port <= 65535 else DEFAULT_PORT

# Bridge drops its chosen port / auth token under %LOCALAPPDATA%/claude_yomih
# (§12.5 / §16.1). Falls back to OS user data dir off Windows.
# Runtime-file rendezvous, in probe order. The bridge writes to
# %LOCALAPPDATA%/claude_yomih normally, but under Microsoft Store Python
# (which virtualizes AppData into its package sandbox) it falls back to
# ~/.claude_yomih — so the mod must probe both.
func _runtime_paths(fname):
	var paths = []
	var local = OS.get_environment("LOCALAPPDATA")
	if local != "":
		paths.append(local.plus_file("claude_yomih").plus_file(fname))
	var home = OS.get_environment("USERPROFILE")
	if home == "":
		home = OS.get_environment("HOME")
	if home != "":
		paths.append(home.plus_file(".claude_yomih").plus_file(fname))
	paths.append(OS.get_user_data_dir().plus_file("claude_yomih").plus_file(fname))
	return paths

func _read_runtime_file(fname):
	var f = File.new()
	for path in _runtime_paths(fname):
		if f.open(path, File.READ) == OK:
			var txt = f.get_as_text().strip_edges()
			f.close()
			return txt
	return ""

func _read_port_file():
	var txt = _read_runtime_file("port")
	if txt.is_valid_integer():
		var p = int(txt)
		if p >= 1024 and p <= 65535:
			return p
	return -1

func _read_token():
	return _read_runtime_file("token")

# ---------------------------------------------------------------------------
# Bridge probe + socket (§7 / §9.3)
# ---------------------------------------------------------------------------

func _spawn_bridge_probe():
	if bridge_ready:
		return
	if probe_thread != null and probe_thread.is_active():
		return
	if decision_thread != null and decision_thread.is_active():
		# Never two threads on one socket; retry shortly.
		reprobe_timer.start(2)
		return
	probe_thread = Thread.new()
	probe_thread.start(self, "_probe_off_thread", null)

func _probe_off_thread(_userdata):
	var ok = _reconnect()
	call_deferred("_probe_done", ok)

func _probe_done(ok):
	if probe_thread != null and probe_thread.is_active():
		probe_thread.wait_to_finish()
	probe_thread = null
	bridge_ready = ok
	_update_offline_hud()
	if ok:
		_log_line("[match=%s] BRIDGE_READY port=%d" % [match_id, bridge_port])
	else:
		_log_line("[match=%s] BRIDGE_OFFLINE port=%d — using heuristic; re-probing in %ds" % [match_id, bridge_port, REPROBE_INTERVAL_S])
		reprobe_timer.start(REPROBE_INTERVAL_S)

# §9.3: small persistent HUD line so the user can tell heuristic-only play
# from Claude play. The Label (not the CanvasLayer) is toggled because
# CanvasLayer has no `visible` property in Godot 3.5. Shown from creation
# until the first successful probe — during that window decisions really
# are heuristic-only.
func _setup_offline_hud():
	var layer = CanvasLayer.new()
	layer.layer = 100
	offline_label = Label.new()
	offline_label.text = "Claude bridge offline — using heuristic"
	offline_label.modulate = Color("ffcc66")
	offline_label.margin_left = 4
	offline_label.margin_top = 4
	layer.add_child(offline_label)
	add_child(layer)
	_update_offline_hud()

func _update_offline_hud():
	if offline_label != null and is_instance_valid(offline_label):
		offline_label.visible = not bridge_ready

# Runs on worker threads (probe + decision). Full reconnect: socket,
# non-blocking connect poll, hello/auth handshake.
func _reconnect():
	if tcp != null:
		tcp.disconnect_from_host()
	tcp = StreamPeerTCP.new()
	tcp.set_no_delay(true)
	tcp.set_big_endian(true)  # CRITICAL: Godot 3.5 default is little-endian (§3)
	if tcp.connect_to_host("127.0.0.1", bridge_port) != OK:
		return false
	# connect_to_host is non-blocking — poll get_status with a wall clock
	# (OS-level TCP timeout is 21-75s on Windows; we cap at 2s).
	var t0 = OS.get_ticks_msec()
	while tcp.get_status() == StreamPeerTCP.STATUS_CONNECTING:
		if OS.get_ticks_msec() - t0 > CONNECT_TIMEOUT_MS:
			tcp.disconnect_from_host()
			return false
		OS.delay_msec(5)
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return false
	return PE.do_handshake(tcp, MOD_VERSION, _read_token(), HANDSHAKE_TIMEOUT_MS)

# ---------------------------------------------------------------------------
# Per-turn flow — main thread, synchronous, fast (§6)
# ---------------------------------------------------------------------------

func _start_decision_thread():
	if pending_tick != -1:
		# game.gd's paused turn-boundary block emits player_actionable once
		# for the p1 branch and again for the p2 branch on consecutive frames
		# of the SAME paused tick — the second emission is normal every turn.
		# Only a different tick while pending is a genuine anomaly worth a
		# warning; the routine duplicate goes to the debug log.
		if game.current_tick != pending_tick:
			push_warning("Claude: actionable fired while pending (tick %d != pending %d); ignoring." % [game.current_tick, pending_tick])
		else:
			_log_line("[match=%s tick=%d] DUP_ACTIONABLE_IGNORED" % [match_id, pending_tick])
		return
	if Network.multiplayer_active:  # defense-in-depth: can flip mid-session
		return
	if game.is_ghost:
		return
	if target_player == null or not is_instance_valid(target_player):
		target_player = game.get_player(id)
		if target_player == null:
			return

	_read_options()
	pending_tick = game.current_tick
	var t0 = OS.get_ticks_msec()

	# Default DI: away from opponent (reference formula, §11).
	var ai_pos = target_player.get_pos()
	var opp_pos = target_player.opponent.get_pos()
	var away_vec = Vector2(ai_pos.x - opp_pos.x, ai_pos.y - opp_pos.y).normalized()
	var di = heuristic.di_as_percentage_int_vec(away_vec)
	var temp_extra = {"DI": di, "feint": false, "prediction": -1, "reverse": false}

	var action_buttons = main.find_node("P" + str(2 - id % 2) + "ActionButtons")
	if action_buttons == null:
		push_error("ClaudeController: no action buttons for id %d — SAFE_CONTINUE." % id)
		pending_tick = -1
		_submit_action("Continue", null, false, di, "SAFE_CONTINUE", "no_action_buttons", t0, null)
		return

	# Synchronous ghost-eval section: fence undo with resimulating exactly
	# like the reference's make_move does for its own ghost sims (fix #9
	# scope: ghost-eval only — the TCP window below is NOT fenced).
	ReplayManager.resimulating = true

	# Opponent-modelling pre-step (fix #5): heuristic best move for the
	# OPPONENT id; shipped to Claude as predicted_opponent and held fixed
	# for every ghost-eval this turn.
	var predicted_choice = heuristic.opponent_guess(temp_extra)
	if predicted_choice.get("fallback", false):
		_log_line("[match=%s tick=%d] PREDICTED_OPP_FALLBACK_CONTINUE" % [match_id, pending_tick])
	var predicted_opponent = PE.build_predicted_opponent(predicted_choice)

	var legal_moves = []
	var safety_pairs = []
	var heuristic_top1 = null
	if current_mode == "v1":
		# Heuristic top-1 for the UNION pool (fix #10), computed once here
		# and reused as the Tier-2 answer at apply time. Args mirror the
		# DESIGN §6 Tier-2 call (leeway 0.01: deterministic fallback pick).
		heuristic_top1 = heuristic.get_best_move(
			temp_extra, id, 0.01, true, true, true,
			predicted_opponent.action_name, predicted_opponent.data)
		var ensure_pairs = []
		if heuristic_top1 != null and heuristic_top1.get("action") != null:
			ensure_pairs.append({"action": heuristic_top1.action, "data": heuristic_top1.data, "source": "heuristic_top1"})
		for pa in last_claude_actions:  # Claude prior K ≤ 3 (§6 UNION)
			ensure_pairs.append({"action": pa.action, "data": pa.data, "source": "claude_prior"})
		var enum_result = enumerator.enumerate(
			action_buttons, predicted_opponent.action_name, predicted_opponent.data, ensure_pairs)
		legal_moves = enum_result.legal_moves
		safety_pairs = enum_result.safety_pairs

	ReplayManager.resimulating = false

	# Stamp a monotonic request_id and a cheap state hash so the apply path
	# can detect "same tick number, different state" (undo+redo) — §7.1.
	request_id_counter += 1
	var state_hash = _hash_state(target_player, target_player.opponent)

	var ctx = {
		"game": game,
		"target_player": target_player,
		"match_id": match_id,
		"round_number": 1,
		"round_score_self": 0,
		"round_score_opponent": 0,
		"tick": pending_tick,
		"mode": current_mode,
		"predicted_opponent": predicted_opponent,
		"recent_history": recent_history.duplicate(true),
	}
	var payload = null
	if current_mode == "v1":
		payload = PE.build_v1_payload(ctx, legal_moves)
	elif current_mode == "v0":
		payload = PE.build_v0_payload(ctx, _visible_categories(action_buttons))

	# Promote ALL decision context to self.pending — _apply_choice runs in a
	# different stack frame (§6 scope rule).
	pending = {
		"tick": pending_tick,
		"request_id": request_id_counter,
		"state_hash": state_hash,
		"mode": current_mode,
		"temp_extra": temp_extra,
		"di": di,
		"away_vec": away_vec,
		"predicted_opponent": predicted_opponent,
		"legal_moves": legal_moves,
		"safety_pairs": safety_pairs,
		"heuristic_top1": heuristic_top1,
		"action_buttons": action_buttons,
		"t0": t0,
	}

	if current_mode == "v_none":
		call_deferred("_apply_choice",
			{"ok": false, "outcome": "error", "error_code": "mode_v_none", "schema_version": 1},
			request_id_counter)
		return

	if not bridge_ready:
		_log_line("[match=%s tick=%d] BRIDGE_OFFLINE_SKIP" % [match_id, pending_tick])
		call_deferred("_apply_choice",
			{"ok": false, "outcome": "error", "error_code": "transport_bridge_offline", "schema_version": 1},
			request_id_counter)
		return

	decision_thread = Thread.new()
	var thread_err = decision_thread.start(self, "_decide_off_thread",
		{"payload": payload, "request_id": request_id_counter})
	if thread_err != OK:
		# Thread never ran: _apply_choice would never fire and pending_tick
		# would wedge forever. Fall through the tier chain right now with a
		# transport_* envelope (Tier 2/3 resolve synchronously).
		decision_thread = null
		push_warning("claude_yomih: Thread.start failed (%d) — degrading to heuristic." % thread_err)
		call_deferred("_apply_choice",
			{"ok": false, "outcome": "error", "error_code": "transport_thread_start", "schema_version": 1},
			request_id_counter)

# OFF MAIN THREAD (§7): one request/response roundtrip, reconnect once.
func _decide_off_thread(args):
	if tcp == null or tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		if not _reconnect():
			call_deferred("_apply_choice",
				{"ok": false, "outcome": "error", "error_code": "transport_no_connect", "schema_version": 1},
				args.request_id)
			return
	var raw = PE.send_and_recv(tcp, args.payload, READ_TIMEOUT_MS)
	call_deferred("_apply_choice", raw, args.request_id)

# ---------------------------------------------------------------------------
# Apply — BACK ON MAIN THREAD (§6)
# ---------------------------------------------------------------------------

func _apply_choice(raw, request_id):
	# ALWAYS join the worker first, regardless of stale outcome (§7.2).
	if decision_thread != null and decision_thread.is_active():
		decision_thread.wait_to_finish()
	decision_thread = null

	if typeof(raw) != TYPE_DICTIONARY:
		raw = {"ok": false, "outcome": "error", "error_code": "transport_unknown", "schema_version": 1}

	if target_player == null or not is_instance_valid(target_player) \
			or game == null or not is_instance_valid(game):
		_clear_pending()
		return

	# Stale guards (§7.1): (1) request_id, (2) resimulating, (3) tick,
	# (4) state hash. Any hit → drop + maybe_redecide.
	if pending.empty() or request_id != pending.get("request_id", -1):
		_log_line("[match=%s req=%d] tier=- resolution=stale_dropped reason=STALE_REQUEST_ID" % [match_id, request_id])
		return  # pending already moved on; nothing to clear
	if ReplayManager.resimulating:
		_log_line("[match=%s tick=%d req=%d] tier=- resolution=stale_dropped reason=STALE_RESIM" % [match_id, pending.tick, request_id])
		_clear_pending()
		call_deferred("_maybe_redecide")
		return
	if game.current_tick != pending.tick:
		_log_line("[match=%s tick=%d req=%d] tier=- resolution=stale_dropped reason=STALE_TICK now=%d" % [match_id, pending.tick, request_id, game.current_tick])
		_clear_pending()
		call_deferred("_maybe_redecide")
		return
	if _hash_state(target_player, target_player.opponent) != pending.state_hash:
		_log_line("[match=%s tick=%d req=%d] tier=- resolution=stale_dropped reason=STALE_STATE_HASH" % [match_id, pending.tick, request_id])
		_clear_pending()
		call_deferred("_maybe_redecide")
		return

	var mode = pending.mode
	var temp_extra = pending.temp_extra
	var di = pending.di
	var predicted_opponent = pending.predicted_opponent
	var legal_moves = pending.legal_moves
	var t0 = pending.t0

	# Bridge health bookkeeping: a transport failure mid-match flips us back
	# into offline+reprobe mode (§9.3).
	var raw_error_code = str(raw.get("error_code", ""))
	if (not raw.get("ok", false)) and raw_error_code.begins_with("transport_") \
			and raw_error_code != "transport_bridge_offline":
		bridge_ready = false
		reprobe_timer.start(REPROBE_INTERVAL_S)
		_update_offline_hud()

	var action_name = null
	var data = null
	var feint = false
	var action_tier = null
	var degradation_reason = null
	var union_source = ""

	if mode == "v_none":
		pass  # heuristic by design; not a degradation
	else:
		degradation_reason = PD.envelope_degradation(raw, mode)

	# ----- TIER 1: Claude LLM -----
	if mode != "v_none" and degradation_reason == null:
		var resp = raw.response
		if mode == "v0":
			# v0 (§10): category → heuristic best within that category.
			# Single call — _heuristic_topk_for_category is expensive.
			var enum_idx = PD.category_to_action_type(str(resp.get("category", "")))
			if enum_idx < 0:
				degradation_reason = "v0_filter_empty"
			else:
				ReplayManager.resimulating = true
				var best = _heuristic_topk_for_category(enum_idx)
				ReplayManager.resimulating = false
				if best != null and best.action != null:
					action_name = best.action
					data = best.data
					feint = bool(best.get("feint", false)) and target_player.feints > 0
					action_tier = "LLM_V0"
				else:
					degradation_reason = "v0_filter_empty"
		else:
			# v1: walk ranked (capped 5), collect ≤3 valid candidates.
			var collected = PD.collect_ranked_candidates(resp, legal_moves)
			if collected.degradation_reason != null:
				degradation_reason = collected.degradation_reason
			else:
				last_claude_actions = []
				for c in collected.candidates:
					last_claude_actions.append({"action": c.action_name, "data": c.data})
				var winner = null
				if ghost_verify:
					# UNION pool ghost-eval (fix #10): heuristic top-1 +
					# safety set + Claude's K≤3, all scored on the sticky
					# ghost against the SAME predicted opponent move.
					winner = _select_via_union(collected.candidates)
				if winner != null:
					action_name = winner.action
					data = winner.data
					union_source = winner.source
					if winner.source == "claude":
						action_tier = "LLM_V1"
						feint = bool(resp.get("feint", false)) and target_player.feints > 0
					else:
						# Ghost-eval outranked every Claude candidate.
						action_tier = "HEURISTIC"
						degradation_reason = "union_outranked"
						feint = bool(winner.get("feint", false)) and target_player.feints > 0
				else:
					# Union disabled or eval budget blown: DESIGN §6 v1
					# path — first valid ranked entry.
					var first = collected.candidates[0]
					action_name = first.action_name
					data = first.data
					feint = bool(resp.get("feint", false)) and target_player.feints > 0
					action_tier = "LLM_V1"

	# ----- TIER 2: heuristic top-1 -----
	if action_name == null:
		var h = pending.get("heuristic_top1")
		if h == null and heuristic != null:
			ReplayManager.resimulating = true
			h = heuristic.get_best_move(
				temp_extra, id, 0.01, true, true, true,
				predicted_opponent.action_name, predicted_opponent.data)
			ReplayManager.resimulating = false
		if h != null and h.get("action") != null:
			action_name = h.action
			data = h.data
			feint = bool(h.get("feint", false)) and target_player.feints > 0
			action_tier = "HEURISTIC"

	# ----- TIER 3: minimal-safe Continue -----
	if action_name == null:
		action_name = "Continue"
		data = null
		feint = false
		action_tier = "SAFE_CONTINUE"
		if degradation_reason == null:
			degradation_reason = raw_error_code if raw_error_code != "" else "heuristic_failed"

	# ----- DI (§11): default away; Claude override only in hitstun -----
	var final_di = di
	if raw.get("ok", false) and raw.get("outcome", "") != "error" \
			and raw.get("response") is Dictionary \
			and raw.response.get("di_override") != null \
			and target_player.current_state() != null \
			and int(target_player.current_state().type) == action_type_hurt:
		var override_vec = PD.decode_di_string(raw.response.di_override, pending.away_vec)
		if override_vec != null:
			final_di = heuristic.di_as_percentage_int_vec(override_vec)

	var latency_ms = OS.get_ticks_msec() - t0
	var snapshot = {
		"tick": pending.tick,
		"request_id": request_id,
		"mode": mode,
		"tier": action_tier,
		"degradation_reason": degradation_reason,
		"union_source": union_source,
		"action": action_name,
		"data": data,
		"predicted_opponent": predicted_opponent,
		"legal_move_names": _legal_move_names(legal_moves),
		"response": raw,
		"latency_ms": latency_ms,
	}

	_log_line("[match=%s tick=%d req=%d] tier=%s resolution=submitted reason=%s latency_ms=%d action=%s predicted_opp=%s" % [
		match_id, pending.tick, request_id, action_tier,
		str(degradation_reason) if degradation_reason != null else "-",
		latency_ms, action_name, predicted_opponent.action_name])
	_write_snapshot(pending.tick, snapshot)

	_push_history(pending.tick, action_name)
	_clear_pending()
	_submit(action_name, data, feint, final_di)

# The submit path — verbatim reference sequence (§6 / verbatim refs table):
# queued_* → on_action_selected → turns_taken/turns_ready → _start_ghost.
func _submit(action_name, data, feint, final_di):
	var extra = {
		"DI": final_di,
		"feint": (feint if target_player.feints > 0 else false),  # §11 feint guard
		"prediction": -1,
		"reverse": false,
	}
	target_player.queued_action = action_name
	target_player.queued_data = data
	target_player.queued_extra = extra
	target_player.on_action_selected(action_name, data, extra)
	# turns_taken is a MultiHustleGame game.gd addition; guard for vanilla.
	if game.get("turns_taken") != null:
		game.turns_taken[target_player.id] = true
	# No-op in singleplayer (Network not authoritative) — kept for parity
	# with AIController.make_move.
	Network.turns_ready[target_player.id] = true
	main.call_deferred("_start_ghost")

# Direct-submit edge path (no pending decision context).
func _submit_action(action_name, data, feint, di, tier, reason, t0, _raw):
	_log_line("[match=%s tick=%d] tier=%s resolution=submitted reason=%s latency_ms=%d action=%s" % [
		match_id, game.current_tick, tier, reason, OS.get_ticks_msec() - t0, action_name])
	_push_history(game.current_tick, action_name)
	_submit(action_name, data, feint, di)

func _clear_pending():
	pending = {}
	pending_tick = -1

# After a stale drop the game has rewound or diverged. process_tick re-emits
# player_actionable on the next state transition; this is the safety net for
# "undo landed us exactly back at an actionable boundary with no new edge."
func _maybe_redecide():
	if pending_tick != -1:
		return  # someone already started a new decision
	if target_player == null or not is_instance_valid(target_player):
		return
	if game.get("turns_taken") != null and game.turns_taken.get(target_player.id, false):
		return  # turn already resolved
	if not target_player.state_interruptable:
		return  # game will re-emit naturally
	call_deferred("_start_decision_thread")

# ---------------------------------------------------------------------------
# Union-pool selection (audit fix #10)
# ---------------------------------------------------------------------------

func _select_via_union(claude_candidates):
	# §8 one-shot ghost-determinism check, lazily before the first real
	# sticky-ghost eval (DESIGN says "at _ready", but the sticky ghost needs a
	# started match to copy from — first use is the earliest safe point).
	# Divergence ⇒ copy_to does not snapshot enough state (e.g. RNG) for
	# eval results to be trustworthy: latch union ghost-eval OFF for the
	# session and fall back to §6's first-valid v1 path (return null).
	if not ghost_determinism_checked:
		ghost_determinism_checked = true
		ReplayManager.resimulating = true
		var deterministic = heuristic.verify_ghost_determinism()
		ReplayManager.resimulating = false
		if not deterministic:
			ghost_verify_forced_off = true
			ghost_verify = false
			_log_line("[match=%s] GHOST_NONDETERMINISTIC — union ghost-eval disabled for this session" % match_id)
			return null

	var pool = []
	var seen = {}
	# Claude first so identical (action, data) pairs keep claude attribution.
	for c in claude_candidates:
		var k = c.action_name + "|" + JSON.print(c.data if c.data != null else {})
		if not seen.has(k):
			seen[k] = true
			pool.append({"action": c.action_name, "data": c.data, "extra": pending.temp_extra, "source": "claude"})
	var h = pending.get("heuristic_top1")
	if h != null and h.get("action") != null:
		var hk = str(h.action) + "|" + JSON.print(h.data if h.data != null else {})
		if not seen.has(hk):
			seen[hk] = true
			pool.append({"action": h.action, "data": h.data, "extra": pending.temp_extra, "source": "heuristic_top1"})
	for sp in pending.safety_pairs:
		var sk = str(sp.action) + "|" + JSON.print(sp.data if sp.data != null else {})
		if not seen.has(sk):
			seen[sk] = true
			pool.append({"action": sp.action, "data": sp.data, "extra": pending.temp_extra, "source": sp.source})

	# resimulating fences ONLY this ghost-eval block (§7.1 / fix #9). Budget:
	# 50ms aggregate inside eval_candidates — undo is blocked ≤ 50ms.
	ReplayManager.resimulating = true
	var evaled = heuristic.eval_candidates(
		pool, pending.predicted_opponent.action_name, pending.predicted_opponent.data)
	ReplayManager.resimulating = false
	if evaled.size() == 0:
		return null
	var best = evaled[0]
	for e in evaled:
		if e.eval > best.eval:
			best = e
	return best

# ---------------------------------------------------------------------------
# v0 helpers (§10)
# ---------------------------------------------------------------------------

func _visible_categories(action_buttons):
	var cats = {}
	var keys = CharacterState.ActionType.keys()
	for button in action_buttons.buttons:
		if button.is_visible() and button.state != null:
			var t = int(button.state.type)
			if t >= 0 and t < keys.size() and keys[t] != "Hurt":
				cats[keys[t]] = true
	return cats.keys()

# Mini get_best_move over the category-filtered button set. EXPENSIVE (each
# evaluate_button rebuilds the ghost) — call once per turn, cache the result.
func _heuristic_topk_for_category(enum_idx):
	var filtered = []
	for button in pending.action_buttons.buttons:
		if button.is_visible() and button.state != null and int(button.state.type) == enum_idx:
			filtered.append(button)
	var best = {"action": null, "data": null, "feint": false, "eval": -INF}
	for button in filtered:
		var ev = heuristic.evaluate_button(
			button, pending.temp_extra, id,
			pending.predicted_opponent.action_name, pending.predicted_opponent.data)
		if ev.eval > best.eval:
			best = {"action": ev.action, "data": ev.data, "feint": ev.feint, "eval": ev.eval}
	# evaluate_button leaves the last rebuilt ghost alive (only get_best_move
	# frees inline); release it so it doesn't self-tick until the next purge.
	heuristic.free_ghost()
	return best

# ---------------------------------------------------------------------------
# Misc plumbing
# ---------------------------------------------------------------------------

func _state_name(player):
	var cs = player.current_state()
	if cs == null:
		return "?"
	if cs.get("state_name") != null:
		return str(cs.state_name)
	return str(cs.name)

# Cheap fingerprint (§7.1 guard #3): xor of hp, positions and state names.
# Catches undo+redo landing on the same tick number with a different state.
func _hash_state(p, o):
	var pp = p.get_pos()
	var op = o.get_pos()
	var h = int(p.hp) ^ (int(o.hp) << 1)
	h ^= (int(pp.x) << 2) ^ (int(pp.y) << 3) ^ (int(op.x) << 4) ^ (int(op.y) << 5)
	h ^= _state_name(p).hash() ^ (_state_name(o).hash() << 1)
	return h

func _push_history(tick, my_action):
	recent_history.append({
		"tick": tick,
		"self": my_action,
		"opponent": _state_name(target_player.opponent),
	})
	while recent_history.size() > 8:
		recent_history.pop_front()

func _legal_move_names(legal_moves):
	var names = []
	for entry in legal_moves:
		names.append(entry.action_name)
	return names

func _log_line(line):
	print("claude_yomih: " + line)
	var f = File.new()
	var path = "user://claude_yomih.log"
	var err
	if f.file_exists(path):
		err = f.open(path, File.READ_WRITE)
		if err == OK:
			f.seek_end()
	else:
		err = f.open(path, File.WRITE)
	if err == OK:
		f.store_line(line)
		f.close()

func _write_snapshot(tick, snapshot):
	var dir = Directory.new()
	var folder = "user://claude_yomih/turns/%s" % match_id
	dir.make_dir_recursive(folder)  # may return ERR_ALREADY_EXISTS; check below
	if not dir.dir_exists(folder):
		return
	var f = File.new()
	if f.open("%s/%d.json" % [folder, tick], File.WRITE) == OK:
		f.store_string(JSON.print(snapshot, "  "))
		f.close()
