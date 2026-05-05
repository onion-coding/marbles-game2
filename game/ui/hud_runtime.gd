class_name HudRuntime
extends Object

# Runtime behaviour for the HUD: process-loop logic, standings tween,
# bet-panel interaction, pickup-badge polling, branding refresh,
# i18n refresh, responsive layout, toast, payout display.
#
# Instantiated by HUD in _ready(). Holds a back-reference to the HUD
# so it can read/write member variables and call create_tween().
# The HUD calls process_tick(delta) from its own _process().

var _hud: HUD  # back-reference, set by HUD after init

# ─── Persistence state ───────────────────────────────────────────────────────

const _STATS_SCHEMA_VERSION := 1
const _STATS_PATH           := "user://player_stats.json"
const _ROUND_HISTORY_CAP    := 50
const _ROUND_HISTORY_VISIBLE := 8

var _player_id:         String  = ""
var _persist_disabled:  bool    = false
var _stat_total_wagered: float  = 0.0
var _stat_total_won:     float  = 0.0
var _stat_rounds_played: int    = 0
var _stat_rounds_won:    int    = 0
var _round_history:      Array  = []   # Array of {track, stake, payout, won}

# ─── Init ────────────────────────────────────────────────────────────────────

func init(hud: HUD) -> void:
	_hud = hud

# ─── Process tick (called from HUD._process) ─────────────────────────────────

func process_tick(delta: float) -> void:
	_tick_toast(delta)
	_tick_bet_countdown(delta)
	_tick_next_round_countdown(delta)
	_tick_finish_settle(delta)
	_tick_live_dot()
	_tick_responsive()
	_tick_pickup_badges(delta)

# Counts down the post-finish settle window. While active, the FinishersList
# panel's countdown label shows seconds remaining. On expiry, the HUD's
# stashed winner payload is revealed via finish_settle_complete() (which
# hides the panel and shows the winner modal).
func _tick_finish_settle(delta: float) -> void:
	if not _hud._finish_settle_active:
		return
	_hud._finish_settle_remaining -= delta
	if _hud._finish_settle_remaining <= 0.0:
		_hud._finish_settle_remaining = 0.0
		_hud.finish_settle_complete()
		return
	# Update the seconds-remaining label in the FinishersList header.
	if _hud._finishers_countdown != null:
		_hud._finishers_countdown.text = "%ds" % int(ceil(_hud._finish_settle_remaining))
	# Pulse colour amber → red in the last 3s for emphasis.
	if _hud._finishers_countdown != null and _hud._finish_settle_remaining < 3.0:
		var pulse: float = 0.5 + 0.5 * sin(float(Engine.get_frames_drawn()) * 0.18)
		var c: Color = HudTheme.C_AMBER.lerp(HudTheme.C_RED, pulse)
		_hud._finishers_countdown.label_settings = HudTheme.ls_label_caps(c, HudTheme.FS_TINY)

func _tick_toast(delta: float) -> void:
	if _hud._toast_timer > 0.0:
		_hud._toast_timer -= delta
		if _hud._toast_timer <= 0.0:
			_dismiss_toast()

func _tick_bet_countdown(delta: float) -> void:
	if not _hud._bet_countdown_active:
		return
	_hud._bet_countdown_remaining -= delta
	if _hud._bet_countdown_remaining <= 0.0:
		_hud._bet_countdown_remaining = 0.0
		_hud._bet_countdown_active = false
		_hud._bet_countdown_label.text = HudI18n.t("hud.bet.countdown.locked")
		_hud._bet_countdown_label.label_settings = HudTheme.ls_label_caps(HudTheme.C_AMBER)
		_hud._bet_cta.disabled = true
	else:
		_hud._bet_countdown_label.text = HudI18n.t("hud.bet.countdown.starts_in") % _hud._bet_countdown_remaining
		if _hud._bet_countdown_remaining < 3.0:
			var pulse: float = 0.5 + 0.5 * sin(float(Engine.get_frames_drawn()) * 0.18)
			var c: Color = HudTheme.C_AMBER.lerp(HudTheme.C_RED, pulse)
			_hud._bet_countdown_label.label_settings = HudTheme.ls_label_caps(c)
		else:
			_hud._bet_countdown_label.label_settings = HudTheme.ls_label_caps(HudTheme.C_GREEN)

func _tick_next_round_countdown(delta: float) -> void:
	if not _hud._next_round_countdown_active:
		return
	_hud._next_round_countdown_remaining -= delta
	if _hud._next_round_countdown_remaining <= 0.0:
		_hud._next_round_countdown_remaining = 0.0
		_hud._next_round_countdown_active = false
		if _hud._winner_next_round_label != null:
			_hud._winner_next_round_label.text = HudI18n.t("hud.winner.starting")
	else:
		if _hud._winner_next_round_label != null:
			_hud._winner_next_round_label.text = HudI18n.t("hud.winner.next_round_in") % _hud._next_round_countdown_remaining

