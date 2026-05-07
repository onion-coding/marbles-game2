class_name HudV2
extends CanvasLayer

# HUD v2 — coordinator + state machine, built against HUD Style Spec.md.
#
# Owns the four cards (balance, round timer, bet, position) and the round
# state machine (IDLE → LIVE → RESOLVE → IDLE). Drives card visibility,
# card-to-card data flow, and the local balance/multiplier model.
#
# Public API used by main.gd interactive mode:
#   set_player_marble_idx(idx: int)             pick which marble is the player's
#   set_track_name(name: String)
#   begin_idle(seconds: float)                  start a fresh IDLE countdown
#   begin_live(round_id: int)                   timer hit 0 / debug force-start
#   begin_resolve(winner_idx: int, payouts: Dictionary)  race ended
#   apply_settlement_balance(delta: float)      credit/debit the balance
#   add_finisher(idx: int, color: Color, name: String)   push to ticker
#   update_standings(rows: Array)               same shape as PositionCard
#   update_player_multiplier(mult: float)
#
# Signals:
#   bet_placed(amount: float)                   user pressed BET in IDLE
#   force_start_requested()                     debug button: skip waiting
#
# State semantics:
#   IDLE     — round timer counting down; bet card unlocked; balance pink.
#   LIVE     — race running; bet card locked; balance green; position card up.
#   RESOLVE  — winner revealed; balance flashes win/loss; bet card locked.

const T := preload("res://ui/v2/hud_v2_theme.gd")
const HudV2BalanceCardClass  := preload("res://ui/v2/hud_v2_balance_card.gd")
const HudV2RoundTimerClass   := preload("res://ui/v2/hud_v2_round_timer.gd")
const HudV2BetCardClass      := preload("res://ui/v2/hud_v2_bet_card.gd")
const HudV2PositionCardClass := preload("res://ui/v2/hud_v2_position_card.gd")

signal bet_placed(amount: float)
signal force_start_requested()

const PHASE_IDLE    := "IDLE"
const PHASE_LIVE    := "LIVE"
const PHASE_RESOLVE := "RESOLVE"

const MARGIN := 24

var _balance_card: HudV2BalanceCardClass
var _round_timer: HudV2RoundTimerClass
var _bet_card: HudV2BetCardClass
var _position_card: HudV2PositionCardClass

var _phase: String = PHASE_IDLE
var _player_marble_idx: int = -1
var _track_name: String = "PLINKO"
var _balance: float = 1000.0
var _open_bet_amount: float = 0.0          # debited when LIVE begins, settled in RESOLVE
var _resolve_message: Label
var _debug_panel: Control

func _init() -> void:
	layer = 100

func _ready() -> void:
	# Left-side stack of cards. The legacy HUD owns the right edge (timing
	# tower / finishers list), so the v2 overlay sits on the left. Top-bar
	# clearance (~120 px) keeps the balance card below the legacy brand /
	# track-name strip.
	var stack := VBoxContainer.new()
	stack.name = "Stack"
	stack.add_theme_constant_override("separation", 12)
	stack.anchor_left   = 0.0
	stack.anchor_right  = 0.0
	stack.anchor_top    = 0.0
	stack.anchor_bottom = 1.0
	stack.offset_left   = MARGIN
	stack.offset_right  = MARGIN + 380
	stack.offset_top    = MARGIN + 96
	stack.offset_bottom = -MARGIN
	stack.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	stack.alignment = BoxContainer.ALIGNMENT_BEGIN
	add_child(stack)

	# Build cards first, parent them, THEN seed initial values — Godot's
	# _ready() fires when a node enters the tree, and most card setters
	# touch nodes built inside _ready, so calling them before add_child()
	# blows up with "method called on null".
	_balance_card = HudV2BalanceCardClass.new()
	stack.add_child(_balance_card)
	_balance_card.set_balance(_balance, false)
	_balance_card.set_seed("—")
	_balance_card.set_next_map(_track_name)

	_position_card = HudV2PositionCardClass.new()
	stack.add_child(_position_card)
	_position_card.visible = false

	_round_timer = HudV2RoundTimerClass.new()
	stack.add_child(_round_timer)
	_round_timer.finished.connect(_on_round_timer_finished)

	_bet_card = HudV2BetCardClass.new()
	stack.add_child(_bet_card)
	_bet_card.bet_pressed.connect(_on_bet_pressed)

	_resolve_message = Label.new()
	_resolve_message.add_theme_font_override("font", T.font_mono(500))
	_resolve_message.add_theme_font_size_override("font_size", 11)
	_resolve_message.add_theme_color_override("font_color", T.TEXT_DIM)
	_resolve_message.visible = false
	stack.add_child(_resolve_message)

	_debug_panel = _build_debug_panel()
	_debug_panel.anchor_left   = 0.0
	_debug_panel.anchor_right  = 0.0
	_debug_panel.anchor_top    = 1.0
	_debug_panel.anchor_bottom = 1.0
	_debug_panel.offset_left   = MARGIN
	_debug_panel.offset_top    = -120
	_debug_panel.offset_right  = MARGIN + 200
	_debug_panel.offset_bottom = -MARGIN
	add_child(_debug_panel)

	_play_card_show(_balance_card, 0.0)
	_play_card_show(_bet_card, 0.08)

