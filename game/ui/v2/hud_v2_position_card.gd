class_name HudV2PositionCard
extends PanelContainer

# Position card per HUD Style Spec.md §Position card.
#
# Visible only during LIVE state. Two rows:
#   1. Headline standing: POS / MULT / GAP, divided by vertical borders.
#   2. Race ladder: ±1 row around the player's marble.
#   (+ optional inline event ticker beneath, fade in/out chips)
#
# Public API:
#   set_field_size(n: int)
#   set_player_marble_idx(idx: int)
#   apply_standings(rows: Array)   each row = {idx: int, name: String,
#                                              colour: Color, gap_sec: float}
#   set_player_multiplier(mult: float)
#   push_event(text: String)
#   reset()

const T := preload("res://ui/v2/hud_v2_theme.gd")

const W := 380.0

var _pos_glow: Control                # POS ordinal with glow
var _pos_subscript: Label             # /N
var _mult_label: Label
var _gap_label: Label

var _ladder: VBoxContainer
var _ticker: VBoxContainer

var _player_idx: int = -1
var _field_size: int = 30
var _last_pos: int = -1
var _pos_bump_tween: Tween
var _pos_flash_tween: Tween

# Cached ticker chip-removal timers so we don't leak Tweens when chips are
# popped early by the FIFO cap.
var _ticker_chips: Array[Control] = []

func _init() -> void:
	custom_minimum_size = Vector2(W, 0)
	add_theme_stylebox_override("panel", T.panel_style())

func _ready() -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	add_child(col)

	# ─── Row 1 — POS / MULT / GAP ───────────────────────────────────────────

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	col.add_child(head)

	var pos_box := _make_metric_box("POS")
	head.add_child(pos_box)
	_pos_glow = T.make_glow_label("—", T.font_display(700),
		T.FS_POS_HEADLINE, T.TEXT, T.ACCENT)
	_pos_glow.custom_minimum_size = Vector2(64, 48)
	pos_box.get_node("Body").add_child(_pos_glow)
	_pos_subscript = Label.new()
	_pos_subscript.text = "/%d" % _field_size
	_pos_subscript.add_theme_font_override("font", T.font_mono(500))
	_pos_subscript.add_theme_font_size_override("font_size", 12)
	_pos_subscript.add_theme_color_override("font_color", T.TEXT_FAINT)
	pos_box.get_node("Body").add_child(_pos_subscript)

	head.add_child(_make_separator())

	var mult_box := _make_metric_box("MULT")
	head.add_child(mult_box)
	_mult_label = Label.new()
	_mult_label.text = "× 1.0"
	_mult_label.add_theme_font_override("font", T.font_display(700))
	_mult_label.add_theme_font_size_override("font_size", T.FS_POS_MULT)
	_mult_label.add_theme_color_override("font_color", T.MULT_POS)
	mult_box.get_node("Body").add_child(_mult_label)

	head.add_child(_make_separator())

	var gap_box := _make_metric_box("GAP")
	head.add_child(gap_box)
	_gap_label = Label.new()
	_gap_label.text = "LEAD"
	_gap_label.add_theme_font_override("font", T.font_mono(600))
	_gap_label.add_theme_font_size_override("font_size", T.FS_POS_GAP)
	_gap_label.add_theme_color_override("font_color", T.TEXT_DIM)
	gap_box.get_node("Body").add_child(_gap_label)

	# ─── Row 2 — race ladder ───────────────────────────────────────────────

	_ladder = VBoxContainer.new()
	_ladder.add_theme_constant_override("separation", 4)
	col.add_child(_ladder)

	# ─── Optional ticker (chips beneath ladder) ─────────────────────────────

	_ticker = VBoxContainer.new()
	_ticker.add_theme_constant_override("separation", 3)
	col.add_child(_ticker)

# ─── Public API ─────────────────────────────────────────────────────────────

func set_field_size(n: int) -> void:
	_field_size = n
	_pos_subscript.text = "/%d" % n

func set_player_marble_idx(idx: int) -> void:
	_player_idx = idx

# `rows` is the standings array sorted by current rank (1st first). Each row:
#   {idx: int, name: String, colour: Color, gap_sec: float}
func apply_standings(rows: Array) -> void:
	# Headline values — find player row.
	var player_rank := -1
	var player_gap := 0.0
	for i in range(rows.size()):
		var r: Dictionary = rows[i]
		if int(r.get("idx", -1)) == _player_idx:
			player_rank = i + 1
			player_gap = float(r.get("gap_sec", 0.0))
			break

	if player_rank > 0:
		_set_pos(player_rank)
		_set_gap(player_rank == 1, player_gap)

	# Ladder: window of ±LADDER_WINDOW around the player.
	_render_ladder(rows, player_rank)

