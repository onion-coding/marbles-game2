class_name StadiumTrack
extends Track

# StadiumTrack — "Stadium Cascade"
#
# First track built under the post-M6 design philosophy: real gravity
# (9.8 m/s²), no SLOW_GRAVITY hack, marble dynamics from track structure
# instead of from artificially slow physics. Reliable drop-cascade design:
# six horizontal floors stacked vertically, each with a directed gap that
# marbles roll toward and drop through. No banked curves, no tilted basis
# compositions — every floor is a flat box rotated only around the Z axis
# by a single shallow angle, with a rectangular gap at one end.
#
# Smoke result: race finishes ~30s, fairness verifier passes, replay
# round-trip OK. Variance comes from spawn slot derivation (different
# seeds → different starting positions → different bounce paths → different
# winners), not from kinematic obstacles. Deterministic by construction.
#
# Cascade:
#   y=40   spawn (24 slots in a 13×3 grid)
#   ─────
#   F1   wide flat catch (gap centered, 4 m × full depth)
#   ─────  drop 5 m
#   F2   left-tilted ramp → gap on the +X side
#   ─────  drop 5 m
#   F3   right-tilted ramp → gap on the -X side
#   ─────  drop 5 m
#   F4   left-tilted ramp → gap on the +X side
#   ─────  drop 5 m
#   F5   peg forest (6 rows × 5 cols hex grid)
#   ─────  drop 5 m
#   F6   12-lane finish gate
#
# Total vertical drop ~35 m, full track 40 m wide × 5 m deep. Real gravity
# gives a 25–45 s race (varies by spawn slot + peg bounce luck).
#
# Determinism: geometry is fully static. Round seed not consumed by this
# track; obstacle motion zero. Replay-stable by construction.

# ─── World layout ────────────────────────────────────────────────────────────
const FIELD_W      := 40.0           # X-axis full width
const FIELD_DEPTH  := 5.0            # Z-axis depth
const WALL_THICK   := 0.5
const FLOOR_THICK  := 0.5
const SIDE_WALL_H  := 2.5

# ─── Vertical layout (Y) ─────────────────────────────────────────────────────
const SPAWN_Y      := 40.0
const F1_Y         := 38.0           # floor surface y
const F2_Y         := 32.0
const F3_Y         := 26.0
const F4_Y         := 20.0
const F5_TOP_Y     := 14.0           # peg forest top
const F5_BOT_Y     := 4.0            # peg forest bottom
const F6_Y         := 0.0            # gate floor surface
const FLOOR_BASE_Y := -6.0           # catchment floor (well below gate)

# ─── Floor 1: wide flat catch with center gap ────────────────────────────────
const F1_GAP_W     := 4.0            # 4 m wide gap at center (x in [-2, +2])

# ─── Floors 2-4: tilted ramps with side gaps ─────────────────────────────────
# Each ramp is one box, tilted 8° around Z, with a rectangular gap cut at
# one end. We model the gap by building TWO rectangular slabs separated
# by a gap, instead of cutting a hole.
const TILT_DEG     := 8.0            # mild tilt — marbles roll predictably
const RAMP_GAP_W   := 4.0            # gap at one side, marbles roll into it

# F2: tilts down toward +X, gap on +X side
# F3: tilts down toward -X, gap on -X side
# F4: same as F2
const _F2_DIR := 1     # +1 = gap on +X end
const _F3_DIR := -1    # -1 = gap on -X end
const _F4_DIR := 1

# ─── Floor 5: peg forest ─────────────────────────────────────────────────────
# Spans the full field width so marbles arriving at the edges (after the F2-F4
# ramps push them sideways) still hit pegs and can't bypass to the gate below.
const F5_PEG_RADIUS := 0.6
const F5_PEG_HEIGHT := FIELD_DEPTH   # cylinder along Z, spans depth
const F5_ROWS       := 6
const F5_COLS       := 9             # was 5; widened to cover full 40m field
const F5_ROW_SPACING := (F5_TOP_Y - F5_BOT_Y) / float(F5_ROWS + 1)  # ≈ 1.43 m
const F5_COL_SPACING := 4.5          # 4.5 × 9 = 40.5 m, just covers FIELD_W

