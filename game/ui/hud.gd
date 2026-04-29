class_name HUD
extends CanvasLayer

# Emitted when the user clicks a marble row in the standings sidebar.
# `index` is the drop-order original index (same key used by FreeCamera's
# follow system). Connect this to FreeCamera.follow_marble_index.
signal marble_selected(index: int)

# Emitted when the player clicks "PLACE BET" in the bet panel (WAITING phase,
# RGS mode only). The caller (main.gd) should forward this to RgsClient.
signal bet_requested(marble_idx: int, amount: float)

# Player-facing overlay for web / live scenes. Shows:
#   - race title + phase label (top-left)
#   - balance label (top-right, live from RGS server; mock in local mode)
#   - marble list with color swatches and names (right sidebar)
#   - race timer (bottom-center)
#   - bet panel (bottom-center, visible in WAITING+RGS mode only)
#   - winner modal centered at race end (shows payout result in RGS mode)
#
# State machine:
#   WAITING  → bet panel visible (RGS mode only), marble list unpopulated
#   RACING   → bet panel hidden / "Bets locked" banner shown, timer ticking
#   FINISHED → winner modal + optional payout line
#
# Sim/headless paths don't add a HUD; this is the "what a player sees" layer.

const TIMER_FORMAT := "%02d:%02d"
const PHASE_WAITING  := "WAITING"
const PHASE_RACING   := "RACING"
const PHASE_FINISHED := "FINISHED"

# Fallback balance used when NOT in RGS mode.
const MOCK_BALANCE := 1250.00

# ─── Nodes ───────────────────────────────────────────────────────────────────

var _phase_label: Label
var _timer_label: Label
var _marble_list: VBoxContainer
var _balance_label: Label
var _winner_modal: Control
var _winner_name_label: Label
var _winner_prize_label: Label
var _winner_payout_label: Label   # RGS payout line inside the modal
var _track_name_label: Label

# Bet panel nodes (visible only in WAITING + RGS mode)
var _bet_panel: Control
var _marble_selector: OptionButton
var _amount_label: Label
var _place_bet_btn: Button
var _bets_list: VBoxContainer
var _bets_locked_label: Label
var _toast_label: Label           # temporary error / confirmation feedback
var _bet_countdown_label: Label   # shows "Race starts in: X.Xs" inside bet panel

# ─── State ───────────────────────────────────────────────────────────────────

var _tick_rate: float = 60.0
var _race_started: bool = false
var _start_tick: int = -1

# Bet-window countdown state.
var _bet_countdown_remaining: float = 0.0
var _bet_countdown_active: bool = false

# Marble metadata stored at setup() time.
# Each entry: {name: String, color: Color, original_index: int}.
var _marble_meta: Array = []

# Which original_index is currently being followed (-1 = none).
var _following_index: int = -1

# Map from original_index → row Control node; rebuilt by setup/update_standings.
var _row_by_index: Dictionary = {}

# RGS betting state
var _rgs_mode: bool = false
var _round_id: int = 0
var _balance: float = MOCK_BALANCE
var _bet_amount: float = 10.0
var _selected_marble: int = -1     # index into _marble_meta (not original_index)
var _placed_bets: Array = []       # array of {marble_idx, amount, expected_payout_if_win}
var _toast_timer: float = 0.0

# ─── Lifecycle ───────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 10   # above any 3D viewport but below editor overlays
	_build_layout()

func _process(delta: float) -> void:
	# Fade out the toast message after its display period.
	if _toast_timer > 0.0:
		_toast_timer -= delta
		if _toast_timer <= 0.0:
			_toast_label.visible = false
			_toast_timer = 0.0

	# Drive the bet-window countdown at 0.1 s precision.
	if _bet_countdown_active:
		_bet_countdown_remaining -= delta
		if _bet_countdown_remaining <= 0.0:
			_bet_countdown_remaining = 0.0
			_bet_countdown_active = false
			_bet_countdown_label.text = "Bets locked"
			_bet_countdown_label.add_theme_color_override("font_color", Color(0.90, 0.50, 0.20))
			_place_bet_btn.disabled = true
		else:
			_bet_countdown_label.text = "Race starts in: %.1fs" % _bet_countdown_remaining

