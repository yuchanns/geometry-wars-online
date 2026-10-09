local lm = require "luamake"
local fs = require "bee.filesystem"

lm.rootdir = lm.basedir
local basedir = fs.path(tostring(lm.basedir))
local destination = lm.web and "dist/web" or "dist/native"
local outputs = {}
if lm.web then
	outputs = {
		destination .. "/main.zip",
		destination .. "/client.js",
		destination .. "/style.css",
		destination .. "/_headers",
		destination .. "/runtime/soluna.js",
		destination .. "/runtime/soluna.wasm",
		destination .. "/runtime/websocket.wasm"
	}
else
	outputs = { destination .. (lm.os == "windows" and "/soluna.exe" or "/soluna"),
		destination .. (lm.os == "windows" and "/websocket.dll" or "/websocket.so") }
	local function collect(dir)
		for path in fs.pairs(basedir / dir) do
			if fs.is_directory(path) then
				collect(fs.relative(path, basedir):string())
			else
				outputs[#outputs + 1] = destination .. "/" .. fs.relative(path, basedir):string()
			end
		end
	end
	collect "game"
end
lm:runlua "client" {
	script = "clibs/package/package.lua",
	deps = { "soluna", "websocket" },
	inputs = { "game/**/*", "website/public/client.js", "website/public/style.css", "website/public/_headers" },
	outputs = outputs,
	args = { lm.web and "web" or "native", lm.bindir, destination, lm.os },
}
