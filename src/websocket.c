#include <lua.h>
#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#ifdef __EMSCRIPTEN__
#include <emscripten/websocket.h>
#include <pthread.h>
#else
#include <curl/curl.h>
#endif

/* Browser callbacks run on the browser thread, never inside a Lua state.
 * poll() transfers owned messages to the Soluna service running Lua. */
#define MAX_MESSAGE 1048576
#define MAX_QUEUE 64
#define CLIENT_MT "geometrywars.websocket"
enum { CONNECTING, OPEN, CLOSED };
typedef struct { char *data; size_t size; } message;
typedef struct {
    int state;
    char error[256];
    message queue[MAX_QUEUE];
    unsigned count;
    unsigned char coalesce[256];
#ifdef __EMSCRIPTEN__
    EMSCRIPTEN_WEBSOCKET_T socket;
    pthread_mutex_t mutex;
#else
    CURL *easy;
    CURLM *multi;
    char incoming[MAX_MESSAGE];
    size_t incoming_size;
    message outgoing;
    size_t sent;
#endif
} client;

#ifdef __EMSCRIPTEN__
#define LOCK(c) pthread_mutex_lock(&(c)->mutex)
#define UNLOCK(c) pthread_mutex_unlock(&(c)->mutex)
#else
#define LOCK(c) ((void)(c))
#define UNLOCK(c) ((void)(c))
#endif

static void fail(client *c, const char *reason) {
    c->state = CLOSED;
    snprintf(c->error, sizeof(c->error), "%s", reason);
}

/* Called with the mutex held on WASM. Overflow closes the connection rather
 * than silently losing a protocol message. */
static void enqueue(client *c, const void *data, size_t size) {
    if (size > MAX_MESSAGE) {
        fail(c, "WebSocket message too large");
        return;
    }
    unsigned replace = c->count;
    if (size && c->coalesce[((const unsigned char *)data)[0]]) {
        for (unsigned i = 0; i < c->count; ++i) {
            if (c->queue[i].size && (unsigned char)c->queue[i].data[0] == ((const unsigned char *)data)[0]) {
                replace = i;
                break;
            }
        }
    }
    if (replace == c->count && c->count == MAX_QUEUE) {
        fail(c, "WebSocket receive limit exceeded");
        return;
    }
    char *copy = malloc(size ? size : 1);
    if (!copy) {
        fail(c, "WebSocket allocation failed");
        return;
    }
    memcpy(copy, data, size);
    if (replace < c->count) {
        free(c->queue[replace].data);
        /* Keep the replacement after intervening room control messages. */
        memmove(c->queue + replace, c->queue + replace + 1,
                (c->count - replace - 1) * sizeof(message));
        --c->count;
    }
    c->queue[c->count++] = (message){ copy, size };
}

#ifdef __EMSCRIPTEN__
static bool on_open(int type, const EmscriptenWebSocketOpenEvent *event, void *ud) {
    (void)type; (void)event;
    client *c = ud;
    LOCK(c);
    if (c->state == CONNECTING) c->state = OPEN;
    UNLOCK(c);
    return true;
}

static bool on_message(int type, const EmscriptenWebSocketMessageEvent *event, void *ud) {
    (void)type;
    client *c = ud;
    LOCK(c);
    if (c->state == OPEN)
        enqueue(c, event->data, event->numBytes - (event->isText ? 1 : 0));
    UNLOCK(c);
    return true;
}

static bool on_error(int type, const EmscriptenWebSocketErrorEvent *event, void *ud) {
    (void)type; (void)event;
    client *c = ud;
    LOCK(c);
    fail(c, "Browser WebSocket connection failed");
    UNLOCK(c);
    return true;
}

static bool on_close(int type, const EmscriptenWebSocketCloseEvent *event, void *ud) {
    (void)type;
    client *c = ud;
    LOCK(c);
    c->state = CLOSED;
    if (!c->error[0])
        snprintf(c->error, sizeof(c->error), "Connection closed (%u)", event->code);
    UNLOCK(c);
    return true;
}
#else
/* No socket waits or blocking easy_perform() in a render frame. The easy
 * handle stays in the multi handle after CONNECT_ONLY completes. */
