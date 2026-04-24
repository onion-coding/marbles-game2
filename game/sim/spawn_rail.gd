class_name SpawnRail
extends RefCounted

# Discrete spawn slots for the fairness-ordered marbles. The positions
# themselves are track-defined (see Track.spawn_points()) — this class only
# owns the drop-order stagger applied on top, so marbles don't overlap
# vertically at t=0.
#
# SLOT_COUNT is part of the fairness protocol — changing it changes which
# server_seed hashes to which slot, which re-derives as a different race.
# It's a class-level const (not per-track) because the fairness verifier
# needs to read it without instantiating a track.

const SLOT_COUNT := 24
const Y_CLEARANCE := 0.5       # world +Y gap above the surface for drop_order 0
const Y_STAGGER := 0.12        # per-drop-order world +Y step; keeps the column short

var _points: Array

func _init(track: Track) -> void:
	_points = track.spawn_points()
	assert(_points.size() == SLOT_COUNT, "track.spawn_points() returned %d entries, expected %d" % [_points.size(), SLOT_COUNT])

func slot_position(slot: int, drop_order: int) -> Vector3:
	return _points[slot] + Vector3(0.0, Y_CLEARANCE + float(drop_order) * Y_STAGGER, 0.0)
