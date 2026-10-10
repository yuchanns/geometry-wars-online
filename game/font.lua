local font = {}

local ASCII_FIRST = 32
local ASCII_LAST = 126
local GLYPH_SIZE = 8
local SPACE_CODEPOINT = 32
local COLOR_WHITE = 0xffffffff
local GAMELIB_FONT8X8 = [[
00 00 00 00 00 00 00 00
18 3C 3C 18 18 00 18 00
6C 6C 24 00 00 00 00 00
6C 6C FE 6C FE 6C 6C 00
18 7E C0 7C 06 FC 18 00
00 C6 CC 18 30 66 C6 00
38 6C 38 76 DC CC 76 00
18 18 30 00 00 00 00 00
0C 18 30 30 30 18 0C 00
30 18 0C 0C 0C 18 30 00
00 66 3C FF 3C 66 00 00
00 18 18 7E 18 18 00 00
00 00 00 00 00 18 18 30
00 00 00 7E 00 00 00 00
00 00 00 00 00 18 18 00
06 0C 18 30 60 C0 80 00
7C CE DE F6 E6 C6 7C 00
18 38 78 18 18 18 7E 00
7C C6 06 1C 70 C6 FE 00
7C C6 06 3C 06 C6 7C 00
1C 3C 6C CC FE 0C 1E 00
FE C0 FC 06 06 C6 7C 00
38 60 C0 FC C6 C6 7C 00
FE C6 0C 18 30 30 30 00
7C C6 C6 7C C6 C6 7C 00
7C C6 C6 7E 06 0C 78 00
00 18 18 00 00 18 18 00
00 18 18 00 00 18 18 30
0C 18 30 60 30 18 0C 00
00 00 7E 00 7E 00 00 00
60 30 18 0C 18 30 60 00
7C C6 0C 18 18 00 18 00
7C C6 DE DE DC C0 7C 00
38 6C C6 C6 FE C6 C6 00
FC C6 C6 FC C6 C6 FC 00
7C C6 C0 C0 C0 C6 7C 00
F8 CC C6 C6 C6 CC F8 00
FE C0 C0 FC C0 C0 FE 00
FE C0 C0 FC C0 C0 C0 00
7C C6 C0 CE C6 C6 7E 00
C6 C6 C6 FE C6 C6 C6 00
3C 18 18 18 18 18 3C 00
1E 0C 0C 0C CC CC 78 00
C6 CC D8 F0 D8 CC C6 00
C0 C0 C0 C0 C0 C0 FE 00
C6 EE FE D6 C6 C6 C6 00
C6 E6 F6 DE CE C6 C6 00
7C C6 C6 C6 C6 C6 7C 00
FC C6 C6 FC C0 C0 C0 00
7C C6 C6 C6 D6 DE 7C 06
FC C6 C6 FC D8 CC C6 00
7C C6 C0 7C 06 C6 7C 00
7E 18 18 18 18 18 18 00
C6 C6 C6 C6 C6 C6 7C 00
C6 C6 C6 C6 6C 38 10 00
C6 C6 C6 D6 FE EE C6 00
C6 C6 6C 38 6C C6 C6 00
66 66 66 3C 18 18 18 00
FE 06 0C 18 30 60 FE 00
3C 30 30 30 30 30 3C 00
C0 60 30 18 0C 06 02 00
3C 0C 0C 0C 0C 0C 3C 00
10 38 6C C6 00 00 00 00
00 00 00 00 00 00 00 FE
30 18 0C 00 00 00 00 00
00 00 78 0C 7C CC 76 00
C0 C0 FC C6 C6 C6 FC 00
00 00 7C C6 C0 C6 7C 00
06 06 7E C6 C6 C6 7E 00
00 00 7C C6 FE C0 7C 00
1C 36 30 7C 30 30 30 00
00 00 7E C6 C6 7E 06 7C
C0 C0 FC C6 C6 C6 C6 00
18 00 38 18 18 18 3C 00
0C 00 1C 0C 0C 0C CC 78
C0 C0 CC D8 F0 D8 CC 00
38 18 18 18 18 18 3C 00
00 00 CC FE D6 C6 C6 00
00 00 FC C6 C6 C6 C6 00
00 00 7C C6 C6 C6 7C 00
00 00 FC C6 C6 FC C0 C0
00 00 7E C6 C6 7E 06 06
00 00 DC E6 C0 C0 C0 00
00 00 7E C0 7C 06 FC 00
30 30 7C 30 30 36 1C 00
00 00 C6 C6 C6 C6 7E 00
00 00 C6 C6 C6 6C 38 00
00 00 C6 C6 D6 FE 6C 00
00 00 C6 6C 38 6C C6 00
00 00 C6 C6 C6 7E 06 7C
00 00 FE 0C 38 60 FE 00
0E 18 18 70 18 18 0E 00
18 18 18 00 18 18 18 00
70 18 18 0E 18 18 70 00
76 DC 00 00 00 00 00 00
]]

