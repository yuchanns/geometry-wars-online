local lm = require "luamake"
local platform = require "bee.platform"

lm.rootdir = lm.basedir
local engine = lm.basedir / "3rd/soluna"
local host = lm.os == "windows" and "win32" or lm.os == "macos"
	and (platform.Arch == "arm64" and "osx_arm64" or "osx") or "linux"
local shader = lm.outputdir / "radial_shape.glsl.h"
local lang = lm.web and "wgsl" or lm.os == "windows" and "hlsl4"
	or lm.os == "macos" and "metal_macos" or "glsl430"
lm:runlua "radial_shape_shader" {
	script = engine / "clibs/soluna/shader2c.lua",
	inputs = { "src/radial_shape.glsl" },
	outputs = { shader },
	args = { engine / ("bin/sokol-tools-bin/bin/" .. host .. "/sokol-shdc" .. (lm.os == "windows" and ".exe" or "")),
		"$in", "$out", lang },
}
lm:dll "websocket" {
	sources = { "src/websocket.c", "src/radial_shape.c",
		"3rd/soluna/extlua/extlua.c", "3rd/soluna/extlua/materialapi.c" },
	objdeps = { "radial_shape_shader" },
	includes = { engine / "3rd/lua", engine / "3rd", engine / "extlua", lm.outputdir },
	warnings = "all",
	links = not lm.web and { lm.os == "windows" and "libcurl" or "curl" } or {},
	emcc = { flags = { "-pthread", "-fPIC", "-fwasm-exceptions" },
		ldflags = { "-pthread", "-fwasm-exceptions" } },
}
