class_name HudTheme
extends Object

# Operator runtime overrides — set via HudTheme.apply_operator_overrides()
# from HUD.apply_operator_theme(). When unset (sentinel zero-alpha for the
# colour, empty string for text, null for the texture), defaults below
# (C_GOLD / "MARBLES" / no logo) are used. Values are queried by
# HudTheme.accent(), HudTheme.brand_text(), HudTheme.brand_logo() —
# always prefer those helpers over the bare constants when an operator
# may want to swap them.
static var _accent_override: Color = Color(0, 0, 0, 0)
static var _brand_text_override: String = ""
static var _brand_logo_override: Texture2D = null

# Apply operator overrides at runtime. Pass a dict with any subset of:
#   accent_color: Color   — replaces C_GOLD as primary accent
#   brand_text:   String  — replaces "MARBLES" as the brand label
#   brand_logo:   Texture2D — replaces the "M" glyph mark
# Caller (HUD.apply_operator_theme) is responsible for re-styling existing
# widgets after this call; this function only stores the overrides.
static func apply_operator_overrides(config: Dictionary) -> void:
	if config.has("accent_color") and typeof(config["accent_color"]) == TYPE_COLOR:
		_accent_override = config["accent_color"]
	if config.has("brand_text") and typeof(config["brand_text"]) == TYPE_STRING:
		_brand_text_override = String(config["brand_text"])
	if config.has("brand_logo") and config["brand_logo"] is Texture2D:
		_brand_logo_override = config["brand_logo"]

static func clear_operator_overrides() -> void:
	_accent_override = Color(0, 0, 0, 0)
	_brand_text_override = ""
	_brand_logo_override = null

static func accent() -> Color:
	return _accent_override if _accent_override.a > 0.0 else C_GOLD

static func brand_text() -> String:
	return _brand_text_override if _brand_text_override != "" else "MARBLES"

static func brand_logo() -> Texture2D:
	return _brand_logo_override

# Centralised broadcast-style theme for the HUD.
#
# Single source for: palette, font sizes, stylebox factories, animation
# constants, breakpoints. The HUD itself stays free of magic numbers.
#
# Aesthetic target: F1 timing tower / ESPN sports broadcast / sportsbook
# premium card — dark navy panels with subtle borders, warm gold accent
# for "leader / payout positive", cyan for "active focus", red for
# "error / loss", green for "success / win". Tabular monospace for
# numbers. Strong contrast for stream readability.

# ─── Palette ────────────────────────────────────────────────────────────────

# Surface (panel backgrounds, layered from outer dark to inner card).
const C_SURFACE_0     := Color(0.04, 0.06, 0.10, 0.92)   # darkest backdrop
const C_SURFACE_1     := Color(0.07, 0.10, 0.16, 0.94)   # default panel
const C_SURFACE_2     := Color(0.10, 0.14, 0.22, 0.96)   # raised card
const C_SURFACE_HERO  := Color(0.05, 0.07, 0.12, 0.98)   # winner modal

# Borders / dividers.
const C_BORDER_DIM    := Color(1.0, 1.0, 1.0, 0.06)
const C_BORDER        := Color(1.0, 1.0, 1.0, 0.10)
const C_BORDER_BRIGHT := Color(1.0, 1.0, 1.0, 0.18)

# Text.
const C_TEXT_PRIMARY   := Color(0.98, 0.98, 1.00)        # white
const C_TEXT_SECONDARY := Color(0.62, 0.66, 0.74)        # gray-blue
const C_TEXT_DIM       := Color(0.42, 0.46, 0.54)        # muted
const C_TEXT_INVERSE   := Color(0.06, 0.08, 0.12)        # for on-accent

# Accents.
const C_GOLD          := Color(0.96, 0.72, 0.20)         # leader, payout positive
const C_GOLD_DIM      := Color(0.55, 0.42, 0.12)         # leader bg fill
const C_CYAN          := Color(0.22, 0.80, 0.96)         # active focus / following
const C_GREEN         := Color(0.22, 0.86, 0.48)         # win / live
const C_RED           := Color(1.00, 0.34, 0.42)         # error / loss
const C_AMBER         := Color(0.96, 0.62, 0.16)         # warning / countdown <3s
const C_VIOLET        := Color(0.55, 0.42, 0.96)         # info / round indicator

# Phase pill colors.
const C_PHASE_WAITING  := Color(0.22, 0.80, 0.96)        # cyan = anticipating
const C_PHASE_RACING   := Color(0.22, 0.86, 0.48)        # green = live
const C_PHASE_FINISHED := Color(0.96, 0.72, 0.20)        # gold = result

