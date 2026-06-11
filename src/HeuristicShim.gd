# claude_yomih/HeuristicShim.gd
# DESIGN.md §5.4 / §8 / §10 — vendored port of _AIOpponents/AIController.gd's
# decision machinery (eval_move / get_best_move / evaluate_button /
# get_block_data / setup_ghost_game / di_as_percentage_int_vec), weights
# faithful to the reference.
#
# NOT a Node. This object must never enter the scene tree: the reference
# controller's _ready self-installs as a player_actionable decision driver,
# which is exactly the last-connected-wins race DESIGN §4 removes. Plain
# Object (not Reference) so ClaudeController._exit_tree's explicit
# heuristic.free() matches DESIGN §5.4. Contract: never enters the scene
# tree, never connects to player_actionable, never reads ModOptions for id.
#
# Two ghost lifecycles, both owned here (the controller never touches them):
#   * ghost_game     — reference-style teardown/rebuild per eval_move call.
#                      Used by Tier 2 get_best_move + get_block_data; full
#                      ~N-cycle cost, fallback path only (DESIGN §8).
#                      A tree-resident is_ghost Game free-runs ticks by itself
#                      (game.gd ghost_tick via _process/_physics_process), so
#                      an orphan burns CPU at ghost_speed=100 for the whole
#                      TCP wait — every call path that ends with a live ghost
#                      must finish with free_ghost() (get_best_move does it
#                      inline; enumerate()/_heuristic_topk_for_category call
#                      free_ghost() explicitly).
#   * sticky_ghost   — instanced lazily, invalidated on match_data change,
#                      game.copy_to(sticky_ghost) before EACH candidate eval,
#                      freed on teardown (audit fix #6). NB: Main._start_ghost
#                      queue_frees every GhostViewport child after each
#                      submit, so in practice the sticky ghost is rebuilt
#                      once PER TURN (ensure_sticky_ghost's is_instance_valid
#                      check absorbs the purge). That still satisfies fix #6's
#                      "once per turn", and it kills the between-turn
#                      self-ticking window as a side effect. Used by
#                      eval_candidates (union-pool ghost-eval, fix #10).
extends Object

# --- Reference eval coefficients (verbatim) --------------------------------
var FRAMES_TO_SIMULATE = 35          # Frames simulated when evaluating a move
var states_to_ignore = ["Taunt", "DefensiveBurst"]
var prevent_self_destruction = true  # Abort eval if a move suicides
var SUPER_MODIFIER = -0.5
var DISTANCE_MODIFIER = 0.1
var DAMAGE_MODIFIER = 1
var FRAME_ADVANTAGE_MODIFIER = 20

# DESIGN §10 HEURISTIC_FIX_FRAME_ADV_DIVISOR: the reference computes a local
# frame_advantage_modifier (/= 10 when distance_closed < 50) but the eval
# expression reads the uppercase export — dead code. false (default) keeps
# the public _AIOpponents behavior; true applies the computed divisor.
var fix_frame_adv_divisor = false

# Last applied modifier per state name (verbatim, incl. Burst clamps).
var state_specific_modifiers = {
	"WhiffInstantCancel": {"operation": "*", "amount": 0},
	"InstantCancel": {"operation": "*", "amount": 0},
	"Roll": {"operation": "*", "amount": 0.5},
	"Burst": {
		"positive": {"operation": "*", "amount": 0},
		"negative": {"operation": "+", "amount": -999999},
	},
	"DefensiveBurst": {
		"positive": {"operation": "*", "amount": 0},
		"negative": {"operation": "+", "amount": -999999},
	},
	"OffensiveBurst": {
		"positive": {"operation": "*", "amount": 0},
		"negative": {"operation": "+", "amount": -999999},
	},
}

# Reference hard mode. With limit_by_difficulty=true this admits button types
# 1..3 (Attack/Special/Super) exactly like the reference's difficulty-3
# self-pick call.
var difficulty = 3

