import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.wasm': 'application/wasm', '.ttf': 'font/ttf', '.lua': 'text/plain', '.game': 'text/plain', '.dl': 'text/plain', '.wav': 'audio/wav' };
const server = http.createServer(async (request, response) => {
  response.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  response.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
  response.setHeader('Cache-Control', 'no-store');
  try {
    const path = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
    const base = path.startsWith('/game/') ? resolve(root, 'game') : resolve(root, 'dist/web');
    const relative = path.startsWith('/game/') ? path.slice(6) : path === '/' ? 'index.html' : path.slice(1);
    const filename = resolve(base, relative);
    if (!filename.startsWith(base + '/') || request.method !== 'GET') {
      response.writeHead(404).end(); return;
    }
    const data = await readFile(filename);
    response.setHeader('Content-Type', mime[extname(filename)] || 'application/octet-stream');
    response.writeHead(200).end(data);
  } catch {
    response.writeHead(404).end('Build the browser client first (see README).');
  }
});

const port = Number(process.env.PORT || 8787);
server.listen(port, '0.0.0.0', () => console.log(`Geometry Wars: http://localhost:${port}`));
process.once('SIGINT', () => server.close());
process.once('SIGTERM', () => server.close());
