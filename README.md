# Geometry Wars Online

Two-player co-op shooter using [Soluna](https://github.com/cloudwu/soluna) and [Skynet](https://github.com/cloudwu/skynet).

Build on Linux (C/C++ compiler and libcurl with WebSocket support):

```sh
git clone --recurse-submodules https://github.com/yuchanns/geometry-wars-online.git
cd geometry-wars-online
./3rd/soluna/bin/luamake-bin/bin/linux/luamake
```

Start the server and client in separate terminals:

```sh
./bin/native/skynet server/config
```
```sh
cd dist/native
./soluna game/main.game 'cpath=./?.so' server=ws://127.0.0.1:8788/ws
```

For the browser client, activate Emscripten, then:

```sh
./3rd/soluna/bin/luamake-bin/bin/linux/luamake -compiler emcc
npm ci
npm start
```

Open <http://localhost:8787/> with WebGPU. Create a room, join from another client, then click **START GAME**. Move with WASD/arrows; aim and shoot with the mouse.

[Source and license credits](THIRD_PARTY.md).
