local progress = {}
progress.__index = progress

function progress.new()
	return setmetatable({}, progress)
end

-- Resource producers share the same fields, while keeping their own units.
function progress:update(id, fields)
	local stage
	for _, item in ipairs(self) do
		if item.id == id then
			stage = item
			break
		end
	end
	if not stage then
		stage = { id = id, done = 0, total = 0, current = "", ready = false }
		self[#self + 1] = stage
	end
	for key, value in pairs(fields) do
		stage[key] = value
	end
	return stage
end

function progress:current()
	for _, stage in ipairs(self) do
		if stage.error then
			return stage
		end
	end
	for _, stage in ipairs(self) do
		if not stage.ready then
			return stage
		end
	end
end

function progress:complete()
	return self:current() == nil
end

return progress
