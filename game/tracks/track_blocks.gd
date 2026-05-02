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
