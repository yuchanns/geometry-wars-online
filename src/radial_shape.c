// Original Geometry Wars radial packing and fragment shader; adapted to Soluna material API.
#include <lua.h>
#include <lauxlib.h>
#include <stdint.h>
#include "materialapi.h"
#include "radial_shape.glsl.h"
#define RADIAL_KIND_CIRCLE 0
#define RADIAL_KIND_RING 1
#define RADIAL_KIND_BURST 2
#define RADIAL_KIND_MASK 0x0fu
#define RADIAL_LEN14_MASK 0x3fffu
#define RADIAL_LEN12_MASK 0xfffu
#define RADIAL_LEN_SCALE 8.0f
#define RADIAL_POWER_SCALE 16.0f
struct color {
	unsigned char channel[4];
};
struct radial_payload {
	uint32_t color;
	uint32_t packed0;
	uint32_t packed1;
};
struct radial_inst {
	float position[3];
	struct color color;
	uint32_t packed0;
	uint32_t packed1;
};
static int material_id;
static inline uint32_t
fixed_len(float value, uint32_t max_value) {
	if (value < 0.0f) {
		value = 0.0f;
	}
	uint32_t fixed = (uint32_t)(value * RADIAL_LEN_SCALE + 0.5f);
	if (fixed > max_value) {
		fixed = max_value;
	}
	return fixed;
}

static inline uint32_t
fixed_power(float value) {
	if (value < 0.0625f) {
		value = 0.0625f;
	}
	uint32_t fixed = (uint32_t)(value * RADIAL_POWER_SCALE + 0.5f);
	if (fixed > 0xffu) {
		fixed = 0xffu;
	}
	return fixed;
}

static struct color
argb_color(uint32_t color) {
	struct color c;
	if (!(color & 0xff000000)) {
		color |= 0xff000000;
	}
	c.channel[0] = (color >> 16) & 0xff;
	c.channel[1] = (color >> 8) & 0xff;
	c.channel[2] = color & 0xff;
	c.channel[3] = (color >> 24) & 0xff;
	return c;
}

static uint32_t
get_argb_color(lua_State *L, int index) {
	lua_getfield(L, index, "color");
	uint32_t color = (uint32_t)luaL_optinteger(L, -1, 0xffffffff);
	lua_pop(L, 1);
	if (!(color & 0xff000000)) {
		color |= 0xff000000;
	}
	return color;
}

static float
get_number_field(lua_State *L, int index, const char *field, float defv) {
	lua_getfield(L, index, field);
	float value = luaL_optnumber(L, -1, defv);
	lua_pop(L, 1);
	return value;
}

static float
get_optional_number_field(lua_State *L, int index, const char *field, float defv, int *has_value) {
	lua_getfield(L, index, field);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		return defv;
	}
	*has_value = 1;
	float value = luaL_checknumber(L, -1);
	lua_pop(L, 1);
	return value;
}