# Sticky-candidate budget (DESIGN §8): aggregate 50ms, ~16ms per candidate.
const STICKY_CANDIDATE_BUDGET_MS = 16
const STICKY_AGGREGATE_BUDGET_MS = 50

var game = null
var main = null
var id = 0
var target_player = null
var ghost_viewport = null
var enumerator = null        # LegalMoveEnumerator (get_option_data port)

var ghost_game = null        # reference-style rebuilt ghost
var sticky_ghost = null      # fix #6 sticky ghost (sole owner: this object)
# match_data.hash() invalidation token. NB: main.match_data is a Dictionary,
# so DESIGN §8's get_instance_id() cannot apply — hash() instead.
var sticky_match_token = -1

func attach(game_, main_, id_, enumerator_):
	game = game_
	main = main_
	id = id_
	enumerator = enumerator_
	target_player = game.get_player(id)
	ghost_viewport = main.find_node("GhostViewport")

func teardown():
	free_ghost()
	if sticky_ghost != null and is_instance_valid(sticky_ghost):
		sticky_ghost.queue_free()
	sticky_ghost = null

# Frees the rebuilt (non-sticky) ghost. The reference always freed it at the
# end of get_best_move; the sentinel-resolution and v0-category paths build
# ghosts outside get_best_move and MUST call this when done, or the orphan
# self-ticks in GhostViewport until Main._start_ghost's purge after submit.
func free_ghost():
	if ghost_game != null and is_instance_valid(ghost_game):
		ghost_game.free()
	ghost_game = null

# ---------------------------------------------------------------------------
# Ghost lifecycles
# ---------------------------------------------------------------------------

# Reference setup_ghost_game, multihustle branches stripped: frees the prior
# ghost and rebuilds Game.tscn from scratch — the expensive primitive.
func setup_ghost_game():
	if ghost_game != null and is_instance_valid(ghost_game):
		ghost_game.free()
	var gg_scene = load("res://Game.tscn")
	ghost_game = gg_scene.instance()
	ghost_game.is_ghost = true
	ghost_game.visible = false
	ghost_viewport.add_child(ghost_game)
	ghost_game.start_game(true, main.match_data)
	ghost_game.ghost_speed = 100
	ghost_game.ghost_freeze = false
	game.copy_to(ghost_game)

func ensure_sticky_ghost():
	if sticky_ghost != null and is_instance_valid(sticky_ghost) \
			and sticky_match_token == main.match_data.hash():
		return true
	if sticky_ghost != null and is_instance_valid(sticky_ghost):
		sticky_ghost.queue_free()
	sticky_ghost = load("res://Game.tscn").instance()
	sticky_ghost.is_ghost = true
	sticky_ghost.visible = false
	ghost_viewport.add_child(sticky_ghost)
	sticky_ghost.start_game(true, main.match_data)
	sticky_ghost.ghost_speed = 100
	sticky_ghost.ghost_freeze = false
	sticky_match_token = main.match_data.hash()
	return true

func _reset_sticky_ghost():
	# Before EACH candidate (fix #6): one-shot snapshot, then defensively
	# re-apply runtime flags copy_to does not cover, and clear end-of-round
	# residue a previous candidate sim may have left (copy_to restores
	# fighters/objects but not game_finished — the reference never hit this
	# because it rebuilt the scene every eval).
	#
	# Drain the ghost's objects/effects BEFORE copy_to. copy_to free()s
	# game.objects then game.effects with NO validity guards (game.gd):
	#   * on_object_spawned appends an object's particle children to effects
	#     WITHOUT a tree_exited hook, so the objects-loop frees them with
	#     their parent and the effects-loop then free()s dead instances —
	#     a script error that aborts copy_to mid-call (object snapshot +
	#     camera limits never run, state goes stale across candidates).
	#   * the objects-loop mutates `objects` while iterating it (free →
	#     tree_exited → _on_obj_exit_tree → objects.erase), skipping every
	#     other element, so live objects leak across candidates.
	# The reference never hit either (fresh ghost = empty arrays). Draining
	# here means copy_to's free-loops iterate empty arrays.
	for obj in sticky_ghost.objects.duplicate():
		if is_instance_valid(obj):
			obj.free()
	sticky_ghost.objects = []
	for fx in sticky_ghost.effects.duplicate():
		if is_instance_valid(fx):
			fx.free()
	sticky_ghost.effects = []
	game.copy_to(sticky_ghost)
	sticky_ghost.ghost_speed = 100
	sticky_ghost.ghost_freeze = false
	if sticky_ghost.get("game_finished") != null:
		sticky_ghost.game_finished = false
	for pid in [1, 2]:
		var p = sticky_ghost.get_player(pid)
		if p != null and p.get("game_over") != null:
			p.game_over = false

