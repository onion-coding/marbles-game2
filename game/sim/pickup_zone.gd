class_name PickupZone
extends Area3D

# A geometric pickup zone that grants a multiplier to marbles passing through.
# Designed for the M15 payout v2 model (see docs/math-model.md):
#   - Tier 1 (2×) zones: max 4 marbles per round can collect.
#   - Tier 2 (3×) zones: max 1 marble per round can collect.
#
# Cap enforcement is per-zone — a zone "saturates" after N marbles enter and
# rejects further pickups. With multiple zones in a track, the AGGREGATE cap
# (4 Tier 1, 1 Tier 2 across the whole map) is enforced at status-write time
# by main.gd's `_aggregate_pickups()` (which sorts by tick and trims).
#
# Determinism:
#   - The zone's geometry is set in track _ready() — static.
#   - body_entered fires when a marble's collision box first crosses the zone.
#   - Physics is deterministic from server_seed → SHA-256-derived spawn slots
#     → identical trajectories every time → same marbles enter the same zones
#     in the same order. Replay-stable by construction.
#
# Tier 2 activation:
#   - Each round, the server derives a Tier-2-active flag from
#     `DeriveTier2Active(seed, round_id)` (see server/rgs/multiplier.go).
#   - Godot ALWAYS records pickups regardless. The server applies the
#     activation flag at payoff time to keep the manifest replay-stable
#     ("what physically happened" vs "what counted for payouts").

# Tier IDs match the math-model. Hard-coded constants instead of an
# @export_enum so subclasses can't accidentally drift.
const TIER_1: int = 1   # 2× multiplier, max 4 marbles per zone
const TIER_2: int = 2   # 3× multiplier, max 1 marble per zone

const MULT_TIER_1: float = 2.0
const MULT_TIER_2: float = 3.0
const MAX_TIER_1: int = 4
const MAX_TIER_2: int = 1

# Set by the track at construction (see TrackBlocks.add_pickup_zone). Once
# set, do not mutate at runtime — would break replay determinism.
var tier: int = TIER_1

# Internal: marble_index → tick of first entry. First N marbles to cross
# get added; subsequent ones are ignored (zone saturated).
var _collected: Dictionary = {}

func _ready() -> void:
	monitoring = true
	monitorable = false      # zones don't trigger each other's signals
	# Bodies are RigidBody3D marbles — non-marble bodies are ignored in the
	# handler below.
	body_entered.connect(_on_body_entered)

# Public — physical multiplier this zone grants.
func get_multiplier() -> float:
	return MULT_TIER_2 if tier == TIER_2 else MULT_TIER_1

# Public — per-zone cap (max marbles that can collect from this zone).
func get_cap() -> int:
	return MAX_TIER_2 if tier == TIER_2 else MAX_TIER_1

# Returns marble_index → tick map of marbles that collected this zone.
# Used by main.gd's pickup aggregator at race finalize time.
func get_collected() -> Dictionary:
	return _collected

func _on_body_entered(body: Node) -> void:
	if not body is RigidBody3D:
		return
	var marble_name := String(body.name)
	if not marble_name.begins_with("Marble_"):
		return
	var idx_str := marble_name.trim_prefix("Marble_")
	if not idx_str.is_valid_int():
		return
	var marble_idx := int(idx_str)
	# Skip if this marble already collected from THIS zone (prevent double-
	# count from a single body re-entering after a bounce). The aggregate
	# cap ("max 4 Tier 1 across all zones") is enforced post-race in main.gd.
	if _collected.has(marble_idx):
		return
	if _collected.size() >= get_cap():
		# Zone saturated — first N marbles took the pickup, this one comes
		# too late. Replay-deterministic because tick order is deterministic.
		return
	var tick: int = Engine.get_physics_frames()
	_collected[marble_idx] = tick
