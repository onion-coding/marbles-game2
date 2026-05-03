class_name HUD
extends CanvasLayer

# Broadcast-style HUD overlay. Premium F1/ESPN-inspired layout: top
# broadcast bar (event + LIVE + balance), right-side timing tower with
# tween-animated reorder, hero race timer, sportsbook-style bet card,
# theatrical winner modal. All styling delegated to HudTheme so colors /
# fonts / styleboxes change in one place.
#
# This file is the orchestrator + state machine. Each visual region is
# built by a dedicated _build_<region>() method and exposed via private
# refs (_top_bar, _timing_tower, _timer_hero, _bet_panel, _winner_modal,
# _toast). The public API is unchanged from the previous implementation
# so main.gd / live_main.gd / web_main.gd / playback_main.gd keep working
# without changes.

# Emitted when the user clicks a marble row in the timing tower.
# `index` is the drop-order original index, same key used by
# FreeCamera.follow_marble_index.
signal marble_selected(index: int)

# Emitted when the player taps the PLACE BET button (RGS + WAITING only).
signal bet_requested(marble_idx: int, amount: float)

# Phase strings — public so callers can compare against PHASE_RACING etc.
const PHASE_WAITING  := "WAITING"
const PHASE_RACING   := "RACING"
const PHASE_FINISHED := "FINISHED"

# Mock balance used when not in RGS mode.
const MOCK_BALANCE := 1250.00

# Fixed row height for the timing tower. Used so we can lay out rows in
# absolute coordinates (instead of VBoxContainer) and tween them on rank
# changes.
const TT_ROW_H := 30
const TT_ROW_GAP := 2
const TT_ROW_PITCH := TT_ROW_H + TT_ROW_GAP

# How fast the bet countdown final-3-seconds pulse blinks.
const COUNTDOWN_PULSE_HZ := 2.0

# Mobile breakpoint — viewport width below this triggers portrait layout.
const BREAKPOINT_MOBILE := 768

# ─── Top broadcast bar nodes ────────────────────────────────────────────────

var _top_bar: PanelContainer
var _brand_mark: PanelContainer       # holds the "M" glyph or operator logo
var _brand_glyph: Label
var _brand_logo_tex: TextureRect      # only visible when operator passed a logo
var _brand_label: Label
var _track_name_label: Label
var _phase_pill: PanelContainer
var _phase_pill_label: Label
var _round_label: Label
var _live_dot: Label                # red ● — pulses when phase is RACING
var _balance_amount_label: Label
var _balance_currency_label: Label
var _balance_caption: Label

# ─── Top-3 podium ribbon (right of phase pill) ──────────────────────────────
var _podium_box: HBoxContainer
var _podium_chips: Array[Control] = []  # 3 chips (rank 1, 2, 3)

# ─── Timing tower nodes ─────────────────────────────────────────────────────

var _timing_tower: PanelContainer
var _timing_tower_header: Label
var _timing_tower_count: Label
var _timing_tower_scroll: ScrollContainer
var _timing_tower_canvas: Control   # absolute-positioned row canvas

# ─── Timer hero nodes ───────────────────────────────────────────────────────

var _timer_card: Control
var _timer_label: Label
var _timer_caption: Label
var _bets_locked_pill: PanelContainer
var _race_progress_bar: ProgressBar    # lap/race progress under timer (0..100)

# ─── Bet panel nodes ────────────────────────────────────────────────────────

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

# ─── Winner modal nodes ─────────────────────────────────────────────────────

var _winner_modal: Control
var _winner_modal_card: PanelContainer
var _winner_color_swatch: ColorRect
var _winner_caption_label: Label
var _winner_name_label: Label
var _winner_payout_label: Label
var _winner_next_round_label: Label

# ─── Toast nodes ────────────────────────────────────────────────────────────

var _toast_anchor: Control
var _toast_card: PanelContainer
var _toast_label: Label
var _toast_timer: float = 0.0
var _toast_tween: Tween

# ─── Race state ─────────────────────────────────────────────────────────────

var _tick_rate: float = 60.0
var _race_started: bool = false
var _start_tick: int = -1
var _current_phase: String = PHASE_WAITING

# Per-marble metadata captured during setup(). Index by drop-order
# (original_index = position in this array).
# Each entry: {name: String, color: Color, original_index: int}.
var _marble_meta: Array = []

# original_index → { row: Control, current_rank: int, target_y: float, tween: Tween }
var _rows_by_index: Dictionary = {}

var _following_index: int = -1

# Race-progress tracking — captured on first update_standings() call so we
# know what 0% looks like (max distance any marble has from the finish at
# t=0). Then progress = 1 - (leader_dist / initial_max_dist).
var _initial_max_dist: float = -1.0

# Mobile responsive state — recomputed on viewport resize.
var _is_mobile: bool = false

# ─── Bet state ──────────────────────────────────────────────────────────────

var _rgs_mode: bool = false
var _round_id: int = 0
var _balance: float = MOCK_BALANCE
var _bet_amount: float = 10.0
var _selected_marble: int = -1            # index into _marble_meta
var _placed_bets: Array = []              # array of bet dicts

# Bet-window countdown state.
var _bet_countdown_remaining: float = 0.0
var _bet_countdown_active: bool = false

# Next-round countdown state (winner modal).
var _next_round_countdown_remaining: float = 0.0
var _next_round_countdown_active: bool = false

# RGS payout multiplier — informational only (server is authoritative).
const PAYOUT_MULT := 19.0

# ─── Lifecycle ──────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 10                # above viewport, below editor
	_build_layout()
	_apply_phase(PHASE_WAITING)

func _process(delta: float) -> void:
	# Toast auto-fade.
	if _toast_timer > 0.0:
		_toast_timer -= delta
		if _toast_timer <= 0.0:
			_dismiss_toast()

	# Bet-window countdown ticking.
	if _bet_countdown_active:
		_bet_countdown_remaining -= delta
		if _bet_countdown_remaining <= 0.0:
			_bet_countdown_remaining = 0.0
			_bet_countdown_active = false
			_bet_countdown_label.text = HudI18n.t("hud.bet.countdown.locked")
			_bet_countdown_label.label_settings = HudTheme.ls_label_caps(HudTheme.C_AMBER)
			_bet_cta.disabled = true
		else:
			_bet_countdown_label.text = HudI18n.t("hud.bet.countdown.starts_in") % _bet_countdown_remaining
			# Final 3 seconds: pulse amber → red.
			if _bet_countdown_remaining < 3.0:
				var pulse: float = 0.5 + 0.5 * sin(float(Engine.get_frames_drawn()) * 0.18)
				var c: Color = HudTheme.C_AMBER.lerp(HudTheme.C_RED, pulse)
				_bet_countdown_label.label_settings = HudTheme.ls_label_caps(c)
			else:
				_bet_countdown_label.label_settings = HudTheme.ls_label_caps(HudTheme.C_GREEN)

	# Next-round countdown (winner modal).
	if _next_round_countdown_active:
		_next_round_countdown_remaining -= delta
		if _next_round_countdown_remaining <= 0.0:
			_next_round_countdown_remaining = 0.0
			_next_round_countdown_active = false
			if _winner_next_round_label != null:
				_winner_next_round_label.text = HudI18n.t("hud.winner.starting")
		else:
			if _winner_next_round_label != null:
				_winner_next_round_label.text = HudI18n.t("hud.winner.next_round_in") % _next_round_countdown_remaining

	# LIVE dot pulse during RACING.
	if _current_phase == PHASE_RACING and _live_dot != null:
		var alpha: float = 0.55 + 0.45 * absf(sin(float(Time.get_ticks_msec()) * 0.004))
		_live_dot.modulate = Color(1, 1, 1, alpha)

	# Mobile/desktop responsive switch — recompute only when crossing the
	# breakpoint to avoid layout thrash every frame.
	var vp := get_viewport()
	if vp != null:
		var w: float = vp.get_visible_rect().size.x
		var should_be_mobile: bool = (w > 0.0 and w < float(BREAKPOINT_MOBILE))
		if should_be_mobile != _is_mobile:
			_is_mobile = should_be_mobile
			_apply_responsive_layout()

