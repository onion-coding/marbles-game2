class_name MarbleSpawner
extends RefCounted

const RADIUS := 0.3

# Deterministic-by-slot spawn. `slots[i]` is the spawn slot for marble i.
# `colors[i]` (optional, same length as slots) overrides the default HSV-by-index color.
# `rail` resolves slot indices to world positions — different tracks have different rails.
static func spawn(parent: Node, rail: SpawnRail, slots: Array, colors: Array = []) -> Array[RigidBody3D]:
	var marbles: Array[RigidBody3D] = []
	for i in range(slots.size()):
		var color: Color = colors[i] if i < colors.size() else Color.from_hsv(float(i) / max(slots.size(), 1), 0.8, 0.95)
		var marble := _make_marble(rail, i, int(slots[i]), color)
		attach_number_label(marble, i)
		parent.add_child(marble)
		marbles.append(marble)
	return marbles

static func _make_marble(rail: SpawnRail, drop_order: int, slot: int, color: Color) -> RigidBody3D:
	var marble := RigidBody3D.new()
	marble.name = "Marble_%02d" % drop_order
	# 1 kg per marble. With Godot's default 9.8 m/s² gravity that's the
	# weight used in collision-response math against kinematic obstacles
	# (paddles, dice, reels). Heavier marbles punch through lighter
	# friction effects faster — useful for the high-energy "fast drop"
	# feel on Plinko.
	marble.mass = 1.0
	marble.continuous_cd = true

	var mesh_inst := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = RADIUS
	sphere.height = RADIUS * 2.0
	mesh_inst.mesh = sphere
	# PBR-tuned marble: slight metallic + low roughness for a glass-bead shine,
	# plus a low-energy emission of the marble's color so bloom turns each
	# marble into a faintly-glowing orb that reads from a distance.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.30
	mat.metallic_specular = 0.6
	mat.roughness = 0.18
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.45
	mesh_inst.material_override = mat
	marble.add_child(mesh_inst)

	var shape := CollisionShape3D.new()
	var sphere_shape := SphereShape3D.new()
	sphere_shape.radius = RADIUS
	shape.shape = sphere_shape
	marble.add_child(shape)

	marble.physics_material_override = PhysicsMaterials.marble()
	marble.position = rail.slot_position(slot, drop_order)
	marble.add_to_group("marbles")
	attach_trail(marble, color)
	return marble

# Floating name label that always faces the camera. Kept public for
# opt-in callers (e.g. a future "leader badge" that shows only above
# the currently-leading marble) — NOT attached by default because 20
# overlapping name labels at the spawn cluster turn into an unreadable
# mess.
#
# Sized in world units (fixed_size=false) so it scales naturally with
# distance: from 5 m a Slots cabinet, the label is readable; from 35 m
# a Plinko field, it's small enough not to dominate the frame.
static func attach_name_label(marble: Node3D, text: String) -> void:
	var label := Label3D.new()
	label.name = "NameLabel"
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true                              # always-on-top
	label.pixel_size = 0.003
	label.font_size = 16
	label.outline_size = 4
	label.outline_modulate = Color(0, 0, 0, 0.85)
	label.modulate = Color(1, 1, 1, 0.92)
	label.position = Vector3(0, RADIUS + 0.5, 0)
	marble.add_child(label)

# Compact drop-order number (0-19) rendered above the marble, more discreet
# than the full name label. pixel_size 0.002 + font_size 14 keeps it readable
# from a few metres without cluttering a wide-angle view. Always-on-top so it
# shows through the marble mesh itself. Called from spawn() for every marble.
static func attach_number_label(marble: Node3D, drop_order: int) -> void:
	var label := Label3D.new()
	label.name = "NumberLabel"
	label.text = str(drop_order)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.pixel_size = 0.002
	label.font_size = 14
	label.outline_size = 4
	label.outline_modulate = Color(0, 0, 0, 1.0)
	label.modulate = Color(1, 1, 1, 1.0)
	label.position = Vector3(0, RADIUS + 0.35, 0)
	marble.add_child(label)

# Color-tinted streak that follows a marble. Pure visual; no effect on
# physics or replay. Implemented as a GPUParticles3D child whose emitter
# inherits the marble's motion, producing a fading trail of small spheres
# the same color as the marble. Public so PlaybackPlayer can attach the
# same trail to its visual-only marble nodes.
static func attach_trail(marble: Node3D, color: Color) -> void:
	var trail := GPUParticles3D.new()
	trail.name = "Trail"
	trail.amount = 32
	trail.lifetime = 0.55
	trail.preprocess = 0.0
	trail.emitting = true
	trail.local_coords = false   # particles emit in world space, freezing them
	                              # in place as the marble moves on — that's the
	                              # "trail" effect we want.

	var pmat := ParticleProcessMaterial.new()
	pmat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pmat.emission_sphere_radius = RADIUS * 0.3
	pmat.direction = Vector3(0, 0, 0)
	pmat.spread = 0.0
	pmat.initial_velocity_min = 0.0
	pmat.initial_velocity_max = 0.0
	pmat.gravity = Vector3.ZERO
	pmat.scale_min = 0.6
	pmat.scale_max = 0.9
	# Curve: shrink to 0 by end of lifetime so the trail tapers cleanly.
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(1.0, 0.0))
	var ctex := CurveTexture.new()
	ctex.curve = curve
	pmat.scale_curve = ctex
	pmat.color = color
	# Alpha-fade across lifetime via a gradient.
	var grad := Gradient.new()
	grad.add_point(0.0, Color(color.r, color.g, color.b, 0.85))
	grad.add_point(1.0, Color(color.r, color.g, color.b, 0.0))
	var gtex := GradientTexture1D.new()
	gtex.gradient = grad
	pmat.color_ramp = gtex
	trail.process_material = pmat

	# Trail mesh: small sphere with emissive of the marble color so bloom
	# turns the whole trail into a light streak.
	var trail_mesh := SphereMesh.new()
	trail_mesh.radius = RADIUS * 0.55
	trail_mesh.height = RADIUS * 1.10
	trail_mesh.radial_segments = 8
	trail_mesh.rings = 4
	var trail_mat := StandardMaterial3D.new()
	trail_mat.albedo_color = color
	trail_mat.emission_enabled = true
	trail_mat.emission = color
	trail_mat.emission_energy_multiplier = 0.8
	trail_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	trail_mesh.material = trail_mat
	trail.draw_pass_1 = trail_mesh

	marble.add_child(trail)
