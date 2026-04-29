class_name HUD
extends CanvasLayer

# Player-facing overlay for web / live scenes. Shows:
#   - race title + phase label (top-left)
#   - mock balance + deposit-stub button (top-right)
#   - marble list with color swatches and names (right sidebar)
#   - race timer (bottom-center)
#   - buy-in stub button (bottom-center, disabled during race)
#   - winner modal centered at race end
#
# All elements are built programmatically against Godot 4's anchor-preset
# system. Sim/headless paths don't add a HUD; this is the "what a player
# sees" layer only.
#
# State machine:
#   _ready       → build layout, hide winner modal, "WAITING" label
#   setup(...)   → populate marble list from replay header
#   update_tick  → drive the timer
#   reveal_winner→ show modal, swap phase to "FINISHED"
#   reset        → return to "WAITING"

const TIMER_FORMAT := "%02d:%02d"
const PHASE_WAITING := "WAITING"
const PHASE_RACING := "RACING"
const PHASE_FINISHED := "FINISHED"

# Mock fields — replaced by real wallet data once an RGS integration lands.
const MOCK_BALANCE := 1250.00
const MOCK_BUY_IN_DEFAULT := 10.00

var _phase_label: Label
var _timer_label: Label
var _marble_list: VBoxContainer
var _balance_label: Label
var _winner_modal: Control
var _winner_name_label: Label
var _winner_prize_label: Label
var _buy_in_button: Button
var _track_name_label: Label

var _tick_rate: float = 60.0
var _race_started: bool = false
var _start_tick: int = -1

# Marble metadata stored at setup() time so update_standings can re-sort rows
# without losing name/color. Each entry: {name: String, color: Color}.
var _marble_meta: Array = []

func _ready() -> void:
	layer = 10   # above any 3D viewport but below editor overlays
	_build_layout()

# ─── Public API ──────────────────────────────────────────────────────────

# Called once when the replay header is known. `header` is the list of marble
# dicts (name + rgba) from the replay/stream protocol.
func setup(header: Array) -> void:
	_clear_marble_list()
	_marble_meta.clear()
	for i in range(header.size()):
		var m: Dictionary = header[i]
		var marble_name := String(m.get("name", "marble_%02d" % i))
		var rgba: int = int(m.get("rgba", 0))
		var color: Color
		if rgba == 0:
			color = Color.from_hsv(float(i) / max(header.size(), 1), 0.8, 0.95)
		else:
			color = Color(((rgba >> 24) & 0xFF) / 255.0, ((rgba >> 16) & 0xFF) / 255.0, ((rgba >> 8) & 0xFF) / 255.0, 1.0)
		_marble_meta.append({"name": marble_name, "color": color, "original_index": i})
		_marble_list.add_child(_make_marble_row("%d. %s" % [i + 1, marble_name], color, false))
	_phase_label.text = PHASE_RACING
	_winner_modal.visible = false
	_buy_in_button.disabled = true   # bets are closed once the race is rolling
	_buy_in_button.text = "Buy-in closed"
	_race_started = false
	_start_tick = -1

# Set the track name displayed in the top-left panel. Called by web/live main
# once the track_id is known (after replay header is parsed).
func set_track_name(track_name: String) -> void:
	if _track_name_label != null:
		_track_name_label.text = track_name

# Update the live leaderboard based on current marble world positions relative
# to the finish line. Safe to call when finish_pos is not yet meaningful (e.g.
# headless / pre-race): if marbles array is empty or finish_pos is ZERO, the
# existing order is preserved to avoid flicker.
#
# marbles — array of RigidBody3D or Node3D, same ordering as the replay header.
# finish_pos — world-space position of the finish-line trigger center.
func update_standings(marbles: Array, finish_pos: Vector3) -> void:
	if marbles.is_empty() or _marble_meta.is_empty():
		return

	# Build (distance, original_index) pairs for sorting.
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

	# Rebuild the marble list rows in the new rank order.
	_clear_marble_list()
	for rank in range(ranked.size()):
		var entry: Dictionary = ranked[rank]
		var meta: Dictionary = _marble_meta[entry["idx"]]
		var row_text := "%d. %s" % [rank + 1, meta["name"]]
		_marble_list.add_child(_make_marble_row(row_text, meta["color"], rank == 0))

# Drive the timer. `tick` is the current playback tick (monotonic from
# _process). `tick_rate_hz` matches the recorder's setting (60 in M3+).
func update_tick(tick: int, tick_rate_hz: float) -> void:
	_tick_rate = tick_rate_hz
	if not _race_started:
		_start_tick = tick
		_race_started = true
	var elapsed_ticks: int = max(0, tick - _start_tick)
	var seconds: int = int(float(elapsed_ticks) / tick_rate_hz)
	_timer_label.text = TIMER_FORMAT % [seconds / 60, seconds % 60]

# Show the winner modal. `prize` is a pre-formatted display string (e.g.
# "1,900 USD"); pass "" if the wallet integration hasn't supplied one yet.
func reveal_winner(name: String, color: Color, prize: String = "") -> void:
	_phase_label.text = PHASE_FINISHED
	_winner_name_label.text = name
	_winner_name_label.add_theme_color_override("font_color", color)
	_winner_prize_label.text = prize if prize != "" else "Race complete"
	_winner_modal.visible = true

func reset() -> void:
	_clear_marble_list()
	_marble_meta.clear()
	_phase_label.text = PHASE_WAITING
	_timer_label.text = TIMER_FORMAT % [0, 0]
	_winner_modal.visible = false
	_buy_in_button.disabled = false
	_buy_in_button.text = "Buy-in (%.2f)" % MOCK_BUY_IN_DEFAULT
	_race_started = false
	if _track_name_label != null:
		_track_name_label.text = ""

# ─── Layout ──────────────────────────────────────────────────────────────

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

	# Scrollable list under the header so 20+ marbles still fit on small windows.
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
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	panel.offset_left = -200
	panel.offset_right = 200
	panel.offset_top = -100
	panel.offset_bottom = -20
	panel.add_theme_stylebox_override("panel", _panel_stylebox(Color(0, 0, 0, 0.55)))

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)

	_timer_label = Label.new()
	_timer_label.text = TIMER_FORMAT % [0, 0]
	_timer_label.add_theme_font_size_override("font_size", 32)
	_timer_label.add_theme_color_override("font_color", Color(1, 0.92, 0.7))
	_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_timer_label)

	_buy_in_button = Button.new()
	_buy_in_button.text = "Buy-in (%.2f)" % MOCK_BUY_IN_DEFAULT
	_buy_in_button.disabled = true   # phase machine not wired through yet
	_buy_in_button.tooltip_text = "Bets close when the race starts (RGS integration TBD)"
	vb.add_child(_buy_in_button)
	return panel

func _build_winner_modal() -> Control:
	# A centered overlay that's hidden by default; reveal_winner() toggles it.
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

	control.visible = false
	return control

# ─── Helpers ─────────────────────────────────────────────────────────────

func _make_marble_row(marble_name: String, color: Color, is_leader: bool = false) -> Control:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)

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

	if not is_leader:
		return hb

	# First-place row: wrap in a PanelContainer with a distinct gold-bordered
	# background so the leader is immediately obvious in the standings list.
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.22, 0.18, 0.04, 0.85)
	sb.border_color = Color(1.0, 0.82, 0.12, 0.90)
	sb.set_border_width_all(2)
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	panel.add_theme_stylebox_override("panel", sb)
	panel.add_child(hb)
	return panel

func _clear_marble_list() -> void:
	for c in _marble_list.get_children():
		c.queue_free()

func _panel_stylebox(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb
