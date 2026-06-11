# claude_yomih/LegalMoveEnumerator.gd
# DESIGN.md §3.1 / §6 — pre-computes the closed (action_name, data_index) set
# Claude picks from.
#
# This is a port of _AIOpponents/AIController.gd:
#   get_option_data() → get_data_structure() → split_potential_data(),
#   quick_data_lookup, get_possible_xyplot_outputs(), get_enabled_options(),
#   make_unique(), get_children_names(), activate_action_ui_data(),
#   verify_data_structure().
# Differences from the reference, both grounded:
#   * The reference type-matches UI elements against an instanced
#     AICheckableUIData.tscn; we compare get_script() against the same six
#     scripts loaded directly (paths read out of that .tscn), so we do not
#     depend on _AIOpponents being installed.
#   * The reference parents transient ActionUIData nodes to itself (a Node2D);
#     we are a Reference, so attach() takes a host Node (ClaudeController) to
#     parent them to. They are freed by get_option_data exactly as upstream.
#   * The "Parry" sentinel (quick_data_lookup["ParryHigh"]) is resolved at
#     enumeration time through HeuristicShim.get_block_data() against the
#     predicted opponent move — mirroring evaluate_button()'s special case,
#     including the count==0 → 1 fix ("Not possible to block @f0").
#
# Output entry shape (§3.1): {action_name, title, action_type,
# earliest_hitbox, is_guard_break, data_options, _internal_options} where
# data_options is JSON-friendly (null → {}) and _internal_options holds the
# exact values to submit (null stays null). Keys starting "_" are stripped
# from the wire by ProtocolEncoder.clean_legal_moves.
extends Reference

var quick_data_lookup = {
	"SuperJump": ["homing"],
	"Grab": {"Dash": [true, false], "Direction": [{"x": 1, "y": 0}, {"x": -1, "y": 0}], "Jump": [false]},
	"ParryHigh": ["Parry"],
	"Jump": [{"x": 0, "y": -100}, {"x": -87, "y": -50}, {"x": 87, "y": -50},  # Largest jump in directions
		{"x": 45, "y": -89}, {"x": -54, "y": -84},  # Diagonal
		{"x": 0, "y": -69}, {"x": -60, "y": -35}, {"x": 60, "y": -35}],  # Short hops
}

# Same six UI element types AICheckableUIData.tscn instances, keyed by the
# names the reference matches on.
const CHECKABLE_SCRIPT_PATHS = {
	"XYPlot": "res://ui/XYPlot/XYPlot.gd",
	"8Way": "res://ui/8Way/8Way.gd",
	"Slider": "res://ui/HorizSlider/HorizSlider.gd",
	"CountOption": "res://ui/CountOption/CountOption.gd",
	"OptionButton": "res://ui/ActionSelector/ActionUIData/ActionUIDataOptionButton.gd",
	"CheckButton": "res://ui/ActionSelector/ActionUIData/ActionUIDataCheckButton.gd",
}

var checkable_scripts = {}  # name → Script
var shim = null             # HeuristicShim (get_block_data for "Parry")
var host_node = null        # Node to parent transient ActionUIData nodes to
var game = null
var main = null
var id = 0
var target_player = null

func _init():
	for key in CHECKABLE_SCRIPT_PATHS.keys():
		var s = load(CHECKABLE_SCRIPT_PATHS[key])
		if s != null:
			checkable_scripts[key] = s
		else:
			push_warning("claude_yomih: LegalMoveEnumerator missing UI script %s" % CHECKABLE_SCRIPT_PATHS[key])

func attach(game_, main_, id_, shim_, host_node_):
	game = game_
	main = main_
	id = id_
	shim = shim_
	host_node = host_node_
	target_player = game.get_player(id)

# ---------------------------------------------------------------------------
# Reference port: data-structure spelunking
# ---------------------------------------------------------------------------

