package.path = "game/?.lua;" .. package.path

local function read(path)
	local file = assert(io.open(path, "r"))
	local source = file:read("a")
	file:close()
	return source
end

-- Use Soluna's coroutine wrapper and the production scene functions without
-- starting graphics/audio services. Service delivery is an internal harness.
local coroutine_source = read("3rd/soluna/src/lualib/coroutine.lua"):gsub("global [^\n]+", "")
package.loaded["soluna.coroutine"] = assert(load(coroutine_source, "@soluna/coroutine.lua", "t",
	setmetatable({}, { __index = _G })))()
local delivery
package.loaded.ltask = {
	uniqueservice = function() return 1 end,
	self = function() return 2 end,
	dispatch = function(handlers) delivery = handlers._network_update end,
	send = function() end,
}
local online = require "online"
local source = read("game/geometry_wars.lua")
local first = assert(source:find("\tlocal function reset()", 1, true))
local last = assert(source:find("\n\tflow.load(game)", first, true))
local scenes = source:sub(first, last - 1) .. "\nreturn game"

local function setup()
	local flow = assert(loadfile("game/flow.lua"))()
	local state = {
		scene = "over", scene_time = .25, frame_dt = 1 / 60,
		player_alive = true, lives = 6, score = 0, best_score = 0, best_time = 0,
		game_time = 0, total_kills = 0, highest_combo = 0,
		set_scene_hooks = function() end,
	}
	local updates, resets = 0, 0
	local net = online.new { endpoint = "wss://test.example/ws", reset_partner = function() end }
	local env = setmetatable({
		state = state, multiplayer = net, flow = flow,
		ensure_runtime_pools = function() end,
		clear_runtime_state = function() resets = resets + 1 end,
		init_starfield = function() end, init_grid = function() end,
		confirm_requested = function() return false end,
		handle_combat_debug_keys = function() end,
		update_combat_scene = function() updates = updates + 1 end,
		update_death_scene = function() end, update_game_over_scene = function() end,
	}, { __index = _G })
	local game = assert(load(scenes, "@game/geometry_wars.lua:scenes", "t", env))()
	flow.load(game)
	local function packets(messages)
		delivery("open", "", messages)
		net.poll()
	end
	packets { { 34, { host = false } } }
	state.round = net.round
	return flow, net, state, packets, function() return updates, resets end
end

for _, scene in ipairs { "combat", "death", "over" } do
	local flow, net, state, packets, counts = setup()
	flow.enter(scene)
	flow.update()
	-- A delayed frame can consume the old round's finish and the new start
	-- together. The final started flag is true in both rounds.
	packets {
		{ 33, { id = 1, count = 2, host = false, started = false } },
		{ 33, { id = 1, count = 2, host = false, started = true } },
		{ 34, { host = false } },
	}
	assert(net.started, "New round did not start")
	assert(flow.update() == "reset", "Guest remained in the previous " .. scene .. " scene after a new round")
	assert(flow.update() == "combat", "New round did not reset into combat")
	assert(state.round == net.round, "Scene did not adopt the new round")
	flow.update()
	local updates, resets = counts()
	assert(updates > 0 and resets == 1, "New round did not resume gameplay exactly once")
end
print "PASS: batched finish/start updates reset guests in combat, death and game over"

-- Execute the complete production snapshot callback and local scene hook.
-- Host snapshots must not take ownership of guest scene timers or music.
local netcode = require "netcode"
local function noop() end
local state = { scene = "combat", scene_time = 2, combo = 0, player_alive = false, life_id = 0 }
local music_stops = 0
local env = setmetatable({
	state = state,
	player = { x = 600, y = 450, angle = 0 },
	partner = { player = {}, health = {} },
	powerup = { entries = {}, black_holes = {}, energy_duration = 8 },
	multiplayer = { local_feedback = netcode.feedback(), restore_pickup_feedback = noop },
	prediction = netcode.client(), world_buffer = netcode.buffer(.1),
	predicted_bullets = {}, enemies = {}, bullets = {}, camera = {},
	render_offset_x = 0, render_offset_y = 0,
	apply_pool = noop, replay_movement = noop,
	MAP_W = 1200, MAP_H = 900, W = 800, H = 600,
	clamp = function(value, low, high) return math.max(low, math.min(high, value)) end,
	ltask = { counter = function() return 100 end },
	input = { clear_ui_actions = noop }, audio = {},
	ensure_music_playing = noop, play_effect = noop,
	stop_music = function() music_stops = music_stops + 1 end,
}, { __index = _G })
local merge_start = assert(source:find("\tlocal function merge(", 1, true))
local merge_end = assert(source:find("\n\tlocal function active_pool", merge_start, true))
env.merge = assert(load(source:sub(merge_start, merge_end - 1) .. "\nreturn merge", "@game:merge", "t", env))()
local apply_start = assert(source:find("\t\tapply = function(data)", 1, true))
local apply_end = assert(source:find("\n\t\tend,\n\t}", apply_start, true))
local apply = assert(load("return " .. source:sub(apply_start + #"\t\tapply = ", apply_end) .. "end", "@game:apply", "t", env))()
local sync_start = assert(source:find("function state.sync_scene(", 1, true))
local sync_end = assert(source:find("\nfunction state.center_camera", sync_start, true))
assert(load(source:sub(sync_start, sync_end - 1), "@game:sync_scene", "t", env))()
local function snapshot(scene, time)
	return {
		state = { scene = scene, combo = 0, game_time = time, score = 100 },
		host_player = { x = 600, y = 450, angle = 0 },
		host_health = { life_id = 0, respawn_started = 0 },
		guest = { player = { x = 655, y = 450, angle = 0 },
			health = { life_id = 0, player_alive = false, respawn_started = 0 } },
		powerup = { energy_started = 0, entries = {}, black_holes = {} },
		enemies = {}, bullets = {}, input_ack = 0, simulation_time = time, time = time,
	}
end
apply(snapshot("death", 1))
assert(state.scene == "combat" and state.scene_time == 2, "Snapshot bypassed the guest scene transition")
assert(state.score == 100 and state.game_time == 1, "Shared world state did not synchronize")
state.sync_scene("death")
assert(music_stops == 1, "Leaving combat did not stop guest music")
state.scene_time = 1
apply(snapshot("over", 2))
assert(state.scene == "death" and state.scene_time == 1, "Repeated host snapshots stalled the guest death timer")
state.sync_scene("over")
state.sync_scene("online")
assert(music_stops == 1, "Guest music cleanup did not occur exactly once")
print "PASS: snapshots preserve local scene timers and combat music cleanup"
