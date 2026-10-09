# Geometry Wars Online

A two-player co-op shooter built with [Soluna](https://github.com/cloudwu/soluna)
and [Skynet](https://github.com/cloudwu/skynet).

## Build

Requires a C/C++ compiler, Soluna's platform dependencies, and libcurl 8.16+
with WebSocket support. The browser build also requires Emscripten.
Skynet runs on Linux or macOS.

```sh
git clone --recurse-submodules https://github.com/yuchanns/geometry-wars-online.git
cd geometry-wars-online
./3rd/soluna/bin/luamake-bin/bin/linux/luamake
# Browser client (activate the Emscripten SDK first):
./3rd/soluna/bin/luamake-bin/bin/linux/luamake -compiler emcc
```

On macOS replace `linux` with `osx_arm64` or `osx`; on Windows use
`win32/luamake.exe`.
Native clients are packaged in `dist/native/`; browser files in `dist/web/`.

## Run

Start the room server from the repository root:

```sh
./bin/native/skynet server/config
```

Native client, in another terminal:

```sh
cd dist/native
./soluna game/main.game 'cpath=./?.so' server=ws://127.0.0.1:8788/ws
```

On Windows use `soluna.exe` and `cpath=./?.dll`.

Browser client:

```sh
npm ci
npm start
```

Open <http://localhost:8787/> in a browser with WebGPU. To connect to another
server, use `?server=ws://server-address:8788/ws` (or `wss://` over HTTPS).

Create a room, join from a second client, then click **START GAME** as the host.
Move with WASD or arrow keys; aim and shoot with the mouse.

Run room integration tests with `npm test` after building Skynet.
Source and license credits: [THIRD_PARTY.md](THIRD_PARTY.md).
