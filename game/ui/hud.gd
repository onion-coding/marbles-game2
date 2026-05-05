class_name HUD
extends CanvasLayer

# Broadcast-style HUD overlay. Coordinator + public API + state machine.
#
# Layout construction is delegated to HudLayout (static helpers).
# Process-loop logic (countdowns, tweens, pickup polling, responsive
# breakpoint, bet-panel interaction, i18n refresh, branding refresh,
# payout display) is delegated to HudRuntime (instance with back-ref).
#
# Public API is unchanged from the pre-refactor implementation; all
# callers (main.gd / live_main.gd / web_main.gd / playback_main.gd)
# remain compatible.

# ─── Signals ─────────────────────────────────────────────────────────────────

# Emitted when the user clicks a marble row in the timing tower.
# `index` is the drop-order original index (same key used by FreeCamera).
signal marble_selected(index: int)

# Emitted when the player taps the PLACE BET button (RGS + WAITING only).
signal bet_requested(marble_idx: int, amount: float)

# Emitted when the player requests a camera mode change (future use).
signal camera_mode_requested(mode: String)

# ─── Phase constants — public so callers can compare ─────────────────────────

const PHASE_WAITING  := "WAITING"
const PHASE_RACING   := "RACING"
const PHASE_FINISHED := "FINISHED"

# ─── Layout / timing constants ───────────────────────────────────────────────

const MOCK_BALANCE := 1250.00
const TT_ROW_H    := 30
const TT_ROW_GAP  := 2
const TT_ROW_PITCH := TT_ROW_H + TT_ROW_GAP
const COUNTDOWN_PULSE_HZ := 2.0
const BREAKPOINT_MOBILE  := 768
const MARBLE_COUNT       := 30
const PICKUP_POLL_INTERVAL := 0.20

# ─── Payout model constants (M15/M18) — informational; server is authoritative

const PAYOUT_MULT        := 19.0
const PAYOUT_1ST         := 9.0
const PAYOUT_2ND         := 4.5
const PAYOUT_3RD         := 3.0
const PAYOUT_TIER1_MULT  := 2.0
const PAYOUT_TIER2_MULT  := 3.0
const PAYOUT_JACKPOT     := 100.0

# ─── Top broadcast bar nodes ─────────────────────────────────────────────────

var _top_bar: PanelContainer
var _brand_mark: PanelContainer
var _brand_glyph: Label
var _brand_logo_tex: TextureRect
var _brand_label: Label
var _track_name_label: Label
var _phase_pill: PanelContainer
var _phase_pill_label: Label
var _round_label: Label
var _live_dot: Label
var _balance_amount_label: Label
var _balance_currency_label: Label
var _balance_caption: Label

# Top-3 podium ribbon (right of phase pill)
var _podium_box: HBoxContainer
var _podium_chips: Array[Control] = []

# ─── Timing tower nodes ──────────────────────────────────────────────────────

var _timing_tower: PanelContainer
var _timing_tower_header: Label
var _timing_tower_count: Label
var _timing_tower_scroll: ScrollContainer
var _timing_tower_canvas: Control

# ─── Timer hero nodes ────────────────────────────────────────────────────────

var _timer_card: Control
var _timer_label: Label
var _timer_caption: Label
var _bets_locked_pill: PanelContainer
var _race_progress_bar: ProgressBar

# ─── Bet panel nodes ─────────────────────────────────────────────────────────

var _bet_panel: Control
var _bet_panel_card: PanelContainer
var _bet_countdown_label: Label
var _bet_marble_strip: HBoxContainer
var _bet_marble_caption: Label
var _bet_stake_label: Label
var _bet_potential_payout: Label
var _bet_cta: Button
var _bet_chip_buttons: Array[Button] = []
var _bet_marble_chips: Array[Button] = []
var _bets_list: VBoxContainer

# ─── Winner modal nodes ──────────────────────────────────────────────────────