func _tick_live_dot() -> void:
	if _hud._current_phase == HUD.PHASE_RACING and _hud._live_dot != null:
		var alpha: float = 0.55 + 0.45 * absf(sin(float(Time.get_ticks_msec()) * 0.004))
		_hud._live_dot.modulate = Color(1, 1, 1, alpha)

func _tick_responsive() -> void:
	var vp := _hud.get_viewport()
	if vp == null:
		return
	var w: float = vp.get_visible_rect().size.x
	var should_be_mobile: bool = (w > 0.0 and w < float(HUD.BREAKPOINT_MOBILE))
	if should_be_mobile != _hud._is_mobile:
		_hud._is_mobile = should_be_mobile
		apply_responsive_layout()

func _tick_pickup_badges(delta: float) -> void:
	if _hud._current_phase != HUD.PHASE_RACING or _hud._track_node == null:
		return
	_hud._pickup_poll_timer -= delta
	if _hud._pickup_poll_timer <= 0.0:
		_hud._pickup_poll_timer = HUD.PICKUP_POLL_INTERVAL
		_poll_pickup_badges()

# ─── Standings rebuild ───────────────────────────────────────────────────────

# Apply rank changes — tween each row's y position smoothly.
func apply_standings(ranked: Array) -> void:
	for rank in range(ranked.size()):
		var idx: int = ranked[rank]["idx"]
		if not _hud._rows_by_index.has(idx):
			continue
		var entry: Dictionary = _hud._rows_by_index[idx]
		var prev_rank: int = entry["current_rank"]
		if prev_rank == rank:
			continue
		entry["current_rank"] = rank
		var new_y := float(rank) * float(HUD.TT_ROW_PITCH)
		entry["target_y"] = new_y
		apply_row_rank_styling(entry["row"] as Control, rank)
		var old_tween: Tween = entry.get("tween")
		if old_tween != null and old_tween.is_valid():
			old_tween.kill()
		var t := _hud.create_tween()
		t.set_ease(Tween.EASE_OUT)
		t.set_trans(Tween.TRANS_CUBIC)
		t.set_parallel(true)
		t.tween_property(entry["row"], "offset_top", new_y, HudTheme.ANIM_REORDER)
		t.tween_property(entry["row"], "offset_bottom", new_y + float(HUD.TT_ROW_H), HudTheme.ANIM_REORDER)
		entry["tween"] = t

	# Re-apply follow marker (rank-styling may have overwritten the row stylebox).
	if _hud._following_index >= 0 and _hud._rows_by_index.has(_hud._following_index):
		apply_following_marker(_hud._following_index, true)

	_update_podium_chips(ranked)

func _update_podium_chips(ranked: Array) -> void:
	if _hud._podium_box == null:
		return
	if _hud._is_mobile:
		_hud._podium_box.visible = false
		return
	_hud._podium_box.visible = (_hud._current_phase != HUD.PHASE_WAITING) and (ranked.size() >= 3)
	if not _hud._podium_box.visible:
		return
	for rank in range(mini(3, mini(_hud._podium_chips.size(), ranked.size()))):
		var idx: int = int(ranked[rank]["idx"])
		if idx < 0 or idx >= _hud._marble_meta.size():
			continue
		var meta: Dictionary = _hud._marble_meta[idx]
		var chip: Control = _hud._podium_chips[rank]
		var color_chip := chip.find_child("ColorChip", true, false) as PanelContainer
		if color_chip != null:
			var sb: StyleBoxFlat = color_chip.get_theme_stylebox("panel") as StyleBoxFlat
			if sb != null:
				sb.bg_color = meta["color"]
		var id_label := chip.find_child("IdLabel", true, false) as Label
		if id_label != null:
			id_label.text = HudTheme.short_marble_name(meta["name"])

# ─── Row styling helpers ─────────────────────────────────────────────────────

func apply_row_rank_styling(row: Control, rank: int) -> void:
	var sb_normal: StyleBoxFlat
	var rank_color: Color
	var id_color: Color
	if rank == 0:
		var acc: Color = HudTheme.accent()
		sb_normal = HudTheme.sb_row(Color(acc.r, acc.g, acc.b, 0.16), acc)
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
	var rank_label := row.find_child("RankLabel", true, false) as Label
	if rank_label != null:
		rank_label.text = "%02d" % (rank + 1)
		rank_label.label_settings = HudTheme.ls_metric(rank_color, HudTheme.FS_TEXT)
	var id_label := row.find_child("IdLabel", true, false) as Label
	if id_label != null:
		id_label.label_settings = HudTheme.ls_caption(id_color, HudTheme.FS_TEXT)

func apply_following_marker(orig_idx: int, active: bool) -> void:
	if not _hud._rows_by_index.has(orig_idx):
		return
	var entry: Dictionary = _hud._rows_by_index[orig_idx]
	var row: Control = entry["row"]
	if active:
		var sb: StyleBoxFlat = (row.get_theme_stylebox("normal") as StyleBoxFlat).duplicate()
		sb.border_color = HudTheme.C_CYAN
		sb.border_width_left = 4
		row.add_theme_stylebox_override("normal",   sb)
		row.add_theme_stylebox_override("disabled", sb)
		row.add_theme_stylebox_override("focus",    sb)
	else:
		apply_row_rank_styling(row, int(entry["current_rank"]))