# ─── Public API ─────────────────────────────────────────────────────────────

func enable_rgs_mode(round_id: int, initial_balance: float = MOCK_BALANCE) -> void:
	_rgs_mode = true
	_round_id = round_id
	_balance = initial_balance
	_update_balance_display()
	_round_label.text = "R#%d" % (round_id % 100000)
	_apply_phase(PHASE_WAITING)
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
	_update_balance_display()

# Apply operator-side branding overrides at runtime. Pass any subset of:
#   accent_color : Color    — replaces gold accent (CTA, leader rows, etc.)
#   brand_text   : String   — replaces "MARBLES" label
#   brand_logo   : Texture2D — replaces the "M" glyph in the brand mark
#   lang         : String   — locale code ("en"/"it"/"es"/"de"/"pt")
# Safe to call at any time. After applying, re-styles the brand mark, the
# CTA button, and the FINISHED phase pill so the new accent shows up.
func apply_operator_theme(config: Dictionary) -> void:
	HudTheme.apply_operator_overrides(config)
	if config.has("lang") and typeof(config["lang"]) == TYPE_STRING:
		HudI18n.set_lang(String(config["lang"]))
	_refresh_branded_widgets()
	_refresh_localised_labels()

# Language-only convenience setter (no other branding overrides).
func set_lang(lang: String) -> void:
	HudI18n.set_lang(lang)
	_refresh_localised_labels()

# Race progress 0..1, drives the bar under the timer. Optional —
# update_standings() also computes this internally if main.gd doesn't
# call this explicitly. Useful if main.gd has a more accurate progress
# (e.g. arc-length distance instead of euclidean).
func update_progress(percent: float) -> void:
	if _race_progress_bar != null:
		_race_progress_bar.value = clamp(percent, 0.0, 1.0) * 100.0

func setup(header: Array) -> void:
	# Build the timing tower rows. One Control per marble, kept alive for
	# the whole race; ranks update via tween instead of rebuilding.
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
		var row := _make_tower_row(i, marble_name, color)
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
		_bet_marble_chips.append(_make_bet_marble_chip(i, marble_name, color))

	_update_timing_tower_count()

	# Transition to RACING: hide bet panel, show "BETS LOCKED" pill if any
	# bet was placed. Reset race-state.
	_apply_phase(PHASE_RACING)
	_race_started = false
	_start_tick = -1
	_winner_modal.visible = false
	_show_bet_panel(false)
	_bets_locked_pill.visible = (_rgs_mode and not _placed_bets.is_empty())
	_bet_countdown_active = false
	# Reset the progress baseline so the bar starts at 0% for the new round.
	_initial_max_dist = -1.0
	if _race_progress_bar != null:
		_race_progress_bar.value = 0.0
	# Hide the podium until the first standings update arrives.
	if _podium_box != null:
		_podium_box.visible = false

func set_track_name(track_name: String) -> void:
	# Strip the "Track" suffix and prettify: "RouletteTrack" → "Roulette" →
	# "FOREST RUN" via i18n key. Falls back to the cleaned class name if
	# the track has no localised display name.
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
	# Apply rank changes — tween each row's y position smoothly.
	for rank in range(ranked.size()):
		var idx: int = ranked[rank]["idx"]
		if not _rows_by_index.has(idx):
			continue
		var entry: Dictionary = _rows_by_index[idx]
		var prev_rank: int = entry["current_rank"]
		if prev_rank == rank:
			continue
		entry["current_rank"] = rank
		var new_y := float(rank) * float(TT_ROW_PITCH)
		entry["target_y"] = new_y
		_apply_row_rank_styling(entry["row"] as Control, rank)
		# Cancel previous tween (rapid swaps shouldn't queue).
		var old_tween: Tween = entry.get("tween")
		if old_tween != null and old_tween.is_valid():
			old_tween.kill()
		# Tween the row's offset_top + offset_bottom together so the height
		# stays constant. EASE_OUT + CUBIC gives a "settling" sports-graphics feel.
		var t := create_tween()
		t.set_ease(Tween.EASE_OUT)
		t.set_trans(Tween.TRANS_CUBIC)
		t.set_parallel(true)
		t.tween_property(entry["row"], "offset_top", new_y, HudTheme.ANIM_REORDER)
		t.tween_property(entry["row"], "offset_bottom", new_y + float(TT_ROW_H), HudTheme.ANIM_REORDER)
		entry["tween"] = t
	# Refresh follow marker (rank-styling overwrote the row's stylebox).
	if _following_index >= 0 and _rows_by_index.has(_following_index):
		_apply_following_marker(_following_index, true)

	# Top-3 podium ribbon in the top bar — refreshed every standings update.
	_update_podium_chips(ranked)

	# Race progress bar — captures initial max distance on first call,
	# then computes leader_progress = 1 - (leader_dist / initial_max_dist).
	if not ranked.is_empty():
		var leader_dist: float = float(ranked[0]["dist"])
		# Capture the trailing marble's distance the first time we have data —
		# that's a stable proxy for "race start" since at t=0 marbles are
		# evenly spread near the spawn area.
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

func reveal_winner(name: String, color: Color, prize: String = "") -> void:
	_apply_phase(PHASE_FINISHED)
	_winner_name_label.text = name
	_winner_name_label.label_settings = HudTheme.ls_hero(color)
	_winner_color_swatch.color = color
	if prize != "":
		_winner_payout_label.text = prize
		_winner_payout_label.label_settings = HudTheme.ls_metric(HudTheme.C_GOLD, HudTheme.FS_NUMBER_LARGE)
		_winner_payout_label.visible = true
	# Compute payout from local _placed_bets (RGS server may also push
	# apply_settlement which overwrites this with authoritative numbers).
	if _rgs_mode and not _placed_bets.is_empty():
		_apply_local_payout_summary(name)
	else:
		_winner_payout_label.visible = (prize != "")
	_show_winner_modal()

func apply_settlement(outcomes: Array, winner_marble_idx: int) -> void:
	# Server-authoritative result. Overwrites any local payout display.
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
	_update_balance_display()
	_placed_bets.append(bet)
	_refresh_bets_list()
	_validate_bet_button()
	_show_toast(
		HudI18n.t("hud.bet.placed") % [
			int(bet.get("marble_idx", 0)),
			HudTheme.format_money(float(bet.get("amount", 0.0))),
		],
		HudTheme.TOAST_SUCCESS,
	)

func show_error_toast(message: String) -> void:
	_show_toast(message, HudTheme.TOAST_ERROR)

func set_following(index: int) -> void:
	if _following_index >= 0:
		_apply_following_marker(_following_index, false)
	_following_index = index
	if index >= 0:
		_apply_following_marker(index, true)

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
	_apply_phase(PHASE_WAITING)
	_update_balance_display()
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
	if _track_name_label != null:
		_track_name_label.text = ""
	if _round_label != null:
		_round_label.text = ""
	if _podium_box != null:
		_podium_box.visible = false
	if _race_progress_bar != null:
		_race_progress_bar.value = 0.0
	_initial_max_dist = -1.0
	_refresh_bets_list()

# ─── Layout — root ──────────────────────────────────────────────────────────

func _build_layout() -> void:
	var root := Control.new()
	root.name = "HudRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	root.add_child(_build_top_bar())
	root.add_child(_build_timing_tower())
	root.add_child(_build_timer_hero())
	root.add_child(_build_bet_panel())
	root.add_child(_build_winner_modal())
	root.add_child(_build_toast())

# ─── Layout — top broadcast bar ─────────────────────────────────────────────