local function rgba_bytes(color)
	local a = color >> 24 & 0xff
	local r = color >> 16 & 0xff
	local g = color >> 8 & 0xff
	local b = color & 0xff
	return string.pack("BBBB", r, g, b, a)
end

local function parse_bitmap(content)
	local glyphs = {}
	for line in content:gmatch "[^\r\n]+" do
		local rows = {}
		for byte in line:gmatch "%x%x" do
			rows[#rows + 1] = tonumber(byte, 16)
		end
		if #rows > 0 then
			assert(#rows == GLYPH_SIZE, "Invalid bitmap font row count")
			glyphs[#glyphs + 1] = rows
		end
	end
	assert(#glyphs == 95, "Invalid bitmap font glyph count")
	return glyphs
end
local GAMELIB_GLYPHS = parse_bitmap(GAMELIB_FONT8X8)

local function build_bitmap_glyph(rows)
	local blank = true
	local pixels = {}
	for y = 1, GLYPH_SIZE do
		local bits = rows[y]
		if bits ~= 0 then
			blank = false
		end
		for x = 0, GLYPH_SIZE - 1 do
			if bits & (0x80 >> x) ~= 0 then
				pixels[#pixels + 1] = rgba_bytes(COLOR_WHITE)
			else
				pixels[#pixels + 1] = "\0\0\0\0"
			end
		end
	end
	if blank then
		return rgba_bytes(COLOR_WHITE), 1, 1
	end
	return table.concat(pixels), GLYPH_SIZE, GLYPH_SIZE
end

function font.register_bitmap_glyphs(add_sprite)
	for index, rows in ipairs(GAMELIB_GLYPHS) do
		local codepoint = ASCII_FIRST + index - 1
		local content, width, height = build_bitmap_glyph(rows)
		add_sprite("font_glyph_" .. codepoint, content, width, height, 0, 0)
	end
end

function font.attach_bitmap_glyphs(sprites)
	sprites.font_glyphs = {}
	for codepoint = ASCII_FIRST, ASCII_LAST do
		sprites.font_glyphs[codepoint] = sprites["font_glyph_" .. codepoint]
	end
end

local function line_width(text, size)
	local width = 0
	for i = 1, #text do
		local codepoint = text:byte(i)
		if codepoint >= ASCII_FIRST and codepoint <= ASCII_LAST then
			width = width + size
		end
	end
	return width
end

local function text_layout(text, size)
	local lines = {}
	local start = 1
	local line_advance = size + math.floor(size / 4)
	local max_width = 0
	while true do
		local nl = text:find("\n", start, true)
		local line
		if nl == nil then
			line = text:sub(start)
			lines[#lines + 1] = { text = line, width = line_width(line, size) }
			break
		end
		line = text:sub(start, nl - 1)
		lines[#lines + 1] = { text = line, width = line_width(line, size) }
		start = nl + 1
	end
	if #lines == 0 then
		lines[1] = { text = "", width = 0 }
	end

	for i = 1, #lines do
		if lines[i].width > max_width then
			max_width = lines[i].width
		end
	end

	local total_height = size
	if #lines > 1 then
		total_height = size + (#lines - 1) * line_advance
	end

	return lines, max_width, total_height, line_advance
end

local function align_text_x(x, width, line_w, align)
	if align and align:find("C", 1, true) then
		return math.floor(x + (width - line_w) * 0.5 + 0.5)
	end
	if align and align:find("R", 1, true) then
		return math.floor(x + width - line_w + 0.5)
	end
	return math.floor(x + 0.5)
end

local function align_text_y(y, height, text_h, align)
	if align and align:find("V", 1, true) then
		return math.floor(y + (height - text_h) * 0.5 + 0.5)
	end
	if align and align:find("B", 1, true) then
		return math.floor(y + height - text_h + 0.5)
	end
	return math.floor(y + 0.5)
end

local function draw_line(batch, masked, glyphs, text, size, color, x, y)
	local scale = size / GLYPH_SIZE
	local scaled = scale ~= 1
	if scaled then
		batch:layer(scale, x, y)
	end
	local dx = 0
	for i = 1, #text do
		local codepoint = text:byte(i)
		local glyph = glyphs[codepoint]
		if codepoint == SPACE_CODEPOINT then
			dx = dx + GLYPH_SIZE
		elseif glyph then
			if scaled then
				batch:add(masked[glyph][color], dx, 0)
			else
				batch:add(masked[glyph][color], x + dx, y)
			end
			dx = dx + GLYPH_SIZE
		end
	end
	if scaled then
		batch:layer()
	end
end

function font.draw_text(batch, masked, glyphs, x, y, text, size, color, align, width, height)
	text = tostring(text)
	local lines, text_width, text_height, line_advance = text_layout(text, size)
	width = width or text_width
	height = height or text_height
	local draw_y = align_text_y(y, height, text_height, align)
	for i = 1, #lines do
		local line = lines[i]
		local draw_x = align_text_x(x, width, line.width, align)
		draw_line(batch, masked, glyphs, line.text, size, color, draw_x, draw_y + (i - 1) * line_advance)
	end
end

return font