var _winner_modal: Control
var _winner_modal_card: PanelContainer
var _winner_color_swatch: ColorRect
var _winner_caption_label: Label
var _winner_name_label: Label
var _winner_payout_label: Label
var _winner_next_round_label: Label
var _winner_breakdown_label: Label

var _podium_name_p2: Label
var _podium_name_p3: Label
var _podium_pillar_p1: PanelContainer
var _podium_pillar_p2: PanelContainer
var _podium_pillar_p3: PanelContainer
var _final_standings_list: VBoxContainer
var _last_ranked: Array = []

# ─── Finishers list nodes (top-right post-finish panel) ──────────────────────

var _finishers_panel: PanelContainer
var _finishers_header: Label
var _finishers_countdown: Label
var _finishers_subtitle: Label
var _finishers_list: VBoxContainer

# ─── Toast nodes ─────────────────────────────────────────────────────────────

var _toast_anchor: Control
var _toast_card: PanelContainer
var _toast_label: Label
var _toast_timer: float = 0.0
var _toast_tween: Tween

# ─── Race state ──────────────────────────────────────────────────────────────

var _tick_rate: float = 60.0
var _race_started: bool = false
var _start_tick: int = -1
var _current_phase: String = PHASE_WAITING

# Per-marble metadata captured during setup(). Each entry:
# {name: String, color: Color, original_index: int}
var _marble_meta: Array = []

# original_index → {row: Control, current_rank: int, target_y: float, tween: Tween}
var _rows_by_index: Dictionary = {}

var _following_index: int = -1
var _initial_max_dist: float = -1.0
var _is_mobile: bool = false

# ─── Bet state ───────────────────────────────────────────────────────────────

var _rgs_mode: bool = false
var _round_id: int = 0
var _balance: float = MOCK_BALANCE
var _bet_amount: float = 10.0
var _selected_marble: int = -1
var _placed_bets: Array = []

var _bet_countdown_remaining: float = 0.0
var _bet_countdown_active: bool = false
var _next_round_countdown_remaining: float = 0.0
var _next_round_countdown_active: bool = false

# Finish-settle window: between the first marble crossing the line and the
# full leaderboard modal appearing. During this window the timing tower is
# hidden and the FinishersList panel (top-right) lists marbles in the order
# they cross. Default 15 s, started by start_finish_settle(). On expiry the
# winner modal is revealed via the runtime tick.
var _finish_settle_remaining: float = 0.0
var _finish_settle_active: bool = false
var _finish_settle_total: float = 0.0
# Pending winner-reveal payload — captured by start_finish_settle(), applied
# by HudRuntime when the countdown reaches zero.
var _pending_winner_name: String = ""
var _pending_winner_color: Color = Color.WHITE
var _pending_winner_prize: String = ""
var _pending_winner_breakdown: Dictionary = {}
# How many marbles have crossed (= next "place" number to assign).
var _finishers_count: int = 0

# ─── Pickup state ────────────────────────────────────────────────────────────

var _pickup_state: Dictionary = {}
var _pickup_poll_timer: float = 0.0
var _track_node: Node = null

# ─── Session stats nodes (populated by HudLayout.build_session_stats) ────────

var _stat_wagered_label:  Label
var _stat_won_label:      Label
var _stat_netpl_label:    Label
var _stat_rounds_label:   Label
var _stat_winrate_label:  Label
var _session_recent_list: VBoxContainer

# ─── Module instances ────────────────────────────────────────────────────────

var _runtime: HudRuntime

# ─── Lifecycle ───────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 10
	_runtime = HudRuntime.new()
	_runtime.init(self)
	_build_layout()
	_runtime.apply_phase(PHASE_WAITING)

func _process(delta: float) -> void:
	_runtime.process_tick(delta)

# ─── Layout build ────────────────────────────────────────────────────────────

