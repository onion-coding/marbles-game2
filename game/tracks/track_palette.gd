class_name TrackPalette
extends Object

# Centralised colour + atmosphere themes for each track.
#
# Each track has a distinct visual identity — palette, sky, sun colour,
# fog tint — so a player watching back-to-back rounds always knows which
# track they're on without reading the HUD label. Themes target broadcast-
# style readability (Marbles-On-Stream / Jelle's Marble Runs feel) rather
# than photorealism.
#
# Tracks call TrackPalette.theme_for(track_id) to get the dictionary of
# parameters; they pluck the keys they need (floor colours, sky overrides,
# physics-material colours, etc.). Adding a new theme = adding an entry to
# THEMES below.
#
# Keys per theme:
#   floor_a, floor_b, floor_c, floor_d  : Color — main floor / ramp tints
#   peg                                 : Color — obstacle / peg colour
#   gate                                 : Color — finish-gate colour
#   wall                                 : Color — outer-frame near-black
#   accent                               : Color — neon stripes / curbs / highlights
#   env                                 : Dictionary — environment_overrides() result
#                                                     for this theme

const _STADIUM := {
	"floor_a": Color(0.85, 0.72, 0.20),   # gold catch
	"floor_b": Color(0.75, 0.10, 0.10),   # red velvet ramp
	"floor_c": Color(0.95, 0.95, 0.97),   # white ramp
	"floor_d": Color(0.20, 0.45, 0.85),   # blue ramp
	"peg":     Color(0.92, 0.96, 1.00),   # chrome
	"gate":    Color(0.92, 0.78, 0.18),   # finish gold
	"wall":    Color(0.10, 0.10, 0.14),   # near-black
	"accent":  Color(1.00, 0.05, 0.85),   # magenta neon
	"env": {
		"sky_top":        Color(0.22, 0.40, 0.78),
		"sky_horizon":    Color(0.92, 0.72, 0.45),
		"ambient_energy": 0.95,
		"fog_color":      Color(0.85, 0.72, 0.55),
		"fog_density":    0.0010,
		"sun_color":      Color(1.0, 0.85, 0.60),
		"sun_energy":     1.6,
	},
}

const _FOREST := {
	"floor_a": Color(0.20, 0.50, 0.18),   # moss green
	"floor_b": Color(0.45, 0.30, 0.12),   # bark brown
	"floor_c": Color(0.30, 0.55, 0.22),   # leaf green
	"floor_d": Color(0.55, 0.42, 0.18),   # warm wood
	"peg":     Color(0.58, 0.40, 0.20),   # tree-trunk wood
	"gate":    Color(0.85, 0.65, 0.18),   # warm gold gate
	"wall":    Color(0.06, 0.10, 0.06),   # forest-floor dark
	"accent":  Color(1.00, 0.80, 0.30),   # firefly yellow
	"env": {
		"sky_top":        Color(0.30, 0.55, 0.30),
		"sky_horizon":    Color(0.78, 0.85, 0.55),
		"ambient_energy": 0.85,
		"fog_color":      Color(0.50, 0.65, 0.45),
		"fog_density":    0.0018,
		"sun_color":      Color(0.95, 0.95, 0.65),
		"sun_energy":     1.4,
	},
}

const _VOLCANO := {
	"floor_a": Color(0.60, 0.10, 0.05),   # lava red
	"floor_b": Color(0.20, 0.10, 0.08),   # cooled basalt
	"floor_c": Color(0.85, 0.30, 0.05),   # molten orange
	"floor_d": Color(0.30, 0.10, 0.05),   # dark red rock
	"peg":     Color(0.15, 0.10, 0.08),   # obsidian
	"gate":    Color(1.00, 0.45, 0.10),   # bright lava
	"wall":    Color(0.06, 0.04, 0.04),   # volcanic black
	"accent":  Color(1.00, 0.60, 0.10),   # ember glow
	"env": {
		"sky_top":        Color(0.20, 0.05, 0.05),
		"sky_horizon":    Color(0.85, 0.25, 0.08),
		"ambient_energy": 0.50,
		"fog_color":      Color(0.40, 0.15, 0.08),
		"fog_density":    0.0030,
		"sun_color":      Color(1.00, 0.55, 0.20),
		"sun_energy":     2.0,
	},
}

