class_name CurveDemoTrack
extends Track

# CurveDemoTrack — proof-of-quality curved slide (v2: closed shell).
#
# Builds a smooth curved half-pipe slide as a single ArrayMesh:
#
#   - Curve3D defines the 3D Bezier spline (slide centreline).
#   - Cross-section is a CLOSED 2D loop with thickness: inner half-circle
#     (where marbles roll) + top lip rim + outer half-circle (visible
#     exterior). No open edges anywhere.
#   - The cross-section is swept along the path using parallel-transport
#     frames (no Frenet flips on straight runs).
#   - Both ends are CAPPED — the cross-section is triangulated as a
#     half-annulus at start and finish, so there are no open tube mouths.
#   - One indexed ArrayMesh, smooth-shaded by SurfaceTool.generate_normals.
#   - Collision: ConcavePolygonShape3D built from the same mesh.
#
# Differences from v1:
#   - v1 used a single half-circle profile (open back, no thickness). With
#     CULL_DISABLED on the material, the back faces were visible with
#     wrong normals → striping artifacts at the lips.
#   - v1 left the tube ends open → visible wedge protrusions in screenshots.
#   - v2 is a closed shell: no CULL_DISABLED needed, no open ends.

# ─── Geometry parameters ────────────────────────────────────────────────────

const R_INNER     := 2.45         # marble-rolling radius
const WALL_THICK  := 0.25         # outer surface offset; lip width
const PATH_SAMPLES   := 160       # rings along the spline (smooth shading)
const SECTION_VERTS  := 28        # vertices per cross-section arc
const SPAWN_Y_LIFT   := 3.0       # marbles spawn this high above path[0]
# Cross-section sweep angle. PI = half-pipe (180°, open U). 4*PI/3 = 240°
# (lips curl inward 30° past vertical on each side). With marbles
# spawning straight down into the opening, 240° still has a wide enough
# mouth to drop into, but at speed and on the S-bends the marbles
# physically can't escape over the lips.
const ARC_SWEEP   := PI * 4.0 / 3.0

# Derived: outer radius for the exterior surface.
const R_OUTER := R_INNER + WALL_THICK

# Spawn / finish anchors, computed in _build_slide.
var _spawn_anchor: Vector3 = Vector3.ZERO
var _finish_pos: Vector3 = Vector3.ZERO

# ─── Build ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	var path := _build_path()
	_build_slide(path)
	_build_finish_slab()

func _build_path() -> Curve3D:
	var c := Curve3D.new()
	c.bake_interval = 0.25
	c.add_point(Vector3(  0.0, 22.0,   0.0), Vector3.ZERO,             Vector3( 0.0, -2.0,  4.0))
	c.add_point(Vector3(  6.0, 17.0,   8.0), Vector3(-4.0,  1.0, -2.0), Vector3( 4.0, -1.0,  2.0))
	c.add_point(Vector3( -6.0, 11.0,  16.0), Vector3( 4.0,  1.0, -2.0), Vector3(-4.0, -1.0,  2.0))
	c.add_point(Vector3(  4.0,  5.0,  24.0), Vector3(-4.0,  1.0, -2.0), Vector3( 4.0, -1.0,  2.0))
	c.add_point(Vector3(  0.0,  0.5,  32.0), Vector3(-3.0,  1.0, -3.0), Vector3.ZERO)
	return c