func _build_layout() -> void:
	var root := Control.new()
	root.name = "HudRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var refs: Dictionary = {}

	# Payout constants forwarded to bet panel builder.
	var payout_consts := {
		"PAYOUT_1ST": PAYOUT_1ST, "PAYOUT_2ND": PAYOUT_2ND,
		"PAYOUT_3RD": PAYOUT_3RD, "PAYOUT_TIER1_MULT": PAYOUT_TIER1_MULT,
		"PAYOUT_TIER2_MULT": PAYOUT_TIER2_MULT, "PAYOUT_JACKPOT": PAYOUT_JACKPOT,
	}

	root.add_child(HudLayout.build_top_bar(refs))
	root.add_child(HudLayout.build_timing_tower(refs, MARBLE_COUNT, TT_ROW_PITCH))
	root.add_child(HudLayout.build_timer_hero(refs))
	root.add_child(HudLayout.build_bet_panel(refs, payout_consts,
		[5, 10, 25, 50, 100],
		_runtime.on_preset_amount,
		_runtime.on_adjust_amount,
		_runtime.on_place_bet_pressed))
	root.add_child(HudLayout.build_winner_modal(refs))
	root.add_child(HudLayout.build_finishers_list(refs, MARBLE_COUNT))
	root.add_child(HudLayout.build_toast(refs))
	root.add_child(HudLayout.build_session_stats(refs))

	_unpack_refs(refs)

# Unpack the refs Dictionary into member variables.
func _unpack_refs(r: Dictionary) -> void:
	_top_bar                = r.get("top_bar")
	_brand_mark             = r.get("brand_mark")
	_brand_glyph            = r.get("brand_glyph")
	_brand_logo_tex         = r.get("brand_logo_tex")
	_brand_label            = r.get("brand_label")
	_track_name_label       = r.get("track_name_label")
	_phase_pill             = r.get("phase_pill")
	_phase_pill_label       = r.get("phase_pill_label")
	_round_label            = r.get("round_label")
	_live_dot               = r.get("live_dot")
	_balance_amount_label   = r.get("balance_amount_label")
	_balance_currency_label = r.get("balance_currency_label")
	_balance_caption        = r.get("balance_caption")
	_podium_box             = r.get("podium_box")
	_podium_chips           = r.get("podium_chips", [] as Array[Control])

	_timing_tower           = r.get("timing_tower")
	_timing_tower_header    = r.get("timing_tower_header")
	_timing_tower_count     = r.get("timing_tower_count")
	_timing_tower_scroll    = r.get("timing_tower_scroll")
	_timing_tower_canvas    = r.get("timing_tower_canvas")

	_timer_card             = r.get("timer_card")
	_timer_label            = r.get("timer_label")
	_timer_caption          = r.get("timer_caption")
	_race_progress_bar      = r.get("race_progress_bar")
	_bets_locked_pill       = r.get("bets_locked_pill")

	_bet_panel              = r.get("bet_panel")
	_bet_panel_card         = r.get("bet_panel_card")
	_bet_countdown_label    = r.get("bet_countdown_label")
	_bet_marble_strip       = r.get("bet_marble_strip")
	_bet_marble_caption     = r.get("bet_marble_caption")
	_bet_stake_label        = r.get("bet_stake_label")
	_bet_potential_payout   = r.get("bet_potential_payout")
	_bet_cta                = r.get("bet_cta")
	_bet_chip_buttons       = r.get("bet_chip_buttons", [] as Array[Button])
	_bets_list              = r.get("bets_list")

	_winner_modal           = r.get("winner_modal")
	_winner_modal_card      = r.get("winner_modal_card")
	_winner_color_swatch    = r.get("winner_color_swatch")
	_winner_caption_label   = r.get("winner_caption_label")
	_winner_name_label      = r.get("winner_name_label")
	_winner_payout_label    = r.get("winner_payout_label")
	_winner_breakdown_label = r.get("winner_breakdown_label")
	_winner_next_round_label = r.get("winner_next_round_label")
	_podium_name_p2         = r.get("podium_name_p2")
	_podium_name_p3         = r.get("podium_name_p3")
	_podium_pillar_p1       = r.get("podium_pillar_p1")
	_podium_pillar_p2       = r.get("podium_pillar_p2")
	_podium_pillar_p3       = r.get("podium_pillar_p3")
	_final_standings_list   = r.get("final_standings_list")

	_finishers_panel        = r.get("finishers_panel")
	_finishers_header       = r.get("finishers_header")
	_finishers_countdown    = r.get("finishers_countdown")
	_finishers_subtitle     = r.get("finishers_subtitle")
	_finishers_list         = r.get("finishers_list")

	_toast_anchor           = r.get("toast_anchor")
	_toast_card             = r.get("toast_card")
	_toast_label            = r.get("toast_label")

	_stat_wagered_label     = r.get("stat_wagered_label")
	_stat_won_label         = r.get("stat_won_label")
	_stat_netpl_label       = r.get("stat_netpl_label")
	_stat_rounds_label      = r.get("stat_rounds_label")
	_stat_winrate_label     = r.get("stat_winrate_label")
	_session_recent_list    = r.get("session_recent_list")

