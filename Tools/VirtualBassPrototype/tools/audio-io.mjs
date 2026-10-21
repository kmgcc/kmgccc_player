// Audio file input/output for the offline tools. Any format ffmpeg can
// read is decoded to planar float stereo; output is 32-bit float WAV.

import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';

export function decode(path, fs = 48000, { start = 0, duration = 0 } = {}) {
  const args = ['-v', 'error'];
  if (start > 0) args.push('-ss', String(start));
  if (duration > 0) args.push('-t', String(duration));
  args.push('-i', path, '-f', 'f32le', '-ac', '2', '-ar', String(fs), '-');
  const r = spawnSync('ffmpeg', args, { maxBuffer: 1 << 30 });
  if (r.status !== 0) throw new Error(`ffmpeg failed: ${r.stderr}`);
  const buf = r.stdout;
  const inter = new Float32Array(buf.buffer, buf.byteOffset, Math.floor(buf.byteLength / 4));
  const n = inter.length >> 1;
  const L = new Float64Array(n);
  const R = new Float64Array(n);
  for (let i = 0; i < n; i++) { L[i] = inter[2 * i]; R[i] = inter[2 * i + 1]; }
  return { L, R, fs };
}

export function writeWav(path, L, R, fs) {
  const n = L.length;
  const data = Buffer.alloc(n * 8);
  for (let i = 0; i < n; i++) {
    data.writeFloatLE(L[i], 8 * i);
    data.writeFloatLE(R[i], 8 * i + 4);
  }
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8);
  h.write('fmt ', 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(3, 20); h.writeUInt16LE(2, 22);
  h.writeUInt32LE(fs, 24); h.writeUInt32LE(fs * 8, 28); h.writeUInt16LE(8, 32); h.writeUInt16LE(32, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  writeFileSync(path, Buffer.concat([h, data]));
}
