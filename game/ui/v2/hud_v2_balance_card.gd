class_name HudV2BalanceCard
extends PanelContainer

# Balance card per HUD Style Spec.md §Balance card.
#
# Always-visible. Shows the wordmark, LIVE / IDLE pill, your balance with
# state-tinted glow, and three info chips (RTP / SEED / NEXT MAP).
#
# Public API:
#   set_balance(value: float, animate: bool = true)
#   set_live(live: bool)               # crossfades pink<->green glow + pill
#   set_seed(text: String)
#   set_next_map(text: String)
#   set_rtp(text: String)              # default "RTP 96.2%"

const T := preload("res://ui/v2/hud_v2_theme.gd")

const W := 340.0

var _wordmark: Label
var _accent_dot: Panel
var _live_pill: PanelContainer
var _live_pill_dot: Panel
var _live_pill_label: Label
var _balance_caption: Label
var _balance_glow: Control
var _chip_rtp_value: Label
var _chip_seed_value: Label
var _chip_next_value: Label

var _balance: float = 0.0
var _live: bool = false
var _bump_tween: Tween
var _flash_overlay: ColorRect
var _flash_tween: Tween
var _glow_tween: Tween
var _pill_dot_tween: Tween

func _init() -> void:
	custom_minimum_size = Vector2(W, 0)
	add_theme_stylebox_override("panel", T.panel_style())

func _ready() -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	add_child(col)

	# ─── Title bar ──────────────────────────────────────────────────────────

	var title := HBoxContainer.new()
	title.add_theme_constant_override("separation", 8)
	col.add_child(title)

	# Accent dot (10 px filled, 12-px glow approximated by a slightly larger
	# tinted panel behind).
	_accent_dot = Panel.new()
	_accent_dot.custom_minimum_size = Vector2(10, 10)
	var dot_sb := StyleBoxFlat.new()
	dot_sb.bg_color = T.ACCENT
	dot_sb.set_corner_radius_all(999)
	dot_sb.shadow_color = Color(T.ACCENT.r, T.ACCENT.g, T.ACCENT.b, 0.55)
	dot_sb.shadow_size = 8
	_accent_dot.add_theme_stylebox_override("panel", dot_sb)
	var dot_box := Control.new()
	dot_box.custom_minimum_size = Vector2(14, 14)
	dot_box.add_child(_accent_dot)
	_accent_dot.position = Vector2(2, 2)
	title.add_child(dot_box)

	_wordmark = Label.new()
	_wordmark.text = "MARBLES MAP"
	_wordmark.add_theme_font_override("font", T.font_display(700))
	_wordmark.add_theme_font_size_override("font_size", T.FS_BRAND)
	_wordmark.add_theme_color_override("font_color", T.TEXT)
	title.add_child(_wordmark)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_child(spacer)

	_live_pill = _make_live_pill()
	title.add_child(_live_pill)

	# ─── Balance caption + number ───────────────────────────────────────────

	_balance_caption = Label.new()
	_balance_caption.text = "YOUR BALANCE"
	_balance_caption.add_theme_font_override("font", T.font_mono(500))
	_balance_caption.add_theme_font_size_override("font_size", T.FS_LABEL_MONO)
	_balance_caption.add_theme_color_override("font_color", T.TEXT_DIM)
	_balance_caption.add_theme_constant_override("shadow_offset_x", 0)
	col.add_child(_balance_caption)

	_balance_glow = T.make_glow_label("$0.00", T.font_display(700),
		T.FS_BALANCE, T.TEXT, T.ACCENT)
	_balance_glow.custom_minimum_size = Vector2(W - 40, 56)
	col.add_child(_balance_glow)

	# Tabular nums via opentype features — applied to the foreground label.
	var fore := _balance_glow.get_meta("fore_label") as Label
	if fore != null:
		fore.add_theme_constant_override("outline_size", 0)
	_flash_overlay = ColorRect.new()
	_flash_overlay.color = Color(0, 0, 0, 0)
	_flash_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_balance_glow.add_child(_flash_overlay)

	# ─── Chip row ───────────────────────────────────────────────────────────

	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 6)
	col.add_child(chips)
	_chip_rtp_value  = _make_chip(chips, "RTP",      "96.2%")
	_chip_seed_value = _make_chip(chips, "SEED",     "—")
	_chip_next_value = _make_chip(chips, "NEXT MAP", "PLINKO")

	_set_live_internal(false, true)

