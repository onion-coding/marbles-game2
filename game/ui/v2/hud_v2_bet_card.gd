class_name HudV2BetCard
extends PanelContainer

# Bet card per HUD Style Spec.md §Bet card.
#
# 3-row layout:
#   1. Bet amount input + repeat icon
#   2. Chip denominations (5/10/25/50/100/250) + trash
#   3. Full-width primary BET button
#
# Public API:
#   set_amount(value: float)
#   set_locked(locked: bool)        disable input + chips during LIVE
#   bet_pressed: signal(amount: float)
#   amount: float (read-only via get_amount())
#
# The card is always-rendered; the coordinator hides/shows it via show()/hide()
# and animates a fade-up on show via the parent's tween.

const T := preload("res://ui/v2/hud_v2_theme.gd")

signal bet_pressed(amount: float)

const W := 380.0

var _amount: float = 25.0
var _locked: bool = false
var _last_amount: float = 25.0   # remembered for the "repeat" button

var _input: LineEdit
var _input_dollar: Label
var _input_label: Label
var _repeat_btn: Button
var _bet_button: Button
var _chip_buttons: Array[Button] = []
var _trash_btn: Button
var _input_bump_tween: Tween

func _init() -> void:
	custom_minimum_size = Vector2(W, 0)
	add_theme_stylebox_override("panel", T.panel_style())

func _ready() -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	add_child(col)

	# ─── Row 1 — input + repeat ─────────────────────────────────────────────

	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 10)
	col.add_child(row1)

	var inputbox := VBoxContainer.new()
	inputbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inputbox.add_theme_constant_override("separation", 4)
	row1.add_child(inputbox)

	_input_label = Label.new()
	_input_label.text = "BET"
	_input_label.add_theme_font_override("font", T.font_mono(500))
	_input_label.add_theme_font_size_override("font_size", T.FS_LABEL_MONO)
	_input_label.add_theme_color_override("font_color", T.TEXT_FAINT)
	inputbox.add_child(_input_label)

	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 4)
	inputbox.add_child(input_row)

	_input_dollar = Label.new()
	_input_dollar.text = "$"
	_input_dollar.add_theme_font_override("font", T.font_display(600))
	_input_dollar.add_theme_font_size_override("font_size", T.FS_BET_NUMBER)
	_input_dollar.add_theme_color_override("font_color", T.TEXT_FAINT)
	input_row.add_child(_input_dollar)

	_input = LineEdit.new()
	_input.text = str(int(_amount))
	_input.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.add_theme_font_override("font", T.font_display(700))
	_input.add_theme_font_size_override("font_size", T.FS_BET_NUMBER)
	_input.add_theme_color_override("font_color", T.TEXT)
	_input.add_theme_color_override("caret_color", T.ACCENT)
	# LineEdit defaults to a chunky StyleBoxFlat — strip it down to plain.
	var input_sb := StyleBoxFlat.new()
	input_sb.bg_color = Color(0, 0, 0, 0)
	_input.add_theme_stylebox_override("normal",   input_sb)
	_input.add_theme_stylebox_override("focus",    input_sb)
	_input.add_theme_stylebox_override("read_only", input_sb)
	_input.text_changed.connect(_on_input_changed)
	_input.text_submitted.connect(_on_input_submitted)
	_input.gui_input.connect(_on_input_gui_input)
	input_row.add_child(_input)

	_repeat_btn = _make_icon_button("↻", _on_repeat_pressed)
	_repeat_btn.tooltip_text = "Repeat last bet"
	row1.add_child(_repeat_btn)

	# ─── Row 2 — chip denominations + trash ─────────────────────────────────

	var grid := GridContainer.new()
	grid.columns = T.DENOMINATIONS.size() + 1
	grid.add_theme_constant_override("h_separation", 1)
	grid.add_theme_constant_override("v_separation", 0)
	col.add_child(grid)

	for d in T.DENOMINATIONS:
		var b := _make_chip_button("+%d" % int(d))
		b.pressed.connect(_on_chip_pressed.bind(int(d)))
		_chip_buttons.append(b)
		grid.add_child(b)

	_trash_btn = _make_chip_button("🗑")
	_trash_btn.add_theme_color_override("font_color", T.BAD)
	_trash_btn.add_theme_color_override("font_hover_color", T.BAD)
	_trash_btn.pressed.connect(_on_trash_pressed)
	grid.add_child(_trash_btn)

	# ─── Row 3 — primary BET button ────────────────────────────────────────

	_bet_button = Button.new()
	_bet_button.text = "PLACE BET"
	_bet_button.custom_minimum_size = Vector2(0, 56)
	_bet_button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bet_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bet_button.add_theme_font_override("font", T.font_display(700))
	_bet_button.add_theme_font_size_override("font_size", T.FS_BET_BUTTON)
	_bet_button.add_theme_color_override("font_color", Color8(0x06, 0x20, 0x19))
	_bet_button.add_theme_color_override("font_hover_color", Color8(0x06, 0x20, 0x19))
	_bet_button.add_theme_color_override("font_pressed_color", Color8(0x06, 0x20, 0x19))
	_bet_button.add_theme_constant_override("h_separation", 0)
	_bet_button.add_theme_constant_override("outline_size", 0)
	var sb_idle := StyleBoxFlat.new()
	sb_idle.bg_color = T.GOOD
	sb_idle.set_corner_radius_all(10)
	sb_idle.set_content_margin_all(6)
	var sb_hover := sb_idle.duplicate()
	sb_hover.bg_color = Color8(0x34, 0xe6, 0xa8)
	sb_hover.shadow_size = 12
	sb_hover.shadow_color = Color(T.GOOD.r, T.GOOD.g, T.GOOD.b, 0.55)
	var sb_pressed := sb_idle.duplicate()
	sb_pressed.bg_color = Color8(0x24, 0xc9, 0x90)
	var sb_disabled := sb_idle.duplicate()
	sb_disabled.bg_color = Color8(0x40, 0x55, 0x4c)
	_bet_button.add_theme_stylebox_override("normal",   sb_idle)
	_bet_button.add_theme_stylebox_override("hover",    sb_hover)
	_bet_button.add_theme_stylebox_override("pressed",  sb_pressed)
	_bet_button.add_theme_stylebox_override("disabled", sb_disabled)
	_bet_button.pressed.connect(_on_bet_pressed)
	col.add_child(_bet_button)

