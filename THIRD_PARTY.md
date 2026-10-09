# Third-party sources

- `game/geometry_wars.lua`, `font.lua`, `flow.lua`, `persist.lua`, `utils.lua`,
  `game/service/geometry_wars/particle.lua`, and `game/asset/geometry_wars/` come
  from [yuchanns/soluna_examples](https://github.com/yuchanns/soluna_examples),
  commit `9eea5b9fd1b77d5b81f04bf50eba36691d2e5ce9`, under Apache-2.0. The
  Geometry Wars example credits [skywind3000/GameSample](https://github.com/skywind3000/GameSample)
  as the original implementation. The game source has been modified to add
  networking and a second player; assets have been retained unchanged.
- `extlua/radial_shape.c`, `extlua/radial_shape.glsl` and the corresponding Lua
  material registration originate in the same example project. They have been
  adapted for Soluna's current material API, retaining the original fragment
  shader and shape data format.
- `3rd/soluna/` and `3rd/skynet/` are pinned upstream submodules. Their licenses,
  and those of their own dependencies, are retained in those submodules.
- The `ws` npm package is used by the room integration test and retains its MIT
  license in the installed dependency.

The root `LICENSE` retains the example project's Apache-2.0 license.