# ─── Floor 6: finish gate (full field width) ─────────────────────────────────
# Gate spans the full field so any marble surviving the cascade lands on it,
# regardless of which side gap it dropped through.
const F6_GATE_W     := FIELD_W       # 40 m — full field
const F6_LANES      := 20            # 1 lane per spawn slot, 2m per lane
const F6_LANE_W     := F6_GATE_W / float(F6_LANES)   # 2 m per lane
const F6_DIVIDER_H  := 1.5
const F6_DIVIDER_T  := 0.15

# ─── Finish line ─────────────────────────────────────────────────────────────
# Box spans the full field width and stretches up well above the gate floor
# so any marble approaching the gate from above triggers body_entered. The
# tall vertical extent also catches marbles in flight (mid-air arrivals).
const FINISH_Y_OFF  := 2.5           # finish box center 2.5 m above gate floor
const FINISH_BOX    := Vector3(FIELD_W + 2.0, 5.0, FIELD_DEPTH + 1.0)

# ─── Spawn (24 slots) ────────────────────────────────────────────────────────
const SPAWN_COLS := 8
const SPAWN_ROWS := 3
const SPAWN_DX   := 1.6              # 8 cols × 1.6 = 12.8 m wide spread
const SPAWN_DZ   := 1.0

# ─── Materials (colours per floor for visual differentiation) ────────────────
const COL_F1     := Color(0.85, 0.72, 0.20)   # gold
const COL_F2     := Color(0.75, 0.10, 0.10)   # red velvet
const COL_F3     := Color(0.95, 0.95, 0.97)   # white
const COL_F4     := Color(0.20, 0.45, 0.85)   # blue
const COL_F5_PEG := Color(0.92, 0.96, 1.00)   # chrome
const COL_F6     := Color(0.92, 0.78, 0.18)   # finish gold
const COL_WALL   := Color(0.10, 0.10, 0.14)   # near-black frame

# ─── Stadium unique mechanic: spinning windmill paddle ──────────────────────
# A 4-blade horizontal cross-shaped paddle at the centre of the F5 zone,
# rotating around the world Y axis at a seed-derived ω. Marbles falling
# through F5 encounter the spinning blades and get sent sideways.
const WINDMILL_BLADE_LEN  := 6.0    # half-length × 2 = full span
const WINDMILL_BLADE_H    := 0.4
const WINDMILL_BLADE_T    := 0.4    # thickness along blade-perpendicular X
const WINDMILL_Y          := 9.0    # mid F5 zone (top=14, bot=4 → center 9)
const WINDMILL_OMEGA_MAX  := 1.4    # rad/s magnitude cap (≈4.5 s/rev)
const WINDMILL_OMEGA_MIN  := 0.5

var _mat_floor:    PhysicsMaterial = null
var _mat_peg:      PhysicsMaterial = null
var _mat_wall:     PhysicsMaterial = null
var _mat_gate:     PhysicsMaterial = null
var _mat_windmill: PhysicsMaterial = null

# Windmill state.
var _windmill: AnimatableBody3D = null
var _windmill_omega: float = 0.0
var _windmill_time: float = 0.0

func _ready() -> void:
	_init_physics_materials()
	_build_outer_walls()
	_build_floor1()
	_build_floor2_ramp(_F2_DIR, F2_Y, COL_F2)
	_build_floor2_ramp(_F3_DIR, F3_Y, COL_F3)
	_build_floor2_ramp(_F4_DIR, F4_Y, COL_F4)
	_build_floor5_peg_forest()
	_build_stadium_windmill()
	_build_floor6_gate()
	_build_catchment_floor()
	_build_pickup_zones()
	_build_mood_lights()

