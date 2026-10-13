shader_type canvas_item;
// Круглая маска портрета.

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	vec4 c = texture(TEXTURE, UV);
	c.a *= 1.0 - smoothstep(0.9, 0.96, r);
	COLOR = c;
}