func _build_top_bar() -> Control:
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_left = 0
	bar.offset_top = 0
	bar.offset_right = 0
	bar.offset_bottom = 0
	bar.custom_minimum_size = Vector2(0, 64)
	bar.add_theme_stylebox_override("panel", HudTheme.sb_top_bar())
	_top_bar = bar

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 18)
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(hb)

	# ── Left cluster: brand + event ────────────────────────────────────────
	var brand_box := HBoxContainer.new()
	brand_box.add_theme_constant_override("separation", 10)
	hb.add_child(brand_box)

	# Brand mark — accent-coloured square containing either the "M" glyph
	# (default) or an operator-supplied logo TextureRect. Both children
	# always exist; visibility flips based on whether HudTheme has a
	# brand_logo override.
	_brand_mark = PanelContainer.new()
	_brand_mark.custom_minimum_size = Vector2(38, 38)
	_brand_mark.add_theme_stylebox_override("panel",
		HudTheme.sb_panel(HudTheme.accent(), HudTheme.accent(), 8, 0))
	_brand_glyph = Label.new()
	_brand_glyph.text = "M"
	_brand_glyph.label_settings = HudTheme.ls_title(HudTheme.C_TEXT_INVERSE, HudTheme.FS_TITLE)
	_brand_glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_brand_glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_brand_mark.add_child(_brand_glyph)
	_brand_logo_tex = TextureRect.new()
	_brand_logo_tex.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_brand_logo_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_brand_logo_tex.visible = false
	_brand_mark.add_child(_brand_logo_tex)
	brand_box.add_child(_brand_mark)

	var brand_text_v := VBoxContainer.new()
	brand_text_v.add_theme_constant_override("separation", 0)
	brand_box.add_child(brand_text_v)

	_brand_label = Label.new()
	_brand_label.text = HudTheme.brand_text()
	_brand_label.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_LABEL)
	brand_text_v.add_child(_brand_label)

	_track_name_label = Label.new()
	_track_name_label.text = ""
	_track_name_label.label_settings = HudTheme.ls_title(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_TITLE)
	brand_text_v.add_child(_track_name_label)

	# Vertical separator.
	hb.add_child(_make_vertical_divider())

	# ── Center: phase pill + LIVE indicator + round ────────────────────────
	var center_box := HBoxContainer.new()
	center_box.add_theme_constant_override("separation", 10)
	center_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	hb.add_child(center_box)

	_phase_pill = PanelContainer.new()
	_phase_pill.add_theme_stylebox_override("panel", HudTheme.sb_phase_pill(PHASE_WAITING))
	var phase_hb := HBoxContainer.new()
	phase_hb.add_theme_constant_override("separation", 6)
	_phase_pill.add_child(phase_hb)

	_live_dot = Label.new()
	_live_dot.text = "●"
	_live_dot.label_settings = HudTheme.ls_caption(HudTheme.C_RED, HudTheme.FS_TEXT)
	phase_hb.add_child(_live_dot)

	_phase_pill_label = Label.new()
	_phase_pill_label.text = HudI18n.t("hud.phase.waiting")
	_phase_pill_label.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_LABEL)
	phase_hb.add_child(_phase_pill_label)
	center_box.add_child(_phase_pill)

	_round_label = Label.new()
	_round_label.text = ""
	_round_label.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_LABEL)
	center_box.add_child(_round_label)

	# Top-3 podium ribbon — three small chips after the round indicator.
	# Hidden until the first standings update arrives.
	_podium_box = HBoxContainer.new()
	_podium_box.add_theme_constant_override("separation", 6)
	_podium_box.visible = false
	center_box.add_child(_podium_box)
	for rank in range(3):
		var chip := _make_podium_chip(rank)
		_podium_box.add_child(chip)
		_podium_chips.append(chip)

	# Spacer pushes balance to the right.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(spacer)

	# ── Right cluster: balance ─────────────────────────────────────────────
	var bal_panel := PanelContainer.new()
	bal_panel.add_theme_stylebox_override("panel",
		HudTheme.sb_panel(Color(0.05, 0.10, 0.18, 0.85), HudTheme.C_BORDER_BRIGHT, 10, 1))
	hb.add_child(bal_panel)

	var bal_hb := HBoxContainer.new()
	bal_hb.add_theme_constant_override("separation", 8)
	bal_panel.add_child(bal_hb)

	_balance_caption = Label.new()
	_balance_caption.text = HudI18n.t("hud.balance.caption")
	_balance_caption.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_TINY)
	var bal_caption_v := VBoxContainer.new()
	bal_caption_v.add_theme_constant_override("separation", 0)
	bal_caption_v.add_child(_balance_caption)
	var bal_amount_hb := HBoxContainer.new()
	bal_amount_hb.add_theme_constant_override("separation", 4)
	bal_caption_v.add_child(bal_amount_hb)

	_balance_amount_label = Label.new()
	_balance_amount_label.text = HudTheme.format_money(MOCK_BALANCE)
	_balance_amount_label.label_settings = HudTheme.ls_metric(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_NUMBER_LARGE)
	bal_amount_hb.add_child(_balance_amount_label)

	_balance_currency_label = Label.new()
	_balance_currency_label.text = HudI18n.t("hud.balance.currency")
	_balance_currency_label.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_TINY)
	bal_amount_hb.add_child(_balance_currency_label)

	bal_hb.add_child(bal_caption_v)

	return bar

# Build a single podium chip (rank 1, 2, or 3). Looks like a tiny pill:
# ordinal "1°/2°/3°" + color chip + marble id. Initially empty; populated
# by _update_podium_chips() once standings start ticking.
func _make_podium_chip(rank: int) -> Control:
	var chip := PanelContainer.new()
	chip.custom_minimum_size = Vector2(72, 24)
	# Rank-tinted background — gold for 1st, silver for 2nd, bronze for 3rd.
	var tint: Color
	match rank:
		0: tint = HudTheme.C_GOLD
		1: tint = Color(0.72, 0.74, 0.78)        # silver
		_: tint = Color(0.78, 0.55, 0.30)        # bronze
	chip.add_theme_stylebox_override("panel",
		HudTheme.sb_pill(Color(tint.r, tint.g, tint.b, 0.18)))

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 4)
	chip.add_child(hb)

	var rank_label := Label.new()
	rank_label.name = "RankLabel"
	rank_label.text = "%d°" % (rank + 1)
	rank_label.label_settings = HudTheme.ls_label_caps(tint, HudTheme.FS_LABEL)
	hb.add_child(rank_label)

	var color_chip := PanelContainer.new()
	color_chip.name = "ColorChip"
	color_chip.custom_minimum_size = Vector2(10, 10)
	color_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.4, 0.4, 0.4)
	sb.set_corner_radius_all(3)
	color_chip.add_theme_stylebox_override("panel", sb)
	hb.add_child(color_chip)

	var id_label := Label.new()
	id_label.name = "IdLabel"
	id_label.text = "—"
	id_label.label_settings = HudTheme.ls_metric(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_LABEL)
	hb.add_child(id_label)
	return chip

# Update the 3 podium chips with the top-3 from the latest ranking.
# `ranked` is the sorted array passed into update_standings().
func _update_podium_chips(ranked: Array) -> void:
	if _podium_box == null:
		return
	if _is_mobile:
		# Hidden in mobile portrait — top bar is collapsed there.
		_podium_box.visible = false
		return
	_podium_box.visible = (_current_phase != PHASE_WAITING) and (ranked.size() >= 3)
	if not _podium_box.visible:
		return
	for rank in range(min(3, _podium_chips.size(), ranked.size())):
		var idx: int = int(ranked[rank]["idx"])
		if idx < 0 or idx >= _marble_meta.size():
			continue
		var meta: Dictionary = _marble_meta[idx]
		var chip: Control = _podium_chips[rank]
		var color_chip := chip.find_child("ColorChip", true, false) as PanelContainer
		if color_chip != null:
			var sb: StyleBoxFlat = color_chip.get_theme_stylebox("panel") as StyleBoxFlat
			if sb != null:
				sb.bg_color = meta["color"]
		var id_label := chip.find_child("IdLabel", true, false) as Label
		if id_label != null:
			id_label.text = HudTheme.short_marble_name(meta["name"])

func _make_vertical_divider() -> Control:
	var div := ColorRect.new()
	div.color = HudTheme.C_BORDER_DIM
	div.custom_minimum_size = Vector2(1, 36)
	div.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return div

