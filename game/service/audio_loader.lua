local ltask = require "ltask"
local file = require "soluna.file"

local owner = ...

-- Check deferred audio outside the game service and notify it only once.
ltask.fork(function()
	while not file.local_exist "/sound.ready" do
		ltask.sleep(10)
	end
	ltask.send(owner, "_audio_ready")
	ltask.quit()
end)

return {}
