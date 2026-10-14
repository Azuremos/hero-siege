shader_type canvas_item;
// «Часы» перезарядки на ячейке панели, как в WoW: затемнён сектор, который ещё не прошёл,
// стрелка идёт по часовой от 12 часов. progress — доля оставшегося времени (1 → 0).
// Для ГКД — светлее (shade.a меньше) и с яркой кромкой стрелки (edge.a > 0).

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform vec4 shade : source_color = vec4(0.0, 0.0, 0.0, 0.65);
uniform vec4 edge : source_color = vec4(1.0, 0.92, 0.55, 0.0);

void fragment() {
	vec2 p = UV - vec2(0.5);
	float ang = atan(p.x, -p.y);                       // 0 — вверх, по часовой — плюс
	float a = (ang < 0.0 ? ang + 6.2831853 : ang) / 6.2831853;
	float hand = 1.0 - progress;
	float covered = step(hand, a) * step(0.001, progress);
	vec4 col = shade * covered;
	// кромка стрелки: тонкая линия от центра к краю
	float px = abs(a - hand) * 6.2831853 * length(p);
	float line = (1.0 - smoothstep(0.008, 0.03, px)) * step(0.001, progress) * step(progress, 0.999);
	col = mix(col, edge, line * edge.a);
	COLOR = col;
}
