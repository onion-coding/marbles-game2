class_name HudLayout
extends Object

# Pure UI construction helpers for HUD.
#
# Every static function here builds a region of the HUD and writes the
# node references it creates into the `refs` Dictionary that HUD passes in.
# The functions return the top-level Control for that region so HUD can
# add_child() it in the right order.
#
# NO state lives here — this file is intentionally stateless. All styling
# is delegated to HudTheme, all localised strings to HudI18n.

# ─── Top broadcast bar ──────────────────────────────────────────────────────

static func build_top_bar(refs: Dictionary) -> Control:
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_left = 0
	bar.offset_top = 0
	bar.offset_right = 0
	bar.offset_bottom = 0
	bar.custom_minimum_size = Vector2(0, 64)
	bar.add_theme_stylebox_override("panel", HudTheme.sb_top_bar())
	refs["top_bar"] = bar

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 18)
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(hb)

	# ── Left cluster: brand + event ──────────────────────────────────────
	var brand_box := HBoxContainer.new()
	brand_box.add_theme_constant_override("separation", 10)
	hb.add_child(brand_box)

	# Brand mark — accent-coloured square containing either the "M" glyph
	# (default) or an operator-supplied logo TextureRect.
	var brand_mark := PanelContainer.new()
	brand_mark.custom_minimum_size = Vector2(38, 38)
	brand_mark.add_theme_stylebox_override("panel",
		HudTheme.sb_panel(HudTheme.accent(), HudTheme.accent(), 8, 0))
	refs["brand_mark"] = brand_mark

	var brand_glyph := Label.new()
	brand_glyph.text = "M"
	brand_glyph.label_settings = HudTheme.ls_title(HudTheme.C_TEXT_INVERSE, HudTheme.FS_TITLE)
	brand_glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	brand_glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	brand_mark.add_child(brand_glyph)
	refs["brand_glyph"] = brand_glyph

	var brand_logo_tex := TextureRect.new()
	brand_logo_tex.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	brand_logo_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	brand_logo_tex.visible = false
	brand_mark.add_child(brand_logo_tex)
	refs["brand_logo_tex"] = brand_logo_tex
	brand_box.add_child(brand_mark)

	var brand_text_v := VBoxContainer.new()
	brand_text_v.add_theme_constant_override("separation", 0)
	brand_box.add_child(brand_text_v)

	var brand_label := Label.new()
	brand_label.text = HudTheme.brand_text()
	brand_label.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_LABEL)
	brand_text_v.add_child(brand_label)
	refs["brand_label"] = brand_label

	var track_name_label := Label.new()
	track_name_label.text = ""
	track_name_label.label_settings = HudTheme.ls_title(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_TITLE)
	brand_text_v.add_child(track_name_label)
	refs["track_name_label"] = track_name_label

	# Vertical separator.
	hb.add_child(make_vertical_divider())

	# ── Center: phase pill + LIVE indicator + round ──────────────────────
	var center_box := HBoxContainer.new()
	center_box.add_theme_constant_override("separation", 10)
	center_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	hb.add_child(center_box)

	var phase_pill := PanelContainer.new()
	phase_pill.add_theme_stylebox_override("panel", HudTheme.sb_phase_pill("WAITING"))
	refs["phase_pill"] = phase_pill

	var phase_hb := HBoxContainer.new()
	phase_hb.add_theme_constant_override("separation", 6)
	phase_pill.add_child(phase_hb)

	var live_dot := Label.new()
	live_dot.text = "●"
	live_dot.label_settings = HudTheme.ls_caption(HudTheme.C_RED, HudTheme.FS_TEXT)
	phase_hb.add_child(live_dot)
	refs["live_dot"] = live_dot

	var phase_pill_label := Label.new()
	phase_pill_label.text = HudI18n.t("hud.phase.waiting")
	phase_pill_label.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_LABEL)
	phase_hb.add_child(phase_pill_label)
	refs["phase_pill_label"] = phase_pill_label
	center_box.add_child(phase_pill)

	var round_label := Label.new()
	round_label.text = ""
	round_label.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_LABEL)
	center_box.add_child(round_label)
	refs["round_label"] = round_label

	# Top-3 podium ribbon — three small chips after the round indicator.
	var podium_box := HBoxContainer.new()
	podium_box.add_theme_constant_override("separation", 6)
	podium_box.visible = false
	center_box.add_child(podium_box)
	refs["podium_box"] = podium_box

	var podium_chips: Array[Control] = []
	for rank in range(3):
		var chip := make_podium_chip(rank)
		podium_box.add_child(chip)
		podium_chips.append(chip)
	refs["podium_chips"] = podium_chips

	# Spacer pushes balance to the right.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(spacer)

	# ── Right cluster: balance ───────────────────────────────────────────
	var bal_panel := PanelContainer.new()
	bal_panel.add_theme_stylebox_override("panel",
		HudTheme.sb_panel(Color(0.05, 0.10, 0.18, 0.85), HudTheme.C_BORDER_BRIGHT, 10, 1))
	hb.add_child(bal_panel)

	var bal_hb := HBoxContainer.new()
	bal_hb.add_theme_constant_override("separation", 8)
	bal_panel.add_child(bal_hb)

	var bal_caption_v := VBoxContainer.new()
	bal_caption_v.add_theme_constant_override("separation", 0)

	var balance_caption := Label.new()
	balance_caption.text = HudI18n.t("hud.balance.caption")
	balance_caption.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_TINY)
	bal_caption_v.add_child(balance_caption)
	refs["balance_caption"] = balance_caption

	var bal_amount_hb := HBoxContainer.new()
	bal_amount_hb.add_theme_constant_override("separation", 4)
	bal_caption_v.add_child(bal_amount_hb)

	var balance_amount_label := Label.new()
	balance_amount_label.text = HudTheme.format_money(1250.00)
	balance_amount_label.label_settings = HudTheme.ls_metric(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_NUMBER_LARGE)
	bal_amount_hb.add_child(balance_amount_label)
	refs["balance_amount_label"] = balance_amount_label

	var balance_currency_label := Label.new()
	balance_currency_label.text = HudI18n.t("hud.balance.currency")
	balance_currency_label.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_TINY)
	bal_amount_hb.add_child(balance_currency_label)
	refs["balance_currency_label"] = balance_currency_label

	bal_hb.add_child(bal_caption_v)

	return bar