# ---------------------------------------------------------------------------
# eval_move — verbatim reference port (+ sticky mode, + metrics out).
# Returns {"eval": float, "feint": bool, "metrics": {...}} or null when the
# sticky per-candidate budget is blown (caller drops the candidate).
# ---------------------------------------------------------------------------
func eval_move(action, data, extra, pid, opponent_action = "Continue", opponent_data = null, use_sticky = false):
	var g
	if use_sticky:
		ensure_sticky_ghost()
		_reset_sticky_ghost()
		g = sticky_ghost
	else:
		setup_ghost_game()
		g = ghost_game

	var evaluee = g.get_player(pid)
	var opponent = g.get_player(evaluee.opponent.id)

	opponent.is_ghost = true
	opponent.queued_action = opponent_action
	opponent.queued_data = opponent_data
	if use_sticky:
		# The reference relies on stale queued_extra surviving in the rebuilt
		# ghost; with a re-used ghost we set the opponent's extra explicitly
		# (DESIGN §8): default away-DI, no feint.
		var od = opponent.get_pos()
		var ed = evaluee.get_pos()
		opponent.queued_extra = {
			"DI": di_as_percentage_int_vec(Vector2(od.x - ed.x, od.y - ed.y).normalized()),
			"feint": false,
			"prediction": -1,
			"reverse": false,
		}

	evaluee.is_ghost = true
	evaluee.queued_action = action
	evaluee.queued_data = data
	evaluee.queued_extra = extra

	var opponent_start_hp = opponent.hp
	var evaluee_start_hp = evaluee.hp
	var evaluee_start_super = evaluee.super_meter

	var evaluee_ready_tick = null
	var opponent_ready_tick = null

	var evaluee_is_hit = opponent.combo_count > 0
	# (reference computes opponent_is_hit symmetrically; unused in scoring)

	var evaluee_opponent_dist_start = sqrt(pow(opponent.get_pos().x - evaluee.get_pos().x, 2) + pow(opponent.get_pos().y - evaluee.get_pos().y, 2))
	var evaluee_opponent_dist_end = 0

	var loop_t0 = OS.get_ticks_msec()
	for current_frame in range(1, FRAMES_TO_SIMULATE + 1):
		if use_sticky and OS.get_ticks_msec() - loop_t0 > STICKY_CANDIDATE_BUDGET_MS:
			return null  # budget blown — caller drops this candidate (§8)
		g.simulate_one_tick()

		if evaluee.hp <= 0 and prevent_self_destruction and evaluee_ready_tick == null:
			return {"eval": -999999, "feint": false, "metrics": null}

		var evaluee_tick = current_frame + (evaluee.hitlag_ticks if not opponent_ready_tick else 0)
		if (evaluee.state_interruptable or evaluee.dummy_interruptable or evaluee.state_hit_cancellable) and evaluee_ready_tick == null:
			evaluee_ready_tick = evaluee_tick
			if (opponent.current_state().interruptible_on_opponent_turn or opponent.feinting or g.negative_on_hit(opponent)) and opponent_ready_tick == null:
				opponent_ready_tick = current_frame
				break

		var opponent_tick = current_frame + (opponent.hitlag_ticks if not evaluee_ready_tick else 0)
		if (opponent.state_interruptable or opponent.dummy_interruptable or opponent.state_hit_cancellable) and opponent_ready_tick == null:
			opponent_ready_tick = opponent_tick
			if (evaluee.current_state().interruptible_on_opponent_turn or evaluee.feinting or g.negative_on_hit(evaluee)) and evaluee_ready_tick == null:
				evaluee_ready_tick = current_frame

		if !evaluee_opponent_dist_end and (opponent_ready_tick != null or evaluee_ready_tick != null):
			evaluee_opponent_dist_end = sqrt(pow(opponent.get_pos().x - evaluee.get_pos().x, 2) + pow(opponent.get_pos().y - evaluee.get_pos().y, 2))
		if opponent_ready_tick != null and evaluee_ready_tick != null:
			break

	if !evaluee_opponent_dist_end:
		evaluee_opponent_dist_end = sqrt(pow(opponent.get_pos().x - evaluee.get_pos().x, 2) + pow(opponent.get_pos().y - evaluee.get_pos().y, 2))
	if evaluee_ready_tick == null:
		evaluee_ready_tick = FRAMES_TO_SIMULATE
	if opponent_ready_tick == null:
		opponent_ready_tick = FRAMES_TO_SIMULATE

	var frame_advantage = opponent_ready_tick - evaluee_ready_tick
	var damage = (opponent_start_hp - opponent.hp) - (evaluee_start_hp - evaluee.hp)
	var distance_closed = evaluee_opponent_dist_start - evaluee_opponent_dist_end

	var evaluee_state = evaluee.state_machine.get_state(action)
	var earliest_hitbox = null
	var supers = null
	var feint = false
	if evaluee_state:
		# Reference quirk kept verbatim: gates on target_player.feints (the
		# shim's controlled fighter), not evaluee's — even for opponent evals.
		if target_player.feints > 0 and evaluee_state.can_feint() and frame_advantage < 0:
			feint = true
			if damage > 0:
				frame_advantage = 0
		earliest_hitbox = evaluee_state.get("earliest_hitbox")
		supers = evaluee_state.get("super_level_")

	if earliest_hitbox == null:
		earliest_hitbox = 0
	if supers == null:
		supers = 0

	# Reference dead code, kept (see fix_frame_adv_divisor above): the local
	# is computed but the eval reads the uppercase modifier unless the fix
	# flag is on.
	var frame_advantage_modifier = FRAME_ADVANTAGE_MODIFIER
	if distance_closed < 50:
		frame_advantage_modifier /= 10

	var distance_modifier = DISTANCE_MODIFIER
	if damage == 0:
		distance_modifier *= 10
	if damage < 0 or evaluee_is_hit:
		distance_modifier *= -1

	var applied_fa_modifier = frame_advantage_modifier if fix_frame_adv_divisor else FRAME_ADVANTAGE_MODIFIER
	var eval = (
		(frame_advantage * applied_fa_modifier) +
		(damage * DAMAGE_MODIFIER) +
		(distance_closed * distance_modifier) +
		(supers * SUPER_MODIFIER)
	)

	var modifier = state_specific_modifiers.get(action)
	if modifier:
		if modifier.has("positive") and eval >= 0:
			modifier = modifier.positive
		elif modifier.has("negative") and eval < 0:
			modifier = modifier.negative
		if modifier.has("operation") and modifier.has("amount"):
			if modifier.operation == "*":
				eval *= modifier.amount
			elif modifier.operation == "+":
				eval += modifier.amount

	# Trying to avoid weird Whiffs where the opponent is far away
	if action == "WhiffInstantCancel" and evaluee_opponent_dist_end > 150:
		eval = -200

	return {
		"eval": eval,
		"feint": feint,
		"metrics": {
			"predicted_self_hp_delta": evaluee.hp - evaluee_start_hp,
			"predicted_opponent_hp_delta": opponent.hp - opponent_start_hp,
			"predicted_frame_advantage": frame_advantage,
			"predicted_distance_closed": distance_closed,
			"predicted_self_super_delta": evaluee.super_meter - evaluee_start_super,
		},
	}