# ─── Public API ──────────────────────────────────────────────────────────────

func enable_rgs_mode(round_id: int, initial_balance: float = MOCK_BALANCE) -> void:
	_rgs_mode = true
	_round_id = round_id
	_balance = initial_balance
	_runtime.update_balance_display()
	_round_label.text = "R#%d" % (round_id % 100000)
	_runtime.apply_phase(PHASE_WAITING)
	_show_bet_panel(true)

func start_bet_countdown(seconds: float) -> void:
	_bet_countdown_remaining = seconds
	_bet_countdown_active = true
	_bet_countdown_label.text = "RACE STARTS IN %.1fs" % seconds
	_bet_countdown_label.label_settings = HudTheme.ls_label_caps(HudTheme.C_GREEN)
	_bet_countdown_label.visible = true

func start_next_round_countdown(seconds: float) -> void:
	_next_round_countdown_remaining = seconds
	_next_round_countdown_active = true
	if _winner_next_round_label != null:
		_winner_next_round_label.text = HudI18n.t("hud.winner.next_round_in") % seconds
		_winner_next_round_label.visible = true

func update_balance(balance: float) -> void:
	if balance < 0.0:
		return
	_balance = balance
	_runtime.update_balance_display()

func apply_operator_theme(config: Dictionary) -> void:
	HudTheme.apply_operator_overrides(config)
	if config.has("lang") and typeof(config["lang"]) == TYPE_STRING:
		HudI18n.set_lang(String(config["lang"]))
	_runtime.refresh_branded_widgets()
	_runtime.refresh_localised_labels()

func set_lang(lang: String) -> void:
	HudI18n.set_lang(lang)
	_runtime.refresh_localised_labels()

func update_progress(percent: float) -> void:
	if _race_progress_bar != null:
		_race_progress_bar.value = clamp(percent, 0.0, 1.0) * 100.0

func setup(header: Array) -> void:
	_clear_timing_tower()
	_marble_meta.clear()
	_clear_bet_marble_chips()

	for i in range(header.size()):
		var m: Dictionary = header[i]
		var marble_name := String(m.get("name", "Marble_%02d" % i))
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
		_marble_meta.append({
			"name": marble_name,
			"color": color,
			"original_index": i,
		})
		var row := HudLayout.make_tower_row(i, marble_name, color, TT_ROW_H, marble_selected)
		_timing_tower_canvas.add_child(row)
		var row_y := float(i) * float(TT_ROW_PITCH)
		_rows_by_index[i] = {
			"row": row,
			"current_rank": i,
			"target_y": row_y,
			"tween": null,
		}
		row.offset_top = row_y
		row.offset_bottom = row_y + float(TT_ROW_H)

		# Bet marble strip (only used in RGS mode).
		_bet_marble_chips.append(
			HudLayout.make_bet_marble_chip(i, marble_name, color, _bet_marble_strip,
				_runtime.on_marble_chip_pressed)
		)

	update_timing_tower_count()

	_runtime.apply_phase(PHASE_RACING)
	_race_started = false
	_start_tick = -1
	_winner_modal.visible = false
	_show_bet_panel(false)
	_bets_locked_pill.visible = (_rgs_mode and not _placed_bets.is_empty())
	_bet_countdown_active = false
	_initial_max_dist = -1.0
	_finish_settle_active = false
	_finish_settle_remaining = 0.0
	_finishers_count = 0
	if _finishers_panel != null:
		_finishers_panel.visible = false
	if _finishers_list != null:
		for c in _finishers_list.get_children():
			c.queue_free()
	if _timing_tower != null:
		_timing_tower.visible = true
	if _race_progress_bar != null:
		_race_progress_bar.value = 0.0
	if _podium_box != null:
		_podium_box.visible = false

