shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
// Телеграф опасной способности на земле: контур фигуры и заливка, которая растёт к моменту удара
// (progress 0 → 1). Фигуры: 0 — круг, 1 — конус (half_angle — половина угла, радианы, смотрит вдоль −Z),
// 2 — полоса (прямоугольник во всю плоскость, заливка от начала к концу), 3 — кольцо (inner — доля
// внутреннего радиуса; outer — доля внешнего, для расходящейся волны). Способности мобов и боссов.

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform float shape = 0.0;
uniform float half_angle = 0.8;
uniform float inner = 0.0;
uniform float outer = 1.0;
uniform vec4 color : source_color = vec4(1.0, 0.25, 0.1, 1.0);

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float r = length(p);
	float a = 0.0;
	if (shape > 2.5) {
		float inside = step(r, outer) * step(inner, r);
		float edge = (smoothstep(outer - 0.04, outer, r) + 1.0 - smoothstep(inner, inner + 0.04, r)) * inside;
		float fill = step(r, inner + (outer - inner) * progress) * inside;
		a = inside * 0.18 + fill * 0.32 + edge * 0.6;
	} else if (shape > 1.5) {
		float edge = max(smoothstep(0.85, 1.0, abs(p.x)), smoothstep(0.96, 1.0, abs(p.y)));
		float fill = step(1.0 - progress * 2.0, p.y);
		a = 0.18 + fill * 0.32 + edge * 0.6;
	} else {
		float inside = step(r, 1.0);
		if (shape > 0.5) {
			float ang = atan(p.x, -p.y);
			inside *= step(abs(ang), half_angle);
		}
		float edge = smoothstep(0.9, 1.0, r) * inside;
		float fill = step(r, progress) * inside;
		a = inside * 0.18 + fill * 0.32 + edge * 0.6;
	}
	ALBEDO = color.rgb;
	ALPHA = a * color.a;
}
