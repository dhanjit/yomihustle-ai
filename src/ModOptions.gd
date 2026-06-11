# claude_yomih/ModOptions.gd
# Mirrors _AIOpponents/ModOptions.gd: extends the SoupModOptions base and is
# registered via installScriptExtension (ModMain). SoupModOptions instances the
# extended script as a child of Main named "ModOptions"; readers go through
# main.get_node("ModOptions").get_setting("claude_yomih", <key>).
#
# Dropdowns / sliders return ints (see _AIOpponents/AIController.gd usage:
# get_setting("_AIOptions", "difficulty") returns the selected index).
# ClaudeController maps the "mode" index through MODE_NAMES = ["v1","v0","v_none"]
# — index 0 (the default selection) is v1 so a fresh install runs the primary
# target mode (DESIGN §6: default mode "v1").
#
# If SoupModOptions is not installed, installScriptExtension fails to resolve
# the parent script and this pane never appears; ClaudeController handles that
# (main.get_node_or_null("ModOptions") == null → defaults, log once).
extends "res://SoupModOptions/ModOptions.gd"

func _ready():
	# Propagate the extension chain FIRST — the loader-side analog of
	# ClaudeLoader._ready()'s ._ready() call. installScriptExtension chains
	# via take_over_path, so with _AIOpponents installed our `extends`
	# resolves to ITS ModOptions.gd: skipping ._ready() here means only our
	# leaf _ready runs and every earlier SoupModOptions consumer's
	# generate_menu never executes (their option panes vanish and e.g.
	# AIController's get_setting("_AIOptions", ...) returns null). Guarded
	# because SoupModOptions itself is not vendored: if NO ancestor script
	# defines _ready, an unconditional ._ready() is a GDScript runtime error
	# ("nonexistent function" — native virtuals are not callable).
	if _ancestor_defines_ready():
		._ready()

	var my_menu = generate_menu("claude_yomih", "Claude Plays HUSTLE")
	my_menu.add_label("lbl1", "Claude Plays HUSTLE — options")

	# Index → mode name mapping lives in ClaudeController.MODE_NAMES.
	# 0 = v1 (default), 1 = v0, 2 = v_none.
	var mode_dropdown = my_menu.add_dropdown_menu("mode", "Mode")
	mode_dropdown.add_item("v1 - Claude picks moves")
	mode_dropdown.add_item("v0 - Claude picks a category")
	mode_dropdown.add_item("v_none - heuristic only")

	# Which side Claude drives. 0 = Auto (the non-human side; defaults to
	# Player 2 when ambiguous), 1 / 2 = explicit slot.
	var player_dropdown = my_menu.add_dropdown_menu("target_player", "Claude player")
	player_dropdown.add_item("Auto")
	player_dropdown.add_item("Player 1")
	player_dropdown.add_item("Player 2")

	# Bridge port. The Python bridge writes its chosen port to
	# %LOCALAPPDATA%/claude_yomih/port; that file wins over this value.
	# This is the fallback when the file is absent (DESIGN §12.5).
	my_menu.add_number_slider("port", "Bridge port (fallback)", 8765, {min_value = 8765, max_value = 8770})

	# Kill-switch: never talk to the bridge, run every decision through the
	# Tier 2 heuristic (equivalent to v_none, kept as a separate toggle so it
	# can be flipped without losing the mode selection).
	my_menu.add_bool("fallback_only", "Fallback only (ignore bridge)")

	# Audit fix #10 union-pool ghost-eval runs by default; this opts out.
	# (Inverted key so the widget's default-off state means "verification ON".)
	my_menu.add_bool("disable_ghost_verify", "Disable ghost-eval verification")

	# DESIGN §10 HEURISTIC_FIX_FRAME_ADV_DIVISOR: the reference AI computes a
	# close-range frame_advantage_modifier /= 10 but never reads it (dead
	# code). Default OFF = faithful to the public _AIOpponents experience;
	# ON = apply the fixed divisor. Keep OFF for A/B comparisons.
	my_menu.add_bool("fix_frame_adv", "Heuristic: fix frame-adv divisor (experimental)")

	my_menu.add_label("lbl2", "Requires the Python bridge (see github.com/dhanjit/yomihustle-ai). When the bridge is offline the built-in heuristic plays instead.")

	add_menu(my_menu)

# True when any ancestor SCRIPT in the extension chain defines _ready().
# Script.get_script_method_list() returns only that script's own methods, so
# walk get_base_script() up the chain (our own script is excluded by starting
# at the base). Cannot use has_method(): it sees our own _ready.
func _ancestor_defines_ready():
	var base = get_script().get_base_script()
	while base != null:
		for m in base.get_script_method_list():
			if m.name == "_ready":
				return true
		base = base.get_base_script()
	return false
