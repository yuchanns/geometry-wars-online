# Third-party sources

- `game/geometry_wars.lua`, `font.lua`, `flow.lua`, `persist.lua`, `utils.lua`,
  `game/service/particle.lua`, and `game/asset/` come
  from [yuchanns/soluna_examples](https://github.com/yuchanns/soluna_examples),
  commit `9eea5b9fd1b77d5b81f04bf50eba36691d2e5ce9`, under Apache-2.0. The
  Geometry Wars example credits [skywind3000/GameSample](https://github.com/skywind3000/GameSample)
  as the original implementation. The game source has been modified to add
  networking and a second player; assets have been retained unchanged.
- `src/radial_shape.c`, `src/radial_shape.glsl` and the corresponding Lua
  material registration originate in the same example project. They have been
  adapted for Soluna's current material API, retaining the original fragment
  shader and shape data format.
- `3rd/soluna/` is a pinned upstream submodule. Its license,
  and those of its dependencies, are retained in the submodule.
- The `ws` package is used by the room integration test and retains its MIT
  license in the installed dependency.

- The Worker uses Hono under MIT and Cloudflare Wrangler under Apache-2.0;
  their licenses are retained in the installed dependencies.

The root `LICENSE` retains the example project's Apache-2.0 license.

- The eight Chinese update-prompt bitmap glyphs in `game/font.lua` are rendered
  from [WenQuanYi Micro Hei](https://wenq.org/wqy2/index.cgi?MicroHei),
  under Apache-2.0.