# Takes a potential data node as input (ActionUIData or XYPlot/Slider etc.)
# Recursively generates a dictionary of arrays of possible inputs.
func get_data_structure(control_node, fighter = null):
	# Account for unused code, halves time to process Grab
	if !control_node.visible and control_node.get_name() == "Jump" and get_children_names(control_node.get_parent()) == ["Direction", "Dash", "Jump"]:
		return {control_node.get_name(): [false]}

	var script = control_node.get_script()
	if script != null:
		for element_name in checkable_scripts.keys():
			if script == checkable_scripts[element_name]:
				match element_name:
					"XYPlot":
						return {control_node.get_name(): get_possible_xyplot_outputs(control_node)}
					"8Way":
						var possible_dirs = []
						for dir in control_node.DIRS:
							if control_node.get(dir):
								possible_dirs.append(control_node.get_value(dir))
						return {control_node.get_name(): possible_dirs}
					"Slider":
						return {control_node.get_name(): make_unique([{"x": control_node.min_value}, {"x": control_node.max_value}, {"x": (control_node.min_value + control_node.max_value) / 2}])}
					"CountOption":
						return {control_node.get_name(): {"count": make_unique([control_node.min_value, control_node.max_value, (control_node.min_value + control_node.max_value) / 2])}}
					"OptionButton":
						return {control_node.get_name(): get_enabled_options(control_node)}
					"CheckButton":
						return {control_node.get_name(): [true, false]}

	if control_node is Container:
		activate_action_ui_data(control_node, fighter)
		var test_data = {}
		var datum = null
		for child in control_node.get_children():
			datum = get_data_structure(child, fighter)
			if datum is int:
				return null
			elif datum != null and not datum is Array:
				test_data[datum.keys()[0]] = datum.values()[0]

		if test_data.keys().size() > 1:
			return verify_data_structure(control_node, test_data)
		elif datum is Array:
			return verify_data_structure(control_node, datum)
		elif datum != null:
			return verify_data_structure(control_node, datum.values()[0])
		else:
			return [null]

# Turns the structure made above into an array of data permutations.
func split_potential_data(data):
	var result = [{}]

	for key in data.keys():
		var new_result = []
		var value = data[key]

		if value is Array:
			for item in value:
				for existing_dict in result:
					var new_dict = existing_dict.duplicate()
					new_dict[key] = item
					new_result.append(new_dict)
		elif value is Dictionary:
			var sub_permutations = split_potential_data(value)
			for sub_perm in sub_permutations:
				for existing_dict in result:
					var new_dict = existing_dict.duplicate()
					new_dict[key] = sub_perm
					new_result.append(new_dict)
		else:
			for existing_dict in result:
				existing_dict[key] = value
			new_result = result

		result = new_result

	return result

func get_enabled_options(option_button):
	var enabled_options = []
	var items = option_button.get_item_count()
	for option in range(items):
		if not option_button.is_item_disabled(option):
			enabled_options.append({
				"id": option,
				"name": option_button.items[option],
			})
	return enabled_options

func create_output(x, y, xy_plot, panel_radius):
	return xy_plot.as_percentage_int_vec(Vector2(x, y) * panel_radius)

# Gets up/down/left/right if applicable, then the extremities of the limited
# area if the plot is angle-limited.
func get_possible_xyplot_outputs(xy_plot):
	var outputs = []
	var panel_radius = xy_plot.panel_radius
	var facing = xy_plot.facing * target_player.get_facing_int()
	var limit_angle = xy_plot.limit_angle
	var limit_center = xy_plot.get_limit_center()
	var limit_range = xy_plot.get_limit_range()

	# Add (1, 0) and (-1, 0) if within allowed angle
	if not limit_angle or abs(Utils.angle_diff(0, limit_center)) <= limit_range / 2:
		outputs.append(create_output(facing, 0, xy_plot, panel_radius))
	if not limit_angle or abs(Utils.angle_diff(PI, limit_center)) <= limit_range / 2:
		outputs.append(create_output(-facing, 0, xy_plot, panel_radius))

	# Add (0, 1) and (0, -1) if within allowed angle
	if not limit_angle or abs(Utils.angle_diff(-PI / 2, limit_center)) <= limit_range / 2:
		outputs.append(create_output(0, -1, xy_plot, panel_radius))
	if not limit_angle or abs(Utils.angle_diff(PI / 2, limit_center)) <= limit_range / 2:
		outputs.append(create_output(0, 1, xy_plot, panel_radius))

	# If angle is limited, add extremities
	if limit_angle:
		var left_extremity = Utils.ang2vec(limit_center - limit_range / 2)
		var right_extremity = Utils.ang2vec(limit_center + limit_range / 2)
		outputs.append(create_output(left_extremity.x * facing, left_extremity.y, xy_plot, panel_radius))
		outputs.append(create_output(right_extremity.x * facing, right_extremity.y, xy_plot, panel_radius))

	return outputs

func make_unique(arr):
	var dict = {}
	for a in arr:
		dict[a] = 1
	return dict.keys()

