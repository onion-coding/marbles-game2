class_name WinnerReveal
extends RefCounted

# One-shot celebration FX fired at the moment a marble crosses the finish.
# A burst of confetti particles spawns at the given world position; the
# burst self-frees after its lifetime so callers don't need to track it.
#
# Used by both the sim path (main.gd connecting to FinishLine.race_finished)
# and the playback/live path (PlaybackPlayer detecting the first
# EVENT_FINISH_CROSS frame).

const BURST_COUNT := 80
const BURST_LIFETIME := 1.6
const BURST_INITIAL_SPEED := 7.0
const BURST_SPREAD_DEG := 65.0
const BURST_SCALE_MIN := 0.6
const BURST_SCALE_MAX := 1.4

# Spawn a confetti burst at world_pos using `accent_color` as the dominant
# tint. Returns the GPUParticles3D node so the caller can configure further
# if needed; node is added to `parent` and self-frees after BURST_LIFETIME.
static func spawn_confetti(parent: Node, world_pos: Vector3, accent_color: Color) -> GPUParticles3D:
	var burst := GPUParticles3D.new()
	burst.name = "WinnerBurst"
	burst.amount = BURST_COUNT
	burst.lifetime = BURST_LIFETIME
	burst.one_shot = true
	burst.explosiveness = 1.0      # all particles spawn at once
	burst.local_coords = false
	burst.emitting = true
	burst.global_position = world_pos

	var pmat := ParticleProcessMaterial.new()
	pmat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pmat.emission_sphere_radius = 0.4
	pmat.direction = Vector3(0, 1, 0)
	pmat.spread = BURST_SPREAD_DEG
	pmat.initial_velocity_min = BURST_INITIAL_SPEED * 0.6
	pmat.initial_velocity_max = BURST_INITIAL_SPEED
	pmat.gravity = Vector3(0, -9.8, 0)
	pmat.angular_velocity_min = -360.0
	pmat.angular_velocity_max = 360.0
	pmat.damping_min = 0.6
	pmat.damping_max = 1.2
	pmat.scale_min = BURST_SCALE_MIN
	pmat.scale_max = BURST_SCALE_MAX

	# Confetti is a mix of accent_color, gold, and white — pull all three
	# from the gradient so the burst reads as celebratory rather than monochrome.
	var grad := Gradient.new()
	grad.add_point(0.0, Color(accent_color.r, accent_color.g, accent_color.b, 1.0))
	grad.add_point(0.5, Color(0.95, 0.78, 0.20, 1.0))
	grad.add_point(1.0, Color(1.0, 1.0, 1.0, 0.0))
	var gtex := GradientTexture1D.new()
	gtex.gradient = grad
	pmat.color_ramp = gtex
	burst.process_material = pmat

	# Mesh: small flat quad with emissive double-sided material — reads as
	# confetti pieces tumbling.
	var quad := QuadMesh.new()
	quad.size = Vector2(0.18, 0.10)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = accent_color
	mat.emission_enabled = true
	mat.emission = accent_color
	mat.emission_energy_multiplier = 1.4
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	quad.material = mat
	burst.draw_pass_1 = quad

	parent.add_child(burst)

	# Auto-free after the lifetime + a small grace period.
	var timer := Timer.new()
	timer.wait_time = BURST_LIFETIME + 0.5
	timer.one_shot = true
	timer.autostart = true
	timer.timeout.connect(burst.queue_free)
	burst.add_child(timer)
	return burst

# Brief emission pulse on the winner marble — bumps its glow for a few
# seconds so viewers can read which marble actually crossed first. The
# `marble_node` should be a Node3D whose first MeshInstance3D child carries
# a StandardMaterial3D as material_override (true for both sim marbles and
# playback marbles).
static func boost_winner_emission(marble_node: Node3D, scene_tree: SceneTree) -> void:
	var mesh: MeshInstance3D = null
	for c in marble_node.get_children():
		if c is MeshInstance3D:
			mesh = c
			break
	# Sim marbles have the mesh as a child; playback marbles ARE the mesh.
	if mesh == null and marble_node is MeshInstance3D:
		mesh = marble_node
	if mesh == null:
		return
	var mat: StandardMaterial3D = mesh.material_override as StandardMaterial3D
	if mat == null:
		return
	# Animate emission energy from 0.45 → 3.5 → 1.0 over ~2s.
	var tween := scene_tree.create_tween()
	tween.tween_property(mat, "emission_energy_multiplier", 3.5, 0.25)
	tween.tween_property(mat, "emission_energy_multiplier", 1.2, 1.6)
