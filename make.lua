local lm = require "luamake"
local fs = require "bee.filesystem"

lm:required_version "1.11"
lm.basedir = fs.current_path()
lm.web = lm.compiler == "emcc"
lm.builddir = lm.web and "build/web" or "build/native"
lm.bindir = "src/bin"
lm.outputdir = lm.basedir / lm.builddir
lm:conf { c = "c11", cxx = "c++20", emcc = { c = "gnu11" } }

lm:import "clibs/websocket/make.lua"
if lm.web then
	lm:default "websocket"
else
	lm:import "clibs/package/make.lua"
	lm:default "client"
end