# ─── Public API ─────────────────────────────────────────────────────────────

func set_balance(value: float, animate: bool = true) -> void:
	var prev := _balance
	_balance = value
	T.set_glow_text(_balance_glow, "$%s" % _format_money(value))
	if not animate:
		return
	_play_bump()
	if not is_equal_approx(prev, value):
		_play_delta_flash(value > prev)

func set_live(live: bool) -> void:
	if live == _live:
		return
	_set_live_internal(live, false)

func set_seed(text: String) -> void:
	_chip_seed_value.text = text

func set_next_map(text: String) -> void:
	_chip_next_value.text = text

func set_rtp(text: String) -> void:
	_chip_rtp_value.text = text

# ─── Internals ──────────────────────────────────────────────────────────────

func _set_live_internal(live: bool, instant: bool) -> void:
	_live = live
	var fg: Color = T.TEXT
	var glow: Color = T.GOOD if live else T.ACCENT
	if instant:
		T.set_glow_colours(_balance_glow, fg, glow)
	else:
		_crossfade_glow(glow)
	_apply_pill_state(live)

func _apply_pill_state(live: bool) -> void:
	var pill_bg: Color = T.PANEL_2
	var pill_border: Color = (
		Color(T.GOOD.r, T.GOOD.g, T.GOOD.b, 0.35) if live else T.BORDER)
	var dot_color: Color = T.GOOD if live else T.BAD
	var label_text: String = "LIVE" if live else "IDLE"
	var label_color: Color = T.GOOD if live else T.TEXT_DIM

	var sb := T.pill_style(pill_bg, pill_border)
	if live:
		sb.shadow_color = Color(T.GOOD.r, T.GOOD.g, T.GOOD.b, 0.18)
		sb.shadow_size = 18
	_live_pill.add_theme_stylebox_override("panel", sb)
	_live_pill_label.text = label_text
	_live_pill_label.add_theme_color_override("font_color", label_color)

	var dot_sb := StyleBoxFlat.new()
	dot_sb.bg_color = dot_color
	dot_sb.set_corner_radius_all(999)
	dot_sb.shadow_color = Color(dot_color.r, dot_color.g, dot_color.b, 0.5)
	dot_sb.shadow_size = 6
	_live_pill_dot.add_theme_stylebox_override("panel", dot_sb)

	# In IDLE the dot pulses; in LIVE it sits steady.
	if _pill_dot_tween != null:
		_pill_dot_tween.kill()
	_live_pill_dot.modulate = Color(1, 1, 1, 1)
	_live_pill_dot.scale = Vector2.ONE
	_live_pill_dot.pivot_offset = _live_pill_dot.size * 0.5
	if not live:
		_pill_dot_tween = create_tween().set_loops()
		_pill_dot_tween.tween_property(_live_pill_dot, "scale",
			Vector2(1.4, 1.4), T.T_PILL_DOT_PULSE * 0.5).set_trans(Tween.TRANS_SINE)
		_pill_dot_tween.parallel().tween_property(_live_pill_dot, "modulate:a",
			0.6, T.T_PILL_DOT_PULSE * 0.5).set_trans(Tween.TRANS_SINE)
		_pill_dot_tween.tween_property(_live_pill_dot, "scale",
			Vector2.ONE, T.T_PILL_DOT_PULSE * 0.5).set_trans(Tween.TRANS_SINE)
		_pill_dot_tween.parallel().tween_property(_live_pill_dot, "modulate:a",
			1.0, T.T_PILL_DOT_PULSE * 0.5).set_trans(Tween.TRANS_SINE)

func _crossfade_glow(target_glow: Color) -> void:
	if _glow_tween != null:
		_glow_tween.kill()
	var blur := _balance_glow.get_meta("blur_label") as Label
	if blur == null:
		return
	var start: Color = blur.get_theme_color("font_color")
	_glow_tween = create_tween()
	_glow_tween.tween_method(func(c: Color) -> void:
			blur.add_theme_color_override("font_color", c),
		start, target_glow, T.T_GLOW_CROSSFADE).set_trans(Tween.TRANS_SINE)

