local soluna = require "soluna"
local app = require "soluna.app"
local ltask = require "ltask"
local matquad = require "soluna.material.quad"
local matmask = require "soluna.material.mask"
local matradial = require "ext.material.radial_shape"
local bitmapfont = require "font"
local flow = require "flow"
local persist = require "persist"
local util = require "utils"

math.randomseed(os.time())

soluna.load_sounds "asset/geometry_wars/sounds.dl"

local args = ...
local batch = assert(args.batch)
local particle = ltask.spawn "geometry_wars/particle"
local init
local multiplayer

local W = 800
local H = 600

local KEY = {
	ESCAPE = 256,
	RELEASE = 0,
	PRESS = 1,
	LEFT = 263,
	RIGHT = 262,
	UP = 265,
	DOWN = 264,
	A = 65,
	D = 68,
	W = 87,
	S = 83,
	ENTER = 257,
	SPACE = 32,
	LEADERBOARD = 76,
	DEBUG_NUKE = 294,
	DEBUG_JACK = 295,
	DEBUG_BLACK_HOLE = 296,
}

local COLOR_WHITE = 0xffffffff
local COLOR_BLACK = 0xff000000
local COLOR_CYAN = 0xff00ffff
local COLOR_ORANGE = 0xffff9a30
local COLOR_GREEN = 0xff44ff72
local COLOR_PURPLE = 0xffb24cff
local COLOR_YELLOW = 0xffffff52
local COLOR_BLUE = 0xff61b8ff
local COLOR_RED = 0xffff554a
local COLOR_GOLD = 0xffffd760
local COLOR_SKY_BLUE = 0xff79c8ff

local function argb(a, r, g, b)
	return (a << 24) | (r << 16) | (g << 8) | b
end

local function unpack_argb(color)
	local a = color >> 24 & 0xff
	local r = color >> 16 & 0xff
	local g = color >> 8 & 0xff
	local b = color & 0xff
	return a, r, g, b
end

local function rgba_bytes(color)
	local a, r, g, b = unpack_argb(color)
	return string.pack("BBBB", r, g, b, a)
end

local function with_alpha(color, alpha)
	return (color & 0x00ffffff) | (alpha << 24)
end

local function scale_alpha(color, factor)
	local a = color >> 24 & 0xff
	local scaled = math.floor(a * factor + 0.5)
	if scaled < 0 then
		scaled = 0
	elseif scaled > 0xff then
		scaled = 0xff
	end
	return with_alpha(color, scaled)
end

local function clamp(v, min_v, max_v)
	if v < min_v then
		return min_v
	end
	if v > max_v then
		return max_v
	end
	return v
end

local function blend_argb(dst, src)
	local sa, sr, sg, sb = unpack_argb(src)
	if sa == 0 then
		return dst
	end
	if sa == 0xff then
		return src
	end

	local da, dr, dg, db = unpack_argb(dst)
	local src_alpha = sa / 255.0
	local dst_alpha = da / 255.0
	local out_alpha = src_alpha + dst_alpha * (1.0 - src_alpha)
	if out_alpha <= 0 then
		return 0
	end

	local out_r = (sr * src_alpha + dr * dst_alpha * (1.0 - src_alpha)) / out_alpha
	local out_g = (sg * src_alpha + dg * dst_alpha * (1.0 - src_alpha)) / out_alpha
	local out_b = (sb * src_alpha + db * dst_alpha * (1.0 - src_alpha)) / out_alpha

	return argb(
		math.floor(out_alpha * 255.0 + 0.5),
		math.floor(out_r + 0.5),
		math.floor(out_g + 0.5),
		math.floor(out_b + 0.5)
	)
end

local build_sprite_assets
local build_font_assets

