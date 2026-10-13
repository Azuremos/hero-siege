shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled;
// Светящаяся оболочка: щиты, купол Барьера Света, столбы света.

uniform vec4 color : source_color = vec4(1.0, 0.9, 0.5, 1.0);
uniform float energy = 1.0;
uniform float power = 2.2;
uniform float base_alpha = 0.06;
uniform float fade = 1.0;
uniform float scroll = 0.0;

void fragment() {
	float f = pow(1.0 - clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), power);
	float bands = 1.0;
	if (scroll > 0.0) {
		bands = 0.75 + 0.25 * sin(UV.y * 40.0 - TIME * scroll);
	}
	ALBEDO = color.rgb * energy;
	ALPHA = clamp((f * 0.9 + base_alpha) * bands * color.a * fade, 0.0, 1.0);
}
