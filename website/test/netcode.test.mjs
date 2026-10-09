import { execFileSync } from 'node:child_process'
// eslint-disable-next-line test/no-import-node-test -- These tests run with node --test.
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const projectRoot = fileURLToPath(new URL('../..', import.meta.url))

test('Lua movement prediction and world interpolation', () => {
  execFileSync('luamake', ['lua', 'test/netcode.test.lua'], {
    stdio: 'inherit',
    cwd: projectRoot,
  })
})