# ─── Layout — timing tower ──────────────────────────────────────────────────

func _build_timing_tower() -> Control:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -300
	panel.offset_top = 80
	panel.offset_right = -16
	panel.offset_bottom = -180
	panel.add_theme_stylebox_override("panel",
		HudTheme.sb_panel(HudTheme.C_SURFACE_1, HudTheme.C_BORDER, 10, 1))
	_timing_tower = panel

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	# Header row: "STANDINGS" + count.
	var head_hb := HBoxContainer.new()
	head_hb.add_theme_constant_override("separation", 8)
	vb.add_child(head_hb)

	_timing_tower_header = Label.new()
	_timing_tower_header.text = HudI18n.t("hud.standings.header")
	_timing_tower_header.label_settings = HudTheme.ls_label_caps(HudTheme.accent(), HudTheme.FS_LABEL)
	_timing_tower_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head_hb.add_child(_timing_tower_header)

	_timing_tower_count = Label.new()
	_timing_tower_count.text = ""
	_timing_tower_count.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_TINY)
	head_hb.add_child(_timing_tower_count)

	# Thin divider below the header.
	var sep := ColorRect.new()
	sep.color = HudTheme.C_BORDER_DIM
	sep.custom_minimum_size = Vector2(0, 1)
	vb.add_child(sep)

	# Scrollable absolute-positioned rows canvas.
	_timing_tower_scroll = ScrollContainer.new()
	_timing_tower_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_timing_tower_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_timing_tower_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(_timing_tower_scroll)

	_timing_tower_canvas = Control.new()
	_timing_tower_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_timing_tower_canvas.custom_minimum_size = Vector2(0, 20 * TT_ROW_PITCH)
	_timing_tower_scroll.add_child(_timing_tower_canvas)

	return panel

func _make_tower_row(orig_idx: int, marble_name: String, color: Color) -> Control:
	# Each row is a Button (for click-to-follow) + content. The row anchors
	# horizontally (full width of the canvas) and its vertical position is
	# controlled via offset_top / offset_bottom — this way `position.y`
	# never conflicts with the anchor system (which would emit a runtime
	# warning) and Tween can animate offset_top directly on rank changes.
	var btn := Button.new()
	btn.flat = false
	btn.focus_mode = Control.FOCUS_NONE
	btn.anchor_left   = 0.0
	btn.anchor_top    = 0.0
	btn.anchor_right  = 1.0
	btn.anchor_bottom = 0.0
	btn.offset_left   = 0.0
	btn.offset_top    = 0.0
	btn.offset_right  = 0.0
	btn.offset_bottom = float(TT_ROW_H)
	btn.custom_minimum_size = Vector2(0, TT_ROW_H)

	# Default + leader styling applied via _apply_row_rank_styling().
	var sb_normal := HudTheme.sb_row(Color(1.0, 1.0, 1.0, 0.04))
	var sb_hover  := HudTheme.sb_row(Color(1.0, 1.0, 1.0, 0.10))
	var sb_press  := HudTheme.sb_row(Color(1.0, 1.0, 1.0, 0.18))
	btn.add_theme_stylebox_override("normal",   sb_normal)
	btn.add_theme_stylebox_override("hover",    sb_hover)
	btn.add_theme_stylebox_override("pressed",  sb_press)
	btn.add_theme_stylebox_override("disabled", sb_normal)
	btn.add_theme_stylebox_override("focus",    sb_normal)

	# Layout: rank | color chip | marble id | (spacer)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	hb.set_anchors_preset(Control.PRESET_FULL_RECT)
	hb.set_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_KEEP_SIZE, 6)
	btn.add_child(hb)

	# Rank — large monospace.
	var rank_label := Label.new()
	rank_label.name = "RankLabel"
	rank_label.text = "%02d" % (orig_idx + 1)
	rank_label.label_settings = HudTheme.ls_metric(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_TEXT)
	rank_label.custom_minimum_size = Vector2(28, 0)
	rank_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hb.add_child(rank_label)

	# Color chip — small rounded square.
	var chip := PanelContainer.new()
	chip.custom_minimum_size = Vector2(14, 14)
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb_chip := StyleBoxFlat.new()
	sb_chip.bg_color = color
	sb_chip.corner_radius_top_left    = 4
	sb_chip.corner_radius_top_right   = 4
	sb_chip.corner_radius_bottom_left = 4
	sb_chip.corner_radius_bottom_right = 4
	chip.add_theme_stylebox_override("panel", sb_chip)
	hb.add_child(chip)

	# Marble id text.
	var id_label := Label.new()
	id_label.name = "IdLabel"
	id_label.text = HudTheme.short_marble_name(marble_name)
	id_label.label_settings = HudTheme.ls_caption(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_TEXT)
	id_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	id_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hb.add_child(id_label)

	btn.pressed.connect(func() -> void:
		marble_selected.emit(orig_idx)
	)

	return btn

func _apply_row_rank_styling(row: Control, rank: int) -> void:
	# Leader (rank 0) row: gold tinted bg + gold left border.
	# Top 3 (rank 1-2): subtle highlight. Rest: default.
	var sb_normal: StyleBoxFlat
	var rank_color: Color
	var id_color: Color
	if rank == 0:
		var acc: Color = HudTheme.accent()
		sb_normal = HudTheme.sb_row(
			Color(acc.r, acc.g, acc.b, 0.16),
			acc)
		rank_color = acc
		id_color = acc
	elif rank <= 2:
		sb_normal = HudTheme.sb_row(Color(1.0, 1.0, 1.0, 0.07))
		rank_color = HudTheme.C_TEXT_PRIMARY
		id_color = HudTheme.C_TEXT_PRIMARY
	else:
		sb_normal = HudTheme.sb_row(Color(1.0, 1.0, 1.0, 0.04))
		rank_color = HudTheme.C_TEXT_SECONDARY
		id_color = HudTheme.C_TEXT_PRIMARY
	row.add_theme_stylebox_override("normal",   sb_normal)
	row.add_theme_stylebox_override("disabled", sb_normal)
	row.add_theme_stylebox_override("focus",    sb_normal)
	# Refresh row content rank label.
	var rank_label := row.find_child("RankLabel", true, false) as Label
	if rank_label != null:
		rank_label.text = "%02d" % (rank + 1)
		rank_label.label_settings = HudTheme.ls_metric(rank_color, HudTheme.FS_TEXT)
	var id_label := row.find_child("IdLabel", true, false) as Label
	if id_label != null:
		id_label.label_settings = HudTheme.ls_caption(id_color, HudTheme.FS_TEXT)

func _apply_following_marker(orig_idx: int, active: bool) -> void:
	if not _rows_by_index.has(orig_idx):
		return
	var entry: Dictionary = _rows_by_index[orig_idx]
	var row: Control = entry["row"]
	var sb: StyleBoxFlat = (row.get_theme_stylebox("normal") as StyleBoxFlat).duplicate()
	if active:
		sb.border_color = HudTheme.C_CYAN
		sb.border_width_left = 4
	else:
		# Restore rank-based styling.
		_apply_row_rank_styling(row, int(entry["current_rank"]))
		return
	row.add_theme_stylebox_override("normal",   sb)
	row.add_theme_stylebox_override("disabled", sb)
	row.add_theme_stylebox_override("focus",    sb)

func _clear_timing_tower() -> void:
	if _timing_tower_canvas != null:
		for c in _timing_tower_canvas.get_children():
			c.queue_free()
	_rows_by_index.clear()

func _update_timing_tower_count() -> void:
	if _timing_tower_count != null:
		_timing_tower_count.text = "%d %s" % [
			_marble_meta.size(), HudI18n.t("hud.standings.count_suffix")]

# ─── Layout — timer hero ────────────────────────────────────────────────────