func _build_slide(path: Curve3D) -> void:
	# 1. Sample path uniformly + central-difference tangents.
	var path_length := path.get_baked_length()
	var samples: Array[Vector3] = []
	for i in range(PATH_SAMPLES + 1):
		var s := float(i) / float(PATH_SAMPLES) * path_length
		samples.append(path.sample_baked(s, true))

	var tangents: Array[Vector3] = []
	tangents.resize(samples.size())
	tangents[0] = (samples[1] - samples[0]).normalized()
	tangents[samples.size() - 1] = (samples[samples.size() - 1] - samples[samples.size() - 2]).normalized()
	for i in range(1, samples.size() - 1):
		tangents[i] = (samples[i + 1] - samples[i - 1]).normalized()

	# 2. Parallel-transport frames (right, up per ring).
	var rights: Array[Vector3] = []
	var ups: Array[Vector3] = []
	rights.resize(samples.size())
	ups.resize(samples.size())
	var seed_ref := Vector3.RIGHT
	if absf(tangents[0].dot(seed_ref)) > 0.9:
		seed_ref = Vector3.FORWARD
	var r0 := (seed_ref - tangents[0] * seed_ref.dot(tangents[0])).normalized()
	var u0 := tangents[0].cross(r0).normalized()
	if u0.dot(Vector3.UP) < 0.0:
		r0 = -r0
		u0 = -u0
	rights[0] = r0
	ups[0] = u0
	for i in range(1, samples.size()):
		var t := tangents[i]
		var r := rights[i - 1] - t * rights[i - 1].dot(t)
		if r.length() < 0.001:
			r = Vector3.RIGHT - t * Vector3.RIGHT.dot(t)
		r = r.normalized()
		var u := t.cross(r).normalized()
		if u.dot(Vector3.UP) < 0.0:
			r = -r
			u = -u
		rights[i] = r
		ups[i] = u

	# 3. Closed cross-section profile (Vector2 in (right, up) plane).
	#
	# Layout going around the loop CCW when viewed from the slide's "forward"
	# direction:
	#
	#       outer_top_L  outer_top_R       (y = 0,        x = ±R_OUTER)
	#       |                   |
	#       lip_inner_L         lip_inner_R (y = 0,       x = ±R_INNER)
	#       |                   |
	#       inner_circle (rolling surface, sweeps PI..2PI at R_INNER)
	#       |
	#       outer_circle (visible exterior, sweeps 2PI..PI at R_OUTER, reverse)
	#
	# Total verts per ring: 2*(SECTION_VERTS+1) + 2 lip-bridge pairs.
	#
	# We index this single closed loop and stitch it ring-to-ring.

	var profile: Array[Vector2] = []
	var n_outer := SECTION_VERTS + 1
	var n_inner := SECTION_VERTS + 1

	# Sweep range centred on "down" (1.5 PI). ARC_SWEEP = PI is a flat
	# half-pipe (180°); ARC_SWEEP = 4PI/3 makes the lips curl 30° inward
	# past vertical so marbles can't fly out over the rim on the bends.
	var sweep_half: float = ARC_SWEEP * 0.5
	var ang_start: float = 1.5 * PI - sweep_half   # left lip
	var ang_end: float   = 1.5 * PI + sweep_half   # right lip

	# (a) Outer arc, ang_start (left lip outer) → ang_end (right lip outer).
	for j in range(n_outer):
		var theta: float = ang_start + ARC_SWEEP * float(j) / float(SECTION_VERTS)
		profile.append(Vector2(cos(theta), sin(theta)) * R_OUTER)
	# (b) Right lip bridge: outer at ang_end → inner at ang_end (= where the
	#     inner arc begins). Single point that connects R_OUTER to R_INNER
	#     at the same angle.
	profile.append(Vector2(cos(ang_end), sin(ang_end)) * R_INNER)
	# (c) Inner arc, ang_end (right lip inner) → ang_start (left lip inner),
	#     traversed in REVERSE so the closed loop keeps a consistent winding.
	for j in range(n_inner):
		var theta_in: float = ang_end - ARC_SWEEP * float(j) / float(SECTION_VERTS)
		profile.append(Vector2(cos(theta_in), sin(theta_in)) * R_INNER)
	# (d) Left lip bridge: closes the loop back to profile[0].
	profile.append(Vector2(cos(ang_start), sin(ang_start)) * R_OUTER)

	var n_prof := profile.size()

	# 4. Emit indexed vertices, ring-major.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var n_rings := samples.size()
	for ring in range(n_rings):
		var p := samples[ring]
		var rr := rights[ring]
		var uu := ups[ring]
		for j in range(n_prof):
			var pr := profile[j]
			var v := p + rr * pr.x + uu * pr.y
			var uv := Vector2(
				float(j) / float(n_prof - 1),
				float(ring) / float(n_rings - 1) * 12.0
			)
			st.set_uv(uv)
			st.add_vertex(v)

	# 5. Stitch ring-to-ring as a closed strip.
	#
	# For each ring pair (ring, ring+1) and each profile edge (j, j+1), emit
	# two triangles. Winding chosen so the surface normal points OUTWARD on
	# the outer half-circle (positive y at the bottom outside), INWARD on the
	# inner half-circle (toward the marbles rolling on it), and UPWARD on
	# the lip bridges. This is automatic: a consistent CCW winding around the
	# closed loop produces the correct outward-facing normals everywhere.
	for ring in range(n_rings - 1):
		for j in range(n_prof - 1):
			var i00: int = ring * n_prof + j
			var i01: int = ring * n_prof + j + 1
			var i10: int = (ring + 1) * n_prof + j
			var i11: int = (ring + 1) * n_prof + j + 1
			st.add_index(i00)
			st.add_index(i10)
			st.add_index(i11)
			st.add_index(i00)
			st.add_index(i11)
			st.add_index(i01)

	# 6. End caps: triangulate the half-annular cross-section at start and end.
	#
	# The cross-section between outer (verts 0..n_outer-1) and inner (reversed
	# in the loop) forms a half-annulus. Pair-up the outer point at index k
	# with the inner point at the equivalent angle (which lives at index
	# (n_outer + 1) + (n_inner - 1 - k) because the inner ring is reversed).
	# Emit two triangles per pair, winding opposite at the start and end caps
	# so both face outward from the slide body.
	_add_end_cap(st, 0, n_outer, false)                       # start cap (entrance)
	_add_end_cap(st, (n_rings - 1) * n_prof, n_outer, true)   # end cap (exit)

	st.generate_normals()
	st.generate_tangents()
	var mesh: ArrayMesh = st.commit()

	# 7. Material — glossy enamel-painted surface. Low roughness so the sky
	#    radiance reflects clearly on the curved surface — the swept tube
	#    catches highlights along its length, which is the main visual cue
	#    that the curvature is smooth. NO CULL_DISABLED: shell is closed.
	var mat := StandardMaterial3D.new()
	# Cool blue-white plastic so the slide reads against the warm sky behind
	# it. Plain white blended into the white sky in v3.
	mat.albedo_color = Color(0.70, 0.78, 0.92)
	mat.metallic = 0.10
	mat.roughness = 0.18
	mat.metallic_specular = 0.7

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "SlideMesh"
	mesh_inst.mesh = mesh
	mesh_inst.material_override = mat
	add_child(mesh_inst)

	# 8. Collision: trimesh from the same mesh (visible == physical surface).
	var body := StaticBody3D.new()
	body.name = "SlideBody"
	var coll := CollisionShape3D.new()
	coll.shape = mesh.create_trimesh_shape()
	body.add_child(coll)
	add_child(body)

	_spawn_anchor = samples[0] + Vector3(0.0, SPAWN_Y_LIFT, 0.0)
	_finish_pos = samples[samples.size() - 1] + Vector3(0.0, -1.5, 0.0)