static void pump(client *c) {
    if (c->state == CONNECTING) {
        int running, left;
        CURLMcode result = curl_multi_perform(c->multi, &running);
        if (result != CURLM_OK) { fail(c, curl_multi_strerror(result)); return; }
        CURLMsg *msg;
        while ((msg = curl_multi_info_read(c->multi, &left))) {
            if (msg->msg == CURLMSG_DONE) {
                if (msg->data.result == CURLE_OK) c->state = OPEN;
                else fail(c, curl_easy_strerror(msg->data.result));
            }
        }
    }
    if (c->state != OPEN) return;
    if (c->outgoing.data) {
        size_t sent = 0;
        CURLcode result = curl_ws_send(c->easy, c->outgoing.data + c->sent,
            c->outgoing.size - c->sent, &sent, 0, CURLWS_BINARY);
        c->sent += sent;
        if (result != CURLE_OK && result != CURLE_AGAIN) {
            fail(c, curl_easy_strerror(result)); return;
        }
        if (c->sent == c->outgoing.size) {
            free(c->outgoing.data);
            c->outgoing = (message){0};
            c->sent = 0;
        }
    }
    /* Bound work per frame, including fragmented messages and control frames. */
    for (unsigned i = 0; i < MAX_QUEUE && c->state == OPEN; ++i) {
        char buffer[4096];
        size_t received = 0;
        const struct curl_ws_frame *frame = NULL;
        CURLcode result = curl_ws_recv(c->easy, buffer, sizeof(buffer), &received, &frame);
        if (result == CURLE_AGAIN) break;
        if (result != CURLE_OK) { fail(c, curl_easy_strerror(result)); break; }
        if (frame->flags & CURLWS_CLOSE) { fail(c, "Server closed the connection"); break; }
        if (!(frame->flags & (CURLWS_TEXT | CURLWS_BINARY))) continue;
        if (received > MAX_MESSAGE - c->incoming_size) {
            fail(c, "WebSocket message too large"); break;
        }
        memcpy(c->incoming + c->incoming_size, buffer, received);
        c->incoming_size += received;
        if (!frame->bytesleft && !(frame->flags & CURLWS_CONT)) {
            enqueue(c, c->incoming, c->incoming_size);
            c->incoming_size = 0;
        }
    }
}
#endif

static client **check_ud(lua_State *L) { return luaL_checkudata(L, 1, CLIENT_MT); }

static int l_close(lua_State *L) {
    client **ud = check_ud(L);
    client *c = *ud;
    if (!c) return 0;
#ifdef __EMSCRIPTEN__
    /* Both calls proxy synchronously to the browser thread. delete() removes
     * all handlers before this userdata can be freed. Never hold the mutex
     * across a proxied call. */
    if (c->socket > 0) {
        emscripten_websocket_close(c->socket, 1000, "");
        emscripten_websocket_delete(c->socket);
    }
    pthread_mutex_destroy(&c->mutex);
#else
    if (c->easy) {
        if (c->state == OPEN) {
            unsigned char code[] = { 3, 232 };
            size_t sent;
            (void)curl_ws_send(c->easy, code, 2, &sent, 0, CURLWS_CLOSE);
        }
        if (c->multi) curl_multi_remove_handle(c->multi, c->easy);
        curl_easy_cleanup(c->easy);
    }
    if (c->multi) curl_multi_cleanup(c->multi);
    free(c->outgoing.data);
#endif
    for (unsigned i = 0; i < c->count; ++i) free(c->queue[i].data);
    free(c);
    *ud = NULL;
    return 0;
}

