class_name TrackBlocks
extends Object

# Reusable building blocks for the post-M6 track redesign.
#
# All tracks built after StadiumTrack share a small set of primitives —
# adding a box collider+mesh pair, adding a cylinder, building a standard
# material. Centralising them here keeps every track file focused on its
# theme and layout instead of repeating 30 lines of "MeshInstance3D + box
# + collision" boilerplate.
#
# Higher-level composites (V-funnel, directed ramp, peg forest, lane gate,
# outer frame) live here too. Track subclasses call them in _ready() with
# their own y-positions, materials, and tuning.
#
# Convention: every helper takes a `parent: Node` (typically a
# StaticBody3D) and adds collision + mesh as children. Materials are
# always passed in; this module never invents palettes — that's the
# track's job (theme) or TrackPalette's job (centralised palette table).
#
# All builders are STATIC — TrackBlocks is a namespace, not an instance.

# ─── Primitive: box ──────────────────────────────────────────────────────────

static func add_box(parent: Node, node_name: String, tx: Transform3D,
		size: Vector3, mat: StandardMaterial3D) -> void:
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

# ─── Primitive: cylinder ─────────────────────────────────────────────────────
# Cylinder default axis is Y. Pass a transform that rotates it to the desired
# axis (e.g. Basis(Vector3.RIGHT, deg_to_rad(90.0)) makes it horizontal along Z).

