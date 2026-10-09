local lm = require "luamake"
local engine = os.getenv("SOLUNA_DIR") or "../soluna"
-- Soluna includes its default build/ path; prefer the headers generated for
-- this build so a desktop checkout cannot supply GLSL headers to a WGSL build.
lm:conf { includes = { lm:path(lm.builddir) } }
-- Import the engine unchanged. MAIN_MODULE=2 requires explicitly retaining the
-- JavaScript imports used by the dynamically loaded websocket.wasm extension.
local define_exe = lm.exe
lm.exe = function(self, name)
    local define = define_exe(self, name)
    return function(attributes)
        if name == "soluna" then
            local flags = attributes.emcc.ldflags
            flags[#flags + 1] = "-lwebsocket.js"
            local imports = {
                "new", "close", "delete", "send_binary", "get_buffered_amount",
                "set_onopen_callback_on_thread", "set_onmessage_callback_on_thread",
                "set_onerror_callback_on_thread", "set_onclose_callback_on_thread",
            }
            local names = {}
            for _, suffix in ipairs(imports) do
                names[#names + 1] = '"emscripten_websocket_' .. suffix .. '"'
            end
            flags[#flags + 1] = "-s DEFAULT_LIBRARY_FUNCS_TO_INCLUDE='[" .. table.concat(names, ",") .. "]'"
            local exports = { '\\"_main\\"' }
            for _, suffix in ipairs(imports) do
                exports[#exports + 1] = '\\"_emscripten_websocket_' .. suffix .. '\\"'
            end
            for _, name in ipairs {
                "strncmp", "snprintf", "calloc", "malloc", "free",
                "pthread_mutex_lock", "pthread_mutex_unlock", "pthread_mutex_init",
                "pthread_mutex_destroy", "pthread_self", "emscripten_builtin_memalign",
            } do
                exports[#exports + 1] = '\\"_' .. name .. '\\"'
            end
            flags[#flags + 1] = "-s EXPORTED_FUNCTIONS=[" .. table.concat(exports, ",") .. "]"
        end
        return define(attributes)
    end
end
lm:import(engine .. "/make.lua")
lm:default "soluna"