func set_track_name(track_name: String) -> void:
	var clean := track_name.trim_suffix("Track")
	var i18n_key := ""
	match clean:
		"Roulette": i18n_key = "hud.track.forest_run"
		"Craps":    i18n_key = "hud.track.volcano_run"
		"Poker":    i18n_key = "hud.track.ice_run"
		"Slots":    i18n_key = "hud.track.cavern_run"
		"Plinko":   i18n_key = "hud.track.sky_run"
		"Stadium":  i18n_key = "hud.track.stadium_run"
		"Ramp":     i18n_key = "hud.track.ramp"
	if _track_name_label != null:
		var display := HudI18n.t(i18n_key) if i18n_key != "" else clean.to_upper()
		_track_name_label.text = display
		_track_name_label.set_meta("i18n_key", i18n_key)

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
	_last_ranked = ranked

	_runtime.apply_standings(ranked)

	# Race progress bar.
	if not ranked.is_empty():
		var leader_dist: float = float(ranked[0]["dist"])
		if _initial_max_dist <= 0.0:
			var max_dist: float = 0.0
			for r in ranked:
				var d: float = float(r["dist"])
				if d != INF and d > max_dist:
					max_dist = d
			if max_dist > 1.0:
				_initial_max_dist = max_dist
		if _initial_max_dist > 0.0 and _race_progress_bar != null:
			var pct: float = clamp(1.0 - (leader_dist / _initial_max_dist), 0.0, 1.0)
			_race_progress_bar.value = pct * 100.0

func update_tick(tick: int, tick_rate_hz: float) -> void:
	_tick_rate = tick_rate_hz
	if not _race_started:
		_start_tick = tick
		_race_started = true
	var elapsed_ticks: int = max(0, tick - _start_tick)
	var seconds: float = float(elapsed_ticks) / tick_rate_hz
	_timer_label.text = HudTheme.format_race_time(seconds)

# Begin the post-finish settle window. The full leaderboard modal is held
# back for `seconds` seconds; during that window the timing tower is hidden
# and the FinishersList panel is revealed in its place. The pending winner
# payload is stashed so HudRuntime can call reveal_winner() on countdown
# expiry.
func start_finish_settle(seconds: float, winner_name: String, winner_color: Color,
		prize: String = "", breakdown: Dictionary = {}) -> void:
	_finish_settle_total = seconds
	_finish_settle_remaining = seconds
	_finish_settle_active = true
	_pending_winner_name = winner_name
	_pending_winner_color = winner_color
	_pending_winner_prize = prize
	_pending_winner_breakdown = breakdown
	_finishers_count = 0

	# Hide the timing tower so the finishers list takes its slot.
	if _timing_tower != null:
		_timing_tower.visible = false

	# Reset finishers list contents and reveal the panel.
	if _finishers_list != null:
		for c in _finishers_list.get_children():
			c.queue_free()
	if _finishers_subtitle != null:
		_finishers_subtitle.text = HudI18n.t("hud.finishers.subtitle")
	if _finishers_countdown != null:
		_finishers_countdown.text = "%ds" % int(ceil(seconds))
	if _finishers_panel != null:
		_finishers_panel.visible = true

