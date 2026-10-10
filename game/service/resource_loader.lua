local ltask = require "ltask"
local file = require "soluna.file"

local owner = ...

-- JS publishes seven newline-delimited fields through the local filesystem:
-- stage, label, resource, completed units, total units, state, error.
ltask.fork(function()
	local previous
	while true do
		local ok, source = pcall(file.local_load, "/progress")
		if ok and source and source ~= previous then
			local fields = {}
			for value in source:gmatch("([^\n]*)\n") do
				fields[#fields + 1] = value
			end
			if #fields == 7 then
				previous = source
				local state = fields[6]
				ltask.send(owner, "_resource_progress", {
					id = fields[1],
					label = fields[2],
					current = fields[3],
					done = tonumber(fields[4]) or 0,
					total = tonumber(fields[5]) or 0,
					ready = state == "ready",
					error = state == "failed" and fields[7] or nil,
				})
				if state == "ready" or state == "failed" then
					ltask.quit()
					return
				end
			end
		end
		ltask.sleep(10)
	end
end)

return {}
