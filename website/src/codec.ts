// Lua tables use this wire format; gameplay payloads are relayed without decoding.
export type Value = null | boolean | number | string | Value[] | { [key: string]: Value }

const utf8 = new TextEncoder()

export function encode(value: Value): Uint8Array {
  const bytes: number[] = []

  function write(item: Value, depth = 0) {
    if (depth >= 12) {
      throw new Error('Packet nesting too deep')
    }
    if (item === null) {
      bytes.push(0)
    }
    else if (typeof item === 'boolean') {
      bytes.push(item ? 2 : 1)
    }
    else if (typeof item === 'number') {
      const number = new Uint8Array(8)
      new DataView(number.buffer).setFloat64(0, item, true)
      bytes.push(3, ...number)
    }
    else if (typeof item === 'string') {
      const text = utf8.encode(item)
      if (text.length > 65535) {
        throw new Error('String too large')
      }
      bytes.push(4, text.length & 255, text.length >> 8)
      for (const byte of text) {
        bytes.push(byte)
      }
    }
    else {
      const entries: [string | number, Value][] = Array.isArray(item)
        ? item.map((value, index) => [index + 1, value])
        : Object.entries(item)
      bytes.push(5, entries.length & 255, entries.length >> 8)
      for (const [key, value] of entries) {
        write(key, depth + 1)
        write(value, depth + 1)
      }
    }
  }

  write(value)
  return Uint8Array.from(bytes)
}

export function packet(kind: number, value: Value): Uint8Array {
  const body = encode(value)
  const result = new Uint8Array(body.length + 1)
  result[0] = kind
  result.set(body, 1)
  return result
}

export function decode(data: Uint8Array): Value {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength)
  let offset = 0
  let budget = 0

  function read(depth = 0): Value {
    budget += 1
    if (depth >= 12 || budget > 50000) {
      throw new Error('Packet complexity limit')
    }
    const tag = view.getUint8(offset++)
    if (tag === 0) {
      return null
    }
    if (tag < 3) {
      return tag === 2
    }
    if (tag === 3) {
      const value = view.getFloat64(offset, true)
      offset += 8
      if (!Number.isFinite(value)) {
        throw new TypeError('Invalid number')
      }
      return value
    }
    if (tag === 4) {
      const size = view.getUint16(offset, true)
      offset += 2
      if (offset + size > data.length) {
        throw new Error('Truncated string')
      }
      const value = new TextDecoder().decode(data.subarray(offset, offset + size))
      offset += size
      return value
    }
    if (tag === 5) {
      const size = view.getUint16(offset, true)
      offset += 2
      const value: { [key: string]: Value } = Object.create(null)
      for (let index = 0; index < size; index++) {
        const key = read(depth + 1)
        const item = read(depth + 1)
        if (typeof key !== 'string' && typeof key !== 'number') {
          throw new TypeError('Invalid key')
        }
        value[key] = item
      }
      return value
    }
    throw new Error('Invalid packet tag')
  }

  const value = read()
  if (offset !== data.length) {
    throw new Error('Trailing packet data')
  }
  return value
}

export function binary(message: ArrayBuffer | string): Uint8Array {
  if (typeof message === 'string' || message.byteLength < 1 || message.byteLength > 1048576) {
    throw new Error('Invalid packet')
  }
  return new Uint8Array(message)
}