# Triangulate the half-annular cross-section of one ring as an end cap.
#
# `base` is the index of profile[0] in that ring (= ring_index * n_prof).
# `n_outer` is the number of outer half-circle vertices (one more than
# SECTION_VERTS so the endpoints align with the lip bridges).
# `flip` reverses winding so the cap normal points outward from the slide
# (start cap normal points BACKWARD along path; end cap normal points
# FORWARD along path).
func _add_end_cap(st: SurfaceTool, base: int, n_outer: int, flip: bool) -> void:
	# Outer ring runs base+0 .. base+(n_outer-1).
	# Lip-bridge to inner is at base+n_outer (this is the (R_INNER, 0) point).
	# Inner ring (reversed in the loop) is base+(n_outer+1) .. base+(n_outer+1)+(n_outer-1).
	#
	# At angle index k, the outer point is at base+k and the inner point is
	# at base + (n_outer + 1) + (n_outer - 1 - k). Pair (k, k+1) with the
	# corresponding inner pair, emit two triangles.
	var inner_base: int = base + n_outer + 1
	var last: int = n_outer - 1
	for k in range(last):
		var o0: int = base + k
		var o1: int = base + k + 1
		var i0: int = inner_base + (last - k)
		var i1: int = inner_base + (last - (k + 1))
		# Quad: o0—o1—i1—i0 (going around the annular slice).
		if flip:
			st.add_index(o0); st.add_index(i1); st.add_index(o1)
			st.add_index(o0); st.add_index(i0); st.add_index(i1)
		else:
			st.add_index(o0); st.add_index(o1); st.add_index(i1)
			st.add_index(o0); st.add_index(i1); st.add_index(i0)

func _build_finish_slab() -> void:
	var body := StaticBody3D.new()
	body.name = "FinishFloor"
	var coll := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(12.0, 0.5, 8.0)
	coll.shape = box_shape
	body.add_child(coll)

	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(12.0, 0.5, 8.0)
	mesh_inst.mesh = box_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.32, 0.35, 0.42)
	mat.roughness = 0.65
	mesh_inst.material_override = mat
	body.add_child(mesh_inst)
	body.position = _finish_pos
	add_child(body)

# ─── Track interface ────────────────────────────────────────────────────────

func spawn_points() -> Array:
	var points: Array = []
	for row in range(4):
		for col in range(8):
			var x := -1.4 + float(col) * 0.4
			var z := -0.6 + float(row) * 0.4
			points.append(_spawn_anchor + Vector3(x, 0.0, z))
	return points

func finish_area_transform() -> Transform3D:
	return Transform3D(Basis(), _finish_pos + Vector3(0.0, 0.3, 0.0))

func finish_area_size() -> Vector3:
	return Vector3(12.0, 0.6, 8.0)

func camera_bounds() -> AABB:
	return AABB(Vector3(-10.0, -2.0, -5.0), Vector3(20.0, 28.0, 40.0))

func environment_overrides() -> Dictionary:
	# Premium daylight sky: deep zenith blue, warm horizon glow. Lower fog
	# density than v1 so the slide doesn't dissolve into haze in wide shots.
	# Higher ambient so the glass marbles pick up colour from the
	# environment rather than reading as flat-tinted plastic spheres.
	return {
		"sky_top":         Color(0.18, 0.36, 0.72),     # rich blue zenith
		"sky_horizon":     Color(0.95, 0.86, 0.74),     # warm horizon (sun haze)
		"ground_top":      Color(0.32, 0.34, 0.38),
		"fog_color":       Color(0.78, 0.82, 0.88),
		"fog_density":     0.0004,                       # was 0.0010
		"ambient_energy":  1.4,
		"exposure":        1.05,
		"sun_color":       Color(1.0, 0.96, 0.88),
		"sun_energy":      1.4,
		"cloud_coverage":  0.4,
		"cloud_scale":     0.8,
	}
