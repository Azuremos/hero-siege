shader_type spatial;
render_mode diffuse_lambert, specular_disabled;
// Трава в палитре KayKit с мягкими пятнами (без текстур — дёшево для GPU и CPU).

uniform vec3 grass_light : source_color = vec3(0.56, 0.74, 0.33);
uniform vec3 grass_dark : source_color = vec3(0.36, 0.56, 0.22);
uniform vec3 grass_dry : source_color = vec3(0.62, 0.66, 0.34);

varying vec3 wpos;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			   mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float n = vnoise(wpos.xz * 0.04) * 0.55 + vnoise(wpos.xz * 0.17) * 0.3 + vnoise(wpos.xz * 1.1) * 0.15;
	vec3 c = mix(grass_dark, grass_light, smoothstep(0.25, 0.75, n));
	float dry = smoothstep(0.62, 0.8, vnoise(wpos.xz * 0.023 + 17.0));
	c = mix(c, grass_dry, dry * 0.5);
	ALBEDO = c;
	ROUGHNESS = 1.0;
}
