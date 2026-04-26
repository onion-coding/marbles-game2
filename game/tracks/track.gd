class_name Track
extends Node3D

# Base class for runnable tracks. A Track exposes only what the fairness-agnostic
# scaffolding (SpawnRail, FinishLine, FixedCamera) needs — everything else is
# free to be track-specific, including moving obstacles, per-track physics
# materials, cinematic hooks, and lighting.
#
# Two usage modes:
#   (1) Added to the scene tree — subclasses build their own bodies / visuals in
#       _ready() or by loading a .tscn scene.
#   (2) Plain math object (e.g. inside the verifier) — callers go through the
#       accessors below without adding the Track to the tree. Subclasses that
#       compute geometry lazily should gate it behind a single guard so the
#       verifier path doesn't spawn physics bodies.
#
# Subclasses override every method below. Base returns empty/zero so a missing
# override shows up loudly (0-length spawn list, empty AABB) rather than
# silently breaking physics.

# Round context. Tracks with deterministic-but-variable obstacle motion (dice in
# Craps, coin cascade in Slots) hash these to seed obstacle paths so each round
# looks different while remaining replay-stable. Tracks with fully static
# geometry (RampTrack, Plinko peg forest) ignore them.
#
# Caller MUST invoke configure() after instance() and before add_child() so
# subclasses can use _round_id / _server_seed during _ready(). Defaults are
# zero so a missing call doesn't crash, but obstacle motion will be uniform
# across rounds.
var _round_id: int = 0
var _server_seed: PackedByteArray = PackedByteArray()

func configure(round_id: int, server_seed: PackedByteArray) -> void:
	_round_id = round_id
	_server_seed = server_seed

# Base positions for the fairness-ordered spawn slots. Length MUST equal
# SpawnRail.SLOT_COUNT. Each returned Vector3 is the resting world-space point
# for that slot index; SpawnRail applies a world-Y stagger on top for
# drop-order so marbles don't overlap at t=0.
func spawn_points() -> Array:
	return []

# World transform of the finish-line area. Origin = center of the trigger
# volume, basis = axes for the BoxShape3D. The FinishLine Area3D is placed
# with this transform verbatim.
func finish_area_transform() -> Transform3D:
	return Transform3D()

# Size of the finish-line BoxShape3D (width, height, thickness) in the
# transform's local frame. Returned separately from the transform because
# Godot's Transform3D conventionally doesn't carry a "size" component.
func finish_area_size() -> Vector3:
	return Vector3.ZERO

# Axis-aligned bounding box of the full track in world coords, used by the
# camera to frame the shot. Should include moving obstacles' reachable
# volume so none of the action is clipped out of frame.
func camera_bounds() -> AABB:
	return AABB()

# Helper for subclasses: hash (server_seed || round_id || tag) → 32 bytes.
# Use to derive deterministic-but-varying obstacle parameters (dice initial
# velocity, peg row offsets, etc.) that are stable per round.
func _hash_with_tag(tag: String) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	if not _server_seed.is_empty():
		ctx.update(_server_seed)
	var rid_bytes := PackedByteArray()
	rid_bytes.resize(8)
	for i in range(8):
		rid_bytes[7 - i] = (_round_id >> (i * 8)) & 0xFF
	ctx.update(rid_bytes)
	ctx.update(tag.to_utf8_buffer())
	return ctx.finish()
