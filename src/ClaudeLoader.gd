# claude_yomih/ClaudeLoader.gd
# DESIGN.md §4 / §5.3 — extends the live game.gd extension chain.
#
# Chain (with _AIOpponents installed):
#   game.gd → _AIOpponents/AILoader.gd (priority -10000) → ClaudeLoader (priority 100000)
# Lower priority installs EARLIER (ancestor); higher priority installs LATER and
# becomes the leaf whose _ready() Godot actually calls. We are the leaf.
#
# _ready() order is load-bearing:
#   1. ._ready() FIRST — propagates the chain; AILoader._ready() instances the
#      reference AIController as a child of the running Game.
#   2. THEN purge: disconnect + queue_free any _AIOpponents controller/loader
#      node, so the reference AI never drives target_player.
#   3. THEN add our ClaudeController.
extends "res://game.gd"

func _ready():
	# Ghost-viewport guard FIRST. Without this, ClaudeController would spawn
	# inside the ghost game during lookahead and recursively call Python. The
	# real protection lives in ClaudeController._ready (self-frees if
	# is_ghost), but stopping the chain here keeps controller churn out of
	# ghost instances entirely.
	if is_ghost:
		# Still need real game.gd._ready (and the rest of the chain) to run —
		# it hides the ghost and sets flags.
		._ready()
		return

	._ready()  # propagates to AILoader if it's in the extension chain

	# Tear down the reference AI's controller if it self-installed. We
	# pattern-match by script resource_path so this stays a cheap, idempotent
	# no-op when _AIOpponents is not installed at all.
	_purge_other_ai_controllers(self)

	add_child(preload("res://claude_yomih/ClaudeController.tscn").instance())

	# First-tick trip-wire: detect leaf-displacement by a higher-priority
	# third-party mod and warn loudly. (DESIGN §4 residual hazard.)
	call_deferred("_chain_leaf_check")

func _purge_other_ai_controllers(node):
	for child in node.get_children():
		var s = child.get_script()
		if s != null and (s.resource_path.find("_AIOpponents/AIController") != -1 \
				or s.resource_path.find("_AIOpponents/AILoader") != -1):
			# Explicit signal disconnect BEFORE queue_free — queue_free is
			# deferred and the signal connection lives until the actual free.
			# Without this, one extra player_actionable emission could race us.
			if is_connected("player_actionable", child, "_start_decision_thread"):
				disconnect("player_actionable", child, "_start_decision_thread")
			child.queue_free()
		_purge_other_ai_controllers(child)

func _chain_leaf_check():
	# We expect get_script() to be ClaudeLoader at runtime. If a future
	# ModLoader change or a higher-priority mod has displaced us, the leaf
	# script differs and our _ready() never ran as the leaf.
	var ls = get_script()
	if ls != null and ls.resource_path.find("claude_yomih/ClaudeLoader") == -1:
		push_error("ClaudeLoader: chain leaf is not us (%s) — priority inversion?" % ls.resource_path)

func _exit_tree():
	# Fail-loud if our extension-order assumption ever inverts: the reference
	# AIController should have been freed in _ready; if it's back, log it.
	for child in get_children():
		var s = child.get_script()
		if s != null and s.resource_path.find("_AIOpponents/AIController") != -1:
			push_error("ClaudeLoader: _AIOpponents controller survived purge — chain inversion?")