# ─── Public API ─────────────────────────────────────────────────────────────

func set_player_marble_idx(idx: int) -> void:
	_player_marble_idx = idx
	_position_card.set_player_marble_idx(idx)

func set_track_name(name: String) -> void:
	_track_name = name.to_upper()
	_balance_card.set_next_map(_track_name)

func set_field_size(n: int) -> void:
	_position_card.set_field_size(n)

func set_seed(text: String) -> void:
	_balance_card.set_seed(text)

func begin_idle(seconds: float) -> void:
	_phase = PHASE_IDLE
	_balance_card.set_live(false)
	_bet_card.set_locked(false)
	_position_card.visible = false
	_resolve_message.visible = false
	_round_timer.start(seconds)

func begin_live(round_id: int) -> void:
	_phase = PHASE_LIVE
	_balance_card.set_live(true)
	_bet_card.set_locked(true)
	_round_timer.stop()
	_resolve_message.visible = false
	_position_card.reset()
	if _player_marble_idx >= 0:
		_position_card.set_player_marble_idx(_player_marble_idx)
	_position_card.visible = true
	_play_card_show(_position_card, 0.0)
	# Debit any pending bet — balance flashes red.
	if _open_bet_amount > 0.0:
		_balance -= _open_bet_amount
		_balance_card.set_balance(_balance)
	_balance_card.set_seed("#%05d" % (round_id % 100000))

func begin_resolve(winner_idx: int, payouts: Dictionary) -> void:
	_phase = PHASE_RESOLVE
	_position_card.visible = false
	# Settle: payouts is keyed by marble idx → multiplier (raw float, e.g. 9.0 for
	# a 1st-place hit, 0 for a loss). Player's resolved amount = bet × payout.
	var win_mult: float = float(payouts.get(_player_marble_idx, 0.0))
	var winnings: float = _open_bet_amount * win_mult
	_balance += winnings
	_balance_card.set_balance(_balance)
	if _open_bet_amount > 0.0:
		var net: float = winnings - _open_bet_amount
		var winner_msg: String = "Winner: marble #%d" % winner_idx
		if net > 0.0:
			_resolve_message.text = "%s   (+$%s)" % [winner_msg, _fmt(net)]
			_resolve_message.add_theme_color_override("font_color", T.GOOD)
		elif net < 0.0:
			_resolve_message.text = "%s   (−$%s)" % [winner_msg, _fmt(-net)]
			_resolve_message.add_theme_color_override("font_color", T.BAD)
		else:
			_resolve_message.text = "%s   (push)" % winner_msg
			_resolve_message.add_theme_color_override("font_color", T.TEXT_DIM)
	else:
		_resolve_message.text = "Winner: marble #%d" % winner_idx
		_resolve_message.add_theme_color_override("font_color", T.TEXT_DIM)
	_resolve_message.visible = true
	_open_bet_amount = 0.0

func apply_settlement_balance(delta: float) -> void:
	_balance += delta
	_balance_card.set_balance(_balance)

func update_standings(rows: Array) -> void:
	if _phase == PHASE_LIVE:
		_position_card.apply_standings(rows)

func update_player_multiplier(mult: float) -> void:
	_position_card.set_player_multiplier(mult)