func set_player_multiplier(mult: float) -> void:
	_mult_label.text = "× %.1f" % mult
	var target: Color = T.MULT_POS if mult >= 1.0 else T.MULT_NEG
	var start: Color = _mult_label.get_theme_color("font_color")
	var t := create_tween()
	t.tween_method(func(c: Color) -> void:
			_mult_label.add_theme_color_override("font_color", c),
		start, target, T.T_GLOW_CROSSFADE).set_trans(Tween.TRANS_SINE)

func push_event(text: String) -> void:
	if _ticker_chips.size() >= T.TICKER_MAX:
		_kill_chip(_ticker_chips[0])
	var chip := _make_event_chip(text)
	_ticker.add_child(chip)
	_ticker_chips.append(chip)
	# Fade in.
	chip.modulate = Color(1, 1, 1, 0)
	create_tween().tween_property(chip, "modulate:a", 1.0,
		T.T_TICKER_IN).set_trans(Tween.TRANS_SINE)
	# Schedule fade out + free.
	get_tree().create_timer(T.TICKER_LIFESPAN).timeout.connect(func() -> void:
		_kill_chip(chip))

func reset() -> void:
	_player_idx = -1
	_last_pos = -1
	T.set_glow_text(_pos_glow, "—")
	_mult_label.text = "× 1.0"
	_mult_label.add_theme_color_override("font_color", T.MULT_POS)
	_gap_label.text = "LEAD"
	_gap_label.add_theme_color_override("font_color", T.TEXT_DIM)
	for c in _ladder.get_children():
		c.queue_free()
	for c in _ticker_chips:
		_kill_chip(c)
	_ticker_chips.clear()

# ─── Internals ──────────────────────────────────────────────────────────────

func _set_pos(rank: int) -> void:
	T.set_glow_text(_pos_glow, _ordinal(rank))
	if _last_pos > 0 and rank != _last_pos:
		_play_pos_bump()
		_play_pos_flash(rank < _last_pos)    # rank decreased = moved UP
	_last_pos = rank

func _set_gap(is_leader: bool, gap_sec: float) -> void:
	if is_leader:
		_gap_label.text = "LEAD"
		_gap_label.add_theme_color_override("font_color", T.TEXT_DIM)
	else:
		_gap_label.text = "+%.1fs" % gap_sec
		_gap_label.add_theme_color_override("font_color",
			T.BAD if gap_sec >= T.GAP_DANGER_SEC else T.TEXT)

func _ordinal(n: int) -> String:
	if n <= 0:
		return "—"
	var suffix := "th"
	var mod100 := n % 100
	if mod100 < 11 or mod100 > 13:
		match n % 10:
			1: suffix = "st"
			2: suffix = "nd"
			3: suffix = "rd"
	return "%d%s" % [n, suffix]

func _render_ladder(rows: Array, player_rank: int) -> void:
	# Clear & rebuild — simpler than diffing each tick. Spec asks for a
	# 240-ms FLIP; we approximate by fading in new rows on each refresh.
	for c in _ladder.get_children():
		c.queue_free()
	if player_rank <= 0:
		return
	var lo: int = int(max(1, player_rank - T.LADDER_WINDOW))
	var hi: int = int(min(rows.size(), player_rank + T.LADDER_WINDOW))
	for r in range(lo, hi + 1):
		var row: Dictionary = rows[r - 1]
		var entry := _make_ladder_entry(r, row, r == player_rank)
		_ladder.add_child(entry)

func _make_metric_box(label_text: String) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 4)
	var head := Label.new()
	head.text = label_text
	head.add_theme_font_override("font", T.font_mono(500))
	head.add_theme_font_size_override("font_size", T.FS_LABEL_MONO)
	head.add_theme_color_override("font_color", T.TEXT_FAINT)
	v.add_child(head)
	var body := HBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", 4)
	v.add_child(body)
	return v

func _make_separator() -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(1, 40)
	var sb := StyleBoxFlat.new()
	sb.bg_color = T.BORDER
	p.add_theme_stylebox_override("panel", sb)
	return p

