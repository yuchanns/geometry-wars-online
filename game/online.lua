local ltask = require "ltask"
local protocol = require "net_protocol"
local effects = require "particle_effects"

local M = {}

function M.new(ctx)
	local net = {
		host = false,
		compact_effects = false,
		started = false,
		room = nil,
		rooms = {},
		selected = 1,
		page = 1,
		error = "",
		connected = false,
		events = {},
	}
	local network = ltask.uniqueservice "network"
	local inbox
	local pending_send = false
	local force_full, send_error = false, nil
	local event_sequence, event_ack = 0, 0
	local sent = 0
	local snapshot_sequence, last_snapshot = 0, 0
	local peer_protocol, snapshot_ack, last_input_sent = 0, 0, 0
	local writer, reader = protocol.writer(), protocol.reader()

	local function send_failed(kind, reason)
		pending_send = false
		if kind == 3 then
			force_full = true
		elseif kind == 2 then
			last_input_sent = 0
		end
		if send_error ~= reason then
			print("Packet send failed: " .. reason)
		end
		send_error, net.error = reason, reason
	end

	-- Acknowledge after the frame consumes this batch, bounding the inbox.
	ltask.dispatch {
		_network_update = function(state, reason, messages)
			inbox = {
				state = state,
				reason = reason,
				messages = messages
			}
		end,
		_network_sent = function()
			pending_send = false
			if send_error and net.error == send_error then
				net.error = ""
			end
			send_error = nil
		end,
		_network_send_failed = send_failed,
	}

	local function send(kind, body, frame)
		if not net.connected then
			return false
		end
		ltask.send(network, "send", kind, body, frame)
		return true
	end

	function net.record(kind, body)
		if net.host and net.started then
			event_sequence = event_sequence + 1
			net.events[#net.events + 1] = { kind, body, net.effect_source, event_sequence }
			if #net.events > 512 then
				table.remove(net.events, 1)
			end
		end
	end

	function net.connect()
		net.connected = false
		net.room = nil
		net.started = false
		pending_send = false
		ltask.send(network, "connect", ltask.self(), ctx.endpoint)
		print("Connecting: " .. ctx.endpoint)
	end

	local function handle_message(kind, body)
		if kind == 32 then
			net.rooms = body
			net.selected = math.min(math.max(1, #body), net.selected)
			net.page = math.min(net.page, math.max(1, math.ceil(#body / 7)))
		elseif kind == 33 then
			if body.count == 0 then
				net.room = nil
				net.started = false
			else
				net.room = body
				net.host = body.host
				net.started = body.started
			end
		elseif kind == 34 then
			net.host = body.host
			net.started = true
			net.error = ""
			snapshot_sequence = 0
			last_snapshot = 0
			peer_protocol, snapshot_ack, last_input_sent = 0, 0, 0
			net.compact_effects = false
			event_sequence, event_ack = 0, 0
			net.events = {}
			writer, reader = protocol.writer(), protocol.reader()
			force_full, send_error = false, nil
			ctx.reset_partner()
			print("Room started / " .. (net.host and "host" or "guest"))
		elseif kind == 35 then
			net.error = body
		elseif kind == 36 then
			net.room = nil
			net.started = false
			pending_send = false
			net.events = {}
		elseif kind == 2 and net.host then
			local commands = protocol.commands(body)
			net.compact_effects = body.effects == 1
			if net.compact_effects and type(body.event_ack) == "number" and body.event_ack <= event_sequence then
				while net.events[1] and net.events[1][4] <= body.event_ack do
					table.remove(net.events, 1)
				end
			end
			if body.version == 1 then
				peer_protocol = 1
				snapshot_ack = body.snapshot_ack
			end
			ctx.remote_input { commands = commands }
		elseif kind == 3 and not net.host and body.sequence > last_snapshot then
			local snapshot = reader:decode(body)
			if snapshot then
				last_snapshot, snapshot_ack = body.sequence, body.sequence
				peer_protocol = snapshot.protocol_version or 0
				if snapshot.effect_version == 1 then
					local events = {}
					for _, event in ipairs(snapshot.events or {}) do
						if event[4] > event_ack then
							events[#events + 1] = event
							event_ack = event[4]
						end
					end
					snapshot.events = events
				end
				ctx.apply(snapshot)
			else
				snapshot_ack = 0
			end
		end
	end

	function net.poll()
		local batch = inbox
		if not batch then
			return
		end
		inbox = nil
		local state, reason = batch.state, batch.reason
		if not net.connected and state == "open" then
			net.error = ""
		end
		net.connected = state == "open"
		if state == "closed" then
			net.started = false
			net.room = nil
			net.error = reason or ""
			pending_send = false
			net.events = {}
		else
			for _, message in ipairs(batch.messages) do
				local ok, err = pcall(handle_message, message[1], message[2])
				if not ok then
					net.error = tostring(err)
					print(err)
					ltask.send(network, "close", net.error)
					break
				end
			end
		end
		ltask.send(network, "received")
	end

	function net.publish(time)
		local interval = net.host and 1 / 15 or 1 / 30
		if not net.started or pending_send or time - sent < interval then
			return
		end
		sent = time
		if net.host then
			local snapshot = ctx.snapshot(time, net.compact_effects)
			snapshot.events = net.events
			if not net.compact_effects then
				-- Cached clients still consume the previous emitter format.
				snapshot.events = {}
				for i, event in ipairs(net.events) do
					snapshot.events[i] = event[1] == "fx"
						and { "emit", effects.emitter(event[2]), event[3], event[4] } or event
				end
			end
			snapshot_sequence = snapshot_sequence + 1
			snapshot.sequence = snapshot_sequence
			snapshot.time = time
			-- Negotiate in a legacy snapshot so cached older clients still work.
			snapshot.protocol_version = 1
			local packet = snapshot
			if peer_protocol == 1 then
				local ok, encoded = pcall(writer.encode, writer, snapshot, force_full and 0 or snapshot_ack)
				if not ok then
					send_failed(3, tostring(encoded))
					return
				end
				packet = encoded
			end
			force_full = false
			if send(3, packet, true) then
				if not net.compact_effects then net.events = {} end
				pending_send = true
				sent = time
			end
		else
			local input = ctx.local_input(peer_protocol == 1 and last_input_sent or 0)
			input.event_ack = event_ack
			local packet = input
			if peer_protocol == 1 then
				local ok, encoded = pcall(protocol.input, input.commands, snapshot_ack, event_ack)
				if not ok then
					send_failed(2, tostring(encoded))
					return
				end
				packet = encoded
			end
			if send(2, packet, true) then
				-- WebSocket delivers these batches in order; retain inputs locally for
				-- reconciliation, but do not retransmit the whole pending history.
				local last = input.commands[#input.commands]
				last_input_sent = last and last.seq or last_input_sent
				pending_send = true
				sent = time
			end
		end
	end

	function net.create()
		send(17, {})
	end

	function net.join()
		local room = net.rooms[net.selected]
		if room then
			send(18, room.id)
		end
	end

	function net.start()
		send(20, {})
	end

	function net.leave()
		send(19, {})
	end

	function net.finish()
		send(21, {})
	end

	function net.refresh()
		send(16, {})
	end

	function net.draw()
		ctx.text(0, 95, "GEOMETRY WARS", 24, 0xff00ffff, "C", 800)
		local function button(x, y, width, label, action, enabled)
			local color = enabled and 0xff00ffff or 0xff404040
			if ctx.button(x, y, width, 30, label, color) and enabled then
				action()
			end
		end
		if not net.connected then
			ctx.text(0, 230, "CONNECTING...", 12, 0xff79c8ff, "C", 800)
			ctx.text(0, 540, net.error, 8, 0xffff554a, "C", 800)
			return
		end
		if net.room then
			ctx.text(0, 178, string.format("ROOM %03d", net.room.id), 16, 0xffffffff, "C", 800)
			local status = net.room.count == 1 and "WAITING FOR SECOND PLAYER" or "TWO PLAYERS READY"
			ctx.text(0, 222, status, 10, 0xff79c8ff, "C", 800)
			button(240, 295, 320, net.host and "START GAME" or "WAITING FOR HOST", net.start,
				net.host and net.room.count == 2)
			button(300, 346, 200, "LEAVE ROOM", net.leave, true)
		else
			ctx.text(60, 160, "ROOM", 8, 0xffc8c8c8, "LT", 120, 8)
			ctx.text(230, 160, "PLAYERS", 8, 0xffc8c8c8, "LT", 100, 8)
			ctx.text(360, 160, "STATUS", 8, 0xffc8c8c8, "LT", 120, 8)
			button(600, 148, 140, "CREATE ROOM", net.create, true)
			if #net.rooms == 0 then
				ctx.text(60, 205, "NO ROOMS", 8, 0xffffffff, "LT", 400, 12)
			end
			local first = (net.page - 1) * 7 + 1
			for index = first, math.min(first + 6, #net.rooms) do
				local room = net.rooms[index]
				local y = 200 + (index - first) * 40
				local enabled = room.count < 2 and not room.started
				local status = room.started and "PLAYING" or (enabled and "WAITING" or "FULL")
				ctx.text(60, y, string.format("#%03d", room.id), 8, 0xffffffff, "LT", 120, 12)
				ctx.text(230, y, string.format("%d/2", room.count), 8, 0xffffffff, "LT", 100, 12)
				ctx.text(360, y, status, 8, 0xffffffff, "LT", 120, 12)
				button(600, y - 8, 140, "JOIN", function()
					net.selected = index
					net.join()
				end, enabled)
			end
			if #net.rooms > 7 then
				local pages = math.ceil(#net.rooms / 7)
				ctx.text(60, 505, string.format("PAGE %d/%d", net.page, pages), 8, 0xffc8c8c8, "LT", 120, 12)
				button(600, 490, 65, "PREV", function()
					net.page = net.page - 1
				end, net.page > 1)
				button(675, 490, 65, "NEXT", function()
					net.page = net.page + 1
				end, net.page < pages)
			end
		end
		ctx.text(0, 540, net.error, 8, 0xffff554a, "C", 800)
	end

	net.reset_partner = ctx.reset_partner
	net.connect()
	return net
end

return M