static func add_cylinder(parent: Node, node_name: String, tx: Transform3D,
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

# ─── Primitive: kinematic (animatable) cylinder ─────────────────────────────
# Builds an AnimatableBody3D + CollisionShape3D + MeshInstance3D positioned
# at `tx`. The cylinder is oriented along its local Y axis by default; pass
# a `tx` with a basis rotation if you want it horizontal (e.g.
# Basis(Vector3.RIGHT, deg_to_rad(90)) to lay it along Z).
#
# Used for rotating obstacles (Forest log rolls, future kinematic cylinders).
# Caller is responsible for driving the body's `global_transform` each frame
# in _physics_process — TrackBlocks doesn't manage motion. `sync_to_physics`
# is enabled so the physics step interpolates motion correctly.
#
# Returns the AnimatableBody3D so the caller can store it for animation.

static func add_animatable_cylinder(parent: Node, node_name: String,
		tx: Transform3D, radius: float, length: float,
		mat: StandardMaterial3D) -> AnimatableBody3D:
	var body := AnimatableBody3D.new()
	body.name = node_name
	body.sync_to_physics = true
	body.global_transform = tx
	parent.add_child(body)

	# Children carry IDENTITY local transform — body's transform IS the orient.
	var coll := CollisionShape3D.new()
	coll.name = node_name + "_shape"
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = length
	coll.shape = shape
	body.add_child(coll)

	var mesh := MeshInstance3D.new()
	mesh.name = node_name + "_mesh"
	var cm := CylinderMesh.new()
	cm.top_radius    = radius
	cm.bottom_radius = radius
	cm.height        = length
	mesh.mesh = cm
	mesh.material_override = mat
	body.add_child(mesh)
	return body

# ─── Primitive: collision-only box (mesh-less) ──────────────────────────────
# For invisible bounding walls (front camera-side wall, finish-line guides).

static func add_collider_only(parent: Node, node_name: String, tx: Transform3D,
		size: Vector3) -> void:
	var coll := CollisionShape3D.new()
	coll.name = node_name + "_shape"
	coll.transform = tx
	var shape := BoxShape3D.new()
	shape.size = size
	coll.shape = shape
	parent.add_child(coll)

# ─── Material helpers ────────────────────────────────────────────────────────

static func std_mat(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic     = metallic
	m.roughness    = roughness
	return m

static func std_mat_emit(color: Color, metallic: float, roughness: float,
		emission_energy: float) -> StandardMaterial3D:
	var m := std_mat(color, metallic, roughness)
	m.emission_enabled           = true
	m.emission                   = color
	m.emission_energy_multiplier = emission_energy
	return m

# Translucent material — for glass walls / decorative panels.
static func glass_mat(color: Color, alpha: float, roughness: float) -> StandardMaterial3D:
	var m := std_mat(Color(color.r, color.g, color.b, alpha), 0.40, roughness)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m

# ─── Composite: V-funnel ────────────────────────────────────────────────────
# Two converging slabs at floor `y_pos`, each tilted by `tilt_deg` toward the
# centre. A `gap_w`-wide rectangular gap at x=0 lets marbles fall through.
# Field full width `field_w`. Slabs cover from ±field_w/2 to ±gap_w/2.
#
# Tilt direction (right-hand rule, rotation around +Z):
#   left slab (sgn=-1): rotate by -tilt_deg → +X edge drops → marbles roll +X
#   right slab (sgn=+1): rotate by +tilt_deg → -X edge drops → marbles roll -X
# i.e. tilt_rad = sgn * tilt_deg.

static func build_v_funnel(parent: Node, name_prefix: String, y_pos: float,
		field_w: float, gap_w: float, depth: float, thickness: float,
		tilt_deg: float, mat: StandardMaterial3D) -> void:
	var slab_w  := (field_w - gap_w) * 0.5
	var slab_x  := (field_w * 0.5 + gap_w * 0.5) * 0.5    # midpoint of each slab

	for sgn in [-1, 1]:
		var center_x: float = float(sgn) * slab_x
		var tilt_rad := float(sgn) * deg_to_rad(tilt_deg)
		var basis := Basis(Vector3(0, 0, 1), tilt_rad)
		add_box(parent, "%s_Slab_%s" % [name_prefix, ("pos" if sgn > 0 else "neg")],
			Transform3D(basis, Vector3(center_x, y_pos, 0.0)),
			Vector3(slab_w, thickness, depth),
			mat)

# ─── Composite: directed ramp ───────────────────────────────────────────────
# A single tilted slab at floor `y_pos`. Marbles roll toward the gap end:
#   gap_dir = +1 → gap on +X side, slab tilts low at +X
#   gap_dir = -1 → gap on -X side, slab tilts low at -X
# Optional curb at the gap-side edge (raised lip; some bounce going into gap).

static func build_directed_ramp(parent: Node, name_prefix: String, y_pos: float,
		field_w: float, gap_w: float, depth: float, thickness: float,
		tilt_deg: float, gap_dir: int, mat: StandardMaterial3D,
		curb_mat: StandardMaterial3D = null) -> void:
	var slab_w := field_w - gap_w
	var center_x: float = -float(gap_dir) * (gap_w * 0.5)
	# gap_dir=+1 wants -X edge UP / +X edge DOWN → negative rotation around +Z
	# gap_dir=-1 wants +X edge UP / -X edge DOWN → positive rotation around +Z
	var tilt_rad := -float(gap_dir) * deg_to_rad(tilt_deg)
	var basis := Basis(Vector3(0, 0, 1), tilt_rad)

	add_box(parent, "%s_Slab" % name_prefix,
		Transform3D(basis, Vector3(center_x, y_pos, 0.0)),
		Vector3(slab_w, thickness, depth),
		mat)

	if curb_mat != null:
		# Short raised lip at the slab's downhill edge so marbles get a small
		# bounce going into the gap (visual + readability).
		var slab_end_x: float = float(gap_dir) * (slab_w * 0.5) + center_x
		add_box(parent, "%s_Curb" % name_prefix,
			Transform3D(basis, Vector3(slab_end_x, y_pos + 0.4, 0.0)),
			Vector3(0.3, 0.4, depth),
			curb_mat)

# ─── Composite: peg forest ──────────────────────────────────────────────────
# Hex-staggered grid of cylindrical pegs along Z, between top_y and bot_y,
# spanning field_w. Caller controls rows / cols / peg_radius / col_spacing.
# Peg height = depth (cylinder spans the full depth axis).

static func build_peg_forest(parent: Node, name_prefix: String,
		top_y: float, bot_y: float, field_w: float, depth: float,
		rows: int, cols: int, peg_radius: float, col_spacing: float,
		mat: StandardMaterial3D) -> void:
	var row_spacing: float = (top_y - bot_y) / float(rows + 1)
	for row in range(rows):
		var y: float = top_y - row_spacing * float(row + 1)
		var x_offset: float = 0.0 if (row % 2 == 0) else col_spacing * 0.5
		var x_origin: float = -float(cols - 1) * 0.5 * col_spacing + x_offset
		for col in range(cols):
			var x: float = x_origin + float(col) * col_spacing
			# Skip pegs that would clip the side walls.
			if abs(x) > field_w * 0.5 - peg_radius - 0.3:
				continue
			# Cylinder along Z axis: rotate from default Y to Z.
			var rot := Basis(Vector3.RIGHT, deg_to_rad(90.0))
			var tx  := Transform3D(rot, Vector3(x, y, 0.0))
			add_cylinder(parent, "%s_Peg_r%d_c%d" % [name_prefix, row, col],
				tx, peg_radius, depth, mat)

# ─── Composite: lane gate ───────────────────────────────────────────────────
# Flat floor at `y_pos` spanning `field_w` × `depth`, with `n_lanes`+1 thin
# vertical dividers rising from the floor. Used as the final finish-line
# layer where marbles settle into discrete lanes.

static func build_lane_gate(parent: Node, name_prefix: String, y_pos: float,
		field_w: float, depth: float, n_lanes: int,
		divider_h: float, divider_t: float, floor_thick: float,
		floor_mat: StandardMaterial3D,
		divider_mat: StandardMaterial3D) -> void:
	add_box(parent, "%s_Floor" % name_prefix,
		Transform3D(Basis.IDENTITY, Vector3(0.0, y_pos, 0.0)),
		Vector3(field_w, floor_thick, depth),
		floor_mat)

	var lane_w: float = field_w / float(n_lanes)
	for i in range(n_lanes + 1):
		var dx: float = -field_w * 0.5 + float(i) * lane_w
		add_box(parent, "%s_Divider_%d" % [name_prefix, i],
			Transform3D(Basis.IDENTITY,
				Vector3(dx, y_pos + divider_h * 0.5, 0.0)),
			Vector3(divider_t, divider_h, depth),
			divider_mat)

# ─── Composite: outer frame ─────────────────────────────────────────────────
# Tall side walls at ±field_w/2, back wall at -depth/2 (with mesh as backdrop),
# front wall at +depth/2 (collision only — camera looks through).
# Top covers from `top_y` (above spawn) to `bot_y` (below catchment).

static func build_outer_frame(parent: Node, name_prefix: String,
		top_y: float, bot_y: float, field_w: float, depth: float,
		wall_thick: float, mat: StandardMaterial3D) -> void:
	var height: float   = top_y - bot_y
	var center_y: float = (top_y + bot_y) * 0.5

	# Side walls (full height) on ±X.
	for sgn in [-1, 1]:
		var x: float = float(sgn) * (field_w * 0.5 + wall_thick * 0.5)
		add_box(parent, "%s_SideX_%s" % [name_prefix, ("pos" if sgn > 0 else "neg")],
			Transform3D(Basis.IDENTITY, Vector3(x, center_y, 0.0)),
			Vector3(wall_thick, height, depth + 0.4),
			mat)

	# Back wall (-Z) — mesh + collision (acts as backdrop).
	add_box(parent, "%s_Back" % name_prefix,
		Transform3D(Basis.IDENTITY, Vector3(0.0, center_y, -depth * 0.5 - wall_thick * 0.5)),
		Vector3(field_w + wall_thick * 2.0, height, wall_thick),
		mat)

	# Front wall (+Z) — collision only, camera looks through.
	add_collider_only(parent, "%s_Front" % name_prefix,
		Transform3D(Basis.IDENTITY,
			Vector3(0.0, center_y, depth * 0.5 + wall_thick * 0.5)),
		Vector3(field_w + wall_thick * 2.0, height, wall_thick))

# ─── Pickup zone (M17 — payout v2 multiplier collection) ────────────────────
# Builds a PickupZone (Area3D) at `tx` with the given size and tier.
#
# Tier 1 (2×) zones: place 4 of them at high-traffic points so the math
# model's expected E[n2] = 4 holds. Place them BETWEEN obstacles (not on
# top of them), wide enough that ~1 marble per zone naturally collects.
#
# Tier 2 (3×) zones: place 1 narrow zone in a "premium" position so only
# the most lucky marble passes through. Geometry should be tight enough
# that only ~0.5-0.7 marbles per round on average traverse it (the
# probabilistic activation comes from the server's Tier 2 active flag —
# this geometry caps the upper bound).
#
# Returns the PickupZone node so the caller can stash it for late tweaks.
static func add_pickup_zone(parent: Node, node_name: String, tx: Transform3D,
		size: Vector3, tier: int,
		mat: StandardMaterial3D = null) -> PickupZone:
	var zone := PickupZone.new()
	zone.name = node_name
	zone.tier = tier
	zone.transform = tx

	var coll := CollisionShape3D.new()
	coll.name = node_name + "_shape"
	var box := BoxShape3D.new()
	box.size = size
	coll.shape = box
	zone.add_child(coll)

	# Optional visual marker — semi-transparent volume that tints the area
	# the marble can be picked up in. Helps players see why some marbles
	# get a multiplier and others don't. Skip the mesh if no material was
	# passed (some operators may want pickup zones to be invisible).
	if mat != null:
		var mesh := MeshInstance3D.new()
		mesh.name = node_name + "_mesh"
		var bm := BoxMesh.new()
		bm.size = size
		mesh.mesh = bm
		mesh.material_override = mat
		zone.add_child(mesh)

	parent.add_child(zone)
	return zone

# ─── Composite: catchment floor ─────────────────────────────────────────────
# Flat catcher well below the gate. Catches marbles that bounce out of the
# finish gate so they don't fall forever (which would also leak the round
# tail recording past the natural end).

static func build_catchment(parent: Node, name_prefix: String, y_pos: float,
		field_w: float, depth: float, thickness: float,
		mat: StandardMaterial3D) -> void:
	add_box(parent, "%s_Floor" % name_prefix,
		Transform3D(Basis.IDENTITY, Vector3(0.0, y_pos, 0.0)),
		Vector3(field_w, thickness, depth),
		mat)

# ═══════════════════════════════════════════════════════════════════════════════
# DECORATION PROPS — Visual-only helpers (NO collision, NO physics).
#
# All helpers below produce MeshInstance3D + lights + GPUParticles3D nodes
# attached directly to `parent` (a plain Node3D, not a StaticBody3D).
# They NEVER create CollisionShape3D or PhysicsBody3D, so the fairness
# chain and race physics remain entirely untouched.
#
# Convention:
#   parent      — any Node3D (NOT a physics body)
#   name_prefix — used as the base for child node names
#   pos         — world-space origin for the group
#   colours     — Array[Color] palette; helpers cycle through them
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Spectator stand row ─────────────────────────────────────────────────────
# Builds `count` "spectator" figures along X, centred at `pos`.
# Each figure is a body-cylinder topped by a head-sphere — two MeshInstance3D
# nodes grouped under a Node3D root (no physics, pure visual).
# `spacing`   : X distance between figures
# `body_col`  : Array[Color] — cycled per seat for crowd variety
# `head_col`  : uniform head colour (or same array cycling)

static func build_spectator_row(parent: Node, name_prefix: String,
		pos: Vector3, count: int, spacing: float,
		body_cols: Array, head_col: Color) -> void:
	var root := Node3D.new()
	root.name = name_prefix
	root.position = pos
	parent.add_child(root)

	const BODY_R  := 0.30
	const BODY_H  := 0.65
	const HEAD_R  := 0.22
	const HEAD_OY := 0.55    # Y offset of head centre above body centre

	for i in range(count):
		var x: float = (float(i) - float(count - 1) * 0.5) * spacing
		var col: Color = body_cols[i % body_cols.size()]

		# Body cylinder.
		var body_mat := std_mat(col, 0.05, 0.75)
		var body_mesh := MeshInstance3D.new()
		body_mesh.name = "%s_Body_%d" % [name_prefix, i]
		var cm := CylinderMesh.new()
		cm.top_radius    = BODY_R
		cm.bottom_radius = BODY_R
		cm.height        = BODY_H
		body_mesh.mesh = cm
		body_mesh.material_override = body_mat
		body_mesh.position = Vector3(x, 0.0, 0.0)
		root.add_child(body_mesh)

		# Head sphere.
		var head_mat := std_mat(head_col, 0.05, 0.65)
		var head_mesh := MeshInstance3D.new()
		head_mesh.name = "%s_Head_%d" % [name_prefix, i]
		var sm := SphereMesh.new()
		sm.radius = HEAD_R
		sm.height = HEAD_R * 2.0
		head_mesh.mesh = sm
		head_mesh.material_override = head_mat
		head_mesh.position = Vector3(x, BODY_H * 0.5 + HEAD_OY, 0.0)
		root.add_child(head_mesh)

# ─── Billboard panel ─────────────────────────────────────────────────────────
# A flat BoxMesh with an emissive material used as a sign/banner.
# `size`   : Vector3 — panel width (X), height (Y), thickness (Z)
# `col`    : emissive face colour
# `energy` : emission_energy_multiplier (2-4 for neon glow)

static func build_billboard(parent: Node, node_name: String,
		tx: Transform3D, size: Vector3,
		col: Color, energy: float) -> void:
	var mat := std_mat_emit(col, 0.10, 0.30, energy)

	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	mesh.transform = tx
	var bm := BoxMesh.new()
	bm.size = size
	mesh.mesh = bm
	mesh.material_override = mat
	parent.add_child(mesh)

	# Dark backing plate (slightly larger, behind the sign).
	var back_mat := std_mat(Color(0.04, 0.04, 0.05), 0.05, 0.90)
	var back := MeshInstance3D.new()
	back.name = node_name + "_Back"
	var back_tx := Transform3D(tx.basis,
		tx.origin + tx.basis.z * (-size.z * 0.5 - 0.05))
	back.transform = back_tx
	var bbm := BoxMesh.new()
	bbm.size = Vector3(size.x + 0.1, size.y + 0.1, 0.06)
	back.mesh = bbm
	back.material_override = back_mat
	parent.add_child(back)

# ─── Neon accent lights ───────────────────────────────────────────────────────
# Adds `count` OmniLight3D nodes spaced along X at `y_level`, offset in Z.
# `cols`   : Array[Color] — cycled per light
# `energy` : light_energy
# `range_` : omni_range

static func build_neon_array(parent: Node, name_prefix: String,
		y_level: float, z_offset: float,
		x_positions: Array, cols: Array,
		energy: float, range_: float) -> void:
	for i in range(x_positions.size()):
		var light := OmniLight3D.new()
		light.name = "%s_Neon_%d" % [name_prefix, i]
		light.light_color  = cols[i % cols.size()]
		light.light_energy = energy
		light.omni_range   = range_
		light.position     = Vector3(float(x_positions[i]), y_level, z_offset)
		parent.add_child(light)

# ─── Ambient particle emitter ────────────────────────────────────────────────
# Builds a GPUParticles3D node for ambient FX (leaves, sparks, snow, dust…).
# Parameters are tuned per-call; helper sets up the ProcessMaterial with the
# supplied colours and velocity / lifetime so the caller only provides intent.
#
# `pos`           : emitter world position
# `amount`        : particles alive at once (keep ≤ 200 total per track)
# `lifetime`      : seconds per particle
# `emit_col`      : base particle colour (albedo)
# `gravity_vec`   : gravity override direction×magnitude (Vector3)
#                   e.g. Vector3(0, -1.5, 0) for gentle fall
# `spread_box`    : BoxShape3D half-extents for the emission volume
# `velocity_min`  : initial speed range min
# `velocity_max`  : initial speed range max
# `scale_min/max` : particle size range

static func build_ambient_particles(parent: Node, node_name: String,
		pos: Vector3, amount: int, lifetime: float,
		emit_col: Color, gravity_vec: Vector3,
		spread_x: float, spread_y: float, spread_z: float,
		velocity_min: float, velocity_max: float,
		scale_min: float, scale_max: float) -> GPUParticles3D:
	var gp := GPUParticles3D.new()
	gp.name = node_name
	gp.position = pos
	gp.amount = amount
	gp.lifetime = lifetime
	gp.preprocess = lifetime          # pre-warm so particles show immediately
	gp.emitting = true

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(spread_x, spread_y, spread_z)
	pm.gravity = gravity_vec
	# Spread in all horizontal directions.
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 180.0
	pm.initial_velocity_min = velocity_min
	pm.initial_velocity_max = velocity_max
	pm.scale_min = scale_min
	pm.scale_max = scale_max
	pm.color = emit_col
	gp.process_material = pm

	# Use a simple sphere mesh for each particle.
	var mesh := SphereMesh.new()
	mesh.radius = 0.05
	mesh.height = 0.10
	var mat := std_mat_emit(emit_col, 0.0, 0.40, 1.2)
	mesh.material = mat
	gp.draw_pass_1 = mesh

	parent.add_child(gp)
	return gp

# ─── Smooth swept tube ──────────────────────────────────────────────────────
#
# Replace the legacy "stack a CylinderMesh per polyline segment" approach
# with a single procedurally-swept ArrayMesh. Eliminates the visible
# faceting + lighting striping at every segment joint.
#
# Pipeline:
#   1. Polyline waypoints → Curve3D with Catmull-Rom-derived Bezier handles
#      (smooth tangent continuity at every interior waypoint; the curve
#      passes through every waypoint exactly).
#   2. Sample the baked curve at uniform arc-length intervals.
#   3. Compute parallel-transport frames at each sample (no Frenet-Serret
#      flip on near-straight runs).
#   4. Sweep a closed full-circle cross-section, emitting indexed vertices
#      so SurfaceTool.generate_normals can average normals at every shared
#      vertex — smooth shading across the whole tube.
#
# `path`: at least 2 Vector3 waypoints in world space (or local — the mesh
#         is built in the parent's frame). Sharp interior bends round off
#         into smooth Bezier curves; the polyline shape is preserved
#         qualitatively but not pixel-exact at the corners.
# `sample_spacing`: target arc-length between rings, metres. 0.25 gives
#         ~4 rings per metre, smooth at any expected camera distance.
# `section_verts`: vertices around the cross-section (≥6, sweet spot 14–20).
#
# Returns the MeshInstance3D so callers can chain (set layer, attach
# overlays, etc.). Adds it to `parent` as part of the call.
static func add_smooth_tube(parent: Node, node_name: String, path: Array,
		radius: float, mat: Material,
		sample_spacing: float = 0.25, section_verts: int = 16,
		inverted_winding: bool = false,
		cap_inner_radius: float = -1.0) -> MeshInstance3D:
	if path.size() < 2:
		push_warning("TrackBlocks.add_smooth_tube: path needs ≥2 points (%s)" % node_name)
		return null

	# 1. Polyline → Curve3D with Catmull-Rom handles.
	var curve := Curve3D.new()
	curve.bake_interval = max(sample_spacing * 0.5, 0.1)
	var n := path.size()
	for i in range(n):
		var p: Vector3 = path[i]
		var prev: Vector3 = path[i - 1] if i > 0 else p
		var next: Vector3 = path[i + 1] if i < n - 1 else p
		# Catmull-Rom-ish tangent at the waypoint: half the chord from
		# neighbour to neighbour, scaled by 1/3 for cubic-Bezier handles.
		# Endpoints taper because prev/next collapse to p there.
		var tangent: Vector3 = (next - prev) * (1.0 / 6.0)
		curve.add_point(p, -tangent, tangent)

	# 2. Uniform-arc-length sampling.
	var length: float = curve.get_baked_length()
	if length < 0.001:
		push_warning("TrackBlocks.add_smooth_tube: zero-length path (%s)" % node_name)
		return null
	var n_rings: int = max(int(ceil(length / sample_spacing)) + 1, 4)
	var samples: Array[Vector3] = []
	samples.resize(n_rings)
	for i in range(n_rings):
		var s: float = (float(i) / float(n_rings - 1)) * length
		samples[i] = curve.sample_baked(s, true)

	# 3. Tangents via central differences (forward at endpoints).
	var tangents: Array[Vector3] = []
	tangents.resize(n_rings)
	tangents[0] = (samples[1] - samples[0]).normalized()
	tangents[n_rings - 1] = (samples[n_rings - 1] - samples[n_rings - 2]).normalized()
	for i in range(1, n_rings - 1):
		var t := samples[i + 1] - samples[i - 1]
		if t.length() < 0.001:
			t = samples[i + 1] - samples[i]
		tangents[i] = t.normalized()

	# 4. Parallel-transport frames.
	var rights: Array[Vector3] = []
	var ups: Array[Vector3] = []
	rights.resize(n_rings)
	ups.resize(n_rings)
	var seed_ref := Vector3.UP
	if absf(tangents[0].dot(seed_ref)) > 0.95:
		seed_ref = Vector3.RIGHT
	var r0 := (seed_ref - tangents[0] * seed_ref.dot(tangents[0])).normalized()
	var u0 := tangents[0].cross(r0).normalized()
	rights[0] = r0
	ups[0] = u0
	for i in range(1, n_rings):
		var t := tangents[i]
		var r := rights[i - 1] - t * rights[i - 1].dot(t)
		if r.length() < 0.001:
			r = Vector3.RIGHT - t * Vector3.RIGHT.dot(t)
		r = r.normalized()
		var u := t.cross(r).normalized()
		rights[i] = r
		ups[i] = u

	# 5. Full-circle cross-section.
	var sv: int = max(section_verts, 6)
	var profile: Array[Vector2] = []
	profile.resize(sv)
	for j in range(sv):
		var theta: float = TAU * float(j) / float(sv)
		profile[j] = Vector2(cos(theta), sin(theta)) * radius

	# 6. Emit indexed vertices, ring-major.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for ring in range(n_rings):
		var p := samples[ring]
		var rr := rights[ring]
		var uu := ups[ring]
		for j in range(sv):
			var pr := profile[j]
			var v := p + rr * pr.x + uu * pr.y
			var uv := Vector2(
				float(j) / float(sv),
				float(ring) / float(n_rings - 1) * (length / max(radius * TAU, 0.01))
			)
			st.set_uv(uv)
			st.add_vertex(v)

	# 7. Quad indices. Wrap around the cross-section so j == sv-1 connects
	# back to j == 0 (closed cylindrical loop). Winding orients normals
	# outward (away from the curve centreline).
	for ring in range(n_rings - 1):
		for j in range(sv):
			var j2: int = (j + 1) % sv
			var i00: int = ring * sv + j
			var i01: int = ring * sv + j2
			var i10: int = (ring + 1) * sv + j
			var i11: int = (ring + 1) * sv + j2
			if inverted_winding:
				# Swap second and third index per triangle -> reversed
				# triangle winding -> normals point inward. Used for the
				# inner shell of a two-sided tube (visible from inside
				# with CULL_BACK lighting the inward-facing surface).
				st.add_index(i00)
				st.add_index(i11)
				st.add_index(i10)
				st.add_index(i00)
				st.add_index(i01)
				st.add_index(i11)
			else:
				st.add_index(i00)
				st.add_index(i10)
				st.add_index(i11)
				st.add_index(i00)
				st.add_index(i11)
				st.add_index(i01)

	# 8. Annular end caps (optional). When cap_inner_radius > 0, emit a
	# flat ring at ring 0 and at ring (n_rings - 1) connecting the
	# existing outer-radius vertices to a fresh inner-radius ring.
	# Built using the EXACT same rights[]/ups[] frames so the cap's
	# outer edge sits flush against the swept mesh's terminal ring —
	# no rotation mismatch, no visible gap.
	# Cap-building moved out of this surface — winding direction was
	# putting the cap on the wrong side of the tube end. Caps are now
	# built by the caller as a SEPARATE MeshInstance3D with CULL_DISABLED
	# material so they always render regardless of normal direction.
	# (See add_smooth_tube_caps below.)

	st.generate_normals()
	st.generate_tangents()
	var mesh: ArrayMesh = st.commit()

	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = mat
	parent.add_child(mi)
	return mi

# Sweep a PARTIAL-ARC cross-section along a polyline path with per-
# waypoint roll. Used for open-topped slides / troughs / half-pipes —
# anywhere the marble should ride on a curved surface that's open at
# the top. Roll lets the user bank the slide around turns.
#
# path           : Array[Vector3] of waypoints (at least 2)
# roll_degrees   : Array[float], one per waypoint, rotation around the
#                  curve tangent in degrees. 0 = opening straight up.
#                  Empty array == all zero. Roll interpolates smoothly
#                  between waypoints via Curve3D.set_point_tilt.
# radius         : cross-section radius
# arc_sweep_deg  : how many degrees of the cross-section are SOLID
#                  (default 210; the remaining ~150° is the open top)
static func add_smooth_trough(parent: Node, node_name: String, path: Array,
		roll_degrees: Array, radius: float, arc_sweep_deg: float,
		mat: Material,
		sample_spacing: float = 0.25, section_verts: int = 18) -> MeshInstance3D:
	if path.size() < 2:
		push_warning("TrackBlocks.add_smooth_trough: path needs ≥2 points (%s)" % node_name)
		return null

	# 1. Build the Curve3D with Catmull-Rom-derived Bezier handles AND
	#    per-waypoint tilt for the roll. Curve3D's baked up vector
	#    interpolates tilt smoothly so each ring between waypoints
	#    inherits a continuously-twisting frame.
	var curve := Curve3D.new()
	curve.bake_interval = max(sample_spacing * 0.5, 0.1)
	var n_path: int = path.size()
	for i in range(n_path):
		var p: Vector3 = path[i]
		var prev: Vector3 = path[i - 1] if i > 0 else p
		var next: Vector3 = path[i + 1] if i < n_path - 1 else p
		var tangent: Vector3 = (next - prev) * (1.0 / 6.0)
		curve.add_point(p, -tangent, tangent)
		var tilt_deg: float = 0.0
		if i < roll_degrees.size():
			tilt_deg = float(roll_degrees[i])
		curve.set_point_tilt(i, deg_to_rad(tilt_deg))

	# 2. Uniform-arc-length sampling. Same N_rings formula as the tube
	#    so behaviour stays consistent across editor objects.
	var length: float = curve.get_baked_length()
	if length < 0.001:
		return null
	var n_rings: int = max(int(ceil(length / sample_spacing)) + 1, 4)
	var samples: Array[Vector3] = []
	var ups_baked: Array[Vector3] = []
	samples.resize(n_rings)
	ups_baked.resize(n_rings)
	for i in range(n_rings):
		var s: float = (float(i) / float(n_rings - 1)) * length
		samples[i] = curve.sample_baked(s, true)
		# sample_baked_up_vector applies the per-point tilt — the
		# whole point of using Curve3D's tilt.
		ups_baked[i] = curve.sample_baked_up_vector(s, true)

	# 3. Tangents via central differences (forward/backward at ends).
	var tangents: Array[Vector3] = []
	tangents.resize(n_rings)
	tangents[0] = (samples[1] - samples[0]).normalized()
	tangents[n_rings - 1] = (samples[n_rings - 1] - samples[n_rings - 2]).normalized()
	for i in range(1, n_rings - 1):
		var t_mid := samples[i + 1] - samples[i - 1]
		if t_mid.length() < 0.001:
			t_mid = samples[i + 1] - samples[i]
		tangents[i] = t_mid.normalized()

	# 4. For each ring, derive (right, up) from the curve's tilted up
	#    vector and the tangent. Re-orthogonalise up against tangent
	#    so the cross-section sits in the plane perpendicular to the
	#    curve direction.
	var rights: Array[Vector3] = []
	var ups: Array[Vector3] = []
	rights.resize(n_rings)
	ups.resize(n_rings)
	for i in range(n_rings):
		var t := tangents[i]
		var u := ups_baked[i]
		u = u - t * u.dot(t)
		if u.length() < 0.001:
			u = Vector3.UP - t * Vector3.UP.dot(t)
			if u.length() < 0.001:
				u = Vector3.RIGHT
		u = u.normalized()
		var r := t.cross(u).normalized()
		rights[i] = r
		ups[i] = u

	# 5. Cross-section profile = arc on the (right, up) plane, centred
	#    at the BOTTOM of the cross-section (angle 3π/2 in standard
	#    polar form). Arc spans arc_sweep_deg degrees, leaving the
	#    rest open at the top. With 210° default we get a generous
	#    'high lipped half-pipe' — bigger than a half-circle so marbles
	#    don't fly out on hard banks.
	var sweep_rad := deg_to_rad(arc_sweep_deg)
	var start_angle: float = 1.5 * PI - sweep_rad * 0.5
	var n_arc: int = section_verts + 1
	var profile: Array[Vector2] = []
	profile.resize(n_arc)
	for j in range(n_arc):
		var theta: float = start_angle + sweep_rad * float(j) / float(section_verts)
		profile[j] = Vector2(cos(theta), sin(theta)) * radius

	# 6. Emit indexed vertices, ring-major.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for ring in range(n_rings):
		var p := samples[ring]
		var rr := rights[ring]
		var uu := ups[ring]
		for j in range(n_arc):
			var pr := profile[j]
			var v := p + rr * pr.x + uu * pr.y
			var uv := Vector2(
				float(j) / float(n_arc - 1),
				float(ring) / float(n_rings - 1)
			)
			st.set_uv(uv)
			st.add_vertex(v)

	# 7. Triangulate. The arc is NOT closed (open at the top) so we
	#    don't wrap j to 0; indices run 0..n_arc-1 per ring with
	#    quads only between adjacent js.
	for ring in range(n_rings - 1):
		for j in range(n_arc - 1):
			var i00: int = ring * n_arc + j
			var i01: int = ring * n_arc + j + 1
			var i10: int = (ring + 1) * n_arc + j
			var i11: int = (ring + 1) * n_arc + j + 1
			st.add_index(i00); st.add_index(i10); st.add_index(i11)
			st.add_index(i00); st.add_index(i11); st.add_index(i01)

	st.generate_normals()
	st.generate_tangents()
	var mesh: ArrayMesh = st.commit()

	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = mat
	parent.add_child(mi)
	return mi

# Build annular end caps for a swept tube. Same path / sample-spacing /
# section_verts as add_smooth_tube so the cap rings sit at the exact
# same positions as the swept mesh's terminal rings (perfect alignment,
# no gap). The cap is a SEPARATE MeshInstance3D so its material can be
# CULL_DISABLED (always visible from any side) without forcing the
# swept tube's curved walls to render two-sided (which produces ugly
# lighting bands).
#
# outer_radius : cap's outer edge (= tube wall outer radius)
# inner_radius : cap's inner edge (= tube wall inner radius)
# Cap is rendered double-sided so no winding direction maths.
static func add_smooth_tube_caps(parent: Node, node_name: String, path: Array,
		outer_radius: float, inner_radius: float, mat: Material,
		sample_spacing: float = 0.25, section_verts: int = 16) -> MeshInstance3D:
	if path.size() < 2:
		return null

	# Replicate add_smooth_tube's Curve3D + sampling + parallel-transport
	# frame computation so the cap rings have the exact same orientation
	# as the swept mesh's terminal rings.
	var curve := Curve3D.new()
	curve.bake_interval = max(sample_spacing * 0.5, 0.1)
	var n_path := path.size()
	for i in range(n_path):
		var pp: Vector3 = path[i]
		var prev: Vector3 = path[i - 1] if i > 0 else pp
		var next: Vector3 = path[i + 1] if i < n_path - 1 else pp
		var tangent: Vector3 = (next - prev) * (1.0 / 6.0)
		curve.add_point(pp, -tangent, tangent)

	var length: float = curve.get_baked_length()
	if length < 0.001:
		return null

	# Sample the curve the EXACT same way add_smooth_tube does so the
	# cap rings sit at the same positions and the tangents come from
	# the same finite differences. Anything subtly different here
	# produces a sub-millimetre seam between the swept tube end and
	# the cap outer edge.
	var n_rings: int = max(int(ceil(length / sample_spacing)) + 1, 4)
	var samples: Array[Vector3] = []
	samples.resize(n_rings)
	for i in range(n_rings):
		var s: float = (float(i) / float(n_rings - 1)) * length
		samples[i] = curve.sample_baked(s, true)

	var tangents: Array[Vector3] = []
	tangents.resize(n_rings)
	tangents[0] = (samples[1] - samples[0]).normalized()
	tangents[n_rings - 1] = (samples[n_rings - 1] - samples[n_rings - 2]).normalized()
	for i in range(1, n_rings - 1):
		var t_mid := samples[i + 1] - samples[i - 1]
		if t_mid.length() < 0.001:
			t_mid = samples[i + 1] - samples[i]
		tangents[i] = t_mid.normalized()

	# Parallel-transport — same algorithm as add_smooth_tube.
	var seed_ref := Vector3.UP
	if absf(tangents[0].dot(seed_ref)) > 0.95:
		seed_ref = Vector3.RIGHT
	var r_curr := (seed_ref - tangents[0] * seed_ref.dot(tangents[0])).normalized()
	var u_curr := tangents[0].cross(r_curr).normalized()
	var r_start := r_curr
	var u_start := u_curr
	for i in range(1, n_rings):
		var t_i: Vector3 = tangents[i]
		var r_new: Vector3 = r_curr - t_i * r_curr.dot(t_i)
		if r_new.length() < 0.001:
			r_new = Vector3.RIGHT - t_i * Vector3.RIGHT.dot(t_i)
		r_new = r_new.normalized()
		u_curr = t_i.cross(r_new).normalized()
		r_curr = r_new
	var r_end := r_curr
	var u_end := u_curr
	var s0: Vector3 = samples[0]
	var s_last: Vector3 = samples[n_rings - 1]

	# Build the two annular caps in one SurfaceTool.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var endpoints: Array = [
		{"centre": s0,     "right": r_start, "up": u_start},
		{"centre": s_last, "right": r_end,   "up": u_end},
	]
	# Manual vertex counter: SurfaceTool doesn't expose vertex count
	# directly in Godot 4. Each ring adds section_verts verts.
	var vert_counter: int = 0
	for ep in endpoints:
		var p_c: Vector3 = ep["centre"]
		var rr: Vector3 = ep["right"]
		var uu: Vector3 = ep["up"]
		var outer_start: int = vert_counter
		# Outer ring
		for j in range(section_verts):
			var theta: float = TAU * float(j) / float(section_verts)
			var v: Vector3 = p_c + rr * (cos(theta) * outer_radius) \
					+ uu * (sin(theta) * outer_radius)
			st.set_uv(Vector2(float(j) / float(section_verts), 0.0))
			st.add_vertex(v)
		vert_counter += section_verts
		var inner_start: int = vert_counter
		# Inner ring
		for j in range(section_verts):
			var theta: float = TAU * float(j) / float(section_verts)
			var v: Vector3 = p_c + rr * (cos(theta) * inner_radius) \
					+ uu * (sin(theta) * inner_radius)
			st.set_uv(Vector2(float(j) / float(section_verts), 1.0))
			st.add_vertex(v)
		vert_counter += section_verts
		# Triangulate annulus (winding doesn't matter — CULL_DISABLED).
		for j in range(section_verts):
			var j2: int = (j + 1) % section_verts
			var o0: int = outer_start + j
			var o1: int = outer_start + j2
			var i0: int = inner_start + j
			var i1: int = inner_start + j2
			st.add_index(o0); st.add_index(o1); st.add_index(i1)
			st.add_index(o0); st.add_index(i1); st.add_index(i0)

	st.generate_normals()
	st.generate_tangents()
	var cap_mesh: ArrayMesh = st.commit()

	var cap_mat := StandardMaterial3D.new()
	if mat is StandardMaterial3D:
		var src := mat as StandardMaterial3D
		cap_mat.albedo_color = src.albedo_color
		cap_mat.metallic = src.metallic
		cap_mat.roughness = src.roughness
	cap_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = cap_mesh
	mi.material_override = cap_mat
	parent.add_child(mi)
	return mi

# SurfaceTool doesn't expose vertex count directly; track via dummy
# scratch surface. We just call add_vertex+add_index counted manually.
# Simpler: pass through outer_start/inner_start indices recorded by the
# caller before each ring's emission. The helper just returns the next
# available index.
static func _surface_vertex_count(_st: SurfaceTool) -> int:
	# Not actually queryable in Godot 4 — but our caller pre-computes
	# indices based on a manual cumulative counter. This helper exists
	# so future maintainers don't trip on the missing API.
	return 0
