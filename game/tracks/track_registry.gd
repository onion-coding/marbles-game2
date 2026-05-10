class_name TrackRegistry
extends Object

# Maps a track_id (u8 in the replay format) to a concrete Track subclass.
# Adding a new track = appending a new constant + a new match arm. IDs are
# wire-format-visible (see docs/tick-schema.md §v3) and MUST stay stable
# across versions — never renumber or delete an existing ID, that would
# silently reinterpret old replays as a different track.
#
# track_id = 0 is RampTrack, the dev/default S-curve that carried the
# project through M5. It stays reserved at 0 indefinitely so pre-M6 replays
# (once upgraded to v3 headers) still map to the right geometry. Casino
# tracks land at IDs 1–5 in M6.1–M6.5.

const RAMP := 0
const ROULETTE := 1
const CRAPS := 2
const POKER := 3
const SLOTS := 4
const PLINKO := 5
const STADIUM := 6
# Phase 6 prototypes — geometrically distinct silhouettes (M23+).
# Not in SELECTABLE until validated end-to-end.
const SERPENT := 7
const SPIRAL_DROP := 8
# Demo / proof-of-quality: smooth procedurally-swept half-pipe slide. Builds
# its geometry via ArrayMesh + parallel-transport frames + smooth normals so
# the curved surface has no box-faceting and lights cleanly. Not in
# SELECTABLE — invoked explicitly via --track=curve_demo.
const CURVE_DEMO := 9

# Track IDs currently available for selection by roundd / random pick.
# Six M11 themed tracks (forest/volcano/ice/cavern/sky/stadium). The legacy
# RAMP (id 0) stays a valid ID for replay decode (is_valid_id below) but is
# NOT in the random rotation pool — it was the dev/default S-curve from M5
# and doesn't fit the M11 visual language.
# SERPENT (7) is a Phase-6 prototype, kept out of the pool until approved.
const SELECTABLE := [ROULETTE, CRAPS, POKER, SLOTS, PLINKO, STADIUM]

static func count() -> int:
	return SELECTABLE.size()

static func is_valid_id(id: int) -> bool:
	# Any ID ever shipped is valid for decode. Only SELECTABLE are picked
	# by the server for new rounds.
	match id:
		RAMP, ROULETTE, CRAPS, POKER, SLOTS, PLINKO, STADIUM, SERPENT, SPIRAL_DROP, CURVE_DEMO:
			return true
		_:
			return false

static func instance(id: int) -> Track:
	match id:
		RAMP:
			return RampTrack.new()
		ROULETTE:
			return RouletteTrack.new()
		CRAPS:
			return CrapsTrack.new()
		POKER:
			return PokerTrack.new()
		SLOTS:
			return SlotsTrack.new()
		PLINKO:
			return PlinkoTrack.new()
		STADIUM:
			return StadiumTrack.new()
		SERPENT:
			return SerpentTrack.new()
		SPIRAL_DROP:
			return SpiralDropTrack.new()
		CURVE_DEMO:
			return CurveDemoTrack.new()
		_:
			push_error("TrackRegistry: unknown track_id=%d — falling back to RampTrack" % id)
			return RampTrack.new()

static func name_of(id: int) -> String:
	match id:
		RAMP:
			return "RampTrack"
		ROULETTE:
			return "RouletteTrack"
		CRAPS:
			return "CrapsTrack"
		POKER:
			return "PokerTrack"
		SLOTS:
			return "SlotsTrack"
		PLINKO:
			return "PlinkoTrack"
		STADIUM:
			return "StadiumTrack"
		SERPENT:
			return "SerpentTrack"
		SPIRAL_DROP:
			return "SpiralDropTrack"
		CURVE_DEMO:
			return "CurveDemoTrack"
		_:
			return "unknown(%d)" % id