do
	local function create_canvas(width, height)
		local pixels = {}
		for i = 1, width * height do
			pixels[i] = 0
		end

		local canvas = {}

		function canvas.blend_pixel(x, y, color)
			x = math.floor(x)
			y = math.floor(y)
			if x < 0 or x >= width or y < 0 or y >= height then
				return
			end
			local index = y * width + x + 1
			pixels[index] = blend_argb(pixels[index], color)
		end

		function canvas.to_content()
			local packed = {}
			for i = 1, #pixels do
				packed[i] = rgba_bytes(pixels[i])
			end
			return table.concat(packed)
		end

		return canvas
	end

	local function regular_polygon(cx, cy, radius, sides, rotation)
		local points = {}
		for i = 0, sides - 1 do
			local angle = rotation + i * math.pi * 2.0 / sides
			points[#points + 1] = cx + math.cos(angle) * radius
			points[#points + 1] = cy + math.sin(angle) * radius
		end
		return points
	end

	---@return boolean
	local function point_in_polygon(px, py, points)
		local inside = false
		local count = #points // 2
		local j = count
		for i = 1, count do
			local xi = points[i * 2 - 1]
			local yi = points[i * 2]
			local xj = points[j * 2 - 1]
			local yj = points[j * 2]
			local intersect = (yi > py) ~= (yj > py)
				and px < (xj - xi) * (py - yi) / ((yj - yi) ~= 0 and (yj - yi) or 1e-6) + xi
			if intersect then
				inside = not inside
			end
			j = i
		end
		return inside
	end

	local function segment_distance_sq(px, py, ax, ay, bx, by)
		local abx = bx - ax
		local aby = by - ay
		local apx = px - ax
		local apy = py - ay
		local denom = abx * abx + aby * aby
		if denom <= 0.000001 then
			local dx = px - ax
			local dy = py - ay
			return dx * dx + dy * dy
		end
		local t = (apx * abx + apy * aby) / denom
		if t < 0 then
			t = 0
		elseif t > 1 then
			t = 1
		end
		local qx = ax + abx * t
		local qy = ay + aby * t
		local dx = px - qx
		local dy = py - qy
		return dx * dx + dy * dy
	end

	local function fill_circle(canvas, cx, cy, radius, color)
		local min_x = math.floor(cx - radius)
		local max_x = math.ceil(cx + radius)
		local min_y = math.floor(cy - radius)
		local max_y = math.ceil(cy + radius)
		local radius_sq = radius * radius
		for y = min_y, max_y do
			for x = min_x, max_x do
				local dx = x + 0.5 - cx
				local dy = y + 0.5 - cy
				if dx * dx + dy * dy <= radius_sq then
					canvas.blend_pixel(x, y, color)
				end
			end
		end
	end

	local function stroke_circle(canvas, cx, cy, radius, thickness, color)
		local outer = radius + thickness * 0.5
		local inner = radius - thickness * 0.5
		local outer_sq = outer * outer
		local inner_sq = inner > 0 and inner * inner or 0
		local min_x = math.floor(cx - outer)
		local max_x = math.ceil(cx + outer)
		local min_y = math.floor(cy - outer)
		local max_y = math.ceil(cy + outer)
		for y = min_y, max_y do
			for x = min_x, max_x do
				local dx = x + 0.5 - cx
				local dy = y + 0.5 - cy
				local dist_sq = dx * dx + dy * dy
				if dist_sq <= outer_sq and dist_sq >= inner_sq then
					canvas.blend_pixel(x, y, color)
				end
			end
		end
	end

	local function fill_polygon(canvas, points, color)
		local min_x = math.huge
		local max_x = -math.huge
		local min_y = math.huge
		local max_y = -math.huge
		for i = 1, #points, 2 do
			local x = points[i]
			local y = points[i + 1]
			if x < min_x then
				min_x = x
			end
			if x > max_x then
				max_x = x
			end
			if y < min_y then
				min_y = y
			end
			if y > max_y then
				max_y = y
			end
		end

		for y = math.floor(min_y), math.ceil(max_y) do
			for x = math.floor(min_x), math.ceil(max_x) do
				if point_in_polygon(x + 0.5, y + 0.5, points) then
					canvas.blend_pixel(x, y, color)
				end
			end
		end
	end

	local function stroke_polygon(canvas, points, thickness, color)
		local min_x = math.huge
		local max_x = -math.huge
		local min_y = math.huge
		local max_y = -math.huge
		for i = 1, #points, 2 do
			local x = points[i]
			local y = points[i + 1]
			if x < min_x then
				min_x = x
			end
			if x > max_x then
				max_x = x
			end
			if y < min_y then
				min_y = y
			end
			if y > max_y then
				max_y = y
			end
		end

		local outer = thickness * 0.5
		local outer_sq = outer * outer
		local count = #points // 2
		for y = math.floor(min_y - outer), math.ceil(max_y + outer) do
			for x = math.floor(min_x - outer), math.ceil(max_x + outer) do
				local px = x + 0.5
				local py = y + 0.5
				for i = 1, count do
					local j = i == count and 1 or i + 1
					local ax = points[i * 2 - 1]
					local ay = points[i * 2]
					local bx = points[j * 2 - 1]
					local by = points[j * 2]
					if segment_distance_sq(px, py, ax, ay, bx, by) <= outer_sq then
						canvas.blend_pixel(x, y, color)
						break
					end
				end
			end
		end
	end

	local function player_triangle_points(cx, cy, scale)
		local back = math.pi
		return {
			cx + 18.0 * scale,
			cy,
			cx + ((math.cos(back) * 10.0 + math.cos(back + 1.3) * 10.0) * scale),
			cy + ((math.sin(back) * 10.0 + math.sin(back + 1.3) * 10.0) * scale),
			cx + ((math.cos(back) * 10.0 + math.cos(back - 1.3) * 10.0) * scale),
			cy + ((math.sin(back) * 10.0 + math.sin(back - 1.3) * 10.0) * scale),
		}
	end

	local function build_player_core_mask()
		local size = 72
		local canvas = create_canvas(size, size)
		local cx = size // 2
		local cy = size // 2
		fill_polygon(canvas, player_triangle_points(cx, cy, 1.0), COLOR_WHITE)
		return canvas.to_content(), size, size
	end

	local function build_player_outline_mask()
		local size = 88
		local canvas = create_canvas(size, size)
		local cx = size // 2
		local cy = size // 2
		stroke_polygon(canvas, player_triangle_points(cx, cy, 1.3), 2.0, COLOR_WHITE)
		return canvas.to_content(), size, size
	end

	local function build_player_sprite()
		local size = 96
		local canvas = create_canvas(size, size)
		local cx = size // 2
		local cy = size // 2
		fill_circle(canvas, cx, cy, 20, scale_alpha(COLOR_CYAN, 0.24))
		stroke_polygon(canvas, player_triangle_points(cx, cy, 1.3), 2.0, scale_alpha(COLOR_WHITE, 0.65))
		fill_polygon(canvas, player_triangle_points(cx, cy, 1.0), COLOR_CYAN)
		fill_circle(canvas, cx - 12, cy, 4, scale_alpha(COLOR_ORANGE, 0.60))
		return canvas.to_content(), size, size
	end

	local function build_swarm_shape()
		local size = 32
		local canvas = create_canvas(size, size)
		local cx = size // 2
		local cy = size // 2
		fill_circle(canvas, cx, cy, 6.0, COLOR_WHITE)
		stroke_circle(canvas, cx, cy, 7.5, 1.5, scale_alpha(COLOR_WHITE, 0.55))
		return canvas.to_content(), size, size
	end

	local function build_chaser_shape()
		local size = 40
		local canvas = create_canvas(size, size)
		local cx = size // 2
		local cy = size // 2
		local triangle = {
			cx + 11, cy,
			cx - 8, cy - 10,
			cx - 8, cy + 10,
		}
		stroke_polygon(canvas, triangle, 2.0, COLOR_WHITE)
		return canvas.to_content(), size, size
	end

	local function build_bouncer_shape()
		local size = 40
		local canvas = create_canvas(size, size)
		local cx = size // 2
		local cy = size // 2
		local diamond = {
			cx, cy - 12,
			cx + 12, cy,
			cx, cy + 12,
			cx - 12, cy,
		}
		stroke_polygon(canvas, diamond, 2.0, COLOR_WHITE)
		return canvas.to_content(), size, size
	end

	local function build_orbiter_shape()
		local size = 56
		local canvas = create_canvas(size, size)
		local cx = size // 2
		local cy = size // 2
		fill_circle(canvas, cx, cy, 13.0, scale_alpha(COLOR_WHITE, 0.25))
		stroke_circle(canvas, cx, cy, 13.0, 2.0, COLOR_WHITE)
		stroke_circle(canvas, cx, cy, 7.5, 2.0, scale_alpha(COLOR_WHITE, 0.85))
		return canvas.to_content(), size, size
	end

	local function build_weaver_shape()
		local size = 44
		local canvas = create_canvas(size, size)
		local cx = size // 2
		local cy = size // 2
		local pentagon = regular_polygon(cx, cy, 12, 5, -math.pi / 2)
		stroke_polygon(canvas, pentagon, 2.0, COLOR_WHITE)
		return canvas.to_content(), size, size
	end

	local function build_powerup_shape(radius)
		local size = radius * 2 + 4
		local canvas = create_canvas(size, size)
		local cx = size // 2
		local cy = size // 2
		fill_polygon(canvas, { cx, cy - radius, cx + radius, cy, cx, cy }, COLOR_WHITE)
		fill_polygon(canvas, { cx, cy, cx + radius, cy, cx, cy + radius }, COLOR_WHITE)
		fill_polygon(canvas, { cx - radius, cy, cx, cy, cx, cy + radius }, COLOR_WHITE)
		return canvas.to_content(), size, size
	end

	local function build_black_hole_sprite()
		local size = 64
		local canvas = create_canvas(size, size)
		local cx = size // 2
		local cy = size // 2
		stroke_circle(canvas, cx, cy, 18, 2.0, scale_alpha(COLOR_PURPLE, 0.55))
		fill_circle(canvas, cx, cy, 11, scale_alpha(COLOR_PURPLE, 0.65))
		fill_circle(canvas, cx, cy, 7, scale_alpha(0xff6b1a8d, 0.90))
		fill_circle(canvas, cx, cy, 3, COLOR_WHITE)
		return canvas.to_content(), size, size
	end

	local function register_sprite(add_sprite, name, builder, ...)
		local content, width, height = builder(...)
		add_sprite(name, content, width, height)
	end

	local function register_radius_sprites(add_sprite, prefix, builder, first_radius, last_radius, step, ...)
		for radius = first_radius, last_radius, step do
			local content, width, height = builder(radius, ...)
			add_sprite(prefix .. radius, content, width, height)
		end
	end

	local function count_radius_sprites(first_radius, last_radius, step)
		return (last_radius - first_radius) // step + 1
	end

	local function add_preloaded_sprite(bundle, name, content, width, height, offset_x, offset_y)
		local filename = "@" .. name
		soluna.preload {
			filename = filename,
			content = content,
			w = width,
			h = height,
		}
		bundle[#bundle + 1] = {
			name = name,
			filename = filename,
			cw = width,
			ch = height,
			x = offset_x == nil and -0.5 or offset_x,
			y = offset_y == nil and -0.5 or offset_y,
		}
	end

	local function load_bitmap_font_sprites()
		local bundle = {}
		bitmapfont.register_bitmap_glyphs(function(name, content, width, height, offset_x, offset_y)
			add_preloaded_sprite(bundle, name, content, width, height, offset_x, offset_y)
		end)
		local loaded = soluna.load_sprites(bundle)
		bitmapfont.attach_bitmap_glyphs(loaded)
		return loaded.font_glyphs
	end

	build_sprite_assets = function(progress)
		local bundle = {}
		local shape_builders = {
			{ "swarm_shape",   build_swarm_shape },
			{ "chaser_shape",  build_chaser_shape },
			{ "bouncer_shape", build_bouncer_shape },
			{ "orbiter_shape", build_orbiter_shape },
			{ "weaver_shape",  build_weaver_shape },
		}

		if progress then
			local total = 0
			total = total + 3
			total = total + #shape_builders
			total = total + count_radius_sprites(12, 18, 1)
			total = total + 1
			progress.done = 0
			progress.total = total
			progress.current = ""
			progress.ready = false
		end

		local function add_sprite(name, content, width, height, offset_x, offset_y)
			add_preloaded_sprite(bundle, name, content, width, height, offset_x, offset_y)
			if progress then
				progress.done = progress.done + 1
				progress.current = name
				flow.sleep(0)
			end
		end

		register_sprite(add_sprite, "player", build_player_sprite)
		register_sprite(add_sprite, "player_core_mask", build_player_core_mask)
		register_sprite(add_sprite, "player_outline_mask", build_player_outline_mask)

		for _, def in ipairs(shape_builders) do
			register_sprite(add_sprite, def[1], def[2])
		end

		register_radius_sprites(add_sprite, "powerup_shape_", build_powerup_shape, 12, 18, 1)
		register_sprite(add_sprite, "black_hole", build_black_hole_sprite)

		local loaded = soluna.load_sprites(bundle)

		return loaded
	end

	build_font_assets = load_bitmap_font_sprites
end

soluna.set_window_title "Geometry Wars"

local sprites
local loading_sprites = {
	font_glyphs = build_font_assets(),
}
local asset_progress = {
	started = false,
	ready = false,
	done = 0,
	total = 1,
	current = "",
	error = nil,
}
local quad = util.quad_cache(matquad)
local view = util.fixed_view(args, W, H)
local masked = util.cache(function(sprite)
	return util.cache(function(color)
		return matmask.mask(sprite, color)
	end)
end)
local radial_circle = util.cache(function(radius)
	return util.cache(function(color)
		return matradial.circle {
			radius = radius,
			color = color,
			outer_softness = 0.75,
		}
	end)
end)

local function start_sprite_loading()
	if asset_progress.started then
		return
	end
	asset_progress.started = true
	ltask.fork(function()
		local ok, loaded = pcall(build_sprite_assets, asset_progress)
		if ok then
			sprites = loaded
			sprites.font_glyphs = loading_sprites.font_glyphs
			asset_progress.done = asset_progress.total
			asset_progress.current = "ready"
			asset_progress.ready = true
		else
			asset_progress.error = tostring(loaded)
		end
	end)
end

local function clear_particles()
	ltask.send(particle, "clear")
end

do
	function init()
		ltask.call(particle, "init")
		init = nil
	end
end

local MAP_W = 1200
local MAP_H = 900
local PLAYER_SPEED = 250.0
local CAMERA_LERP = 0.10
local GRID_SPACING = 25
local GRID_COLS = MAP_W // GRID_SPACING + 1
local GRID_ROWS = MAP_H // GRID_SPACING + 1
local MAX_STARS_FAR = 50
local MAX_STARS_NEAR = 30
local MAX_BULLETS = 150
local MAX_ENEMIES = 100
local MAX_FLOAT_TEXTS = 30
local MAX_TICKER = 4
local MAX_POWERUPS = 5
local BULLET_SPEED = 810.0
local SHOOT_RATE = 0.12
local COMBO_TIMEOUT = 2.0
local POPUP_LIFE = 2.0
local POPUP_GROW_TIME = 0.2
local POPUP_FADE_TIME = 0.5
local MAX_LIVES = 3
local RESPAWN_INVINCIBLE = 2.0
local SPAWN_CLEAR_RADIUS = 150.0
local TRAIL_LEN = 12
local TRAIL_INTERVAL = 0.03
local COLOR_GRID = 0x46323282
local COLOR_BORDER = 0xb46464ff
local BULLET_CORE = argb(255, 200, 255, 200)
local BULLET_GLOW = argb(100, 100, 255, 100)
local BULLET_HOMING_CORE = argb(255, 130, 220, 255)
local BULLET_HOMING_GLOW = argb(100, 80, 180, 255)
local PLAYER_GLOW = argb(60, 0, 255, 255)
local PLAYER_CORE = argb(240, 0, 255, 255)
local PLAYER_OUTLINE = argb(160, 100, 255, 255)
local PLAYER_TRAIL = argb(100, 0, 200, 255)
local ENGINE_GLOW = argb(150, 255, 180, 60)
local BULLET_SPARK_SPREAD = 100.0 * math.pi / 180.0
local ATTRACT_SPARK_SPREAD = 60.0 * math.pi / 180.0
local THRUST_SPREAD = 60.0 * math.pi / 180.0
local THRUST_NORMAL_COLOR_RANGE = { r = { 150, 254 }, g = { 220, 255 }, b = { 200, 254 }, step = 16 }
local THRUST_ENERGY_COLOR_RANGE = { r = 255, g = 240, b = { 200, 254 }, step = 16 }

local ENEMY_DEFS = {
	[0] = {
		name = "SWARM",
		color = argb(255, 255, 150, 40),
		score = 50,
		radius = 10,
		speed = 60,
		hp = 1,
		shape_sprite = "swarm_shape",
		glow_scale = 1.8,
		icon_scale = 0.5,
	},
	[1] = {
		name = "CHASER",
		color = argb(255, 255, 80, 140),
		score = 100,
		radius = 12,
		speed = 140,
		hp = 1,
		shape_sprite = "chaser_shape",
		draw_rotated = true,
		glow_scale = 2.0,
		icon_scale = 0.4,
	},
	[2] = {
		name = "BOUNCER",
		color = argb(255, 80, 255, 80),
		score = 150,
		radius = 14,
		speed = 100,
		hp = 2,
		shape_sprite = "bouncer_shape",
		draw_rotated = true,
		glow_scale = 1.5,
		icon_scale = 0.4,
	},
	[3] = {
		name = "ORBITER",
		color = argb(255, 160, 60, 220),
		score = 300,
		radius = 22,
		speed = 50,
		hp = 5,
		shape_sprite = "orbiter_shape",
		glow_scale = 1.6,
		icon_scale = 0.36,
		core_color = argb(200, 220, 120, 255),
		core_scale = 0.6,
	},
	[4] = {
		name = "WEAVER",
		color = argb(255, 255, 220, 50),
		score = 200,
		radius = 12,
		speed = 120,
		hp = 2,
		shape_sprite = "weaver_shape",
		draw_rotated = true,
		glow_scale = 1.6,
		icon_scale = 0.4,
	},
}

local NUKE_DEF = {
	name = "NUKE",
	color = COLOR_CYAN,
	glow = argb(80, 0, 200, 255),
	outline = argb(150, 0, 255, 255),
}

local ABILITY_DEFS = {
	[0] = {
		name = "SPREAD",
		color = argb(255, 255, 180, 60),
		glow = argb(80, 255, 120, 30),
		outline = argb(150, 255, 120, 30),
		popup = "SPREAD SHOT!",
	},
	[1] = {
		name = "HOMING",
		color = argb(255, 130, 220, 255),
		glow = argb(80, 80, 180, 255),
		outline = argb(150, 80, 180, 255),
		popup = "HOMING SHOT!",
	},
	[2] = {
		name = "SHIELD",
		color = argb(255, 255, 215, 0),
		glow = argb(80, 200, 160, 0),
		outline = argb(150, 200, 160, 0),
		popup = "SHIELD!",
	},
	[3] = {
		name = "SLOW",
		color = argb(255, 80, 180, 255),
		glow = argb(80, 40, 100, 220),
		outline = argb(150, 40, 100, 220),
		popup = "SLOW FIELD!",
	},
}

local input = {
	---@type boolean
	left = false,
	---@type boolean
	right = false,
	---@type boolean
	up = false,
	---@type boolean
	down = false,
	---@type boolean
	mouse_left = false,
	---@type boolean
	mouse_pressed = false,
	---@type boolean
	mouse_released = false,
	---@type boolean|string
	ui_active_button = false,
	key_pressed = {},
	ui_actions = {},
}
local window_w = args.width or W
local window_h = args.height or H
local mouse_screen_x = window_w * 0.5
local mouse_screen_y = window_h * 0.5
local mouse_world_x = MAP_W * 0.5
local mouse_world_y = MAP_H * 0.5
local last_tick
local fps = 0.0
local fps_clock
local fps_frames = 0
local state = {
	---@type string
	scene = "title",
	---@type number
	scene_time = 0.0,
	---@type number
	game_time = 0.0,
	---@type number
	total_time = 0.0,
	---@type number
	lives = MAX_LIVES,
	---@type number
	score = 0,
	---@type number
	combo = 1,
	---@type number
	highest_combo = 1,
	---@type number
	total_kills = 0,
	---@type number
	combo_timer = 0.0,
	---@type number
	combo_bump_timer = 0.0,
	---@type number
	spawn_timer = 0.0,
	---@type number
	shoot_timer = 0.0,
	---@type number
	trail_timer = 0.0,
	---@type number
	trail_count = 0,
	---@type number
	thrust_particle_timer = 0.0,
	---@type number
	respawn_timer = 0.0,
	---@type boolean
	respawn_invincible = false,
	---@type boolean
	player_alive = true,
	---@type number
	killed_by_type = -1,
	---@type number
	shake_amt = 0.0,
	---@type number
	shake_frames = 0,
	---@type number
	shake_x = 0.0,
	---@type number
	shake_y = 0.0,
	---@type number
	screen_shake_y = 0.0,
	---@type number
	screen_shake_frames = 0,
	---@type boolean
	combo5_shown = false,
	---@type boolean
	combo10_shown = false,
	---@type boolean
	kills50_shown = false,
	---@type boolean
	kills100_shown = false,
	---@type boolean
	kills200_shown = false,
	---@type number
	best_score = 0,
	best_time = 0.0,
	lb_highlight = -1,
	---@type boolean|string
	save_path = false,
	---@type any[]
	leaderboard = {},
}
local audio = {
	music_voice = nil,
	death_sound_played = false,
	shoot = { "shoot_01", "shoot_02", "shoot_03", "shoot_04" },
	explosion = {
		"explosion_01", "explosion_02", "explosion_03", "explosion_04",
		"explosion_05", "explosion_06", "explosion_07", "explosion_08",
	},
	spawn = { "spawn_01", "spawn_02", "spawn_03", "spawn_04", "spawn_05", "spawn_06", "spawn_07", "spawn_08" },
	rise = { "rise_01", "rise_02", "rise_03", "rise_04", "rise_05", "rise_06", "rise_07" },
	powerup = "powerup_01",
	death = "explosion_01",
	game_over = "explosion_02",
}
local trail_x = {}
local trail_y = {}
local trail_a = {}

local player = {
	x = MAP_W * 0.5,
	y = MAP_H * 0.5,
	---@type number
	angle = 0,
}

local camera = {
	---@type number
	x = 0,
	---@type number
	y = 0,
}

local stars_far = {}
local stars_near = {}
---@type any[]
local grid = {}
---@type any[]
local bullets = {}
---@type any[]
local enemies = {}
local feedback = {
	---@type any[]
	float_texts = {},
	---@type any[]
	ticker_msgs = {},
	popup = {
		text = "",
		color = COLOR_WHITE,
		---@type number
		life = 0.0,
		---@type number
		max_life = 0.0,
		---@type number
		scale = 1,
	},
	menu_colors = {
		red = 0xffff0000,
		dark_gray = 0xff444444,
		light_gray = 0xffcccccc,
	},
}
state.frame_dt = 1.0 / 60.0

function state.set_scene_hooks(draw_world, draw_overlay)
	state.scene_draw_world = draw_world
	state.scene_draw_overlay = draw_overlay
end

function input.emit_ui_action(action)
	input.ui_actions[action] = true
end

function input.consume_ui_action(action)
	local pending = input.ui_actions[action] == true
	input.ui_actions[action] = nil
	return pending
end

function input.clear_ui_actions()
	for action in pairs(input.ui_actions) do
		input.ui_actions[action] = nil
	end
end

function input.consume_key_press(keycode)
	local pressed = input.key_pressed[keycode] == true
	input.key_pressed[keycode] = nil
	return pressed
end

function input.clear_key_presses()
	for keycode in pairs(input.key_pressed) do
		input.key_pressed[keycode] = nil
	end
end

function feedback.ui_lighten_rgb(color, amount)
	amount = clamp(amount, 0, 255)
	local a, r, g, b = unpack_argb(color)
	r = r + math.floor((255 - r) * amount / 255)
	g = g + math.floor((255 - g) * amount / 255)
	b = b + math.floor((255 - b) * amount / 255)
	return argb(a, r, g, b)
end

function feedback.ui_darken_rgb(color, amount)
	amount = clamp(amount, 0, 255)
	local a, r, g, b = unpack_argb(color)
	local scale = 255 - amount
	r = math.floor(r * scale / 255)
	g = math.floor(g * scale / 255)
	b = math.floor(b * scale / 255)
	return argb(a, r, g, b)
end

function feedback.ui_button_text_color(color)
	local _, r, g, b = unpack_argb(color)
	local luma = r * 299 + g * 587 + b * 114
	if luma >= 140000 then
		return COLOR_BLACK
	end
	return COLOR_WHITE
end

function feedback.draw_bevel_rect(x, y, width, height, face, pressed)
	if width <= 0 or height <= 0 then
		return
	end

	local function add_rect(rx, ry, rw, rh, color)
		if rw <= 0 or rh <= 0 then
			return
		end
		batch:add(quad { width = rw, height = rh, color = color }, rx, ry)
	end

	add_rect(x, y, width, height, face)

	local light_outer = feedback.ui_lighten_rgb(face, 112)
	local light_inner = feedback.ui_lighten_rgb(face, 56)
	local dark_outer = feedback.ui_darken_rgb(face, 112)
	local dark_inner = feedback.ui_darken_rgb(face, 56)

	if pressed then
		light_outer, dark_outer = dark_outer, light_outer
		light_inner, dark_inner = dark_inner, light_inner
	end

	add_rect(x, y, width, 1, light_outer)
	add_rect(x, y, 1, height, light_outer)
	add_rect(x, y + height - 1, width, 1, dark_outer)
	add_rect(x + width - 1, y, 1, height, dark_outer)

	if width > 2 and height > 2 then
		add_rect(x + 1, y + 1, width - 2, 1, light_inner)
		add_rect(x + 1, y + 1, 1, height - 2, light_inner)
		add_rect(x + 1, y + height - 2, width - 2, 1, dark_inner)
		add_rect(x + width - 2, y + 1, 1, height - 2, dark_inner)
	end
end

local powerup = {
	---@type any[]
	entries = {},
	---@type any[]
	black_holes = {},
	---@type number
	spawn_timer = 0.0,
	---@type number
	jack_timer = 0.0,
	---@type boolean
	jack_active = false,
	---@type number
	jack_spawn_timer = 0.0,
	---@type number
	jack_count = 0,
	---@type number
	jack_total = 0,
	---@type number
	bh_spawn_timer = 0.0,
	---@type number
	nuke_flash_alpha = 0.0,
	---@type number
	nuke_wave_radius = 0.0,
	---@type number
	nuke_wave_alpha = 0.0,
	---@type boolean
	nuke_fx_active = false,
	energy_duration = 5.0,
	energy_shoot_rate = 0.08,
	---@type boolean
	energy_active = false,
	---@type number
	energy_timer = 0.0,
	---@type number
	ability_type = 0,
	---@type boolean
	homing_active = false,
	---@type boolean
	shield_active = false,
	---@type boolean
	slow_active = false,
	---@type number
	shield_angle = 0.0,
	jack_phrases = {
		"THE SWARM RISES FROM EVERY CORNER!",
		"SHADOWS CONVERGE - ENEMIES SURGING FROM ALL SIDES!",
		"THE HIVE HAS AWAKENED - INVASION INBOUND!",
		"FOUR WALLS BREACHED - DENSITY CRITICAL!",
		"NOWHERE TO HIDE - THEY COME FROM EVERYWHERE!",
	},
	bh_phrases = {
		"GRAVITATIONAL ANOMALY DETECTED - CAUTION ADVISED!",
		"A SINGULARITY FORMS - ALL TRAJECTORIES BENDING!",
		"THE VOID AWAKENS - SPACE ITSELF IS WARPING!",
		"GRAVITY WELL ACTIVE - NOTHING ESCAPES ITS PULL!",
		"DIMENSIONAL RIFT - REALITY COLLAPSING INWARD!",
	},
}

---@type fun(cx, cy, radius, strength)
local grid_impulse

local function random_star_color(alpha_min, alpha_max)
	local alpha = math.random(alpha_min, alpha_max)
	local variant = math.random(1, 3)
	if variant == 1 then
		return argb(alpha, 200, 200, 255)
	elseif variant == 2 then
		return argb(alpha, 180, 220, 255)
	end
	return argb(alpha, 220, 220, 220)
end

local function quantize_byte(value, step)
	local q = math.floor((value + step * 0.5) / step) * step
	return clamp(q, 0, 255)
end

local function particle_alpha(color, alpha)
	local _, r, g, b = unpack_argb(color)
	return argb(quantize_byte(alpha, 16), r, g, b)
end

local function distance(ax, ay, bx, by)
	local dx = bx - ax
	local dy = by - ay
	return math.sqrt(dx * dx + dy * dy)
end

local function enemy_color(enemy_type)
	local def = ENEMY_DEFS[enemy_type]
	return def and def.color or COLOR_WHITE
end

local function stop_music(fade_seconds)
	local voice = audio.music_voice
	audio.music_voice = nil
	if voice == nil then
		return
	end
	voice:stop(fade_seconds)
end

local function ensure_music_playing()
	local voice = audio.music_voice
	if voice ~= nil and voice:playing() then
		return
	end
	local started, err = soluna.play_sound "music1"
	if started == nil then
		error(err or "failed to start Geometry Wars music")
	end
	audio.music_voice = started
end

local function play_effect(name, opts)
	if multiplayer then multiplayer.record("sound", {name, opts or {}}) end
	local voice, err = soluna.play_sound(name, opts)
	if voice == nil then
		error(err or ("failed to play sound " .. tostring(name)))
	end
	return voice
end

local function play_random_effect(list, opts)
	return play_effect(list[math.random(1, #list)], opts)
end

function state.sync_scene(next_scene)
	if state.scene ~= next_scene then
		local previous_scene = state.scene
		state.scene = next_scene
		state.scene_time = 0.0
		input.ui_active_button = false
		input.clear_ui_actions()
		if next_scene == "death" then
			audio.death_sound_played = false
		elseif next_scene == "over" then
			play_effect(audio.game_over)
		end
		if next_scene == "combat" then
			ensure_music_playing()
		elseif previous_scene == "combat" then
			stop_music()
		end
	end
end

function state.center_camera()
	camera.x = (MAP_W - W) * 0.5
	camera.y = (MAP_H - H) * 0.5
end

function state.load_records()
	for i = 1, 10 do
		if state.leaderboard[i] == nil then
			state.leaderboard[i] = {
				score = 0,
				time = 0.0,
				kills = 0,
				combo = 0,
			}
		end
	end

	if state.save_path == false then
		local ok, dir = pcall(soluna.gamedir)
		if ok and type(dir) == "string" then
			state.save_path = dir .. "geometry_wars_save.dl"
		else
			state.save_path = "./geometry_wars_save.dl"
		end
	end

	local ok, data = persist.load(state.save_path)
	if not ok or type(data) ~= "table" then
		return
	end

	state.best_score = tonumber(data.best_score) or 0
	state.best_time = tonumber(data.best_time) or 0.0
	if type(data.leaderboard) == "table" then
		for i = 1, 10 do
			local src = data.leaderboard[i]
			local dst = state.leaderboard[i]
			if type(src) == "table" then
				dst.score = tonumber(src.score) or 0
				dst.time = tonumber(src.time) or 0.0
				dst.kills = tonumber(src.kills) or 0
				dst.combo = tonumber(src.combo) or 0
			else
				dst.score = 0
				dst.time = 0.0
				dst.kills = 0
				dst.combo = 0
			end
		end
	end
end

function state.save_records()
	if not state.save_path then
		state.load_records()
	end

	local rows = {}
	for i = 1, 10 do
		local entry = state.leaderboard[i] or {}
		rows[i] = {
			score = tonumber(entry.score) or 0,
			time = tonumber(entry.time) or 0.0,
			kills = tonumber(entry.kills) or 0,
			combo = tonumber(entry.combo) or 0,
		}
	end

	persist.save(state.save_path, {
		best_score = state.best_score,
		best_time = state.best_time,
		leaderboard = rows,
	})
end

function state.insert_leaderboard(score, survival_time, kills, combo)
	local pos = -1
	for i = 1, 10 do
		if score > state.leaderboard[i].score then
			pos = i
			break
		end
	end
	if pos < 0 then
		return -1
	end
	for i = 10, pos + 1, -1 do
		local prev = state.leaderboard[i - 1]
		local dst = state.leaderboard[i]
		dst.score = prev.score
		dst.time = prev.time
		dst.kills = prev.kills
		dst.combo = prev.combo
	end
	local row = state.leaderboard[pos]
	row.score = score
	row.time = survival_time
	row.kills = kills
	row.combo = combo
	state.save_records()
	return pos
end

local function shake(amount, frames)
	if amount > state.shake_amt then
		state.shake_amt = amount
		state.shake_frames = frames
	end
end

local function draw_masked_circle(color, radius, x, y)
	if radius <= 0 then
		return
	end
	batch:add(radial_circle[radius][color], x, y)
end

local function draw_masked_ring(color, radius, x, y, thickness, inner_softness, outer_softness)
	if radius <= 0 then
		return
	end
	batch:add(matradial.ring {
		radius = radius,
		thickness = thickness or 1.5,
		inner_softness = inner_softness or 0.75,
		outer_softness = outer_softness or 0.75,
		color = color,
	}, x, y)
end

function feedback.spawn_float_text(x, y, text, color)
	for i = 1, MAX_FLOAT_TEXTS do
		local float_text = feedback.float_texts[i]
		if float_text.life <= 0 then
			float_text.x = x
			float_text.y = y
			float_text.vy = -60.0
			float_text.text = text
			float_text.color = color
			float_text.life = 1.0
			float_text.max_life = 1.0
			return
		end
	end
end

function feedback.show_popup(text, color, scale)
	feedback.popup.text = text
	feedback.popup.color = color
	feedback.popup.life = POPUP_LIFE
	feedback.popup.max_life = POPUP_LIFE
	feedback.popup.scale = scale
end

function feedback.ticker_add(text, color)
	local slot = -1
	for i = 1, MAX_TICKER do
		if not feedback.ticker_msgs[i].active then
			slot = i
			break
		end
	end
	if slot == -1 then
		local best_life = 999.0
		for i = 1, MAX_TICKER do
			local remaining = feedback.ticker_msgs[i].life - feedback.ticker_msgs[i].timer
			if remaining < best_life then
				best_life = remaining
				slot = i
			end
		end
	end
	local msg = feedback.ticker_msgs[slot]
	msg.text = text
	msg.color = color
	msg.life = 3.0
	msg.timer = 0.0
	msg.active = true
end

local function spawn_bullet(angle, homing)
	for i = 1, MAX_BULLETS do
		local bullet = bullets[i]
		if not bullet.active then
			bullet.active = true
			bullet.x = player.x + math.cos(angle) * 15.0
			bullet.y = player.y + math.sin(angle) * 15.0
			bullet.vx = math.cos(angle) * BULLET_SPEED
			bullet.vy = math.sin(angle) * BULLET_SPEED
			bullet.homing = homing
			return
		end
	end
end

local function emit_particles(emitter)
	if multiplayer then multiplayer.record("emit", emitter) end
	ltask.send(particle, "emit", emitter)
end

local function spawn_explosion(x, y, color, count)
	emit_particles {
		x = x,
		y = y,
		count = count,
		color = color,
		radial = true,
		speed_min = 80.0,
		speed_max = 360.0,
		life_min = 0.4,
		life_max = 1.2,
		size_min = 3.0,
		size_max = 6.0,
	}
end

local function spawn_enemy(enemy_type, x, y)
	local def = assert(ENEMY_DEFS[enemy_type], "Unknown enemy type")
	for i = 1, MAX_ENEMIES do
		local enemy = enemies[i]
		if not enemy.active then
			enemy.active = true
			enemy.type = enemy_type
			enemy.x = x
			enemy.y = y
			enemy.angle = 0
			enemy.r = def.radius
			enemy.speed = def.speed
			enemy.hp = def.hp
			enemy.max_hp = def.hp
			enemy.vx = 0
			enemy.vy = 0
			enemy.timer = 0
			if enemy_type == 2 then
				local angle = math.random() * 2.0 * math.pi
				enemy.vx = math.cos(angle) * enemy.speed
				enemy.vy = math.sin(angle) * enemy.speed
				enemy.angle = math.random() * 2.0 * math.pi
			elseif enemy_type == 3 then
				enemy.timer = math.random(0, 599) / 100.0
			elseif enemy_type == 4 then
				enemy.timer = math.random(0, 599) / 100.0
				local angle = math.random() * 2.0 * math.pi
				enemy.vx = math.cos(angle) * enemy.speed
				enemy.vy = math.sin(angle) * enemy.speed
				enemy.angle = angle
			end
			return true
		end
	end
	return false
end

local function spawn_from_edge(enemy_type)
	local margin = 80.0
	for _ = 1, 20 do
		local x
		local y
		local side = math.random(0, 3)
		if side == 0 then
			x = math.random() * MAP_W
			y = -margin
		elseif side == 1 then
			x = math.random() * MAP_W
			y = MAP_H + margin
		elseif side == 2 then
			x = -margin
			y = math.random() * MAP_H
		else
			x = MAP_W + margin
			y = math.random() * MAP_H
		end
		x = clamp(x, -margin, MAP_W + margin)
		y = clamp(y, -margin, MAP_H + margin)
		if distance(x, y, player.x, player.y) > 250.0 then
			return spawn_enemy(enemy_type, x, y)
		end
	end
	return false
end

local function update_enemies(dt)
	for i = 1, MAX_ENEMIES do
		local enemy = enemies[i]
		if enemy.active then
			local player = multiplayer and multiplayer.target(enemy.x, enemy.y) or player
			if enemy.type == 0 then
				local dx = player.x - enemy.x
				local dy = player.y - enemy.y
				local dist = distance(enemy.x, enemy.y, player.x, player.y)
				if dist > 1 then
					enemy.vx = enemy.vx + (dx / dist) * enemy.speed * 2.0 * dt
					enemy.vy = enemy.vy + (dy / dist) * enemy.speed * 2.0 * dt
				end
				local friction = 1.0 - 3.0 * dt
				if friction < 0.7 then
					friction = 0.7
				end
				enemy.vx = enemy.vx * friction
				enemy.vy = enemy.vy * friction
			elseif enemy.type == 1 then
				local dx = player.x - enemy.x
				local dy = player.y - enemy.y
				local dist = distance(enemy.x, enemy.y, player.x, player.y)
				if dist > 1 then
					enemy.vx = enemy.vx + (dx / dist) * enemy.speed * 4.0 * dt
					enemy.vy = enemy.vy + (dy / dist) * enemy.speed * 4.0 * dt
				end
				local max_speed = enemy.speed * 1.2
				local current = math.sqrt(enemy.vx * enemy.vx + enemy.vy * enemy.vy)
				if current > max_speed then
					enemy.vx = enemy.vx / current * max_speed
					enemy.vy = enemy.vy / current * max_speed
				end
				enemy.angle = math.atan(enemy.vy, enemy.vx)
			elseif enemy.type == 2 then
				enemy.angle = enemy.angle - (4.0 * math.pi) * dt
			elseif enemy.type == 3 then
				local dx = player.x - enemy.x
				local dy = player.y - enemy.y
				local dist = distance(enemy.x, enemy.y, player.x, player.y)
				if dist > 1 then
					local target_dist = 180.0
					local radial_force = (dist - target_dist) / dist
					enemy.vx = enemy.vx + (dx / dist) * radial_force * enemy.speed * 2.0 * dt
					enemy.vy = enemy.vy + (dy / dist) * radial_force * enemy.speed * 2.0 * dt
					enemy.timer = enemy.timer + dt
					local tang_angle = math.atan(dy, dx) + math.pi * 0.5
					enemy.vx = enemy.vx + math.cos(tang_angle) * enemy.speed * 3.0 * dt
					enemy.vy = enemy.vy + math.sin(tang_angle) * enemy.speed * 3.0 * dt
				end
				local friction = 1.0 - 3.0 * dt
				if friction < 0.8 then
					friction = 0.8
				end
				enemy.vx = enemy.vx * friction
				enemy.vy = enemy.vy * friction
				enemy.angle = enemy.angle + 2.0 * dt
			elseif enemy.type == 4 then
				enemy.timer = enemy.timer + dt
				local base_angle = enemy.angle
				local weave_offset = math.sin(enemy.timer * 3.0) * 0.8
				local move_angle = base_angle + weave_offset
				enemy.vx = math.cos(move_angle) * enemy.speed
				enemy.vy = math.sin(move_angle) * enemy.speed
			end

			enemy.x = enemy.x + enemy.vx * dt
			enemy.y = enemy.y + enemy.vy * dt
			if powerup.slow_active and distance(enemy.x, enemy.y, player.x, player.y) < 180.0 then
				enemy.x = enemy.x - enemy.vx * dt * 0.7
				enemy.y = enemy.y - enemy.vy * dt * 0.7
			end

			if enemy.type ~= 2 and enemy.type ~= 4 then
				enemy.x = clamp(enemy.x, enemy.r, MAP_W - enemy.r)
				enemy.y = clamp(enemy.y, enemy.r, MAP_H - enemy.r)
			elseif enemy.type == 2 then
				if enemy.x < enemy.r then
					enemy.x = enemy.r
					enemy.vx = -enemy.vx
				end
				if enemy.x > MAP_W - enemy.r then
					enemy.x = MAP_W - enemy.r
					enemy.vx = -enemy.vx
				end
				if enemy.y < enemy.r then
					enemy.y = enemy.r
					enemy.vy = -enemy.vy
				end
				if enemy.y > MAP_H - enemy.r then
					enemy.y = MAP_H - enemy.r
					enemy.vy = -enemy.vy
				end
			else
				if enemy.x < enemy.r then
					enemy.x = enemy.r
					enemy.vx = -enemy.vx
					enemy.angle = math.atan(enemy.vy, enemy.vx)
				end
				if enemy.x > MAP_W - enemy.r then
					enemy.x = MAP_W - enemy.r
					enemy.vx = -enemy.vx
					enemy.angle = math.atan(enemy.vy, enemy.vx)
				end
				if enemy.y < enemy.r then
					enemy.y = enemy.r
					enemy.vy = -enemy.vy
					enemy.angle = math.atan(enemy.vy, enemy.vx)
				end
				if enemy.y > MAP_H - enemy.r then
					enemy.y = MAP_H - enemy.r
					enemy.vy = -enemy.vy
					enemy.angle = math.atan(enemy.vy, enemy.vx)
				end
			end
		end
	end
end

local function handle_player_hit(enemy_type)
	state.killed_by_type = enemy_type
	state.lives = state.lives - 1
	powerup.clear_ability()
	if state.lives <= 0 then
		state.player_alive = false
		if not multiplayer or not multiplayer.other_alive() then
		for i = 1, MAX_ENEMIES do
			enemies[i].active = false
		end
		if enemy_type < 0 then
			for i = 1, 2 do
				powerup.black_holes[i].active = false
			end
		end
		for i = 1, MAX_BULLETS do
			bullets[i].active = false
		end
		end
		spawn_explosion(player.x, player.y, COLOR_WHITE, 80)
		spawn_explosion(player.x, player.y, COLOR_CYAN, 60)
		spawn_explosion(player.x, player.y, argb(255, 255, 200, 100), 40)
		grid_impulse(player.x, player.y, 500, 500)
		shake(10, 25)
	else
		spawn_explosion(player.x, player.y, COLOR_WHITE, 30)
		spawn_explosion(player.x, player.y, COLOR_CYAN, 20)
		grid_impulse(player.x, player.y, 200, 200)
		shake(5, 10)
		play_random_effect(audio.explosion, { volume = 0.25 })
		player.x = MAP_W * 0.5
		player.y = MAP_H * 0.5
		player.angle = 0
		camera.x = player.x - W * 0.5
		camera.y = player.y - H * 0.5
		camera.x = clamp(camera.x, 0, MAP_W - W)
		camera.y = clamp(camera.y, 0, MAP_H - H)
		for i = 1, MAX_ENEMIES do
			local enemy = enemies[i]
			if enemy.active and distance(player.x, player.y, enemy.x, enemy.y) < SPAWN_CLEAR_RADIUS then
				spawn_explosion(enemy.x, enemy.y, enemy_color(enemy.type), 8)
				enemy.active = false
			end
		end
		for i = 1, MAX_BULLETS do
			bullets[i].active = false
		end
		state.respawn_invincible = true
		state.respawn_timer = RESPAWN_INVINCIBLE
	end
end

local function update_collisions()
	if not state.player_alive then
		return
	end

	for i = 1, MAX_BULLETS do
		local bullet = bullets[i]
		if bullet.active then
			for j = 1, MAX_ENEMIES do
				local enemy = enemies[j]
				if enemy.active and distance(bullet.x, bullet.y, enemy.x, enemy.y) < enemy.r + 4 then
					local bullet_angle = math.atan(bullet.vy, bullet.vx)
					local spark_count = 5 + math.random(0, 3)
					emit_particles {
						x = bullet.x,
						y = bullet.y,
						count = spark_count,
						color = argb(255, 255, 255, 200),
						angle = bullet_angle + math.pi,
						spread = BULLET_SPARK_SPREAD,
						speed_min = 150.0,
						speed_max = 400.0,
						life_min = 0.3,
						life_max = 0.7,
						size_min = 3.0,
						size_max = 6.0,
					}

					bullet.active = false
					enemy.hp = enemy.hp - 1
					if enemy.hp <= 0 then
						local points = ENEMY_DEFS[enemy.type].score
						state.combo = state.combo + 1
						state.combo_timer = COMBO_TIMEOUT
						state.combo_bump_timer = 0.3
						if state.combo > state.highest_combo then
							state.highest_combo = state.combo
						end
						local earned = points * state.combo
						state.score = state.score + earned
						state.total_kills = state.total_kills + 1
						spawn_explosion(enemy.x, enemy.y, enemy_color(enemy.type), 25 + enemy.type * 10)
						grid_impulse(enemy.x, enemy.y, 120, 50 + enemy.type * 20)
						shake(1 + enemy.type // 2, 3 + enemy.type)
						play_random_effect(audio.explosion, { volume = 0.25 })
						feedback.spawn_float_text(enemy.x, enemy.y - 10.0, string.format("+%d", earned), COLOR_YELLOW)
						powerup.try_enemy_drop(enemy.type, enemy.x, enemy.y)
						if state.combo >= 5 and not state.combo5_shown then
							state.combo5_shown = true
							feedback.show_popup("x5 COMBO!", COLOR_YELLOW, 3)
							shake(4, 10)
						end
						if state.combo >= 10 and not state.combo10_shown then
							state.combo10_shown = true
							feedback.show_popup("x10 COMBO!", argb(255, 255, 200, 0), 3)
							shake(6, 15)
						end
						if state.total_kills == 50 and not state.kills50_shown then
							state.kills50_shown = true
							feedback.show_popup("50 KILLS!", COLOR_GREEN, 3)
							shake(3, 8)
						end
						if state.total_kills == 100 and not state.kills100_shown then
							state.kills100_shown = true
							feedback.show_popup("100 KILLS!", argb(255, 80, 255, 80), 3)
							shake(5, 12)
						end
						if state.total_kills == 200 and not state.kills200_shown then
							state.kills200_shown = true
							feedback.show_popup("200 KILLS!", argb(255, 160, 60, 220), 3)
							shake(7, 15)
						end
						if enemy.type == 3 then
							shake(7, 30)
							state.screen_shake_frames = 30
							for k = 0, 2 do
								local split_angle = (k * 120.0) * math.pi / 180.0
								spawn_enemy(0, enemy.x + math.cos(split_angle) * 20.0,
									enemy.y + math.sin(split_angle) * 20.0)
							end
						end
						enemy.active = false
					else
						shake(1, 2)
					end
					break
				end
			end
		end
	end

	if powerup.shield_active and state.player_alive then
		for i = 1, MAX_ENEMIES do
			local enemy = enemies[i]
			if enemy.active then
				for d = 0, 2 do
					local dot_angle = powerup.shield_angle + d * (2.0 * math.pi / 3.0)
					local dot_x = player.x + math.cos(dot_angle) * 50.0
					local dot_y = player.y + math.sin(dot_angle) * 50.0
					if distance(dot_x, dot_y, enemy.x, enemy.y) < enemy.r + 8.0 then
						local points = ENEMY_DEFS[enemy.type].score
						state.combo = state.combo + 1
						state.combo_timer = COMBO_TIMEOUT
						state.combo_bump_timer = 0.3
						if state.combo > state.highest_combo then
							state.highest_combo = state.combo
						end
						local earned = points * state.combo
						state.score = state.score + earned
						state.total_kills = state.total_kills + 1
						spawn_explosion(enemy.x, enemy.y, enemy_color(enemy.type), 12)
						grid_impulse(enemy.x, enemy.y, 60, 40)
						play_random_effect(audio.explosion, { volume = 0.25 })
						feedback.spawn_float_text(enemy.x, enemy.y - 10.0, string.format("+%d", earned),
							argb(255, 255, 215, 0))
						enemy.active = false
						if enemy.type == 3 then
							for k = 0, 2 do
								local split_angle = k * 120.0 * math.pi / 180.0
								spawn_enemy(0, dot_x + math.cos(split_angle) * 20.0, dot_y + math.sin(split_angle) * 20.0)
							end
						end
						break
					end
				end
			end
		end
	end

	if not state.respawn_invincible then
		for i = 1, MAX_ENEMIES do
			local enemy = enemies[i]
			if enemy.active and distance(player.x, player.y, enemy.x, enemy.y) < enemy.r + 8 then
				handle_player_hit(enemy.type)
				break
			end
		end
	end

	powerup.try_collect()

	for i = 1, MAX_BULLETS do
		local bullet = bullets[i]
		if bullet.active then
			for j = 1, 2 do
				local bh = powerup.black_holes[j]
				if bh.active and not bh.exploding and distance(bullet.x, bullet.y, bh.x, bh.y) < 30.0 then
					emit_particles {
						x = bullet.x,
						y = bullet.y,
						count = 3,
						color = argb(255, 220, 150, 255),
						angle = math.atan(bh.y - bullet.y, bh.x - bullet.x),
						spread = ATTRACT_SPARK_SPREAD,
						speed_min = 100.0,
						speed_max = 179.0,
						life_min = 0.3,
						size_min = 3.0,
					}
					bh.absorbed = bh.absorbed + 1
					bullet.active = false
					break
				end
			end
		end
	end

	if not state.respawn_invincible and state.player_alive then
		for i = 1, 2 do
			local bh = powerup.black_holes[i]
			if bh.active and not bh.exploding then
				local core_r = 15.0 + bh.absorbed * 2.0
				if core_r > 35.0 then
					core_r = 35.0
				end
				if distance(player.x, player.y, bh.x, bh.y) < core_r + 8.0 then
					handle_player_hit(-1)
					break
				end
			end
		end
	end
end

local function update_timers(dt)
	if state.combo > 1 then
		state.combo_timer = state.combo_timer - dt
		if state.combo_timer <= 0 then
			state.combo = 1
			state.combo_timer = 0
		end
	end
	if state.combo_bump_timer > 0 then
		state.combo_bump_timer = state.combo_bump_timer - dt
		if state.combo_bump_timer < 0 then
			state.combo_bump_timer = 0
		end
	end
	if state.respawn_invincible then
		state.respawn_timer = state.respawn_timer - dt
		if state.respawn_timer <= 0 then
			state.respawn_invincible = false
			state.respawn_timer = 0
		end
	end
end

function feedback.update(dt)
	for i = 1, MAX_FLOAT_TEXTS do
		local float_text = feedback.float_texts[i]
		if float_text.life > 0 then
			float_text.life = float_text.life - dt
			float_text.y = float_text.y + float_text.vy * dt
			if float_text.life < 0 then
				float_text.life = 0
			end
		end
	end
	if feedback.popup.life > 0 then
		feedback.popup.life = feedback.popup.life - dt
		if feedback.popup.life < 0 then
			feedback.popup.life = 0
		end
	end
	for i = 1, MAX_TICKER do
		local msg = feedback.ticker_msgs[i]
		if msg.active then
			msg.timer = msg.timer + dt
			if msg.timer >= msg.life then
				msg.active = false
			end
		end
	end
	if state.shake_frames > 0 then
		local a = state.shake_amt * (state.shake_frames / 20.0)
		state.shake_x = (math.random(-100, 99) / 100.0) * a
		state.shake_y = (math.random(-100, 99) / 100.0) * a
		state.shake_frames = state.shake_frames - 1
	else
		state.shake_amt = 0
		state.shake_x = 0
		state.shake_y = 0
	end
	if state.screen_shake_frames > 0 then
		local t = state.screen_shake_frames / 30.0
		state.screen_shake_y = math.sin(state.screen_shake_frames * 0.7) * 20.0 * t
		state.screen_shake_frames = state.screen_shake_frames - 1
	else
		state.screen_shake_y = 0.0
	end
end

function powerup.spawn(x, y, powerup_type, ability_type)
	for i = 1, MAX_POWERUPS do
		local entry = powerup.entries[i]
		if not entry.active then
			entry.x = x
			entry.y = y
			entry.r = 15.0
			entry.life = 8.0
			entry.pulse = 0.0
			entry.active = true
			entry.type = powerup_type or 0
			entry.ability = ability_type or 0
			return
		end
	end
end

function powerup.describe(powerup_type, ability_type)
	if powerup_type == 0 then
		return NUKE_DEF.name, NUKE_DEF.color, NUKE_DEF.glow, NUKE_DEF.outline
	end
	local def = ABILITY_DEFS[ability_type] or ABILITY_DEFS[0]
	return def.name, def.color, def.glow, def.outline
end

function powerup.clear_ability()
	powerup.energy_active = false
	powerup.energy_timer = 0.0
	powerup.ability_type = 0
	powerup.homing_active = false
	powerup.shield_active = false
	powerup.slow_active = false
	powerup.shield_angle = 0.0
end

function powerup.spawn_black_hole(x, y)
	for i = 1, 2 do
		local bh = powerup.black_holes[i]
		if not bh.active then
			bh.active = true
			bh.x = x
			bh.y = y
			bh.radius = 100.0
			bh.pull_strength = 120.0
			bh.life = 8.0
			bh.absorbed = 0
			bh.pulse = 0.0
			bh.exploding = false
			bh.explode_timer = 0.0
			return true
		end
	end
	return false
end

function powerup.trigger_jack(total)
	powerup.jack_timer = 0.0
	powerup.jack_active = true
	powerup.jack_spawn_timer = 0.0
	powerup.jack_count = 0
	powerup.jack_total = total
end

function powerup.activate_ability(ability_type)
	local def = ABILITY_DEFS[ability_type] or ABILITY_DEFS[0]
	powerup.ability_type = ability_type
	powerup.energy_active = true
	powerup.energy_timer = powerup.energy_duration
	powerup.homing_active = ability_type == 1
	powerup.shield_active = ability_type == 2
	powerup.slow_active = ability_type == 3
	powerup.shield_angle = 0.0
	play_effect(audio.rise[ability_type + 1])
	feedback.show_popup(def.popup, def.color, 3)
	shake(3, 8)
end

function powerup.try_enemy_drop(enemy_type, x, y)
	local base_drop = ({ 7, 10, 12, 17, 10 })[enemy_type + 1]
	local active_enemies = 0
	for i = 1, MAX_ENEMIES do
		if enemies[i].active then
			active_enemies = active_enemies + 1
		end
	end
	local drop_scale = 1.0
	if active_enemies > 15 then
		drop_scale = drop_scale - (active_enemies - 15) / 50.0
		if drop_scale < 0.3 then
			drop_scale = 0.3
		end
	end
	local drop_pct = math.floor(base_drop * drop_scale)
	if drop_pct > 0 and math.random(0, 99) < drop_pct then
		powerup.spawn(x, y, 1, math.random(0, 3))
	end
end

function powerup.trigger_nuke()
	feedback.show_popup("NUKE ACTIVATED!", COLOR_CYAN, 3)
	shake(8, 20)
	grid_impulse(player.x, player.y, 600, 400)
	powerup.nuke_flash_alpha = 1.0
	powerup.nuke_wave_radius = 0.0
	powerup.nuke_wave_alpha = 1.0
	powerup.nuke_fx_active = true

	for i = 1, MAX_ENEMIES do
		local enemy = enemies[i]
		if enemy.active then
			local earned = ENEMY_DEFS[enemy.type].score
			state.score = state.score + earned
			state.total_kills = state.total_kills + 1
			spawn_explosion(enemy.x, enemy.y, enemy_color(enemy.type), 20 + enemy.type * 8)
			feedback.spawn_float_text(enemy.x, enemy.y - 10.0, string.format("+%d", earned), COLOR_WHITE)
			enemy.active = false
		end
	end
	spawn_explosion(player.x, player.y, argb(255, 255, 255, 200), 50)
end

function powerup.update(dt)
	for i = 1, MAX_POWERUPS do
		local entry = powerup.entries[i]
		if entry.active then
			entry.life = entry.life - dt
			entry.pulse = entry.pulse + dt * 5.0
			if entry.life <= 0 then
				entry.active = false
			end
		end
	end
	if powerup.energy_active then
		powerup.energy_timer = powerup.energy_timer - dt
		if powerup.energy_timer <= 0 then
			powerup.clear_ability()
		end
	end
	if powerup.shield_active then
		powerup.shield_angle = powerup.shield_angle + 4.0 * math.pi * dt
	end
	if powerup.nuke_fx_active then
		powerup.nuke_flash_alpha = powerup.nuke_flash_alpha - dt * 2.0
		if powerup.nuke_flash_alpha < 0 then
			powerup.nuke_flash_alpha = 0
		end
		powerup.nuke_wave_radius = powerup.nuke_wave_radius + dt * 1200.0
		powerup.nuke_wave_alpha = powerup.nuke_wave_alpha - dt * 2.5
		if powerup.nuke_wave_alpha < 0 then
			powerup.nuke_wave_alpha = 0
		end
		if powerup.nuke_flash_alpha <= 0 and powerup.nuke_wave_alpha <= 0 then
			powerup.nuke_fx_active = false
			powerup.nuke_wave_radius = 0.0
		end
	end
end

function powerup.update_events(dt)
	for i = 1, 2 do
		local bh = powerup.black_holes[i]
		if bh.active then
			if bh.exploding then
				bh.explode_timer = bh.explode_timer + dt
				if bh.explode_timer >= 0.5 then
					bh.active = false
				end
			else
				bh.pulse = bh.pulse + dt * 3.0
				bh.life = bh.life - dt
				bh.radius = 100.0 + bh.absorbed * 8.0
				if bh.radius > 180.0 then
					bh.radius = 180.0
				end
				for j = 1, MAX_ENEMIES do
					local enemy = enemies[j]
					if enemy.active then
						local dx = bh.x - enemy.x
						local dy = bh.y - enemy.y
						local dist = distance(enemy.x, enemy.y, bh.x, bh.y)
						if dist < bh.radius and dist > 1.0 then
							enemy.vx = enemy.vx + (dx / dist) * bh.pull_strength * dt
							enemy.vy = enemy.vy + (dy / dist) * bh.pull_strength * dt
						end
						if dist < 20.0 then
							bh.absorbed = bh.absorbed + 1
							local points = ENEMY_DEFS[enemy.type].score
							local earned = points * state.combo
							state.score = state.score + earned
							state.combo = state.combo + 1
							state.combo_timer = COMBO_TIMEOUT
							state.combo_bump_timer = 0.3
							if state.combo > state.highest_combo then
								state.highest_combo = state.combo
							end
							spawn_explosion(enemy.x, enemy.y, enemy_color(enemy.type), 8)
							feedback.spawn_float_text(enemy.x, enemy.y - 10.0, string.format("+%d", earned), COLOR_WHITE)
							enemy.active = false
						end
					end
				end
				if bh.absorbed >= 10 then
					bh.exploding = true
					bh.explode_timer = 0.0
					shake(5, 12)
					spawn_explosion(bh.x, bh.y, argb(255, 160, 60, 220), 30)
					feedback.ticker_add(powerup.bh_phrases[math.random(1, #powerup.bh_phrases)], argb(255, 200, 60, 80))
					grid_impulse(bh.x, bh.y, 300, 200)
					for k = 0, 7 do
						local angle = k * 45.0 * math.pi / 180.0
						spawn_enemy(0, bh.x + math.cos(angle) * 20.0, bh.y + math.sin(angle) * 20.0)
					end
				elseif bh.life <= 0 then
					spawn_explosion(bh.x, bh.y, argb(255, 100, 50, 150), 10)
					bh.active = false
				end
			end
		end
	end
end

function powerup.try_collect()
	if not state.player_alive then
		return
	end
	for i = 1, MAX_POWERUPS do
		local entry = powerup.entries[i]
		if entry.active and distance(player.x, player.y, entry.x, entry.y) < entry.r + 12.0 then
			if entry.type == 0 then
				powerup.trigger_nuke()
				play_effect(audio.powerup)
			elseif entry.type == 1 then
				powerup.activate_ability(entry.ability)
			end
			entry.active = false
		end
	end
end

function powerup.maybe_spawn(dt)
	powerup.spawn_timer = powerup.spawn_timer + dt
	if powerup.spawn_timer >= 14.0 + math.random(0, 79) / 10.0 then
		powerup.spawn_timer = 0.0
		local px = math.random() * MAP_W
		local py = math.random() * MAP_H
		if distance(px, py, player.x, player.y) > 200.0 then
			powerup.spawn(px, py, 0, 0)
		end
	end
end

function powerup.draw()
	for i = 1, MAX_POWERUPS do
		local entry = powerup.entries[i]
		if entry.active then
			local pr = clamp(math.floor(entry.r * (math.sin(entry.pulse) * 0.2 + 1.0)), 12, 18)
			local label_text, core, glow = powerup.describe(entry.type, entry.ability)
			local beacon_phase1 = (entry.pulse * 0.8) % 2.0
			local beacon_phase2 = (entry.pulse * 0.8 + 1.0) % 2.0

			if beacon_phase1 < 1.5 then
				local expand = beacon_phase1 / 1.5
				local ring_r = entry.r + expand * 30.0
				local ring_color = particle_alpha(core, 120.0 * (1.0 - expand))
				draw_masked_ring(ring_color, ring_r, entry.x, entry.y, 2.0, 0.5, 1.25)
			end
			if beacon_phase2 < 1.5 then
				local expand = beacon_phase2 / 1.5
				local ring_r = entry.r + expand * 30.0
				local ring_color = particle_alpha(core, 120.0 * (1.0 - expand))
				draw_masked_ring(ring_color, ring_r, entry.x, entry.y, 2.0, 0.5, 1.25)
			end

			draw_masked_circle(glow, pr * 2.0, entry.x, entry.y)
			batch:add(masked[sprites["powerup_shape_" .. pr]][core], entry.x, entry.y)
			feedback.draw_shadowed_text(
				entry.x - (#label_text * 3),
				entry.y - pr - 10.0,
				label_text,
				8,
				particle_alpha(core, 180.0),
				"LT",
				#label_text * 8,
				10,
				argb(80, 255, 255, 255)
			)

			if entry.life < 3.0 and math.floor(entry.pulse * 2.0) % 2 == 0 then
				draw_masked_circle(argb(40, 255, 255, 255), pr * 2.0, entry.x, entry.y)
			end
		end
	end
end

function powerup.draw_black_holes()
	for i = 1, 2 do
		local bh = powerup.black_holes[i]
		if bh.active then
			if bh.exploding then
				local expand_progress = bh.explode_timer / 0.5
				local wave_r = expand_progress * 400.0
				local wave_alpha = 200.0 * (1.0 - expand_progress)
				if wave_r > 0.01 then
					draw_masked_ring(particle_alpha(argb(255, 160, 60, 220), wave_alpha), wave_r, bh.x, bh.y, 3.0, 1.0,
						2.0)
				end
				if wave_r > 0.02 then
					draw_masked_ring(particle_alpha(argb(255, 220, 150, 255), wave_alpha * 0.5), wave_r * 0.5, bh.x, bh
						.y, 2.0, 0.75, 1.5)
				end
			else
				local pulse_scale = math.sin(bh.pulse) * 0.1 + 1.0
				local ring_r = bh.radius * pulse_scale
				local core_r = 15.0 + bh.absorbed * 2.0
				if core_r > 35.0 then
					core_r = 35.0
				end
				draw_masked_ring(argb(40, 160, 60, 220), ring_r, bh.x, bh.y, 2.0, 0.75, 1.5)
				draw_masked_circle(argb(80, 160, 60, 220), core_r + 5.0, bh.x, bh.y)
				batch:layer(core_r / 16.0, bh.x, bh.y)
				batch:add(sprites.black_hole)
				batch:layer()
				local dot_alpha = 100.0 + bh.absorbed * 15.0
				if dot_alpha > 255.0 then
					dot_alpha = 255.0
				end
				draw_masked_circle(argb(quantize_byte(dot_alpha, 16), 220, 150, 255), 3.0, bh.x, bh.y)
			end
		end
	end
end

function powerup.draw_world_fx()
	if powerup.nuke_fx_active and powerup.nuke_wave_alpha > 0 then
		local outer = particle_alpha(COLOR_CYAN, powerup.nuke_wave_alpha * 200.0)
		local inner = argb(quantize_byte(powerup.nuke_wave_alpha * 100.0, 16), 200, 255, 255)
		if powerup.nuke_wave_radius > 0.01 then
			draw_masked_ring(outer, powerup.nuke_wave_radius, player.x, player.y, 3.0, 1.0, 2.0)
		end
		if powerup.nuke_wave_radius > 0.02 then
			draw_masked_ring(inner, powerup.nuke_wave_radius * 0.85, player.x, player.y, 2.0, 0.75, 1.5)
		end
	end
end

function powerup.draw_screen_fx()
	if powerup.nuke_fx_active and powerup.nuke_flash_alpha > 0 then
		batch:add(quad {
			width = W,
			height = H,
			color = argb(quantize_byte(powerup.nuke_flash_alpha * 220.0, 16), 255, 255, 255),
		}, 0, 0)
	end
end

local function update_spawner(dt)
	if state.scene ~= "combat" or not state.player_alive then
		return
	end
	state.game_time = state.game_time + dt
	powerup.jack_timer = powerup.jack_timer + dt
	local jack_cooldown = 45.0 - state.game_time * 0.01
	if jack_cooldown < 30.0 then
		jack_cooldown = 30.0
	end
	if not powerup.jack_active and powerup.jack_timer >= jack_cooldown then
		powerup.jack_timer = 0.0
		powerup.jack_active = true
		powerup.jack_spawn_timer = 0.0
		powerup.jack_count = 0
		powerup.jack_total = 20 + math.floor(state.game_time / 30.0)
		if powerup.jack_total > 40 then
			powerup.jack_total = 40
		end
		feedback.show_popup("JACK INVASION!", argb(255, 255, 220, 50), 3)
		shake(5, 10)
	end
	if powerup.jack_active then
		powerup.jack_spawn_timer = powerup.jack_spawn_timer + dt
		if powerup.jack_spawn_timer >= 0.05 and powerup.jack_count < powerup.jack_total then
			powerup.jack_spawn_timer = 0.0
			local side = math.random(0, 3)
			local margin = 80.0
			local x
			local y
			if side == 0 then
				x = math.random() * MAP_W
				y = -margin
			elseif side == 1 then
				x = math.random() * MAP_W
				y = MAP_H + margin
			elseif side == 2 then
				x = -margin
				y = math.random() * MAP_H
			else
				x = MAP_W + margin
				y = math.random() * MAP_H
			end
			if spawn_enemy(0, x, y) then
				powerup.jack_count = powerup.jack_count + 1
			end
		end
		if powerup.jack_count >= powerup.jack_total then
			powerup.jack_active = false
		end
		if powerup.jack_active then
			return
		end
	end
	local spawn_interval = 0.35 - state.game_time * 0.001
	if spawn_interval < 0.10 then
		spawn_interval = 0.10
	end
	local max_on_screen = 15 + math.floor(state.game_time / 10.0)
	if max_on_screen > 60 then
		max_on_screen = 60
	end
	local active_count = 0
	for i = 1, MAX_ENEMIES do
		if enemies[i].active then
			active_count = active_count + 1
		end
	end
	state.spawn_timer = state.spawn_timer + dt
	if state.spawn_timer >= spawn_interval and active_count < max_on_screen then
		state.spawn_timer = 0
		local enemy_type
		if state.game_time <= 15.0 then
			enemy_type = 0
		elseif state.game_time <= 30.0 then
			enemy_type = (math.random(0, 2) == 0) and 2 or 0
		elseif state.game_time <= 60.0 then
			local roll = math.random(0, 9)
			if roll < 5 then
				enemy_type = 0
			elseif roll < 8 then
				enemy_type = 1
			else
				enemy_type = 2
			end
		elseif state.game_time <= 90.0 then
			local roll = math.random(0, 9)
			if roll < 4 then
				enemy_type = 0
			elseif roll < 6 then
				enemy_type = 1
			elseif roll < 8 then
				enemy_type = 2
			else
				enemy_type = 4
			end
		else
			local roll = math.random(0, 9)
			if roll < 3 then
				enemy_type = 0
			elseif roll < 5 then
				enemy_type = 1
			elseif roll < 7 then
				enemy_type = 2
			elseif roll < 8 then
				enemy_type = 3
			else
				enemy_type = 4
			end
		end
		if spawn_from_edge(enemy_type) and state.game_time > 3.0 and enemy_type ~= 0 then
			play_random_effect(audio.spawn)
		end
	end

	powerup.maybe_spawn(dt)
	powerup.bh_spawn_timer = powerup.bh_spawn_timer + dt
	local bh_cooldown = 60.0 + math.random(0, 29)
	local active_bh = 0
	for i = 1, 2 do
		if powerup.black_holes[i].active then
			active_bh = active_bh + 1
		end
	end
	if powerup.bh_spawn_timer >= bh_cooldown and active_bh < 2 and state.game_time > 60.0 then
		powerup.bh_spawn_timer = 0.0
		for _ = 1, 20 do
			local x = 80.0 + math.random() * (MAP_W - 160.0)
			local y = 80.0 + math.random() * (MAP_H - 160.0)
			if distance(x, y, player.x, player.y) > 250.0 and powerup.spawn_black_hole(x, y) then
				break
			end
		end
	end
end

local function init_starfield()
	for i = 1, MAX_STARS_FAR do
		stars_far[i] = {
			x = math.random() * MAP_W,
			y = math.random() * MAP_H,
			size = math.random(1, 2),
			speed = math.random(5, 9),
			color = random_star_color(30, 59),
		}
	end

	for i = 1, MAX_STARS_NEAR do
		stars_near[i] = {
			x = math.random() * MAP_W,
			y = math.random() * MAP_H,
			size = math.random(2, 3),
			speed = math.random(15, 24),
			color = random_star_color(60, 99),
		}
	end
end

local function init_grid()
	for row = 0, GRID_ROWS - 1 do
		local nodes = {}
		grid[row + 1] = nodes
		for col = 0, GRID_COLS - 1 do
			local x = col * GRID_SPACING
			local y = row * GRID_SPACING
			nodes[col + 1] = {
				x = x,
				y = y,
				vx = x,
				vy = y,
			}
		end
	end
end

grid_impulse = function(cx, cy, radius, strength)
	if multiplayer then multiplayer.record("grid", { cx, cy, radius, strength }) end
	for row = 1, GRID_ROWS do
		local nodes = grid[row]
		for col = 1, GRID_COLS do
			local node = nodes[col]
			local dx = node.x - cx
			local dy = node.y - cy
			local dist_sq = dx * dx + dy * dy
			if dist_sq > 0.01 and dist_sq < radius * radius then
				local dist = math.sqrt(dist_sq)
				local force = strength * (1.0 - dist / radius)
				node.vx = node.vx + dx / dist * force
				node.vy = node.vy + dy / dist * force
			end
		end
	end
end

local function update_grid(dt)
	for row = 0, GRID_ROWS - 1 do
		local nodes = grid[row + 1]
		for col = 0, GRID_COLS - 1 do
			local node = nodes[col + 1]
			local fx = col * GRID_SPACING
			local fy = row * GRID_SPACING
			node.vx = node.vx + (fx - node.x) * 12.0 * dt
			node.vy = node.vy + (fy - node.y) * 12.0 * dt
			local damping = 1.0 - 5.0 * dt
			if damping < 0.85 then
				damping = 0.85
			end
			node.vx = node.vx * damping
			node.vy = node.vy * damping
			node.x = node.x + node.vx * dt * 60.0
			node.y = node.y + node.vy * dt * 60.0
		end
	end
end

local pools_initialized = false

local function ensure_runtime_pools()
	if pools_initialized then
		return
	end

	for i = 1, MAX_BULLETS do
		bullets[i] = { active = false, homing = false }
	end
	for i = 1, MAX_ENEMIES do
		enemies[i] = { active = false, type = 0 }
	end
	for i = 1, MAX_FLOAT_TEXTS do
		feedback.float_texts[i] = { life = 0, max_life = 0, text = "", color = COLOR_WHITE }
	end
	for i = 1, MAX_TICKER do
		feedback.ticker_msgs[i] = { text = "", color = COLOR_WHITE, life = 0.0, timer = 0.0, active = false }
	end
	for i = 1, 2 do
		powerup.black_holes[i] = {
			active = false,
			x = 0.0,
			y = 0.0,
			radius = 100.0,
			pull_strength = 120.0,
			life = 0.0,
			absorbed = 0,
			pulse = 0.0,
			exploding = false,
			explode_timer = 0.0,
		}
	end
	for i = 1, MAX_POWERUPS do
		powerup.entries[i] = {
			x = 0.0,
			y = 0.0,
			r = 15.0,
			life = 0.0,
			pulse = 0.0,
			active = false,
			type = 0,
			ability = 0,
		}
	end

	pools_initialized = true
end

local function clear_runtime_state()
	state.scene_time = 0.0
	state.game_time = 0.0
	state.score = 0
	state.combo = 1
	state.highest_combo = 1
	state.total_kills = 0
	state.combo_timer = 0.0
	state.combo_bump_timer = 0.0
	state.lives = MAX_LIVES
	state.player_alive = true
	state.respawn_invincible = false
	state.respawn_timer = 0.0
	state.killed_by_type = -1
	state.shake_amt = 0.0
	state.shake_frames = 0
	state.shake_x = 0.0
	state.shake_y = 0.0
	state.screen_shake_y = 0.0
	state.screen_shake_frames = 0
	state.combo5_shown = false
	state.combo10_shown = false
	state.kills50_shown = false
	state.kills100_shown = false
	state.kills200_shown = false
	state.lb_highlight = -1
	state.spawn_timer = 0.0
	state.shoot_timer = 0.0
	state.trail_timer = 0.0
	state.trail_count = 0
	state.thrust_particle_timer = 0.0

	input.mouse_left = false
	input.mouse_pressed = false
	input.mouse_released = false
	input.ui_active_button = false

	player.x = MAP_W * 0.5
	player.y = MAP_H * 0.5
	player.angle = 0
	camera.x = clamp(player.x - W * 0.5, 0, MAP_W - W)
	camera.y = clamp(player.y - H * 0.5, 0, MAP_H - H)

	for i = 1, MAX_BULLETS do
		local bullet = bullets[i]
		bullet.active = false
		bullet.homing = false
	end
	for i = 1, MAX_ENEMIES do
		local enemy = enemies[i]
		enemy.active = false
		enemy.type = 0
	end
	clear_particles()
	for i = 1, MAX_FLOAT_TEXTS do
		local float_text = feedback.float_texts[i]
		float_text.life = 0
		float_text.max_life = 0
		float_text.text = ""
	end
	for i = 1, MAX_TICKER do
		local msg = feedback.ticker_msgs[i]
		msg.text = ""
		msg.life = 0.0
		msg.timer = 0.0
		msg.active = false
	end

	feedback.popup.text = ""
	feedback.popup.color = COLOR_WHITE
	feedback.popup.life = 0.0
	feedback.popup.max_life = 0.0
	feedback.popup.scale = 1

	powerup.spawn_timer = 0.0
	powerup.jack_timer = 0.0
	powerup.jack_active = false
	powerup.jack_spawn_timer = 0.0
	powerup.jack_count = 0
	powerup.jack_total = 0
	powerup.bh_spawn_timer = 0.0
	powerup.nuke_flash_alpha = 0.0
	powerup.nuke_wave_radius = 0.0
	powerup.nuke_wave_alpha = 0.0
	powerup.nuke_fx_active = false
	powerup.clear_ability()

	for i = 1, 2 do
		local bh = powerup.black_holes[i]
		bh.active = false
		bh.life = 0.0
		bh.absorbed = 0
		bh.pulse = 0.0
		bh.exploding = false
		bh.explode_timer = 0.0
	end
	for i = 1, MAX_POWERUPS do
		local entry = powerup.entries[i]
		entry.life = 0.0
		entry.pulse = 0.0
		entry.active = false
		entry.type = 0
		entry.ability = 0
	end
end

local function update_star_layer(stars, dt)
	for i = 1, #stars do
		local star = stars[i]
		star.y = star.y + star.speed * dt
		if star.y > MAP_H then
			star.y = 0
			star.x = math.random() * MAP_W
		end
	end
end

local function update_shooting(dt)
	if state.scene ~= "combat" or not state.player_alive then
		return
	end
	state.shoot_timer = state.shoot_timer + dt
	local rate = powerup.energy_active and powerup.energy_shoot_rate or SHOOT_RATE
	if input.mouse_left and state.shoot_timer >= rate then
		state.shoot_timer = 0
		if powerup.energy_active and powerup.ability_type == 0 then
			for _, angle_offset in ipairs { -15.0, -7.0, 0.0, 7.0, 15.0 } do
				spawn_bullet(player.angle + angle_offset * math.pi / 180.0, powerup.homing_active)
			end
		else
			spawn_bullet(player.angle, powerup.homing_active)
		end
		play_random_effect(audio.shoot, { volume = 0.25 })
	end
end

local function update_bullets(dt)
	for i = 1, MAX_BULLETS do
		local bullet = bullets[i]
		if bullet.active then
			if bullet.homing then
				local best_dist = 999999.0
				local nearest_x = 0.0
				local nearest_y = 0.0
				for j = 1, MAX_ENEMIES do
					local enemy = enemies[j]
					if enemy.active then
						local dist = distance(bullet.x, bullet.y, enemy.x, enemy.y)
						if dist < best_dist then
							best_dist = dist
							nearest_x = enemy.x
							nearest_y = enemy.y
						end
					end
				end
				if best_dist < 500.0 then
					local bullet_angle = math.atan(bullet.vy, bullet.vx)
					local target_angle = math.atan(nearest_y - bullet.y, nearest_x - bullet.x)
					local diff = target_angle - bullet_angle
					while diff > math.pi do
						diff = diff - math.pi * 2.0
					end
					while diff < -math.pi do
						diff = diff + math.pi * 2.0
					end
					local steer = 3.0 * math.pi / 180.0 * dt * 60.0
					if diff > 0 then
						bullet_angle = bullet_angle + steer
					elseif diff < 0 then
						bullet_angle = bullet_angle - steer
					end
					bullet.vx = math.cos(bullet_angle) * BULLET_SPEED
					bullet.vy = math.sin(bullet_angle) * BULLET_SPEED
				end
			end
			bullet.x = bullet.x + bullet.vx * dt
			bullet.y = bullet.y + bullet.vy * dt
			if bullet.x < -20 or bullet.x > MAP_W + 20 or bullet.y < -20 or bullet.y > MAP_H + 20 then
				bullet.active = false
			end
		end
	end
end

local function world_scale()
	local scale = math.min(window_w / W, window_h / H)
	if scale <= 0 then
		return 1, 0, 0
	end
	local offset_x = (window_w - W * scale) * 0.5
	local offset_y = (window_h - H * scale) * 0.5
	return scale, offset_x, offset_y
end

local function sync_particle_service_frame(dt)
	local scale, offset_x, offset_y = world_scale()
	ltask.send(particle, "frame", {
		dt = dt,
		visible = state.scene == "combat" or state.scene == "death" or state.scene == "over",
		view = {
			scale = scale,
			offset_x = offset_x,
			offset_y = offset_y,
		},
		camera = {
			x = camera.x,
			y = camera.y,
		},
		shake = {
			x = state.shake_x,
			y = state.shake_y,
			screen_y = state.screen_shake_y,
		},
	})
end

local function update_mouse_world()
	local scale, offset_x, offset_y = world_scale()
	local vx = (mouse_screen_x - offset_x) / scale
	local vy = (mouse_screen_y - offset_y) / scale
	mouse_world_x = vx + camera.x
	mouse_world_y = vy + camera.y
end

local function record_trail()
	if state.trail_count < TRAIL_LEN then
		state.trail_count = state.trail_count + 1
	end
	for i = state.trail_count, 2, -1 do
		trail_x[i] = trail_x[i - 1]
		trail_y[i] = trail_y[i - 1]
		trail_a[i] = trail_a[i - 1]
	end
	trail_x[1] = player.x
	trail_y[1] = player.y
	trail_a[1] = player.angle
end

local function update_player(dt)
	---@type number
	local dx = 0
	---@type number
	local dy = 0
	if input.left then
		dx = dx - 1
	end
	if input.right then
		dx = dx + 1
	end
	if input.up then
		dy = dy - 1
	end
	if input.down then
		dy = dy + 1
	end

	local len_sq = dx * dx + dy * dy
	local is_moving = len_sq > 0
	if len_sq > 0 then
		local inv_len = 1.0 / math.sqrt(len_sq)
		dx = dx * inv_len
		dy = dy * inv_len
		player.x = player.x + dx * PLAYER_SPEED * dt
		player.y = player.y + dy * PLAYER_SPEED * dt
	end
	player.x = clamp(player.x, 20, MAP_W - 20)
	player.y = clamp(player.y, 20, MAP_H - 20)
	for i = 1, 2 do
		local bh = powerup.black_holes[i]
		if bh.active and not bh.exploding then
			local x = bh.x - player.x
			local y = bh.y - player.y
			local dist = distance(player.x, player.y, bh.x, bh.y)
			if dist < bh.radius and dist > 1.0 then
				player.x = player.x + (x / dist) * bh.pull_strength * 0.3 * dt
				player.y = player.y + (y / dist) * bh.pull_strength * 0.3 * dt
				player.x = clamp(player.x, 20, MAP_W - 20)
				player.y = clamp(player.y, 20, MAP_H - 20)
			end
		end
	end

	local aim_dx = mouse_world_x - player.x
	local aim_dy = mouse_world_y - player.y
	if aim_dx * aim_dx + aim_dy * aim_dy > 25 then
		player.angle = math.atan(aim_dy, aim_dx)
	end

	state.trail_timer = state.trail_timer + dt
	while state.trail_timer >= TRAIL_INTERVAL do
		state.trail_timer = state.trail_timer - TRAIL_INTERVAL
		record_trail()
	end

	state.thrust_particle_timer = state.thrust_particle_timer + dt
	if is_moving and not state.respawn_invincible and state.thrust_particle_timer >= 0.06 then
		state.thrust_particle_timer = 0
		local rear_x = player.x - math.cos(player.angle) * 14.0
		local rear_y = player.y - math.sin(player.angle) * 14.0
		emit_particles {
			x = rear_x,
			y = rear_y,
			count = 1,
			angle = player.angle + math.pi,
			spread = THRUST_SPREAD,
			color_range = powerup.energy_active and THRUST_ENERGY_COLOR_RANGE or THRUST_NORMAL_COLOR_RANGE,
			speed_min = 350.0,
			speed_max = 599.0,
			life_min = 0.35,
			life_max = 0.55,
			size_min = 2.0,
			size_max = 3.0,
		}
	end
end

local function update_camera(dt)
	local target_x = clamp(player.x - W * 0.5, 0, MAP_W - W)
	local target_y = clamp(player.y - H * 0.5, 0, MAP_H - H)
	local factor = 1.0 - (1.0 - CAMERA_LERP) ^ (dt * 60.0)
	camera.x = camera.x + (target_x - camera.x) * factor
	camera.y = camera.y + (target_y - camera.y) * factor
end

local function draw_grid_segment(ax, ay, bx, by, color)
	local dx = bx - ax
	local dy = by - ay
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.5 then
		return
	end
	local angle = math.atan(dy, dx)
	local width = math.max(1, math.floor(len + 0.5))
	batch:layer(1, angle, ax, ay)
	batch:add(quad { width = width, height = 1, color = color }, 0, -0.5)
	batch:layer()
end

local function draw_grid()
	local first_col = math.max(0, math.floor(camera.x / GRID_SPACING) - 1)
	local last_col = math.min(GRID_COLS - 1, math.floor((camera.x + W) / GRID_SPACING) + 1)
	local first_row = math.max(0, math.floor(camera.y / GRID_SPACING) - 1)
	local last_row = math.min(GRID_ROWS - 1, math.floor((camera.y + H) / GRID_SPACING) + 1)

	for row = first_row, last_row do
		for col = first_col, last_col do
			local node = grid[row + 1][col + 1]

			if col + 1 <= last_col and col + 1 < GRID_COLS then
				local right = grid[row + 1][col + 2]
				draw_grid_segment(node.x, node.y, right.x, right.y, COLOR_GRID)
			end

			if row + 1 <= last_row and row + 1 < GRID_ROWS then
				local down = grid[row + 2][col + 1]
				draw_grid_segment(node.x, node.y, down.x, down.y, COLOR_GRID)
			end
		end
	end
end

local function draw_world_border()
	batch:add(quad { width = MAP_W, height = 3, color = COLOR_BORDER }, 0, 0)
	batch:add(quad { width = MAP_W, height = 3, color = COLOR_BORDER }, 0, MAP_H - 3)
	batch:add(quad { width = 3, height = MAP_H, color = COLOR_BORDER }, 0, 0)
	batch:add(quad { width = 3, height = MAP_H, color = COLOR_BORDER }, MAP_W - 3, 0)
end

local function draw_stars(stars)
	for i = 1, #stars do
		local star = stars[i]
		if star.x >= camera.x - 8 and star.x <= camera.x + W + 8
			and star.y >= camera.y - 8 and star.y <= camera.y + H + 8 then
			draw_masked_circle(star.color, star.size, star.x, star.y)
		end
	end
end

local function draw_player_trail()
	for i = state.trail_count, 2, -1 do
		local alpha_factor = 1.0 - (i - 1) / TRAIL_LEN
		local scale = 0.7 + alpha_factor * 0.3
		local color = particle_alpha(PLAYER_TRAIL, alpha_factor * 100.0)
		batch:layer(scale, trail_a[i], trail_x[i], trail_y[i])
		batch:add(masked[sprites.player_core_mask][color])
		batch:layer()
	end
end

local function draw_bullets()
	for i = 1, MAX_BULLETS do
		local bullet = bullets[i]
		if bullet.active then
			local core = bullet.homing and BULLET_HOMING_CORE or BULLET_CORE
			local glow = bullet.homing and BULLET_HOMING_GLOW or BULLET_GLOW
			draw_masked_circle(core, 3, bullet.x, bullet.y)
			draw_masked_circle(glow, 6, bullet.x, bullet.y)
			draw_masked_circle(glow, 2, bullet.x - bullet.vx * 0.008, bullet.y - bullet.vy * 0.008)
		end
	end
end

local function draw_enemies()
	for i = 1, MAX_ENEMIES do
		local enemy = enemies[i]
		if enemy.active then
			local def = ENEMY_DEFS[enemy.type]
			local color = def.color
			local glow = particle_alpha(color, 60)
			if def.draw_rotated then
				batch:layer(1, enemy.angle, enemy.x, enemy.y)
				batch:add(masked[sprites[def.shape_sprite]][color])
				batch:layer()
			else
				batch:add(masked[sprites[def.shape_sprite]][color], enemy.x, enemy.y)
			end
			draw_masked_circle(glow, enemy.r * def.glow_scale, enemy.x, enemy.y)
			if def.core_color then
				draw_masked_circle(def.core_color, enemy.r * def.core_scale, enemy.x, enemy.y)
			end
		end
	end
end

local function add_text(x, y, text, size, color, align, width, height)
	bitmapfont.draw_text(batch, masked, sprites.font_glyphs, x, y, text, size, color, align, width, height)
end

function feedback.draw_shadowed_text(x, y, text, size, color, align, width, height, shadow_color)
	add_text(x + 1, y + 1, text, size, shadow_color or argb(100, 255, 255, 255), align, width, height)
	add_text(x, y, text, size, color, align, width, height)
end

function feedback.screen_mouse()
	local scale, offset_x, offset_y = world_scale()
	return (mouse_screen_x - offset_x) / scale, (mouse_screen_y - offset_y) / scale
end

function feedback.button(x, y, width, height, text, color)
	if width <= 0 or height <= 0 then
		return false
	end

	local mx, my = feedback.screen_mouse()
	local hovered = mx >= x and mx <= x + width and my >= y and my <= y + height
	local id = string.format("%d:%d:%d:%d:%s", x, y, width, height, text)
	if input.mouse_pressed and hovered then
		input.ui_active_button = id
	end

	local pressed = input.ui_active_button == id and input.mouse_left and hovered
	local face = color
	if pressed then
		face = feedback.ui_darken_rgb(color, 36)
	elseif hovered then
		face = feedback.ui_lighten_rgb(color, 46)
	end

	feedback.draw_bevel_rect(x, y, width, height, face, pressed)

	local text_color = feedback.ui_button_text_color(face)
	local shadow_color
	if text_color == COLOR_WHITE then
		shadow_color = argb(160, 0, 0, 0)
	else
		shadow_color = argb(112, 255, 255, 255)
	end

	local text_x = x
	local text_y = y
	if pressed then
		text_x = text_x + 1
		text_y = text_y + 1
	end

	add_text(text_x + 1, text_y + 1, text, 8, shadow_color, "CV", width, height)
	add_text(text_x, text_y, text, 8, text_color, "CV", width, height)

	local clicked = input.mouse_released and hovered and input.ui_active_button == id
	if input.mouse_released and input.ui_active_button == id then
		input.ui_active_button = false
	end
	return clicked
end

function feedback.draw_float_texts()
	for i = 1, MAX_FLOAT_TEXTS do
		local float_text = feedback.float_texts[i]
		if float_text.life > 0 then
			local elapsed = float_text.max_life - float_text.life
			local hold_time = 0.5
			local fade_time = float_text.max_life - hold_time
			local alpha = 1.0
			if elapsed >= hold_time then
				alpha = 1.0 - (elapsed - hold_time) / fade_time
				if alpha < 0 then
					alpha = 0
				end
			end
			local width = #float_text.text * 10 + 8
			feedback.draw_shadowed_text(
				float_text.x,
				float_text.y,
				float_text.text,
				10,
				particle_alpha(float_text.color, alpha * 255.0),
				"LT",
				width,
				12,
				argb(quantize_byte(alpha * 100.0, 16), 255, 255, 255)
			)
		end
	end
end

local function draw_centered_text(text, y, size, color)
	add_text(0, y, text, size, color, "CV", W, size)
end

function feedback.draw_popup()
	if feedback.popup.life <= 0 then
		return
	end
	local elapsed = feedback.popup.max_life - feedback.popup.life
	local current_scale
	if elapsed < POPUP_GROW_TIME then
		current_scale = 1 + math.floor((elapsed / POPUP_GROW_TIME) * (feedback.popup.scale - 1))
		if current_scale < 1 then
			current_scale = 1
		end
	else
		current_scale = feedback.popup.scale
	end
	local draw_color = feedback.popup.color
	if feedback.popup.life < POPUP_FADE_TIME then
		draw_color = particle_alpha(feedback.popup.color, feedback.popup.life / POPUP_FADE_TIME * 255.0)
	end
	local size = 8 * current_scale
	feedback.draw_shadowed_text(0, H * 0.5 - 20, feedback.popup.text, size, draw_color, "CV", W, size + 8,
		argb(100, 255, 255, 255))
end

function feedback.draw_ticker()
	local slide_in_dur = 0.4
	local slide_out_dur = 0.5
	local y_offset = 35
	for i = 1, MAX_TICKER do
		local msg = feedback.ticker_msgs[i]
		if msg.active then
			local tw = #msg.text * 8
			local y = y_offset + (i - 1) * 15
			local x
			if msg.timer < slide_in_dur then
				local progress = msg.timer / slide_in_dur
				x = W + 10 - progress * (W + 10 + tw + 20)
			elseif msg.timer < msg.life - slide_out_dur then
				x = 20
			else
				local progress = (msg.timer - (msg.life - slide_out_dur)) / slide_out_dur
				x = 20 - progress * (tw + 20)
			end
			local draw_color
			if msg.timer >= msg.life - slide_out_dur then
				local alpha = 1.0 - (msg.timer - (msg.life - slide_out_dur)) / slide_out_dur
				draw_color = particle_alpha(msg.color, alpha * 200.0)
			else
				draw_color = particle_alpha(msg.color, 200.0)
			end
			feedback.draw_shadowed_text(x, y, msg.text, 8, draw_color, "LT", tw + 8, 12, argb(100, 255, 255, 255))
		end
	end
end

local function draw_hud()
	add_text(10, 10, string.format("SCORE: %d", state.score), 8, COLOR_WHITE, "LT", 220, 8)
	add_text(W * 0.5 - 80, 8, string.format("BEST: %d", state.best_score), 8, COLOR_GOLD, "LT", 160, 8)
	local minutes = math.floor(state.game_time / 60)
	local seconds = math.floor(state.game_time) % 60
	add_text(W - 100, 10, string.format("TIME %d:%02d", minutes, seconds), 8, COLOR_SKY_BLUE, "LT", 100, 8)
	add_text(10, H - 20, string.format("LIVES: %d", state.lives), 8, COLOR_WHITE, "LT", 120, 8)
	add_text(W - 60, H - 20, string.format("%.0f FPS", fps), 8, COLOR_WHITE, "LT", 60, 8)
	if state.combo > 1 then
		local base_size = 16 + (state.combo - 2) * 2
		if base_size > 32 then
			base_size = 32
		end
		local draw_size = base_size
		if state.combo_bump_timer > 0 then
			local bump_progress = state.combo_bump_timer / 0.3
			local overshoot
			if bump_progress > 0.7 then
				local phase1 = (bump_progress - 0.7) / 0.3
				overshoot = phase1 * (base_size * 0.25)
			else
				local phase2 = bump_progress / 0.7
				overshoot = phase2 * (base_size * 0.25)
			end
			draw_size = base_size + math.floor(overshoot)
		end
		local digits = state.combo < 10 and 1 or (state.combo < 100 and 2 or 3)
		local width = draw_size + digits * draw_size
		add_text(W - width - 10, 30, string.format("x%d", state.combo), draw_size, COLOR_YELLOW, "LT", width,
			draw_size + 8)
	end
	if powerup.energy_active then
		local ability = ABILITY_DEFS[powerup.ability_type] or ABILITY_DEFS[0]
		local bar_color = ability.color
		local bar_outline = ability.outline
		local ability_name = ability.name
		local bar_w = 80
		local bar_h = 6
		local bar_x = W * 0.5 - bar_w * 0.5
		local bar_y = 50
		local ratio = powerup.energy_timer / powerup.energy_duration
		batch:add(quad {
			width = math.floor(bar_w * ratio + 0.5),
			height = bar_h,
			color = particle_alpha(bar_color, 200.0),
		}, bar_x, bar_y)
		batch:add(quad { width = bar_w, height = 1, color = bar_outline }, bar_x, bar_y)
		batch:add(quad { width = bar_w, height = 1, color = bar_outline }, bar_x, bar_y + bar_h - 1)
		batch:add(quad { width = 1, height = bar_h, color = bar_outline }, bar_x, bar_y)
		batch:add(quad { width = 1, height = bar_h, color = bar_outline }, bar_x + bar_w - 1, bar_y)
		feedback.draw_shadowed_text(W * 0.5 - #ability_name * 4, bar_y - 12, ability_name, 8, bar_color, "LT",
			#ability_name * 8, 10, argb(80, 255, 255, 255))
	end
end

local function draw_player()
	if state.respawn_invincible and math.floor(state.total_time * 8) % 2 == 0 then
		return
	end
	draw_player_trail()
	draw_masked_circle(PLAYER_GLOW, 20, player.x, player.y)
	if powerup.energy_active then
		draw_masked_circle(argb(80, 255, 180, 60), 25, player.x, player.y)
	end
	batch:layer(1, player.angle, player.x, player.y)
	batch:add(masked[sprites.player_outline_mask][PLAYER_OUTLINE])
	batch:layer()
	batch:layer(1, player.angle, player.x, player.y)
	batch:add(masked[sprites.player_core_mask][PLAYER_CORE])
	batch:layer()
	draw_masked_circle(
		ENGINE_GLOW,
		4,
		player.x - math.cos(player.angle) * 12.0,
		player.y - math.sin(player.angle) * 12.0
	)
	if powerup.shield_active then
		draw_masked_ring(argb(100, 255, 215, 0), 50.0, player.x, player.y, 2.0, 0.75, 1.0)
		for d = 0, 2 do
			local dot_angle = powerup.shield_angle + d * (2.0 * math.pi / 3.0)
			local dot_x = player.x + math.cos(dot_angle) * 50.0
			local dot_y = player.y + math.sin(dot_angle) * 50.0
			draw_masked_circle(argb(255, 255, 215, 0), 8, dot_x, dot_y)
			draw_masked_circle(argb(80, 255, 215, 0), 12, dot_x, dot_y)
		end
	end
	if powerup.slow_active then
		local slow_pulse = math.sin(state.total_time * 3.0) * 0.1 + 1.0
		local slow_r = 180.0 * slow_pulse
		draw_masked_ring(argb(60, 80, 180, 255), slow_r, player.x, player.y, 2.5, 1.0, 2.0)
		draw_masked_ring(argb(30, 120, 220, 255), slow_r - 5.0, player.x, player.y, 1.5, 0.75, 1.5)
	end
end

local function draw_backdrop(include_border)
	batch:add(quad { width = MAP_W, height = MAP_H, color = COLOR_BLACK }, 0, 0)
	draw_stars(stars_far)
	draw_stars(stars_near)
	draw_grid()
	if include_border then
		draw_world_border()
	end
end

local function draw_world()
	draw_backdrop(true)
	draw_bullets()
	powerup.draw_black_holes()
	draw_enemies()
	if state.player_alive then
		if state.player_alive then draw_player() end
	if multiplayer then multiplayer.draw_partner() end
	end
	powerup.draw()
	feedback.draw_float_texts()
end

local function draw_game_over()
	draw_centered_text("GAME OVER", H // 2 - 70, 24, feedback.menu_colors.red)
	draw_centered_text(string.format("FINAL SCORE: %d", state.score), H // 2 - 10, 8, COLOR_WHITE)
	local minutes = math.floor(state.game_time / 60)
	local seconds = math.floor(state.game_time) % 60
	draw_centered_text(string.format("SURVIVED: %d:%02d", minutes, seconds), H // 2 + 15, 8, COLOR_WHITE)
	draw_centered_text(string.format("TOTAL KILLS: %d", state.total_kills), H // 2 + 40, 8, COLOR_WHITE)
	draw_centered_text(string.format("MAX COMBO: x%d", state.highest_combo), H // 2 + 65, 8, COLOR_YELLOW)
	if state.killed_by_type >= 0 then
		local def = assert(ENEMY_DEFS[state.killed_by_type])
		local kill_text = "KILLED BY: " .. def.name
		local kill_color = def.color
		draw_centered_text(kill_text, H // 2 + 90, 8, kill_color)
		local icon_x = W * 0.5 - #kill_text * 4 - 20
		local icon_y = H // 2 + 93
		batch:layer(def.icon_scale, icon_x, icon_y)
		batch:add(masked[sprites[def.shape_sprite]][kill_color])
		batch:layer()
	end
	if state.scene_time > 2.0 then
		if feedback.button(W * 0.5 - 80, H // 2 + 115, 160, 30, "CONTINUE", feedback.menu_colors.red) then
			input.emit_ui_action "confirm"
		end
	end
end

function feedback.draw_title_scene()
	local pulse = math.sin(state.total_time * 2.0) * 0.3 + 0.7
	local title_color = argb(math.floor(pulse * 255.0), 0, 255, 255)
	draw_centered_text("GEOMETRY WARS", 200, 24, title_color)
	if feedback.button(W * 0.5 - 70, 260, 140, 30, "START", COLOR_CYAN) then
		input.emit_ui_action "confirm"
	end
	draw_centered_text("WASD Move  |  Mouse Aim + Shoot", 310, 8, feedback.menu_colors.dark_gray)
	draw_centered_text("L Leaderboard  |  Enter Start", 330, 8, feedback.menu_colors.dark_gray)
	add_text(
		W * 0.5 - 130,
		H - 50,
		string.format("BEST: %d  |  TIME %d:%02d", state.best_score, math.floor(state.best_time / 60),
			math.floor(state.best_time) % 60),
		8,
		feedback.menu_colors.dark_gray,
		"LT",
		260,
		8
	)
	draw_centered_text("Powered by Soluna", H - 25, 8, argb(100, 100, 100, 100))
end

function feedback.draw_leaderboard_scene()
	draw_centered_text("LEADERBOARD", 30, 24, COLOR_CYAN)
	add_text(60, 80, "RANK", 8, feedback.menu_colors.light_gray, "LT", 60, 8)
	add_text(120, 80, "SCORE", 8, feedback.menu_colors.light_gray, "LT", 80, 8)
	add_text(260, 80, "KILLS", 8, feedback.menu_colors.light_gray, "LT", 80, 8)
	add_text(380, 80, "TIME", 8, feedback.menu_colors.light_gray, "LT", 80, 8)
	local y = 105
	for i = 1, 10 do
		local row = state.leaderboard[i]
		if row.score > 0 then
			local row_color = i == state.lb_highlight and COLOR_GOLD or COLOR_WHITE
			add_text(60, y, string.format("#%d", i), 8, row_color, "LT", 40, 12)
			add_text(120, y, string.format("%d", row.score), 8, row_color, "LT", 120, 12)
			add_text(260, y, string.format("%d", row.kills), 8, row_color, "LT", 80, 12)
			add_text(380, y, string.format("%d:%02d", math.floor(row.time / 60), math.floor(row.time) % 60), 8, row_color,
				"LT", 80, 12)
			y = y + 22
		end
	end
	if state.scene_time > 1.0 then
		if feedback.button(W * 0.5 - 80, H - 45, 160, 30, "CONTINUE", COLOR_CYAN) then
			input.emit_ui_action "confirm"
		end
	end
end

-- Multiplayer integration keeps the original player, weapons, enemy AI and effects.
local other_health
local partner = { player = {}, health = {}, input = {}, tx = {}, ty = {}, ta = {} }
local correction_x, correction_y = 0, 0
local host_target
local have_snapshot = false
local health_keys = { "lives", "player_alive", "killed_by_type", "respawn_invincible", "respawn_timer", "shoot_timer", "trail_timer", "trail_count", "thrust_particle_timer" }
local function copy_health(out)
    for _, k in ipairs(health_keys) do out[k] = state[k] end
end
local function with_partner(fn)
    local old_player, old_input, old_x, old_y = player, input, mouse_world_x, mouse_world_y
    local old_tx, old_ty, old_ta = trail_x, trail_y, trail_a
    local old_cx, old_cy, old_health = camera.x, camera.y, {}
    copy_health(old_health)
    player, input = partner.player, partner.input
    trail_x, trail_y, trail_a = partner.tx, partner.ty, partner.ta
    mouse_world_x, mouse_world_y = input.mx or player.x + 50, input.my or player.y
    for _, k in ipairs(health_keys) do state[k] = partner.health[k] end
    other_health = old_health
    fn()
    other_health = nil
    copy_health(partner.health)
    player, input, mouse_world_x, mouse_world_y = old_player, old_input, old_x, old_y
    trail_x, trail_y, trail_a = old_tx, old_ty, old_ta
    camera.x, camera.y = old_cx, old_cy
    for _, k in ipairs(health_keys) do state[k] = old_health[k] end
end
local function merge(dst, src)
    for k,v in pairs(src) do
        if type(v)=="table" then dst[k]=dst[k] or {};merge(dst[k],v) else dst[k]=v end
    end
end
local function active_pool(pool)
    local out={}
    for i,v in ipairs(pool) do if v.active then out[i]=v end end
    return out
end
local function apply_pool(pool, data)
    for _,v in ipairs(pool) do v.active=false end
    for i,v in pairs(data) do merge(pool[i],v) end
end
local online = require "online"
multiplayer = online.new {
    endpoint = soluna.settings().server or "ws://127.0.0.1:8788/ws",
    text = add_text,
    button = feedback.button,
    pointer = function()
        local scale,ox,oy=world_scale()
        return (mouse_screen_x-ox)/scale,(mouse_screen_y-oy)/scale,input.mouse_pressed
    end,
    reset_partner = function()
        correction_x, correction_y, host_target = 0, 0, nil
        have_snapshot = false
        partner.player = { x=MAP_W*.5+55,y=MAP_H*.5,angle=0 }
        partner.health = { lives=MAX_LIVES,player_alive=true,killed_by_type=-1,respawn_invincible=true,respawn_timer=RESPAWN_INVINCIBLE,shoot_timer=0,trail_timer=0,trail_count=0,thrust_particle_timer=0 }
        partner.input = { key_pressed={},ui_actions={},mouse_left=false,mx=partner.player.x+50,my=partner.player.y }
        partner.tx,partner.ty,partner.ta={},{},{}
    end,
    remote_input = function(data)
        for _,k in ipairs {"left","right","up","down","mouse_left"} do partner.input[k]=data[k]==true end
        if type(data.mx)=="number" and type(data.my)=="number" then partner.input.mx,partner.input.my=data.mx,data.my end
    end,
    local_input = function()
        return {left=input.left,right=input.right,up=input.up,down=input.down,mouse_left=input.mouse_left,mx=mouse_world_x,my=mouse_world_y}
    end,
    snapshot = function()
        local host_health={};copy_health(host_health)
        return { state=state,host_player=player,host_health=host_health,host_tx=trail_x,host_ty=trail_y,host_ta=trail_a,
            guest=partner,enemies=active_pool(enemies),bullets=active_pool(bullets),powerup=powerup,feedback=feedback }
    end,
    apply = function(data)
        local old_x,old_y,old_angle,was_alive = player.x,player.y,player.angle,state.player_alive
        local local_timers={shoot_timer=state.shoot_timer,trail_timer=state.trail_timer,trail_count=state.trail_count,thrust_particle_timer=state.thrust_particle_timer}
        merge(state,data.state)
        merge(player,data.guest.player)
        for _,k in ipairs(health_keys) do state[k]=data.guest.health[k] end
        -- Input advances locally each frame. Ordinary server corrections are
        -- spread over a few frames; respawns and large corrections snap.
        if have_snapshot and was_alive and state.player_alive and distance(old_x,old_y,player.x,player.y)<150 then
            correction_x,correction_y=player.x-old_x,player.y-old_y
            player.x,player.y,player.angle=old_x,old_y,old_angle
            for k,v in pairs(local_timers) do state[k]=v end
        else
            correction_x,correction_y=0,0
            trail_x,trail_y,trail_a=data.guest.tx,data.guest.ty,data.guest.ta
        end
        if host_target then
            host_target={x=data.host_player.x,y=data.host_player.y,angle=data.host_player.angle,left=1/15}
        else
            partner.player=data.host_player
            host_target={x=data.host_player.x,y=data.host_player.y,angle=data.host_player.angle,left=0}
        end
        partner.health=data.host_health
        have_snapshot = true
        partner.tx,partner.ty,partner.ta=data.host_tx,data.host_ty,data.host_ta
        apply_pool(enemies,data.enemies);apply_pool(bullets,data.bullets)
        merge(powerup,data.powerup);merge(feedback,data.feedback)
        for _,e in ipairs(data.events or {}) do
            if e[3]=="guest-motion" or e[3]=="guest-shot" then
                -- Already produced by the guest's local prediction.
            elseif e[1]=="emit" then ltask.send(particle,"emit",e[2])
            elseif e[1]=="grid" then grid_impulse(table.unpack(e[2]))
            elseif e[1]=="sound" then play_effect(e[2][1],e[2][2]) end
        end
    end,
}
function multiplayer.other_alive()
    if other_health then return multiplayer.started and other_health.player_alive==true end
    return multiplayer.started and partner.health.player_alive==true
end
function multiplayer.target(x,y)
    if multiplayer.other_alive() and (not state.player_alive or distance(x,y,partner.player.x,partner.player.y)<distance(x,y,player.x,player.y)) then return partner.player end
    return player
end
function multiplayer.update_partner(dt)
    if not multiplayer.other_alive() then return end
    with_partner(function()
        multiplayer.effect_source="guest-motion"
        update_player(dt)
        multiplayer.effect_source="guest-shot"
        update_shooting(dt)
        multiplayer.effect_source=nil
        if state.respawn_invincible then
            state.respawn_timer=math.max(0,state.respawn_timer-dt)
            state.respawn_invincible=state.respawn_timer>0
        end
    end)
end
function multiplayer.predict(dt)
    if state.player_alive then
        update_player(dt)
        local factor=1-math.exp(-12*dt)
        local dx,dy=correction_x*factor,correction_y*factor
        player.x,player.y=clamp(player.x+dx,20,MAP_W-20),clamp(player.y+dy,20,MAP_H-20)
        correction_x,correction_y=correction_x-dx,correction_y-dy
        update_shooting(dt)
    end
    if host_target and host_target.left>0 then
        local factor=math.min(1,dt/host_target.left)
        partner.player.x=partner.player.x+(host_target.x-partner.player.x)*factor
        partner.player.y=partner.player.y+(host_target.y-partner.player.y)*factor
        local angle=(host_target.angle-partner.player.angle+math.pi)%(2*math.pi)-math.pi
        partner.player.angle=partner.player.angle+angle*factor
        host_target.left=math.max(0,host_target.left-dt)
    end
    -- Reuse the original movement and effects between authoritative snapshots.
    -- Collisions, drops, score, deaths and spawning remain host decisions.
    update_bullets(dt)
    update_enemies(dt)
    update_timers(dt)
    powerup.update(dt)
    feedback.update(dt)
end
function multiplayer.collide_partner()
    if multiplayer.other_alive() then with_partner(update_collisions) end
end
function multiplayer.draw_partner()
    if multiplayer.other_alive() then with_partner(draw_player) end
end

do
	local function update_combat_scene(dt)
		update_star_layer(stars_far, dt)
		update_star_layer(stars_near, dt)
		update_mouse_world()
		if not multiplayer.host then
			multiplayer.predict(dt)
			update_camera(dt)
			update_grid(dt)
			return
		end
		if state.player_alive then update_player(dt); update_shooting(dt) end
		multiplayer.update_partner(dt)
		update_bullets(dt)
		update_enemies(dt)
		update_collisions()
		multiplayer.collide_partner()
		powerup.update_events(dt)
		update_grid(dt)
		update_timers(dt)
		powerup.update(dt)
		feedback.update(dt)
		update_spawner(dt)
		update_camera(dt)
	end

	local function update_title_scene(dt)
		state.center_camera()
		update_grid(dt)
	end

	local function update_death_scene(dt)
		update_star_layer(stars_far, dt)
		update_star_layer(stars_near, dt)
		update_grid(dt)
		update_timers(dt)
		powerup.update(dt)
		feedback.update(dt)
		if not audio.death_sound_played and state.scene_time >= 0.5 and state.scene_time < 1.0 then
			audio.death_sound_played = true
			play_effect(audio.death)
		end
	end

	local function update_game_over_scene(dt)
		update_star_layer(stars_far, dt)
		update_star_layer(stars_near, dt)
		update_grid(dt)
		update_timers(dt)
		powerup.update(dt)
		feedback.update(dt)
	end

	local function update_leaderboard_scene(dt)
		update_star_layer(stars_far, dt)
		update_star_layer(stars_near, dt)
		state.center_camera()
		update_grid(dt)
	end

	local function draw_loading_overlay()
		local ratio = 0.0
		if asset_progress.total > 0 then
			ratio = clamp(asset_progress.done / asset_progress.total, 0.0, 1.0)
		end

		local bar_w = 360
		local bar_h = 10
		local bar_x = (W - bar_w) // 2
		local bar_y = H // 2 + 48
		local fill_w = math.floor((bar_w - 4) * ratio + 0.5)
		local pulse = math.floor((math.sin(state.total_time * 4.0) * 0.5 + 0.5) * 80 + 80)
		local percent = math.floor(ratio * 100.0 + 0.5)
		local current = asset_progress.current
		if current == "" then
			current = "initializing"
		end

		batch:add(quad { width = W, height = H, color = COLOR_BLACK }, 0, 0)
		batch:add(quad { width = 220, height = 2, color = argb(pulse, 0, 255, 255) }, W // 2 - 110, H // 2 - 22)
		batch:add(quad { width = 160, height = 2, color = argb(120, 255, 255, 255) }, W // 2 - 80, H // 2 - 8)
		bitmapfont.draw_text(batch, masked, loading_sprites.font_glyphs, 0, H // 2 - 82, "GEOMETRY WARS", 16, COLOR_CYAN,
			"CV", W, 20)
		bitmapfont.draw_text(batch, masked, loading_sprites.font_glyphs, 0, H // 2 + 12, "LOADING SPRITES", 8,
			COLOR_WHITE, "CV", W, 10)
		bitmapfont.draw_text(batch, masked, loading_sprites.font_glyphs, 0, H // 2 + 26,
			string.format("%3d%%  %s", percent, current), 8, argb(180, 180, 220, 255), "CV", W, 10)

		batch:add(quad { width = bar_w, height = bar_h, color = argb(120, 20, 40, 60) }, bar_x, bar_y)
		if fill_w > 0 then
			batch:add(quad { width = fill_w, height = bar_h - 4, color = argb(220, 0, 255, 255) }, bar_x + 2, bar_y + 2)
		end
		batch:add(quad { width = bar_w, height = 1, color = COLOR_CYAN }, bar_x, bar_y)
		batch:add(quad { width = bar_w, height = 1, color = COLOR_CYAN }, bar_x, bar_y + bar_h - 1)
		batch:add(quad { width = 1, height = bar_h, color = COLOR_CYAN }, bar_x, bar_y)
		batch:add(quad { width = 1, height = bar_h, color = COLOR_CYAN }, bar_x + bar_w - 1, bar_y)
	end

	local function draw_title_world()
		draw_backdrop(false)
	end

	local function draw_combat_overlay()
		feedback.draw_popup()
		feedback.draw_ticker()
		draw_hud()
		batch:layer(-camera.x + state.shake_x, -camera.y + state.shake_y)
		powerup.draw_world_fx()
		batch:layer()
		powerup.draw_screen_fx()
	end

	local function draw_death_world()
		draw_backdrop(true)
	end

	local function draw_death_overlay()
		if state.scene_time < 0.5 then
			local alpha = clamp((0.5 - state.scene_time) * 400.0, 0, 255)
			batch:add(quad { width = W, height = H, color = argb(math.floor(alpha + 0.5), 255, 255, 255) }, 0, 0)
		end
	end

	local function draw_game_over_world()
		draw_backdrop(false)
	end

	local function draw_game_over_overlay()
		feedback.draw_popup()
		feedback.draw_ticker()
		draw_game_over()
	end

	local function confirm_requested()
		return input.consume_ui_action "confirm"
			or input.consume_key_press(KEY.ENTER)
			or input.consume_key_press(KEY.SPACE)
	end

	local function handle_combat_debug_keys()
		if input.consume_key_press(KEY.DEBUG_NUKE) then
			powerup.trigger_nuke()
			return
		end
		if input.consume_key_press(KEY.DEBUG_JACK) then
			powerup.trigger_jack(25)
			feedback.ticker_add(powerup.jack_phrases[math.random(1, #powerup.jack_phrases)], argb(255, 255, 80, 60))
			shake(5, 10)
			return
		end
		if input.consume_key_press(KEY.DEBUG_BLACK_HOLE) then
			powerup.spawn_black_hole(player.x + 200.0, player.y)
		end
	end

	local function reset()
		ensure_runtime_pools()
		clear_runtime_state()
		multiplayer.reset_partner()
		init_starfield()
		init_grid()
		return "combat"
	end

	local game = {}

	game.reset = reset

	function game.loading()
		state.set_scene_hooks(nil, draw_loading_overlay)
		start_sprite_loading()
		while true do
			if asset_progress.error then
				error(asset_progress.error)
			end
			if asset_progress.ready then
				state.load_records()
				reset()
				return "online"
			end
			flow.sleep(0)
		end
	end

	function game.online()
        state.center_camera()
		state.set_scene_hooks(draw_title_world, multiplayer.draw)
		while true do
			if multiplayer.started then return "reset" end
            update_title_scene(state.frame_dt)
			flow.sleep(0)
		end
	end

	function game.title()
		state.set_scene_hooks(draw_title_world, feedback.draw_title_scene)
		while true do
			if confirm_requested() then
				return "reset"
			end
			if input.consume_key_press(KEY.LEADERBOARD) then
				state.lb_highlight = -1
				return "leaderboard"
			end
			update_title_scene(state.frame_dt)
			flow.sleep(0)
		end
	end

	function game.combat()
		state.set_scene_hooks(draw_world, draw_combat_overlay)
		while true do
			if not multiplayer.started then return "online" end
			handle_combat_debug_keys()
			update_combat_scene(state.frame_dt)
			if not state.player_alive and state.lives <= 0 and not multiplayer.other_alive() then
				return "death"
			end
			flow.sleep(0)
		end
	end

	function game.death()
		state.set_scene_hooks(draw_death_world, draw_death_overlay)
		while true do
            if not multiplayer.started then return "online" end
			update_death_scene(state.frame_dt)
			if state.scene_time > 1.5 then
				state.lb_highlight = state.insert_leaderboard(state.score, state.game_time, state.total_kills,
					state.highest_combo)
				if state.score > state.best_score then
					state.best_score = state.score
				end
				if state.game_time > state.best_time then
					state.best_time = state.game_time
				end
				state.save_records()
				return "over"
			end
			flow.sleep(0)
		end
	end

	function game.over()
		state.set_scene_hooks(draw_game_over_world, draw_game_over_overlay)
		while true do
            if not multiplayer.started then return "online" end
			if state.scene_time > 2.0 and confirm_requested() then
                multiplayer.finish()
				return "online"
			end
			update_game_over_scene(state.frame_dt)
			flow.sleep(0)
		end
	end

	function game.leaderboard()
		state.set_scene_hooks(draw_title_world, feedback.draw_leaderboard_scene)
		while true do
			if state.scene_time > 1.0 and confirm_requested() then
				return "title"
			end
			update_leaderboard_scene(state.frame_dt)
			flow.sleep(0)
		end
	end

	flow.load(game)
	flow.enter "loading"
end

local callback = {}

function callback.frame()
	if init then
		init()
	end

	local _, now = ltask.now()
	local dt = 1.0 / 60.0
	if last_tick ~= nil then
		dt = clamp((now - last_tick) / 100.0, 1.0 / 240.0, 0.05)
	end
	last_tick = now
	if fps_clock == nil then
		fps_clock = now
	end
	fps_frames = fps_frames + 1
	local fps_elapsed = (now - fps_clock) / 100.0
	if fps_elapsed >= 0.25 then
		fps = fps_frames / fps_elapsed
		fps_frames = 0
		fps_clock = now
	end
	state.total_time = state.total_time + dt
	state.scene_time = state.scene_time + dt
	state.frame_dt = dt
	multiplayer.poll(now / 100)
	local current_scene = flow.update()
	if current_scene ~= nil then
		state.sync_scene(current_scene)
	end
	multiplayer.publish(now / 100)
	sync_particle_service_frame(dt)

	view.begin(batch)
	batch:add(quad { width = W, height = H, color = COLOR_BLACK }, 0, 0)

	batch:layer(0, state.screen_shake_y)
	batch:layer(-camera.x + state.shake_x, -camera.y + state.shake_y)
	if state.scene_draw_world then
		state.scene_draw_world()
	end
	batch:layer()
	if state.scene_draw_overlay then
		state.scene_draw_overlay()
	end
	batch:layer()

	view.finish(batch)
	input.mouse_pressed = false
	input.mouse_released = false
	input.clear_key_presses()
end

function callback.mouse_move(x, y)
	mouse_screen_x = x
	mouse_screen_y = y
end

function callback.mouse_button(button, key_state)
	if button == 0 then
		input.mouse_left = key_state == KEY.PRESS
		if key_state == KEY.PRESS then
			input.mouse_pressed = true
		elseif key_state == KEY.RELEASE then
			input.mouse_released = true
		end
	end
end

function callback.key(keycode, key_state)
	local pressed = key_state == KEY.PRESS
	if pressed and keycode == KEY.ESCAPE then
		app.quit()
		return
	end
	if pressed then
		input.key_pressed[keycode] = true
	end

	if keycode == KEY.LEFT or keycode == KEY.A then
		input.left = pressed
	elseif keycode == KEY.RIGHT or keycode == KEY.D then
		input.right = pressed
	elseif keycode == KEY.UP or keycode == KEY.W then
		input.up = pressed
	elseif keycode == KEY.DOWN or keycode == KEY.S then
		input.down = pressed
	end
end

function callback.window_resize(w, h)
	window_w = w
	window_h = h
	view.resize(w, h)
end

return callback
