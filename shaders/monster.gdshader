shader_type spatial;
// Монстры Quaternius: части тела склеены в один меш (model_factory._merge_monster).
// Цвет части — в цвете вершины (sRGB), сила свечения части — в альфе вершины.
// Текстура атласа (если у модели она есть) умножается на цвет.

uniform sampler2D tex : source_color, filter_linear_mipmap;
uniform bool use_tex = false;
uniform float glow_energy = 1.5;

vec3 srgb_to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) / 1.055, vec3(2.4)), c / 12.92, lessThan(c, vec3(0.04045)));
}

void fragment() {
	vec3 col = srgb_to_linear(COLOR.rgb);
	if (use_tex) {
		col *= texture(tex, UV).rgb;
	}
	ALBEDO = col;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	EMISSION = col * COLOR.a * glow_energy;
}
