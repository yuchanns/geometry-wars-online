import { copyFile, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'
import { zipSync } from 'fflate'

const websiteDir = fileURLToPath(new URL('..', import.meta.url))
const repoRoot = path.resolve(websiteDir, '..')
const runtimeDir = path.join(websiteDir, 'public/runtime')
const buildDir = path.join(repoRoot, 'bin/web')

async function collectFiles(directory) {
  const files = []
  const entries = await readdir(directory, { withFileTypes: true })
  entries.sort((a, b) => a.name.localeCompare(b.name))
  for (const entry of entries) {
    const filename = path.join(directory, entry.name)
    if (entry.isDirectory())
      files.push(...await collectFiles(filename))
    else if (entry.isFile())
      files.push(filename)
  }
  return files
}

await rm(runtimeDir, { recursive: true, force: true })
await mkdir(runtimeDir, { recursive: true })
for (const name of ['soluna.js', 'soluna.wasm', 'websocket.wasm'])
  await copyFile(path.join(buildDir, name), path.join(runtimeDir, name))

const gameDir = path.join(repoRoot, 'game')
const entries = {}
for (const filename of await collectFiles(gameDir)) {
  const name = path.relative(gameDir, filename).split(path.sep).join('/')
  entries[name] = await readFile(filename)
}
await writeFile(path.join(websiteDir, 'public/main.zip'), zipSync(entries, { level: 9 }))
process.stdout.write(`Prepared Soluna runtime and ${Object.keys(entries).length} game files.\n`)
