import { Hono } from 'hono'
import { html } from 'hono/html'

export { Lobby, Room } from './rooms'
const app = new Hono<{ Bindings: Env }>()
app.use('*', async (c, next) => {
  await next()
  if (c.res.status !== 101) {
    c.header('Cross-Origin-Opener-Policy', 'same-origin')
    c.header('Cross-Origin-Embedder-Policy', 'require-corp')
  }
})
app.get('/', (c) => {
  const page = (
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Geometry Wars</title>
        <link rel="stylesheet" href="/style.css" />
        <script defer src="https://stateflare.yuchanns.xyz/track.js"></script>
      </head>
      <body>
        <a
          class="source"
          href="https://github.com/yuchanns/geometry-wars-online"
          target="_blank"
          rel="noopener noreferrer"
          aria-label="Source on GitHub"
          title="Source on GitHub"
        >
          <svg
            viewBox="0 0 24 24"
            width="24"
            height="24"
            aria-hidden="true"
          >
            <path
              fill="currentColor"
              d="M12 .5a12 12 0 0 0-3.79 23.38c.6.11.82-.26.82-.58v-2.24c-3.34.73-4.04-1.42-4.04-1.42-.55-1.39-1.34-1.76-1.34-1.76-1.09-.75.08-.73.08-.73 1.2.08 1.83 1.23 1.83 1.23 1.07 1.83 2.81 1.3 3.5.99.11-.77.42-1.3.76-1.6-2.67-.3-5.47-1.34-5.47-5.93 0-1.31.47-2.38 1.23-3.22-.12-.3-.53-1.52.12-3.18 0 0 1.01-.32 3.3 1.23a11.5 11.5 0 0 1 6 0c2.29-1.55 3.3-1.23 3.3-1.23.65 1.66.24 2.88.12 3.18.77.84 1.23 1.91 1.23 3.22 0 4.6-2.8 5.63-5.48 5.92.43.37.82 1.1.82 2.22v3.32c0 .32.22.69.83.58A12 12 0 0 0 12 .5Z"
            />
          </svg>
        </a>
        <main>
          <canvas
            id="canvas"
            width="1080"
            height="810"
            tabIndex={0}
            aria-label="Geometry Wars. WASD to move; mouse to aim and shoot."
          />
        </main>
        <p id="status" role="status">Loading Soluna…</p>
        <script type="module" src="/client.js"></script>
      </body>
    </html>
  )
  return c.html(html`<!doctype html>${page}`)
})
app.get('/ws', async (c) => {
  if (c.req.header('Upgrade')?.toLowerCase() !== 'websocket')
    return c.text('WebSocket upgrade required', 426)
  const room = c.req.query('room')
  const stub = room && /^\d+$/.test(room) ? c.env.ROOM.getByName(room) : c.env.LOBBY.getByName('public')
  return stub.fetch(c.req.raw)
})
app.all('*', c => c.env.ASSETS.fetch(c.req.raw))
export default app