# ─── Pickup badge polling ────────────────────────────────────────────────────

func _poll_pickup_badges() -> void:
	if _hud._track_node == null or not is_instance_valid(_hud._track_node):
		return
	var tier_for: Dictionary = {}
	_walk_pickup_zones(_hud._track_node, tier_for)
	for orig_idx in tier_for:
		if not _hud._rows_by_index.has(orig_idx):
			continue
		var tier: int = int(tier_for[orig_idx])
		var entry: Dictionary = _hud._rows_by_index[orig_idx]
		var row: Control = entry["row"]
		var badge := row.find_child("PickupBadge", true, false) as PanelContainer
		if badge == null:
			continue
		var badge_lbl := badge.find_child("PickupBadgeLabel", true, false) as Label
		var prev: Dictionary = _hud._pickup_state.get(orig_idx, {"tier": 0})
		if int(prev.get("tier", 0)) == tier:
			continue
		_hud._pickup_state[orig_idx] = {"tier": tier}
		if tier == 2:
			badge.add_theme_stylebox_override("panel",
				HudTheme.sb_pill(Color(HudTheme.C_GOLD.r, HudTheme.C_GOLD.g, HudTheme.C_GOLD.b, 0.28)))
			if badge_lbl != null:
				badge_lbl.text = HudI18n.t("hud.pickup.tier2_badge")
				badge_lbl.label_settings = HudTheme.ls_label_caps(HudTheme.C_GOLD, HudTheme.FS_TINY)
		else:
			badge.add_theme_stylebox_override("panel",
				HudTheme.sb_pill(Color(HudTheme.C_GREEN.r, HudTheme.C_GREEN.g, HudTheme.C_GREEN.b, 0.25)))
			if badge_lbl != null:
				badge_lbl.text = HudI18n.t("hud.pickup.tier1_badge")
				badge_lbl.label_settings = HudTheme.ls_label_caps(HudTheme.C_GREEN, HudTheme.FS_TINY)
		badge.visible = true

func _walk_pickup_zones(node: Node, result: Dictionary) -> void:
	if node.has_method("get_collected") and node.has_method("get_marble_index") \
			and node.has_method("get_tier"):
		if node.get_collected():
			var marble_idx: int = node.get_marble_index()
			var tier: int       = node.get_tier()
			var prev_tier: int = int(result.get(marble_idx, 0))
			if tier > prev_tier:
				result[marble_idx] = tier
	for child in node.get_children():
		_walk_pickup_zones(child, result)

# ─── Bet panel interaction ───────────────────────────────────────────────────

func on_preset_amount(val: float, source_btn: Button) -> void:
	_hud._bet_amount = val
	_hud._bet_stake_label.text = HudTheme.format_money(val)
	for b in _hud._bet_chip_buttons:
		HudLayout.apply_chip_style(b, b == source_btn)
	_validate_bet_button()
	_update_potential_payout()

func on_adjust_amount(delta: float) -> void:
	_hud._bet_amount = max(1.0, _hud._bet_amount + delta)
	_hud._bet_stake_label.text = HudTheme.format_money(_hud._bet_amount)
	for b in _hud._bet_chip_buttons:
		HudLayout.apply_chip_style(b, false)
	_validate_bet_button()
	_update_potential_payout()

func on_marble_chip_pressed(orig_idx: int, _color: Color) -> void:
	for i in range(_hud._marble_meta.size()):
		if int(_hud._marble_meta[i]["original_index"]) == orig_idx:
			_hud._selected_marble = i
			break
	for i in range(_hud._bet_marble_chips.size()):
		if not is_instance_valid(_hud._bet_marble_chips[i]):
			continue
		var meta_color: Color = _hud._marble_meta[i]["color"]
		HudLayout.apply_marble_chip_style(_hud._bet_marble_chips[i], meta_color, i == _hud._selected_marble)
	_validate_bet_button()
	_update_potential_payout()

func on_place_bet_pressed() -> void:
	if _hud._selected_marble < 0 or _hud._bet_amount <= 0.0:
		return
	if _hud._bet_amount > _hud._balance:
		show_toast(HudI18n.t("hud.bet.insufficient"), HudTheme.TOAST_ERROR)
		return
	var original_idx: int = _hud._marble_meta[_hud._selected_marble]["original_index"]
	_hud.bet_requested.emit(original_idx, _hud._bet_amount)

func _validate_bet_button() -> void:
	if not _hud._rgs_mode:
		_hud._bet_cta.disabled = true
		_hud._bet_cta.tooltip_text = "Betting requires RGS mode (--rgs=<url>)"
		return
	var valid := _hud._selected_marble >= 0 and _hud._bet_amount > 0.0 \
		and _hud._bet_amount <= _hud._balance
	_hud._bet_cta.disabled = not valid
	if valid:
		_hud._bet_cta.tooltip_text = ""