# M19 — Stadium pickup zones (broadcast-gold theme). The windmill at
# y=WINDMILL_Y=9 sweeps blades in a horizontal disc with span 6m radius.
# Tier 1 zones at y=11 (above the windmill plane) are clear of the
# kinematic sweep; T2 at y=6.5 is below the sweep plane. Both are Area3D
# and filter to RigidBody3D marbles, so the AnimatableBody3D windmill
# wouldn't trigger them anyway — placement is for marble-traffic
# alignment, not collision avoidance.
func _build_pickup_zones() -> void:
	var t1_mat := TrackBlocks.std_mat_emit(
		Color(1.00, 0.85, 0.30, 0.30),    # broadcast-gold semi-transparent
		0.0, 0.45, 0.70)
	t1_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var t2_mat := TrackBlocks.std_mat_emit(
		Color(1.00, 0.55, 0.10, 0.45),    # bright amber semi-transparent
		0.0, 0.30, 1.10)
	t2_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	const TIER1_SIZE := Vector3(3.0, 1.5, FIELD_DEPTH - 0.4)
	const TIER1_Y    := 11.0    # above windmill (y=9), below F5 top (y=14)
	const TIER1_XS   := [-12.0, -4.0, 4.0, 12.0]
	for i in range(TIER1_XS.size()):
		var x: float = float(TIER1_XS[i])
		TrackBlocks.add_pickup_zone(self, "PickupT1_%d" % i,
			Transform3D(Basis.IDENTITY, Vector3(x, TIER1_Y, 0.0)),
			TIER1_SIZE, PickupZone.TIER_1, t1_mat)

	# T2 below the windmill plane, narrow centre zone.
	TrackBlocks.add_pickup_zone(self, "PickupT2",
		Transform3D(Basis.IDENTITY, Vector3(0.0, 6.5, 0.0)),
		Vector3(1.4, 1.5, FIELD_DEPTH - 0.4), PickupZone.TIER_2, t2_mat)

func _physics_process(delta: float) -> void:
	# Drive the windmill rotation around world Y. Constant ω; phase
	# (effective starting orientation) is naturally part of the rotation
	# evolution from the seed-derived ω value.
	if _windmill == null:
		return
	_windmill_time += delta
	var angle: float = _windmill_omega * _windmill_time
	var basis := Basis(Vector3.UP, angle)
	_windmill.global_transform = Transform3D(basis, Vector3(0.0, WINDMILL_Y, 0.0))

func _init_physics_materials() -> void:
	_mat_floor = PhysicsMaterial.new()
	_mat_floor.friction = 0.40
	_mat_floor.bounce   = 0.20

	_mat_peg = PhysicsMaterial.new()
	_mat_peg.friction = 0.25
	_mat_peg.bounce   = 0.55

	_mat_wall = PhysicsMaterial.new()
	_mat_wall.friction = 0.30
	_mat_wall.bounce   = 0.30

	_mat_windmill = PhysicsMaterial.new()
	_mat_windmill.friction = 0.30
	_mat_windmill.bounce   = 0.45

	_mat_gate = PhysicsMaterial.new()
	_mat_gate.friction = 0.55
	_mat_gate.bounce   = 0.10

# ─── Outer frame: side walls + back wall ─────────────────────────────────────
# Two tall walls along the X edges (catch any marble that would escape the
# field laterally) and one back wall (-Z) so marbles can't exit toward
# camera-back. Front (+Z) is left open for camera.

func _build_outer_walls() -> void:
	var wall_mat := _std_mat(COL_WALL, 0.30, 0.70)

	var frame := StaticBody3D.new()
	frame.name = "OuterFrame"
	frame.physics_material_override = _mat_wall
	add_child(frame)

	var top_y    := SPAWN_Y + 3.0
	var bot_y    := FLOOR_BASE_Y - 1.0
	var height   := top_y - bot_y
	var center_y := (top_y + bot_y) * 0.5

	# X side walls (full height)
	for sgn in [-1, 1]:
		var x: float = float(sgn) * (FIELD_W * 0.5 + WALL_THICK * 0.5)
		_add_box(frame, "SideWallX_%s" % ("pos" if sgn > 0 else "neg"),
			Transform3D(Basis.IDENTITY, Vector3(x, center_y, 0.0)),
			Vector3(WALL_THICK, height, FIELD_DEPTH + 0.4),
			wall_mat)

	# Z back wall (full width × height) — collision + mesh as backdrop
	_add_box(frame, "BackWallZ",
		Transform3D(Basis.IDENTITY, Vector3(0.0, center_y, -FIELD_DEPTH * 0.5 - WALL_THICK * 0.5)),
		Vector3(FIELD_W + WALL_THICK * 2.0, height, WALL_THICK),
		wall_mat)

	# Z front wall (collision only — no mesh, camera looks through)
	var front_coll := CollisionShape3D.new()
	front_coll.name = "FrontWallZ_shape"
	var front_box := BoxShape3D.new()
	front_box.size = Vector3(FIELD_W + WALL_THICK * 2.0, height, WALL_THICK)
	front_coll.shape = front_box
	front_coll.transform = Transform3D(Basis.IDENTITY,
		Vector3(0.0, center_y, FIELD_DEPTH * 0.5 + WALL_THICK * 0.5))
	frame.add_child(front_coll)

