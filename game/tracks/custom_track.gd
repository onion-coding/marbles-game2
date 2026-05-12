class_name CustomTrack
extends Track

# Loads a map JSON saved by the editor (MapEditor → user://maps/<name>.json or
# any absolute/user:// path) and assembles a playable track by reconstructing
# the same geometry the editor previews.
#
# Usage:
#   var t := CustomTrack.new()
#   t.set_map_path("user://maps/my_track.json")
#   t.configure(round_id, server_seed)
#   add_child(t)   # _ready() calls _load_and_build()
#
# Or via CLI flag (interactive mode):
#   --map=user://maps/my_track.json
#   --map=C:/absolute/path/to/my_track.json
#
# Track ID 10 in TrackRegistry — never renumber.

const TRACK_ID := 10

# Map path set before add_child() — or auto-read from --map= in _ready().
var _map_path: String = ""

# Parsed object list (set by _load_and_build).
var _objects: Array = []  # Array[Dictionary]

# Derived track geometry (cached after _ensure_built).
var _spawn_pts: Array = []         # Array[Vector3]
var _finish_tx: Transform3D = Transform3D()
var _finish_sz: Vector3 = Vector3.ZERO
var _camera_aabb: AABB = AABB()
var _built: bool = false

# ─── Configuration ───────────────────────────────────────────────────────────

func set_map_path(path: String) -> void:
	_map_path = path

# ─── Lifecycle ───────────────────────────────────────────────────────────────

func _ready() -> void:
	# Auto-read --map= from CLI if set_map_path() was not called.
	if _map_path == "":
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--map="):
				_map_path = a.substr("--map=".length()).strip_edges()
				break
	if _map_path == "":
		push_error("CustomTrack: no map path — pass set_map_path() or --map=<path>")
		return
	_load_and_build()

# ─── Map loading ─────────────────────────────────────────────────────────────

func _load_and_build() -> void:
	if _built:
		return
	_built = true

	# 1. Read the JSON file.
	var f := FileAccess.open(_map_path, FileAccess.READ)
	if f == null:
		push_error("CustomTrack: cannot open map '%s' (err=%d)" % [_map_path, FileAccess.get_open_error()])
		return
	var text := f.get_as_text()
	f.close()

	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("CustomTrack: map '%s' is not a valid JSON object" % _map_path)
		return

	var arr = parsed.get("objects", [])
	if not (arr is Array):
		push_error("CustomTrack: map has no 'objects' array")
		return
	_objects = arr as Array

	# 2. Create ONE shared StaticBody3D for all static geometry.
	#    Tubes/troughs build their own bodies inside build_* — those are
	#    added as sibling Node3D containers (never nested PhysicsBody3D).
	var body := StaticBody3D.new()
	body.name = "CustomTrackBody"
	add_child(body)

	# 3. Dispatch each object to the appropriate builder.
	for entry in _objects:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		_build_object(body, entry as Dictionary)

	# 4. Derive track geometry descriptors from the parsed object list.
	_derive_track_geometry()

	print("[CustomTrack] loaded '%s' — %d objects, %d spawn points" \
			% [_map_path, _objects.size(), _spawn_pts.size()])

# ─── Per-object builder ───────────────────────────────────────────────────────

func _build_object(body: StaticBody3D, d: Dictionary) -> void:
	var type: String = String(d.get("type", ""))
	var pos := _vec3(d.get("position", [0.0, 0.0, 0.0]))
	var rot_y: float = float(d.get("rotation_y", 0.0))
	var scl := _vec3(d.get("scale", [1.0, 1.0, 1.0]), Vector3.ONE)
	var params: Dictionary = d.get("params", {}) as Dictionary

	match type:
		"funnel":
			_build_funnel(body, pos, rot_y, scl, params)
		"peg":
			_build_peg(body, pos, rot_y, scl, params)
		"slab":
			_build_slab(body, pos, rot_y, scl, params)
		"multiplier":
			_build_multiplier(body, pos, rot_y, scl, params)
		"tube":
			_build_tube(pos, params)
		"trough":
			_build_trough(pos, params)
		_:
			push_warning("CustomTrack: unknown object type '%s' — skipped" % type)