func _update_potential_payout() -> void:
	if _hud._selected_marble < 0:
		_refresh_payout_matrix_values(0.0)
		return
	_refresh_payout_matrix_values(_hud._bet_amount)

func _refresh_payout_matrix_values(stake: float) -> void:
	if _hud._bet_panel_card == null:
		return
	var row_specs := [
		{"name": "Row1st", "mult": HUD.PAYOUT_1ST},
		{"name": "Row2nd", "mult": HUD.PAYOUT_2ND},
		{"name": "Row3rd", "mult": HUD.PAYOUT_3RD},
		{"name": "RowT1",  "mult": HUD.PAYOUT_TIER1_MULT},
		{"name": "RowT2",  "mult": HUD.PAYOUT_TIER2_MULT},
		{"name": "RowJP",  "mult": HUD.PAYOUT_JACKPOT},
	]
	for spec in row_specs:
		var r_hb := _hud._bet_panel_card.find_child(String(spec["name"]), true, false)
		if r_hb == null:
			continue
		var val_lbl := r_hb.find_child("ValLabel", true, false) as Label
		if val_lbl == null:
			continue
		if stake <= 0.0:
			val_lbl.text = "= —"
		else:
			var payout := stake * float(spec["mult"])
			val_lbl.text = "= €%s" % HudTheme.format_money(payout)

func refresh_bets_list() -> void:
	for c in _hud._bets_list.get_children():
		c.queue_free()
	for b in _hud._placed_bets:
		var marble_idx: int = int(b.get("marble_idx", 0))
		var amount: float = float(b.get("amount", 0.0))
		var row := PanelContainer.new()
		row.add_theme_stylebox_override("panel",
			HudTheme.sb_panel(Color(1, 1, 1, 0.04), HudTheme.C_BORDER_DIM, 8, 1))
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 8)
		row.add_child(hb)
		var color := Color(0.6, 0.6, 0.6)
		for m in _hud._marble_meta:
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
		_hud._bets_list.add_child(row)

# ─── Toast ───────────────────────────────────────────────────────────────────

func show_toast(message: String, toast_type: int = HudTheme.TOAST_INFO) -> void:
	_hud._toast_label.text = message
	_hud._toast_card.add_theme_stylebox_override("panel", HudTheme.sb_toast(toast_type))
	_hud._toast_card.visible = true
	_hud._toast_timer = 3.5
	if _hud._toast_tween != null and _hud._toast_tween.is_valid():
		_hud._toast_tween.kill()
	_hud._toast_card.modulate = Color(1, 1, 1, 0)
	_hud._toast_card.scale = Vector2(0.95, 0.95)
	_hud._toast_card.pivot_offset = _hud._toast_card.size * 0.5
	var t := _hud.create_tween()
	t.set_parallel(true)
	t.set_ease(Tween.EASE_OUT)
	t.set_trans(Tween.TRANS_CUBIC)
	t.tween_property(_hud._toast_card, "modulate:a", 1.0, HudTheme.ANIM_FAST)
	t.tween_property(_hud._toast_card, "scale", Vector2(1.0, 1.0), HudTheme.ANIM_FAST)
	_hud._toast_tween = t

func _dismiss_toast() -> void:
	if _hud._toast_tween != null and _hud._toast_tween.is_valid():
		_hud._toast_tween.kill()
	var t := _hud.create_tween()
	t.set_ease(Tween.EASE_IN)
	t.tween_property(_hud._toast_card, "modulate:a", 0.0, HudTheme.ANIM_FAST)
	t.tween_callback(func() -> void:
		_hud._toast_card.visible = false
	)
	_hud._toast_tween = t

# ─── Winner modal ────────────────────────────────────────────────────────────

func show_winner_modal() -> void:
	_hud._winner_modal.visible = true
	_hud._winner_modal_card.modulate = Color(1, 1, 1, 0)
	_hud._winner_modal_card.scale = Vector2(0.92, 0.92)
	_hud._winner_modal_card.pivot_offset = _hud._winner_modal_card.size * 0.5
	var t := _hud.create_tween()
	t.set_parallel(true)
	t.set_ease(Tween.EASE_OUT)
	t.set_trans(Tween.TRANS_CUBIC)
	t.tween_property(_hud._winner_modal_card, "modulate:a", 1.0, HudTheme.ANIM_NORMAL)
	t.tween_property(_hud._winner_modal_card, "scale", Vector2(1.0, 1.0), HudTheme.ANIM_NORMAL)