# Append a finisher entry to the top-right list. Called from main.gd as each
# marble crosses the finish line. `place` is auto-derived from internal count
# so callers don't need to track it.
func add_finisher(idx: int, color: Color, marble_name: String = "") -> void:
	if _finishers_list == null:
		return
	_finishers_count += 1
	var resolved_name := marble_name
	if resolved_name == "" and idx >= 0 and idx < _marble_meta.size():
		resolved_name = String(_marble_meta[idx].get("name", "Marble_%02d" % idx))
	if resolved_name == "":
		resolved_name = "Marble_%02d" % idx
	var row := HudLayout.make_finisher_row(_finishers_count, resolved_name, color)
	_finishers_list.add_child(row)

# Internal — called from HudRuntime when the settle countdown reaches zero.
# Hides the finishers panel and shows the regular winner modal.
func finish_settle_complete() -> void:
	_finish_settle_active = false
	_finish_settle_remaining = 0.0
	if _finishers_panel != null:
		_finishers_panel.visible = false
	# Restore timing tower visibility — the modal usually covers it but a
	# scrim/transparency could leave it visible briefly. Cleaner to leave it
	# hidden until reset() runs at next-round time.
	reveal_winner(_pending_winner_name, _pending_winner_color,
		_pending_winner_prize, _pending_winner_breakdown)

func reveal_winner(name: String, color: Color, prize: String = "",
		breakdown: Dictionary = {}) -> void:
	_runtime.apply_phase(PHASE_FINISHED)
	_winner_name_label.text = name.to_upper()
	_winner_name_label.label_settings = HudTheme.ls_hero(color)
	_winner_color_swatch.color = color

	_runtime.populate_podium()
	_runtime.populate_final_table()

	if prize != "":
		_winner_payout_label.text = prize
		_winner_payout_label.label_settings = HudTheme.ls_metric(HudTheme.C_GOLD, HudTheme.FS_NUMBER_LARGE)
		_winner_payout_label.visible = true
	if _rgs_mode and not _placed_bets.is_empty():
		_runtime.apply_local_payout_summary(name)
	else:
		_winner_payout_label.visible = (prize != "")
	if _winner_breakdown_label != null:
		if not breakdown.is_empty():
			_winner_breakdown_label.text = _runtime.format_winner_breakdown(breakdown)
			_winner_breakdown_label.visible = true
		else:
			_winner_breakdown_label.visible = false
	_runtime.show_winner_modal()

func apply_settlement(outcomes: Array, winner_marble_idx: int) -> void:
	var _unused := winner_marble_idx
	if outcomes.is_empty():
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
		_winner_payout_label.text = "+%s" % HudTheme.format_money(total_payout)
		_winner_payout_label.label_settings = HudTheme.ls_metric(HudTheme.C_GREEN, HudTheme.FS_HERO_NUM)
	else:
		_winner_payout_label.text = HudTheme.format_money(-total_wagered)
		_winner_payout_label.label_settings = HudTheme.ls_metric(HudTheme.C_RED, HudTheme.FS_HERO_NUM)
	_winner_payout_label.visible = true

func on_bet_confirmed(bet: Dictionary) -> void:
	_balance = float(bet.get("balance_after", _balance))
	_runtime.update_balance_display()
	_placed_bets.append(bet)
	_runtime.refresh_bets_list()
	# revalidate via runtime
	_bet_cta.disabled = not (_rgs_mode and _selected_marble >= 0
		and _bet_amount > 0.0 and _bet_amount <= _balance)
	_runtime.show_toast(
		HudI18n.t("hud.bet.placed") % [
			int(bet.get("marble_idx", 0)),
			HudTheme.format_money(float(bet.get("amount", 0.0))),
		],
		HudTheme.TOAST_SUCCESS,
	)

func show_error_toast(message: String) -> void:
	_runtime.show_toast(message, HudTheme.TOAST_ERROR)