# Build a single podium chip (rank 0=1st, 1=2nd, 2=3rd). Initially empty;
# populated by HudRuntime._update_podium_chips() once standings tick.
static func make_podium_chip(rank: int) -> Control:
	var chip := PanelContainer.new()
	chip.custom_minimum_size = Vector2(72, 24)
	var tint: Color
	match rank:
		0: tint = HudTheme.C_GOLD
		1: tint = Color(0.72, 0.74, 0.78)
		_: tint = Color(0.78, 0.55, 0.30)
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

static func make_vertical_divider() -> Control:
	var div := ColorRect.new()
	div.color = HudTheme.C_BORDER_DIM
	div.custom_minimum_size = Vector2(1, 36)
	div.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return div

# ─── Timing tower ───────────────────────────────────────────────────────────

static func build_timing_tower(refs: Dictionary, marble_count: int, row_pitch: int) -> Control:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -300
	panel.offset_top = 80
	panel.offset_right = -16
	panel.offset_bottom = -180
	panel.add_theme_stylebox_override("panel",
		HudTheme.sb_panel(HudTheme.C_SURFACE_1, HudTheme.C_BORDER, 10, 1))
	refs["timing_tower"] = panel

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	var head_hb := HBoxContainer.new()
	head_hb.add_theme_constant_override("separation", 8)
	vb.add_child(head_hb)

	var timing_tower_header := Label.new()
	timing_tower_header.text = HudI18n.t("hud.standings.header")
	timing_tower_header.label_settings = HudTheme.ls_label_caps(HudTheme.accent(), HudTheme.FS_LABEL)
	timing_tower_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head_hb.add_child(timing_tower_header)
	refs["timing_tower_header"] = timing_tower_header

	var timing_tower_count := Label.new()
	timing_tower_count.text = ""
	timing_tower_count.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_TINY)
	head_hb.add_child(timing_tower_count)
	refs["timing_tower_count"] = timing_tower_count

	var sep := ColorRect.new()
	sep.color = HudTheme.C_BORDER_DIM
	sep.custom_minimum_size = Vector2(0, 1)
	vb.add_child(sep)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	refs["timing_tower_scroll"] = scroll

	var canvas := Control.new()
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.custom_minimum_size = Vector2(0, marble_count * row_pitch)
	scroll.add_child(canvas)
	refs["timing_tower_canvas"] = canvas

	return panel