# ─── Floor 1: wide flat catch with centered gap ──────────────────────────────
# Two rectangular slabs separated by a 4 m centered gap. Marbles drop from
# spawn, hit one of the slabs, roll toward the center gap (slabs are
# slightly tilted toward the gap), and fall through.

func _build_floor1() -> void:
	var floor_mat := _std_mat(COL_F1, 0.85, 0.30)
	var body := StaticBody3D.new()
	body.name = "F1_GoldCatch"
	body.physics_material_override = _mat_floor
	add_child(body)

	# Two slabs, each spanning from ±FIELD_W/2 to ±F1_GAP_W/2.
	var slab_w := (FIELD_W - F1_GAP_W) * 0.5
	var slab_x := (FIELD_W * 0.5 + F1_GAP_W * 0.5) * 0.5    # midpoint of each slab

	for sgn in [-1, 1]:
		var center_x: float = float(sgn) * slab_x
		# Tilt the slab so the gap-side end is lower (marbles roll toward gap).
		# Rotation around +Z by +θ lifts the slab's +X edge UP (right-hand rule:
		# +X → +Y for positive θ). So:
		#   sgn=-1 (left slab, gap on slab's +X side) → want +X edge LOW → θ < 0
		#   sgn=+1 (right slab, gap on slab's -X side) → want -X edge LOW → θ > 0
		# i.e. tilt sign matches sgn.
		var tilt_rad := float(sgn) * deg_to_rad(6.0)
		var basis := Basis(Vector3(0, 0, 1), tilt_rad)
		_add_box(body, "F1_Slab_%s" % ("pos" if sgn > 0 else "neg"),
			Transform3D(basis, Vector3(center_x, F1_Y, 0.0)),
			Vector3(slab_w, FLOOR_THICK, FIELD_DEPTH),
			floor_mat)

# ─── Floors 2/3/4: tilted ramp with gap at one end ───────────────────────────
# A single slab extending across most of the field, tilted around Z so it
# slopes downward toward the gap end. The gap is just empty space — the
# slab simply ends before the field edge on the gap side.
#
#   gap_dir = +1 → gap on +X side → slab spans from -FIELD_W/2 to (FIELD_W/2 - GAP_W)
#                  slab tilts down toward +X (lower at the gap end)
#   gap_dir = -1 → mirror

func _build_floor2_ramp(gap_dir: int, y_pos: float, col: Color) -> void:
	var floor_mat := _std_mat(col, 0.30, 0.50)
	var body := StaticBody3D.new()
	body.name = "Ramp_%s_y%d" % [("Right" if gap_dir > 0 else "Left"), int(y_pos)]
	body.physics_material_override = _mat_floor
	add_child(body)

	# Slab extends across the field minus the gap on the gap-side.
	var slab_w := FIELD_W - RAMP_GAP_W
	# Center X of the slab is shifted away from the gap side.
	var center_x: float = -float(gap_dir) * (RAMP_GAP_W * 0.5)

	# Tilt: gap_dir +1 → slab tilts so +X side is lower. Rotate around +Z by -tilt
	#       gap_dir -1 → -X side is lower. Rotate by +tilt
	var tilt_rad := -float(gap_dir) * deg_to_rad(TILT_DEG)
	var basis := Basis(Vector3(0, 0, 1), tilt_rad)

	_add_box(body, "RampSlab",
		Transform3D(basis, Vector3(center_x, y_pos, 0.0)),
		Vector3(slab_w, FLOOR_THICK, FIELD_DEPTH),
		floor_mat)

	# Curb at the gap-end of the slab — short raised lip so marbles don't
	# accumulate on the slab edge but still get a small bounce going into
	# the gap. Sits at the slab's downhill edge.
	var slab_end_x: float = float(gap_dir) * (slab_w * 0.5) + center_x
	var curb_mat := _std_mat(COL_WALL, 0.30, 0.70)
	_add_box(body, "Curb",
		Transform3D(basis, Vector3(slab_end_x, y_pos + 0.4, 0.0)),
		Vector3(0.3, 0.4, FIELD_DEPTH),
		curb_mat)

