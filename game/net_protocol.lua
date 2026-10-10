local M = {}
local HISTORY_SIZE = 64
local ENEMY_FORMAT = "<I4i2i2i2BBBB"
local BULLET_FORMAT = "<I4i2i2i2i2BI4B"
local INPUT_FORMAT = "<I4I4dBi2i2d"

local function coordinate(value)
	return math.max(-32768, math.min(32767, math.floor(value * 4 + .5)))
end

local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, item in pairs(value) do
		if type(item) ~= "function" then
			result[key] = copy(item)
		end
	end
	return result
end

local function difference(value, base, depth)
	depth = depth or 0
	local patch = { set = {}, remove = {}, edit = {} }
	for key, item in pairs(value) do
		local old = base[key]
		if type(item) == "table" and type(old) == "table" then
			local edit = difference(item, old, depth + 1)
			if edit and depth >= 2 then
				-- Deep edits multiply wire nesting. Replace the changed subtree
				-- instead, keeping particle parameters within the codec limit.
				patch.set[key] = copy(item)
			else
				patch.edit[key] = edit
			end
		elseif item ~= old then
			patch.set[key] = copy(item)
		end
	end
	for key in pairs(base) do
		if value[key] == nil then
			patch.remove[#patch.remove + 1] = key
		end
	end
	if not next(patch.set) then
		patch.set = nil
	end
	if #patch.remove == 0 then
		patch.remove = nil
	end
	if not next(patch.edit) then
		patch.edit = nil
	end
	return next(patch) and patch or nil
end

local function apply(base, patch)
	local result = copy(base)
	for _, key in ipairs(patch.remove or {}) do
		result[key] = nil
	end
	for key, value in pairs(patch.set or {}) do
		result[key] = copy(value)
	end
	for key, value in pairs(patch.edit or {}) do
		assert(type(result[key]) == "table", "Invalid snapshot patch")
		result[key] = apply(result[key], value)
	end
	return result
end

local function normalize(snapshot)
	local result = copy(snapshot)
	result.enemies, result.bullets = {}, {}
	for slot, enemy in pairs(snapshot.enemies) do
		local angle = (enemy.angle + math.pi) % (math.pi * 2) - math.pi
		result.enemies[slot] = string.pack(ENEMY_FORMAT, enemy.id,
			coordinate(enemy.x), coordinate(enemy.y), math.floor(angle / math.pi * 32767),
			enemy.type, enemy.r, enemy.hp, enemy.max_hp)
	end
	for slot, bullet in pairs(snapshot.bullets) do
		result.bullets[slot] = string.pack(BULLET_FORMAT, bullet.id,
			coordinate(bullet.x), coordinate(bullet.y), coordinate(bullet.vx), coordinate(bullet.vy),
			bullet.homing and 1 or 0, bullet.input_seq or 0, bullet.shot or 0)
	end
	return result
end

local function expand(snapshot)
	local result = copy(snapshot)
	result.enemies, result.bullets = {}, {}
	for slot, data in pairs(snapshot.enemies) do
		assert(type(slot) == "number" and slot % 1 == 0 and slot >= 1 and slot <= 100
			and #data == string.packsize(ENEMY_FORMAT), "Invalid enemy")
		local id, x, y, angle, kind, radius, hp, max_hp = string.unpack(ENEMY_FORMAT, data)
		assert(kind <= 4, "Invalid enemy type")
		result.enemies[slot] = {
			id = id,
			x = x / 4,
			y = y / 4,
			angle = angle / 32767 * math.pi,
			type = kind,
			r = radius,
			hp = hp,
			max_hp = max_hp,
			active = true
		}
	end
	for slot, data in pairs(snapshot.bullets) do
		assert(type(slot) == "number" and slot % 1 == 0 and slot >= 1 and slot <= 150
			and #data == string.packsize(BULLET_FORMAT), "Invalid projectile")
		local id, x, y, vx, vy, homing, sequence, shot = string.unpack(BULLET_FORMAT, data)
		result.bullets[slot] = {
			id = id,
			x = x / 4,
			y = y / 4,
			vx = vx / 4,
			vy = vy / 4,
			homing = homing == 1,
			input_seq = sequence > 0 and sequence or nil,
			shot = shot,
			active = true
		}
	end
	return result
end

local function remember(self, sequence, snapshot)
	self.frames[sequence] = snapshot
	self.order[#self.order + 1] = sequence
	while #self.order > HISTORY_SIZE do
		self.frames[table.remove(self.order, 1)] = nil
	end
end

function M.writer()
	local self = { frames = {}, order = {} }
	function self:encode(snapshot, acknowledged)
		local current = normalize(snapshot)
		local base = self.frames[acknowledged]
		local packet = {
			sequence = snapshot.sequence,
			base = base and acknowledged or 0,
			delta = difference(current, base or {})
		}
		remember(self, snapshot.sequence, current)
		return packet
	end

	return self
end

function M.reader()
	local self = { frames = {}, order = {} }
	function self:decode(packet)
		local base = packet.base == 0 and {} or self.frames[packet.base]
		if not base then
			return nil -- Ask for a full snapshot; never apply a broken delta.
		end
		local snapshot = apply(base, packet.delta)
		assert(snapshot.sequence == packet.sequence, "Invalid snapshot sequence")
		local expanded = expand(snapshot)
		remember(self, packet.sequence, snapshot)
		return expanded
	end

	return self
end

function M.input(commands, acknowledged, event_ack)
	local parts = { string.pack("<I2", #commands) }
	for _, command in ipairs(commands) do
		parts[#parts + 1] = string.pack(INPUT_FORMAT, command.seq, command.life,
			command.dt, command.buttons, coordinate(command.mx), coordinate(command.my), command.view_time or -1)
	end
	return {
		event_ack = event_ack or 0,
		snapshot_ack = acknowledged,
		commands = table.concat(parts)
	}
end

function M.commands(packet)
	local count, offset = string.unpack("<I2", packet.commands)
	assert(count <= 256 and #packet.commands == 2 + count * string.packsize(INPUT_FORMAT), "Invalid input batch")
	local commands = {}
	for i = 1, count do
		local sequence, life, dt, buttons, x, y, view_time
		sequence, life, dt, buttons, x, y, view_time, offset = string.unpack(INPUT_FORMAT, packet.commands, offset)
		commands[i] = {
			seq = sequence,
			life = life,
			dt = dt,
			buttons = buttons,
			mx = x / 4,
			my = y / 4,
			view_time = view_time >= 0 and view_time or nil
		}
	end
	return commands
end

return M
