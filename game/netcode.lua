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
	function self:record(input, dt, life, view_time)
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
			mx = math.floor(clamp(input.mx * 4, -32768, 32767) + .5) / 4,
			my = math.floor(clamp(input.my * 4, -32768, 32767) + .5) / 4,
			view_time = view_time,
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

local function timestamp(v)
	return type(v) == "number" and v == v and math.abs(v) < math.huge
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
			if command.view_time ~= nil and not timestamp(command.view_time) then
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

	function self:process(dt, life, alive, step, finish)
		local budget = math.min(.1, dt * 2)
		local processed = false
		while #self.queue > 0 do
			local command = self.queue[1]
			if command.life == life and (alive or finish) then
				if processed and command.dt > budget then
					break
				end
				if alive then
					step(command)
				end
				if finish then
					finish(command)
				end
				budget = budget - command.dt
				processed = true
			end
			self.ack = command.seq
			table.remove(self.queue, 1)
		end
	end

	return self
end

-- Guest projectiles advance against the world timeline the shooter saw. The
-- host keeps collision history; clients never choose damage or an enemy ID.
function M.history(duration)
	local self = { frames = {}, duration = duration }
	function self:record(time, enemies)
		local frames = self.frames
		if frames[#frames] and time <= frames[#frames].time then
			return
		end
		local poses = {}
		for slot, enemy in pairs(enemies) do
			if enemy.active then
				poses[slot] = { id = enemy.id, x = enemy.x, y = enemy.y, r = enemy.r, active = true }
			end
		end
		frames[#frames + 1] = { time = time, enemies = poses }
		while #frames > 2 and (frames[2].time < time - duration or #frames > 256) do
			table.remove(frames, 1)
		end
	end

	function self:shot_time(requested, now)
		local first = self.frames[1]
		if timestamp(requested) and first and requested >= math.max(first.time, now - duration)
			and requested <= now then
			return requested
		end
	end

	function self:sample(time, out)
		local frames = self.frames
		if not frames[1] or time < frames[1].time or time > frames[#frames].time then
			return nil
		end
		local a, b = frames[1], frames[1]
		for i = 2, #frames do
			b = frames[i]
			if b.time >= time then
				break
			end
			a = b
		end
		local t = b.time > a.time and clamp((time - a.time) / (b.time - a.time), 0, 1) or 1
		out = out or {}
		for _, value in pairs(out) do
			value.active = false
		end
		for slot, value in pairs(t < 1 and a.enemies or b.enemies) do
			local next_value = b.enemies[slot]
			local target = out[slot] or {}
			out[slot] = target
			target.id, target.r, target.active = value.id, value.r, true
			target.x, target.y = value.x, value.y
			if next_value and value.id == next_value.id then
				target.x = value.x + (next_value.x - value.x) * t
				target.y = value.y + (next_value.y - value.y) * t
			end
		end
		return out
	end

	return self
end

-- Sweep the relative motion, rather than testing one endpoint at low FPS.
function M.projectile_hit(bullet, enemy, target, previous_target)
	if not enemy.active or not target or not target.active or enemy.id ~= target.id then
		return false
	end
	if not previous_target or not previous_target.active or previous_target.id ~= target.id then
		previous_target = target
	end
	local x = (bullet.previous_x or bullet.x) - previous_target.x
	local y = (bullet.previous_y or bullet.y) - previous_target.y
	local dx, dy = bullet.x - target.x - x, bullet.y - target.y - y
	local length = dx * dx + dy * dy
	local t = length > 0 and clamp(-(x * dx + y * dy) / length, 0, 1) or 0
	x, y = x + dx * t, y + dy * t
	return x * x + y * y < (target.r + 4) ^ 2
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
	-- A reused slot must not retain shot ownership from its previous lifetime.
	for key in pairs(out) do
		out[key] = nil
	end
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
		clock = 0,
		delay = delay,
		interval = delay / 2,
		jitter = 0,
		view = {
			host = {},
			enemies = {},
			bullets = {}
		}
	}
	function self:push(time, player, life, enemies, bullets, ack, received_at)
		local frames = self.frames
		local previous = frames[#frames]
		if previous and time <= previous.time then
			return
		end
		received_at = received_at or self.clock
		if previous and self.received_at then
			local interval = time - previous.time
			self.interval = self.interval + (math.min(interval, .5) - self.interval) * .1
			self.jitter = clamp(math.max(self.jitter, received_at - self.received_at - interval), 0, .5)
		end
		self.received_at = received_at
		self.delay = clamp(self.interval * 2 + self.jitter, delay, .6)
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
		frames[#frames + 1] = frame
		if #frames > 32 then
			table.remove(frames, 1)
		end
		if not self.started then
			self.time = time - delay
		end
	end

	function self:advance(dt)
		self.clock = self.clock + dt
		self.jitter = math.max(0, self.jitter - dt * .025)
		local frames = self.frames
		if #frames == 0 then
			return nil
		end
		local latest = frames[#frames]
		self.delay = clamp(self.interval * 2 + self.jitter, delay, .6)
		-- Resume near the newest state after an outage, rather than replaying seconds of backlog.
		if latest.time - self.time > 1.2 then
			self.time = latest.time - self.delay
		end
		-- Adjust playback speed instead of jumping the clock when a batch arrives.
		local error = latest.time - self.delay - self.time
		local rate = 1
		if self.started and math.abs(error) > .1 then
			rate = clamp(1 + error * .5, .9, 1.1)
		end
		self.started = true
		self.time = math.min(math.max(self.time + dt * rate, frames[1].time), latest.time)
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