# ---------------------------------------------------------------------------
# get_block_data — verbatim reference port. Frame at which to block to parry
# a given move; pid is the blocking player. Uses the rebuilt ghost.
# ---------------------------------------------------------------------------
func get_block_data(opponent_action, opponent_data, pid):
	setup_ghost_game()

	var evaluee = ghost_game.get_player(pid)
	var opponent = evaluee.opponent

	opponent.is_ghost = true
	opponent.queued_action = opponent_action
	opponent.queued_data = opponent_data

	evaluee.queued_action = "ParryHigh"
	evaluee.queued_data = {"Block Height": {"y": 0}, "Melee Parry Timing": {"count": 19}}
	evaluee.queued_extra = null
	evaluee.is_ghost = true

	var tick = 0
	# If the move doesn't hit, only go for 20 frames then return a default of 4
	while evaluee.ghost_blocked_melee_attack == -1 and tick < 20:
		ghost_game.simulate_one_tick()
		tick += 1

	return {
		"Block Height": {"y": 1 if evaluee.ghost_wrong_block == "Low" else 0},
		"Melee Parry Timing": {"count": evaluee.ghost_blocked_melee_attack if evaluee.ghost_blocked_melee_attack != -1 else 4},
	}

# ---------------------------------------------------------------------------
# evaluate_button / get_best_move — verbatim reference port (multihustle and
# debug prints stripped; get_option_data delegated to LegalMoveEnumerator).
# ---------------------------------------------------------------------------
func evaluate_button(button, extra, pid, opponent_action, opponent_data):
	var temp_data = enumerator.get_option_data(button.action_name, extra, button.state.data_ui_scene if button.state != null else null, game.get_player(pid))
	var best_score = -999999
	var best_data = null
	var feint = false

	for example_data in temp_data:
		if example_data is String and example_data == "Parry":
			example_data = get_block_data(opponent_action, opponent_data, pid)
			if example_data["Melee Parry Timing"].count == 0:
				example_data["Melee Parry Timing"].count = 1  # Not possible to block @f0
		var prediction = eval_move(button.action_name, example_data, extra, pid, opponent_action, opponent_data)
		if prediction != null and prediction.eval > best_score:
			best_score = prediction.eval
			best_data = example_data
			feint = prediction.feint
	return {"action": button.action_name, "eval": best_score, "data": best_data, "feint": feint}

