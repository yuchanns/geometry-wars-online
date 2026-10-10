package.path = "game/?.lua;" .. package.path
local netcode = require "netcode"
local codec = require "net_codec"
local protocol = require "net_protocol"
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

do
	local epoch = 1791569600
	local history, client, host = netcode.history(1.25), netcode.client(), netcode.host()
	history:record(epoch, { { id = 1, x = 100, y = 200, r = 10, active = true } })
	history:record(epoch + 1, { { id = 1, x = 100, y = 220, r = 10, active = true } })
	assert(history:shot_time(epoch + .5, epoch + 1) == epoch + .5, "Absolute source clocks were rejected")
	local command = client:record({ mx = 300, my = 400 }, .02, 0, epoch + .5)
	host:receive(protocol.commands(clone(protocol.input({ command }, 0))))
	local moved, flight = 0, 0
	host:process(.02, 0, false, function()
		moved = moved + 1
	end, function(c)
		flight = flight + c.dt
		near(c.view_time, epoch + .5)
	end)
	assert(host.ack == 1 and moved == 0)
	near(flight, .02)
	print "PASS: real epoch timestamps and projectile clocks while the shooter is dead"
end

do
	local history = netcode.history(1.25)
	local current = { id = 41, x = 350, y = 0, r = 10, active = true }
	for frame = 0, 108 do
		current.y = 100 + frame / 60 * 200
		history:record(frame / 60, { current })
	end
	assert(history:shot_time(1, 1.8) == 1)
	assert(not history:shot_time(.1, 1.8) and not history:shot_time(2, 1.8))
	assert(not history:shot_time(0 / 0, 1.8) and not history:shot_time(math.huge, 1.8))
	local bullet = { x = 250, y = 325 }
	local hits = 0
	for frame = 1, 12 do
		local age = frame / 60
		current.y = 100 + (1.8 + age) * 200
		history:record(1.8 + age, { current })
		bullet.previous_x, bullet.previous_y = bullet.x, bullet.y
		bullet.x = 250 + 810 * age
		local target = history:sample(1 + age)[1]
		local previous = history:sample(1 + age - 1 / 60)[1]
		assert(not netcode.projectile_hit(bullet, current, current), "The latest world should miss this delayed shot")
		if netcode.projectile_hit(bullet, current, target, previous) then
			hits = hits + 1
			local replacement = clone(current)
			replacement.id = 42
			assert(not netcode.projectile_hit(bullet, replacement, target, previous),
				"A historical hit damaged a reused slot")
		end
	end
	assert(hits > 0, "Flight-time history failed to confirm the shooter's visible intersection")
	assert(not history:sample(.01), "Unbounded historical rewind")
	assert(#history.frames <= 256)
	assert(netcode.projectile_hit({ x = 200, y = 50, previous_x = 0, previous_y = 50 },
			{ id = 1, active = true }, { id = 1, x = 100, y = 50, r = 10, active = true }),
		"A projectile tunneled through an enemy at low FPS")
	print "PASS: delayed moving-target projectile, flight-time history, rewind bounds and enemy lifetimes"
end

do
	local function snapshot(sequence)
		return {
			sequence = sequence,
			time = sequence / 15,
			protocol_version = 1,
			state = { lives = 6, score = 0, scene = "combat", game_time = sequence / 15 },
			host_player = { x = 500, y = 500, angle = 0 },
			host_health = { player_alive = true, life_id = 0 },
			host_tx = { 1, 2 },
			host_ty = { 3, 4 },
			host_ta = { 0, 1 },
			guest = {
				player = { x = 555, y = 500, angle = 0 },
				health = { life_id = 0, player_alive = true },
				tx = {},
				ty = {},
				ta = {}
			},
			input_ack = 1,
			enemies = {
				[100] = {
					id = 7,
					x = 100.12,
					y = 200.13,
					angle = math.pi * 10 + .3,
					type = 3,
					r = 22,
					hp = 5,
					max_hp = 5,
					active = true,
					speed = 70,
					timer = 1
				}
			},
			bullets = {
				[150] = {
					id = 8,
					x = 300.12,
					y = 400.13,
					vx = 810,
					vy = 0,
					homing = true,
					input_seq = 1,
					shot = 2,
					active = true
				}
			},
			powerup = {},
			feedback = {},
			events = {}
		}
	end
	local writer, reader = protocol.writer(), protocol.reader()
	local first = snapshot(1)
	local full = clone(writer:encode(first, 0))
	local decoded = assert(reader:decode(full))
	assert(full.base == 0 and decoded.enemies[100].id == 7 and decoded.bullets[150].input_seq == 1)
	assert(decoded.bullets[150].homing and decoded.bullets[150].shot == 2)
	assert(math.abs(decoded.enemies[100].x - first.enemies[100].x) <= .125)
	assert(math.abs(decoded.enemies[100].y - first.enemies[100].y) <= .125)
	near(decoded.host_player.x, first.host_player.x)
	writer:encode(snapshot(2), 1) -- Coalesced: the receiver never sees this packet.
	local third = snapshot(3)
	third.enemies[100].x, third.state.score = 110, 123
	third.bullets = {}
	third.guest.health.player_alive = false
	third.events = { { "sound", { "hit", { volume = .5 } } } }
	decoded = assert(reader:decode(clone(writer:encode(third, 1))))
	assert(decoded.sequence == 3 and decoded.enemies[100].x == 110 and decoded.state.score == 123)
	assert(not decoded.bullets[150] and decoded.guest.health.player_alive == false)
	assert(decoded.events[1][1] == "sound")
	local fourth = snapshot(4)
	fourth.enemies[100].id = 9
	decoded = assert(reader:decode(clone(writer:encode(fourth, 3))))
	assert(decoded.enemies[100].id == 9 and decoded.state.score == 0 and #decoded.events == 0)
	assert(reader:decode(clone(writer:encode(snapshot(5), 2))) == nil, "An unknown baseline corrupted the world")
	assert(reader:decode(clone(writer:encode(snapshot(6), 0))).sequence == 6, "Full snapshot recovery failed")
	for sequence = 7, 100 do
		assert(reader:decode(clone(writer:encode(snapshot(sequence), sequence - 1))))
	end
	assert(#writer.order == 64 and #reader.order == 64)
	assert(writer:encode(snapshot(101), 1).base == 0, "An evicted baseline did not recover")
	assert(protocol.reader():decode(first) == first, "Legacy snapshots no longer work")
	-- Ordinary thrust changes must remain encodable for cached clients too.
	local effects = require "particle_effects"
	local particle_writer, particle_reader = protocol.writer(), protocol.reader()
	for sequence = 1, 20 do
		local frame = snapshot(sequence)
		frame.events = { { "emit", effects.emitter {
			kind = "thrust", x = sequence, y = 100, angle = 0,
			style = sequence % 2 == 1 and "energy" or "normal"
		}, "guest-motion" } }
		local received = particle_reader:decode(clone(particle_writer:encode(frame, sequence - 1)))
		assert(received.events[1][2].x == sequence, "Thrust delta failed to round-trip")
	end
	local client, host = netcode.client(), netcode.host()
	for frame = 1, 60 do
		local command = client:record({ right = true, mx = 700.13, my = 400.14 }, 1 / 60, 0, frame / 60)
		local packet = clone(protocol.input({ command }, 3))
		local commands = protocol.commands(packet)
		near(commands[1].dt, command.dt)
		near(commands[1].view_time, command.view_time)
		near(commands[1].mx, command.mx)
		host:receive(commands)
	end
	local steps = 0
	for _ = 1, 60 do
		host:process(1 / 60, 0, true, function()
			steps = steps + 1
		end)
	end
	assert(steps == 60 and host.ack == 60, "Ordered new-input batches lost or repeated movement")
	local compact = #codec.encode(protocol.input({ client.pending[60] }, 100))
	local old = #codec.encode { commands = client.pending }
	assert(compact < old / 10, "Input packets still retransmit pending history")
	assert(not pcall(protocol.commands, { version = 1, commands = "\1\0" }), "Truncated commands accepted")
	assert(not pcall(protocol.commands, { version = 2, commands = "\0\0" }), "Unknown protocol accepted")
	print(string.format(
		"PASS: acknowledged deltas, missing-baseline recovery, compact pools, ordered inputs (%d vs %d bytes)",
		compact, old))
end

do
	local feedback = netcode.feedback()
	local enemy = { id = 7, active = true, hp = 1 }
	local entry = { id = 8, active = true, type = 1, ability = 0 }
	local command = { seq = 10, life = 1 }
	feedback:hit(enemy, command)
	assert(feedback:collect(entry, command) and not feedback:collect(entry, command))
	feedback:reconcile(9, 1, { enemy }, { entry })
	assert(feedback.hits[7] and feedback:ability(), "An older acknowledgement undid local feedback")
	feedback:reconcile(10, 1, { enemy }, { entry })
	assert(not feedback.hits[7] and not feedback:ability(), "Rejected hits or pickups were not restored")
	assert(enemy.hp == 1 and entry.active, "Prediction changed authoritative game rules")
	command.seq = 11
	feedback:hit(enemy, command)
	feedback:reconcile(11, 1, {}, {})
	assert(feedback.hits[7], "A confirmed death reappeared in the delayed world")
	feedback:advance(.02, {})
	assert(not feedback.hits[7])
	entry.id = 9
	feedback:collect(entry, command)
	feedback:reconcile(10, 2, {}, { entry })
	assert(not feedback:ability(), "An old life retained a provisional ability")
	enemy.hp, command.life = 5, 2
	feedback:hit(enemy, command, true)
	assert(feedback.hits[7] and enemy.hp == 5, "Nuke presentation changed authoritative health")
	feedback:reconcile(11, 2, { enemy }, { entry })
	assert(not feedback.hits[7], "A rejected nuke death was not restored")
	print "PASS: reversible local hit and pickup presentation"
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
	local buffer = netcode.buffer(.1)
	local player = { x = 100, y = 100, angle = 0 }
	buffer:push(0, player, 0, {}, { { id = 1, x = 100, y = 100, active = true, input_seq = 7, shot = 1 } }, 7)
	assert(buffer:advance(.01).bullets[1].input_seq == 7)
	buffer:push(.1, player, 0, {}, { { id = 2, x = 200, y = 100, active = true } }, 7)
	local view = buffer:advance(.1)
	assert(view.bullets[1].id == 2 and view.bullets[1].input_seq == nil and view.bullets[1].shot == nil,
		"A host projectile inherited guest ownership and disappeared")
	print "PASS: reused projectile slots clear previous shot ownership"
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

do
	-- Model the extension's documented coalescing option, then run the actual
	-- Lua network service over a burst. A one-frame fire press must survive both
	-- receive queues even when several snapshots are discarded.
	local worker, received
	local host = netcode.host()
	local old_ltask, old_socket = package.loaded.ltask, package.loaded["ext.websocket"]
	package.loaded.ltask = {
		fork = function(fn)
			worker = coroutine.create(fn)
		end,
		now = function()
			return 0
		end,
		sleep = function()
			coroutine.yield()
		end,
		send = function(_, method, _, _, messages)
			if method == "_network_update" then
				received = messages
			end
		end
	}
	package.loaded["ext.websocket"] = {
		connect = function(_, latest)
			local batch = {}
			local function arrive(kind, body)
				if latest:find(string.char(kind), 1, true) then
					for index, packet in ipairs(batch) do
						if packet:byte(1) == kind then
							table.remove(batch, index)
							break
						end
					end
				end
				batch[#batch + 1] = string.char(kind) .. codec.encode(body)
			end
			for sequence = 1, 5 do
				arrive(2, protocol.input({ {
					seq = sequence,
					life = 0,
					dt = 1 / 60,
					buttons = sequence == 3 and 16 or 0,
					mx = 500,
					my = 500,
					view_time = 1791569600
				} }, 0))
				arrive(3, { sequence = sequence })
			end
			return {
				poll = function()
					return batch
				end,
				status = function()
					return "open"
				end,
				close = function()
				end,
			}
		end
	}
	local network = require "service.network"
	network.connect(1, "ws://test")
	assert(coroutine.resume(worker))
	local snapshots = 0
	for _, message in ipairs(assert(received)) do
		if message[1] == 2 then
			host:receive(protocol.commands(message[2]))
		elseif message[1] == 3 then
			snapshots = snapshots + 1
			assert(message[2].sequence == 5)
		end
	end
	local steps, shots = 0, 0
	host:process(.05, 0, true, function(command)
		steps = steps + 1
		if command.buttons & 16 ~= 0 then
			shots = shots + 1
		end
	end)
	assert(steps == 5 and shots == 1 and snapshots == 1, "A burst discarded the single fire command")
	network.quit()
	package.loaded.ltask, package.loaded["ext.websocket"] = old_ltask, old_socket
	package.loaded["service.network"] = nil
	print "PASS: native/WASM coalescing policy and Lua receive queue preserve burst fire commands"
end

do
	local handlers, applied
	local packets = {}
	local old_ltask = package.loaded.ltask
	package.loaded.ltask = {
		uniqueservice = function()
			return 1
		end,
		self = function()
			return 2
		end,
		dispatch = function(value)
			handlers = value
		end,
		send = function(_, method, kind, body)
			if method == "send" then
				packets[#packets + 1] = { kind, clone(body) }
			end
		end
	}
	local online = require "online"
	local ctx = {
		endpoint = "ws://test",
		reset_partner = function()
		end,
		remote_input = function(data)
			assert(type(data.commands) == "table")
		end,
		local_input = function(after)
			return { commands = { { seq = after + 1, life = 0, dt = .02, buttons = 0, mx = 500, my = 500 } } }
		end,
		apply = function(snapshot)
			applied = snapshot
		end,
		snapshot = function(_, effects)
			return {
				effect_version = effects and 1 or nil,
				state = {},
				host_player = {},
				host_health = {},
				host_tx = {},
				host_ty = {},
				host_ta = {},
				guest = { player = {}, health = {}, tx = {}, ty = {}, ta = {} },
				input_ack = 0,
				enemies = {},
				bullets = {},
				powerup = {},
				feedback = {}
			}
		end
	}
	local function deliver(net, kind, body)
		handlers._network_update("open", nil, { { kind, clone(body) } })
		net.poll()
	end
	local function publish(net, time)
		handlers._network_sent()
		net.publish(time)
		return packets[#packets][2]
	end
	local host = online.new(ctx)
	deliver(host, 34, { host = true })
	local first = publish(host, 2)
	assert(first.version == nil and first.protocol_version == 1, "A new host broke the legacy handshake")
	deliver(host, 2, { commands = {} })
	assert(publish(host, 3).version == nil, "A legacy guest received an unsupported compact snapshot")
	deliver(host, 2, protocol.input({}, 0))
	local compact = publish(host, 4)
	assert(compact.version == 1 and protocol.reader():decode(compact).sequence == 3)
	host.record("fx", { kind = "thrust", x = 100, y = 200, style = "normal" })
	local effect_first = publish(host, 4.1)
	local effect_repeat = publish(host, 4.2)
	local effect_reader = protocol.reader()
	local event_id = effect_reader:decode(effect_first).events[1][4]
	assert(#effect_reader:decode(effect_repeat).events == 1, "An unacknowledged effect was discarded")
	deliver(host, 2, protocol.input({}, effect_first.sequence, event_id))
	assert(#effect_reader:decode(publish(host, 4.3)).events == 0, "Acknowledged effects kept replaying")
	local guest = online.new(ctx)
	deliver(guest, 34, { host = false })
	first.protocol_version = nil -- The cached old host has no capability advertisement.
	deliver(guest, 3, first)
	assert(applied.sequence == 1 and publish(guest, 2).version == nil, "A new guest broke a legacy host")
	first.sequence, first.protocol_version = 2, 1
	deliver(guest, 3, first)
	assert(publish(guest, 3).version == 1, "Mutually supported compact inputs were not enabled")
	deliver(guest, 3, effect_first)
	assert(#applied.events == 1)
	deliver(guest, 3, effect_repeat)
	assert(#applied.events == 0 and publish(guest, 4).event_ack == event_id,
		"Repeated snapshot effects were presented more than once")
	package.loaded.ltask, package.loaded.online = old_ltask, nil
	print "PASS: new/legacy host and guest protocol negotiation"
end
