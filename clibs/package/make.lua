local lm = require "luamake"
local fs = require "bee.filesystem"

lm.rootdir = lm.basedir
local basedir = fs.path(tostring(lm.basedir))
local destination = "dist/native"
local platform = lm.os == "windows" and "msvc" or lm.os
local exe = lm.os == "windows" and "soluna.exe" or "soluna"
local module = lm.os == "windows" and "websocket.dll" or "websocket.so"
local engine = os.getenv "SOLUNA_PATH" or ("3rd/soluna/bin/" .. platform .. "/release/" .. exe)
local outputs = { destination .. "/" .. exe, destination .. "/" .. module }

local function collect(directory)
	for path in fs.pairs(basedir / directory) do
		if fs.is_directory(path) then
			collect(fs.relative(path, basedir):string())
		else
			outputs[#outputs + 1] = destination .. "/" .. fs.relative(path, basedir):string()
		end
	end
end
collect "game"

lm:runlua "client" {
	script = "clibs/package/package.lua",
	deps = { "websocket" },
	inputs = { "game/**/*", engine },
	outputs = outputs,
	args = { lm.bindir, destination, lm.os, engine },
}
