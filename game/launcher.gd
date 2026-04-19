extends Node

# Routes the startup scene based on platform + flags.
# - Desktop F5 / dedicated server export → res://main.tscn (the physics sim).
# - Web export → res://web_main.tscn (archive-replay client).
# - Either platform with "live" requested → res://live_main.tscn (WS live feed).
#
# Live selection:
# - Desktop: pass `++ --live` on the Godot CLI.
# - Web: append `?live=1` to the URL. Also accepts `?--live` for parity with the
#   desktop form, since Godot Web feeds URL params into cmdline_user_args().
#
# CLI runs that pass a scene path explicitly (roundd, verify_main, etc.) bypass
# this entirely: Godot only uses the project's main_scene when no scene is
# specified on the command line.

func _ready() -> void:
	var target := _pick_target()
	print("LAUNCHER: routing to %s" % target)
	# Deferred: calling change_scene_to_file from inside _ready hits "Parent node
	# is busy adding/removing children" because the tree is still propagating our
	# own entering. Defer to the next idle frame.
	get_tree().change_scene_to_file.call_deferred(target)

func _pick_target() -> String:
	if _live_requested():
		return "res://live_main.tscn"
	if OS.has_feature("web"):
		return "res://web_main.tscn"
	return "res://main.tscn"

func _live_requested() -> bool:
	for a in OS.get_cmdline_user_args():
		if a == "--live" or a == "--live=1":
			return true
	if OS.has_feature("web"):
		var win := JavaScriptBridge.get_interface("window")
		if win != null:
			var search := String(win.location.search)
			if search.contains("live=1") or search.contains("--live"):
				return true
	return false
