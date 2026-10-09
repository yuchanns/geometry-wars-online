@vs vs
layout(binding = 0) uniform vs_params {
	vec2 framesize;
	float texsize;
};

in vec3 position;
in vec4 color;
in uint packed0;
in uint packed1;

out vec2 local_pos;
out vec4 frag_color;
out flat vec4 shape0;
out flat vec4 shape1;

float unpack_len14(uint value) {
	return float(value & 0x3fffu) * 0.125;
}

float unpack_len12(uint value) {
	return float(value & 0xfffu) * 0.125;
}

struct sr_mat {
	mat2 m;
};
layout(binding = 0) readonly buffer sr_lut {
	sr_mat sr[];
};

void main() {
	uint index = uint(gl_VertexIndex);

	float kind = float(packed0 & 0x0fu);
	float radius = unpack_len14(packed0 >> 4);
	float thickness = unpack_len14(packed0 >> 18);
	float inner_softness = unpack_len12(packed1);
	float outer_softness = unpack_len12(packed1 >> 12);
	float power = max(float((packed1 >> 24) & 0xffu) * 0.0625, 0.0625);
	float extent = radius + outer_softness + 1.0;
	if (kind > 0.5 && kind < 1.5) {
		extent = radius + thickness * 0.5 + outer_softness + 1.0;
	}

	vec2 corner = vec2((index & 1u) == 0u ? -1.0 : 1.0, index < 2u ? -1.0 : 1.0);
	local_pos = corner * extent;
	vec2 pos = local_pos * sr[int(position.z)].m + position.xy;
	frag_color = color;
	shape0 = vec4(kind, radius, thickness, inner_softness);
	shape1 = vec4(outer_softness, power, 0.0, 0.0);

	vec2 clip = pos * framesize;
	gl_Position = vec4(clip.x - 1.0, clip.y + 1.0, 0.0, 1.0);
}
@end

@fs fs
in vec2 local_pos;
in vec4 frag_color;
in flat vec4 shape0;
in flat vec4 shape1;

out vec4 out_color;

float edge_softness(float requested, float d) {
	return max(max(requested, fwidth(d)), 0.5);
}

void main() {
	float kind = shape0.x;
	float radius = shape0.y;
	float thickness = shape0.z;
	float inner_softness = shape0.w;
	float outer_softness = shape1.x;
	float power = shape1.y;
	float d = length(local_pos);
	float alpha;

	if (kind < 0.5) {
		float soft = edge_softness(outer_softness, d);
		alpha = 1.0 - smoothstep(radius - soft, radius + soft, d);
	} else if (kind < 1.5) {
		float half_width = max(thickness * 0.5, 0.0);
		float inner = max(radius - half_width, 0.0);
		float outer = radius + half_width;
		float inner_soft = edge_softness(inner_softness, d);
		float outer_soft = edge_softness(outer_softness, d);
		float inner_alpha = inner <= 0.0 ? 1.0 : smoothstep(inner - inner_soft, inner + inner_soft, d);
		float outer_alpha = 1.0 - smoothstep(outer - outer_soft, outer + outer_soft, d);
		alpha = inner_alpha * outer_alpha;
	} else {
		float core_radius = min(max(thickness, 0.0), radius);
		float span = max(radius - core_radius, 0.0001);
		float t = clamp((d - core_radius) / span, 0.0, 1.0);
		alpha = pow(1.0 - t, power);
		float soft = edge_softness(outer_softness, d);
		alpha *= 1.0 - smoothstep(radius - soft, radius + soft, d);
	}

	out_color = frag_color;
	out_color.a *= clamp(alpha, 0.0, 1.0);
}
@end

@program radial_shape vs fs
