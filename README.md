# Geometry Wars Online

<div align="center">

<strong><a href="https://geometry-wars.yuchanns.xyz">>> Play Online <<</a></strong>

</div>

Two-player co-op shooter using [Soluna](https://github.com/cloudwu/soluna) and Cloudflare Workers.

Play at <https://geometry-wars.yuchanns.xyz/> with WebGPU. Create a room, join from another client, then click **START GAME**. Move with WASD/arrows; aim and shoot with the mouse.

Build on Linux (C/C++ compiler and libcurl with WebSocket support):

```sh
git clone --recurse-submodules https://github.com/yuchanns/geometry-wars-online.git
cd geometry-wars-online
(cd 3rd/soluna && ./bin/luamake-bin/bin/linux/luamake -mode release soluna)
./3rd/soluna/bin/luamake-bin/bin/linux/luamake -mode release
cd dist/native
./soluna game/main.game 'cpath=./?.so'
```

For the browser client and local Worker, activate Emscripten and install `zip`, then run from the repository root:

```sh
(cd 3rd/soluna && ./bin/luamake-bin/bin/linux/luamake -mode release soluna && ./bin/luamake-bin/bin/linux/luamake -mode release -compiler emcc)
./3rd/soluna/bin/luamake-bin/bin/linux/luamake -mode release -compiler emcc
cd website
pnpm install
pnpm start
```

Open <http://localhost:8789/>. To connect the native client to this local server, append `server=ws://127.0.0.1:8789/ws` to its launch command.

[Source and license credits](THIRD_PARTY.md).