func _build_timer_hero() -> Control:
	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	anchor.offset_left = -130
	anchor.offset_right = 130
	anchor.offset_top = -130
	anchor.offset_bottom = -32
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timer_card = anchor

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", HudTheme.sb_card())
	card.set_anchors_preset(Control.PRESET_FULL_RECT)
	anchor.add_child(card)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 2)
	card.add_child(vb)

	_timer_caption = Label.new()
	_timer_caption.text = HudI18n.t("hud.timer.caption")
	_timer_caption.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_TINY)
	_timer_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_timer_caption)

	_timer_label = Label.new()
	_timer_label.text = HudTheme.format_race_time(0.0)
	_timer_label.label_settings = HudTheme.ls_timer(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_TIMER)
	_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_timer_label)

	# Race progress bar — driven by leader_distance / initial_max_distance
	# in update_standings(). Tinted accent (gold) so it reads as the
	# canonical race-progress indicator.
	_race_progress_bar = ProgressBar.new()
	_race_progress_bar.show_percentage = false
	_race_progress_bar.min_value = 0.0
	_race_progress_bar.max_value = 100.0
	_race_progress_bar.value = 0.0
	_race_progress_bar.custom_minimum_size = Vector2(0, 4)
	# Custom styling — slim track, accent-coloured fill.
	var pb_track := StyleBoxFlat.new()
	pb_track.bg_color = Color(1.0, 1.0, 1.0, 0.10)
	pb_track.set_corner_radius_all(2)
	var pb_fill := StyleBoxFlat.new()
	pb_fill.bg_color = HudTheme.accent()
	pb_fill.set_corner_radius_all(2)
	_race_progress_bar.add_theme_stylebox_override("background", pb_track)
	_race_progress_bar.add_theme_stylebox_override("fill", pb_fill)
	vb.add_child(_race_progress_bar)

	# "Bets locked" pill — only shown during RACING when at least one bet
	# was placed. Floats below the timer card.
	_bets_locked_pill = PanelContainer.new()
	_bets_locked_pill.add_theme_stylebox_override("panel",
		HudTheme.sb_pill(Color(HudTheme.C_AMBER.r, HudTheme.C_AMBER.g, HudTheme.C_AMBER.b, 0.20)))
	_bets_locked_pill.visible = false
	var lock_lbl := Label.new()
	lock_lbl.text = HudI18n.t("hud.timer.bets_locked")
	lock_lbl.label_settings = HudTheme.ls_label_caps(HudTheme.C_AMBER, HudTheme.FS_TINY)
	lock_lbl.set_meta("i18n_key", "hud.timer.bets_locked")
	_bets_locked_pill.add_child(lock_lbl)
	vb.add_child(_bets_locked_pill)

	return anchor

# ─── Layout — bet panel ─────────────────────────────────────────────────────

func _build_bet_panel() -> Control:
	# The whole bet panel sits center-bottom, above the timer card.
	# Visible only in WAITING + RGS mode; show_bet_panel(false) hides it.
	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	anchor.offset_left = -290
	anchor.offset_right = 290
	anchor.offset_top = -380
	anchor.offset_bottom = -150
	anchor.mouse_filter = Control.MOUSE_FILTER_PASS
	anchor.visible = false
	_bet_panel = anchor

	_bet_panel_card = PanelContainer.new()
	_bet_panel_card.add_theme_stylebox_override("panel", HudTheme.sb_card(HudTheme.C_SURFACE_2))
	_bet_panel_card.set_anchors_preset(Control.PRESET_FULL_RECT)
	anchor.add_child(_bet_panel_card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", HudTheme.GAP_SECTION)
	_bet_panel_card.add_child(vb)

	# ── Header: "PLACE YOUR BET" + countdown ──────────────────────────────
	var header_hb := HBoxContainer.new()
	header_hb.add_theme_constant_override("separation", 12)
	vb.add_child(header_hb)

	var header_lbl := Label.new()
	header_lbl.text = HudI18n.t("hud.bet.header")
	header_lbl.label_settings = HudTheme.ls_label_caps(HudTheme.accent(), HudTheme.FS_LABEL)
	header_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_lbl.set_meta("i18n_key", "hud.bet.header")
	header_hb.add_child(header_lbl)

	_bet_countdown_label = Label.new()
	_bet_countdown_label.text = ""
	_bet_countdown_label.label_settings = HudTheme.ls_label_caps(HudTheme.C_GREEN, HudTheme.FS_LABEL)
	_bet_countdown_label.visible = false
	header_hb.add_child(_bet_countdown_label)

	# Divider.
	var div1 := ColorRect.new()
	div1.color = HudTheme.C_BORDER_DIM
	div1.custom_minimum_size = Vector2(0, 1)
	vb.add_child(div1)

	# ── Marble selector strip ────────────────────────────────────────────
	_bet_marble_caption = Label.new()
	_bet_marble_caption.text = HudI18n.t("hud.bet.pick_marble")
	_bet_marble_caption.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_TINY)
	_bet_marble_caption.set_meta("i18n_key", "hud.bet.pick_marble")
	vb.add_child(_bet_marble_caption)

	var strip_scroll := ScrollContainer.new()
	strip_scroll.custom_minimum_size = Vector2(0, 50)
	strip_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(strip_scroll)

	_bet_marble_strip = HBoxContainer.new()
	_bet_marble_strip.add_theme_constant_override("separation", 6)
	strip_scroll.add_child(_bet_marble_strip)

	# ── Stake row: chips + custom amount ─────────────────────────────────
	var stake_caption := Label.new()
	stake_caption.text = HudI18n.t("hud.bet.stake_caption")
	stake_caption.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_TINY)
	stake_caption.set_meta("i18n_key", "hud.bet.stake_caption")
	vb.add_child(stake_caption)

	var stake_hb := HBoxContainer.new()
	stake_hb.add_theme_constant_override("separation", 8)
	vb.add_child(stake_hb)

	for preset_val in [5, 10, 25, 50, 100]:
		var pb := Button.new()
		pb.text = "%d" % preset_val
		pb.flat = false
		pb.focus_mode = Control.FOCUS_NONE
		_apply_chip_style(pb, false)
		pb.custom_minimum_size = Vector2(48, 32)
		pb.pressed.connect(_on_preset_amount.bind(float(preset_val), pb))
		_bet_chip_buttons.append(pb)
		stake_hb.add_child(pb)

	# Adjust + amount.
	var adj_hb := HBoxContainer.new()
	adj_hb.add_theme_constant_override("separation", 6)
	vb.add_child(adj_hb)

	for delta in [-10, -1, 1, 10]:
		var b := Button.new()
		b.text = "%+d" % delta
		b.flat = false
		b.focus_mode = Control.FOCUS_NONE
		_apply_chip_style(b, false)
		b.custom_minimum_size = Vector2(40, 28)
		b.pressed.connect(_on_adjust_amount.bind(float(delta)))
		adj_hb.add_child(b)

	_bet_stake_label = Label.new()
	_bet_stake_label.text = HudTheme.format_money(_bet_amount)
	_bet_stake_label.label_settings = HudTheme.ls_metric(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_NUMBER_LARGE)
	_bet_stake_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_bet_stake_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	adj_hb.add_child(_bet_stake_label)

	# ── Potential payout ─────────────────────────────────────────────────
	_bet_potential_payout = Label.new()
	_bet_potential_payout.text = "%s —" % HudI18n.t("hud.bet.potential_win")
	_bet_potential_payout.label_settings = HudTheme.ls_label_caps(HudTheme.C_GREEN, HudTheme.FS_TEXT)
	_bet_potential_payout.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_bet_potential_payout)

	# ── CTA ──────────────────────────────────────────────────────────────
	_bet_cta = Button.new()
	_bet_cta.text = HudI18n.t("hud.bet.cta")
	_bet_cta.flat = false
	_bet_cta.focus_mode = Control.FOCUS_NONE
	_bet_cta.set_meta("i18n_key", "hud.bet.cta")
	_bet_cta.add_theme_stylebox_override("normal",   HudTheme.sb_button_primary(HudTheme.accent()))
	_bet_cta.add_theme_stylebox_override("hover",    HudTheme.sb_button_primary(HudTheme.accent().lightened(0.10)))
	_bet_cta.add_theme_stylebox_override("pressed",  HudTheme.sb_button_primary(HudTheme.accent().darkened(0.10)))
	_bet_cta.add_theme_stylebox_override("disabled", HudTheme.sb_button_primary_disabled())
	_bet_cta.add_theme_stylebox_override("focus",    HudTheme.sb_button_primary(HudTheme.accent()))
	_bet_cta.add_theme_font_override("font", HudTheme.font_display())
	_bet_cta.add_theme_font_size_override("font_size", HudTheme.FS_TEXT)
	_bet_cta.add_theme_color_override("font_color", HudTheme.C_TEXT_INVERSE)
	_bet_cta.add_theme_color_override("font_disabled_color", HudTheme.C_TEXT_DIM)
	_bet_cta.add_theme_color_override("font_hover_color", HudTheme.C_TEXT_INVERSE)
	_bet_cta.add_theme_color_override("font_pressed_color", HudTheme.C_TEXT_INVERSE)
	_bet_cta.disabled = true
	_bet_cta.pressed.connect(_on_place_bet_pressed)
	vb.add_child(_bet_cta)

	# ── Active bets list ─────────────────────────────────────────────────
	var bets_caption := Label.new()
	bets_caption.text = HudI18n.t("hud.bet.your_bets")
	bets_caption.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_TINY)
	bets_caption.set_meta("i18n_key", "hud.bet.your_bets")
	vb.add_child(bets_caption)

	var bets_scroll := ScrollContainer.new()
	bets_scroll.custom_minimum_size = Vector2(0, 60)
	bets_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(bets_scroll)

	_bets_list = VBoxContainer.new()
	_bets_list.add_theme_constant_override("separation", 4)
	_bets_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bets_scroll.add_child(_bets_list)

	return anchor