# ── Funnel ────────────────────────────────────────────────────────────────────
# Mirror of EditorFunnel.build_visual(). Creates a CylinderMesh cone with a
# ConcavePolygonShape3D collider (backface_collision = true so marbles
# approaching from outside and inside both collide with the wall).

func _build_funnel(body: StaticBody3D, pos: Vector3, rot_y: float,
		_scl: Vector3, p: Dictionary) -> void:
	var top_r: float    = float(p.get("top_radius",    1.20))
	var bot_r: float    = float(p.get("bottom_radius", 0.55))
	var height: float   = float(p.get("height",        1.80))
	var color: Color    = _color_from_param(p.get("color", null),
			Color(0.55, 0.85, 1.00, 0.78))

	var pivot := Transform3D(Basis(Vector3.UP, rot_y), pos)

	var cm := CylinderMesh.new()
	cm.top_radius    = top_r
	cm.bottom_radius = bot_r
	cm.height        = height
	cm.radial_segments = 28
	cm.cap_top    = false
	cm.cap_bottom = false

	var mat := StandardMaterial3D.new()
	mat.albedo_color    = color
	mat.transparency    = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode       = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	mat.metallic        = 0.15
	mat.roughness       = 0.30

	var mi := MeshInstance3D.new()
	mi.name     = "FunnelMesh"
	mi.mesh     = cm
	mi.material_override = mat
	mi.transform = pivot
	add_child(mi)   # visual: child of track, not body

	var coll := CollisionShape3D.new()
	var shape: ConcavePolygonShape3D = cm.create_trimesh_shape()
	shape.backface_collision = true
	coll.shape     = shape
	coll.transform = pivot
	body.add_child(coll)

# ── Peg ───────────────────────────────────────────────────────────────────────
# EditorPeg serialises axis ("x"/"y"/"z") + radius + height.

func _build_peg(body: StaticBody3D, pos: Vector3, rot_y: float,
		_scl: Vector3, p: Dictionary) -> void:
	var radius: float  = float(p.get("radius", 0.30))
	var height: float  = float(p.get("height", 3.0))
	var axis: String   = String(p.get("axis",   "z"))
	var color: Color   = _color_from_param(p.get("color", null),
			Color(0.95, 0.55, 0.20, 1.0))

	var axis_basis: Basis = _peg_axis_basis(axis)
	var pivot := Transform3D(Basis(Vector3.UP, rot_y) * axis_basis, pos)

	var mat := TrackBlocks.std_mat(color, 0.10, 0.45)
	TrackBlocks.add_cylinder(body, "Peg", pivot, radius, height, mat)

func _peg_axis_basis(axis: String) -> Basis:
	match axis:
		"x":
			return Basis(Vector3.FORWARD, deg_to_rad(90.0))
		"z":
			return Basis(Vector3.RIGHT,   deg_to_rad(90.0))
		_:
			return Basis.IDENTITY

# ── Slab ──────────────────────────────────────────────────────────────────────
# Box with optional tilt_deg around local Z and rotation_y around local Y.

func _build_slab(body: StaticBody3D, pos: Vector3, rot_y: float,
		_scl: Vector3, p: Dictionary) -> void:
	var sx: float       = float(p.get("size_x",   4.0))
	var sy: float       = float(p.get("size_y",   0.4))
	var sz: float       = float(p.get("size_z",   3.0))
	var tilt: float     = float(p.get("tilt_deg", 0.0))
	var color: Color    = _color_from_param(p.get("color", null),
			Color(0.55, 0.58, 0.62, 1.0))

	# Mirror EditorSlab.build_visual():
	#   basis = Basis(Z, tilt_rad) * Basis(UP, rot_y)
	var basis := Basis(Vector3(0, 0, 1), deg_to_rad(tilt)) * Basis(Vector3.UP, rot_y)
	var tx := Transform3D(basis, pos)
	var mat := TrackBlocks.std_mat(color, 0.05, 0.65)
	TrackBlocks.add_box(body, "Slab", tx, Vector3(sx, sy, sz), mat)