func get_children_names(node):
	var children_names = []
	for child in node.get_children():
		children_names.append(child.get_name())
	return children_names

func activate_action_ui_data(control_node, fighter):
	if control_node is ActionUIData:
		control_node.fighter = fighter
		host_node.add_child(control_node)
		control_node.fighter_update()

func verify_data_structure(control_node, unverified_data):
	if control_node is ActionUIData:
		var default_data = control_node.get_data()
		var test_data
		if unverified_data is Array:
			test_data = unverified_data[0]
		else:
			test_data = unverified_data
		if default_data is Dictionary and test_data is Dictionary and default_data.keys() != test_data.keys():
			return [default_data]
		if test_data is Dictionary and not default_data is Dictionary or not test_data is Dictionary and default_data is Dictionary:
			return [default_data]
	return unverified_data

# Reference get_option_data, verbatim semantics: [null] when there is no data
# UI; permutations otherwise. The returned array may contain the sentinel
# strings from quick_data_lookup ("Parry", "homing") — callers resolve them.
func get_option_data(option, extra, data_ui_scene, fighter):
	var temp_data = [null]
	if data_ui_scene != null:
		var possible_data = []
		if option in quick_data_lookup:
			possible_data = quick_data_lookup[option]
		else:
			var data_scene_instance = data_ui_scene.instance()
			possible_data = get_data_structure(data_scene_instance, fighter)
			data_scene_instance.free()
		temp_data = split_potential_data(possible_data) if possible_data is Dictionary else possible_data
	return temp_data

# ---------------------------------------------------------------------------
# Wire-shape enumeration (§3.1)
# ---------------------------------------------------------------------------

func _action_type_name(state):
	if state == null:
		return "Other"
	var keys = CharacterState.ActionType.keys()
	var t = int(state.type)
	if t >= 0 and t < keys.size():
		return keys[t]
	return "Other"

func _resolve_sentinels(options, opponent_action, opponent_data):
	# "Parry" → concrete block data against the predicted opponent move
	# (mirrors evaluate_button's special case; needs the shim's ghost).
	var out = []
	for example_data in options:
		if example_data is String and example_data == "Parry":
			if shim != null:
				example_data = shim.get_block_data(opponent_action, opponent_data, id)
				if example_data["Melee Parry Timing"].count == 0:
					example_data["Melee Parry Timing"].count = 1  # Not possible to block @f0
			else:
				example_data = {"Block Height": {"y": 0}, "Melee Parry Timing": {"count": 4}}
		out.append(example_data)
	return out

func _wire_data(d):
	# JSON-friendly mirror: null → {} ("one valid empty-dict invocation",
	# §3.2). Everything else ships as-is; fixed-point strings stay strings.
	if d == null:
		return {}
	return d

func _entry_from_button(button, opponent_action, opponent_data):
	var state = button.state
	var internal = get_option_data(
		button.action_name, {},
		state.data_ui_scene if state != null else null,
		game.get_player(id))
	internal = _resolve_sentinels(internal, opponent_action, opponent_data)
	# Dedupe permutations by JSON identity.
	var seen = {}
	var internal_unique = []
	for d in internal:
		var k = JSON.print(_wire_data(d))
		if not seen.has(k):
			seen[k] = true
			internal_unique.append(d)
	var wire = []
	for d in internal_unique:
		wire.append(_wire_data(d))
	var earliest = null
	var guard_break = false
	if state != null:
		earliest = state.get("earliest_hitbox")
		# ObjectState.gd: var is_guard_break (set when hitboxes load).
		guard_break = bool(state.get("is_guard_break")) if state.get("is_guard_break") != null else false
	return {
		"action_name": button.action_name,
		"title": str(state.title) if state != null and state.get("title") != null and str(state.title) != "" else str(button.action_name),
		"action_type": _action_type_name(state),
		"earliest_hitbox": earliest,
		"is_guard_break": guard_break,
		"data_options": wire,
		"_internal_options": internal_unique,
	}

func _merge_entry(by_name, entry):
	# Dedupe by (action_name, frozen(data_options)) — §3.1. Same action_name
	# twice with different options → union the options under one entry so
	# data_index stays unambiguous.
	if not by_name.has(entry.action_name):
		by_name[entry.action_name] = entry
		return
	var existing = by_name[entry.action_name]
	for i in range(entry.data_options.size()):
		var k = JSON.print(entry.data_options[i])
		var found = false
		for j in range(existing.data_options.size()):
			if JSON.print(existing.data_options[j]) == k:
				found = true
				break
		if not found:
			existing.data_options.append(entry.data_options[i])
			existing._internal_options.append(entry._internal_options[i])

