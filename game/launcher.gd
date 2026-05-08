extends Node

# Routes the startup scene.
#
# Since the M29 casino architecture moved player-facing rendering to the
# server (Godot subprocess renders → ffmpeg H.264 → Pion SFU → browser
# <video>), the in-browser Godot paths no longer have a player to serve.
# Two routes were retired:
#
#   - Web platform → res://web_main.tscn (archive-replay client).
#     Replaced by /casino/ + WebRTC video. The .tscn files remain on
#     disk in case the path is ever revived for offline replay viewing.
#
#   - --live / ?live=1 → res://live_main.tscn (WebSocket live feed of
#     per-tick positions, rendered locally in browser Godot). Replaced
#     by the same /casino/ video stream, where positions are pre-baked
#     into encoded frames server-side.
#
# Both retired routes log a warning so a future user reading the trace
# knows why their flag was ignored. To resurrect either, restore the
# corresponding line in _pick_target() — the scenes still parse and run.
#
# Routes that remain:
#   - Default (desktop / dedicated server): res://main.tscn.
#   - res://main.tscn supports modes (a) spec via --round-spec=<path>
#     (server-driven sims) and (c) interactive (local seed). Mode (b)
#     RGS client-physics (--rgs=<base>) was ripped at the same time
#     since the architecture no longer needs an interactive client to
#     fetch a seed and run physics locally.
#
# CLI runs that pass a scene path explicitly (roundd, verify_main, etc.)
# bypass this entirely: Godot only uses the project's main_scene when
# no scene is specified on the command line.

func _ready() -> void:
	_warn_about_retired_flags()
	var target := "res://main.tscn"
	print("LAUNCHER: routing to %s" % target)
	# Deferred: calling change_scene_to_file from inside _ready hits "Parent node
	# is busy adding/removing children" because the tree is still propagating our
	# own entering. Defer to the next idle frame.
	get_tree().change_scene_to_file.call_deferred(target)

# Surface a single line to the log if the user passed a flag that used
# to drive a web/live route. Avoids the silent "I asked for live and got
# main.tscn" head-scratcher.
func _warn_about_retired_flags() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--live" or a == "--live=1":
			push_warning("LAUNCHER: --live ignored; live feed moved to /casino/ WebRTC video — see docs/casino-frontend.md")
			return
	if OS.has_feature("web"):
		push_warning("LAUNCHER: web platform detected; player-facing path is now /casino/ WebRTC video, not the in-browser Godot client")
