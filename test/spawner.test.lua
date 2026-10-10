-- Run the production spawner without starting the graphics/audio services.
local file = assert(io.open("game/geometry_wars.lua", "r"))
local source = file:read("a")
file:close()
local start = assert(source:find("local function update_spawner(dt)", 1, true))
local finish = assert(source:find("\nlocal function init_starfield()", start, true))
local spawner = source:sub(start, finish - 1) .. "\nreturn update_spawner"

local function run(host_alive, guest_alive, scene, invasion)
	local spawned, pickups = 0, 0
	local state = { scene = scene or "combat", player_alive = host_alive, game_time = 0, spawn_timer = .35 }
	local powerup = {
		jack_timer = 0, jack_active = invasion or false, jack_spawn_timer = .05,
		jack_count = 0, jack_total = 20, bh_spawn_timer = 0,
		black_holes = { { active = false }, { active = false } },
		maybe_spawn = function() pickups = pickups + 1 end,
	}
	local environment = {
		state = state, powerup = powerup, math = math, MAX_ENEMIES = 1,
		enemies = { { active = false } }, MAP_W = 2000, MAP_H = 2000,
		multiplayer = { other_alive = function() return guest_alive end },
		spawn_from_edge = function() spawned = spawned + 1 return true end,
		spawn_enemy = function() spawned = spawned + 1 return true end,
	}
	local update = assert(load(spawner, "@game/geometry_wars.lua:update_spawner", "t", environment))()
	update(.1)
	return spawned, pickups, state.game_time, powerup.jack_count
end

for _, players in ipairs { { true, true }, { true, false }, { false, true } } do
	local spawned, pickups, time = run(players[1], players[2])
	assert(spawned == 1, "Spawning stopped while a player was alive")
	assert(pickups == 1 and time == .1, "World timers/pickups stopped while a player was alive")
end
for _, scene in ipairs { "combat", "death", "over", "title" } do
	local spawned, pickups, time = run(false, false, scene)
	assert(spawned == 0 and pickups == 0 and time == 0, "Spawning continued without a live player")
end
for _, scene in ipairs { "death", "over", "title" } do
	local spawned, pickups, time = run(false, true, scene)
	assert(spawned == 0 and pickups == 0 and time == 0, "Spawning continued outside combat")
end
local spawned, _, time, invasion_count = run(false, true, "combat", true)
assert(spawned == 1 and invasion_count == 1 and time == .1, "Invasion stopped after host death")
print "PASS: normal waves, invasion and world timers continue for the surviving player"