static material_error
radial_submit(const struct material_item *item, void *out) {
	const struct radial_payload *payload = (const struct radial_payload *)item->data;
	struct radial_inst *inst = out;
	inst->position[0] = item->x;
	inst->position[1] = item->y;
	inst->position[2] = item->transform_index;
	inst->color = argb_color(payload->color);
	inst->packed0 = payload->packed0;
	inst->packed1 = payload->packed1;
	return NULL;
}
static void
radial_pipeline(sg_pipeline_desc *desc) {
	desc->layout.attrs[ATTR_radial_shape_position].format = SG_VERTEXFORMAT_FLOAT3;
	desc->layout.attrs[ATTR_radial_shape_color].format = SG_VERTEXFORMAT_UBYTE4N;
	desc->layout.attrs[ATTR_radial_shape_packed0].format = SG_VERTEXFORMAT_UINT;
	desc->layout.attrs[ATTR_radial_shape_packed1].format = SG_VERTEXFORMAT_UINT;
}
static const struct material_hook radial_hooks[] = {
	{"shader", {.shader = radial_shape_shader_desc}},
	{"pipeline", {.pipeline = radial_pipeline}},
	{"submit", {.submit = radial_submit}},
	{NULL, {NULL}},
};
static int
lset_material_id(lua_State *L) {
	material_id = luaL_checkinteger(L, 1);
	return 0;
}
static int
lradial_shape(int kind, lua_State *L) {
	if (material_id <= 0) {
		return luaL_error(L, "Radial shape material is not registered");
	}
	luaL_checktype(L, 1, LUA_TTABLE);
	float radius = get_number_field(L, 1, "radius", 1.0f);
	float thickness = get_number_field(L, 1, "thickness", kind == RADIAL_KIND_RING ? 1.0f : 0.0f);
	float softness = get_number_field(L, 1, "softness", 0.75f);
	if (radius <= 0.0f) {
		lua_pushliteral(L, "");
		return 1;
	}

	struct radial_payload payload;
	payload.color = get_argb_color(L, 1);
	int has_inner_softness = 0;
	int has_outer_softness = 0;
	int has_inner_radius = 0;
	int has_power = 0;
	float inner_softness = get_optional_number_field(L, 1, "inner_softness", softness, &has_inner_softness);
	float outer_softness = get_optional_number_field(L, 1, "outer_softness", softness, &has_outer_softness);
	float inner_radius = get_optional_number_field(L, 1, "inner_radius", 0.0f, &has_inner_radius);
	float power = get_optional_number_field(L, 1, "power", 2.0f, &has_power);

	if (kind == RADIAL_KIND_BURST) {
		if (has_inner_radius) {
			thickness = inner_radius;
		} else if (thickness <= 0.0f) {
			thickness = radius * 0.18f;
		}
		if (!has_outer_softness) {
			outer_softness = 1.0f;
		}
		if (!has_power) {
			power = 2.0f;
		}
	} else if (kind == RADIAL_KIND_RING && !has_inner_softness) {
		inner_softness = softness;
	}

	/* Extent is reconstructed from the original packed values in the shader. */
	uint32_t radius_fixed = fixed_len(radius, RADIAL_LEN14_MASK);
	uint32_t thickness_fixed = fixed_len(thickness, RADIAL_LEN14_MASK);
	uint32_t inner_softness_fixed = fixed_len(inner_softness, RADIAL_LEN12_MASK);
	uint32_t outer_softness_fixed = fixed_len(outer_softness, RADIAL_LEN12_MASK);
	payload.packed0 = ((uint32_t)kind & RADIAL_KIND_MASK) | (radius_fixed << 4) | (thickness_fixed << 18);
	payload.packed1 = inner_softness_fixed | (outer_softness_fixed << 12) | (fixed_power(power) << 24);

	struct material_push_item item = {.sprite = -1, .data = &payload};
	return material_push(L, material_id, &item);
}

static int
lradial_shape_circle(lua_State *L) {
	return lradial_shape(RADIAL_KIND_CIRCLE, L);
}

static int
lradial_shape_ring(lua_State *L) {
	return lradial_shape(RADIAL_KIND_RING, L);
}

static int
lradial_shape_burst(lua_State *L) {
	return lradial_shape(RADIAL_KIND_BURST, L);
}

int
luaopen_ext_material_radial_shape(lua_State *L) {
	luaL_checkversion(L);
	luaL_Reg l[] = {
		{"set_material_id", lset_material_id},
		{"circle", lradial_shape_circle},
		{"ring", lradial_shape_ring},
		{"burst", lradial_shape_burst},
		{"instance_size", NULL},
		{NULL, NULL},
	};
	luaL_newlib(L, l);
	lua_pushinteger(L, sizeof(struct radial_inst));
	lua_setfield(L, -2, "instance_size");
	material_push_hooks(L, radial_hooks);
	lua_setfield(L, -2, "hooks");
	return 1;
}
