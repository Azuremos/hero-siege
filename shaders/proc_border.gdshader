shader_type canvas_item;
// Бегущая рамка прока по периметру ячейки, как автокаст в Warcraft 3:
// светящиеся точки бегут по кругу, рамка слегка светится. Один ColorRect на ячейку, без нод на точки.

uniform vec4 color : source_color = vec4(1.0, 0.82, 0.3, 1.0);
uniform float band = 0.13;     // ширина рамки в долях ячейки
uniform float dots = 6.0;      // сколько точек по периметру
uniform float speed = 0.7;     // оборотов в секунду (в долях периметра × dots)

void fragment() {
	vec2 uv = UV;
	float dl = uv.x;
	float dr = 1.0 - uv.x;
	float dt = uv.y;
	float db = 1.0 - uv.y;
	float d = min(min(dl, dr), min(dt, db));
	// координата вдоль периметра по часовой, 0..1
	float s = 0.75 + (1.0 - uv.y) * 0.25;
	if (d == dt) {
		s = uv.x * 0.25;
	} else if (d == dr) {
		s = 0.25 + uv.y * 0.25;
	} else if (d == db) {
		s = 0.5 + (1.0 - uv.x) * 0.25;
	}
	float ph = fract(s * dots - TIME * speed);
	float dot_v = smoothstep(0.0, 0.25, ph) * (1.0 - smoothstep(0.25, 0.6, ph));
	float edge = clamp(1.0 - d / band, 0.0, 1.0);
	float a = (0.45 * edge + 1.6 * dot_v * edge) * step(d, band);
	COLOR = vec4(mix(color.rgb, vec3(1.0, 1.0, 0.85), dot_v) * (1.2 + dot_v), clamp(a, 0.0, 1.0) * color.a);
}
