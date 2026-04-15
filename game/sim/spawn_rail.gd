class_name SpawnRail
extends RefCounted

# Discrete spawn slots at the uphill end of the ramp.
# Slots are ordered left→right across the usable width; marbles are assigned
# to slots via the fairness hash (see game/fairness/seed.gd).

const SLOT_COUNT := 24
const Z_BASE := 14.0        # uphill end
const Y_BASE := 5.8
const Y_STAGGER := 0.35     # per-drop-order step so marbles don't spawn on top of each other
const EDGE_MARGIN := 0.4    # keep slots off the side walls

static func slot_position(slot: int, drop_order: int) -> Vector3:
	var usable := RampTrack.WIDTH - 2.0 * EDGE_MARGIN
	var x := -RampTrack.WIDTH * 0.5 + EDGE_MARGIN + float(slot) * (usable / float(SLOT_COUNT - 1))
	var y := Y_BASE + float(drop_order) * Y_STAGGER
	return Vector3(x, y, Z_BASE)
