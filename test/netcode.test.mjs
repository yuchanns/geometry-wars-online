import test from 'node:test';
import {execFileSync} from 'node:child_process';

test('Lua movement prediction and world interpolation', () => {
  execFileSync('./3rd/soluna/bin/luamake-bin/bin/linux/luamake', ['lua', 'test/netcode.test.lua'], {
    stdio: 'inherit',
  });
});