# Build one timing-tower row (a clickable Button with rank/chip/name/badge).
static func make_tower_row(orig_idx: int, marble_name: String, color: Color,
		row_h: int, marble_selected_signal: Signal) -> Control:
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
	btn.offset_bottom = float(row_h)
	btn.custom_minimum_size = Vector2(0, row_h)

	var sb_normal := HudTheme.sb_row(Color(1.0, 1.0, 1.0, 0.04))
	var sb_hover  := HudTheme.sb_row(Color(1.0, 1.0, 1.0, 0.10))
	var sb_press  := HudTheme.sb_row(Color(1.0, 1.0, 1.0, 0.18))
	btn.add_theme_stylebox_override("normal",   sb_normal)
	btn.add_theme_stylebox_override("hover",    sb_hover)
	btn.add_theme_stylebox_override("pressed",  sb_press)
	btn.add_theme_stylebox_override("disabled", sb_normal)
	btn.add_theme_stylebox_override("focus",    sb_normal)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	hb.set_anchors_preset(Control.PRESET_FULL_RECT)
	hb.set_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_KEEP_SIZE, 6)
	btn.add_child(hb)

	var rank_label := Label.new()
	rank_label.name = "RankLabel"
	rank_label.text = "%02d" % (orig_idx + 1)
	rank_label.label_settings = HudTheme.ls_metric(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_TEXT)
	rank_label.custom_minimum_size = Vector2(28, 0)
	rank_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hb.add_child(rank_label)

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

	var id_label := Label.new()
	id_label.name = "IdLabel"
	id_label.text = HudTheme.short_marble_name(marble_name)
	id_label.label_settings = HudTheme.ls_caption(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_TEXT)
	id_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	id_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hb.add_child(id_label)

	var badge := PanelContainer.new()
	badge.name = "PickupBadge"
	badge.visible = false
	badge.add_theme_stylebox_override("panel",
		HudTheme.sb_pill(Color(HudTheme.C_GREEN.r, HudTheme.C_GREEN.g, HudTheme.C_GREEN.b, 0.25)))
	var badge_lbl := Label.new()
	badge_lbl.name = "PickupBadgeLabel"
	badge_lbl.text = HudI18n.t("hud.pickup.tier1_badge")
	badge_lbl.label_settings = HudTheme.ls_label_caps(HudTheme.C_GREEN, HudTheme.FS_TINY)
	badge.add_child(badge_lbl)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(badge)

	btn.pressed.connect(func() -> void:
		marble_selected_signal.emit(orig_idx)
	)
	return btn

# ─── Timer hero ─────────────────────────────────────────────────────────────

static func build_timer_hero(refs: Dictionary) -> Control:
	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	anchor.offset_left = -130
	anchor.offset_right = 130
	anchor.offset_top = -130
	anchor.offset_bottom = -32
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	refs["timer_card"] = anchor

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", HudTheme.sb_card())
	card.set_anchors_preset(Control.PRESET_FULL_RECT)
	anchor.add_child(card)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 2)
	card.add_child(vb)

	var timer_caption := Label.new()
	timer_caption.text = HudI18n.t("hud.timer.caption")
	timer_caption.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_TINY)
	timer_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(timer_caption)
	refs["timer_caption"] = timer_caption

	var timer_label := Label.new()
	timer_label.text = HudTheme.format_race_time(0.0)
	timer_label.label_settings = HudTheme.ls_timer(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_TIMER)
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(timer_label)
	refs["timer_label"] = timer_label

	var race_progress_bar := ProgressBar.new()
	race_progress_bar.show_percentage = false
	race_progress_bar.min_value = 0.0
	race_progress_bar.max_value = 100.0
	race_progress_bar.value = 0.0
	race_progress_bar.custom_minimum_size = Vector2(0, 4)
	var pb_track := StyleBoxFlat.new()
	pb_track.bg_color = Color(1.0, 1.0, 1.0, 0.10)
	pb_track.set_corner_radius_all(2)
	var pb_fill := StyleBoxFlat.new()
	pb_fill.bg_color = HudTheme.accent()
	pb_fill.set_corner_radius_all(2)
	race_progress_bar.add_theme_stylebox_override("background", pb_track)
	race_progress_bar.add_theme_stylebox_override("fill", pb_fill)
	vb.add_child(race_progress_bar)
	refs["race_progress_bar"] = race_progress_bar

	var bets_locked_pill := PanelContainer.new()
	bets_locked_pill.add_theme_stylebox_override("panel",
		HudTheme.sb_pill(Color(HudTheme.C_AMBER.r, HudTheme.C_AMBER.g, HudTheme.C_AMBER.b, 0.20)))
	bets_locked_pill.visible = false
	var lock_lbl := Label.new()
	lock_lbl.text = HudI18n.t("hud.timer.bets_locked")
	lock_lbl.label_settings = HudTheme.ls_label_caps(HudTheme.C_AMBER, HudTheme.FS_TINY)
	lock_lbl.set_meta("i18n_key", "hud.timer.bets_locked")
	bets_locked_pill.add_child(lock_lbl)
	vb.add_child(bets_locked_pill)
	refs["bets_locked_pill"] = bets_locked_pill

	return anchor

# ─── Bet panel ──────────────────────────────────────────────────────────────

