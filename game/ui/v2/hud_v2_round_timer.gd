class_name HudV2RoundTimer
extends PanelContainer

# Round timer per HUD Style Spec.md §Round timer.
#
# Two-line layout:
#   "Round starts in" mono caps caption + clock (M:SS)
#   6-px progress bar that drains left-to-right linearly over the round.
#
# Tints: green (>50%) → amber (≤50%) → red (≤20%, with 0.8 s pulse).
#
# Public API:
#   start(seconds: float)   begin a fresh countdown
#   pause()                 freeze the bar at its current value
#   resume()                continue from pause
#   stop()                  hide the timer (idle state)
#   set_running(bool)       expose state to coordinator
#   remaining: float        read-only; how many seconds left
#   finished: signal()      fires once when the bar empties

const T := preload("res://ui/v2/hud_v2_theme.gd")

signal finished()

const W := 340.0

var _label: Label
var _clock: Label
var _bar_track: PanelContainer
var _bar_fill: Panel

var _total: float = 0.0
var _remaining: float = 0.0
var _running: bool = false
var _state_color: Color = T.TIMER_OK
var _danger_pulse: Tween

func _init() -> void:
	custom_minimum_size = Vector2(W, 0)
	add_theme_stylebox_override("panel", T.panel_style())
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	add_child(col)

	# Top row: caption left + clock right.
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	col.add_child(top)

	_label = Label.new()
	_label.text = "ROUND STARTS IN"
	_label.add_theme_font_override("font", T.font_mono(500))
	_label.add_theme_font_size_override("font_size", T.FS_LABEL_MONO)
	_label.add_theme_color_override("font_color", T.TEXT_FAINT)
	top.add_child(_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)

	_clock = Label.new()
	_clock.text = "0:00"
	_clock.add_theme_font_override("font", T.font_display(600))
	_clock.add_theme_font_size_override("font_size", T.FS_TIMER_CLOCK)
	_clock.add_theme_color_override("font_color", _state_color)
	top.add_child(_clock)

	# Bottom row: 6-px progress bar (track + fill panel).
	_bar_track = PanelContainer.new()
	_bar_track.custom_minimum_size = Vector2(0, 6)
	var track_sb := StyleBoxFlat.new()
	track_sb.bg_color = Color(1, 1, 1, 0.14)
	track_sb.set_corner_radius_all(3)
	_bar_track.add_theme_stylebox_override("panel", track_sb)
	col.add_child(_bar_track)

	_bar_fill = Panel.new()
	_bar_fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bar_track.add_child(_bar_fill)
	_apply_state_color(_state_color)
	visible = false

func _process(delta: float) -> void:
	if not _running:
		return
	_remaining = max(0.0, _remaining - delta)
	_refresh_clock()
	_refresh_bar()
	_refresh_color_state()
	if _remaining <= 0.0:
		_running = false
		visible = false
		finished.emit()

# ─── Public API ─────────────────────────────────────────────────────────────

func start(seconds: float) -> void:
	_total = max(seconds, 0.001)
	_remaining = _total
	_running = true
	visible = true
	_apply_state_color(T.TIMER_OK)
	_state_color = T.TIMER_OK
	_kill_pulse()
	_refresh_clock()
	_refresh_bar()

func pause() -> void:
	_running = false

func resume() -> void:
	if _remaining > 0.0:
		_running = true

func stop() -> void:
	_running = false
	visible = false
	_kill_pulse()

func set_running(running: bool) -> void:
	_running = running

func remaining() -> float:
	return _remaining

# ─── Internals ──────────────────────────────────────────────────────────────

func _refresh_clock() -> void:
	# M:SS format. Round up so the player sees "0:01" for the final second.
	var s_total: int = int(ceil(_remaining))
	var m: int = s_total / 60
	var s: int = s_total % 60
	_clock.text = "%d:%02d" % [m, s]

func _refresh_bar() -> void:
	var pct: float = clampf(_remaining / _total, 0.0, 1.0)
	# Fill anchored to track left, width = pct * track width.
	var track_w := _bar_track.size.x
	if track_w <= 0.0:
		track_w = _bar_track.custom_minimum_size.x
	_bar_fill.size = Vector2(track_w * pct, 6)
	_bar_fill.position = Vector2(0, 0)

func _refresh_color_state() -> void:
	var pct: float = _remaining / _total
	var target_color: Color
	if pct > T.WARN_PCT:
		target_color = T.TIMER_OK
	elif pct > T.DANGER_PCT:
		target_color = T.TIMER_WARN
	else:
		target_color = T.TIMER_DANGER

	if target_color != _state_color:
		_state_color = target_color
		_apply_state_color(target_color)
		# Pulse only in the final-band (≤20%) state.
		_kill_pulse()
		if target_color == T.TIMER_DANGER:
			_danger_pulse = create_tween().set_loops()
			_danger_pulse.tween_property(_bar_fill, "modulate:a",
				0.6, T.T_TIMER_DANGER * 0.5).set_trans(Tween.TRANS_SINE)
			_danger_pulse.tween_property(_bar_fill, "modulate:a",
				1.0, T.T_TIMER_DANGER * 0.5).set_trans(Tween.TRANS_SINE)

func _apply_state_color(c: Color) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(3)
	sb.shadow_color = Color(c.r, c.g, c.b, 0.6)
	sb.shadow_size = 8
	_bar_fill.add_theme_stylebox_override("panel", sb)
	# Crossfade clock font colour.
	var ct := create_tween()
	var start: Color = _clock.get_theme_color("font_color")
	ct.tween_method(func(col: Color) -> void:
			_clock.add_theme_color_override("font_color", col),
		start, c, T.T_TIMER_COLOR).set_trans(Tween.TRANS_SINE)

func _kill_pulse() -> void:
	if _danger_pulse != null:
		_danger_pulse.kill()
		_danger_pulse = null
	_bar_fill.modulate = Color(1, 1, 1, 1)