func get_best_move(extra, pid, leeway_percentage, allow_leeway, limit_by_difficulty, randomise_burst, opponent_action = "Continue", opponent_data = null):
	var moves = []
	var best_score = -999999

	var action_buttons = main.find_node("P" + str(2 - pid % 2) + "ActionButtons")
	if action_buttons == null:
		return {"action": "Continue", "eval": 0, "data": null, "feint": false}

	var evaluee = game.get_player(pid)
	var opponent = game.get_player(evaluee.opponent.id)

	var dist = sqrt(pow(opponent.get_pos().x - evaluee.get_pos().x, 2) + pow(opponent.get_pos().y - evaluee.get_pos().y, 2))

	for button in action_buttons.buttons:
		# Check if the button is a move we're bothering to check.
		if (button.is_visible() and ((button.state == null or (button.state.type != 0 and button.state.type <= difficulty)) or !limit_by_difficulty)) and !(button.action_name in states_to_ignore or "StrikeAPose" in button.action_name or "StrikeA_Pose" in button.action_name) and !(dist > 200 and button.state and button.state.type == 1):
			var evaluation = evaluate_button(button, extra, pid, opponent_action, opponent_data)
			if best_score < evaluation.eval:
				if !allow_leeway or abs(best_score - evaluation.eval) >= best_score * leeway_percentage:
					moves = [evaluation]
				best_score = evaluation.eval
			elif allow_leeway and abs(best_score - evaluation.eval) <= best_score * leeway_percentage:
				moves.append(evaluation)

	# Burst randomisation and failsafe if no moves are returned
	if moves.empty() or randomise_burst and moves[0].action == "Burst":
		moves.append({"action": "Continue", "eval": 0, "data": null, "feint": false})

	var chosen_move = moves[target_player.randi_range(0, moves.size() - 1)].duplicate() if !moves.empty() else {"action": "Continue", "eval": -999999, "data": null, "feint": false}
	free_ghost()  # reference frees its ghost here; single owner is free_ghost()
	return chosen_move

