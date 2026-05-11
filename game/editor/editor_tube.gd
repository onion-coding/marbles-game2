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

	_build_markers()

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
