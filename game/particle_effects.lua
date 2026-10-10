-- Effect descriptions are local assets. Network events only name a preset,
-- position, direction and intensity; particle sampling stays in the service.
local M = {}
local palettes = {
	[0] = 0xffff9628,
	[1] = 0xffff508c,
	[2] = 0xff50ff50,
	[3] = 0xffa03cdc,
	[4] = 0xffffdc32,
	white = 0xffffffff,
	cyan = 0xff00ffff,
	death = 0xffffc864,
	nuke = 0xffffffc8,
	void = 0xff643296,
}
local presets = {
	explosion = {
		radial = true,
		speed_min = 80,
		speed_max = 360,
		life_min = .4,
		life_max = 1.2,
		size_min = 3,
		size_max = 6,
	},
	hit = {
		spread = math.rad(100),
		color = 0xffffffc8,
		speed_min = 150,
		speed_max = 400,
		life_min = .3,
		life_max = .7,
		size_min = 3,
		size_max = 6,
	},
	attract = {
		count = 3,
		spread = math.rad(60),
		color = 0xffdc96ff,
		speed_min = 100,
		speed_max = 179,
		life_min = .3,
		size_min = 3,
	},
	thrust = {
		count = 1,
		spread = math.rad(60),
		speed_min = 350,
		speed_max = 599,
		life_min = .35,
		life_max = .55,
		size_min = 2,
		size_max = 3,
	},
}
local thrust_colors = {
	{ r = { 150, 254 }, g = { 220, 255 }, b = { 200, 254 }, step = 16 },
	{ r = 255,          g = 240,          b = { 200, 254 }, step = 16 },
}

function M.emitter(event)
	local preset = presets[event.kind]
	if not preset then
		return
	end
	local emitter = {}
	for key, value in pairs(preset) do
		emitter[key] = value
	end
	emitter.x, emitter.y, emitter.angle = event.x, event.y, event.angle
	if event.kind == "explosion" then
		emitter.color = palettes[event.style] or palettes.white
		emitter.count = event.count
	elseif event.kind == "thrust" then
		emitter.color_range = thrust_colors[event.style == "energy" and 2 or 1]
	elseif event.kind == "hit" then
		emitter.count = math.random(5, 8)
	end
	return emitter
end

return M