func populate_podium() -> void:
	if _hud._last_ranked.is_empty() or _hud._marble_meta.is_empty():
		return
	var slots := [
		{"name_lbl": _hud._winner_name_label, "pillar": _hud._podium_pillar_p1},
		{"name_lbl": _hud._podium_name_p2,    "pillar": _hud._podium_pillar_p2},
		{"name_lbl": _hud._podium_name_p3,    "pillar": _hud._podium_pillar_p3},
	]
	for r in range(slots.size()):
		var slot: Dictionary = slots[r]
		var name_lbl: Label = slot["name_lbl"]
		var pillar: PanelContainer = slot["pillar"]
		if name_lbl == null or pillar == null:
			continue
		if r >= _hud._last_ranked.size():
			name_lbl.text = "—"
			continue
		var idx: int = int(_hud._last_ranked[r]["idx"])
		if idx < 0 or idx >= _hud._marble_meta.size():
			continue
		var meta: Dictionary = _hud._marble_meta[idx]
		var marble_color: Color = meta["color"]
		name_lbl.text = String(meta["name"]).to_upper()
		var ls := LabelSettings.new()
		ls.font_color = marble_color
		ls.font_size = HudTheme.FS_HERO_NUM if r == 0 else HudTheme.FS_TITLE
		name_lbl.label_settings = ls
		var sb: StyleBoxFlat = (pillar.get_theme_stylebox("panel") as StyleBoxFlat).duplicate()
		sb.bg_color = Color(marble_color.r, marble_color.g, marble_color.b, 0.42)
		pillar.add_theme_stylebox_override("panel", sb)

func populate_final_table() -> void:
	if _hud._final_standings_list == null:
		return
	for c in _hud._final_standings_list.get_children():
		c.queue_free()
	var max_rows: int = mini(_hud._last_ranked.size(), 20)
	var entries_count: int = max(0, max_rows - 3)
	if entries_count == 0:
		return
	var per_column: int = (entries_count + 1) / 2

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 28)
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var col1 := VBoxContainer.new()
	col1.add_theme_constant_override("separation", 4)
	col1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(col1)

	var col2 := VBoxContainer.new()
	col2.add_theme_constant_override("separation", 4)
	col2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(col2)

	for r in range(3, max_rows):
		var entry: Dictionary = _hud._last_ranked[r]
		var idx: int = int(entry["idx"])
		if idx < 0 or idx >= _hud._marble_meta.size():
			continue
		var meta: Dictionary = _hud._marble_meta[idx]
		var row := HudLayout.make_final_table_row(r + 1, String(meta["name"]), meta["color"])
		if (r - 3) < per_column:
			col1.add_child(row)
		else:
			col2.add_child(row)

	_hud._final_standings_list.add_child(hb)

# ─── Payout helpers ──────────────────────────────────────────────────────────

func apply_local_payout_summary(winner_name: String) -> void:
	var winner_idx := -1
	var trimmed := winner_name.trim_prefix("Marble_")
	if trimmed.is_valid_int():
		winner_idx = int(trimmed)
	var total_payout := 0.0
	var total_wagered := 0.0
	for b in _hud._placed_bets:
		total_wagered += float(b["amount"])
		if int(b["marble_idx"]) == winner_idx:
			total_payout += float(b.get("expected_payout_if_win", b["amount"] * HUD.PAYOUT_MULT))
	if total_payout > 0.0:
		_hud._winner_payout_label.text = "+%s" % HudTheme.format_money(total_payout)
		_hud._winner_payout_label.label_settings = HudTheme.ls_metric(HudTheme.C_GREEN, HudTheme.FS_HERO_NUM)
	else:
		_hud._winner_payout_label.text = HudTheme.format_money(-total_wagered)
		_hud._winner_payout_label.label_settings = HudTheme.ls_metric(HudTheme.C_RED, HudTheme.FS_HERO_NUM)
	_hud._winner_payout_label.visible = true

func format_winner_breakdown(bd: Dictionary) -> String:
	var rank: int           = int(bd.get("rank", 1))
	var podium_mult: float  = float(bd.get("podium_mult", HUD.PAYOUT_1ST))
	var pickup_tier: int    = int(bd.get("pickup_tier", 0))
	var pickup_mult: float  = float(bd.get("pickup_mult", 1.0))
	var jackpot: bool       = bool(bd.get("jackpot", false))
	var total_mult: float   = float(bd.get("total_mult", podium_mult))
	var stake: float        = float(bd.get("stake", 0.0))
	var total_payout: float = float(bd.get("total_payout", 0.0))
	var _unused_pickup_mult: float = pickup_mult  # used only via tier check

	var rank_str: String
	match rank:
		1: rank_str = HudI18n.t("hud.bet.payout_1st")
		2: rank_str = HudI18n.t("hud.bet.payout_2nd")
		3: rank_str = HudI18n.t("hud.bet.payout_3rd")
		_: rank_str = "%d" % rank

	var parts: Array[String] = []
	if jackpot:
		parts.append("%s + T2 %s" % [rank_str, HudI18n.t("hud.winner.jackpot_trigger")])
	else:
		parts.append("%s (%s×)" % [rank_str, _format_compact_float(podium_mult)])
		if pickup_tier == 1:
			parts.append(HudI18n.t("hud.winner.pickup_bonus") % "2")
		elif pickup_tier == 2:
			parts.append(HudI18n.t("hud.winner.pickup_bonus") % "3")

	var left := " ".join(PackedStringArray(parts))
	var right := ""
	if stake > 0.0 and total_payout > 0.0:
		right = " = " + _format_compact_float(total_mult) + "× × €" + HudTheme.format_money(stake) \
			+ " = €" + HudTheme.format_money(total_payout)
	elif total_mult > 0.0:
		right = " = " + _format_compact_float(total_mult) + "×"
	return left + right