# ─── Font sizes ─────────────────────────────────────────────────────────────

const FS_HERO_NUM     := 56     # winner big number (4 digits stake / podium)
const FS_TIMER        := 48     # race timer (monospace)
const FS_TITLE        := 22     # section titles
const FS_NUMBER_LARGE := 20     # primary metric (balance, stake)
const FS_TEXT         := 14     # body
const FS_SMALL        := 12     # secondary
const FS_TINY         := 10     # caps / chip
const FS_LABEL        := 11     # uppercase labels (LIVE, BET, etc.)

# ─── Spacing ────────────────────────────────────────────────────────────────

const PAD_PANEL_X := 16
const PAD_PANEL_Y := 12
const PAD_CARD_X  := 18
const PAD_CARD_Y  := 14
const PAD_PILL_X  := 10
const PAD_PILL_Y  := 5
const GAP_SECTION := 10
const GAP_ROW     := 4

# ─── Breakpoints (responsive) ──────────────────────────────────────────────
# Below 768 px wide → portrait/mobile layout. Above → landscape/desktop.
const BREAKPOINT_MOBILE := 768

# ─── Animation timings ──────────────────────────────────────────────────────
const ANIM_FAST   := 0.18
const ANIM_NORMAL := 0.28
const ANIM_SLOW   := 0.45
const ANIM_REORDER := 0.32   # standings rank-change tween

# ─── Toast types ────────────────────────────────────────────────────────────
const TOAST_INFO    := 0
const TOAST_SUCCESS := 1
const TOAST_ERROR   := 2
const TOAST_WARNING := 3

# ─── Fonts ──────────────────────────────────────────────────────────────────
# We use SystemFont with a preference list so on most OSes (Windows,
# macOS, Linux) we get a clean modern sans-serif, falling back to the
# Godot default if nothing matches. For Web export this falls back to the
# bundled font — readable, not premium, but at least stable.

static func font_display() -> SystemFont:
	# Headers, big numbers — condensed/heavy preferred.
	var f := SystemFont.new()
	f.font_names = [
		"Inter", "Inter Display", "Roboto Condensed", "Bebas Neue",
		"Oswald", "Helvetica Neue", "Arial Black", "Arial", "sans-serif",
	]
	f.font_weight = 700
	return f

static func font_body() -> SystemFont:
	# Default body text — regular weight.
	var f := SystemFont.new()
	f.font_names = [
		"Inter", "Roboto", "Helvetica Neue", "Segoe UI", "Arial", "sans-serif",
	]
	f.font_weight = 500
	return f

static func font_mono() -> SystemFont:
	# Timer, numbers — tabular monospace.
	var f := SystemFont.new()
	f.font_names = [
		"JetBrains Mono", "Roboto Mono", "Menlo", "Consolas",
		"DejaVu Sans Mono", "Courier New", "monospace",
	]
	f.font_weight = 600
	return f

# ─── StyleBox factories ─────────────────────────────────────────────────────

# Default panel: rounded card with subtle border.
static func sb_panel(bg: Color = C_SURFACE_1, border: Color = C_BORDER,
		corner: int = 10, border_w: int = 1) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.corner_radius_top_left    = corner
	sb.corner_radius_top_right   = corner
	sb.corner_radius_bottom_left = corner
	sb.corner_radius_bottom_right = corner
	sb.content_margin_left   = PAD_PANEL_X
	sb.content_margin_right  = PAD_PANEL_X
	sb.content_margin_top    = PAD_PANEL_Y
	sb.content_margin_bottom = PAD_PANEL_Y
	return sb

# Hero card: bigger padding, subtle drop shadow effect via dark border.
static func sb_card(bg: Color = C_SURFACE_2, accent: Color = C_BORDER_BRIGHT) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = accent
	sb.set_border_width_all(1)
	sb.corner_radius_top_left    = 14
	sb.corner_radius_top_right   = 14
	sb.corner_radius_bottom_left = 14
	sb.corner_radius_bottom_right = 14
	sb.content_margin_left   = PAD_CARD_X
	sb.content_margin_right  = PAD_CARD_X
	sb.content_margin_top    = PAD_CARD_Y
	sb.content_margin_bottom = PAD_CARD_Y
	# Soft shadow.
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 12
	sb.shadow_offset = Vector2(0, 4)
	return sb