# ── Multiplier ────────────────────────────────────────────────────────────────
# Translucent emissive box — same box geometry as a slab, emissive material.
# Purely cosmetic / gameplay zone. Builds via add_box so the marble can land
# on it; the PickupZone mechanic (M17 payout v2) is left to the host track.

func _build_multiplier(body: StaticBody3D, pos: Vector3, rot_y: float,
		_scl: Vector3, p: Dictionary) -> void:
	var sx: float   = float(p.get("size_x",     2.0))
	var sy: float   = float(p.get("size_y",     1.2))
	var sz: float   = float(p.get("size_z",     3.0))
	var mult: float = float(p.get("multiplier", 1.0))

	var c := _multiplier_color(mult)
	var mat := StandardMaterial3D.new()
	mat.albedo_color              = Color(c.r, c.g, c.b, 0.55)
	mat.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode           = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	mat.emission_enabled          = true
	mat.emission                  = c
	mat.emission_energy_multiplier = 0.45

	var tx := Transform3D(Basis(Vector3.UP, rot_y), pos)
	# Use add_box but override the material after — it uses std_mat internally,
	# so we manually add collision + mesh here to keep the emissive look.
	var coll := CollisionShape3D.new()
	coll.name = "MultShape"
	coll.transform = tx
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(sx, sy, sz)
	coll.shape = box_shape
	body.add_child(coll)

	var mi := MeshInstance3D.new()
	mi.name = "MultMesh"
	mi.transform = tx
	var bm := BoxMesh.new()
	bm.size = Vector3(sx, sy, sz)
	mi.mesh = bm
	mi.material_override = mat
	add_child(mi)

	# Multiplier label.
	var label := Label3D.new()
	label.text          = "x%s" % _fmt_mult(mult)
	label.billboard     = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size    = 0.012
	label.font_size     = 32
	label.outline_size  = 4
	label.modulate      = Color(1, 1, 1)
	label.position      = pos + Vector3(0, sy * 0.5 + 0.4, 0)
	add_child(label)

func _multiplier_color(m: float) -> Color:
	if m >= 5.0: return Color(1.0, 0.20, 0.30)
	if m >= 2.0: return Color(1.0, 0.65, 0.20)
	if m >= 1.0: return Color(1.0, 0.95, 0.40)
	if m >= 0.5: return Color(0.55, 0.85, 1.00)
	return Color(0.45, 0.55, 0.70)

static func _fmt_mult(m: float) -> String:
	if is_equal_approx(m, round(m)):
		return "%d" % int(round(m))
	return "%.1f" % m

# ── Tube ──────────────────────────────────────────────────────────────────────
# Swept tube — identical to EditorTube.build_visual() but targeting a plain
# Node3D parent (never a PhysicsBody3D — per Jolt bugfixes.md rule).
# Collision trimesh is created under a sibling StaticBody3D.

