local util = {}

local DEFAULT_FONT_CANDIDATES = {
	"Arial",
	"Helvetica",
	"Microsoft YaHei",
	"Yuanti SC",
	"WenQuanYi Micro Hei",
}

function util.cache(f)
	local meta
	if type(f) == "function" then
		meta = {}
		---@param self table
		---@param k any
		meta.__index = function(self, k)
			local v = f(k)
			self[k] = v
			return v
		end
	else
		meta = getmetatable(f)
	end

	return setmetatable({}, meta)
end

function util.font_init(soluna, font, file, options)
	options = options or {}

	local bundled_path = options.bundled_path or "asset/font/arial.ttf"
	local bundled_name = options.bundled_name or "Arial"
	local candidates = options.candidates or DEFAULT_FONT_CANDIDATES
	local error_message = options.error_message or "No available font"

	if soluna.platform == "wasm" then
		local bundled_data = file.load(bundled_path)
		if bundled_data then
			font.import(bundled_data)
			local bundled_id = font.name(bundled_name)
			if bundled_id then
				return bundled_id
			end
		end
	end

	local sysfont = require "soluna.font.system"
	for _, name in ipairs(candidates) do
		local ok, data = pcall(sysfont.ttfdata, name)
		if ok and data then
			font.import(data)
			local fontid = font.name(name)
			if fontid then
				return fontid
			end
		end
	end

	error(error_message)
end

function util.label_cache()
	local cache = util.cache(function(block)
		return util.cache(function(text)
			return util.cache(function(width)
				return util.cache(function(height)
					return block(text, width, height)
				end)
			end)
		end)
	end)

	return function(args)
		return cache[args.block][args.text][args.width][args.height]
	end
end

function util.quad_cache(matquad)
	local cache = util.cache(function(width)
		return util.cache(function(height)
			return util.cache(function(color)
				return matquad.quad(width, height, color)
			end)
		end)
	end)

	return function(args)
		return cache[args.width][args.height][args.color]
	end
end

function util.fixed_view(args, base_width, base_height)
	local width = args.width or base_width
	local height = args.height or base_height
	local scale = 1
	local offset_x = 0
	local offset_y = 0

	local function recalc()
		if width <= 0 or height <= 0 then
			scale = 1
			offset_x = 0
			offset_y = 0
			return
		end

		scale = math.min(width / base_width, height / base_height)
		if scale <= 0 then
			scale = 1
		end

		offset_x = (width - base_width * scale) * 0.5
		offset_y = (height - base_height * scale) * 0.5
	end

	recalc()

	return {
		begin = function(batch)
			batch:layer(scale, offset_x, offset_y)
		end,
		finish = function(batch)
			batch:layer()
		end,
		resize = function(w, h)
			width = w
			height = h
			args.width = w
			args.height = h
			recalc()
		end,
	}
end

return util