# ─── Public API ──────────────────────────────────────────────────────────────

# Enable RGS betting mode. Must be called before setup().
# `round_id` is the server-authoritative round ID needed for the bet POST.
# `initial_balance` is the balance to show until bet_placed updates it.
# After this call the HUD is in WAITING phase with the bet panel visible.
func enable_rgs_mode(round_id: int, initial_balance: float = MOCK_BALANCE) -> void:
	_rgs_mode = true
	_round_id = round_id
	_balance = initial_balance
	_update_balance_label()
	_phase_label.text = PHASE_WAITING
	_bet_panel.visible = true
	_bets_locked_label.visible = false

# Start the visible bet-window countdown shown inside the bet panel.
# Call this immediately after enable_rgs_mode().  Internally ticks every frame
# (0.1 s display precision).  If called while a previous countdown is still
# running it resets gracefully.
func start_bet_countdown(seconds: float) -> void:
	_bet_countdown_remaining = seconds
	_bet_countdown_active = true
	_bet_countdown_label.text = "Race starts in: %.1fs" % seconds
	_bet_countdown_label.add_theme_color_override("font_color", Color(0.70, 0.85, 0.70))
	_bet_countdown_label.visible = true

# Update the displayed balance.  Pass -1.0 to silently ignore (sentinel for
# a failed balance fetch — the last good value is preserved).
func update_balance(balance: float) -> void:
	if balance < 0.0:
		return
	_balance = balance
	_update_balance_label()

# Called once when the replay header is known. `header` is the list of marble
# dicts (name + rgba) from the replay/stream protocol.
func setup(header: Array) -> void:
	_clear_marble_list()
	_marble_meta.clear()
	_marble_selector.clear()

	for i in range(header.size()):
		var m: Dictionary = header[i]
		var marble_name := String(m.get("name", "marble_%02d" % i))
		var rgba: int = int(m.get("rgba", 0))
		var color: Color
		if rgba == 0:
			color = Color.from_hsv(float(i) / max(header.size(), 1), 0.8, 0.95)
		else:
			color = Color(
				((rgba >> 24) & 0xFF) / 255.0,
				((rgba >> 16) & 0xFF) / 255.0,
				((rgba >> 8)  & 0xFF) / 255.0,
				1.0
			)
		_marble_meta.append({"name": marble_name, "color": color, "original_index": i})
		var row := _make_marble_row("%d. %s" % [i + 1, marble_name], color, false, i)
		_row_by_index[i] = row
		_marble_list.add_child(row)
		_marble_selector.add_item("%02d  %s" % [i, marble_name], i)

	_phase_label.text = PHASE_RACING
	_winner_modal.visible = false
	_race_started = false
	_start_tick = -1

	# Cancel any in-progress bet countdown (setup() means the race is starting).
	_bet_countdown_active = false

	# Transition to RACING: hide bet placement, show lock banner if bets placed.
	_bet_panel.visible = false
	_bets_locked_label.visible = _rgs_mode

# Set the track name displayed in the top-left panel.
func set_track_name(track_name: String) -> void:
	if _track_name_label != null:
		_track_name_label.text = track_name

# Drive the live leaderboard. Safe to call before the race starts.
func update_standings(marbles: Array, finish_pos: Vector3) -> void:
	if marbles.is_empty() or _marble_meta.is_empty():
		return
	var ranked: Array = []
	for i in range(min(marbles.size(), _marble_meta.size())):
		var node: Node3D = marbles[i] as Node3D
		var dist: float = INF
		if node != null and is_instance_valid(node):
			dist = node.global_position.distance_to(finish_pos)
		ranked.append({"dist": dist, "idx": i})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["dist"] < b["dist"]
	)
	_clear_marble_list()
	for rank in range(ranked.size()):
		var entry: Dictionary = ranked[rank]
		var meta: Dictionary = _marble_meta[entry["idx"]]
		var orig_idx: int = meta["original_index"]
		var row_text := "%d. %s" % [rank + 1, meta["name"]]
		var row := _make_marble_row(row_text, meta["color"], rank == 0, orig_idx)
		_row_by_index[orig_idx] = row
		_marble_list.add_child(row)
	if _following_index >= 0:
		_apply_following_marker(_following_index, true)

