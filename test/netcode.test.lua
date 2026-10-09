package.path = "game/?.lua;" .. package.path
local netcode = require "netcode"
local codec = require "net_codec"
local world = {
	speed = 250,
	width = 2000,
	height = 2000,
	black_holes = {}
}
local function step(player, command)
	netcode.move(player, netcode.controls(command), command.dt, world)
end
local function near(a, b)
	assert(math.abs(a - b) < 1e-7, string.format("%.9f != %.9f", a, b))
end
local function clone(value)
	return codec.decode(codec.encode(value))
end

-- Real input batches and acknowledgements, with delay, jitter, coalescing,
-- reversals and different render rates. Prediction must remain at local time.
for _, host_rate in ipairs { 30, 60, 120 } do
	local client, host = netcode.client(), netcode.host()
	local player, authoritative, reference = {
			x = 500,
			y = 500,
			angle = 0
		}, {
			x = 500,
			y = 500,
			angle = 0
		},
		{
			x = 500,
			y = 500,
			angle = 0
		}
	local to_host, to_client = {}, {}
	local last_input_arrival, last_snapshot_arrival = 0, 0
	local packet_count, next_host, next_input, next_snapshot = 0, 0, 0, 0
	for frame = 1, 540 do
		local time = frame / 60
		local input = {
			right = time < 2,
			left = time >= 2 and time < 4,
			up = time >= 4 and time < 6,
			down = time >= 6 and
				time < 8,
			mx = 900,
			my = 700
		}
		local command = assert(client:record(input, 1 / 60, 0))
		step(player, command)
		step(reference, command)
		if time >= next_input then
			next_input = time + 1 / 30
			packet_count = packet_count + 1
			if packet_count % 4 ~= 0 then
				last_input_arrival = math.max(last_input_arrival + .001, time + .12 + (packet_count % 3 - 1) * .018)
				to_host[#to_host + 1] = { time = last_input_arrival, commands = clone(client.pending) }
			end
		end
		while to_host[1] and to_host[1].time <= time do
			local packet = table.remove(to_host, 1)
			host:receive(packet.commands)
			host:receive(packet.commands) -- duplicates must not move twice
		end
		while next_host <= time do
			host:process(1 / host_rate, 0, true, function(c)
				step(authoritative, c)
			end)
			next_host = next_host + 1 / host_rate
		end
		if time >= next_snapshot then
			next_snapshot = time + 1 / 15
			last_snapshot_arrival = math.max(last_snapshot_arrival + .001, time + .12 + (frame % 3 - 1) * .018)
			to_client[#to_client + 1] = {
				time = last_snapshot_arrival,
				player = clone(authoritative),
				ack = host.ack
			}
		end
		while to_client[1] and to_client[1].time <= time do
			local snapshot = table.remove(to_client, 1)
			client:reconcile(player, snapshot.player, snapshot.ack, 0, true, step)
		end
		near(player.x, reference.x)
		near(player.y, reference.y)
		assert(#client.pending < 40, "Acknowledgements stopped advancing")
	end
	print("PASS: 240 ms RTT, jitter, reversals, duplicate/coalesced packets, host " .. host_rate .. " Hz")
end

do
	local client, host = netcode.client(), netcode.host()
	local player = {
		x = 300,
		y = 300,
		angle = 0
	}
	assert(client:record({
		right = true,
		mx = 800,
		my = 300
	}, .016, 0))
	host:receive(clone(client.pending))
	local calls = 0
	host:process(.016, 1, true, function()
		calls = calls + 1
	end)
	assert(calls == 0 and host.ack == 1, "Pre-death input leaked into respawn")
	client:reconcile(player, {
		x = 1000,
		y = 1000,
		angle = 0
	}, host.ack, 1, true, step)
	assert(#client.pending == 0)
	near(player.x, 1000)
	local c = assert(client:record({
		left = true,
		mx = 800,
		my = 300
	}, .016, 1))
	host:receive { c }
	host:process(.004, 1, true, function(command)
		calls = calls + 1
		step(player, command)
	end)
	assert(calls == 1 and host.ack == 2, "A faster host could not consume a slower client's command")
	client:reconcile(player, {
		x = 700,
		y = 700,
		angle = 0
	}, 0, 1, false, step)
	near(player.x, 700)
	near(player.y, 700)
	print "PASS: respawn epoch, dead-player prediction, mismatched frame rates"
end

do
	local buffer = netcode.buffer(.1)
	buffer:push(0, {
			x = 0,
			y = 0,
			angle = 3
		}, 0, {
			[1] = {
				id = 1,
				x = 0,
				y = 0,
				angle = 3,
				active = true
			}
		},
		{
			[1] = {
				id = 2,
				x = 0,
				y = 0,
				active = true
			}
		}, 1)
	buffer:push(.1, {
			x = 100,
			y = 0,
			angle = -3
		}, 0, {
			[1] = {
				id = 1,
				x = 100,
				y = 0,
				angle = -3,
				active = true
			}
		},
		{
			[1] = {
				id = 3,
				x = 1000,
				y = 0,
				active = true
			}
		}, 2)
	local view = buffer:advance(.05)
	near(view.host.x, 50)
	near(view.enemies[1].x, 50)
	near(view.host.angle, math.pi)
	assert(view.bullets[1].id == 2 and view.bullets[1].x == 0 and view.ack == 1,
		"Future objects appeared before their snapshot")
	view = buffer:advance(.05)
	assert(view.bullets[1].id == 3 and view.bullets[1].x == 1000 and view.ack == 2,
		"A reused bullet slot interpolated across object lifetimes")
	print "PASS: world interpolation, angle wrapping, object lifetimes and shot confirmation"
end

do
	-- Applied snapshot intervals captured from two browser clients on a real CF room.
	-- Each pair is receipt interval / host simulation interval, in seconds.
	local arrivals = {
		{ .154, .162 }, { .140, .071 }, { .040, .081 }, { .133, .081 },
		{ .030, .081 }, { .599, .467 }, { .530, .701 }, { .143, .081 },
		{ .029, .071 }, { .153, .162 }, { .142, .071 }, { .041, .081 },
		{ .111, .081 }, { .020, .071 }, { .153, .163 }, { .143, .152 },
		{ .132, .081 }, { .040, .071 }, { .235, .244 }
	}
	local buffer = netcode.buffer(.1)
	local receipt, source, index = 0, 0, 1
	local last_x, holds, measured = nil, 0, 0
	for frame = 1, 1800 do
		local now, dt = frame / 60, 1 / 60
		while receipt <= now do
			local player = { x = source * 60, y = 100, angle = 0 }
			local old_time = buffer.time
			buffer:push(source, player, 1, { { id = 1, x = player.x, y = 100, active = true } }, {}, 1, receipt)
			if old_time and last_x then
				near(buffer.time, old_time)
			end
			local interval = arrivals[index]
			receipt, source = receipt + interval[1], source + interval[2]
			index = index % #arrivals + 1
		end
		local old_time = buffer.time
		local view = buffer:advance(dt)
		if frame > 300 then
			local dx = view.enemies[1].x - last_x
			assert(dx >= -1e-7 and dx <= 60 * dt * 1.10001, "A packet batch jumped the playback clock")
			assert(buffer.time >= old_time, "Playback moved backwards")
			assert(buffer.frames[#buffer.frames].time - buffer.time <= 1.2, "Playback retained old history")
			measured = measured + 1
			if math.abs(dx) < 1e-7 then
				holds = holds + 1
			end
		end
		last_x = view.enemies[1].x
	end
	assert(holds / measured < .03, "Recorded CF jitter repeatedly exhausted the playback buffer")
	-- A long outage must not leave an unbounded delay estimate or retained history.
	for i = 1, 100 do
		local player = { x = source * 60, y = 100, angle = 0 }
		buffer:push(source, player, 1, {}, {}, 1, receipt + 20)
		source = source + .08
	end
	assert(#buffer.frames <= 32)
	buffer:advance(1 / 60)
	assert(buffer.frames[#buffer.frames].time - buffer.time <= .6, "Outage recovery replayed old history")
	print "PASS: recorded CF burst arrivals, continuous playback and bounded jitter buffer"
end

do
	local player = {
		x = 1990,
		y = 1990,
		angle = 0
	}
	netcode.move(player, {
		right = true,
		down = true,
		mx = 0,
		my = 0
	}, .05, world)
	near(player.x, 1980)
	near(player.y, 1980)
	local host = netcode.host()
	host:receive { {
		seq = 1,
		life = 0,
		dt = math.huge,
		buttons = 2,
		mx = 10,
		my = 10
	} }
	assert(#host.queue == 0)
	print "PASS: map bounds and invalid input durations"
end