# ─── Floor 5: peg forest ─────────────────────────────────────────────────────

func _build_floor5_peg_forest() -> void:
	var peg_mat := _std_mat_emit(COL_F5_PEG, 0.95, 0.18, 0.20)
	var pegs := StaticBody3D.new()
	pegs.name = "F5_PegForest"
	pegs.physics_material_override = _mat_peg
	add_child(pegs)

	for row in range(F5_ROWS):
		var y: float = F5_TOP_Y - F5_ROW_SPACING * float(row + 1)
		# Hex stagger: even rows centered, odd rows offset by half spacing.
		var x_offset: float = 0.0 if (row % 2 == 0) else F5_COL_SPACING * 0.5
		var x_origin: float = -float(F5_COLS - 1) * 0.5 * F5_COL_SPACING + x_offset
		for col in range(F5_COLS):
			var x: float = x_origin + float(col) * F5_COL_SPACING
			# Skip pegs that would clip into the side walls.
			if abs(x) > FIELD_W * 0.5 - F5_PEG_RADIUS - 0.3:
				continue
			# Cylinder along Z (depth axis) — circular cross-section in XY.
			var rot := Basis(Vector3.RIGHT, deg_to_rad(90.0))
			var tx  := Transform3D(rot, Vector3(x, y, 0.0))
			_add_cylinder(pegs, "Peg_r%d_c%d" % [row, col], tx,
				F5_PEG_RADIUS, F5_PEG_HEIGHT, peg_mat)

# ─── Floor 6: 12-lane finish gate ────────────────────────────────────────────

func _build_floor6_gate() -> void:
	var floor_mat := _std_mat(COL_F6, 0.90, 0.25)
	var divider_mat := _std_mat_emit(COL_F6, 0.85, 0.25, 0.50)
	var body := StaticBody3D.new()
	body.name = "F6_Gate"
	body.physics_material_override = _mat_gate
	add_child(body)

	# Gate floor: flat at F6_Y, spans gate width.
	_add_box(body, "GateFloor",
		Transform3D(Basis.IDENTITY, Vector3(0.0, F6_Y, 0.0)),
		Vector3(F6_GATE_W, FLOOR_THICK, FIELD_DEPTH),
		floor_mat)

	# Lane dividers (n+1 walls).
	for i in range(F6_LANES + 1):
		var dx := -F6_GATE_W * 0.5 + float(i) * F6_LANE_W
		_add_box(body, "Divider_%d" % i,
			Transform3D(Basis.IDENTITY,
				Vector3(dx, F6_Y + F6_DIVIDER_H * 0.5, 0.0)),
			Vector3(F6_DIVIDER_T, F6_DIVIDER_H, FIELD_DEPTH),
			divider_mat)

# ─── Catchment floor (safety net well below gate) ────────────────────────────
# Catches marbles that bounce out of the gate so they don't fall forever.

func _build_catchment_floor() -> void:
	var catcher_mat := _std_mat(Color(0.12, 0.12, 0.15), 0.20, 0.80)
	var body := StaticBody3D.new()
	body.name = "Catchment"
	body.physics_material_override = _mat_gate
	add_child(body)

	_add_box(body, "CatchFloor",
		Transform3D(Basis.IDENTITY, Vector3(0.0, FLOOR_BASE_Y, 0.0)),
		Vector3(FIELD_W, FLOOR_THICK, FIELD_DEPTH),
		catcher_mat)