# ─── Public API ─────────────────────────────────────────────────────────────

func set_amount(value: float) -> void:
	_amount = clampf(value, float(T.BET_MIN), float(T.BET_MAX))
	_input.text = str(int(_amount))
	_play_input_bump()

func get_amount() -> float:
	return _amount

func set_locked(locked: bool) -> void:
	_locked = locked
	_input.editable = not locked
	for b in _chip_buttons:
		b.disabled = locked
	_trash_btn.disabled = locked
	_repeat_btn.disabled = locked
	_bet_button.disabled = locked
	# Disabled visual: spec calls for grayscale + brightness loss — Godot
	# doesn't have an easy filter shader available without setup, so we
	# rely on the disabled StyleBox swap and modulate the whole card.
	modulate = Color(0.85, 0.85, 0.85, 1) if locked else Color(1, 1, 1, 1)

# ─── Helpers ────────────────────────────────────────────────────────────────

func _make_icon_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(44, 44)
	b.add_theme_font_override("font", T.font_display(500))
	b.add_theme_font_size_override("font_size", 18)
	b.add_theme_color_override("font_color", T.TEXT_DIM)
	b.add_theme_color_override("font_hover_color", T.TEXT)
	var sb_n := StyleBoxFlat.new()
	sb_n.bg_color = T.PANEL_2
	sb_n.border_color = T.BORDER
	sb_n.set_border_width_all(1)
	sb_n.set_corner_radius_all(8)
	var sb_h := sb_n.duplicate()
	sb_h.bg_color = Color8(0x16, 0x1a, 0x26)
	b.add_theme_stylebox_override("normal", sb_n)
	b.add_theme_stylebox_override("hover",  sb_h)
	b.add_theme_stylebox_override("pressed", sb_h)
	b.pressed.connect(cb)
	return b