func _make_bet_marble_chip(orig_idx: int, marble_name: String, color: Color) -> Button:
	var chip := Button.new()
	chip.flat = false
	chip.focus_mode = Control.FOCUS_NONE
	chip.toggle_mode = false
	chip.custom_minimum_size = Vector2(48, 44)
	chip.tooltip_text = marble_name
	_apply_marble_chip_style(chip, color, false)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 0)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	chip.add_child(vb)

	var color_block := PanelContainer.new()
	color_block.custom_minimum_size = Vector2(0, 14)
	var sb_block := StyleBoxFlat.new()
	sb_block.bg_color = color
	sb_block.corner_radius_top_left    = 4
	sb_block.corner_radius_top_right   = 4
	sb_block.corner_radius_bottom_left = 4
	sb_block.corner_radius_bottom_right = 4
	color_block.add_theme_stylebox_override("panel", sb_block)
	vb.add_child(color_block)

	var lbl := Label.new()
	lbl.text = HudTheme.short_marble_name(marble_name)
	lbl.label_settings = HudTheme.ls_metric(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_TINY)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(lbl)

	chip.pressed.connect(func() -> void:
		_on_marble_chip_pressed(orig_idx, color)
	)
	if _bet_marble_strip != null:
		_bet_marble_strip.add_child(chip)
	return chip

func _apply_marble_chip_style(chip: Button, color: Color, selected: bool) -> void:
	var sb_normal: StyleBoxFlat
	var sb_hover: StyleBoxFlat
	if selected:
		sb_normal = HudTheme.sb_chip(true, color)
		sb_hover  = HudTheme.sb_chip(true, color)
	else:
		sb_normal = HudTheme.sb_chip(false, color)
		sb_hover  = HudTheme.sb_chip(false, color.lightened(0.10))
	chip.add_theme_stylebox_override("normal",   sb_normal)
	chip.add_theme_stylebox_override("hover",    sb_hover)
	chip.add_theme_stylebox_override("pressed",  sb_normal)
	chip.add_theme_stylebox_override("disabled", sb_normal)
	chip.add_theme_stylebox_override("focus",    sb_normal)

func _apply_chip_style(btn: Button, selected: bool) -> void:
	var sb_normal := HudTheme.sb_chip(selected)
	var sb_hover  := HudTheme.sb_chip(selected)
	btn.add_theme_stylebox_override("normal",   sb_normal)
	btn.add_theme_stylebox_override("hover",    sb_hover)
	btn.add_theme_stylebox_override("pressed",  sb_normal)
	btn.add_theme_stylebox_override("disabled", sb_normal)
	btn.add_theme_stylebox_override("focus",    sb_normal)
	btn.add_theme_font_override("font", HudTheme.font_body())
	btn.add_theme_font_size_override("font_size", HudTheme.FS_TEXT)
	btn.add_theme_color_override("font_color", HudTheme.C_TEXT_PRIMARY)
	btn.add_theme_color_override("font_hover_color", HudTheme.C_TEXT_PRIMARY)
	btn.add_theme_color_override("font_pressed_color", HudTheme.C_TEXT_PRIMARY)

func _clear_bet_marble_chips() -> void:
	for c in _bet_marble_chips:
		if is_instance_valid(c):
			c.queue_free()
	_bet_marble_chips.clear()

func _on_marble_chip_pressed(orig_idx: int, _color: Color) -> void:
	# Find the meta entry whose original_index matches.
	for i in range(_marble_meta.size()):
		if int(_marble_meta[i]["original_index"]) == orig_idx:
			_selected_marble = i
			break
	# Refresh chip styling.
	for i in range(_bet_marble_chips.size()):
		if not is_instance_valid(_bet_marble_chips[i]):
			continue
		var meta_color: Color = _marble_meta[i]["color"]
		_apply_marble_chip_style(_bet_marble_chips[i], meta_color, i == _selected_marble)
	_validate_bet_button()
	_update_potential_payout()

func _on_preset_amount(val: float, source_btn: Button) -> void:
	_bet_amount = val
	_bet_stake_label.text = HudTheme.format_money(_bet_amount)
	# Highlight selected chip; reset others.
	for b in _bet_chip_buttons:
		_apply_chip_style(b, b == source_btn)
	_validate_bet_button()
	_update_potential_payout()

func _on_adjust_amount(delta: float) -> void:
	_bet_amount = max(1.0, _bet_amount + delta)
	_bet_stake_label.text = HudTheme.format_money(_bet_amount)
	# Adjusting clears chip selection — the stake is no longer at a preset.
	for b in _bet_chip_buttons:
		_apply_chip_style(b, false)
	_validate_bet_button()
	_update_potential_payout()

func _on_place_bet_pressed() -> void:
	if _selected_marble < 0 or _bet_amount <= 0.0:
		return
	if _bet_amount > _balance:
		_show_toast(HudI18n.t("hud.bet.insufficient"), HudTheme.TOAST_ERROR)
		return
	var original_idx: int = _marble_meta[_selected_marble]["original_index"]
	bet_requested.emit(original_idx, _bet_amount)

func _validate_bet_button() -> void:
	if not _rgs_mode:
		_bet_cta.disabled = true
		_bet_cta.tooltip_text = "Betting requires RGS mode (--rgs=<url>)"
		return
	var valid := _selected_marble >= 0 and _bet_amount > 0.0 and _bet_amount <= _balance
	_bet_cta.disabled = not valid
	if valid:
		_bet_cta.tooltip_text = ""

func _update_potential_payout() -> void:
	if _selected_marble < 0:
		_bet_potential_payout.text = "%s —" % HudI18n.t("hud.bet.potential_win")
		return
	var payout := _bet_amount * PAYOUT_MULT
	_bet_potential_payout.text = HudI18n.t("hud.bet.potential_win_value") % HudTheme.format_money(payout)