func _format_compact_float(v: float) -> String:
	if v == floor(v):
		return "%.0f" % v
	return "%.1f" % v

# ─── Phase ───────────────────────────────────────────────────────────────────

func apply_phase(phase: String) -> void:
	_hud._current_phase = phase
	var phase_key := "hud.phase.waiting"
	match phase:
		HUD.PHASE_RACING:   phase_key = "hud.phase.racing"
		HUD.PHASE_FINISHED: phase_key = "hud.phase.finished"
	_hud._phase_pill_label.text = HudI18n.t(phase_key)
	_hud._phase_pill_label.set_meta("phase_key", phase_key)
	_hud._phase_pill.add_theme_stylebox_override("panel", HudTheme.sb_phase_pill(phase))
	_hud._live_dot.visible = (phase == HUD.PHASE_RACING)
	var phase_col: Color = HudTheme.phase_color(phase)
	if phase == HUD.PHASE_FINISHED:
		phase_col = HudTheme.accent()
	_hud._phase_pill_label.label_settings = HudTheme.ls_label_caps(phase_col, HudTheme.FS_LABEL)
	if _hud._podium_box != null and phase == HUD.PHASE_WAITING:
		_hud._podium_box.visible = false

# ─── Balance display ─────────────────────────────────────────────────────────

func update_balance_display() -> void:
	if _hud._balance_amount_label != null:
		_hud._balance_amount_label.text = HudTheme.format_money(_hud._balance)

# ─── Operator branding refresh ───────────────────────────────────────────────

func refresh_branded_widgets() -> void:
	if _hud._brand_mark != null:
		_hud._brand_mark.add_theme_stylebox_override("panel",
			HudTheme.sb_panel(HudTheme.accent(), HudTheme.accent(), 8, 0))
	var logo := HudTheme.brand_logo()
	if _hud._brand_logo_tex != null:
		_hud._brand_logo_tex.texture = logo
		_hud._brand_logo_tex.visible = (logo != null)
	if _hud._brand_glyph != null:
		_hud._brand_glyph.visible = (logo == null)
	if _hud._brand_label != null:
		_hud._brand_label.text = HudTheme.brand_text()
	if _hud._timing_tower_header != null:
		_hud._timing_tower_header.label_settings = HudTheme.ls_label_caps(
			HudTheme.accent(), HudTheme.FS_LABEL)
	if _hud._bet_cta != null:
		_hud._bet_cta.add_theme_stylebox_override("normal",
			HudTheme.sb_button_primary(HudTheme.accent()))
		_hud._bet_cta.add_theme_stylebox_override("hover",
			HudTheme.sb_button_primary(HudTheme.accent().lightened(0.10)))
		_hud._bet_cta.add_theme_stylebox_override("pressed",
			HudTheme.sb_button_primary(HudTheme.accent().darkened(0.10)))
		_hud._bet_cta.add_theme_stylebox_override("focus",
			HudTheme.sb_button_primary(HudTheme.accent()))
	if _hud._race_progress_bar != null:
		var pb_fill := StyleBoxFlat.new()
		pb_fill.bg_color = HudTheme.accent()
		pb_fill.set_corner_radius_all(2)
		_hud._race_progress_bar.add_theme_stylebox_override("fill", pb_fill)
	if _hud._winner_caption_label != null:
		_hud._winner_caption_label.label_settings = HudTheme.ls_label_caps(
			HudTheme.accent(), HudTheme.FS_TITLE)

# ─── Localised label refresh ─────────────────────────────────────────────────

func refresh_localised_labels() -> void:
	if _hud._phase_pill_label != null:
		apply_phase(_hud._current_phase)
	if _hud._balance_caption != null:
		_hud._balance_caption.text = HudI18n.t("hud.balance.caption")
	if _hud._balance_currency_label != null:
		_hud._balance_currency_label.text = HudI18n.t("hud.balance.currency")
	if _hud._track_name_label != null and _hud._track_name_label.has_meta("i18n_key"):
		var k := String(_hud._track_name_label.get_meta("i18n_key"))
		if k != "":
			_hud._track_name_label.text = HudI18n.t(k)
	if _hud._timing_tower_header != null:
		_hud._timing_tower_header.text = HudI18n.t("hud.standings.header")
	if _hud._timing_tower_count != null:
		_hud.update_timing_tower_count()
	if _hud._timer_caption != null:
		_hud._timer_caption.text = HudI18n.t("hud.timer.caption")
	_relocalise_recursive(_hud)

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

# ─── Responsive layout ───────────────────────────────────────────────────────

func apply_responsive_layout() -> void:
	if _hud._is_mobile:
		_apply_mobile_layout()
	else:
		_apply_desktop_layout()

