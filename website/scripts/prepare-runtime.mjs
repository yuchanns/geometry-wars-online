import { createHash } from 'node:crypto'
import { copyFile, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'
import { zipSync } from 'fflate'

const websiteDir = fileURLToPath(new URL('..', import.meta.url))
const repoRoot = path.resolve(websiteDir, '..')
const runtimeDir = path.join(websiteDir, 'public/runtime')
const audioDir = path.join(websiteDir, 'public/audio')
const buildDir = path.join(repoRoot, 'bin/web')
const engineDir = path.join(repoRoot, '3rd/soluna/bin/emcc/release')

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
for (const [name, source] of [
  ['soluna.js', process.env.SOLUNA_JS_PATH || path.join(engineDir, 'soluna.js')],
  ['soluna.wasm', process.env.SOLUNA_WASM_PATH || path.join(engineDir, 'soluna.wasm')],
  ['websocket.wasm', path.join(buildDir, 'websocket.wasm')],
]) {
  await copyFile(source, path.join(runtimeDir, name))
}

const gameDir = path.join(repoRoot, 'game')
const entries = {}
const audioFiles = []
await rm(audioDir, { recursive: true, force: true })
await mkdir(audioDir, { recursive: true })
for (const filename of await collectFiles(gameDir)) {
  const name = path.relative(gameDir, filename).split(path.sep).join('/')
  const data = await readFile(filename)
  if (path.extname(name) === '.wav') {
    const hash = createHash('sha256').update(data).digest('hex').slice(0, 12)
    const audioName = name.replace(/^asset\//, '').replace(/\.wav$/, `.${hash}.wav`)
    const destination = path.join(audioDir, audioName)
    await mkdir(path.dirname(destination), { recursive: true })
    await writeFile(destination, data)
    audioFiles.push([name, `/audio/${audioName}`, data.length])
  }
  else {
    entries[name] = data
  }
}
await writeFile(path.join(websiteDir, 'public/main.zip'), zipSync(entries, { level: 9 }))
await writeFile(path.join(websiteDir, 'src/audio-manifest.json'), `${JSON.stringify(audioFiles, null, 2)}\n`)
process.stdout.write(`Prepared Soluna runtime, ${Object.keys(entries).length} game files and ${audioFiles.length} individual audio files.\n`)
