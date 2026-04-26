class_name EnvironmentBuilder
extends RefCounted

# Builds the shared production environment (WorldEnvironment + DirectionalLight)
# used by every entry-point scene. Centralizing this so the M7 visual pass can
# tune one place and have all six tracks (sim / playback / web / live / verify)
# pick up the same look.
#
# What's in the environment:
#   - ACES filmic tone mapping (instead of linear default → instant cinematic).
#   - Bloom (glow) so emissive marbles read as glowing orbs at distance.
#   - SSAO for contact shadows on chip stacks, pegs, dice.
#   - Procedural sky tinted toward warm casino interior; ambient inherits
#     from sky so unlit faces have plausible color.
#   - Mild fog for depth separation on long tracks.
#
# What's NOT here:
#   - Per-track mood lights — those stay in each track's _build_mood_light.
#   - HDRI / sky textures — using procedural for now (no asset shipping).

static func build_environment(overrides: Dictionary = {}) -> WorldEnvironment:
	var node := WorldEnvironment.new()
	node.name = "Environment"
	var env := Environment.new()

	# Sky
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	# Slightly warm, low-saturation sky — reads as "indoor casino" rather than
	# "outdoor blue sky".
	sky_mat.sky_top_color = Color(0.10, 0.08, 0.12)
	sky_mat.sky_horizon_color = Color(0.20, 0.15, 0.10)
	sky_mat.ground_bottom_color = Color(0.06, 0.05, 0.05)
	sky_mat.ground_horizon_color = Color(0.18, 0.13, 0.08)
	sky_mat.sun_angle_max = 30.0
	sky_mat.sun_curve = 0.10
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky

	# Ambient light from the sky, modest energy so direct lights still pop.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.45

	# Tone mapping — filmic ACES is the current Godot best-practice for
	# physically-based scenes. Default linear blows out emissive highlights.
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0

	# Bloom: pick up emissive surfaces and bright highlights.
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_strength = 1.0
	env.glow_bloom = 0.10
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_hdr_threshold = 1.0
	env.glow_hdr_scale = 2.0

	# SSAO — contact shadows under chips/pegs/dice. Subtle, not crushing.
	env.ssao_enabled = true
	env.ssao_radius = 0.8
	env.ssao_intensity = 1.4
	env.ssao_power = 1.5
	env.ssao_detail = 0.5

	# Light fog for depth/atmosphere — keeps long tracks from looking flat.
	env.fog_enabled = true
	env.fog_light_color = Color(0.10, 0.08, 0.10)
	env.fog_light_energy = 0.6
	env.fog_density = 0.005   # very mild

	# Adjustments — slight color grading toward warmer.
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = 1.05
	env.adjustment_saturation = 1.10

	# Apply per-track overrides on top of the defaults. Mutating the existing
	# Sky / Environment is fine because each track gets its own copy.
	if overrides.has("sky_top"):
		sky_mat.sky_top_color = overrides["sky_top"]
	if overrides.has("sky_horizon"):
		sky_mat.sky_horizon_color = overrides["sky_horizon"]
	if overrides.has("ground_top"):
		sky_mat.ground_horizon_color = overrides["ground_top"]
	if overrides.has("ground_bottom"):
		sky_mat.ground_bottom_color = overrides["ground_bottom"]
	if overrides.has("ambient_energy"):
		env.ambient_light_energy = overrides["ambient_energy"]
	if overrides.has("fog_color"):
		env.fog_light_color = overrides["fog_color"]
	if overrides.has("fog_energy"):
		env.fog_light_energy = overrides["fog_energy"]
	if overrides.has("fog_density"):
		env.fog_density = overrides["fog_density"]
	if overrides.has("exposure"):
		env.tonemap_exposure = overrides["exposure"]

	node.environment = env
	return node

# The sun: directional light at a slight side-angle so casinos read 3D rather
# than top-lit-flat. Soft shadows on by default. Returns the configured node;
# caller add_child's it. Optional overrides apply on top of the defaults.
static func build_sun(overrides: Dictionary = {}) -> DirectionalLight3D:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-55.0, -38.0, 0.0)
	sun.light_color = Color(1.0, 0.95, 0.85)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	sun.shadow_blur = 1.5
	# PSSM splits — closer cascades sharper, far cascades blurrier. 4-split
	# gives reasonable shadow quality for the depth range our tracks span.
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 100.0
	if overrides.has("sun_color"):
		sun.light_color = overrides["sun_color"]
	if overrides.has("sun_energy"):
		sun.light_energy = overrides["sun_energy"]
	return sun