func _build_tube(origin: Vector3, p: Dictionary) -> void:
	var radius: float       = float(p.get("radius",        0.6))
	var section_verts: int  = int(p.get("section_verts",  18))
	var color: Color        = _color_from_param(p.get("color", null),
			Color(0.55, 0.85, 1.00, 1.00))

	var waypoints: Array = _load_waypoints(p.get("waypoints", []))
	var roll_degrees: Array = _load_floats(p.get("roll_degrees", []))
	var scale_multipliers: Array = _load_floats(p.get("scale_multipliers", []))
	_pad_float_array(roll_degrees, waypoints.size(), 0.0)
	_pad_float_array(scale_multipliers, waypoints.size(), 1.0)

	if waypoints.size() < 2:
		push_warning("CustomTrack: tube has <2 waypoints — skipped")
		return

	# Shift waypoints to world space (editor stores them LOCAL to the
	# object's position, which matches how EditorTube works).
	var world_wps: Array = []
	for wp in waypoints:
		world_wps.append((wp as Vector3) + origin)

	# Visual container: plain Node3D so MeshInstance3D children never
	# land inside a PhysicsBody3D.
	var container := Node3D.new()
	container.name = "TubeContainer"
	add_child(container)

	var pipe_mat := StandardMaterial3D.new()
	pipe_mat.albedo_color = Color(color.r, color.g, color.b, 1.0)
	pipe_mat.metallic     = 0.10
	pipe_mat.roughness    = 0.30

	var inner_r: float = radius * 0.78
	var outer_mi: MeshInstance3D = TrackBlocks.add_smooth_tube(container,
			"TubeOuter", world_wps, radius, pipe_mat, 0.25, section_verts,
			false, -1.0, roll_degrees, scale_multipliers)
	TrackBlocks.add_smooth_tube(container,
			"TubeInner", world_wps, inner_r, pipe_mat, 0.25, section_verts,
			true, -1.0, roll_degrees, scale_multipliers)
	TrackBlocks.add_smooth_tube_caps(container, "TubeCaps", world_wps,
			radius, inner_r, pipe_mat, 0.25, section_verts,
			roll_degrees, scale_multipliers)

	# Collision: StaticBody3D sibling of the container.
	if outer_mi != null and outer_mi.mesh != null:
		var tube_body := StaticBody3D.new()
		tube_body.name = "TubeBody"
		add_child(tube_body)
		var coll := CollisionShape3D.new()
		var trimesh: ConcavePolygonShape3D = outer_mi.mesh.create_trimesh_shape()
		trimesh.backface_collision = true
		coll.shape = trimesh
		tube_body.add_child(coll)

# ── Trough ────────────────────────────────────────────────────────────────────
# Open-top swept channel — mirror of EditorTrough.build_visual().

func _build_trough(origin: Vector3, p: Dictionary) -> void:
	var radius: float       = float(p.get("radius",         0.6))
	var arc_sweep: float    = float(p.get("arc_sweep_deg",  210.0))
	var section_verts: int  = int(p.get("section_verts",   18))
	var color: Color        = _color_from_param(p.get("color", null),
			Color(0.55, 0.85, 1.00, 1.00))

	var waypoints: Array    = _load_waypoints(p.get("waypoints", []))
	var roll_degrees: Array = _load_floats(p.get("roll_degrees", []))
	var scale_mult: Array   = _load_floats(p.get("scale_multipliers", []))
	var sweeps_deg: Array   = _load_floats(p.get("sweeps_deg", []))
	_pad_float_array(roll_degrees,   waypoints.size(), 0.0)
	_pad_float_array(scale_mult,     waypoints.size(), 1.0)
	_pad_float_array(sweeps_deg,     waypoints.size(), arc_sweep)

	if waypoints.size() < 2:
		push_warning("CustomTrack: trough has <2 waypoints — skipped")
		return

	var world_wps: Array = []
	for wp in waypoints:
		world_wps.append((wp as Vector3) + origin)

	var container := Node3D.new()
	container.name = "TroughContainer"
	add_child(container)

	var pipe_mat := StandardMaterial3D.new()
	pipe_mat.albedo_color = color
	pipe_mat.metallic     = 0.10
	pipe_mat.roughness    = 0.30
	pipe_mat.cull_mode    = BaseMaterial3D.CULL_DISABLED

	var mi: MeshInstance3D = TrackBlocks.add_smooth_trough(container,
			"TroughMesh", world_wps, roll_degrees, radius,
			arc_sweep, pipe_mat, 0.25, section_verts,
			radius * 0.78, scale_mult, sweeps_deg)

	if mi != null and mi.mesh != null:
		var trough_body := StaticBody3D.new()
		trough_body.name = "TroughBody"
		add_child(trough_body)
		var coll := CollisionShape3D.new()
		var trimesh: ConcavePolygonShape3D = mi.mesh.create_trimesh_shape()
		trimesh.backface_collision = true
		coll.shape = trimesh
		trough_body.add_child(coll)

