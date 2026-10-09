local lm = require "luamake"

lm.rootdir = lm.basedir / "3rd/skynet"
lm.bindir = tostring(lm.basedir / lm.bindir)
lm:conf {
    c = "c11", includes = { "3rd/lua", "skynet-src" },
    defines = { "NOUSE_JEMALLOC" }, warnings = "on", visibility = "default",
    linux = { defines = { "_GNU_SOURCE" } },
    macos = { defines = { "_DARWIN_C_SOURCE" } },
}
lm:lib "skynet_lua" {
    sources = { "3rd/lua/*.c", "!3rd/lua/lua.c", "!3rd/lua/luac.c", "!3rd/lua/onelua.c", "!3rd/lua/ltests.c" },
    linux = { defines = { "LUA_USE_LINUX" } },
    macos = { defines = { "LUA_USE_MACOSX" } },
}
lm:exe "skynet_bin" {
    basename = "skynet", sources = { "skynet-src/*.c" }, deps = { "skynet_lua" },
    links = { "pthread", "m", "dl" },
    linux = { links = { "rt" }, ldflags = { "-Wl,-E" } },
}
local deps = { "skynet_bin" }
for _, name in ipairs { "snlua", "logger", "gate", "harbor" } do
    local target = "skynet_service_" .. name
    lm:dll(target) {
        basename = name, bindir = lm.bindir .. "/cservice",
        sources = { "service-src/service_" .. name .. ".c" },
    }
    deps[#deps + 1] = target
end
local modules = {
    skynet = { "lualib-src/lua-skynet.c", "lualib-src/lua-seri.c", "lualib-src/lua-socket.c",
        "lualib-src/lua-mongo.c", "lualib-src/lua-netpack.c", "lualib-src/lua-memory.c",
        "lualib-src/lua-multicast.c", "lualib-src/lua-cluster.c", "lualib-src/lua-crypt.c",
        "lualib-src/lsha1.c", "lualib-src/lua-sharedata.c", "lualib-src/lua-stm.c",
        "lualib-src/lua-debugchannel.c", "lualib-src/lua-datasheet.c", "lualib-src/lua-sharetable.c" },
    bson = { "lualib-src/lua-bson.c" },
    md5 = { "3rd/lua-md5/md5.c", "3rd/lua-md5/md5lib.c", "3rd/lua-md5/compat-5.2.c" },
    client = { "lualib-src/lua-clientsocket.c", "lualib-src/lua-crypt.c", "lualib-src/lsha1.c" },
    sproto = { "lualib-src/sproto/sproto.c", "lualib-src/sproto/lsproto.c" },
    lpeg = { "3rd/lpeg/lpcap.c", "3rd/lpeg/lpcode.c", "3rd/lpeg/lpprint.c",
        "3rd/lpeg/lptree.c", "3rd/lpeg/lpvm.c", "3rd/lpeg/lpcset.c" },
}
for _, name in ipairs { "skynet", "bson", "md5", "client", "sproto", "lpeg" } do
    local target = "skynet_module_" .. name
    lm:dll(target) {
        basename = name, bindir = lm.bindir .. "/luaclib", sources = modules[name],
        includes = { "service-src", "lualib-src", "3rd/lua-md5", "lualib-src/sproto" },
        links = name == "client" and { "pthread" } or {},
    }
    deps[#deps + 1] = target
end
lm:phony "skynet" { deps = deps }