func _synthetic_entry(action_name):
	return {
		"action_name": action_name,
		"title": action_name,
		"action_type": "Other",
		"earliest_hitbox": null,
		"is_guard_break": false,
		"data_options": [],
		"_internal_options": [],
	}

func ensure_pair(by_name, action_name, data):
	# UNION insertion (§6): guarantee (action_name, data) is representable in
	# the legal set. Returns the data_index of the pair.
	if not by_name.has(action_name):
		by_name[action_name] = _synthetic_entry(action_name)
	var entry = by_name[action_name]
	var k = JSON.print(_wire_data(data))
	for i in range(entry.data_options.size()):
		if JSON.print(entry.data_options[i]) == k:
			return i
	entry.data_options.append(_wire_data(data))
	entry._internal_options.append(data)
	return entry.data_options.size() - 1

# Cheapest visible Defense-type move = lowest super_level_ (meter cost), used
# as part of the safety set (audit fix #10). Returns {action, data} or null.
func cheapest_defense(action_buttons, opponent_action, opponent_data):
	var best_button = null
	var best_cost = 999999
	for button in action_buttons.buttons:
		if button.is_visible() and button.state != null \
				and int(button.state.type) == CharacterState.ActionType.Defense:
			var cost = button.state.get("super_level_")
			cost = int(cost) if cost != null else 0
			if cost < best_cost:
				best_cost = cost
				best_button = button
	if best_button == null:
		return null
	var options = get_option_data(
		best_button.action_name, {},
		best_button.state.data_ui_scene, game.get_player(id))
	options = _resolve_sentinels(options, opponent_action, opponent_data)
	if options.size() == 0:
		return null
	return {"action": best_button.action_name, "data": options[0]}

# ---------------------------------------------------------------------------
# Main entry point.
#   action_buttons   — main.find_node("P<n>ActionButtons") for our side
#   opponent_action/_data — predicted opponent move (held fixed; fix #5)
#   ensure_pairs     — [{action, data, source}] guaranteed present (heuristic
#                      top-1, prior Claude picks)
# Returns {legal_moves: [...entries...], safety_pairs: [{action,data,source}]}
# ---------------------------------------------------------------------------
func enumerate(action_buttons, opponent_action, opponent_data, ensure_pairs = []):
	var by_name = {}
	var order = []
	for button in action_buttons.buttons:
		if not button.is_visible():
			continue
		var entry = _entry_from_button(button, opponent_action, opponent_data)
		if entry.data_options.size() == 0:
			continue  # zero valid invocations → not legal (§3.2)
		if not by_name.has(entry.action_name):
			order.append(entry.action_name)
		_merge_entry(by_name, entry)

	# Safety set: Continue (always legal) + cheapest Defense.
	var safety_pairs = []
	if not by_name.has("Continue"):
		order.append("Continue")
	ensure_pair(by_name, "Continue", null)
	safety_pairs.append({"action": "Continue", "data": null, "source": "safety_continue"})
	var defense = cheapest_defense(action_buttons, opponent_action, opponent_data)
	if defense != null:
		if not by_name.has(defense.action):
			order.append(defense.action)
		ensure_pair(by_name, defense.action, defense.data)
		safety_pairs.append({"action": defense.action, "data": defense.data, "source": "safety_defense"})

	# UNION extras (heuristic top-1, Claude prior K). Never synthesize an
	# entry for an action that is not visible THIS turn — a stale Claude
	# prior (e.g. an air move while grounded) must not re-enter the legal
	# set. Heuristic top-1 always comes from visible buttons, so this only
	# ever drops stale priors.
	for pair in ensure_pairs:
		if pair == null or pair.get("action") == null:
			continue
		if not by_name.has(pair.action):
			continue
		ensure_pair(by_name, pair.action, pair.get("data"))

	var legal_moves = []
	for action_name in order:
		legal_moves.append(by_name[action_name])

	# _resolve_sentinels → shim.get_block_data leaves the last rebuilt ghost
	# alive in GhostViewport, where it would free-run ticks at ghost_speed=100
	# for the entire Claude TCP wait (0.5–8s). Release it before returning.
	if shim != null:
		shim.free_ghost()
	return {"legal_moves": legal_moves, "safety_pairs": safety_pairs}
