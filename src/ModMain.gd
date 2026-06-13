# claude_yomih/ModMain.gd
# DESIGN.md §5.2 — single-line _init matching the _AIOpponents/ModMain.gd shape.
# NO side effects in _init beyond the two installScriptExtension calls:
# ModLoader.installScriptExtension calls childScript.new() at load time, so any
# _init side effects (sockets, threads, file handles) would persist for the
# lifetime of the editor session. All side effects live in
# ClaudeController._ready() instead.
extends Node

func _init(modLoader = ModLoader):
	modLoader.installScriptExtension("res://claude_yomih/ClaudeLoader.gd")
	# ModOptions.gd `extends "res://SoupModOptions/ModOptions.gd"`, which GDScript
	# resolves at PARSE time — so if SoupModOptions isn't installed, merely
	# loading ModOptions.gd is a hard parse error (observed live: "Couldn't load
	# the base class"). SoupModOptions is an OPTIONAL in-game settings pane, not a
	# requirement: gate the extension on the base actually existing. Without it,
	# ClaudeController reads a standalone config.json (or built-in defaults:
	# mode=v1, Claude=P2, port from the bridge's runtime file). All mounted mod
	# zips are resource-packed before any ModMain._init runs, so this check sees
	# SoupModOptions if the user has it.
	if ResourceLoader.exists("res://SoupModOptions/ModOptions.gd"):
		modLoader.installScriptExtension("res://claude_yomih/ModOptions.gd")
	else:
		print("claude_yomih: SoupModOptions not installed — in-game options pane disabled; using config.json/defaults.")

func _ready():
	pass