func _apply_mobile_layout() -> void:
	if _hud._podium_box != null:
		_hud._podium_box.visible = false
	if _hud._brand_label != null:
		_hud._brand_label.visible = false
	if _hud._timing_tower != null:
		_hud._timing_tower.offset_left = -200
		_hud._timing_tower.offset_right = -8
		_hud._timing_tower.offset_top = 76
		_hud._timing_tower.offset_bottom = -200
	if _hud._bet_panel != null:
		_hud._bet_panel.offset_left = 8
		_hud._bet_panel.offset_right = -8
		_hud._bet_panel.offset_top = -440
		_hud._bet_panel.offset_bottom = -100
	if _hud._timer_card != null:
		_hud._timer_card.offset_left = -100
		_hud._timer_card.offset_right = 100
		_hud._timer_card.offset_top = -100
		_hud._timer_card.offset_bottom = -16

func _apply_desktop_layout() -> void:
	if _hud._podium_box != null and _hud._current_phase != HUD.PHASE_WAITING:
		_hud._podium_box.visible = true
	if _hud._brand_label != null:
		_hud._brand_label.visible = true
	if _hud._timing_tower != null:
		_hud._timing_tower.offset_left = -300
		_hud._timing_tower.offset_right = -16
		_hud._timing_tower.offset_top = 80
		_hud._timing_tower.offset_bottom = -180
	if _hud._bet_panel != null:
		_hud._bet_panel.offset_left = -290
		_hud._bet_panel.offset_right = 290
		_hud._bet_panel.offset_top = -380
		_hud._bet_panel.offset_bottom = -150
	if _hud._timer_card != null:
		_hud._timer_card.offset_left = -130
		_hud._timer_card.offset_right = 130
		_hud._timer_card.offset_top = -130
		_hud._timer_card.offset_bottom = -32

# ─── Session stats persistence ───────────────────────────────────────────────
#
# set_player_id() must be called before record_round_outcome() so that stats
# are loaded from / saved under the correct player bucket.
#
# Schema v1 (user://player_stats.json):
# {
#   "version": 1,
#   "players": {
#     "<player_id>": {
#       "total_wagered": float,
#       "total_won":     float,
#       "rounds_played": int,
#       "rounds_won":    int,
#       "round_history": [
#         {"track": String, "stake": float, "payout": float, "won": bool}, ...
#       ]
#     }
#   }
# }
# Errors: missing file / corrupt JSON / wrong version / wrong player → fresh
# start with push_warning; _persist_disabled if user:// is not writable.

func set_player_id(id: String) -> void:
	_player_id = id
	_runtime_load_stats()
	_refresh_stats_ui()

func record_round_outcome(outcome: Dictionary) -> void:
	# outcome keys: track_name (String), stake (float), payout (float), won (bool)
	var track:  String = String(outcome.get("track_name", ""))
	var stake:  float  = float(outcome.get("stake",  0.0))
	var payout: float  = float(outcome.get("payout", 0.0))
	var won:    bool   = bool(outcome.get("won",     false))

	_stat_total_wagered += stake
	_stat_total_won     += payout
	_stat_rounds_played += 1
	if won:
		_stat_rounds_won += 1

	_round_history.append({"track": track, "stake": stake, "payout": payout, "won": won})
	if _round_history.size() > _ROUND_HISTORY_CAP:
		_round_history.pop_front()

	_runtime_save_stats()
	_refresh_stats_ui()

func _runtime_load_stats() -> void:
	if _player_id.is_empty():
		return

	# Probe write access once.
	if not _persist_disabled:
		var probe := FileAccess.open(_STATS_PATH, FileAccess.READ_WRITE)
		if probe == null:
			var create_probe := FileAccess.open(_STATS_PATH, FileAccess.WRITE)
			if create_probe == null:
				push_warning("HudRuntime: user:// not writable — persistence disabled")
				_persist_disabled = true
				return
			create_probe = null   # close

	if not FileAccess.file_exists(_STATS_PATH):
		return   # fresh start, nothing to load

	var f := FileAccess.open(_STATS_PATH, FileAccess.READ)
	if f == null:
		push_warning("HudRuntime: cannot read %s — fresh start" % _STATS_PATH)
		return

	var raw := f.get_as_text()
	f = null   # close

	var parsed: Variant = JSON.parse_string(raw)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		push_warning("HudRuntime: player_stats.json is corrupt — fresh start")
		return

	var data := parsed as Dictionary
	if int(data.get("version", 0)) != _STATS_SCHEMA_VERSION:
		push_warning("HudRuntime: player_stats.json wrong version — fresh start")
		return

	var players: Variant = data.get("players")
	if players == null or typeof(players) != TYPE_DICTIONARY:
		push_warning("HudRuntime: player_stats.json missing 'players' — fresh start")
		return

	var pdict := players as Dictionary
	if not pdict.has(_player_id):
		return   # new player, fresh start

	var p: Dictionary = pdict[_player_id] as Dictionary
	_stat_total_wagered = float(p.get("total_wagered", 0.0))
	_stat_total_won     = float(p.get("total_won",     0.0))
	_stat_rounds_played = int(p.get("rounds_played",   0))
	_stat_rounds_won    = int(p.get("rounds_won",      0))
	var hist: Variant   = p.get("round_history")
	if hist != null and typeof(hist) == TYPE_ARRAY:
		_round_history = hist as Array
		# Cap in case the stored file grew beyond limit
		while _round_history.size() > _ROUND_HISTORY_CAP:
			_round_history.pop_front()