# Drive the race timer.
func update_tick(tick: int, tick_rate_hz: float) -> void:
	_tick_rate = tick_rate_hz
	if not _race_started:
		_start_tick = tick
		_race_started = true
	var elapsed_ticks: int = max(0, tick - _start_tick)
	var seconds: int = int(float(elapsed_ticks) / tick_rate_hz)
	_timer_label.text = TIMER_FORMAT % [seconds / 60, seconds % 60]

# Show the winner modal. In RGS mode, payout/loss is computed from _placed_bets
# and the winning marble index. `prize` is a pre-formatted string fallback.
func reveal_winner(name: String, color: Color, prize: String = "") -> void:
	_phase_label.text = PHASE_FINISHED
	_winner_name_label.text = name
	_winner_name_label.add_theme_color_override("font_color", color)
	_winner_prize_label.text = prize if prize != "" else "Race complete"

	# Compute payout result from placed bets if in RGS mode.
	if _rgs_mode and not _placed_bets.is_empty():
		# The winner's marble_idx is embedded in the name ("Marble_07" → 7).
		var winner_idx := -1
		var trimmed := name.trim_prefix("Marble_")
		if trimmed.is_valid_int():
			winner_idx = int(trimmed)
		var total_payout := 0.0
		var total_wagered := 0.0
		for b in _placed_bets:
			total_wagered += float(b["amount"])
			if int(b["marble_idx"]) == winner_idx:
				total_payout += float(b["expected_payout_if_win"])
		if total_payout > 0.0:
			_winner_payout_label.text = "+%.2f (won %.2f on %.2f wagered)" % [
				total_payout, total_payout, total_wagered]
			_winner_payout_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
		else:
			_winner_payout_label.text = "-%.2f (all bets lost)" % total_wagered
			_winner_payout_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
		_winner_payout_label.visible = true
	else:
		_winner_payout_label.visible = false

	_winner_modal.visible = true

# Apply server-authoritative settlement outcomes to the winner modal.
# `outcomes` is the filtered list for the current player only.
# Each outcome dict: {bet_id, player_id, marble_idx, amount, won, payout, winner_index}.
# Safe to call before or after reveal_winner — if the modal is not yet
# visible the data is written and will be visible when reveal_winner fires.
func apply_settlement(outcomes: Array, winner_marble_idx: int) -> void:
	if outcomes.is_empty():
		# No bets for this player this round — hide the payout line.
		_winner_payout_label.visible = false
		return

	var total_payout := 0.0
	var total_wagered := 0.0
	for o in outcomes:
		if typeof(o) != TYPE_DICTIONARY:
			continue
		total_wagered += float(o.get("amount", 0.0))
		if bool(o.get("won", false)):
			total_payout += float(o.get("payout", 0.0))

	if total_payout > 0.0:
		_winner_payout_label.text = "+%.2f won (wagered %.2f)" % [total_payout, total_wagered]
		_winner_payout_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
	else:
		_winner_payout_label.text = "-%.2f lost" % total_wagered
		_winner_payout_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	_winner_payout_label.visible = true

# Called after a successful bet_placed response from RgsClient.
# Updates the balance label and appends a row to the "Your bets" list.
func on_bet_confirmed(bet: Dictionary) -> void:
	_balance = float(bet.get("balance_after", _balance))
	_update_balance_label()
	_placed_bets.append(bet)
	_refresh_bets_list()
	_validate_bet_button()
	_show_toast("Bet placed: Marble_%02d — %.2f" % [int(bet.get("marble_idx", 0)), float(bet.get("amount", 0.0))])

# Show a temporary error toast (e.g. after bet_failed signal).
func show_error_toast(message: String) -> void:
	_show_toast(message)

# Called by FreeCamera.following_changed signal.
func set_following(index: int) -> void:
	if _following_index >= 0:
		_apply_following_marker(_following_index, false)
	_following_index = index
	if index >= 0:
		_apply_following_marker(index, true)