# `payout_consts` dict: {PAYOUT_1ST, PAYOUT_2ND, PAYOUT_3RD, PAYOUT_TIER1_MULT,
#                        PAYOUT_TIER2_MULT, PAYOUT_JACKPOT}
# `preset_amounts` array of float values for stake chips
# `on_preset_cb` / `on_adjust_cb` / `on_place_bet_cb` / `on_marble_chip_cb`:
#   callables wired to the buttons; passed in from HudRuntime.
static func build_bet_panel(refs: Dictionary,
		payout_consts: Dictionary,
		preset_amounts: Array,
		on_preset_cb: Callable,
		on_adjust_cb: Callable,
		on_place_bet_cb: Callable) -> Control:
	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	anchor.offset_left = -290
	anchor.offset_right = 290
	anchor.offset_top = -380
	anchor.offset_bottom = -150
	anchor.mouse_filter = Control.MOUSE_FILTER_PASS
	anchor.visible = false
	refs["bet_panel"] = anchor

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", HudTheme.sb_card(HudTheme.C_SURFACE_2))
	card.set_anchors_preset(Control.PRESET_FULL_RECT)
	anchor.add_child(card)
	refs["bet_panel_card"] = card

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", HudTheme.GAP_SECTION)
	card.add_child(vb)

	# Header
	var header_hb := HBoxContainer.new()
	header_hb.add_theme_constant_override("separation", 12)
	vb.add_child(header_hb)

	var header_lbl := Label.new()
	header_lbl.text = HudI18n.t("hud.bet.header")
	header_lbl.label_settings = HudTheme.ls_label_caps(HudTheme.accent(), HudTheme.FS_LABEL)
	header_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_lbl.set_meta("i18n_key", "hud.bet.header")
	header_hb.add_child(header_lbl)

	var bet_countdown_label := Label.new()
	bet_countdown_label.text = ""
	bet_countdown_label.label_settings = HudTheme.ls_label_caps(HudTheme.C_GREEN, HudTheme.FS_LABEL)
	bet_countdown_label.visible = false
	header_hb.add_child(bet_countdown_label)
	refs["bet_countdown_label"] = bet_countdown_label

	var div1 := ColorRect.new()
	div1.color = HudTheme.C_BORDER_DIM
	div1.custom_minimum_size = Vector2(0, 1)
	vb.add_child(div1)

	# Marble selector strip
	var bet_marble_caption := Label.new()
	bet_marble_caption.text = HudI18n.t("hud.bet.pick_marble")
	bet_marble_caption.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_TINY)
	bet_marble_caption.set_meta("i18n_key", "hud.bet.pick_marble")
	vb.add_child(bet_marble_caption)
	refs["bet_marble_caption"] = bet_marble_caption

	var strip_scroll := ScrollContainer.new()
	strip_scroll.custom_minimum_size = Vector2(0, 50)
	strip_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(strip_scroll)

	var bet_marble_strip := HBoxContainer.new()
	bet_marble_strip.add_theme_constant_override("separation", 6)
	strip_scroll.add_child(bet_marble_strip)
	refs["bet_marble_strip"] = bet_marble_strip

	# Stake row
	var stake_caption := Label.new()
	stake_caption.text = HudI18n.t("hud.bet.stake_caption")
	stake_caption.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_TINY)
	stake_caption.set_meta("i18n_key", "hud.bet.stake_caption")
	vb.add_child(stake_caption)

	var stake_hb := HBoxContainer.new()
	stake_hb.add_theme_constant_override("separation", 8)
	vb.add_child(stake_hb)

	var bet_chip_buttons: Array[Button] = []
	for preset_val in preset_amounts:
		var pb := Button.new()
		pb.text = "%d" % preset_val
		pb.flat = false
		pb.focus_mode = Control.FOCUS_NONE
		apply_chip_style(pb, false)
		pb.custom_minimum_size = Vector2(48, 32)
		pb.pressed.connect(on_preset_cb.bind(float(preset_val), pb))
		bet_chip_buttons.append(pb)
		stake_hb.add_child(pb)
	refs["bet_chip_buttons"] = bet_chip_buttons

	var adj_hb := HBoxContainer.new()
	adj_hb.add_theme_constant_override("separation", 6)
	vb.add_child(adj_hb)

	for delta in [-10, -1, 1, 10]:
		var b := Button.new()
		b.text = "%+d" % delta
		b.flat = false
		b.focus_mode = Control.FOCUS_NONE
		apply_chip_style(b, false)
		b.custom_minimum_size = Vector2(40, 28)
		b.pressed.connect(on_adjust_cb.bind(float(delta)))
		adj_hb.add_child(b)

	var bet_stake_label := Label.new()
	bet_stake_label.text = HudTheme.format_money(10.0)
	bet_stake_label.label_settings = HudTheme.ls_metric(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_NUMBER_LARGE)
	bet_stake_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bet_stake_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	adj_hb.add_child(bet_stake_label)
	refs["bet_stake_label"] = bet_stake_label

	# Payout matrix
	var pm_header := Label.new()
	pm_header.text = HudI18n.t("hud.bet.payout_matrix.header")
	pm_header.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_TINY)
	pm_header.set_meta("i18n_key", "hud.bet.payout_matrix.header")
	vb.add_child(pm_header)

	var pm_card := PanelContainer.new()
	pm_card.add_theme_stylebox_override("panel",
		HudTheme.sb_panel(Color(1, 1, 1, 0.04), HudTheme.C_BORDER_DIM, 8, 1))
	vb.add_child(pm_card)

	var pm_vb := VBoxContainer.new()
	pm_vb.add_theme_constant_override("separation", 3)
	pm_card.add_child(pm_vb)

	for row_data in [
		{"key": "hud.bet.payout_1st",    "mult": float(payout_consts.get("PAYOUT_1ST", 9.0)),
		 "name": "Row1st", "color": HudTheme.C_GOLD},
		{"key": "hud.bet.payout_2nd",    "mult": float(payout_consts.get("PAYOUT_2ND", 4.5)),
		 "name": "Row2nd", "color": HudTheme.C_TEXT_PRIMARY},
		{"key": "hud.bet.payout_3rd",    "mult": float(payout_consts.get("PAYOUT_3RD", 3.0)),
		 "name": "Row3rd", "color": HudTheme.C_TEXT_PRIMARY},
		{"key": "hud.bet.payout_tier1",  "mult": float(payout_consts.get("PAYOUT_TIER1_MULT", 2.0)),
		 "name": "RowT1",  "color": HudTheme.C_GREEN},
		{"key": "hud.bet.payout_tier2",  "mult": float(payout_consts.get("PAYOUT_TIER2_MULT", 3.0)),
		 "name": "RowT2",  "color": HudTheme.C_GOLD},
		{"key": "hud.bet.payout_jackpot","mult": float(payout_consts.get("PAYOUT_JACKPOT", 100.0)),
		 "name": "RowJP",  "color": HudTheme.C_AMBER},
	]:
		var r_hb := HBoxContainer.new()
		r_hb.name = String(row_data["name"])
		r_hb.add_theme_constant_override("separation", 6)
		pm_vb.add_child(r_hb)

		var r_lbl := Label.new()
		r_lbl.text = HudI18n.t(String(row_data["key"]))
		r_lbl.set_meta("i18n_key", String(row_data["key"]))
		r_lbl.label_settings = HudTheme.ls_caption(Color(row_data["color"]), HudTheme.FS_SMALL)
		r_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r_hb.add_child(r_lbl)

		var r_mult := Label.new()
		r_mult.name = "MultLabel"
		var mult_f: float = float(row_data["mult"])
		var mult_str: String = ("%.0f" % mult_f) if mult_f == floor(mult_f) else ("%.1f" % mult_f)
		r_mult.text = mult_str + "×"
		r_mult.label_settings = HudTheme.ls_metric(Color(row_data["color"]), HudTheme.FS_SMALL)
		r_hb.add_child(r_mult)

		var r_val := Label.new()
		r_val.name = "ValLabel"
		r_val.text = "= —"
		r_val.label_settings = HudTheme.ls_metric(HudTheme.C_TEXT_SECONDARY, HudTheme.FS_SMALL)
		r_val.custom_minimum_size = Vector2(64, 0)
		r_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		r_hb.add_child(r_val)

	# Legacy single payout label (hidden — kept for compat).
	var bet_potential_payout := Label.new()
	bet_potential_payout.text = ""
	bet_potential_payout.label_settings = HudTheme.ls_label_caps(HudTheme.C_GREEN, HudTheme.FS_TEXT)
	bet_potential_payout.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bet_potential_payout.visible = false
	vb.add_child(bet_potential_payout)
	refs["bet_potential_payout"] = bet_potential_payout

	# CTA
	var bet_cta := Button.new()
	bet_cta.text = HudI18n.t("hud.bet.cta")
	bet_cta.flat = false
	bet_cta.focus_mode = Control.FOCUS_NONE
	bet_cta.set_meta("i18n_key", "hud.bet.cta")
	bet_cta.add_theme_stylebox_override("normal",   HudTheme.sb_button_primary(HudTheme.accent()))
	bet_cta.add_theme_stylebox_override("hover",    HudTheme.sb_button_primary(HudTheme.accent().lightened(0.10)))
	bet_cta.add_theme_stylebox_override("pressed",  HudTheme.sb_button_primary(HudTheme.accent().darkened(0.10)))
	bet_cta.add_theme_stylebox_override("disabled", HudTheme.sb_button_primary_disabled())
	bet_cta.add_theme_stylebox_override("focus",    HudTheme.sb_button_primary(HudTheme.accent()))
	bet_cta.add_theme_font_override("font", HudTheme.font_display())
	bet_cta.add_theme_font_size_override("font_size", HudTheme.FS_TEXT)
	bet_cta.add_theme_color_override("font_color", HudTheme.C_TEXT_INVERSE)
	bet_cta.add_theme_color_override("font_disabled_color", HudTheme.C_TEXT_DIM)
	bet_cta.add_theme_color_override("font_hover_color", HudTheme.C_TEXT_INVERSE)
	bet_cta.add_theme_color_override("font_pressed_color", HudTheme.C_TEXT_INVERSE)
	bet_cta.disabled = true
	bet_cta.pressed.connect(on_place_bet_cb)
	vb.add_child(bet_cta)
	refs["bet_cta"] = bet_cta

	# Active bets list
	var bets_caption := Label.new()
	bets_caption.text = HudI18n.t("hud.bet.your_bets")
	bets_caption.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_TINY)
	bets_caption.set_meta("i18n_key", "hud.bet.your_bets")
	vb.add_child(bets_caption)

	var bets_scroll := ScrollContainer.new()
	bets_scroll.custom_minimum_size = Vector2(0, 60)
	bets_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(bets_scroll)

	var bets_list := VBoxContainer.new()
	bets_list.add_theme_constant_override("separation", 4)
	bets_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bets_scroll.add_child(bets_list)
	refs["bets_list"] = bets_list

	return anchor

