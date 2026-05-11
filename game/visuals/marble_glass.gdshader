// Marble glass shader — real-glass-marble look with per-marble variants.
//
// Reads as: a glass sphere (METALLIC=0, ROUGHNESS≈0.05, SPECULAR≈0.5) with a
// distinct INTERNAL pattern visible through the clear outer shell. Strong
// fresnel rim so each marble picks up the environment radiance at glancing
// angles. Subtle emission so bloom traces fast marbles without overpowering
// the glassy specular highlight.
//
// Per-marble inputs (set in marble_spawner.gd):
//   marble_color     : primary colour from the fairness chain
//   secondary_color  : second colour for two-tone variants (swirl, banded,
//                      onionskin); falls back to a hash of marble_color if
//                      left at default
//   marble_type      : 0=cat's-eye, 1=swirl, 2=banded, 3=clearie. Picked
//                      deterministically per marble in marble_spawner.gd via
//                      (drop_order modulo 4) so every round has a mix.
//   swirl_seed       : float in [0,1] — pattern offset so two same-type
//                      marbles still look distinct.

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4  marble_color     : source_color = vec4(0.80, 0.60, 0.20, 1.0);
uniform vec4  secondary_color  : source_color = vec4(1.00, 1.00, 1.00, 1.0);
uniform int   marble_type      : hint_range(0, 3) = 1;
uniform float swirl_seed       : hint_range(0.0, 1.0) = 0.0;
uniform float swirl_scale      : hint_range(1.0, 20.0) = 6.0;
uniform float rim_strength     : hint_range(0.0, 4.0) = 0.35;
uniform float rim_power        : hint_range(0.5, 8.0) = 5.0;
uniform float emission_strength: hint_range(0.0, 4.0) = 0.0;
uniform float roughness_param  : hint_range(0.0, 0.6) = 0.25;
uniform float specular_param   : hint_range(0.0, 1.0) = 0.55;

// ─── Noise helpers ──────────────────────────────────────────────────────────