func reset() -> void:
	_clear_marble_list()
	_marble_meta.clear()
	_following_index = -1
	_placed_bets.clear()
	_selected_marble = -1
	_bet_amount = 10.0
	_rgs_mode = false
	_phase_label.text = PHASE_WAITING
	_timer_label.text = TIMER_FORMAT % [0, 0]
	_winner_modal.visible = false
	_bet_panel.visible = false
	_bets_locked_label.visible = false
	_balance = MOCK_BALANCE
	_balance_label.text = "%.2f USD" % _balance
	_race_started = false
	_bet_countdown_active = false
	_bet_countdown_remaining = 0.0
	if _track_name_label != null:
		_track_name_label.text = ""
	if _marble_selector != null:
		_marble_selector.clear()
	_refresh_bets_list()

# ─── Layout ──────────────────────────────────────────────────────────────────

func _build_layout() -> void:
	var root := Control.new()
	root.name = "HudRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	root.add_child(_build_top_left())
	root.add_child(_build_top_right())
	root.add_child(_build_right_sidebar())
	root.add_child(_build_bottom_center())
	root.add_child(_build_winner_modal())
	root.add_child(_build_toast())

func _build_top_left() -> Control:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(20, 20)
	panel.add_theme_stylebox_override("panel", _panel_stylebox(Color(0, 0, 0, 0.55)))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "MARBLES RACE"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(1, 0.92, 0.7))
	vb.add_child(title)

	_track_name_label = Label.new()
	_track_name_label.text = ""
	_track_name_label.add_theme_font_size_override("font_size", 11)
	_track_name_label.add_theme_color_override("font_color", Color(0.65, 0.85, 0.65))
	vb.add_child(_track_name_label)

	_phase_label = Label.new()
	_phase_label.text = PHASE_WAITING
	_phase_label.add_theme_font_size_override("font_size", 13)
	_phase_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.95))
	vb.add_child(_phase_label)
	return panel

func _build_top_right() -> Control:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.position = Vector2(-220, 20)
	panel.size = Vector2(200, 0)
	panel.add_theme_stylebox_override("panel", _panel_stylebox(Color(0, 0, 0, 0.55)))
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	panel.add_child(hb)

	var bal_label := Label.new()
	bal_label.text = "BAL"
	bal_label.add_theme_font_size_override("font_size", 11)
	bal_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.65))
	hb.add_child(bal_label)

	_balance_label = Label.new()
	_balance_label.text = "%.2f USD" % MOCK_BALANCE
	_balance_label.add_theme_font_size_override("font_size", 16)
	_balance_label.add_theme_color_override("font_color", Color(0.95, 0.95, 1.0))
	hb.add_child(_balance_label)

	var deposit := Button.new()
	deposit.text = "+"
	deposit.tooltip_text = "Deposit (stub)"
	deposit.custom_minimum_size = Vector2(24, 24)
	hb.add_child(deposit)
	return panel

func _build_right_sidebar() -> Control:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -260
	panel.offset_top = 110
	panel.offset_right = -20
	panel.offset_bottom = -160
	panel.add_theme_stylebox_override("panel", _panel_stylebox(Color(0, 0, 0, 0.45)))

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	panel.add_child(vb)

	var header := Label.new()
	header.text = "STANDINGS"
	header.add_theme_font_size_override("font_size", 12)
	header.add_theme_color_override("font_color", Color(0.55, 0.55, 0.65))
	vb.add_child(header)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)

	_marble_list = VBoxContainer.new()
	_marble_list.add_theme_constant_override("separation", 2)
	_marble_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_marble_list)
	return panel

