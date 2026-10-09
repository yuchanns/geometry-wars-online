# Geometry Wars Online

A two-player online version of the Geometry Wars example from
[yuchanns/soluna_examples](https://github.com/yuchanns/soluna_examples), built with
[Soluna](https://github.com/cloudwu/soluna) and [Skynet](https://github.com/cloudwu/skynet).

The original game supplies the artwork, player and bullet colors, weapons, enemy
AI, sounds, particles, grid effects and HUD. Each player has their own camera.
Players create a room, join through the room list, and wait for the host to start.
A game requires two players. Room actions and gameplay messages use WebSocket.

## Build

```sh
git clone --recurse-submodules https://github.com/yuchanns/geometry-wars-online.git
cd geometry-wars-online
```

Requirements: Python 3, CMake 3.24+, a C compiler, and Soluna's native build
requirements. Native clients also require libcurl 8.16+ built with WebSocket
support (`ws` and `wss` in `curl --version`). Install a recent curl through your
platform's package manager or build curl from source. CMake can be pointed at
that installation with `--cmake-option=-DCMAKE_PREFIX_PATH=/path/to/curl`.

```sh
python3 scripts/build.py native
```

The native output is `dist/native/`. On Windows the executable is `soluna.exe`
and the extension is `websocket.dll`; Linux and macOS use `soluna` and
`websocket.so`. A Windows build uses Soluna's bundled luamake and its compiler
toolchain; run the command from a development shell where those tools are on PATH.
An existing compatible Soluna checkout can be selected with `--soluna /path/to/soluna`.

For the browser client, activate the Emscripten SDK first:

```sh
python3 scripts/build.py web
```

The browser needs WebGPU and a secure origin, such as localhost or HTTPS. The
included HTTP server sends the COOP/COEP headers needed by the WASM threads.
Check that the browser actually selects a hardware WebGPU adapter: a software
adapter such as SwiftShader can make the original game run slowly too.
Linux Chromium builds may require enabling Vulkan as described in the
[WebGPU implementation status](https://github.com/gpuweb/gpuweb/wiki/Implementation-Status).

## Run

Build Skynet and start the room server from the repository root:

```sh
make -C server/skynet linux
server/skynet/skynet server/config
```

On macOS use `make -C server/skynet macosx`. Skynet runs on Linux or macOS;
Windows clients connect to a server running on either platform. The server
listens on port 8788; change `ws_port` in `server/config` if needed.

Start a native client from its output directory:

```sh
cd dist/native
./soluna game/main.game 'cpath=./?.so' server=ws://127.0.0.1:8788/ws
```

On Windows use `soluna.exe game/main.game cpath=./?.dll` with the same `server`
argument. For a second computer, replace `127.0.0.1` with the room server's address.
Use WASD or the arrow keys to move, and the mouse to aim and shoot.

To play in a browser, run the static server in another terminal:

```sh
npm ci
npm start
```

Open <http://localhost:8787/>. A different room server can be selected with
`?server=ws://server-address:8788/ws`. When hosting the page over HTTPS, expose
the room server through a TLS reverse proxy and use a `wss://` endpoint.

Create a room in one client, join it from the second, then click **START GAME**
as the host. Closing a client ends the current game and leaves the other player
waiting in the room for a new partner. **CONTINUE** after a game returns to the
room so the host can start again.

## Implementation

`extlua/websocket.c` provides the same Lua API on native and WASM:

```lua
local websocket = require "ext.websocket"
local socket = websocket.connect("ws://127.0.0.1:8788/ws", string.char(2, 3))
local state, reason = socket:status()
local messages = socket:poll()
socket:send(binary_message)
socket:close()
```

The optional second argument lists message prefixes for which only the newest
pending message is needed. The game uses it for input and state packets; room
control messages remain ordered. Browser callbacks queue data safely and never
call into a Lua state. Native connections use nonblocking libcurl.

Skynet manages the rooms and relays messages only between the two players in a
started room. The host runs the original game simulation, receives the guest's
input and publishes the world state and original effect events. The guest uses
the original movement, shooting and rendering between snapshots, corrects its
predicted player against the host state, interpolates the other player, and
follows its own camera. Collisions, spawning and scores remain host decisions.
This is a cooperative
hosted game; the host controls simulation outcomes.

The original radial-shape fragment shader and packed shape format are retained;
the extension is adapted to the pinned Soluna material API. Soluna itself is
included as an unchanged, pinned submodule.

## Validation

Linux native and WASM clients have been built and exercised together locally.
The native Windows and macOS paths are supplied but have not been run locally.
In the local browser comparison, enabling the Intel hardware adapter raised
the original single-player game from roughly 36–38 FPS to 59–60 FPS; the online
host averaged approximately 57 FPS. These are local measurements, not a guarantee
for other machines. Pausing state packets verified that the guest kept moving
and firing, and an eight-second frozen page recovered after 104 incoming packets
without overflowing its receive queue.
The real Skynet room integration test checks the two-player requirement, join
rules, relay isolation, restart and disconnect handling:

```sh
npm ci
npm test
```

See [THIRD_PARTY.md](THIRD_PARTY.md) for source and license attribution.
