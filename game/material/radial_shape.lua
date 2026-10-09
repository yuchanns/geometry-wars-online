local render = require "soluna.render"
local matext = require "soluna.material.ext"
local radial = require "ext.material.radial_shape"
local ctx = ...
local state = ctx.state
radial.set_material_id(ctx.id)
local inst = render.buffer {
	type = "vertex",
	usage = "stream",
	label = "radial-instance",
	size = radial.instance_size * ctx.settings.draw_instance
}
local bindings = render.bindings()
bindings:vbuffer(0, inst)
bindings:view(0, state.views.storage)
return matext.new {
	id = ctx.id,
	instance_size = radial.instance_size,
	inst_buffer = inst,
	bindings = bindings,
	uniform = state.uniform,
	sr_buffer = state.srbuffer_mem,
	sprite_bank = ctx.arg.bank_ptr,
	texture_views = state.views,
	hooks = radial.hooks,
	label = "radial-shape"
}
