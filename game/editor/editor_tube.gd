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
var color: Color = Color(0.55, 0.85, 1.00, 1.00)

const MARKER_RADIUS := 0.18

func get_object_type() -> String:
	return "tube"

func build_visual() -> void:
	if waypoints.size() < 2:
		# Not enough waypoints yet — render just markers so the user
		# sees where their first click landed.
		_build_markers()
		return

	# Opaque material — the user explicitly rejected the translucent
	# look ('its transparent now I hate that'). Default rendering
	# pipeline, no alpha, no special depth-draw modes.
	var pipe_mat := StandardMaterial3D.new()
	pipe_mat.albedo_color = Color(color.r, color.g, color.b, 1.0)
	pipe_mat.metallic = 0.10
	pipe_mat.roughness = 0.30

	# Inner shell sits at 78% of outer radius — a clearly visible 22%
	# wall thickness so the tube reads as substantial, not paper-thin.
	var inner_r: float = radius * 0.78
	var outer: MeshInstance3D = TrackBlocks.add_smooth_tube(self,
			"TubeOuter", waypoints, radius, pipe_mat, 0.25, section_verts)
	TrackBlocks.add_smooth_tube(self, "TubeInner", waypoints,
			inner_r, pipe_mat, 0.25, section_verts, true)

	# FLANGE rims at the first/last waypoints — a flat ring sticking
	# OUT beyond the tube's outer wall (inner edge = tube outer wall,
	# outer edge = tube wall + 0.2 m). Reads as a proper pipe-end
	# fitting/border around the opening, instead of an internal
	# annulus that's hidden by the tube body. The bore stays clear
	# all the way through.
	_build_endpoint_annuli(radius + 0.20, radius, pipe_mat)

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

# Flat annular caps at each tube end. Each cap is the ring you'd see
# if you cut the tube with a perpendicular plane: outer radius =
# tube outer wall, inner radius = inner shell. Lets the user see the
# wall thickness as a real visible rim instead of a 1D line.
func _build_endpoint_annuli(outer_r: float, inner_r: float, mat: Material) -> void:
	if waypoints.size() < 2:
		return
	for endpoint_idx in [0, waypoints.size() - 1]:
		var p: Vector3 = waypoints[endpoint_idx]
		# Tangent direction at the endpoint. The annulus' normal points
		# OUTWARD from the tube (away from the next interior waypoint).
		var t: Vector3
		if endpoint_idx == 0:
			t = (waypoints[0] as Vector3) - (waypoints[1] as Vector3)
		else:
			var n := waypoints.size()
			t = (waypoints[n - 1] as Vector3) - (waypoints[n - 2] as Vector3)
		if t.length() < 0.001:
			continue
		t = t.normalized()
		# Build orthonormal basis with `right` and `up` perpendicular to
		# `t`. Pick a stable reference axis not parallel to the tangent.
		var ref := Vector3.UP
		if absf(t.dot(ref)) > 0.95:
			ref = Vector3.RIGHT
		var right: Vector3 = t.cross(ref).normalized()
		var up: Vector3 = right.cross(t).normalized()

		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var n_seg: int = section_verts
		# Emit (outer, inner) vertex pairs around the ring.
		for j in range(n_seg):
			var theta: float = TAU * float(j) / float(n_seg)
			var dx: float = cos(theta)
			var dy: float = sin(theta)
			var outer_v: Vector3 = p + right * (dx * outer_r) + up * (dy * outer_r)
			var inner_v: Vector3 = p + right * (dx * inner_r) + up * (dy * inner_r)
			st.set_uv(Vector2(float(j) / float(n_seg), 0.0))
			st.add_vertex(outer_v)
			st.set_uv(Vector2(float(j) / float(n_seg), 1.0))
			st.add_vertex(inner_v)
		# Triangulate the annulus. Winding chosen so the visible normal
		# points along `t` (outward from the tube interior).
		for j in range(n_seg):
			var j2: int = (j + 1) % n_seg
			var o0: int = j * 2
			var i0: int = j * 2 + 1
			var o1: int = j2 * 2
			var i1: int = j2 * 2 + 1
			st.add_index(o0); st.add_index(i0); st.add_index(o1)
			st.add_index(o1); st.add_index(i0); st.add_index(i1)
		st.generate_normals()
		st.generate_tangents()
		var mesh: ArrayMesh = st.commit()
		var mi := MeshInstance3D.new()
		mi.name = "EndAnnulus_%d" % endpoint_idx
		mi.mesh = mesh
		mi.material_override = mat
		add_child(mi)

		# No disk over the bore — user wants the hole left clear; just
		# the annular rim above showing the wall thickness as a
		# 'proper border'.

# _build_endpoint_disk removed. User explicitly: "remove this freaking
# circle in the middle and do an actual proper border". The annular
# rim built in _build_endpoint_annuli is the border; the bore stays
# open.

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
