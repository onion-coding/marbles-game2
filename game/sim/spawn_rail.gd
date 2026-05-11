class_name SpawnRail
extends RefCounted

# Discrete spawn slots for the fairness-ordered marbles. The positions
# themselves are track-defined (see Track.spawn_points()) — this class only
# owns the drop-order stagger applied on top, so marbles don't overlap
# vertically at t=0.
#
# SLOT_COUNT is the LEGACY DEFAULT (32) preserved for replay decode of
# tracks that haven't expanded their spawn grid. Per-track size is now
# read from `_points.size()` via `slot_count()`. Bumping a track's slot
# count is fairness-visible: the hash-to-slot mapping for that track
# changes, so old replays for that track decode against the old layout
# and new replays use the new one. The verifier reads slot_count_for via
# the track instance, so it stays in sync.

const SLOT_COUNT := 32
const Y_CLEARANCE := 0.5       # world +Y gap above the surface for drop_order 0
const Y_STAGGER := 0.12        # per-drop-order world +Y step; keeps the column short

var _points: Array

func _init(track: Track) -> void:
	_points = track.spawn_points()
	assert(_points.size() >= 1,
		"track.spawn_points() returned %d entries, expected at least 1" % _points.size())

func slot_position(slot: int, drop_order: int) -> Vector3:
	return _points[slot] + Vector3(0.0, Y_CLEARANCE + float(drop_order) * Y_STAGGER, 0.0)

# Effective slot count for fairness derivation. Replaces the hardcoded
# SpawnRail.SLOT_COUNT lookup at the callsites; reading this lets each
# track expand its spawn grid (e.g. plinko 32 → 60) without touching
# every other track.
func slot_count() -> int:
	return _points.size()
