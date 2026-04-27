shader_type sky;

uniform vec3 zenith_color : source_color = vec3(0.20, 0.45, 0.85);
uniform vec3 horizon_color : source_color = vec3(0.78, 0.88, 0.96);
uniform vec3 ground_color : source_color = vec3(0.45, 0.48, 0.46);
uniform vec3 cloud_color : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 cloud_shadow_color : source_color = vec3(0.55, 0.62, 0.72);
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.55;
uniform float cloud_softness : hint_range(0.001, 0.5) = 0.10;
uniform float cloud_scale : hint_range(0.05, 8.0) = 0.6;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * vnoise(p);
		p *= 2.07;
		a *= 0.5;
	}
	return v;
}

void sky() {
	vec3 d = EYEDIR;
	float t = clamp(d.y, -1.0, 1.0);
	vec3 col;
	if (t >= 0.0) {
		col = mix(horizon_color, zenith_color, smoothstep(0.0, 0.7, t));
	} else {
		col = mix(horizon_color, ground_color, smoothstep(0.0, 0.4, -t));
	}
	if (d.y > 0.02) {
		vec2 uv = d.xz / max(d.y, 0.02) * cloud_scale;
		float n = fbm(uv);
		float lo = 1.0 - cloud_coverage - cloud_softness;
		float hi = 1.0 - cloud_coverage + cloud_softness;
		float cloud = smoothstep(lo, hi, n);
		float n2 = fbm(uv * 1.7 + vec2(11.0, 7.0));
		float shade = smoothstep(0.45, 0.85, n2);
		float fade = smoothstep(0.02, 0.20, d.y);
		float a_cloud = cloud * fade;
		vec3 c_col = mix(cloud_color, cloud_shadow_color, shade * 0.55);
		col = mix(col, c_col, a_cloud);
	}
	COLOR = col;
}
