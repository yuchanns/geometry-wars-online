import type { Value } from './codec'
import { DurableObject } from 'cloudflare:workers'
import { binary, decode, packet } from './codec'

interface Listing extends Record<string, number> {
  id: number
  count: number
  started: number
}

interface Seat {
  host: boolean
  version: number
}

const RESERVED_MS = 30000
const UPDATE_CLIENT = 'Please update your client'

function send(socket: WebSocket, kind: number, body: Value) {
  socket.send(packet(kind, body))
}

function accept(ctx: DurableObjectState): [WebSocket, Response] {
  const pair = new WebSocketPair()
  ctx.acceptWebSocket(pair[1])
  return [pair[1], new Response(null, { status: 101, webSocket: pair[0] })]
}

// Only low-frequency room discovery and changes go through the lobby.
export class Lobby extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS rooms (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        count INTEGER NOT NULL DEFAULT 0,
        started INTEGER NOT NULL DEFAULT 0
      )
    `)
  }

  listing(): Value[] {
    const rooms = this.ctx.storage.sql
      .exec<Listing>('SELECT id, count, started FROM rooms WHERE count > 0 ORDER BY id')
      .toArray()

    return rooms.map(room => ({
      id: room.id,
      count: room.count,
      started: room.started !== 0,
    }))
  }

  async update(id: number, count: number, started: boolean) {
    if (count === 0) {
      this.ctx.storage.sql.exec('DELETE FROM rooms WHERE id = ?', id)
    }
    else {
      this.ctx.storage.sql.exec('UPDATE rooms SET count = ?, started = ? WHERE id = ?', count, started ? 1 : 0, id)
    }

    const listing = this.listing()
    for (const socket of this.ctx.getWebSockets()) {
      try {
        send(socket, 32, listing)
      }
      catch {
        socket.close(1011, 'Connection lost')
      }
    }
  }

  async fetch(request: Request): Promise<Response> {
    const [socket, response] = accept(this.ctx)
    socket.serializeAttachment({ redirected: false, version: Number(new URL(request.url).searchParams.get('version')) })
    send(socket, 32, this.listing())
    return response
  }

  async webSocketMessage(socket: WebSocket, message: ArrayBuffer | string) {
    try {
      const data = binary(message)
      const kind = data[0]
      const body = decode(data.subarray(1))
      if (kind === 16) {
        send(socket, 32, this.listing())
        return
      }
      if (kind !== 17 && kind !== 18) {
        send(socket, 35, 'Join a room first')
        return
      }

      const attachment = socket.deserializeAttachment() as { redirected: boolean, version: number }
      if (attachment.redirected) {
        return
      }

      let id: number
      if (kind === 17) {
        id = this.ctx.storage.sql
          .exec<{ id: number }>('INSERT INTO rooms DEFAULT VALUES RETURNING id')
          .one()
          .id
      }
      else {
        if (typeof body !== 'number' || !Number.isSafeInteger(body)) {
          send(socket, 35, 'Room unavailable')
          return
        }
        id = body
        const room = this.ctx.storage.sql
          .exec<Listing>('SELECT id, count, started FROM rooms WHERE id = ?', id)
          .toArray()[0]
        if (!room || room.count !== 1 || room.started) {
          send(socket, 35, 'Room unavailable')
          return
        }
      }

      socket.serializeAttachment({ ...attachment, redirected: true })
      const ticket = await this.env.ROOM.getByName(String(id)).reserve(id, kind === 17, attachment.version)
      if (ticket === '') {
        socket.serializeAttachment({ ...attachment, redirected: false })
        send(socket, 35, UPDATE_CLIENT)
        return
      }
      if (!ticket) {
        socket.serializeAttachment({ ...attachment, redirected: false })
        send(socket, 35, 'Room unavailable')
        return
      }
      send(socket, 36, { room: id, ticket })
      socket.close(1000, 'Joining room')
    }
    catch (error) {
      console.error(JSON.stringify({ event: 'lobby_packet_error', error: String(error) }))
      socket.close(1008, 'Invalid packet')
    }
  }

  webSocketClose(socket: WebSocket) {
    socket.close(1000, 'Disconnected')
  }

  webSocketError(socket: WebSocket) {
    socket.close(1011, 'Connection lost')
  }
}

// Each room owns two hibernatable sockets. High-frequency data never touches SQL.
export class Room extends DurableObject<Env> {
  private players = new Map<WebSocket, Seat>()
  private id = 0
  private started = false

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS room (
        id INTEGER PRIMARY KEY,
        started INTEGER NOT NULL DEFAULT 0
      )
    `)
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS tickets (
        ticket TEXT PRIMARY KEY,
        host INTEGER NOT NULL,
        expires INTEGER NOT NULL
      )
    `)

    const row = this.ctx.storage.sql
      .exec<{ id: number, started: number }>('SELECT id, started FROM room')
      .toArray()[0]
    if (row) {
      this.id = row.id
      this.started = row.started !== 0
    }
    for (const socket of this.ctx.getWebSockets()) {
      this.players.set(socket, socket.deserializeAttachment() as Seat)
    }
  }

  async reserve(id: number, host: boolean, version: number): Promise<string | null> {
    this.ctx.storage.sql.exec('DELETE FROM tickets WHERE expires < ?', Date.now())
    const reserved = this.ctx.storage.sql.exec<{ host: number }>('SELECT host FROM tickets').toArray()
    if (this.started || this.players.size + reserved.length >= 2) {
      return null
    }
    if (host && (this.players.size > 0 || reserved.length > 0)) {
      return null
    }
    if (!host && ![...this.players.values()].some(seat => seat.host)) {
      return null
    }

    for (const [socket, seat] of this.players) {
      if (seat.version !== version) {
        send(socket, 35, UPDATE_CLIENT)
        return ''
      }
    }

    this.ctx.storage.sql.exec('INSERT OR IGNORE INTO room (id) VALUES (?)', id)
    this.id = id
    const ticket = crypto.randomUUID()
    this.ctx.storage.sql.exec(
      'INSERT INTO tickets (ticket, host, expires) VALUES (?, ?, ?)',
      ticket,
      host ? 1 : 0,
      Date.now() + RESERVED_MS,
    )
    await this.ctx.storage.setAlarm(Date.now() + RESERVED_MS)
    return ticket
  }

  async fetch(request: Request): Promise<Response> {
    const ticket = new URL(request.url).searchParams.get('ticket')
    const reservation = this.ctx.storage.sql
      .exec<{ host: number, expires: number }>('DELETE FROM tickets WHERE ticket = ? RETURNING host, expires', ticket)
      .toArray()[0]
    if (!reservation || reservation.expires < Date.now() || this.players.size >= 2) {
      return new Response('Room unavailable', { status: 409 })
    }

    const [socket, response] = accept(this.ctx)
    const seat = { host: reservation.host !== 0, version: Number(new URL(request.url).searchParams.get('version')) }
    socket.serializeAttachment(seat)
    this.players.set(socket, seat)
    await this.changed()
    return response
  }

  private async changed() {
    this.ctx.storage.sql.exec('UPDATE room SET started = ? WHERE id = ?', this.started ? 1 : 0, this.id)
    for (const [socket, seat] of this.players) {
      send(socket, 33, {
        id: this.id,
        count: this.players.size,
        host: seat.host,
        started: this.started,
      })
    }
    await this.env.LOBBY.getByName('public').update(this.id, this.players.size, this.started)
  }

  async webSocketMessage(socket: WebSocket, message: ArrayBuffer | string) {
    try {
      const data = binary(message)
      const kind = data[0]
      const seat = this.players.get(socket)
      if (!seat) {
        return
      }
      if (kind === 2 || kind === 3) {
        if (!this.started || this.players.size !== 2 || (kind === 2) === seat.host) {
          return
        }
        for (const peer of this.players.keys()) {
          if (peer !== socket) {
            peer.send(message)
          }
        }
        return
      }

      decode(data.subarray(1))
      if (kind === 19) {
        await this.leave(socket)
        send(socket, 33, { count: 0 })
        send(socket, 36, { room: 0 })
        socket.close(1000, 'Leaving room')
      }
      else if (kind === 20) {
        if (!seat.host || this.players.size !== 2 || this.started) {
          send(socket, 35, 'Two players required')
          return
        }
        this.started = true
        await this.changed()
        for (const [peer, role] of this.players) {
          send(peer, 34, { host: role.host })
        }
      }
      else if (kind === 21) {
        if (this.started) {
          this.started = false
          await this.changed()
        }
      }
      else if (kind === 17 || kind === 18) {
        send(socket, 35, 'Leave your room first')
      }
      else if (kind !== 16) {
        socket.close(1008, 'Unknown command')
      }
    }
    catch (error) {
      console.error(JSON.stringify({ event: 'room_packet_error', room: this.id, error: String(error) }))
      socket.close(1008, 'Invalid packet')
    }
  }

  private async leave(socket: WebSocket) {
    if (!this.players.delete(socket)) {
      return
    }
    this.started = false
    // The remaining player becomes host, matching the original room behavior.
    for (const [peer, seat] of this.players) {
      seat.host = true
      peer.serializeAttachment(seat)
    }
    await this.changed()
    if (this.players.size === 0) {
      await this.ctx.storage.setAlarm(Date.now() + RESERVED_MS)
    }
  }

  async webSocketClose(socket: WebSocket) {
    await this.leave(socket)
    socket.close(1000, 'Disconnected')
  }

  async webSocketError(socket: WebSocket) {
    await this.leave(socket)
    socket.close(1011, 'Connection lost')
  }

  async alarm() {
    this.ctx.storage.sql.exec('DELETE FROM tickets WHERE expires <= ?', Date.now())
    const pending = this.ctx.storage.sql.exec('SELECT ticket FROM tickets').toArray()
    if (this.players.size === 0 && pending.length === 0) {
      await this.env.LOBBY.getByName('public').update(this.id, 0, false)
      await this.ctx.storage.deleteAll()
    }
    else if (pending.length > 0) {
      await this.ctx.storage.setAlarm(Date.now() + RESERVED_MS)
    }
  }
}
