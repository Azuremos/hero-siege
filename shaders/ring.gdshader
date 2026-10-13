shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;
// Круг на земле: прицел, области заклинаний, освящённая земля (с рунами).

uniform vec4 color : source_color = vec4(1.0);
uniform float energy = 1.0;
uniform float fill = 0.15;
uniform float ring = 0.06;
uniform float runes = 0.0;
uniform float fade = 1.0;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	if (r > 1.0) {
		discard;
	}
	float edge = smoothstep(1.0 - ring, 1.0 - ring * 0.35, r) * (1.0 - smoothstep(0.975, 1.0, r));
	float a = fill * (0.35 + 0.65 * r * r) + edge;
	if (runes > 0.5) {
		float ang = atan(p.y, p.x);
		float band = smoothstep(0.76, 0.78, r) * (1.0 - smoothstep(0.86, 0.88, r));
		float marks = step(0.55, fract((ang + TIME * 0.5) * 8.0 / 6.28318));
		a += band * marks * 0.7;
		float inner = smoothstep(0.5, 0.515, r) * (1.0 - smoothstep(0.53, 0.545, r));
		a += inner * 0.6;
		float star = smoothstep(0.03, 0.0, abs(sin((ang - TIME * 0.3) * 3.0)) * r) * step(r, 0.5);
		a += star * 0.5;
		a *= 0.85 + 0.15 * sin(TIME * 3.0);
	}
	ALBEDO = color.rgb * energy;
	ALPHA = clamp(a * color.a * fade, 0.0, 1.0);
}