# ─── Stadium windmill paddle (kinematic Y-axis spinner) ─────────────────────
# Built as a single AnimatableBody3D parented at (0, WINDMILL_Y, 0) with
# 4 box children laid out as a + cross (one along X, one along Z, plus
# their negatives — so the cross is built from 2 long boxes through the
# centre). Spin is driven from _physics_process by rotating the body's
# basis around world Y; the children inherit the rotation automatically.

func _build_stadium_windmill() -> void:
	var blade_mat := _std_mat_emit(
		Color(1.00, 0.85, 0.30),       # gold blades — broadcast accent
		0.85, 0.20, 0.40)

	var body := AnimatableBody3D.new()
	body.name = "StadiumWindmill"
	body.sync_to_physics = true
	body.physics_material_override = _mat_windmill
	body.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, WINDMILL_Y, 0))
	add_child(body)

	# Two long crossing blades = a + cross. First along X, second rotated
	# 90° around Y to lie along Z.
	for i in range(2):
		var orient := Basis.IDENTITY
		if i == 1:
			orient = Basis(Vector3.UP, deg_to_rad(90.0))
		# Collision shape (box, sized for the blade).
		var coll := CollisionShape3D.new()
		coll.name = "Blade%d_shape" % i
		coll.transform = Transform3D(orient, Vector3.ZERO)
		var shape := BoxShape3D.new()
		shape.size = Vector3(WINDMILL_BLADE_LEN, WINDMILL_BLADE_H, WINDMILL_BLADE_T)
		coll.shape = shape
		body.add_child(coll)
		# Mesh.
		var mesh := MeshInstance3D.new()
		mesh.name = "Blade%d_mesh" % i
		mesh.transform = Transform3D(orient, Vector3.ZERO)
		var bm := BoxMesh.new()
		bm.size = Vector3(WINDMILL_BLADE_LEN, WINDMILL_BLADE_H, WINDMILL_BLADE_T)
		mesh.mesh = bm
		mesh.material_override = blade_mat
		body.add_child(mesh)

	# Central hub for visual anchor (small box).
	var hub_mesh := MeshInstance3D.new()
	hub_mesh.name = "WindmillHub"
	var hub_bm := BoxMesh.new()
	hub_bm.size = Vector3(0.6, 0.5, 0.6)
	hub_mesh.mesh = hub_bm
	hub_mesh.material_override = blade_mat
	body.add_child(hub_mesh)

	_windmill = body

	# ω from seed: first byte → -1..+1, scaled by WINDMILL_OMEGA_MAX, with
	# minimum |ω| floor so the paddle always spins visibly.
	var hash_bytes: PackedByteArray = _hash_with_tag("stadium_windmill")
	var raw_omega: float
	if hash_bytes.size() >= 1:
		raw_omega = float(int(hash_bytes[0]) - 128) / 128.0
	else:
		raw_omega = 0.7
	if absf(raw_omega) < (WINDMILL_OMEGA_MIN / WINDMILL_OMEGA_MAX):
		raw_omega = (WINDMILL_OMEGA_MIN / WINDMILL_OMEGA_MAX) * (1.0 if raw_omega >= 0 else -1.0)
	_windmill_omega = raw_omega * WINDMILL_OMEGA_MAX

# ─── Mood lighting ───────────────────────────────────────────────────────────

func _build_mood_lights() -> void:
	# Warm key: stadium late-afternoon directional sun, slight orange.
	var key := DirectionalLight3D.new()
	key.name = "StadiumKey"
	key.light_color    = Color(1.0, 0.88, 0.65)
	key.light_energy   = 1.5
	key.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	key.shadow_enabled = true
	add_child(key)

	# Cool back rim: from below-back, picks out marble silhouettes.
	var rim := OmniLight3D.new()
	rim.name = "StadiumRim"
	rim.light_color  = Color(0.55, 0.80, 1.0)
	rim.light_energy = 1.4
	rim.omni_range   = 50.0
	rim.position     = Vector3(0.0, F4_Y - 5.0, -8.0)
	add_child(rim)

	# Warm spot above the gate: highlight the finish line area.
	var finish_spot := OmniLight3D.new()
	finish_spot.name = "FinishSpot"
	finish_spot.light_color  = Color(1.0, 0.85, 0.55)
	finish_spot.light_energy = 2.0
	finish_spot.omni_range   = 12.0
	finish_spot.position     = Vector3(0.0, F6_Y + 4.0, 3.0)
	add_child(finish_spot)

