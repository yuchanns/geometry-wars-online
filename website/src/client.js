import { zipSync } from 'fflate'
import audioFiles from './audio-manifest.json'

const status = document.querySelector('#status')
const canvas = document.querySelector('#canvas')
canvas.addEventListener('pointerdown', () => canvas.focus())
canvas.addEventListener('contextmenu', event => event.preventDefault())
window.geometryWarsLog = []
function log(message) {
  // Soluna writes normal startup and gameplay output through this callback.
  // eslint-disable-next-line no-console
  console.log(message)
  window.geometryWarsLog.push(message)
  if (window.geometryWarsLog.length > 80)
    window.geometryWarsLog.shift()
}

function createProgressReporter(module, id) {
  let published = -Infinity
  let finished = false
  return function progress({ label, current = '', done = 0, total = 0, state = 'loading', error = '' }, force = false) {
    const now = performance.now()
    if (finished || (!force && now - published < 100))
      return
    published = now
    const fields = [id, label, current, done, total, state, error]
    const source = `${fields.map(value => String(value).replace(/[\r\n]/g, ' ')).join('\n')}\n`
    // Replace a complete snapshot so Lua never reads a partially written file.
    module.FS.writeFile('/progress.tmp', source)
    module.FS.rename('/progress.tmp', '/progress')
    finished = state === 'ready' || state === 'failed'
  }
}

async function loadAudio(module) {
  const total = audioFiles.reduce((sum, [, , size]) => sum + size, 0)
  let loaded = 0
  const progress = createProgressReporter(module, 'audio')
  const controller = new AbortController()
  try {
    progress({ label: 'DOWNLOADING AUDIO', total }, true)
    const entries = {}
    let next = 0
    async function download() {
      while (next < audioFiles.length) {
        const [name, url, expectedSize] = audioFiles[next++]
        const response = await fetch(url, { signal: controller.signal })
        if (!response.ok)
          throw new Error(`Could not load ${name}`)
        const reader = response.body.getReader()
        const chunks = []
        let size = 0
        for (;;) {
          const { value, done } = await reader.read()
          if (done)
            break
          chunks.push(value)
          size += value.length
          loaded += value.length
          progress({ label: 'DOWNLOADING AUDIO', current: name.replace(/^asset\//, ''), done: loaded, total })
        }
        if (size !== expectedSize)
          throw new Error(`Incomplete audio file: ${name}`)
        const data = new Uint8Array(size)
        let offset = 0
        for (const chunk of chunks) {
          data.set(chunk, offset)
          offset += chunk.length
        }
        entries[name] = data
      }
    }
    await Promise.all(Array.from({ length: Math.min(4, audioFiles.length) }, download))
    progress({ label: 'PACKING AUDIO' }, true)
    // The audio VFS reopens this registered archive when a sound first plays.
    module.FS.writeFile('/sound.zip', zipSync(entries, { level: 0 }))
    module.FS.writeFile('/sound.ready', new Uint8Array())
    progress({ label: 'AUDIO READY', done: loaded, total, state: 'ready' }, true)
  }
  catch (error) {
    progress({ label: 'DOWNLOADING AUDIO', done: loaded, total, state: 'failed', error: error.message }, true)
    controller.abort()
    console.warn('Audio loading failed.', error)
  }
}

async function startGame() {
  try {
    if (!crossOriginIsolated)
      throw new Error('This server must send COOP/COEP headers for Soluna WASM threads.')
    if (!navigator.gpu)
      throw new Error('Soluna requires a browser with WebGPU support.')
    const { default: createApp } = await import(/* @vite-ignore */ './runtime/soluna.js')
    const archiveResponse = await fetch('/main.zip')
    if (!archiveResponse.ok)
      throw new Error('Could not load main.zip')
    const total = Number(archiveResponse.headers.get('Content-Length'))
    const reader = archiveResponse.body.getReader()
    const chunks = []
    let loaded = 0
    for (;;) {
      const { value, done } = await reader.read()
      if (done)
        break
      chunks.push(value)
      loaded += value.length
      status.textContent = total
        ? `Loading game… ${Math.min(100, Math.round(loaded / total * 100))}%`
        : `Loading game… ${(loaded / 1048576).toFixed(1)} MB`
    }
    const archive = new Uint8Array(loaded)
    let offset = 0
    for (const chunk of chunks) {
      archive.set(chunk, offset)
      offset += chunk.length
    }
    const socketResponse = await fetch('/runtime/websocket.wasm')
    if (!socketResponse.ok)
      throw new Error('Could not load websocket.wasm')
    const files = [
      ['/main.zip', archive],
      ['/sound.zip', zipSync({ 'audio.pending': new Uint8Array() }, { level: 0 })],
      ['/runtime/websocket.wasm', new Uint8Array(await socketResponse.arrayBuffer())],
    ]
    status.textContent = 'Starting game…'
    const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:'
    const endpoint = new URLSearchParams(location.search).get('server') || `${scheme}//${location.host}/ws`
    if (!/^wss?:\/\//.test(endpoint))
      throw new Error('Expected a ws:// or wss:// server URL.')
    window.geometryWarsApp = await createApp({
      canvas,
      arguments: ['zipfile=/main.zip;/sound.zip', 'deferred_audio=1', 'cpath=/runtime/?.wasm', `server=${endpoint}`],
      locateFile: path => new URL(`./runtime/${path}`, location.href).href,
      print: log,
      printErr: (message) => {
        log(message)
        console.error(message)
      },
      preRun: [(module) => {
        for (const [path, data] of files) {
          module.FS_createPath('/', path.slice(1, path.lastIndexOf('/')), true, true)
          module.FS.writeFile(path, data)
        }
      }],
      onAbort: (reason) => {
        status.hidden = false
        status.textContent = `Soluna stopped: ${reason}`
      },
    })
    status.hidden = true
    canvas.focus()
    void loadAudio(window.geometryWarsApp)
  }
  catch (error) {
    status.textContent = error.message
    console.error(error)
  }
}

void startGame()
