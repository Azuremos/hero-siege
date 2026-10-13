shader_type spatial;
render_mode diffuse_lambert, depth_draw_opaque;
// Серая брусчатка для дорог и площади у замка (камни по сетке Вороного, края — из альфы вершин).

uniform vec3 stone_light : source_color = vec3(0.62, 0.62, 0.6);
uniform vec3 stone_dark : source_color = vec3(0.42, 0.42, 0.43);
uniform vec3 grout : source_color = vec3(0.24, 0.24, 0.24);
uniform float stone_size = 0.85;

varying vec3 wpos;

vec2 hash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = wpos.xz / stone_size;
	vec2 cell = floor(p);
	vec2 f = fract(p);
	float d1 = 8.0;
	float d2 = 8.0;
	vec2 id = vec2(0.0);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 g = vec2(float(x), float(y));
			vec2 o = hash2(cell + g) * 0.8 + 0.1;
			float d = length(g + o - f);
			if (d < d1) {
				d2 = d1;
				d1 = d;
				id = cell + g;
			} else if (d < d2) {
				d2 = d;
			}
		}
	}
	float edge = d2 - d1;
	float shade = hash2(id).x;
	vec3 c = mix(stone_dark, stone_light, shade);
	c *= 0.85 + 0.15 * smoothstep(0.0, 0.35, edge);   // выпуклость камня
	c = mix(grout, c, smoothstep(0.03, 0.09, edge));    // швы
	ALBEDO = c;
	ROUGHNESS = 0.9;
	ALPHA = COLOR.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
