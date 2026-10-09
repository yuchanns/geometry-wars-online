local coroutine = require "soluna.coroutine"
local debug = debug

local flow = {}

local states
local current = {
	state = nil,
	thread = nil,
}

function flow.load(definitions)
	states = definitions
	local checker = {}
	for name in pairs(definitions) do
		checker[name] = name
	end
	flow.state = setmetatable(checker, {
		__index = function(_, key)
			error("Invalid state name " .. tostring(key))
		end,
	})
end

function flow.enter(state, args)
	assert(states, "Call flow.load() first")
	assert(current.thread == nil, "Running state")
	local fn = states[state] or error("Missing state " .. tostring(state))
	current.state = state
	current.thread = coroutine.create(function()
		local next_state, next_args = fn(args)
		return "NEXT", next_state, next_args
	end)
end

function flow.current()
	return current.state
end

function flow.sleep(tick)
	coroutine.yield("SLEEP", tick)
end

local function sleep(thread, tick)
	coroutine.yield()
	for _ = 1, tick - 1 do
		coroutine.yield "YIELD"
	end
	return "RESUME", thread
end

local command = {}

function command.NEXT(state, args)
	current.thread = nil
	if state ~= nil then
		flow.enter(state, args)
	else
		current.state = nil
	end
end

function command.SLEEP(tick)
	if tick <= 0 then
		return
	end
	local thread = current.thread
	current.thread = coroutine.create(sleep)
	coroutine.resume(current.thread, thread, tick)
end

function command.YIELD()
end

function command.RESUME(thread)
	current.thread = thread
end

local function update_process(thread)
	local ok, cmd, arg1, arg2 = coroutine.resume(thread)
	if ok then
		command[cmd](arg1, arg2)
	else
		error(tostring(cmd) .. "\n" .. debug.traceback(thread))
	end
end

function flow.update()
	if current.thread then
		update_process(current.thread)
	end
	return current.state
end

return flow
