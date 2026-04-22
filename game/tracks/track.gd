class_name Track
extends Node3D

# Base class for runnable tracks. A Track exposes segment-level geometry
# (position, basis, forward/right/up, length) and a whole-track AABB. SpawnRail,
# FinishLine, and FixedCamera read from a Track instance to place themselves,
# so a new track just needs to subclass this and return its own segments.
#
# Two usage modes:
#   (1) Added to the scene tree — _ready() builds the StaticBody3D children.
#   (2) Plain RefCounted-style math object (e.g. inside the verifier) — callers
#       go through the accessors below; meta is computed lazily on first access.
#
# Subclasses override every virtual method below. The base returns empty/zero
# so a missing override shows up loudly rather than silently breaking physics.

func get_width() -> float:
	return 0.0

func segment_count() -> int:
	return 0

func segment_meta(_i: int) -> Dictionary:
	return {}

func segment_surface_point(_i: int, _forward_offset: float) -> Vector3:
	return Vector3.ZERO

func track_bounds() -> AABB:
	return AABB()