func push_event(text: String) -> void:
	_position_card.push_event(text)

func get_balance() -> float:
	return _balance

func get_phase() -> String:
	return _phase

# ─── Internals ──────────────────────────────────────────────────────────────

func _on_round_timer_finished() -> void:
	# Coordinator emits — main.gd is responsible for actually starting the
	# race (spawning marbles, etc.). It then calls begin_live() back.
	force_start_requested.emit()

func _on_bet_pressed(amount: float) -> void:
	if _phase != PHASE_IDLE:
		return
	if amount > _balance:
		# Visual feedback only — tint the bet button briefly.
		var btn := _bet_card.get_node("VBoxContainer/Button") if _bet_card.has_node(
			"VBoxContainer/Button") else null
		if btn != null:
			var t := create_tween()
			t.tween_property(btn, "modulate", Color(1.4, 0.6, 0.6), 0.15)
			t.tween_property(btn, "modulate", Color.WHITE, 0.25)
		return
	_open_bet_amount = amount
	bet_placed.emit(amount)
	# Visual confirmation: bet card briefly pulses.
	var t := create_tween()
	_bet_card.pivot_offset = _bet_card.size * 0.5
	t.tween_property(_bet_card, "scale", Vector2(1.02, 1.02), 0.10)
	t.tween_property(_bet_card, "scale", Vector2.ONE, 0.18)

func _play_card_show(card: Control, delay: float) -> void:
	# VBoxContainer owns the card's `position`, so we limit the animation
	# to opacity + a tiny pivot-anchored scale. The vertical-rise effect
	# from the spec is approximated via the modulate fade-in cadence.
	card.modulate = Color(1, 1, 1, 0)
	card.pivot_offset = Vector2(card.size.x * 0.5, 0)
	card.scale = Vector2(0.98, 0.98)
	var t := create_tween()
	t.tween_interval(delay)
	t.tween_property(card, "modulate:a", 1.0,
		T.T_CARD_SHOW).set_trans(Tween.TRANS_CUBIC)
	t.parallel().tween_property(card, "scale", Vector2.ONE,
		T.T_CARD_SHOW).set_trans(Tween.TRANS_CUBIC)

func _build_debug_panel() -> PanelContainer:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", T.panel_style(
		Color(T.PANEL_2.r, T.PANEL_2.g, T.PANEL_2.b, 0.92)))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	pc.add_child(col)

	var head := Label.new()
	head.text = "DEBUG"
	head.add_theme_font_override("font", T.font_mono(700))
	head.add_theme_font_size_override("font_size", T.FS_LABEL_MONO)
	head.add_theme_color_override("font_color", T.TEXT_FAINT)
	col.add_child(head)

	var force := _make_debug_btn("FORCE START", func() -> void:
		force_start_requested.emit())
	col.add_child(force)

	var add100 := _make_debug_btn("+ $100", func() -> void:
		apply_settlement_balance(100.0))
	col.add_child(add100)

	var sub100 := _make_debug_btn("− $100", func() -> void:
		apply_settlement_balance(-100.0))
	col.add_child(sub100)

	return pc

func _make_debug_btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", T.font_mono(600))
	b.add_theme_font_size_override("font_size", T.FS_DEBUG_BTN)
	b.add_theme_color_override("font_color", T.TEXT_DIM)
	b.add_theme_color_override("font_hover_color", T.TEXT)
	var sb_n := StyleBoxFlat.new()
	sb_n.bg_color = T.BG_2
	sb_n.border_color = T.BORDER
	sb_n.set_border_width_all(1)
	sb_n.set_corner_radius_all(8)
	sb_n.content_margin_left = 8
	sb_n.content_margin_top = 4
	sb_n.content_margin_right = 8
	sb_n.content_margin_bottom = 4
	var sb_h := sb_n.duplicate()
	sb_h.bg_color = Color8(0x16, 0x1a, 0x26)
	b.add_theme_stylebox_override("normal", sb_n)
	b.add_theme_stylebox_override("hover",  sb_h)
	b.add_theme_stylebox_override("pressed", sb_h)
	b.pressed.connect(cb)
	return b

func _fmt(v: float) -> String:
	return "%.2f" % v
