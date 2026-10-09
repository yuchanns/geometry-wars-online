# Geometry Wars Online

Two-player co-op shooter using [Soluna](https://github.com/cloudwu/soluna) and Cloudflare Workers.

Play at <https://geometry-wars.yuchanns.xyz/> with WebGPU. Create a room, join from another client, then click **START GAME**. Move with WASD/arrows; aim and shoot with the mouse.

Build on Linux (C/C++ compiler and libcurl with WebSocket support):

```sh
git clone --recurse-submodules https://github.com/yuchanns/geometry-wars-online.git
cd geometry-wars-online
./3rd/soluna/bin/luamake-bin/bin/linux/luamake
cd dist/native
./soluna game/main.game 'cpath=./?.so'
```

For the browser client and local Worker, activate Emscripten and install `zip`, then run from the repository root:

```sh
./3rd/soluna/bin/luamake-bin/bin/linux/luamake -compiler emcc
pnpm install
pnpm start
```

Open <http://localhost:8789/>. To connect the native client to this local server, append `server=ws://127.0.0.1:8789/ws` to its launch command.

Pushes to `main` build the browser client, test rooms, and deploy through GitHub Actions. Set the repository secret `CLOUDFLARE_API_TOKEN` and your account/domain in `wrangler.jsonc`.

[Source and license credits](THIRD_PARTY.md).