func _make_chip_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 52)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_override("font", T.font_display(600))
	b.add_theme_font_size_override("font_size", T.FS_CHIP_VALUE)
	b.add_theme_color_override("font_color", T.TEXT)
	b.add_theme_color_override("font_hover_color", T.TEXT)
	var sb_n := StyleBoxFlat.new()
	sb_n.bg_color = T.PANEL
	sb_n.border_color = T.BORDER
	sb_n.border_width_right = 1
	sb_n.set_corner_radius_all(0)
	var sb_h := sb_n.duplicate()
	sb_h.bg_color = Color8(0x16, 0x1a, 0x26)
	var sb_p := sb_n.duplicate()
	sb_p.bg_color = Color8(0x1c, 0x20, 0x30)
	b.add_theme_stylebox_override("normal",  sb_n)
	b.add_theme_stylebox_override("hover",   sb_h)
	b.add_theme_stylebox_override("pressed", sb_p)
	return b

# ─── Input handlers ────────────────────────────────────────────────────────

func _on_input_changed(s: String) -> void:
	# Only digits — strip anything else as the user types.
	var clean := ""
	for ch in s:
		if ch >= "0" and ch <= "9":
			clean += ch
	if clean != s:
		var caret := _input.caret_column
		_input.text = clean
		_input.caret_column = min(caret, clean.length())

func _on_input_submitted(s: String) -> void:
	_commit_input(s)

func _on_input_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		# Up/down arrows nudge by 1 per spec.
		if event.keycode == KEY_UP:
			set_amount(_amount + 1)
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_DOWN:
			set_amount(_amount - 1)
			get_viewport().set_input_as_handled()

func _commit_input(s: String) -> void:
	var n: int = max(int(s), int(T.BET_MIN))
	set_amount(min(n, T.BET_MAX))

func _on_chip_pressed(value: int) -> void:
	set_amount(_amount + float(value))

func _on_trash_pressed() -> void:
	set_amount(float(T.BET_MIN))

func _on_repeat_pressed() -> void:
	set_amount(_last_amount)
	# Spin animation: full 360°.
	var t := create_tween()
	_repeat_btn.pivot_offset = _repeat_btn.size * 0.5
	t.tween_property(_repeat_btn, "rotation", TAU,
		T.T_REPEAT_SPIN).set_trans(Tween.TRANS_CUBIC)
	t.tween_callback(func() -> void: _repeat_btn.rotation = 0.0)

func _on_bet_pressed() -> void:
	if _locked:
		return
	_commit_input(_input.text)
	_last_amount = _amount
	bet_pressed.emit(_amount)

func _play_input_bump() -> void:
	if _input_bump_tween != null:
		_input_bump_tween.kill()
	_input_bump_tween = create_tween()
	_input_bump_tween.tween_property(_input, "position:y",
		_input.position.y - 2, T.T_NUM_BUMP * 0.5).set_trans(Tween.TRANS_CUBIC)
	_input_bump_tween.parallel().tween_property(_input, "scale",
		Vector2(1.04, 1.04), T.T_NUM_BUMP * 0.5).set_trans(Tween.TRANS_CUBIC)
	_input_bump_tween.tween_property(_input, "position:y",
		_input.position.y, T.T_NUM_BUMP * 0.5).set_trans(Tween.TRANS_CUBIC)
	_input_bump_tween.parallel().tween_property(_input, "scale",
		Vector2.ONE, T.T_NUM_BUMP * 0.5).set_trans(Tween.TRANS_CUBIC)
