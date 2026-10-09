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
      ['/runtime/websocket.wasm', new Uint8Array(await socketResponse.arrayBuffer())],
    ]
    status.textContent = 'Starting game…'
    const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:'
    const endpoint = new URLSearchParams(location.search).get('server') || `${scheme}//${location.host}/ws`
    if (!/^wss?:\/\//.test(endpoint))
      throw new Error('Expected a ws:// or wss:// server URL.')
    window.geometryWarsApp = await createApp({
      canvas,
      arguments: ['zipfile=/main.zip', 'cpath=/runtime/?.wasm', `server=${endpoint}`],
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
  }
  catch (error) {
    status.textContent = error.message
    console.error(error)
  }
}

void startGame()