static int l_poll(lua_State *L) {
    client *c = *check_ud(L);
    lua_newtable(L);
    if (!c) return 1;
#ifndef __EMSCRIPTEN__
    pump(c);
#endif
    message batch[MAX_QUEUE];
    LOCK(c);
    unsigned count = c->count;
    memcpy(batch, c->queue, count * sizeof(message));
    c->count = 0;
    UNLOCK(c);
    for (unsigned i = 0; i < count; ++i) {
        lua_pushlstring(L, batch[i].data, batch[i].size);
        free(batch[i].data);
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

static int l_status(lua_State *L) {
    client *c = *check_ud(L);
    if (!c) { lua_pushliteral(L, "closed"); lua_pushliteral(L, ""); return 2; }
    char error[256];
    LOCK(c);
    int state = c->state;
    memcpy(error, c->error, sizeof(error));
    UNLOCK(c);
    lua_pushstring(L, state == OPEN ? "open" : state == CONNECTING ? "connecting" : "closed");
    lua_pushstring(L, error);
    return 2;
}

static int l_send(lua_State *L) {
    client *c = *check_ud(L);
    size_t size;
    const char *data = luaL_checklstring(L, 2, &size);
    luaL_argcheck(L, size > 0 && size <= MAX_MESSAGE, 2, "Expected 1..1048576 bytes");
    if (!c) { lua_pushboolean(L, 0); return 1; }
    LOCK(c);
    int open = c->state == OPEN;
    UNLOCK(c);
    if (!open) { lua_pushboolean(L, 0); return 1; }
#ifdef __EMSCRIPTEN__
    size_t buffered = 0;
    emscripten_websocket_get_buffered_amount(c->socket, &buffered);
    int accepted = buffered < MAX_MESSAGE &&
        emscripten_websocket_send_binary(c->socket, (void *)data, (uint32_t)size) == EMSCRIPTEN_RESULT_SUCCESS;
#else
    int accepted = c->outgoing.data == NULL;
    if (accepted) {
        c->outgoing.data = malloc(size);
        if (!c->outgoing.data) return luaL_error(L, "WebSocket allocation failed");
        memcpy(c->outgoing.data, data, size);
        c->outgoing.size = size;
        pump(c);
    }
#endif
    lua_pushboolean(L, accepted);
    return 1;
}

static int l_connect(lua_State *L) {
    const char *url = luaL_checkstring(L, 1);
    luaL_argcheck(L, !strncmp(url, "ws://", 5) || !strncmp(url, "wss://", 6), 1, "Expected ws:// or wss:// URL");
    size_t latest_size = 0;
    const char *latest = luaL_optlstring(L, 2, "", &latest_size);
    client **ud = lua_newuserdatauv(L, sizeof(*ud), 0);
    *ud = calloc(1, sizeof(client));
    if (!*ud) return luaL_error(L, "WebSocket allocation failed");
    luaL_setmetatable(L, CLIENT_MT);
    client *c = *ud;
    for (size_t i = 0; i < latest_size; ++i) c->coalesce[(unsigned char)latest[i]] = 1;
#ifdef __EMSCRIPTEN__
    pthread_mutex_init(&c->mutex, NULL);
    EmscriptenWebSocketCreateAttributes attributes = { url, NULL, true };
    c->socket = emscripten_websocket_new(&attributes);
    if (c->socket <= 0) { fail(c, "Browser WebSocket unavailable"); return 1; }
    /* Emscripten's current implementation invokes these on the browser thread.
     * Select that thread explicitly and only write to the C message queue. */
    pthread_t thread = EM_CALLBACK_THREAD_CONTEXT_MAIN_RUNTIME_THREAD;
    emscripten_websocket_set_onopen_callback_on_thread(c->socket, c, on_open, thread);
    emscripten_websocket_set_onmessage_callback_on_thread(c->socket, c, on_message, thread);
    emscripten_websocket_set_onerror_callback_on_thread(c->socket, c, on_error, thread);
    emscripten_websocket_set_onclose_callback_on_thread(c->socket, c, on_close, thread);
#else
    c->easy = curl_easy_init();
    c->multi = curl_multi_init();
    if (!c->easy || !c->multi) { fail(c, "libcurl initialization failed"); return 1; }
    CURLcode result = curl_easy_setopt(c->easy, CURLOPT_URL, url);
    if (result == CURLE_OK) result = curl_easy_setopt(c->easy, CURLOPT_CONNECT_ONLY, 2L);
    if (result == CURLE_OK) result = curl_easy_setopt(c->easy, CURLOPT_NOSIGNAL, 1L);
    if (result != CURLE_OK) { fail(c, curl_easy_strerror(result)); return 1; }
    CURLMcode added = curl_multi_add_handle(c->multi, c->easy);
    if (added != CURLM_OK) fail(c, curl_multi_strerror(added));
#endif
    return 1;
}

static int luaopen_websocket(lua_State *L) {
    luaL_newmetatable(L, CLIENT_MT);
    luaL_Reg methods[] = {
        {"poll", l_poll}, {"send", l_send}, {"status", l_status},
        {"close", l_close}, {"__gc", l_close}, {"__close", l_close}, {NULL, NULL}
    };
    luaL_setfuncs(L, methods, 0);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);
    luaL_Reg functions[] = {{"connect", l_connect}, {NULL, NULL}};
    luaL_newlib(L, functions);
    return 1;
}

LUA_API void luaapi_init(lua_State *L);
void materialapi_init(lua_State *L);
int luaopen_ext_material_radial_shape(lua_State *L);
#ifdef _WIN32
#define EXTLUA_EXPORT __declspec(dllexport)
#else
#define EXTLUA_EXPORT __attribute__((visibility("default")))
#endif
EXTLUA_EXPORT int extlua_init(lua_State *L) {
    luaapi_init(L);
    materialapi_init(L);
#ifndef __EMSCRIPTEN__
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK)
        return luaL_error(L, "libcurl initialization failed");
#endif
    luaL_Reg modules[] = {{"ext.websocket", luaopen_websocket}, {"ext.material.radial_shape", luaopen_ext_material_radial_shape}, {NULL, NULL}};
    luaL_newlib(L, modules);
    return 1;
}
