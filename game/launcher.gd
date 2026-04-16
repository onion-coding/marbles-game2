extends Node

# Routes the startup scene based on platform.
# - Web export → res://web_main.tscn (network-sourced playback).
# - Everything else (desktop F5, dedicated-server export) → res://main.tscn
#   (the physics sim / recorder).
#
# CLI runs that pass a scene path explicitly (roundd, verify_main, etc.) bypass
# this entirely: Godot only uses the project's main_scene when no scene is
# specified on the command line.

func _ready() -> void:
	var target := "res://web_main.tscn" if OS.has_feature("web") else "res://main.tscn"
	print("LAUNCHER: routing to %s" % target)
	# Deferred: calling change_scene_to_file from inside _ready hits "Parent node
	# is busy adding/removing children" because the tree is still propagating our
	# own entering. Defer to the next idle frame.
	get_tree().change_scene_to_file.call_deferred(target)