# ---------------------------------------------------------------------------
# Mod-facing API
# ---------------------------------------------------------------------------

# From the actual DI code (reference verbatim).
func di_as_percentage_int_vec(vec2):
	return {
		"x": int(round(vec2.x * 100)),
		"y": int(round(vec2.y * 100)),
	}

# Opponent-modelling pre-step (audit fix #5). Mirrors the top of the
# reference's make_move(): gate on "can they even act", then
# get_best_move(temp_extra, opponent.id, 0.2, allow_leeway=true,
# limit_by_difficulty=false, randomise_burst=false) per DESIGN §6 (which
# deliberately drops the reference's difficulty coupling). Always returns a
# usable dict; degrades to Continue with fallback=true on any error.
func opponent_guess(temp_extra):
	var result = {"action": "Continue", "data": null, "eval": 0.0, "feint": false, "fallback": false}
	if target_player == null or target_player.opponent == null:
		result.fallback = true
		return result
	if target_player.bursts_available > 0 or target_player.opponent.combo_count <= 0:
		var raw_choice = get_best_move(temp_extra, target_player.opponent.id, 0.2, true, false, false)
		if raw_choice != null and raw_choice.has("action"):
			return raw_choice
		result.fallback = true
	return result

# DESIGN §8 ghost-determinism detector: sticky-ghost eval assumes
# game.copy_to(ghost) + identical inputs ⇒ identical outputs (RNG state
# included — NOT verified upstream). One-shot: run the same Continue-vs-
# Continue candidate twice on the sticky ghost and compare full results.
# Returns false only on a real divergence; true when deterministic OR
# inconclusive (per-candidate budget blown — don't disable on a slow frame).
# Caller owns the ReplayManager.resimulating fence and the
# GHOST_NONDETERMINISTIC latch (ClaudeController disables union ghost-eval
# for the session, falling back to DESIGN §6's first-valid v1 path).
func verify_ghost_determinism():
	var extra = {"DI": {"x": 0, "y": 0}, "feint": false, "prediction": -1, "reverse": false}
	var a = eval_move("Continue", null, extra.duplicate(true), id, "Continue", null, true)
	var b = eval_move("Continue", null, extra.duplicate(true), id, "Continue", null, true)
	if a == null or b == null:
		return true
	return JSON.print(a) == JSON.print(b)

# Union-pool ghost-eval (audit fix #10): score every candidate against the
# SAME fixed predicted opponent move on the sticky ghost. union_pool entries:
# {action, data, extra, source}. Returns evaluated entries (+eval/feint/
# metrics), dropping candidates whose eval blew the budget. Caller is
# responsible for the ReplayManager.resimulating fence (fix #9: resimulating
# wraps ONLY ghost-eval, never the TCP roundtrip).
func eval_candidates(union_pool, opponent_action, opponent_data):
	var out = []
	var t0 = OS.get_ticks_msec()
	for cand in union_pool:
		if OS.get_ticks_msec() - t0 > STICKY_AGGREGATE_BUDGET_MS:
			break  # aggregate budget — submit what we have (§8)
		var r = eval_move(cand.action, cand.data, cand.extra, id, opponent_action, opponent_data, true)
		if r == null:
			continue
		var entry = cand.duplicate()
		entry["eval"] = r.eval
		entry["feint"] = r.feint
		entry["metrics"] = r.metrics
		out.append(entry)
	return out