# ─── Track geometry derivation ───────────────────────────────────────────────
#
# Spawn convention:
#   - The first "funnel" object becomes the spawn anchor. Marbles are
#     placed in a 6×5 grid (or square-root-based grid for any count)
#     centred on the funnel's position, at the top of its opening.
#   - If no funnel exists, fall back to the bounding-box top centre.
#
# Finish convention:
#   - The LAST "slab" or "multiplier" object is the finish plane.
#   - If neither exists, use the bounding-box bottom.
#
# These are intentionally simple heuristics — a map author can always
# order their objects to steer the spawn/finish picks.  A future version
# may add explicit "spawn_anchor" / "finish_anchor" object types.

func _derive_track_geometry() -> void:
	var funnel_entry: Dictionary = {}
	var finish_entry: Dictionary = {}
	var all_positions: Array = []

	for d in _objects:
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var type: String = String(d.get("type", ""))
		var pos := _vec3(d.get("position", [0.0, 0.0, 0.0]))
		all_positions.append(pos)
		if type == "funnel" and funnel_entry.is_empty():
			funnel_entry = d
		if type == "slab" or type == "multiplier":
			finish_entry = d

	# Bounding box of all object origins (used as fallback).
	var bbox := AABB()
	for i in range(all_positions.size()):
		if i == 0:
			bbox = AABB(all_positions[0], Vector3.ZERO)
		else:
			bbox = bbox.expand(all_positions[i])
	# Grow by a generous margin so moving obstacles and tube extents are framed.
	bbox = bbox.grow(3.0)
	_camera_aabb = bbox

	# ── Spawn grid ────────────────────────────────────────────────────────────
	# Target: SpawnRail.SLOT_COUNT = 32. Build a grid centred on the funnel
	# (or fallback centre) using the funnel top_radius as lane spacing.
	var spawn_centre: Vector3
	var spawn_radius: float = 1.20   # default funnel top_radius
	if not funnel_entry.is_empty():
		var fp := _vec3(funnel_entry.get("position", [0.0, 0.0, 0.0]))
		var fh: float = float(funnel_entry.get("params", {}).get("height", 1.80))
		spawn_centre = fp + Vector3(0, fh * 0.5, 0)
		spawn_radius = float(funnel_entry.get("params", {}).get("top_radius", 1.20))
	else:
		spawn_centre = Vector3(bbox.position.x + bbox.size.x * 0.5,
				bbox.position.y + bbox.size.y,
				bbox.position.z + bbox.size.z * 0.5)

	# 32-point grid: 6 cols × 5 rows + 2 extras in a 7th row = 32. Place
	# as a hexagonal spiral capped to 32 so distribution is even and no
	# two spawn points overlap.
	_spawn_pts = _make_spawn_grid(spawn_centre, spawn_radius, SpawnRail.SLOT_COUNT)

	# ── Finish area ───────────────────────────────────────────────────────────
	if not finish_entry.is_empty():
		var fp := _vec3(finish_entry.get("position", [0.0, 0.0, 0.0]))
		var rot_y: float = float(finish_entry.get("rotation_y", 0.0))
		var params: Dictionary = finish_entry.get("params", {}) as Dictionary
		var sx: float = float(params.get("size_x", 4.0))
		var sy: float = float(params.get("size_y", 0.4))
		var sz: float = float(params.get("size_z", 3.0))
		var basis := Basis(Vector3.UP, rot_y)
		_finish_tx = Transform3D(basis, fp)
		_finish_sz = Vector3(sx, max(sy, 0.6), sz)
	else:
		# Fall back: invisible finish plane at the bottom of the AABB.
		var bot := Vector3(
				bbox.position.x + bbox.size.x * 0.5,
				bbox.position.y,
				bbox.position.z + bbox.size.z * 0.5)
		_finish_tx = Transform3D(Basis.IDENTITY, bot)
		_finish_sz = Vector3(bbox.size.x * 0.9, 0.6, bbox.size.z * 0.9)