func _build_bottom_center() -> Control:
	# Outer anchor container that holds both the timer area and the bet panel.
	var outer := Control.new()
	outer.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	outer.offset_left  = -220
	outer.offset_right =  220
	outer.offset_top   = -340
	outer.offset_bottom = -20
	outer.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# --- Timer panel (always visible) ---
	var timer_panel := PanelContainer.new()
	timer_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	timer_panel.offset_top = -100
	timer_panel.add_theme_stylebox_override("panel", _panel_stylebox(Color(0, 0, 0, 0.55)))
	outer.add_child(timer_panel)

	var timer_vb := VBoxContainer.new()
	timer_vb.alignment = BoxContainer.ALIGNMENT_CENTER
	timer_vb.add_theme_constant_override("separation", 6)
	timer_panel.add_child(timer_vb)

	_timer_label = Label.new()
	_timer_label.text = TIMER_FORMAT % [0, 0]
	_timer_label.add_theme_font_size_override("font_size", 32)
	_timer_label.add_theme_color_override("font_color", Color(1, 0.92, 0.7))
	_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	timer_vb.add_child(_timer_label)

	# "Bets locked" banner — shown in RACING when bets were placed.
	_bets_locked_label = Label.new()
	_bets_locked_label.text = "Bets locked"
	_bets_locked_label.add_theme_font_size_override("font_size", 12)
	_bets_locked_label.add_theme_color_override("font_color", Color(0.75, 0.60, 0.25))
	_bets_locked_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bets_locked_label.visible = false
	timer_vb.add_child(_bets_locked_label)

	# --- Bet panel (above the timer; visible only in WAITING + RGS mode) ---
	_bet_panel = _build_bet_panel()
	_bet_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_bet_panel.offset_bottom = 230   # leave room below for the timer panel
	_bet_panel.visible = false
	outer.add_child(_bet_panel)

	return outer

func _build_bet_panel() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_stylebox(Color(0.04, 0.04, 0.12, 0.88)))

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	# Header label
	var header := Label.new()
	header.text = "BET PLACEMENT"
	header.add_theme_font_size_override("font_size", 14)
	header.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(header)

	# Marble selector
	var sel_label := Label.new()
	sel_label.text = "Select marble:"
	sel_label.add_theme_font_size_override("font_size", 11)
	sel_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
	vb.add_child(sel_label)

	_marble_selector = OptionButton.new()
	_marble_selector.placeholder_text = "— pick a marble —"
	_marble_selector.item_selected.connect(_on_marble_selected)
	vb.add_child(_marble_selector)

	# Amount row: preset chips + live amount label
	var amt_header := Label.new()
	amt_header.text = "Bet amount:"
	amt_header.add_theme_font_size_override("font_size", 11)
	amt_header.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
	vb.add_child(amt_header)

	# Preset buttons
	var presets_hb := HBoxContainer.new()
	presets_hb.add_theme_constant_override("separation", 4)
	vb.add_child(presets_hb)

	for preset_val in [1, 5, 10, 50, 100]:
		var pb := Button.new()
		pb.text = "%d" % preset_val
		pb.custom_minimum_size = Vector2(36, 26)
		pb.pressed.connect(_on_preset_amount.bind(float(preset_val)))
		presets_hb.add_child(pb)

	# Fine-adjust row
	var adjust_hb := HBoxContainer.new()
	adjust_hb.add_theme_constant_override("separation", 6)
	vb.add_child(adjust_hb)

	var minus_btn := Button.new()
	minus_btn.text = "-10"
	minus_btn.custom_minimum_size = Vector2(42, 26)
	minus_btn.pressed.connect(_on_adjust_amount.bind(-10.0))
	adjust_hb.add_child(minus_btn)

	_amount_label = Label.new()
	_amount_label.text = "%.2f" % _bet_amount
	_amount_label.add_theme_font_size_override("font_size", 18)
	_amount_label.add_theme_color_override("font_color", Color(0.95, 0.95, 1.0))
	_amount_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_amount_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	adjust_hb.add_child(_amount_label)

	var plus_btn := Button.new()
	plus_btn.text = "+10"
	plus_btn.custom_minimum_size = Vector2(42, 26)
	plus_btn.pressed.connect(_on_adjust_amount.bind(10.0))
	adjust_hb.add_child(plus_btn)

	# Countdown label — updated by start_bet_countdown() / _process().
	_bet_countdown_label = Label.new()
	_bet_countdown_label.text = ""
	_bet_countdown_label.add_theme_font_size_override("font_size", 12)
	_bet_countdown_label.add_theme_color_override("font_color", Color(0.70, 0.85, 0.70))
	_bet_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bet_countdown_label.visible = false
	vb.add_child(_bet_countdown_label)

	# Place Bet button
	_place_bet_btn = Button.new()
	_place_bet_btn.text = "PLACE BET"
	_place_bet_btn.disabled = true
	_place_bet_btn.add_theme_font_size_override("font_size", 15)
	_place_bet_btn.pressed.connect(_on_place_bet_pressed)
	vb.add_child(_place_bet_btn)

	# "Your bets" section
	var bets_header := Label.new()
	bets_header.text = "Your bets:"
	bets_header.add_theme_font_size_override("font_size", 11)
	bets_header.add_theme_color_override("font_color", Color(0.55, 0.55, 0.65))
	vb.add_child(bets_header)

	var bets_scroll := ScrollContainer.new()
	bets_scroll.custom_minimum_size = Vector2(0, 60)
	bets_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(bets_scroll)

	_bets_list = VBoxContainer.new()
	_bets_list.add_theme_constant_override("separation", 2)
	_bets_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bets_scroll.add_child(_bets_list)

	return panel

