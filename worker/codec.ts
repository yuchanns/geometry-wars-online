// The existing Lua wire format. Gameplay payloads are relayed without decoding.
export type Value = null | boolean | number | string | Value[] | {[key: string]: Value};
const utf8 = new TextEncoder();
export function encode(value: Value): Uint8Array {
  const bytes: number[] = [];
  function write(v: Value, depth = 0) {
    if (depth >= 12) throw new Error('Packet nesting too deep');
    if (v === null) bytes.push(0);
    else if (typeof v === 'boolean') bytes.push(v ? 2 : 1);
    else if (typeof v === 'number') {
      const b = new Uint8Array(8); new DataView(b.buffer).setFloat64(0, v, true);
      bytes.push(3, ...b);
    } else if (typeof v === 'string') {
      const b = utf8.encode(v); if (b.length > 65535) throw new Error('String too large');
      bytes.push(4, b.length & 255, b.length >> 8); for (const x of b) bytes.push(x);
    } else {
      const entries: [string | number, Value][] = Array.isArray(v)
        ? v.map((x, i) => [i + 1, x]) : Object.entries(v);
      bytes.push(5, entries.length & 255, entries.length >> 8);
      for (const [k, x] of entries) { write(k, depth + 1); write(x, depth + 1); }
    }
  }
  write(value); return Uint8Array.from(bytes);
}
export function packet(kind: number, value: Value): Uint8Array {
  const body = encode(value); const out = new Uint8Array(body.length + 1);
  out[0] = kind; out.set(body, 1); return out;
}
export function decode(data: Uint8Array): Value {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  let offset = 0, budget = 0;
  function read(depth = 0): Value {
    if (depth >= 12 || ++budget > 50000) throw new Error('Packet complexity limit');
    const tag = view.getUint8(offset++);
    if (tag === 0) return null;
    if (tag < 3) return tag === 2;
    if (tag === 3) {
      const value = view.getFloat64(offset, true); offset += 8;
      if (!Number.isFinite(value)) throw new Error('Invalid number'); return value;
    }
    if (tag === 4) {
      const size = view.getUint16(offset, true); offset += 2;
      if (offset + size > data.length) throw new Error('Truncated string');
      const value = new TextDecoder().decode(data.subarray(offset, offset + size)); offset += size; return value;
    }
    if (tag === 5) {
      const size = view.getUint16(offset, true); offset += 2;
      const value: {[key: string]: Value} = Object.create(null);
      for (let i = 0; i < size; i++) {
        const key = read(depth + 1); const item = read(depth + 1);
        if (typeof key !== 'string' && typeof key !== 'number') throw new Error('Invalid key');
        value[key] = item;
      }
      return value;
    }
    throw new Error('Invalid packet tag');
  }
  const value = read(); if (offset !== data.length) throw new Error('Trailing packet data'); return value;
}
export function binary(message: ArrayBuffer | string): Uint8Array {
  if (typeof message === 'string' || message.byteLength < 1 || message.byteLength > 1048576) throw new Error('Invalid packet');
  return new Uint8Array(message);
}
