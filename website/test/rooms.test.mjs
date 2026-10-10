import assert from 'node:assert/strict'
// eslint-disable-next-line test/no-import-node-test -- These tests run with node --test.
import test from 'node:test'
import { setTimeout as delay } from 'node:timers/promises'
import { WebSocket } from 'ws'
import { decode, packet } from '../src/codec.ts'

const endpoint = process.env.GAME_SERVER || 'ws://127.0.0.1:8789/ws'

async function createPeer(version = 2) {
  let socket
  let stopped = false
  let observer
  const sockets = new Set()
  const messages = []

  function connect(url) {
    socket = new WebSocket(url)
    sockets.add(socket)
    socket.on('error', () => {})
    socket.on('message', (data) => {
      if (stopped) {
        return
      }
      const message = { kind: data[0], body: decode(data.subarray(1)) }
      if (message.kind === 36) {
        const destination = new URL(endpoint)
        destination.searchParams.set('version', version)
        if (message.body.room) {
          destination.searchParams.set('room', message.body.room)
          destination.searchParams.set('ticket', message.body.ticket)
        }
        connect(destination)
        return
      }
      messages.push(message)
      observer?.()
    })
  }

  const initial = new URL(endpoint)
  initial.searchParams.set('version', version)
  connect(initial)
  await new Promise((resolve, reject) => {
    socket.once('open', resolve)
    socket.once('error', reject)
  })

  return {
    get socket() {
      return socket
    },
    messages,
    close() {
      stopped = true
      for (const connection of sockets) {
        connection.terminate()
      }
    },
    send(kind, body = {}) {
      socket.send(packet(kind, body))
    },
    waitFor(kind, predicate = () => true) {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          reject(new Error(`Missing packet ${kind}: queued ${JSON.stringify(messages)}`))
        }, 15000)

        const check = () => {
          const index = messages.findIndex(message => message.kind === kind && predicate(message.body))
          if (index >= 0) {
            const [message] = messages.splice(index, 1)
            clearTimeout(timer)
            observer = undefined
            resolve(message.body)
          }
        }
        observer = check
        check()
      })
    },
  }
}

test('Worker rooms require two players, isolate games, and recover after a player leaves', async (context) => {
  const host = await createPeer()
  const guest = await createPeer()
  const other = await createPeer()
  for (const peer of [host, guest, other]) {
    context.after(() => peer.close())
  }

  host.send(17)
  const room = await host.waitFor(33, body => body.count === 1)
  assert.equal(room.host, true)
  host.send(20)
  assert.equal(await host.waitFor(35), 'Two players required')

  const listing = await guest.waitFor(32, body => Object.values(body).some(item => item.id === room.id))
  assert.equal(Object.values(listing).find(item => item.id === room.id).count, 1)
  guest.send(18, room.id)
  assert.equal((await guest.waitFor(33, body => body.count === 2)).host, false)
  await host.waitFor(33, body => body.count === 2)

  guest.send(20)
  assert.equal(await guest.waitFor(35), 'Two players required')
  other.send(18, room.id)
  assert.equal(await other.waitFor(35), 'Room unavailable')
  host.send(20)
  assert.equal((await host.waitFor(34)).host, true)
  assert.equal((await guest.waitFor(34)).host, false)

  guest.send(2, { right: true })
  assert.equal((await host.waitFor(2)).right, true)
  host.send(3, { score: 123 })
  assert.equal((await guest.waitFor(3)).score, 123)
  guest.send(3, { score: 999 })
  other.send(3, { score: 888 })
  await delay(80)
  assert.equal(host.messages.some(message => message.kind === 3), false)
  assert.equal(other.messages.some(message => message.kind === 2 || message.kind === 3), false)

  guest.send(21)
  await host.waitFor(33, body => !body.started && body.count === 2)
  host.send(20)
  await guest.waitFor(34)
  guest.socket.close()
  const waiting = await host.waitFor(33, body => body.count === 1 && !body.started)
  assert.equal(waiting.host, true)

  host.send(19)
  await host.waitFor(33, body => body.count === 0)
  await host.waitFor(32, body => Object.values(body).every(item => item.id !== room.id))
})

test('Different client versions cannot share a room and both receive the update prompt', async (context) => {
  const host = await createPeer(2)
  const guest = await createPeer(3)
  context.after(() => host.close())
  context.after(() => guest.close())
  host.send(17)
  const room = await host.waitFor(33, body => body.count === 1)
  await guest.waitFor(32, body => Object.values(body).some(item => item.id === room.id))
  guest.send(18, room.id)
  assert.equal(await guest.waitFor(35), '请更新客户端版本')
  assert.equal(await host.waitFor(35), '请更新客户端版本')
  assert.equal(host.messages.some(message => message.kind === 33 && message.body.count === 2), false)
  guest.send(17)
  assert.equal((await guest.waitFor(33, body => body.count === 1)).host, true)
})