func _runtime_save_stats() -> void:
	if _persist_disabled or _player_id.is_empty():
		return

	# Read existing file so we don't clobber other player buckets.
	var existing: Dictionary = {}
	if FileAccess.file_exists(_STATS_PATH):
		var rf := FileAccess.open(_STATS_PATH, FileAccess.READ)
		if rf != null:
			var raw := rf.get_as_text()
			rf = null
			var parsed: Variant = JSON.parse_string(raw)
			if parsed != null and typeof(parsed) == TYPE_DICTIONARY:
				var d := parsed as Dictionary
				if int(d.get("version", 0)) == _STATS_SCHEMA_VERSION:
					var pl: Variant = d.get("players")
					if pl != null and typeof(pl) == TYPE_DICTIONARY:
						existing = pl as Dictionary

	existing[_player_id] = {
		"total_wagered": _stat_total_wagered,
		"total_won":     _stat_total_won,
		"rounds_played": _stat_rounds_played,
		"rounds_won":    _stat_rounds_won,
		"round_history": _round_history,
	}

	var payload := {"version": _STATS_SCHEMA_VERSION, "players": existing}
	var json_str := JSON.stringify(payload, "\t")

	var wf := FileAccess.open(_STATS_PATH, FileAccess.WRITE)
	if wf == null:
		push_warning("HudRuntime: cannot write %s — disabling persistence" % _STATS_PATH)
		_persist_disabled = true
		return
	wf.store_string(json_str)
	wf = null   # close (FileAccess closes on unreference)

func _refresh_stats_ui() -> void:
	if _hud._stat_wagered_label != null:
		_hud._stat_wagered_label.text = HudTheme.format_money(_stat_total_wagered)
	if _hud._stat_won_label != null:
		var net := _stat_total_won - _stat_total_wagered
		var won_color: Color = HudTheme.C_GREEN if _stat_total_won >= _stat_total_wagered \
			else HudTheme.C_TEXT_PRIMARY
		_hud._stat_won_label.text = HudTheme.format_money(_stat_total_won)
		_hud._stat_won_label.label_settings = HudTheme.ls_metric(won_color, HudTheme.FS_SMALL)
		if _hud._stat_netpl_label != null:
			var net_color: Color = HudTheme.C_GREEN if net >= 0.0 else HudTheme.C_RED
			var prefix := "+" if net >= 0.0 else ""
			_hud._stat_netpl_label.text = prefix + HudTheme.format_money(net)
			_hud._stat_netpl_label.label_settings = HudTheme.ls_metric(net_color, HudTheme.FS_SMALL)
	if _hud._stat_rounds_label != null:
		_hud._stat_rounds_label.text = "%d" % _stat_rounds_played
	if _hud._stat_winrate_label != null:
		if _stat_rounds_played > 0:
			var rate := float(_stat_rounds_won) / float(_stat_rounds_played) * 100.0
			_hud._stat_winrate_label.text = "%.1f%%" % rate
		else:
			_hud._stat_winrate_label.text = "—"

	_refresh_recent_rounds()

func _refresh_recent_rounds() -> void:
	if _hud._session_recent_list == null:
		return
	for c in _hud._session_recent_list.get_children():
		c.queue_free()
	var start: int = int(max(0, _round_history.size() - _ROUND_HISTORY_VISIBLE))
	for i in range(_round_history.size() - 1, start - 1, -1):
		var entry: Dictionary = _round_history[i] as Dictionary
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)

		var track_lbl := Label.new()
		var track_str := String(entry.get("track", "—"))
		track_lbl.text = track_str.left(10) if track_str.length() > 10 else track_str
		track_lbl.label_settings = HudTheme.ls_caption(HudTheme.C_TEXT_DIM, HudTheme.FS_TINY)
		track_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(track_lbl)

		var stake_lbl := Label.new()
		stake_lbl.text = HudTheme.format_money(float(entry.get("stake", 0.0)))
		stake_lbl.label_settings = HudTheme.ls_metric(HudTheme.C_TEXT_SECONDARY, HudTheme.FS_TINY)
		row.add_child(stake_lbl)

		var result_lbl := Label.new()
		var won: bool = bool(entry.get("won", false))
		var payout: float = float(entry.get("payout", 0.0))
		result_lbl.text = ("+%s" % HudTheme.format_money(payout)) if won \
			else ("-%s" % HudTheme.format_money(float(entry.get("stake", 0.0))))
		var res_color: Color = HudTheme.C_GREEN if won else HudTheme.C_RED
		result_lbl.label_settings = HudTheme.ls_metric(res_color, HudTheme.FS_TINY)
		row.add_child(result_lbl)

		_hud._session_recent_list.add_child(row)