func _refresh_bets_list() -> void:
	for c in _bets_list.get_children():
		c.queue_free()
	for b in _placed_bets:
		var marble_idx: int = int(b.get("marble_idx", 0))
		var amount: float = float(b.get("amount", 0.0))
		var row := PanelContainer.new()
		row.add_theme_stylebox_override("panel",
			HudTheme.sb_panel(Color(1, 1, 1, 0.04), HudTheme.C_BORDER_DIM, 8, 1))
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 8)
		row.add_child(hb)
		# Color chip of the marble bet on (lookup color from meta).
		var color := Color(0.6, 0.6, 0.6)
		for m in _marble_meta:
			if int(m["original_index"]) == marble_idx:
				color = m["color"]
				break
		var chip := PanelContainer.new()
		chip.custom_minimum_size = Vector2(10, 10)
		chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var sbc := StyleBoxFlat.new()
		sbc.bg_color = color
		sbc.set_corner_radius_all(3)
		chip.add_theme_stylebox_override("panel", sbc)
		hb.add_child(chip)
		var nm := Label.new()
		nm.text = "Marble %02d" % marble_idx
		nm.label_settings = HudTheme.ls_caption(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_SMALL)
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hb.add_child(nm)
		var amt := Label.new()
		amt.text = HudTheme.format_money(amount)
		amt.label_settings = HudTheme.ls_metric(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_SMALL)
		hb.add_child(amt)
		_bets_list.add_child(row)

func _show_bet_panel(yes: bool) -> void:
	if _bet_panel != null:
		_bet_panel.visible = yes

# ─── Layout — winner modal ──────────────────────────────────────────────────

func _build_winner_modal() -> Control:
	var control := Control.new()
	control.set_anchors_preset(Control.PRESET_FULL_RECT)
	control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	control.visible = false
	_winner_modal = control

	# Dark scrim.
	var scrim := ColorRect.new()
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.color = Color(0, 0, 0, 0.78)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	control.add_child(scrim)

	# Centered hero card.
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	control.add_child(center)

	_winner_modal_card = PanelContainer.new()
	_winner_modal_card.add_theme_stylebox_override("panel",
		HudTheme.sb_card(HudTheme.C_SURFACE_HERO, HudTheme.C_GOLD))
	_winner_modal_card.custom_minimum_size = Vector2(520, 0)
	center.add_child(_winner_modal_card)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 14)
	_winner_modal_card.add_child(vb)

	# "🏁 WINNER" caption row with color chip.
	var caption_hb := HBoxContainer.new()
	caption_hb.alignment = BoxContainer.ALIGNMENT_CENTER
	caption_hb.add_theme_constant_override("separation", 12)
	vb.add_child(caption_hb)

	_winner_color_swatch = ColorRect.new()
	_winner_color_swatch.color = HudTheme.C_GOLD
	_winner_color_swatch.custom_minimum_size = Vector2(28, 28)
	_winner_color_swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	caption_hb.add_child(_winner_color_swatch)

	_winner_caption_label = Label.new()
	_winner_caption_label.text = HudI18n.t("hud.winner.caption")
	_winner_caption_label.label_settings = HudTheme.ls_label_caps(HudTheme.accent(), HudTheme.FS_TITLE)
	_winner_caption_label.set_meta("i18n_key", "hud.winner.caption")
	caption_hb.add_child(_winner_caption_label)

	# Marble name — hero size.
	_winner_name_label = Label.new()
	_winner_name_label.text = "—"
	_winner_name_label.label_settings = HudTheme.ls_hero(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_HERO_NUM)
	_winner_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_winner_name_label)

	# Payout result — hidden when no bets / non-RGS mode.
	_winner_payout_label = Label.new()
	_winner_payout_label.text = ""
	_winner_payout_label.label_settings = HudTheme.ls_metric(HudTheme.C_GREEN, HudTheme.FS_HERO_NUM)
	_winner_payout_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_winner_payout_label.visible = false
	vb.add_child(_winner_payout_label)

	# Subtle divider before next-round countdown.
	var div := ColorRect.new()
	div.color = HudTheme.C_BORDER_DIM
	div.custom_minimum_size = Vector2(0, 1)
	vb.add_child(div)

	# Next-round countdown.
	_winner_next_round_label = Label.new()
	_winner_next_round_label.text = ""
	_winner_next_round_label.label_settings = HudTheme.ls_label_caps(HudTheme.C_CYAN, HudTheme.FS_LABEL)
	_winner_next_round_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_winner_next_round_label.visible = false
	vb.add_child(_winner_next_round_label)

	return control

func _show_winner_modal() -> void:
	_winner_modal.visible = true
	# Entrance: scale 0.92 → 1.0 + alpha 0 → 1, parallel.
	_winner_modal_card.modulate = Color(1, 1, 1, 0)
	_winner_modal_card.scale = Vector2(0.92, 0.92)
	_winner_modal_card.pivot_offset = _winner_modal_card.size * 0.5
	var t := create_tween()
	t.set_parallel(true)
	t.set_ease(Tween.EASE_OUT)
	t.set_trans(Tween.TRANS_CUBIC)
	t.tween_property(_winner_modal_card, "modulate:a", 1.0, HudTheme.ANIM_NORMAL)
	t.tween_property(_winner_modal_card, "scale", Vector2(1.0, 1.0), HudTheme.ANIM_NORMAL)

func _apply_local_payout_summary(winner_name: String) -> void:
	# Compute payout from local _placed_bets given the winning marble.
	var winner_idx := -1
	var trimmed := winner_name.trim_prefix("Marble_")
	if trimmed.is_valid_int():
		winner_idx = int(trimmed)
	var total_payout := 0.0
	var total_wagered := 0.0
	for b in _placed_bets:
		total_wagered += float(b["amount"])
		if int(b["marble_idx"]) == winner_idx:
			total_payout += float(b.get("expected_payout_if_win", b["amount"] * PAYOUT_MULT))
	if total_payout > 0.0:
		_winner_payout_label.text = "+%s" % HudTheme.format_money(total_payout)
		_winner_payout_label.label_settings = HudTheme.ls_metric(HudTheme.C_GREEN, HudTheme.FS_HERO_NUM)
	else:
		_winner_payout_label.text = HudTheme.format_money(-total_wagered)
		_winner_payout_label.label_settings = HudTheme.ls_metric(HudTheme.C_RED, HudTheme.FS_HERO_NUM)
	_winner_payout_label.visible = true

# ─── Layout — toast ─────────────────────────────────────────────────────────

func _build_toast() -> Control:
	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	anchor.offset_left = -200
	anchor.offset_right = 200
	anchor.offset_top = -176
	anchor.offset_bottom = -140
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_anchor = anchor

	_toast_card = PanelContainer.new()
	_toast_card.add_theme_stylebox_override("panel", HudTheme.sb_toast(HudTheme.TOAST_INFO))
	_toast_card.set_anchors_preset(Control.PRESET_FULL_RECT)
	_toast_card.modulate = Color(1, 1, 1, 0)
	_toast_card.visible = false
	anchor.add_child(_toast_card)

	_toast_label = Label.new()
	_toast_label.text = ""
	_toast_label.label_settings = HudTheme.ls_caption(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_TEXT)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast_card.add_child(_toast_label)

	return anchor

func _show_toast(message: String, toast_type: int = HudTheme.TOAST_INFO) -> void:
	_toast_label.text = message
	_toast_card.add_theme_stylebox_override("panel", HudTheme.sb_toast(toast_type))
	_toast_card.visible = true
	_toast_timer = 3.5
	# Pop-in tween.
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_card.modulate = Color(1, 1, 1, 0)
	_toast_card.scale = Vector2(0.95, 0.95)
	_toast_card.pivot_offset = _toast_card.size * 0.5
	var t := create_tween()
	t.set_parallel(true)
	t.set_ease(Tween.EASE_OUT)
	t.set_trans(Tween.TRANS_CUBIC)
	t.tween_property(_toast_card, "modulate:a", 1.0, HudTheme.ANIM_FAST)
	t.tween_property(_toast_card, "scale", Vector2(1.0, 1.0), HudTheme.ANIM_FAST)
	_toast_tween = t

func _dismiss_toast() -> void:
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	var t := create_tween()
	t.set_ease(Tween.EASE_IN)
	t.tween_property(_toast_card, "modulate:a", 0.0, HudTheme.ANIM_FAST)
	t.tween_callback(func() -> void:
		_toast_card.visible = false
	)
	_toast_tween = t

