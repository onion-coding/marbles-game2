class_name HudV2Theme
extends RefCounted

# HUD v2 design tokens. Mirrors HUD Style Spec.md verbatim so card scripts
# read named values rather than scattered literals. Update tokens here →
# every card picks up the change.

# ─── Surface colours ────────────────────────────────────────────────────────

const BG          := Color8(0x07, 0x08, 0x0c)
const BG_2        := Color8(0x0d, 0x10, 0x18)
const PANEL       := Color(0.051, 0.063, 0.094, 0.85)   # rgba(13,16,24,.85)
const PANEL_2     := Color8(0x11, 0x14, 0x1d)
const BORDER      := Color(1.0, 1.0, 1.0, 0.06)

# ─── Text ───────────────────────────────────────────────────────────────────

const TEXT        := Color8(0xf4, 0xf6, 0xff)
const TEXT_DIM    := Color8(0xb4, 0xba, 0xcb)
const TEXT_FAINT  := Color8(0x7a, 0x80, 0x94)

# ─── Accent / state colours ─────────────────────────────────────────────────

const ACCENT      := Color8(0xff, 0x3e, 0xa5)   # pink — idle balance glow
const ACCENT_2    := Color8(0x6b, 0x5b, 0xff)
const GOOD        := Color8(0x2b, 0xd9, 0x9f)   # green — LIVE / BET button
const BAD         := Color8(0xff, 0x54, 0x70)   # red — IDLE pulse / trash

# Soft-tinted background variants used by chip/cell hover/active states.
const ACCENT_TINT_35 := Color(1.0, 0.243, 0.647, 0.35)
const BAD_TINT_8     := Color(1.0, 0.329, 0.439, 0.08)

# Round-timer state colours
const TIMER_OK     := GOOD
const TIMER_WARN   := Color8(0xff, 0xb5, 0x47)
const TIMER_DANGER := BAD

# Multiplier polarity colours (position card)
const MULT_POS := GOOD
const MULT_NEG := ACCENT

# ─── Sizes ──────────────────────────────────────────────────────────────────

const RADIUS_CARD     := 14
const PADDING_CARD    := 20
const BORDER_W        := 1
const PILL_RADIUS     := 999

# ─── Font sizes ─────────────────────────────────────────────────────────────

const FS_BRAND        := 16
const FS_BALANCE      := 40
const FS_LABEL_MONO   := 10        # the 0.15em-tracking caps labels
const FS_CHIP_MONO    := 10
const FS_TIMER_CLOCK  := 16
const FS_BET_NUMBER   := 24
const FS_CHIP_VALUE   := 13
const FS_BET_BUTTON   := 16
const FS_POS_HEADLINE := 40
const FS_POS_MULT     := 32
const FS_POS_GAP      := 18
const FS_LADDER_MONO  := 11
const FS_TICKER_MONO  := 10
const FS_DEBUG_BTN    := 11

# ─── Animation timings (ms → seconds) ───────────────────────────────────────

const T_CARD_SHOW      := 0.420
const T_NUM_BUMP       := 0.280
const T_DELTA_FLASH    := 0.480
const T_GLOW_CROSSFADE := 0.600
const T_PILL_STATE     := 0.280
const T_PILL_DOT_PULSE := 1.400
const T_CHIP_HOVER_BG  := 0.100
const T_CHIP_UNDERLINE := 0.120
const T_CHIP_PRESS     := 0.080
const T_CHIP_FLASH     := 0.360
const T_TRASH_SHAKE    := 0.380
const T_REPEAT_HOVER   := 0.140
const T_REPEAT_SPIN    := 0.600
const T_BET_HOVER      := 0.180
const T_BET_SHEEN      := 0.700
const T_BET_PRESS      := 0.120
const T_TIMER_COLOR    := 0.600
const T_TIMER_DANGER   := 0.800
const T_LADDER_REORDER := 0.240
const T_TICKER_IN      := 0.200
const T_TICKER_OUT     := 0.400

# ─── Quick-port constants (mirror Spec §Quick-port) ─────────────────────────

const ROUND_SECONDS    := 30.0
const WARN_PCT         := 0.5
const DANGER_PCT       := 0.2
const BET_MIN          := 1
const BET_MAX          := 99999
const DENOMINATIONS    : Array = [5, 10, 25, 50, 100, 250]
const RACE_FIELD_SIZE  := 30
const GAP_DANGER_SEC   := 3.0
const LADDER_WINDOW    := 1
const TICKER_LIFESPAN  := 2.4
const TICKER_MAX       := 2

