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
	modLoader.installScriptExtension("res://claude_yomih/ModOptions.gd")

func _ready():
	pass
