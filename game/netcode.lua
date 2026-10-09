local M = {}
local MAX_COMMANDS = 256

local function clamp(v, lo, hi)
	return math.max(lo, math.min(hi, v))
end

-- The host, prediction and replay use exactly the same movement calculation.
function M.move(player, input, dt, world)
	local dx = (input.right and 1 or 0) - (input.left and 1 or 0)
	local dy = (input.down and 1 or 0) - (input.up and 1 or 0)
	local length = math.sqrt(dx * dx + dy * dy)
	if length > 0 then
		player.x = player.x + dx / length * world.speed * dt
		player.y = player.y + dy / length * world.speed * dt
	end
	player.x, player.y = clamp(player.x, 20, world.width - 20), clamp(player.y, 20, world.height - 20)
	for _, hole in ipairs(world.black_holes or {}) do
		if hole.active and not hole.exploding then
			local x, y = hole.x - player.x, hole.y - player.y
			local distance = math.sqrt(x * x + y * y)
			if distance < hole.radius and distance > 1 then
				player.x = clamp(player.x + x / distance * hole.pull_strength * .3 * dt, 20, world.width - 20)
				player.y = clamp(player.y + y / distance * hole.pull_strength * .3 * dt, 20, world.height - 20)
			end
		end
	end
	local x, y = (input.mx or player.x) - player.x, (input.my or player.y) - player.y
	if x * x + y * y > 25 then
		player.angle = math.atan(y, x)
	end
	return length > 0
end

function M.controls(command, out)
	out = out or {}
	local buttons = command.buttons
	out.left, out.right = buttons & 1 ~= 0, buttons & 2 ~= 0
	out.up, out.down = buttons & 4 ~= 0, buttons & 8 ~= 0
	out.mouse_left = buttons & 16 ~= 0
	out.mx, out.my = command.mx, command.my
	return out
end

function M.client()
	local self = { sequence = 0, pending = {} }
	function self:record(input, dt, life)
		if #self.pending >= MAX_COMMANDS then
			return nil
		end
		self.sequence = self.sequence + 1
		local command = {
			seq = self.sequence,
			life = life,
			dt = dt,
			buttons = (input.left and 1 or 0) | (input.right and 2 or 0)
				| (input.up and 4 or 0) | (input.down and 8 or 0) | (input.mouse_left and 16 or 0),
			mx = input.mx,
			my = input.my,
		}
		self.pending[#self.pending + 1] = command
		return command
	end

	function self:reconcile(player, authoritative, ack, life, alive, step)
		local pending = {}
		for _, command in ipairs(self.pending) do
			if command.seq > ack and command.life == life then
				pending[#pending + 1] = command
			end
		end
		self.pending = pending
		player.x, player.y, player.angle = authoritative.x, authoritative.y, authoritative.angle
		if alive then
			for _, command in ipairs(pending) do
				step(player, command)
			end
		end
	end

	return self
end

local function finite(v)
	return type(v) == "number" and v == v and math.abs(v) < 1e9
end

function M.host()
	local self = {
		ack = 0,
		received = 0,
		queue = {}
	}
	function self:receive(commands)
		if type(commands) ~= "table" or #commands > MAX_COMMANDS then
			return
		end
		for _, command in ipairs(commands) do
			if type(command) ~= "table" or not finite(command.seq) or command.seq % 1 ~= 0
				or not finite(command.life) or command.life % 1 ~= 0
				or not finite(command.dt) or command.dt <= 0 or command.dt > .05
				or not finite(command.buttons) or command.buttons % 1 ~= 0 or command.buttons < 0 or command.buttons > 31
				or not finite(command.mx) or not finite(command.my) then
				return
			end
			if command.seq > self.received then
				if #self.queue >= MAX_COMMANDS then
					return
				end
				self.queue[#self.queue + 1] = command
				self.received = command.seq
			end
		end
	end

	function self:process(dt, life, alive, step)
		local budget = math.min(.1, dt * 2)
		local processed = false
		while #self.queue > 0 do
			local command = self.queue[1]
			if command.life == life and alive then
				if processed and command.dt > budget then
					break
				end
				step(command)
				budget = budget - command.dt
				processed = true
			end
			self.ack = command.seq
			table.remove(self.queue, 1)
		end
	end

	return self
end

local function pose(value)
	local out = {}
	for k, v in pairs(value) do
		if type(v) ~= "table" then
			out[k] = v
		end
	end
	return out
end

local function interpolate(a, b, t, out)
	for k, v in pairs(b) do
		out[k] = v
	end
	-- A reused object slot or respawn is a new object, not a long movement.
	if a and a.id == b.id then
		out.x, out.y = a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t
		if a.angle and b.angle then
			local angle = (b.angle - a.angle + math.pi) % (2 * math.pi) - math.pi
			out.angle = a.angle + angle * t
		end
	end
end

function M.buffer(delay)
	local self = {
		frames = {},
		view = {
			host = {},
			enemies = {},
			bullets = {}
		}
	}
	function self:push(time, player, life, enemies, bullets, ack)
		local frame = {
			time = time,
			host = pose(player),
			enemies = {},
			bullets = {},
			ack = ack
		}
		frame.host.id = life
		for i, enemy in pairs(enemies) do
			frame.enemies[i] = pose(enemy)
		end
		for i, bullet in pairs(bullets) do
			frame.bullets[i] = pose(bullet)
		end
		local frames = self.frames
		frames[#frames + 1] = frame
		if #frames > 8 then
			table.remove(frames, 1)
		end
		self.time = math.max(self.time or time - delay, time - delay)
	end

	function self:advance(dt)
		local frames = self.frames
		if #frames == 0 then
			return nil
		end
		self.time = math.min(self.time + dt, frames[#frames].time)
		while #frames > 2 and frames[2].time <= self.time do
			table.remove(frames, 1)
		end
		local a, b = frames[1], frames[2] or frames[1]
		local t = b.time > a.time and clamp((self.time - a.time) / (b.time - a.time), 0, 1) or 1
		interpolate(a.host, b.host, t, self.view.host)
		self.view.ack = t < 1 and a.ack or b.ack
		for _, kind in ipairs { "enemies", "bullets" } do
			local view = self.view[kind]
			for _, value in pairs(view) do
				value.active = false
			end
			local source = t < 1 and a[kind] or b[kind]
			for i, value in pairs(source) do
				view[i] = view[i] or {}
				local next_value = b[kind][i]
				if next_value and value.id == next_value.id then
					interpolate(value, next_value, t, view[i])
				else
					interpolate(nil, value, t, view[i])
				end
			end
		end
		return self.view
	end

	return self
end

return M