# Build one marble selector chip for the bet panel.
# `on_press_cb` receives (orig_idx, color) when pressed.
static func make_bet_marble_chip(orig_idx: int, marble_name: String,
		color: Color, bet_marble_strip: HBoxContainer,
		on_press_cb: Callable) -> Button:
	var chip := Button.new()
	chip.flat = false
	chip.focus_mode = Control.FOCUS_NONE
	chip.toggle_mode = false
	chip.custom_minimum_size = Vector2(48, 44)
	chip.tooltip_text = marble_name
	apply_marble_chip_style(chip, color, false)

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
		on_press_cb.call(orig_idx, color)
	)
	if bet_marble_strip != null:
		bet_marble_strip.add_child(chip)
	return chip

# Styling helpers — kept static so HudRuntime can call them too.
static func apply_marble_chip_style(chip: Button, color: Color, selected: bool) -> void:
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

static func apply_chip_style(btn: Button, selected: bool) -> void:
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

# ─── Winner modal ────────────────────────────────────────────────────────────

# `refs` receives: winner_modal, winner_modal_card, winner_color_swatch,
#   winner_caption_label, winner_name_label, winner_payout_label,
#   winner_breakdown_label, winner_next_round_label,
#   podium_name_p2, podium_name_p3,
#   podium_pillar_p1, podium_pillar_p2, podium_pillar_p3,
#   final_standings_list.
static func build_winner_modal(refs: Dictionary) -> Control:
	var control := Control.new()
	control.set_anchors_preset(Control.PRESET_FULL_RECT)
	control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	control.visible = false
	refs["winner_modal"] = control

	var scrim := ColorRect.new()
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.color = Color(0, 0, 0, 0.86)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	control.add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	control.add_child(center)

	var modal_card := PanelContainer.new()
	modal_card.add_theme_stylebox_override("panel",
		HudTheme.sb_card(HudTheme.C_SURFACE_HERO, HudTheme.C_GOLD))
	modal_card.custom_minimum_size = Vector2(960, 0)
	center.add_child(modal_card)
	refs["winner_modal_card"] = modal_card

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 18)
	modal_card.add_child(vb)

	# Caption row
	var caption_hb := HBoxContainer.new()
	caption_hb.alignment = BoxContainer.ALIGNMENT_CENTER
	caption_hb.add_theme_constant_override("separation", 12)
	vb.add_child(caption_hb)

	var winner_color_swatch := ColorRect.new()
	winner_color_swatch.color = HudTheme.C_GOLD
	winner_color_swatch.custom_minimum_size = Vector2(28, 28)
	winner_color_swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	caption_hb.add_child(winner_color_swatch)
	refs["winner_color_swatch"] = winner_color_swatch

	var winner_caption_label := Label.new()
	winner_caption_label.text = HudI18n.t("hud.winner.caption")
	winner_caption_label.label_settings = HudTheme.ls_label_caps(HudTheme.accent(), HudTheme.FS_TITLE)
	winner_caption_label.set_meta("i18n_key", "hud.winner.caption")
	caption_hb.add_child(winner_caption_label)
	refs["winner_caption_label"] = winner_caption_label

	# Podium row (P2 | P1 | P3 order)
	var podium_hb := HBoxContainer.new()
	podium_hb.alignment = BoxContainer.ALIGNMENT_CENTER
	podium_hb.add_theme_constant_override("separation", 16)
	vb.add_child(podium_hb)
	podium_hb.add_child(_make_podium_column(2, 150, refs))
	podium_hb.add_child(_make_podium_column(1, 220, refs))
	podium_hb.add_child(_make_podium_column(3, 110, refs))

	# Final standings table (positions 4..20)
	var table_panel := PanelContainer.new()
	table_panel.add_theme_stylebox_override("panel",
		HudTheme.sb_panel(HudTheme.C_SURFACE_1, HudTheme.C_BORDER, 8, 1))
	vb.add_child(table_panel)

	var table_vb := VBoxContainer.new()
	table_vb.add_theme_constant_override("separation", 8)
	table_panel.add_child(table_vb)

	var table_header := Label.new()
	table_header.text = "FINAL STANDINGS"
	table_header.label_settings = HudTheme.ls_label_caps(HudTheme.C_GOLD, HudTheme.FS_LABEL)
	table_vb.add_child(table_header)

	var table_sep := ColorRect.new()
	table_sep.color = HudTheme.C_GOLD
	table_sep.custom_minimum_size = Vector2(0, 2)
	table_vb.add_child(table_sep)

	var final_standings_list := VBoxContainer.new()
	final_standings_list.add_theme_constant_override("separation", 4)
	table_vb.add_child(final_standings_list)
	refs["final_standings_list"] = final_standings_list

	# Payout labels
	var winner_payout_label := Label.new()
	winner_payout_label.text = ""
	winner_payout_label.label_settings = HudTheme.ls_metric(HudTheme.C_GREEN, HudTheme.FS_HERO_NUM)
	winner_payout_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	winner_payout_label.visible = false
	vb.add_child(winner_payout_label)
	refs["winner_payout_label"] = winner_payout_label

	var winner_breakdown_label := Label.new()
	winner_breakdown_label.text = ""
	winner_breakdown_label.label_settings = HudTheme.ls_caption(HudTheme.C_TEXT_SECONDARY, HudTheme.FS_SMALL)
	winner_breakdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	winner_breakdown_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	winner_breakdown_label.visible = false
	vb.add_child(winner_breakdown_label)
	refs["winner_breakdown_label"] = winner_breakdown_label

	var div := ColorRect.new()
	div.color = HudTheme.C_BORDER_DIM
	div.custom_minimum_size = Vector2(0, 1)
	vb.add_child(div)

	var winner_next_round_label := Label.new()
	winner_next_round_label.text = ""
	winner_next_round_label.label_settings = HudTheme.ls_label_caps(HudTheme.C_CYAN, HudTheme.FS_LABEL)
	winner_next_round_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	winner_next_round_label.visible = false
	vb.add_child(winner_next_round_label)
	refs["winner_next_round_label"] = winner_next_round_label

	return control