func _play_bump() -> void:
	if _bump_tween != null:
		_bump_tween.kill()
	_balance_glow.pivot_offset = _balance_glow.size * 0.5
	_bump_tween = create_tween()
	_bump_tween.tween_property(_balance_glow, "position:y",
		_balance_glow.position.y - 4, T.T_NUM_BUMP * 0.5).set_trans(Tween.TRANS_CUBIC)
	_bump_tween.parallel().tween_property(_balance_glow, "scale",
		Vector2(1.06, 1.06), T.T_NUM_BUMP * 0.5).set_trans(Tween.TRANS_CUBIC)
	_bump_tween.tween_property(_balance_glow, "position:y",
		_balance_glow.position.y, T.T_NUM_BUMP * 0.5).set_trans(Tween.TRANS_CUBIC)
	_bump_tween.parallel().tween_property(_balance_glow, "scale",
		Vector2.ONE, T.T_NUM_BUMP * 0.5).set_trans(Tween.TRANS_CUBIC)

func _play_delta_flash(positive: bool) -> void:
	if _flash_tween != null:
		_flash_tween.kill()
	var tint: Color = T.GOOD if positive else T.BAD
	_flash_overlay.color = Color(tint.r, tint.g, tint.b, 0.32)
	_flash_tween = create_tween()
	_flash_tween.tween_property(_flash_overlay, "color:a", 0.0,
		T.T_DELTA_FLASH).set_trans(Tween.TRANS_SINE)

func _make_live_pill() -> PanelContainer:
	var pill := PanelContainer.new()
	pill.add_theme_stylebox_override("panel", T.pill_style())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	pill.add_child(row)

	_live_pill_dot = Panel.new()
	_live_pill_dot.custom_minimum_size = Vector2(8, 8)
	var dot_box := Control.new()
	dot_box.custom_minimum_size = Vector2(10, 10)
	_live_pill_dot.position = Vector2(1, 1)
	dot_box.add_child(_live_pill_dot)
	row.add_child(dot_box)

	_live_pill_label = Label.new()
	_live_pill_label.text = "IDLE"
	_live_pill_label.add_theme_font_override("font", T.font_mono(600))
	_live_pill_label.add_theme_font_size_override("font_size", T.FS_LABEL_MONO)
	_live_pill_label.add_theme_color_override("font_color", T.TEXT_DIM)
	row.add_child(_live_pill_label)
	return pill

func _make_chip(parent: Control, label_text: String, value: String) -> Label:
	var chip := PanelContainer.new()
	chip.add_theme_stylebox_override("panel", T.pill_style(T.PANEL_2))
	parent.add_child(chip)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	chip.add_child(row)

	var lab := Label.new()
	lab.text = label_text
	lab.add_theme_font_override("font", T.font_mono(500))
	lab.add_theme_font_size_override("font_size", T.FS_CHIP_MONO)
	lab.add_theme_color_override("font_color", T.TEXT_FAINT)
	row.add_child(lab)

	var val := Label.new()
	val.text = value
	val.add_theme_font_override("font", T.font_mono(600))
	val.add_theme_font_size_override("font_size", T.FS_CHIP_MONO)
	val.add_theme_color_override("font_color", T.TEXT_DIM)
	row.add_child(val)
	return val

# Compact USD formatting: thousands separator, 2 decimals, no minus sign on
# zero. Negative balances are conceivable in test code so handle the sign
# explicitly.
func _format_money(v: float) -> String:
	var sign_str := "-" if v < 0.0 else ""
	v = abs(v)
	var whole := int(v)
	var cents := int(round((v - float(whole)) * 100.0))
	var s := str(whole)
	var with_commas := ""
	for i in range(s.length()):
		if i > 0 and (s.length() - i) % 3 == 0:
			with_commas += ","
		with_commas += s[i]
	return "%s%s.%02d" % [sign_str, with_commas, cents]
