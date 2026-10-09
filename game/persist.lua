local datalist = require "soluna.datalist"
local file = require "soluna.file"

local io = io
local os = os
local table = table

local persist = {}

local function quote(value)
	if value:find "%A" then
		return datalist.quote(value)
	elseif value == "" then
		return '""'
	end
	return value
end

local function sort_keys(t)
	local keys = {}
	for key in pairs(t) do
		local key_type = type(key)
		if key_type == "number" or key_type == "string" then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys)
	return keys
end

local function is_list(t)
	local n = #t
	if n == 0 then
		return false
	end
	for i = 1, n do
		if t[i] == nil then
			return false
		end
	end
	return next(t, n) == nil
end

local function write_scalar(f, key, value, indent)
	local value_type = type(value)
	if value_type == "string" then
		f:write(indent, key, ":", quote(value), "\n")
	else
		f:write(indent, key, ":", tostring(value), "\n")
	end
end

local function write_object(f, object, indent)
	local keys = sort_keys(object)
	for _, key in ipairs(keys) do
		local value = object[key]
		local value_type = type(value)
		if value_type == "table" then
			if is_list(value) then
				f:write(indent, key, ":\n")
				for _, item in ipairs(value) do
					f:write(indent, "\t---\n")
					write_object(f, item, indent .. "\t")
				end
			else
				f:write(indent, key, ":\n")
				write_object(f, value, indent .. "\t")
			end
		else
			write_scalar(f, key, value, indent)
		end
	end
end

function persist.load(filename)
	if not file.local_exist(filename) then
		if file.local_exist(filename .. ".save") then
			os.rename(filename .. ".save", filename)
		else
			return false
		end
	end
	return pcall(function()
		return datalist.parse(file.local_load(filename))
	end)
end

function persist.save(filename, data)
	local f <close>, err = io.open(filename .. ".saving", "wb")
	if not f then
		return false, err
	end
	write_object(f, data, "")
	f:close()
	os.remove(filename .. ".save")
	os.rename(filename .. ".saving", filename .. ".save")
	os.remove(filename)
	os.rename(filename .. ".save", filename)
	return true
end

return persist
