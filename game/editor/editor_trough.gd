class_name EditorTrough
extends EditorObject

# Open swept channel — like a water slide / luge track. Cross-section
# is a partial arc (default ~210°, configurable 50–280°) so the top
# stays OPEN, marbles ride along the inner curve. Each waypoint has
# its own ROLL angle (degrees around the tangent) so the user can
# bank the slide around turns — opening faces inward on a left curve,
# outward on a right curve, vertical on straights, anything in between.
#
# Path = Array[Vector3] in LOCAL space. roll_degrees = Array[float],
# one entry per waypoint, defaulted to 0 when a new waypoint is added.
# Roll is interpolated smoothly between waypoints via Curve3D's
# built-in tilt facility.

var waypoints: Array = []                # Array[Vector3] local
var roll_degrees: Array = []             # Array[float], one per waypoint
var scale_multipliers: Array = []        # Array[float], one per waypoint (default 1.0)
var sweeps_deg: Array = []               # Array[float], one per waypoint (default arc_sweep_deg)
var radius: float = 0.6                  # matches EditorTube default
var arc_sweep_deg: float = 210.0         # how many degrees of the cross-section
                                          # are SOLID (the rest is the open top)
                                          # — used as the default for waypoints
                                          # missing an entry in sweeps_deg.
var section_verts: int = 18
var color: Color = Color(0.55, 0.85, 1.00, 1.00)
# Inner-wall radius ratio matches the tube's 78% — same visible wall
# thickness. Set via radius * INNER_RATIO at build time.
const INNER_RATIO := 0.78

const MARKER_RADIUS := 0.18

func get_object_type() -> String:
	return "trough"

func build_visual() -> void:
	if waypoints.size() < 2:
		_build_markers()
		return
	# Trough wall material — opaque, two-sided so the marble's view
	# from inside the channel renders the same as the spectator view
	# from outside. The half-pipe is thin enough that the front/back
	# lighting bands typical of CULL_DISABLED on curved geometry don't
	# show meaningfully at this scale.
	var pipe_mat := StandardMaterial3D.new()
	pipe_mat.albedo_color = color
	pipe_mat.metallic = 0.10
	pipe_mat.roughness = 0.30
	pipe_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mesh_inst: MeshInstance3D = TrackBlocks.add_smooth_trough(self,
			"TroughMesh", waypoints, roll_degrees, radius,
			arc_sweep_deg, pipe_mat, 0.25, section_verts,
			radius * INNER_RATIO, scale_multipliers, sweeps_deg)
	if mesh_inst != null and mesh_inst.mesh != null:
		var body := StaticBody3D.new()
		body.name = "TroughBody"
		var coll := CollisionShape3D.new()
		var trimesh: ConcavePolygonShape3D = mesh_inst.mesh.create_trimesh_shape()
		trimesh.backface_collision = true
		coll.shape = trimesh
		body.add_child(coll)
		add_child(body)
	_build_markers()

func _build_markers() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.55, 0.2, 1.0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for i in range(waypoints.size()):
		var marker := MeshInstance3D.new()
		marker.name = "Waypoint_%d" % i
		var sm := SphereMesh.new()
		sm.radius = MARKER_RADIUS
		sm.height = MARKER_RADIUS * 2.0
		sm.radial_segments = 12
		sm.rings = 8
		marker.mesh = sm
		marker.material_override = mat
		marker.position = waypoints[i]
		marker.visible = _selected
		add_child(marker)

func set_selected(sel: bool) -> void:
	super.set_selected(sel)
	for c in get_children():
		if c is MeshInstance3D and String(c.name).begins_with("Waypoint_"):
			c.visible = sel

# MapEditor's multi-click placement appends waypoints one-by-one. Same
# interface as EditorTube; roll/scale/sweep default per click (roll=0,
# scale=1.0, sweep=current arc_sweep_deg) — user tweaks afterwards via
# the property panel.
func append_waypoint_local(local_pos: Vector3) -> void:
	waypoints.append(local_pos)
	roll_degrees.append(0.0)
	scale_multipliers.append(1.0)
	sweeps_deg.append(arc_sweep_deg)
	rebuild_visual()

func append_waypoint_world(world_pos: Vector3) -> void:
	append_waypoint_local(world_pos - global_position)

func get_params() -> Dictionary:
	var wps: Array = []
	for w in waypoints:
		wps.append([float(w.x), float(w.y), float(w.z)])
	var rolls: Array = []
	for r in roll_degrees:
		rolls.append(float(r))
	var scales: Array = []
	for s in scale_multipliers:
		scales.append(float(s))
	var sweeps: Array = []
	for sw in sweeps_deg:
		sweeps.append(float(sw))
	return {
		"radius": radius,
		"arc_sweep_deg": arc_sweep_deg,
		"section_verts": section_verts,
		"color": [color.r, color.g, color.b, color.a],
		"waypoints": wps,
		"roll_degrees": rolls,
		"scale_multipliers": scales,
		"sweeps_deg": sweeps,
	}

func apply_params(d: Dictionary) -> void:
	radius = float(d.get("radius", radius))
	# arc_sweep_deg now ranges up to 360° so a Trough can be fully
	# enclosed at a waypoint (acts like a closed tube section there).
	arc_sweep_deg = clampf(float(d.get("arc_sweep_deg", arc_sweep_deg)), 30.0, 360.0)
	section_verts = int(d.get("section_verts", section_verts))
	var c = d.get("color", null)
	if c is Array and c.size() >= 4:
		color = Color(float(c[0]), float(c[1]), float(c[2]), float(c[3]))
	var w = d.get("waypoints", null)
	if w is Array:
		waypoints.clear()
		for entry in w:
			if entry is Array and entry.size() >= 3:
				waypoints.append(Vector3(float(entry[0]), float(entry[1]), float(entry[2])))
	var r_arr = d.get("roll_degrees", null)
	if r_arr is Array:
		roll_degrees.clear()
		for entry in r_arr:
			roll_degrees.append(float(entry))
	var s_arr = d.get("scale_multipliers", null)
	if s_arr is Array:
		scale_multipliers.clear()
		for entry in s_arr:
			scale_multipliers.append(float(entry))
	var sw_arr = d.get("sweeps_deg", null)
	if sw_arr is Array:
		sweeps_deg.clear()
		for entry in sw_arr:
			sweeps_deg.append(float(entry))
	# Keep per-waypoint arrays length-aligned with waypoints. New entries
	# pick up sensible defaults (roll 0, scale 1.0, sweep = global default)
	# so old saves missing these fields load cleanly.
	while roll_degrees.size() < waypoints.size():
		roll_degrees.append(0.0)
	while roll_degrees.size() > waypoints.size():
		roll_degrees.pop_back()
	while scale_multipliers.size() < waypoints.size():
		scale_multipliers.append(1.0)
	while scale_multipliers.size() > waypoints.size():
		scale_multipliers.pop_back()
	while sweeps_deg.size() < waypoints.size():
		sweeps_deg.append(arc_sweep_deg)
	while sweeps_deg.size() > waypoints.size():
		sweeps_deg.pop_back()
	rebuild_visual()
