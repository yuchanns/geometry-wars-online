# Development

Geometry Wars Online uses [Soluna](https://github.com/cloudwu/soluna) and Cloudflare Workers. To play without building, [open the online game](https://geometry-wars.yuchanns.xyz/).

## Native Client

Build on Linux (C/C++ compiler and libcurl with WebSocket support):

```sh
git clone --recurse-submodules https://github.com/yuchanns/geometry-wars-online.git
cd geometry-wars-online
./3rd/soluna/bin/luamake-bin/bin/linux/luamake
cd dist/native
./soluna game/main.game 'cpath=./?.so'
```

## Browser Client and Local Server

Activate Emscripten and run from the repository root:

```sh
./3rd/soluna/bin/luamake-bin/bin/linux/luamake -compiler emcc
cd website
pnpm install
pnpm run build
pnpm start
```

Open <http://localhost:8789/>. To connect the native client to this local server, append `server=ws://127.0.0.1:8789/ws` to its launch command.