# ─── Helpers ─────────────────────────────────────────────────────────────────

func _add_box(parent: Node, node_name: String, tx: Transform3D, size: Vector3,
		mat: StandardMaterial3D) -> void:
	var coll := CollisionShape3D.new()
	coll.name = node_name + "_shape"
	coll.transform = tx
	var shape := BoxShape3D.new()
	shape.size = size
	coll.shape = shape
	parent.add_child(coll)

	var mesh := MeshInstance3D.new()
	mesh.name = node_name + "_mesh"
	mesh.transform = tx
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = mat
	parent.add_child(mesh)

func _add_cylinder(parent: Node, node_name: String, tx: Transform3D,
		radius: float, height: float, mat: StandardMaterial3D) -> void:
	var coll := CollisionShape3D.new()
	coll.name = node_name + "_shape"
	coll.transform = tx
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	coll.shape = shape
	parent.add_child(coll)

	var mesh := MeshInstance3D.new()
	mesh.name = node_name + "_mesh"
	mesh.transform = tx
	var cm := CylinderMesh.new()
	cm.top_radius    = radius
	cm.bottom_radius = radius
	cm.height        = height
	mesh.mesh = cm
	mesh.material_override = mat
	parent.add_child(mesh)

func _std_mat(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic     = metallic
	m.roughness    = roughness
	return m

func _std_mat_emit(color: Color, metallic: float, roughness: float,
		emission_energy: float) -> StandardMaterial3D:
	var m := _std_mat(color, metallic, roughness)
	m.emission_enabled           = true
	m.emission                   = color
	m.emission_energy_multiplier = emission_energy
	return m

# ─── Track API overrides ─────────────────────────────────────────────────────

func spawn_points() -> Array:
	# 24 slots: 8 cols × 3 rows centered on the field, just above F1.
	var pts: Array = []
	for r in range(SPAWN_ROWS):
		for c in range(SPAWN_COLS):
			var fx := (float(c) - float(SPAWN_COLS - 1) * 0.5) * SPAWN_DX
			var fz := (float(r) - float(SPAWN_ROWS - 1) * 0.5) * SPAWN_DZ
			pts.append(Vector3(fx, SPAWN_Y, fz))
	return pts

func finish_area_transform() -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(0.0, F6_Y + FINISH_Y_OFF, 0.0))

func finish_area_size() -> Vector3:
	return FINISH_BOX

func camera_bounds() -> AABB:
	var min_v := Vector3(-FIELD_W * 0.5 - 1.0, FLOOR_BASE_Y - 2.0, -FIELD_DEPTH * 0.5 - 1.0)
	var max_v := Vector3( FIELD_W * 0.5 + 1.0, SPAWN_Y + 4.0,        FIELD_DEPTH * 0.5 + 1.0)
	return AABB(min_v, max_v - min_v)

func camera_pose() -> Dictionary:
	# Stadium overview: full track in frame, angled diagonally down.
	# Track spans y=-6 to y=43 (~49 m height), 40 m wide. From z=55, FOV 65°
	# half-height ≈ 35 m — fits with margin.
	var mid_y: float = (SPAWN_Y + FLOOR_BASE_Y) * 0.5    # ≈ 17
	return {
		"position": Vector3(8.0, mid_y + 6.0, 55.0),
		"target":   Vector3(0.0, mid_y - 4.0, 0.0),
		"fov":      65.0,
	}

func environment_overrides() -> Dictionary:
	# Late-afternoon stadium: warm sky, light haze, warm sun.
	return {
		"sky_top":        Color(0.22, 0.40, 0.78),
		"sky_horizon":    Color(0.92, 0.72, 0.45),
		"ambient_energy": 0.95,
		"fog_color":      Color(0.85, 0.72, 0.55),
		"fog_density":    0.0010,
		"sun_color":      Color(1.0, 0.85, 0.60),
		"sun_energy":     1.6,
	}