# ─── Helpers ────────────────────────────────────────────────────────────────

# Standard panel StyleBox: fill + 1-px border + 14-px radius. Pass alpha=0
# for the rare dark-on-dark case (debug overlay), otherwise spec PANEL.
static func panel_style(fill: Color = PANEL, border: Color = BORDER,
		radius: int = RADIUS_CARD) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(BORDER_W)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(PADDING_CARD)
	sb.anti_aliasing = true
	sb.anti_aliasing_size = 0.5
	return sb

# Pill-shaped panel for chips and the LIVE pill. `bg` defaults to PANEL_2.
static func pill_style(bg: Color = PANEL_2, border: Color = BORDER) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(BORDER_W)
	sb.set_corner_radius_all(PILL_RADIUS)
	sb.content_margin_left = 10
	sb.content_margin_top = 4
	sb.content_margin_right = 10
	sb.content_margin_bottom = 4
	sb.anti_aliasing = true
	return sb

# Translucent overlay for hover / pressed / flash states on a chip cell.
static func cell_style(bg: Color, radius: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(0)
	return sb

# Returns a SystemFont with a sensible chain for "display" (UI sans). The
# spec calls for Space Grotesk; production builds can drop a TTF in
# user://fonts/ to override. For now we fall back to the platform's
# preferred sans-serif which keeps the layout consistent without needing
# to ship font assets alongside the spec change.
static func font_display(weight: int = 600) -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray([
		"Space Grotesk", "Inter", "SF Pro Display", "Segoe UI", "Helvetica", "Arial",
	])
	f.font_weight = weight
	return f

# Mono font with a similar fallback chain. JetBrains Mono → fallbacks.
static func font_mono(weight: int = 500) -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray([
		"JetBrains Mono", "Consolas", "Menlo", "DejaVu Sans Mono", "Courier New",
	])
	f.font_weight = weight
	return f

# Apply a pre-rendered text glow via duplicate Label trick — pass a parent
# `Control` and a label config; returns the parent so callers can append it
# to their own layout. Two Labels stacked: one for glow (modulate.a low,
# scale slightly larger for blur effect), one foreground.
#
# This is a poor-man's text-shadow approximation since Godot's Label
# doesn't support multi-pass blur out of the box. For higher fidelity the
# theme could later swap in a shader, but the layered Label trick reads
# acceptably at the 40-px headline size used by balance + position card.
static func make_glow_label(text: String, font: Font, size: int,
		fg: Color, glow: Color) -> Control:
	var wrap := Control.new()
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var blur := Label.new()
	blur.text = text
	blur.add_theme_font_override("font", font)
	blur.add_theme_font_size_override("font_size", size)
	blur.add_theme_color_override("font_color", glow)
	blur.modulate = Color(1, 1, 1, 0.55)
	blur.set_anchors_preset(Control.PRESET_FULL_RECT)
	blur.scale = Vector2(1.04, 1.04)
	blur.pivot_offset = Vector2(0.5, 0.5)
	wrap.add_child(blur)

	var fore := Label.new()
	fore.text = text
	fore.add_theme_font_override("font", font)
	fore.add_theme_font_size_override("font_size", size)
	fore.add_theme_color_override("font_color", fg)
	fore.set_anchors_preset(Control.PRESET_FULL_RECT)
	wrap.add_child(fore)

	wrap.set_meta("blur_label", blur)
	wrap.set_meta("fore_label", fore)
	return wrap

# Recolour both layers of a make_glow_label result. Crossfade by tween-ing
# `font_color` overrides via add_theme_color_override.
static func set_glow_colours(node: Control, fg: Color, glow: Color) -> void:
	var fore := node.get_meta("fore_label", null) as Label
	var blur := node.get_meta("blur_label", null) as Label
	if fore != null:
		fore.add_theme_color_override("font_color", fg)
	if blur != null:
		blur.add_theme_color_override("font_color", glow)

static func set_glow_text(node: Control, text: String) -> void:
	var fore := node.get_meta("fore_label", null) as Label
	var blur := node.get_meta("blur_label", null) as Label
	if fore != null:
		fore.text = text
	if blur != null:
		blur.text = text
