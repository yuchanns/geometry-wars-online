local fs = require "bee.filesystem"
local subprocess = require "bee.subprocess"
local kind, bindir, destination, host = ...
bindir, destination = fs.path(bindir), fs.path(destination)

local function read(path)
	local file = assert(io.open(tostring(path), "rb"))
	local data = file:read "a"
	file:close()
	return data
end
local function write(path, data)
	local file = assert(io.open(tostring(path), "wb"))
	file:write(data)
	file:close()
end
local function copy(source, target)
	fs.create_directories(target:parent_path())
	fs.copy_file(source, target, fs.copy_options.overwrite_existing)
end
local files = {}
local function collect(dir)
	for path in fs.pairs(dir) do
		if fs.is_directory(path) then
			collect(path)
		else
			files[#files + 1] = path:string():gsub("\\", "/")
		end
	end
end
collect(fs.path "game")
table.sort(files, function(a, b)
	return a:gsub("/", "\0") < b:gsub("/", "\0")
end)

fs.remove_all(destination)
fs.create_directories(destination)
if kind == "native" then
	local exe = host == "windows" and "soluna.exe" or "soluna"
	local module = host == "windows" and "websocket.dll" or "websocket.so"
	copy(bindir / exe, destination / exe)
	copy(bindir / module, destination / module)
	for _, path in ipairs(files) do
		copy(fs.path(path), destination / path)
	end
else
	local runtime = destination / "runtime"
	fs.create_directories(runtime)
	for path in fs.pairs(bindir) do
		if fs.is_regular_file(path) and path:filename():string():match "^soluna%." then
			copy(path, runtime / path:filename())
		end
	end
	copy(bindir / "websocket.wasm", runtime / "websocket.wasm")
	for _, name in ipairs { "client.js", "style.css", "_headers" } do
		copy(fs.path("website/public/" .. name), destination / name)
	end
	-- Soluna mounts this archive directly, avoiding a request for each game file.
	local args = { "zip", "-q", "-9", "-X", (fs.current_path() / destination / "main.zip"):string() }
	for _, path in ipairs(files) do
		args[#args + 1] = path:sub(6)
	end
	local process = assert(subprocess.spawn {
		args,
		cwd = "game",
		searchPath = true,
		stdout = io.stdout,
		stderr = io.stderr,
	})
	local code = process:wait()
	process:detach()
	assert(code == 0, "Unable to build main.zip; install the zip command")
	-- Match the WebGPU glue fixes in the pinned engine's release action.
	local patches = {
		{ "setBindGroup(groupIndex,group,(growMemViews(),HEAPU32),dynamicOffsetsPtr>>2,dynamicOffsetCount)",
			"setBindGroup(groupIndex,group,(growMemViews(),HEAPU32).subarray(dynamicOffsetsPtr>>2,(dynamicOffsetsPtr>>2)+dynamicOffsetCount))" },
		{ "setBindGroup(groupIndex, group, (growMemViews(), HEAPU32), ((dynamicOffsetsPtr) >> 2), dynamicOffsetCount)",
			"setBindGroup(groupIndex, group, (growMemViews(), HEAPU32).subarray(((dynamicOffsetsPtr) >> 2), ((dynamicOffsetsPtr) >> 2) + dynamicOffsetCount))" },
		{ "var group=WebGPU.getJsObject(groupPtr);if(dynamicOffsetCount==0)",
			"var group=WebGPU.getJsObject(groupPtr);if(!group){return}if(dynamicOffsetCount==0)" },
		{ "var group = WebGPU.getJsObject(groupPtr);\n  if (dynamicOffsetCount == 0)",
			"var group = WebGPU.getJsObject(groupPtr);\n  if (!group) { return; }\n  if (dynamicOffsetCount == 0)" },
	}
	local glue = read(runtime / "soluna.js")
	for _, patch in ipairs(patches) do
		local old, new = patch[1], patch[2]
		local from = 1
		while true do
			local first, last = glue:find(old, from, true)
			if not first then
				break
			end
			glue = glue:sub(1, first - 1) .. new .. glue:sub(last + 1)
			from = first + #new
		end
	end
	write(runtime / "soluna.js", glue)
end
