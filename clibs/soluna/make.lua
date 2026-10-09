local lm = require "luamake"
local fs = require "bee.filesystem"

local project = lm.basedir
lm.basedir = project / "3rd/soluna"
lm.rootdir = lm.basedir
lm.fs_basedir = fs.path(tostring(lm.basedir))
lm.builddir = tostring(lm.outputdir)
lm.bindir = tostring(project / lm.bindir)
lm.osbindir = tostring(lm.outputdir / "host")
lm.platform = lm.web and "emcc" or (lm.os == "windows"
    and (lm.compiler == "gcc" and "mingw" or lm.cc == "clang-cl" and "clang-cl" or "msvc") or lm.os)
lm:conf { includes = { lm.outputdir } }

lm:conf {
	cxx = "c++20",
	clang = {
		c = "c11",
	},
	flags = {
		lm.mode ~= "debug" and "-O2",
	},
	msvc = {
		c = "c11",
		flags = {
			"-W3",
			"-utf-8",
			"-experimental:c11atomics",
			"/wd4244",
			"/wd4267",
			"/wd4305",
			"/wd4996",
			"/wd4018",
			"/wd4113",
		},
		defines = {
			"_CRT_SECURE_NO_WARNINGS",
			"_CRT_NONSTDC_NO_DEPRECATE",
			"_CRT_SECURE_NO_DEPRECATE"
		},
	},
	mingw = {
		c = "c99",
	},
	gcc = {
		c = "c11",
		flags = {
			"-Wall",
		},
		defines = {
			"_POSIX_C_SOURCE=199309L",
			"_GNU_SOURCE",
		},
		links = {
			"m",
			(lm.os ~= "windows" and lm.platform ~= "emcc") and "fontconfig",
		},
	},
	emcc = {
		c = "gnu11",
		flags = {
			"-Wall",
			"-pthread",
			"-fPIC",
			"--use-port=emdawnwebgpu",
			"-fwasm-exceptions",
		},
		links = {
			"idbfs.js",
		},
		ldflags = {
			"--use-port=emdawnwebgpu",
			"-s ALLOW_MEMORY_GROWTH",
			"-s FORCE_FILESYSTEM=1",
			"-s USE_PTHREADS=1",
			"-fwasm-exceptions",

			lm.mode == "debug" and "-gsource-map",
			lm.mode == "debug" and "-s EXCEPTION_STACK_TRACES=1",
			lm.mode == "debug" and "-s ASSERTIONS=2",
			lm.mode == "debug" and "-s STACK_OVERFLOW_CHECK=1",
			lm.mode == "debug" and "-s PTHREADS_DEBUG=1",
		},
		defines = {
			"_POSIX_C_SOURCE=200809L",
			"_GNU_SOURCE",
		},
	},
	defines = {
		lm.mode == "debug" and "SOKOL_DEBUG",
	}
}


if lm.web then
    -- Shader/Lua headers are generated on the host, even for a WASM build.
    local lua = lm.basedir / "3rd/lua/onelua.c"
    local luaexe = lm.outputdir / (lm.os == "windows" and "host/lua.exe" or "host/lua")
    local command
    if lm.os == "windows" then
        command = { "cl", "/nologo", "/O2", "/std:c11", "/DMAKE_LUA",
            "/D_CRT_SECURE_NO_WARNINGS", lua, "/Fe$out", "/Fo" .. tostring(lm.outputdir / "host/lua.obj") }
    else
        command = { os.getenv "HOST_CC" or "cc", "-O2", "-std=c11", "-DMAKE_LUA",
            "-DLUA_USE_DLOPEN", lua, "-lm", lm.os == "linux" and "-ldl", "-o", "$out" }
    end
    lm:rule "host_lua" { args = command, description = "Build host Lua" }
    lm:build "lua" {
        rule = "host_lua", inputs = { lua, lm.basedir / "3rd/lua/*.h", lm.basedir / "3rd/lua/*.c" },
        outputs = { luaexe },
    }
    lm:source_set "lua_src" {
        sources = { "3rd/lua/onelua.c" }, defines = { "MAKE_LIB", "LUA_USE_DLOPEN" },
    }
else
    lm:import(lm.basedir / "clibs/lua/make.lua")
end

local deps = { "soluna_src", "lua_src" }
for _, name in ipairs { "ltask", "datalist", "zip", "yoga" } do
    lm:import(lm.basedir / ("clibs/" .. name .. "/make.lua"))
    deps[#deps + 1] = name .. "_src"
end
lm:import(lm.basedir / "clibs/soluna/make.lua")

local functions = { "new", "close", "delete", "send_binary", "get_buffered_amount",
    "set_onopen_callback_on_thread", "set_onmessage_callback_on_thread",
    "set_onerror_callback_on_thread", "set_onclose_callback_on_thread" }
local imports, exports = {}, { [=[\"_main\"]=] }
for _, name in ipairs(functions) do
    imports[#imports + 1] = '"emscripten_websocket_' .. name .. '"'
    exports[#exports + 1] = [=[\"_emscripten_websocket_]=] .. name .. [=[\"]=]
end
for _, name in ipairs { "strncmp", "snprintf", "calloc", "malloc", "free",
    "pthread_mutex_lock", "pthread_mutex_unlock", "pthread_mutex_init", "pthread_mutex_destroy",
    "pthread_self", "emscripten_builtin_memalign" } do
    exports[#exports + 1] = [=[\"_]=] .. name .. [=[\"]=]
end
lm:exe "soluna" {
    deps = deps,
    emcc = {
        ldflags = {
            "--js-library=3rd/soluna/src/platform/wasm/soluna_ime.js",
            "--js-library=3rd/soluna/src/platform/wasm/soluna_openurl.js",
            "-lwebsocket.js",
            "-s DEFAULT_LIBRARY_FUNCS_TO_INCLUDE='[" .. table.concat(imports, ",") .. "]'",
            "-s EXPORTED_FUNCTIONS=[" .. table.concat(exports, ",") .. "]",
            "-s MODULARIZE=1", "-s EXPORT_ES6=1", "-s EXPORT_NAME=createApp",
            [=[-s EXPORTED_RUNTIME_METHODS=[\"FS\",\"FS_createPath\",\"FS_createDataFile\",\"IDBFS\"]]=],
            [=[-s "PTHREAD_POOL_SIZE=Math.max(2,navigator.hardwareConcurrency)"]=],
            "-s PTHREAD_POOL_SIZE_STRICT=2", "-s MAIN_MODULE=2",
            "-Wl,-u,emscripten_builtin_memalign", "-Wl,--export=emscripten_builtin_memalign",
        },
    },
}