func set_following(index: int) -> void:
	if _following_index >= 0:
		_runtime.apply_following_marker(_following_index, false)
	_following_index = index
	if index >= 0:
		_runtime.apply_following_marker(index, true)

func set_track_node(track: Node) -> void:
	_track_node = track
	_pickup_state.clear()
	_pickup_poll_timer = 0.0

func reset() -> void:
	_clear_timing_tower()
	_clear_bet_marble_chips()
	_marble_meta.clear()
	_following_index = -1
	_placed_bets.clear()
	_selected_marble = -1
	_bet_amount = 10.0
	_rgs_mode = false
	_race_started = false
	_start_tick = -1
	_balance = MOCK_BALANCE
	_runtime.apply_phase(PHASE_WAITING)
	_runtime.update_balance_display()
	_timer_label.text = HudTheme.format_race_time(0.0)
	_winner_modal.visible = false
	_show_bet_panel(false)
	_bets_locked_pill.visible = false
	_bet_countdown_active = false
	_bet_countdown_remaining = 0.0
	_next_round_countdown_active = false
	_next_round_countdown_remaining = 0.0
	if _winner_next_round_label != null:
		_winner_next_round_label.visible = false
		_winner_next_round_label.text = ""
	if _winner_breakdown_label != null:
		_winner_breakdown_label.visible = false
		_winner_breakdown_label.text = ""
	_pickup_state.clear()
	_track_node = null
	if _track_name_label != null:
		_track_name_label.text = ""
	if _round_label != null:
		_round_label.text = ""
	if _podium_box != null:
		_podium_box.visible = false
	if _race_progress_bar != null:
		_race_progress_bar.value = 0.0
	_initial_max_dist = -1.0
	_finish_settle_active = false
	_finish_settle_remaining = 0.0
	_finish_settle_total = 0.0
	_pending_winner_name = ""
	_pending_winner_color = Color.WHITE
	_pending_winner_prize = ""
	_pending_winner_breakdown = {}
	_finishers_count = 0
	if _finishers_panel != null:
		_finishers_panel.visible = false
	if _finishers_list != null:
		for c in _finishers_list.get_children():
			c.queue_free()
	if _timing_tower != null:
		_timing_tower.visible = true
	_runtime.refresh_bets_list()

# ─── Player session / persistence API ────────────────────────────────────────

# Set the player identifier. Triggers a load from user://player_stats.json
# for this player's bucket and refreshes the session stats panel.
# Must be called before record_round_outcome() for per-player persistence.
func set_player_id(id: String) -> void:
	_runtime.set_player_id(id)

# Record a completed round outcome and persist to disk.
# Expected keys: track_name (String), stake (float), payout (float), won (bool)
func record_round_outcome(outcome: Dictionary) -> void:
	_runtime.record_round_outcome(outcome)

# Switch camera overlay mode ("free" / "follow" / "cinematic" / ...).
# Emits camera_mode_requested so callers can react.
func set_camera_mode(mode: String) -> void:
	camera_mode_requested.emit(mode)

# ─── Internal helpers ─────────────────────────────────────────────────────────

func _clear_timing_tower() -> void:
	if _timing_tower_canvas != null:
		for c in _timing_tower_canvas.get_children():
			c.queue_free()
	_rows_by_index.clear()

func update_timing_tower_count() -> void:
	if _timing_tower_count != null:
		var n: int = _marble_meta.size()
		var racers_key := "hud.standings.racers"
		if HudI18n.t(racers_key) != racers_key:
			_timing_tower_count.text = HudI18n.t(racers_key) % n
		else:
			_timing_tower_count.text = "%d %s" % [n, HudI18n.t("hud.standings.count_suffix")]

func _clear_bet_marble_chips() -> void:
	for c in _bet_marble_chips:
		if is_instance_valid(c):
			c.queue_free()
	_bet_marble_chips.clear()

func _show_bet_panel(yes: bool) -> void:
	if _bet_panel != null:
		_bet_panel.visible = yes