# Internal: build one podium column; writes winner_name_label / podium_name_p2 /
# podium_name_p3 and the three pillar refs into `refs`.
static func _make_podium_column(rank: int, pillar_height: int, refs: Dictionary) -> Control:
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_END
	col.add_theme_constant_override("separation", 6)
	col.custom_minimum_size = Vector2(180, 0)

	var place_caption := Label.new()
	place_caption.text = ["1ST", "2ND", "3RD"][rank - 1]
	place_caption.label_settings = HudTheme.ls_label_caps(
		HudTheme.C_GOLD if rank == 1 else HudTheme.C_TEXT_SECONDARY,
		HudTheme.FS_LABEL)
	place_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(place_caption)

	var name_lbl := Label.new()
	name_lbl.text = "—"
	name_lbl.label_settings = HudTheme.ls_hero(
		HudTheme.C_TEXT_PRIMARY,
		HudTheme.FS_HERO_NUM if rank == 1 else HudTheme.FS_TITLE)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(name_lbl)
	if rank == 1:
		refs["winner_name_label"] = name_lbl
	elif rank == 2:
		refs["podium_name_p2"] = name_lbl
	else:
		refs["podium_name_p3"] = name_lbl

	var pillar := PanelContainer.new()
	pillar.custom_minimum_size = Vector2(0, pillar_height)
	pillar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pstyle := StyleBoxFlat.new()
	pstyle.bg_color = HudTheme.C_SURFACE_2
	pstyle.border_color = HudTheme.C_GOLD if rank == 1 else HudTheme.C_BORDER
	pstyle.set_border_width_all(2 if rank == 1 else 1)
	pstyle.corner_radius_top_left  = 6
	pstyle.corner_radius_top_right = 6
	pstyle.corner_radius_bottom_left  = 0
	pstyle.corner_radius_bottom_right = 0
	pillar.add_theme_stylebox_override("panel", pstyle)

	var pillar_center := CenterContainer.new()
	pillar.add_child(pillar_center)

	var num_lbl := Label.new()
	num_lbl.text = str(rank)
	var ls := LabelSettings.new()
	ls.font_color = HudTheme.C_TEXT_PRIMARY
	ls.font_size = 120 if rank == 1 else 88
	num_lbl.label_settings = ls
	num_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	num_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pillar_center.add_child(num_lbl)

	if rank == 1:
		refs["podium_pillar_p1"] = pillar
	elif rank == 2:
		refs["podium_pillar_p2"] = pillar
	else:
		refs["podium_pillar_p3"] = pillar

	col.add_child(pillar)
	return col

