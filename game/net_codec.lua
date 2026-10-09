-- Binary table encoding shared by the game clients and the room server.
local M = {}

local function encode(value, chunks, depth)
	assert(depth < 12, "Packet nesting too deep")
	local value_type = type(value)
	if value_type == "nil" then
		chunks[#chunks + 1] = "\0"
	elseif value_type == "boolean" then
		chunks[#chunks + 1] = value and "\2" or "\1"
	elseif value_type == "number" then
		chunks[#chunks + 1] = "\3" .. string.pack("<d", value)
	elseif value_type == "string" then
		chunks[#chunks + 1] = "\4" .. string.pack("<I2", #value) .. value
	elseif value_type == "table" then
		local count = 0
		for key, item in pairs(value) do
			if type(item) ~= "function" and (type(key) == "string" or type(key) == "number") then
				count = count + 1
			end
		end
		chunks[#chunks + 1] = "\5" .. string.pack("<I2", count)
		for key, item in pairs(value) do
			if type(item) ~= "function" and (type(key) == "string" or type(key) == "number") then
				encode(key, chunks, depth + 1)
				encode(item, chunks, depth + 1)
			end
		end
	else
		error("Unsupported packet value: " .. value_type)
	end
end

function M.encode(value)
	local chunks = {}
	encode(value, chunks, 0)
	local result = table.concat(chunks)
	assert(#result <= 1048575, "Packet too large")
	return result
end

local function decode(data, offset, depth, budget)
	assert(depth < 12 and budget[1] < 50000, "Packet complexity limit")
	budget[1] = budget[1] + 1
	local tag = data:byte(offset)
	offset = offset + 1
	if tag == 0 then
		return nil, offset
	elseif tag == 1 then
		return false, offset
	elseif tag == 2 then
		return true, offset
	elseif tag == 3 then
		local value
		value, offset = string.unpack("<d", data, offset)
		assert(value == value and math.abs(value) < math.huge, "Invalid number")
		return value, offset
	elseif tag == 4 then
		local size
		size, offset = string.unpack("<I2", data, offset)
		assert(offset + size - 1 <= #data, "Truncated string")
		return data:sub(offset, offset + size - 1), offset + size
	elseif tag == 5 then
		local size
		size, offset = string.unpack("<I2", data, offset)
		local result = {}
		for _ = 1, size do
			local key, value
			key, offset = decode(data, offset, depth + 1, budget)
			value, offset = decode(data, offset, depth + 1, budget)
			assert(type(key) == "string" or type(key) == "number", "Invalid key")
			result[key] = value
		end
		return result, offset
	end
	error "Invalid packet tag"
end

function M.decode(data)
	assert(#data <= 1048575, "Packet too large")
	local result, offset = decode(data, 1, 0, { 0 })
	assert(offset == #data + 1, "Trailing packet data")
	return result
end

return M
