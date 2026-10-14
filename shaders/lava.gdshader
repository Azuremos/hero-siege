shader_type spatial;
render_mode cull_disabled;
// Лава в логове демонов: медленно текущие светящиеся жилы на тёмной корке. Без текстур — шум из синусов.

uniform vec4 hot : source_color = vec4(1.0, 0.45, 0.08, 1.0);
uniform vec4 crust : source_color = vec4(0.12, 0.04, 0.03, 1.0);
uniform float speed = 0.12;

float wave(vec2 p) {
	return sin(p.x * 1.7 + sin(p.y * 1.3 + TIME * speed * 6.0)) * 0.5 + sin(p.y * 2.1 + sin(p.x * 0.9 - TIME * speed * 4.0)) * 0.5;
}

void fragment() {
	vec2 p = UV * 9.0 + vec2(TIME * speed, TIME * speed * 0.6);
	float v = wave(p) + 0.5 * wave(p * 2.3 + 4.0);
	float veins = smoothstep(0.35, 0.95, abs(v));
	// у краёв ямы корка толще
	float edge = smoothstep(0.5, 0.42, length(UV - vec2(0.5)));
	float glow = (1.0 - veins) * edge;
	ALBEDO = mix(crust.rgb, hot.rgb, glow);
	EMISSION = hot.rgb * glow * (1.4 + 0.4 * sin(TIME * 2.0));
	ROUGHNESS = 0.9;
	ALPHA = edge;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