# Build one row in the 4..20 final-standings table.
static func make_final_table_row(rank: int, marble_name: String, color: Color) -> Control:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)

	var rank_lbl := Label.new()
	rank_lbl.text = "%02d" % rank
	rank_lbl.label_settings = HudTheme.ls_caption(HudTheme.C_TEXT_SECONDARY, HudTheme.FS_TEXT)
	rank_lbl.custom_minimum_size = Vector2(38, 0)
	hb.add_child(rank_lbl)

	var bar := ColorRect.new()
	bar.color = color
	bar.custom_minimum_size = Vector2(6, 24)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(bar)

	var name_lbl := Label.new()
	name_lbl.text = marble_name.to_upper()
	name_lbl.label_settings = HudTheme.ls_caption(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_TEXT)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(name_lbl)

	return hb

# ─── Toast ───────────────────────────────────────────────────────────────────

static func build_toast(refs: Dictionary) -> Control:
	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	anchor.offset_left = -200
	anchor.offset_right = 200
	anchor.offset_top = -176
	anchor.offset_bottom = -140
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	refs["toast_anchor"] = anchor

	var toast_card := PanelContainer.new()
	toast_card.add_theme_stylebox_override("panel", HudTheme.sb_toast(HudTheme.TOAST_INFO))
	toast_card.set_anchors_preset(Control.PRESET_FULL_RECT)
	toast_card.modulate = Color(1, 1, 1, 0)
	toast_card.visible = false
	anchor.add_child(toast_card)
	refs["toast_card"] = toast_card

	var toast_label := Label.new()
	toast_label.text = ""
	toast_label.label_settings = HudTheme.ls_caption(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_TEXT)
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	toast_card.add_child(toast_label)
	refs["toast_label"] = toast_label

	return anchor

