shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
// Телеграф опасной способности на земле: контур фигуры и заливка, которая растёт от центра
// к моменту удара (progress 0 → 1). Круг (shape 0) или конус (shape 1, half_angle — половина угла, радианы;
// конус смотрит вдоль −Z плоскости). Переиспользуется способностями мобов и боссов.

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform float shape = 0.0;
uniform float half_angle = 0.8;
uniform vec4 color : source_color = vec4(1.0, 0.25, 0.1, 1.0);

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;          // −1..1, центр — сам моб (для конуса) или точка удара
	float r = length(p);
	float inside = step(r, 1.0);
	if (shape > 0.5) {
		float ang = atan(p.x, -p.y);
		inside *= step(abs(ang), half_angle);
	}
	float edge = smoothstep(0.9, 1.0, r) * inside;
	float fill = step(r, progress) * inside;
	float a = inside * 0.18 + fill * 0.32 + edge * 0.6;
	ALBEDO = color.rgb;
	ALPHA = a * color.a;
}