# Pill — small rounded chip for phase badges, LIVE, payout etc.
static func sb_pill(bg: Color, fg: Color = C_TEXT_PRIMARY) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	# fg unused on stylebox itself — caller picks font_color, we just need bg.
	# Kept in signature for API consistency / future hovered/disabled variants.
	var _ignore := fg
	sb.corner_radius_top_left    = 100  # full-pill (cap radius)
	sb.corner_radius_top_right   = 100
	sb.corner_radius_bottom_left = 100
	sb.corner_radius_bottom_right = 100
	sb.content_margin_left   = PAD_PILL_X
	sb.content_margin_right  = PAD_PILL_X
	sb.content_margin_top    = PAD_PILL_Y
	sb.content_margin_bottom = PAD_PILL_Y
	return sb

# Top broadcast bar — full-width strip. Slight gradient effect via flat.
static func sb_top_bar() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.05, 0.09, 0.92)
	sb.border_color = C_GOLD
	sb.border_width_bottom = 2
	sb.content_margin_left   = 16
	sb.content_margin_right  = 16
	sb.content_margin_top    = 10
	sb.content_margin_bottom = 10
	return sb

# Standings row — flat with optional left accent bar (for leader / following).
static func sb_row(bg: Color, accent: Color = Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	if accent.a > 0.0:
		sb.border_color = accent
		sb.border_width_left = 3
		sb.border_width_top = 0
		sb.border_width_right = 0
		sb.border_width_bottom = 0
	sb.corner_radius_top_left    = 6
	sb.corner_radius_top_right   = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left   = 8
	sb.content_margin_right  = 8
	sb.content_margin_top    = 5
	sb.content_margin_bottom = 5
	return sb

# Premium CTA button (PLACE BET).
static func sb_button_primary(bg: Color = C_GOLD) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.corner_radius_top_left    = 10
	sb.corner_radius_top_right   = 10
	sb.corner_radius_bottom_left = 10
	sb.corner_radius_bottom_right = 10
	sb.content_margin_left   = 22
	sb.content_margin_right  = 22
	sb.content_margin_top    = 12
	sb.content_margin_bottom = 12
	return sb

static func sb_button_primary_hover() -> StyleBoxFlat:
	var sb := sb_button_primary(C_GOLD.lightened(0.10))
	return sb

static func sb_button_primary_disabled() -> StyleBoxFlat:
	var sb := sb_button_primary(Color(0.20, 0.22, 0.28, 0.65))
	return sb

# Secondary chip button (preset stake amounts, marble color cards).
static func sb_chip(selected: bool = false, accent: Color = C_GOLD) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	if selected:
		sb.bg_color = Color(accent.r, accent.g, accent.b, 0.20)
		sb.border_color = accent
		sb.set_border_width_all(2)
	else:
		sb.bg_color = Color(1.0, 1.0, 1.0, 0.06)
		sb.border_color = C_BORDER
		sb.set_border_width_all(1)
	sb.corner_radius_top_left    = 8
	sb.corner_radius_top_right   = 8
	sb.corner_radius_bottom_left = 8
	sb.corner_radius_bottom_right = 8
	sb.content_margin_left   = 12
	sb.content_margin_right  = 12
	sb.content_margin_top    = 7
	sb.content_margin_bottom = 7
	return sb

# Toast pill — colored by type.
static func sb_toast(toast_type: int) -> StyleBoxFlat:
	var bg: Color
	var border: Color
	match toast_type:
		TOAST_SUCCESS:
			bg = Color(0.06, 0.18, 0.12, 0.96)
			border = C_GREEN
		TOAST_ERROR:
			bg = Color(0.20, 0.06, 0.10, 0.96)
			border = C_RED
		TOAST_WARNING:
			bg = Color(0.20, 0.14, 0.04, 0.96)
			border = C_AMBER
		_:
			bg = C_SURFACE_2
			border = C_BORDER_BRIGHT
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.border_width_left = 3
	sb.corner_radius_top_left    = 10
	sb.corner_radius_top_right   = 10
	sb.corner_radius_bottom_left = 10
	sb.corner_radius_bottom_right = 10
	sb.content_margin_left   = 14
	sb.content_margin_right  = 14
	sb.content_margin_top    = 10
	sb.content_margin_bottom = 10
	return sb

# Phase badge stylebox — used for the WAITING/RACING/FINISHED pill.
static func sb_phase_pill(phase: String) -> StyleBoxFlat:
	var bg: Color
	match phase:
		"RACING":
			bg = Color(C_PHASE_RACING.r, C_PHASE_RACING.g, C_PHASE_RACING.b, 0.22)
		"FINISHED":
			bg = Color(C_PHASE_FINISHED.r, C_PHASE_FINISHED.g, C_PHASE_FINISHED.b, 0.22)
		_:
			bg = Color(C_PHASE_WAITING.r, C_PHASE_WAITING.g, C_PHASE_WAITING.b, 0.22)
	return sb_pill(bg)

static func phase_color(phase: String) -> Color:
	match phase:
		"RACING": return C_PHASE_RACING
		"FINISHED": return C_PHASE_FINISHED
		_: return C_PHASE_WAITING

# ─── LabelSettings factories ────────────────────────────────────────────────
# LabelSettings is the modern Godot 4 way to style Labels — preferred over
# add_theme_font_size_override + add_theme_color_override pairs because it's
# a single Resource that the Label remembers, and easier to swap per-state.

static func ls_caption(color: Color = C_TEXT_SECONDARY, size: int = FS_SMALL) -> LabelSettings:
	var ls := LabelSettings.new()
	ls.font = font_body()
	ls.font_size = size
	ls.font_color = color
	return ls

static func ls_label_caps(color: Color = C_TEXT_SECONDARY, size: int = FS_LABEL) -> LabelSettings:
	# For UPPERCASE LABELS — caller must uppercase the text themselves;
	# Godot Label has no text-transform property natively.
	var ls := LabelSettings.new()
	ls.font = font_display()
	ls.font_size = size
	ls.font_color = color
	return ls

static func ls_title(color: Color = C_TEXT_PRIMARY, size: int = FS_TITLE) -> LabelSettings:
	var ls := LabelSettings.new()
	ls.font = font_display()
	ls.font_size = size
	ls.font_color = color
	return ls

static func ls_metric(color: Color = C_TEXT_PRIMARY, size: int = FS_NUMBER_LARGE) -> LabelSettings:
	var ls := LabelSettings.new()
	ls.font = font_mono()
	ls.font_size = size
	ls.font_color = color
	return ls

static func ls_timer(color: Color = C_TEXT_PRIMARY, size: int = FS_TIMER) -> LabelSettings:
	var ls := LabelSettings.new()
	ls.font = font_mono()
	ls.font_size = size
	ls.font_color = color
	# Subtle outline for stream readability.
	ls.outline_size = 2
	ls.outline_color = Color(0, 0, 0, 0.85)
	return ls

static func ls_hero(color: Color = C_TEXT_PRIMARY, size: int = FS_HERO_NUM) -> LabelSettings:
	var ls := LabelSettings.new()
	ls.font = font_display()
	ls.font_size = size
	ls.font_color = color
	ls.outline_size = 3
	ls.outline_color = Color(0, 0, 0, 0.65)
	return ls

# ─── Format helpers ─────────────────────────────────────────────────────────

# Display a balance amount with thousand separators and 2 decimals.
# E.g. 1250.5 → "1,250.50"
static func format_money(amount: float) -> String:
	var negative := amount < 0.0
	var v: float = absf(amount)
	var int_part := int(v)
	var frac_str := "%02d" % int(round((v - float(int_part)) * 100.0))
	# Insert thousand separators.
	var int_str := str(int_part)
	var with_seps := ""
	var n: int = int_str.length()
	for i in range(n):
		with_seps += int_str[i]
		var remaining: int = n - 1 - i
		if remaining > 0 and remaining % 3 == 0:
			with_seps += ","
	var sign_str := "-" if negative else ""
	return "%s%s.%s" % [sign_str, with_seps, frac_str]

# Race timer formatter: "M:SS.D" — minutes always 1 digit, seconds always 2,
# tenths shown for sport-broadcast precision. e.g. 23.4s → "0:23.4"
static func format_race_time(seconds: float) -> String:
	var minutes := int(seconds / 60.0)
	var sec_in_min := seconds - float(minutes * 60)
	return "%d:%05.2f" % [minutes, sec_in_min]

# Compact "+1,250.00" / "-50.00" — for payout deltas.
static func format_signed_money(amount: float) -> String:
	if amount >= 0.0:
		return "+%s" % format_money(amount)
	return format_money(amount)

# Trim "Marble_07" → "07" for compact display in standings rows.
static func short_marble_name(name: String) -> String:
	var trimmed := name.trim_prefix("Marble_")
	if trimmed.is_valid_int():
		return trimmed
	return name