const _ICE := {
	"floor_a": Color(0.80, 0.90, 1.00),   # ice white
	"floor_b": Color(0.55, 0.78, 0.92),   # glacier blue
	"floor_c": Color(0.92, 0.95, 1.00),   # snow white
	"floor_d": Color(0.30, 0.55, 0.78),   # deep ice
	"peg":     Color(0.75, 0.92, 1.00),   # crystal
	"gate":    Color(0.45, 0.85, 1.00),   # ice neon
	"wall":    Color(0.08, 0.12, 0.18),   # midnight ice
	"accent":  Color(0.30, 0.85, 1.00),   # cyan accent
	"env": {
		"sky_top":        Color(0.20, 0.32, 0.55),
		"sky_horizon":    Color(0.65, 0.80, 0.95),
		"ambient_energy": 1.10,
		"fog_color":      Color(0.70, 0.85, 0.95),
		"fog_density":    0.0014,
		"sun_color":      Color(0.85, 0.92, 1.00),
		"sun_energy":     1.3,
	},
}

const _CAVERN := {
	"floor_a": Color(0.18, 0.10, 0.30),   # deep purple
	"floor_b": Color(0.08, 0.20, 0.30),   # teal cave
	"floor_c": Color(0.25, 0.08, 0.40),   # crystal purple
	"floor_d": Color(0.10, 0.15, 0.20),   # dark stone
	"peg":     Color(0.55, 0.30, 0.85),   # crystal pillar
	"gate":    Color(0.85, 0.30, 0.95),   # crystal magenta
	"wall":    Color(0.04, 0.04, 0.08),   # cavern black
	"accent":  Color(0.50, 0.95, 0.90),   # bioluminescent teal
	"env": {
		"sky_top":        Color(0.05, 0.04, 0.10),
		"sky_horizon":    Color(0.20, 0.10, 0.30),
		"ambient_energy": 0.55,
		"fog_color":      Color(0.20, 0.12, 0.30),
		"fog_density":    0.0040,
		"sun_color":      Color(0.65, 0.55, 1.00),
		"sun_energy":     1.0,
	},
}

const _SKY := {
	"floor_a": Color(0.92, 0.92, 0.98),   # cloud white
	"floor_b": Color(0.65, 0.85, 1.00),   # sky blue
	"floor_c": Color(0.95, 0.85, 0.55),   # sunny gold
	"floor_d": Color(0.55, 0.78, 0.95),   # cyan
	"peg":     Color(0.95, 0.95, 1.00),   # cloud pillar
	"gate":    Color(1.00, 0.85, 0.30),   # sun gold gate
	"wall":    Color(0.12, 0.18, 0.28),   # high-altitude shadow
	"accent":  Color(1.00, 0.95, 0.55),   # sun gold accent
	"env": {
		"sky_top":        Color(0.30, 0.55, 0.95),
		"sky_horizon":    Color(0.95, 0.92, 0.78),
		"ambient_energy": 1.20,
		"fog_color":      Color(0.85, 0.90, 1.00),
		"fog_density":    0.0008,
		"sun_color":      Color(1.00, 0.95, 0.70),
		"sun_energy":     1.7,
	},
}

# Track-id keyed dispatch. Keep this in sync with TrackRegistry constants.
const _BY_ID := {
	0: _STADIUM,    # legacy RAMP placeholder — gets stadium look until rebuilt
	1: _FOREST,     # was ROULETTE → now Forest Run
	2: _VOLCANO,    # was CRAPS    → now Volcano Run
	3: _ICE,        # was POKER    → now Ice Run
	4: _CAVERN,     # was SLOTS    → now Cavern Run
	5: _SKY,        # was PLINKO   → now Sky Run
	6: _STADIUM,    # STADIUM
}

static func theme_for(track_id: int) -> Dictionary:
	if _BY_ID.has(track_id):
		return _BY_ID[track_id]
	return _STADIUM

static func env_for(track_id: int) -> Dictionary:
	return theme_for(track_id).get("env", {})