func _make_ladder_entry(rank: int, row: Dictionary, is_player: bool) -> Control:
	var pc := PanelContainer.new()
	if is_player:
		var sb := StyleBoxFlat.new()
		sb.border_color = T.ACCENT
		sb.border_width_left = 1
		sb.set_corner_radius_all(0)
		sb.set_content_margin_all(0)
		sb.content_margin_left = 8
		sb.content_margin_top = 4
		sb.content_margin_right = 4
		sb.content_margin_bottom = 4
		pc.add_theme_stylebox_override("panel", sb)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	pc.add_child(hb)

	var rank_lab := Label.new()
	rank_lab.text = "%d." % rank
	rank_lab.custom_minimum_size = Vector2(28, 0)
	rank_lab.add_theme_font_override("font", T.font_mono(500))
	rank_lab.add_theme_font_size_override("font_size", T.FS_LADDER_MONO)
	rank_lab.add_theme_color_override("font_color",
		T.TEXT if is_player else T.TEXT_DIM)
	hb.add_child(rank_lab)

	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(8, 8)
	var dot_sb := StyleBoxFlat.new()
	dot_sb.bg_color = row.get("colour", Color.WHITE)
	dot_sb.set_corner_radius_all(999)
	dot.add_theme_stylebox_override("panel", dot_sb)
	var dot_box := Control.new()
	dot_box.custom_minimum_size = Vector2(10, 10)
	dot.position = Vector2(1, 1)
	dot_box.add_child(dot)
	hb.add_child(dot_box)

	var name_lab := Label.new()
	name_lab.text = "YOU" if is_player else String(row.get("name", "—"))
	name_lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lab.add_theme_font_override("font", T.font_mono(500))
	name_lab.add_theme_font_size_override("font_size", T.FS_LADDER_MONO)
	name_lab.add_theme_color_override("font_color",
		T.TEXT if is_player else T.TEXT_DIM)
	hb.add_child(name_lab)

	var gap_lab := Label.new()
	var gap_sec := float(row.get("gap_sec", 0.0))
	gap_lab.text = "——" if (is_player and gap_sec == 0.0) else (
		"+%.1fs" % gap_sec if gap_sec >= 0.0 else "%.1fs" % gap_sec)
	gap_lab.add_theme_font_override("font", T.font_mono(500))
	gap_lab.add_theme_font_size_override("font_size", T.FS_LADDER_MONO)
	gap_lab.add_theme_color_override("font_color",
		T.TEXT if is_player else T.TEXT_DIM)
	hb.add_child(gap_lab)
	return pc

func _make_event_chip(text: String) -> Control:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", T.pill_style(T.PANEL_2))
	var lab := Label.new()
	lab.text = text
	lab.add_theme_font_override("font", T.font_mono(500))
	lab.add_theme_font_size_override("font_size", T.FS_TICKER_MONO)
	lab.add_theme_color_override("font_color", T.TEXT_DIM)
	pc.add_child(lab)
	return pc

func _kill_chip(chip: Control) -> void:
	if chip == null or not is_instance_valid(chip):
		return
	if chip in _ticker_chips:
		_ticker_chips.erase(chip)
	var t := create_tween()
	t.tween_property(chip, "modulate:a", 0.0, T.T_TICKER_OUT)
	t.tween_callback(func() -> void:
		if is_instance_valid(chip):
			chip.queue_free())

func _play_pos_bump() -> void:
	if _pos_bump_tween != null:
		_pos_bump_tween.kill()
	_pos_glow.pivot_offset = _pos_glow.size * 0.5
	_pos_bump_tween = create_tween()
	_pos_bump_tween.tween_property(_pos_glow, "scale",
		Vector2(1.06, 1.06), T.T_NUM_BUMP * 0.5).set_trans(Tween.TRANS_CUBIC)
	_pos_bump_tween.tween_property(_pos_glow, "scale",
		Vector2.ONE, T.T_NUM_BUMP * 0.5).set_trans(Tween.TRANS_CUBIC)

func _play_pos_flash(moved_up: bool) -> void:
	if _pos_flash_tween != null:
		_pos_flash_tween.kill()
	var glow_color: Color = T.GOOD if moved_up else T.BAD
	# Briefly tint the foreground label of the glow widget.
	var fore := _pos_glow.get_meta("fore_label") as Label
	if fore == null:
		return
	var start: Color = fore.get_theme_color("font_color")
	_pos_flash_tween = create_tween()
	_pos_flash_tween.tween_method(func(c: Color) -> void:
			fore.add_theme_color_override("font_color", c),
		glow_color, start, T.T_DELTA_FLASH).set_trans(Tween.TRANS_SINE)
