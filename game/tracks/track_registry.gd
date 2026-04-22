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
# Reserved, added as each casino track ships:
# const ROULETTE := 1
# const CRAPS    := 2
# const POKER    := 3
# const SLOTS    := 4
# const PLINKO   := 5

# Track IDs currently available for selection by roundd. Grows as casino
# tracks ship. The live/playback paths accept any registered ID — this is
# just the "rotation pool" the server picks from.
const SELECTABLE := [RAMP]

static func count() -> int:
	return SELECTABLE.size()

static func is_valid_id(id: int) -> bool:
	# Any ID ever shipped is valid for decode. Only SELECTABLE are picked
	# by the server for new rounds.
	match id:
		RAMP:
			return true
		_:
			return false

static func instance(id: int) -> Track:
	match id:
		RAMP:
			return RampTrack.new()
		_:
			push_error("TrackRegistry: unknown track_id=%d — falling back to RampTrack" % id)
			return RampTrack.new()

static func name_of(id: int) -> String:
	match id:
		RAMP:
			return "RampTrack"
		_:
			return "unknown(%d)" % id
