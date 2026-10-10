import { execFileSync } from 'node:child_process'
// eslint-disable-next-line test/no-import-node-test -- These tests run with node --test.
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const projectRoot = fileURLToPath(new URL('../..', import.meta.url))

test('Lua prediction, projectile compensation and snapshot protocol', () => {
  execFileSync(`${projectRoot}/3rd/soluna/bin/luamake-bin/bin/linux/luamake`, ['lua', 'test/netcode.test.lua'], {
    stdio: 'inherit',
    cwd: projectRoot,
  })
})

test('World spawning continues after host death while the guest is alive', () => {
  execFileSync(`${projectRoot}/3rd/soluna/bin/luamake-bin/bin/linux/luamake`, ['lua', 'test/spawner.test.lua'], {
    stdio: 'inherit',
    cwd: projectRoot,
  })
})