func _build_winner_modal() -> Control:
	var control := Control.new()
	control.set_anchors_preset(Control.PRESET_FULL_RECT)
	control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_winner_modal = control

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 0.55)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	control.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	control.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_stylebox(Color(0.05, 0.05, 0.10, 0.95)))
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)

	var label := Label.new()
	label.text = "WINNER"
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.65))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(label)

	_winner_name_label = Label.new()
	_winner_name_label.text = "—"
	_winner_name_label.add_theme_font_size_override("font_size", 48)
	_winner_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_winner_name_label)

	_winner_prize_label = Label.new()
	_winner_prize_label.text = "—"
	_winner_prize_label.add_theme_font_size_override("font_size", 16)
	_winner_prize_label.add_theme_color_override("font_color", Color(0.95, 0.78, 0.20))
	_winner_prize_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_winner_prize_label)

	# RGS payout line (hidden when not in RGS mode or no bets placed).
	_winner_payout_label = Label.new()
	_winner_payout_label.text = ""
	_winner_payout_label.add_theme_font_size_override("font_size", 14)
	_winner_payout_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_winner_payout_label.visible = false
	vb.add_child(_winner_payout_label)

	control.visible = false
	return control

func _build_toast() -> Control:
	# Anchored to bottom-left, floats above the marble list area.
	var ctrl := Control.new()
	ctrl.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	ctrl.offset_left = 20
	ctrl.offset_bottom = -20
	ctrl.offset_top = -60
	ctrl.offset_right = 380
	ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_toast_label = Label.new()
	_toast_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_toast_label.add_theme_font_size_override("font_size", 13)
	_toast_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.5))
	_toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast_label.visible = false
	ctrl.add_child(_toast_label)
	return ctrl

# ─── Bet panel callbacks ──────────────────────────────────────────────────────

func _on_marble_selected(index: int) -> void:
	_selected_marble = index
	_validate_bet_button()

func _on_preset_amount(val: float) -> void:
	_bet_amount = val
	_amount_label.text = "%.2f" % _bet_amount
	_validate_bet_button()

func _on_adjust_amount(delta: float) -> void:
	_bet_amount = max(1.0, _bet_amount + delta)
	_amount_label.text = "%.2f" % _bet_amount
	_validate_bet_button()

func _on_place_bet_pressed() -> void:
	if _selected_marble < 0 or _bet_amount <= 0.0:
		return
	if _bet_amount > _balance:
		_show_toast("Insufficient balance")
		return
	var original_idx: int = _marble_meta[_selected_marble]["original_index"]
	bet_requested.emit(original_idx, _bet_amount)

# ─── Helpers ─────────────────────────────────────────────────────────────────

func _validate_bet_button() -> void:
	if not _rgs_mode:
		_place_bet_btn.disabled = true
		_place_bet_btn.tooltip_text = "Betting requires RGS mode (--rgs=<url>)"
		return
	var valid := _selected_marble >= 0 and _bet_amount > 0.0 and _bet_amount <= _balance
	_place_bet_btn.disabled = not valid