# ─── Session stats panel ────────────────────────────────────────────────────
# Anchored bottom-left, below the timing tower. Shows aggregate session stats
# (Total wagered, Total won, Net P/L, Rounds played, Win rate) plus a
# scrollable Recent Rounds list (up to 8 rows, FIFO cap 50).
# All label refs written into `refs` for runtime to update.

static func build_session_stats(refs: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	panel.offset_left  = 16
	panel.offset_right = 316
	panel.offset_top   = -340
	panel.offset_bottom = -16
	panel.add_theme_stylebox_override("panel",
		HudTheme.sb_panel(HudTheme.C_SURFACE_1, HudTheme.C_BORDER, 10, 1))
	refs["session_stats_panel"] = panel

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", HudTheme.GAP_ROW)
	panel.add_child(vb)

	# ── Header ──
	var hdr := Label.new()
	hdr.text = "SESSION"
	hdr.label_settings = HudTheme.ls_label_caps(HudTheme.accent(), HudTheme.FS_LABEL)
	vb.add_child(hdr)

	var div := ColorRect.new()
	div.color = HudTheme.C_BORDER_DIM
	div.custom_minimum_size = Vector2(0, 1)
	vb.add_child(div)

	# ── Stat rows ──
	var stat_rows := [
		["Wagered",  "stat_wagered_label"],
		["Won",      "stat_won_label"],
		["Net P/L",  "stat_netpl_label"],
		["Rounds",   "stat_rounds_label"],
		["Win rate", "stat_winrate_label"],
	]
	for spec in stat_rows:
		var row_hb := HBoxContainer.new()
		row_hb.add_theme_constant_override("separation", 4)
		vb.add_child(row_hb)

		var key_lbl := Label.new()
		key_lbl.text = String(spec[0])
		key_lbl.label_settings = HudTheme.ls_caption(HudTheme.C_TEXT_DIM, HudTheme.FS_SMALL)
		key_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row_hb.add_child(key_lbl)

		var val_lbl := Label.new()
		val_lbl.text = "—"
		val_lbl.label_settings = HudTheme.ls_metric(HudTheme.C_TEXT_PRIMARY, HudTheme.FS_SMALL)
		val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row_hb.add_child(val_lbl)
		refs[String(spec[1])] = val_lbl

	# ── Recent rounds divider ──
	var div2 := ColorRect.new()
	div2.color = HudTheme.C_BORDER_DIM
	div2.custom_minimum_size = Vector2(0, 1)
	vb.add_child(div2)

	var recent_hdr := Label.new()
	recent_hdr.text = "RECENT ROUNDS"
	recent_hdr.label_settings = HudTheme.ls_label_caps(HudTheme.C_TEXT_DIM, HudTheme.FS_TINY)
	vb.add_child(recent_hdr)

	# Scrollable recent rounds list (8 rows visible)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)

	var recent_list := VBoxContainer.new()
	recent_list.add_theme_constant_override("separation", 2)
	recent_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(recent_list)
	refs["session_recent_list"] = recent_list

	return panel