# Build `count` spawn points around `centre` as a tight hex grid,
# spacing proportional to `radius / 2`. Returns exactly `count` points.
static func _make_spawn_grid(centre: Vector3, radius: float, count: int) -> Array:
	var pts: Array = []
	if count <= 0:
		return pts
	# Spacing: half the funnel opening so marbles can spread out.
	var spacing: float = max(radius * 0.5, 0.15)
	# Simple row-major rectangular grid (col, row) centred at zero.
	# Hex-stagger every other row by spacing/2 along X.
	var cols: int = ceili(sqrt(float(count)))
	var rows: int = ceili(float(count) / float(cols))
	var idx: int = 0
	for row in range(rows):
		var x_offset: float = 0.0 if (row % 2 == 0) else spacing * 0.5
		for col in range(cols):
			if idx >= count:
				break
			var x: float = (float(col) - float(cols - 1) * 0.5) * spacing + x_offset
			var z: float = (float(row) - float(rows - 1) * 0.5) * spacing
			pts.append(centre + Vector3(x, 0.0, z))
			idx += 1
		if idx >= count:
			break
	# If we fell short (rounding), duplicate last point to fill.
	while pts.size() < count:
		pts.append(pts.back())
	return pts

# ─── Track interface overrides ───────────────────────────────────────────────

func spawn_points() -> Array:
	_ensure_built()
	return _spawn_pts

func finish_area_transform() -> Transform3D:
	_ensure_built()
	return _finish_tx

func finish_area_size() -> Vector3:
	_ensure_built()
	return _finish_sz

func camera_bounds() -> AABB:
	_ensure_built()
	return _camera_aabb

# _ensure_built() supports the "plain math object" verifier path (track is NOT
# added to the scene tree). We parse the JSON and compute geometry without
# spawning any physics nodes.
func _ensure_built() -> void:
	if _built:
		return
	_built = true
	if _map_path == "":
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--map="):
				_map_path = a.substr("--map=".length()).strip_edges()
				break
	if _map_path == "":
		push_error("CustomTrack._ensure_built: no map path — spawn_points/finish will be empty")
		return

	var f := FileAccess.open(_map_path, FileAccess.READ)
	if f == null:
		push_error("CustomTrack._ensure_built: cannot open '%s' (err=%d)" % [_map_path, FileAccess.get_open_error()])
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var arr = parsed.get("objects", [])
	if arr is Array:
		_objects = arr as Array
	_derive_track_geometry()
	# NOTE: _ensure_built() does NOT spawn physics geometry — only geometry-
	# derivation is done. Physics geometry is created in _ready() → _load_and_build().

# ─── Utility helpers ─────────────────────────────────────────────────────────

static func _vec3(v, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if v is Array and (v as Array).size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return fallback

static func _color_from_param(c, fallback: Color) -> Color:
	if c is Array and (c as Array).size() >= 4:
		return Color(float(c[0]), float(c[1]), float(c[2]), float(c[3]))
	return fallback

static func _load_waypoints(raw) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for entry in (raw as Array):
		if entry is Array and (entry as Array).size() >= 3:
			out.append(Vector3(float(entry[0]), float(entry[1]), float(entry[2])))
	return out

static func _load_floats(raw) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for entry in (raw as Array):
		out.append(float(entry))
	return out

static func _pad_float_array(arr: Array, target_size: int, fill: float) -> void:
	while arr.size() < target_size:
		arr.append(fill)
	while arr.size() > target_size:
		arr.pop_back()