func _update_balance_label() -> void:
	_balance_label.text = "%.2f USD" % _balance

func _refresh_bets_list() -> void:
	for c in _bets_list.get_children():
		c.queue_free()
	for b in _placed_bets:
		var row := Label.new()
		row.text = "Marble_%02d — %.2f" % [int(b.get("marble_idx", 0)), float(b.get("amount", 0.0))]
		row.add_theme_font_size_override("font_size", 12)
		row.add_theme_color_override("font_color", Color(0.85, 0.85, 0.95))
		_bets_list.add_child(row)

func _show_toast(message: String) -> void:
	_toast_label.text = message
	_toast_label.visible = true
	_toast_timer = 3.5

func _make_marble_row(marble_name: String, color: Color, is_leader: bool = false,
		original_index: int = -1) -> Control:
	var btn := Button.new()
	btn.flat = true
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.focus_mode = Control.FOCUS_NONE
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var sb_normal := _row_stylebox(Color(0, 0, 0, 0.0),    Color(0, 0, 0, 0.0))
	var sb_hover  := _row_stylebox(Color(1, 1, 1, 0.08),   Color(0, 0, 0, 0.0))
	var sb_press  := _row_stylebox(Color(1, 1, 1, 0.18),   Color(0, 0, 0, 0.0))

	if is_leader:
		sb_normal = _row_stylebox(Color(0.22, 0.18, 0.04, 0.85), Color(1.0, 0.82, 0.12, 0.90))
		sb_hover  = _row_stylebox(Color(0.28, 0.24, 0.08, 0.90), Color(1.0, 0.82, 0.12, 0.90))
		sb_press  = _row_stylebox(Color(0.34, 0.30, 0.12, 0.95), Color(1.0, 0.82, 0.12, 0.90))

	btn.add_theme_stylebox_override("normal",   sb_normal)
	btn.add_theme_stylebox_override("hover",    sb_hover)
	btn.add_theme_stylebox_override("pressed",  sb_press)
	btn.add_theme_stylebox_override("disabled", sb_normal)
	btn.add_theme_stylebox_override("focus",    sb_normal)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	btn.add_child(hb)

	var swatch := ColorRect.new()
	swatch.color = color
	swatch.custom_minimum_size = Vector2(14, 14)
	hb.add_child(swatch)

	var label := Label.new()
	label.text = marble_name
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color",
		Color(1.0, 0.92, 0.30) if is_leader else Color(0.92, 0.92, 0.96))
	hb.add_child(label)

	if original_index >= 0:
		btn.pressed.connect(func() -> void:
			marble_selected.emit(original_index)
		)

	return btn

func _apply_following_marker(orig_idx: int, active: bool) -> void:
	if not _row_by_index.has(orig_idx):
		return
	var row: Control = _row_by_index[orig_idx]
	if not row is Button:
		return
	var btn := row as Button
	var sb: StyleBoxFlat = btn.get_theme_stylebox("normal").duplicate()
	if active:
		sb.border_color = Color(0.0, 0.85, 1.0, 1.0)
		sb.border_width_left = 3
		sb.border_width_top = 0
		sb.border_width_right = 0
		sb.border_width_bottom = 0
	else:
		sb.border_color = Color(0, 0, 0, 0)
		sb.border_width_left = 0
	btn.add_theme_stylebox_override("normal",   sb)
	btn.add_theme_stylebox_override("disabled", sb)
	btn.add_theme_stylebox_override("focus",    sb)

func _row_stylebox(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(0 if border.a == 0.0 else 2)
	sb.corner_radius_top_left    = 4
	sb.corner_radius_top_right   = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	sb.content_margin_left   = 4
	sb.content_margin_right  = 4
	sb.content_margin_top    = 2
	sb.content_margin_bottom = 2
	return sb

func _clear_marble_list() -> void:
	for c in _marble_list.get_children():
		c.queue_free()
	_row_by_index.clear()

func _panel_stylebox(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.corner_radius_top_left    = 6
	sb.corner_radius_top_right   = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left   = 12
	sb.content_margin_right  = 12
	sb.content_margin_top    = 8
	sb.content_margin_bottom = 8
	return sb