vec3 hash33(vec3 p) {
	p = vec3(
		dot(p, vec3(127.1, 311.7,  74.7)),
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

// Cheap 3D value noise.
float vn3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash33(i).x;
	float n100 = hash33(i + vec3(1, 0, 0)).x;
	float n010 = hash33(i + vec3(0, 1, 0)).x;
	float n110 = hash33(i + vec3(1, 1, 0)).x;
	float n001 = hash33(i + vec3(0, 0, 1)).x;
	float n101 = hash33(i + vec3(1, 0, 1)).x;
	float n011 = hash33(i + vec3(0, 1, 1)).x;
	float n111 = hash33(i + vec3(1, 1, 1)).x;
	return mix(
		mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
		f.z
	);
}

// ─── Per-type interior pattern. Returns (interior_color, opacity_of_pattern). ──

// Cat's-eye: clear glass with a flat coloured "vane" through the middle. The
// vane is oriented along the local Y axis; falloff away from the vane plane
// fades into the clear shell so the rim is glass-white.
vec4 catseye(vec3 local_pos, vec3 base, vec3 second) {
	// Distance from the y=0 plane in local space (vane orientation). The
	// orientation jitter per marble keeps every cat's-eye looking different.
	float ang = swirl_seed * 6.2831853;
	mat2 rot = mat2(vec2(cos(ang), -sin(ang)), vec2(sin(ang), cos(ang)));
	vec2 xy = rot * local_pos.xz;
	float d = abs(xy.y);                 // distance from vane plane in rotated frame
	// Wider smoothstep (was 0.05..0.18) so the vane boundary is a soft
	// gradient, not a sharp edge — sharp edges on a rotating sphere
	// alias temporally.
	float vane = 1.0 - smoothstep(0.05, 0.30, d);
	float center_brighten = 1.0 - smoothstep(0.0, 0.25, length(local_pos));
	vec3 col = mix(base * 0.9, second * 1.2, vane);
	col += second * center_brighten * 0.4;
	float opacity = mix(0.45, 0.95, vane);
	return vec4(col, opacity);
}

// Swirl: low-frequency two-tone blend along a marble-local axis. The
// previous version sampled Voronoi noise in local space — which produced
// temporal aliasing as the marble rotated (every frame, each screen pixel
// sampled a different Voronoi cell → visible flicker on motion). Replaced
// with a smooth two-axis dot-product gradient: low frequency, no
// discontinuities, no aliasing on rotation.
vec4 swirl(vec3 local_pos, vec3 base, vec3 second) {
	float ang_a = swirl_seed * 6.2831853;
	float ang_b = ang_a + 1.7;
	vec3 axis_a = normalize(vec3(cos(ang_a), 0.4, sin(ang_a)));
	vec3 axis_b = normalize(vec3(cos(ang_b), -0.3, sin(ang_b)));
	float t1 = dot(normalize(local_pos + vec3(0.001)), axis_a) * 0.5 + 0.5;
	float t2 = dot(normalize(local_pos + vec3(0.001)), axis_b) * 0.5 + 0.5;
	float t = mix(t1, t2, 0.5);
	vec3 col = mix(base, second, smoothstep(0.25, 0.75, t));
	return vec4(col, 1.0);
}

// Banded: 3-4 horizontal stripes around the local Y axis. Crisp bands like a
// peewee marble. Orientation jittered by swirl_seed so no two share the same
// banding axis.
vec4 banded(vec3 local_pos, vec3 base, vec3 second) {
	float ang = swirl_seed * 6.2831853;
	mat2 rot = mat2(vec2(cos(ang), -sin(ang)), vec2(sin(ang), cos(ang)));
	vec2 xz = rot * local_pos.xz;
	// Pretend a "latitude" off the rotated horizontal plane.
	float latitude = atan(local_pos.y, length(xz));      // [-pi/2, pi/2]
	// Fewer bands (was 6.0) + wider transition (was -0.15..0.15) so the
	// stripe boundaries are gentle gradients, not crisp edges. Sharp
	// stripes on a rotating sphere alias temporally → looks like flicker.
	float n_bands = 4.0;
	float stripe = sin(latitude * n_bands);
	float t = smoothstep(-0.55, 0.55, stripe);
	vec3 col = mix(base, second, t);
	return vec4(col, 1.0);
}

// Clearie: solid translucent colour with a subtle interior brightening
// toward the centre (catches the light through the glass).
vec4 clearie(vec3 local_pos, vec3 base, vec3 second) {
	float r = length(local_pos);
	float core = 1.0 - smoothstep(0.0, 0.30, r);
	vec3 col = mix(base * 0.85, base * 1.4, core);
	col += second * core * 0.15;
	return vec4(col, mix(0.65, 0.95, core));
}

// ─── Fragment ───────────────────────────────────────────────────────────────

void fragment() {
	// Local-space position (sphere frame) drives every interior pattern, so
	// rotations don't make the pattern swim.
	vec3 local_pos = (inverse(MODEL_MATRIX) * vec4(VERTEX, 1.0)).xyz;

	vec3 base = marble_color.rgb;
	vec3 second = secondary_color.rgb;

	vec4 interior;
	if (marble_type == 0) {
		interior = catseye(local_pos, base, second);
	} else if (marble_type == 2) {
		interior = banded(local_pos, base, second);
	} else if (marble_type == 3) {
		interior = clearie(local_pos, base, second);
	} else {
		interior = swirl(local_pos, base, second);
	}

	// Fresnel rim: glass picks up the environment at glancing angles. NdV
	// is the Lambertian term; (1-NdV)^p is the fresnel approximation. We
	// don't actually sample a cubemap here — Godot's BG_SKY radiance feeds
	// the GGX specular automatically because METALLIC=0 + SPECULAR>0.
	float NdV = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float rim = pow(1.0 - NdV, rim_power);
	vec3 rim_tint = mix(base, vec3(1.0), 0.5) * rim_strength;

	// Lift toward white-ish at the rim — the "halo" you see on real glass
	// marbles where the edge bends the light.
	vec3 albedo = mix(interior.rgb, rim_tint, rim);

	ALBEDO   = albedo;
	METALLIC = 0.0;          // glass is dielectric
	ROUGHNESS = roughness_param;
	SPECULAR  = specular_param;

	// Emission: zero. Any non-zero rim emission was crossing the bloom
	// HDR threshold (1.0) as marbles rotated under the sun, producing
	// pulsing bloom that read as flicker. Bloom on marbles now comes
	// purely from specular highlight intensity, which the rougher shader
	// keeps below threshold.
	EMISSION = vec3(0.0);
}
