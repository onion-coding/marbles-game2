// Marble glass shader — glass orb with an internal coloured swirl pattern.
//
// Reads as: a translucent sphere with a coloured "core" inside (Voronoi noise
// driven), a fresnel rim that picks up environment, and a strong emission
// tint that bloom turns into a halo. Replaces the flat StandardMaterial3D
// used in marble_spawner.gd so each marble looks like a real glass marble
// instead of a plastic sphere.
//
// Inputs (set per-marble in marble_spawner.gd):
//   marble_color   : the marble's deterministic colour (from fairness chain)
//   swirl_seed     : float in [0,1] — drives the Voronoi noise offset so two
//                    marbles with similar colours still look distinct
//
// All other params have sensible defaults that read well from camera.

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 marble_color : source_color = vec4(0.8, 0.6, 0.2, 1.0);
uniform float swirl_seed : hint_range(0.0, 1.0) = 0.0;
uniform float swirl_scale : hint_range(1.0, 20.0) = 6.0;
uniform float swirl_intensity : hint_range(0.0, 1.0) = 0.6;
uniform float rim_strength : hint_range(0.0, 4.0) = 1.5;
uniform float rim_power : hint_range(0.5, 8.0) = 2.5;
uniform float emission_strength : hint_range(0.0, 4.0) = 0.8;
uniform float core_lightness : hint_range(0.0, 2.0) = 1.4;

// Cheap Voronoi-ish noise — 3D hash + cell distance. Good enough for an
// internal swirl pattern read from a moving sphere; not perfect Voronoi.
vec3 hash33(vec3 p) {
	p = vec3(
		dot(p, vec3(127.1, 311.7, 74.7)),
		dot(p, vec3(269.5, 183.3, 246.1)),
		dot(p, vec3(113.5, 271.9, 124.6))
	);
	return fract(sin(p) * 43758.5453);
}

float voronoi3(vec3 x) {
	vec3 p = floor(x);
	vec3 f = fract(x);
	float min_d = 1.0;
	for (int k = -1; k <= 1; k++) {
		for (int j = -1; j <= 1; j++) {
			for (int i = -1; i <= 1; i++) {
				vec3 b = vec3(float(i), float(j), float(k));
				vec3 r = b + hash33(p + b) - f;
				float d = dot(r, r);
				min_d = min(min_d, d);
			}
		}
	}
	return sqrt(min_d);
}

void fragment() {
	// Local-space position (in object frame) drives the swirl pattern. Since
	// it's local-space, the swirl is anchored to the sphere — it doesn't
	// "swim" relative to the marble's surface as the marble rotates.
	vec3 local_pos = (inverse(MODEL_MATRIX) * vec4(VERTEX, 1.0)).xyz;
	vec3 swirl_uv = local_pos * swirl_scale + vec3(swirl_seed * 31.4, swirl_seed * 17.7, swirl_seed * 5.2);

	float v = voronoi3(swirl_uv);
	// Mix two scales for richer pattern.
	float v2 = voronoi3(swirl_uv * 2.3 + 7.7);
	float core = mix(v, v2, 0.4);

	// Lift the core toward white where the noise is high — this creates the
	// "swirl bloom" of a glass marble.
	vec3 base = marble_color.rgb;
	vec3 light = clamp(base * core_lightness, 0.0, 1.0);
	vec3 albedo = mix(base, light, smoothstep(0.2, 0.85, core) * swirl_intensity);

	// Fresnel rim — surface-facing pixels get base, edge-facing get rim glow.
	float NdV = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float rim = pow(1.0 - NdV, rim_power);
	vec3 rim_col = base * rim_strength;

	ALBEDO  = albedo;
	METALLIC = 0.20;
	ROUGHNESS = 0.18;
	SPECULAR = 0.6;

	// Emission carries the colour signature so bloom paints a halo around
	// fast-moving marbles even at distance. Strongest at the rim.
	EMISSION = base * emission_strength + rim_col * 0.5;
}
