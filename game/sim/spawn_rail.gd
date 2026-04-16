class_name SpawnRail
extends RefCounted

# Discrete spawn slots at the uphill end of the first track segment.
# Slots are ordered left→right across the usable width; marbles are assigned
# to slots via the fairness hash (see game/fairness/seed.gd).

const SLOT_COUNT := 24
const EDGE_MARGIN := 0.4       # keep slots off the side walls
const UPHILL_MARGIN := 4.0     # distance from segment 0's uphill edge so marbles have runway before it
const Y_CLEARANCE := 0.5       # gap above the ramp surface for drop_order 0
const Y_STAGGER := 0.12        # per-drop-order step; keeps the spawn column short

static func slot_position(slot: int, drop_order: int) -> Vector3:
	var meta := RampTrack.segment_meta(0)
	var right: Vector3 = meta["right"]
	var up: Vector3 = meta["up"]
	var length: float = meta["length"]

	# Surface point at the uphill end of segment 0, UPHILL_MARGIN in from the edge.
	var forward_offset := -(length * 0.5 - UPHILL_MARGIN)
	var surface := RampTrack.segment_surface_point(0, forward_offset)

	var usable := RampTrack.WIDTH - 2.0 * EDGE_MARGIN
	var slot_x := -RampTrack.WIDTH * 0.5 + EDGE_MARGIN + float(slot) * (usable / float(SLOT_COUNT - 1))
	var lateral := right * slot_x
	var vertical := up * (Y_CLEARANCE + float(drop_order) * Y_STAGGER)
	return surface + lateral + vertical
