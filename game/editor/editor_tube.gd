class_name EditorTube
extends EditorObject

# Editable tube. Path = list of local-space waypoints (offsets from
# obj.position). The visible mesh is built by sweeping a circular
# cross-section along the polyline via TrackBlocks.add_smooth_tube,
# which Catmull-Rom-interpolates the corners so a 3-point polyline
# turns into a curved tube without needing the user to plant
# fine-grained waypoints.
#
# When selected, small orange sphere markers render at each waypoint
# so the user can see the path structure (and, in Phase 3, drag them
# directly in the viewport).

var waypoints: Array = []                       # Array[Vector3] LOCAL
var radius: float = 0.6
var section_verts: int = 18
var color: Color = Color(0.55, 0.85, 1.00, 0.78)

const MARKER_RADIUS := 0.18

func get_object_type() -> String:
	return "tube"

func build_visual() -> void:
	if waypoints.size() < 2:
		# Not enough waypoints yet — render just markers so the user
		# sees where their first click landed.
		_build_markers()
		return

	var pipe_mat := StandardMaterial3D.new()
	pipe_mat.albedo_color = color
	pipe_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pipe_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	pipe_mat.metallic = 0.10
	pipe_mat.roughness = 0.30

	# Outer shell.
	var outer: MeshInstance3D = TrackBlocks.add_smooth_tube(self,
			"TubeOuter", waypoints, radius, pipe_mat, 0.25, section_verts)
	# Inner shell with inverted winding so the inside is visible from
	# inside the tube without lighting bands.
	TrackBlocks.add_smooth_tube(self, "TubeInner", waypoints,
			radius * 0.92, pipe_mat, 0.25, section_verts, true)

	# Collision: trimesh from the outer mesh, two-sided.
	if outer != null and outer.mesh != null:
		var body := StaticBody3D.new()
		body.name = "TubeBody"
		var coll := CollisionShape3D.new()
		var trimesh: ConcavePolygonShape3D = outer.mesh.create_trimesh_shape()
		trimesh.backface_collision = true
		coll.shape = trimesh
		body.add_child(coll)
		add_child(body)

	# Endpoint rings (torus markers at first/last waypoints) removed —
	# they didn't align cleanly with the tube tangent and read as
	# crumpled ribbons instead of clean rims. The swept mesh's open
	# ends are visible on their own, and the orange waypoint markers
	# (selection-only) tell the user where the path stops.
	_build_markers()

# Open-ring markers (torus) at the FIRST and LAST waypoints, always
# visible (not gated by selection). Tells the user where the tube
# begins and ends without sealing the openings — a marble dropped at
# the entry sees a clear hole, not a blocking disc.
func _build_endpoint_caps() -> void:
	if waypoints.size() < 2:
		return
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = Color(color.r, color.g, color.b, 1.0)
	cap_mat.emission_enabled = true
	cap_mat.emission = color
	cap_mat.emission_energy_multiplier = 0.45
	for ends in [0, waypoints.size() - 1]:
		var cap := MeshInstance3D.new()
		cap.name = "EndRing_%d" % ends
		var tm := TorusMesh.new()
		# Ring's hole = tube interior, outer rim = slightly outside the
		# tube wall so the marker is visible as a tinted ring without
		# obstructing the opening.
		tm.inner_radius = radius * 0.95
		tm.outer_radius = radius * 1.18
		tm.ring_segments = 32
		tm.rings = 12
		cap.mesh = tm
		cap.material_override = cap_mat
		cap.position = waypoints[ends]
		# Orient the cap perpendicular to the tube's tangent at this
		# waypoint so the disc faces along the pipe rather than always
		# standing upright in world space.
		var neighbour_idx: int = (ends + 1) if ends == 0 else (ends - 1)
		var tangent: Vector3 = (waypoints[neighbour_idx] as Vector3) - (waypoints[ends] as Vector3)
		if tangent.length() > 0.01:
			tangent = tangent.normalized()
			# Cylinder's local +Y axis should point along the tangent
			# (toward the neighbouring waypoint for "entry", away for
			# "exit" — flipping doesn't change the appearance of an
			# axis-symmetric disc).
			cap.basis = _basis_with_up(tangent)
		add_child(cap)

static func _basis_with_up(up_dir: Vector3) -> Basis:
	var u := up_dir.normalized()
	var ref := Vector3.RIGHT
	if absf(u.dot(ref)) > 0.95:
		ref = Vector3.FORWARD
	var right := u.cross(ref).normalized()
	var forward := right.cross(u).normalized()
	return Basis(right, u, forward)

func _build_markers() -> void:
	# Small unshaded spheres at each waypoint so the user can read the
	# tube's path through space. Hidden by default; the selection
	# highlight in set_selected toggles them on.
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
	# Reuse the base-class emission tint, then ALSO toggle the path
	# markers so an unselected tube reads as a clean glass channel
	# without orange dots cluttering its length.
	super.set_selected(sel)
	for c in get_children():
		if c is MeshInstance3D and String(c.name).begins_with("Waypoint_"):
			c.visible = sel

# Append a NEW waypoint (in local space, relative to obj.position).
# Used by MapEditor during the multi-click placement flow.
func append_waypoint_local(local_pos: Vector3) -> void:
	waypoints.append(local_pos)
	rebuild_visual()

func append_waypoint_world(world_pos: Vector3) -> void:
	append_waypoint_local(world_pos - global_position)

func get_params() -> Dictionary:
	# Waypoints serialise as nested arrays so JSON round-trips cleanly.
	var wps: Array = []
	for w in waypoints:
		wps.append([float(w.x), float(w.y), float(w.z)])
	return {
		"radius": radius,
		"section_verts": section_verts,
		"color": [color.r, color.g, color.b, color.a],
		"waypoints": wps,
	}

func apply_params(d: Dictionary) -> void:
	radius = float(d.get("radius", radius))
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
	rebuild_visual()