# ─── Phase ──────────────────────────────────────────────────────────────────

func _apply_phase(phase: String) -> void:
	_current_phase = phase
	# Translate the phase via i18n so the pill matches the current locale.
	var phase_key := "hud.phase.waiting"
	match phase:
		PHASE_RACING:   phase_key = "hud.phase.racing"
		PHASE_FINISHED: phase_key = "hud.phase.finished"
	_phase_pill_label.text = HudI18n.t(phase_key)
	_phase_pill_label.set_meta("phase_key", phase_key)
	_phase_pill.add_theme_stylebox_override("panel", HudTheme.sb_phase_pill(phase))
	# LIVE dot only meaningful in RACING.
	_live_dot.visible = (phase == PHASE_RACING)
	# Phase pill text color matches state — except FINISHED which uses
	# operator accent (gold by default, could be operator-overridden).
	var phase_col: Color = HudTheme.phase_color(phase)
	if phase == PHASE_FINISHED:
		phase_col = HudTheme.accent()
	_phase_pill_label.label_settings = HudTheme.ls_label_caps(phase_col, HudTheme.FS_LABEL)
	# Hide podium during WAITING (no race yet); show in RACING/FINISHED.
	if _podium_box != null and phase == PHASE_WAITING:
		_podium_box.visible = false

# ─── Balance ────────────────────────────────────────────────────────────────

func _update_balance_display() -> void:
	if _balance_amount_label != null:
		_balance_amount_label.text = HudTheme.format_money(_balance)

# ─── Operator branding refresh ──────────────────────────────────────────────
# Called from apply_operator_theme(). Re-styles only the widgets that
# embed the accent colour or the brand identity. Other widgets (timing
# tower rows, etc.) re-style themselves on the next update_standings tick.

func _refresh_branded_widgets() -> void:
	# Brand mark fill — accent.
	if _brand_mark != null:
		_brand_mark.add_theme_stylebox_override("panel",
			HudTheme.sb_panel(HudTheme.accent(), HudTheme.accent(), 8, 0))
	# Brand mark glyph vs operator logo — visibility flip.
	var logo := HudTheme.brand_logo()
	if _brand_logo_tex != null:
		_brand_logo_tex.texture = logo
		_brand_logo_tex.visible = (logo != null)
	if _brand_glyph != null:
		_brand_glyph.visible = (logo == null)
	# Brand label text.
	if _brand_label != null:
		_brand_label.text = HudTheme.brand_text()
	# Standings header colour.
	if _timing_tower_header != null:
		_timing_tower_header.label_settings = HudTheme.ls_label_caps(
			HudTheme.accent(), HudTheme.FS_LABEL)
	# Bet CTA stylebox set.
	if _bet_cta != null:
		_bet_cta.add_theme_stylebox_override("normal",
			HudTheme.sb_button_primary(HudTheme.accent()))
		_bet_cta.add_theme_stylebox_override("hover",
			HudTheme.sb_button_primary(HudTheme.accent().lightened(0.10)))
		_bet_cta.add_theme_stylebox_override("pressed",
			HudTheme.sb_button_primary(HudTheme.accent().darkened(0.10)))
		_bet_cta.add_theme_stylebox_override("focus",
			HudTheme.sb_button_primary(HudTheme.accent()))
	# Race progress bar fill.
	if _race_progress_bar != null:
		var pb_fill := StyleBoxFlat.new()
		pb_fill.bg_color = HudTheme.accent()
		pb_fill.set_corner_radius_all(2)
		_race_progress_bar.add_theme_stylebox_override("fill", pb_fill)
	# Winner caption colour.
	if _winner_caption_label != null:
		_winner_caption_label.label_settings = HudTheme.ls_label_caps(
			HudTheme.accent(), HudTheme.FS_TITLE)

# ─── Localised label refresh ────────────────────────────────────────────────
# Called from set_lang() and apply_operator_theme(). Walks the labels
# tagged with `i18n_key` metadata and re-applies the localised text.
# Works for labels created in the build phase only; dynamic strings
# (countdown, podium ranks, etc.) re-localise themselves on next tick.

func _refresh_localised_labels() -> void:
	# Top bar — phase pill (re-render through _apply_phase to refresh both
	# styling and meta) and balance caption + currency.
	if _phase_pill_label != null:
		_apply_phase(_current_phase)
	if _balance_caption != null:
		_balance_caption.text = HudI18n.t("hud.balance.caption")
	if _balance_currency_label != null:
		_balance_currency_label.text = HudI18n.t("hud.balance.currency")
	# Track name — needs the i18n_key stored at set_track_name() time.
	if _track_name_label != null and _track_name_label.has_meta("i18n_key"):
		var k := String(_track_name_label.get_meta("i18n_key"))
		if k != "":
			_track_name_label.text = HudI18n.t(k)
	# Standings header.
	if _timing_tower_header != null:
		_timing_tower_header.text = HudI18n.t("hud.standings.header")
	if _timing_tower_count != null:
		_update_timing_tower_count()
	# Timer caption + bets-locked pill.
	if _timer_caption != null:
		_timer_caption.text = HudI18n.t("hud.timer.caption")
	# Walk ALL children of the bet panel and root + winner modal looking
	# for `i18n_key` metadata. Cheap — a few dozen labels.
	_relocalise_recursive(self)

func _relocalise_recursive(node: Node) -> void:
	if node is Label and node.has_meta("i18n_key"):
		var k := String(node.get_meta("i18n_key"))
		if k != "":
			(node as Label).text = HudI18n.t(k)
	elif node is Button and node.has_meta("i18n_key"):
		var k := String(node.get_meta("i18n_key"))
		if k != "":
			(node as Button).text = HudI18n.t(k)
	for child in node.get_children():
		_relocalise_recursive(child)

# ─── Responsive layout ──────────────────────────────────────────────────────
# Called from _process() once when the viewport crosses BREAKPOINT_MOBILE.
# Switches between landscape (default) and portrait/mobile layouts by
# repositioning anchors and toggling visibility of the heavier widgets.

func _apply_responsive_layout() -> void:
	if _is_mobile:
		_apply_mobile_layout()
	else:
		_apply_desktop_layout()

func _apply_mobile_layout() -> void:
	# Top bar — collapse: hide podium ribbon and brand subtitle (track name
	# stays visible via track_name_label which is the most important label).
	if _podium_box != null:
		_podium_box.visible = false
	if _brand_label != null:
		_brand_label.visible = false
	# Timing tower — reduce width and dock to right edge.
	if _timing_tower != null:
		_timing_tower.offset_left = -200
		_timing_tower.offset_right = -8
		_timing_tower.offset_top = 76
		_timing_tower.offset_bottom = -200
	# Bet panel — full-width bottom sheet so finger taps on chips work.
	if _bet_panel != null:
		_bet_panel.offset_left = 8
		_bet_panel.offset_right = -8
		_bet_panel.offset_top = -440
		_bet_panel.offset_bottom = -100
	# Timer card — narrower (mobile screens ~360-414 px wide).
	if _timer_card != null:
		_timer_card.offset_left = -100
		_timer_card.offset_right = 100
		_timer_card.offset_top = -100
		_timer_card.offset_bottom = -16

func _apply_desktop_layout() -> void:
	# Restore the default landscape positions set in _build_*().
	if _podium_box != null and _current_phase != PHASE_WAITING:
		_podium_box.visible = true
	if _brand_label != null:
		_brand_label.visible = true
	if _timing_tower != null:
		_timing_tower.offset_left = -300
		_timing_tower.offset_right = -16
		_timing_tower.offset_top = 80
		_timing_tower.offset_bottom = -180
	if _bet_panel != null:
		_bet_panel.offset_left = -290
		_bet_panel.offset_right = 290
		_bet_panel.offset_top = -380
		_bet_panel.offset_bottom = -150
	if _timer_card != null:
		_timer_card.offset_left = -130
		_timer_card.offset_right = 130
		_timer_card.offset_top = -130
		_timer_card.offset_bottom = -32
