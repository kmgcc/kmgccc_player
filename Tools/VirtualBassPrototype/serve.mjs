#!/usr/bin/env node
// Static server for the demo (AudioWorklet modules need http, not file://).
//
//   node serve.mjs [--port 8723] [--media <folder>]
//
// --media exposes a folder of audio files read-only at /media/…, listed in
// the demo's "Library" menu, so tracks can be picked without a file dialog.

import { createServer } from 'node:http';
import { readFile, readdir, stat } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(fileURLToPath(new URL('.', import.meta.url)));
const args = process.argv.slice(2);
const arg = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : def;
};
const port = Number(arg('port', process.env.PORT || 8723));
const mediaDir = arg('media', '') ? resolve(arg('media', '')) : '';

const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json', '.svg': 'image/svg+xml',
  '.wav': 'audio/wav', '.mp3': 'audio/mpeg', '.m4a': 'audio/mp4', '.aac': 'audio/aac', '.flac': 'audio/flac',
  '.ogg': 'audio/ogg', '.aif': 'audio/aiff', '.aiff': 'audio/aiff',
};
const AUDIO = new Set(['.wav', '.mp3', '.m4a', '.aac', '.flac', '.ogg', '.aif', '.aiff']);

function inside(base, p) {
  const full = resolve(base, '.' + sep + normalize(p));
  return full === base || full.startsWith(base + sep) ? full : null;
}

async function listMedia() {
  if (!mediaDir) return [];
  const out = [];
  async function walk(dir, rel, depth) {
    if (depth > 3) return;
    for (const e of await readdir(dir, { withFileTypes: true })) {
      if (e.name.startsWith('.')) continue;
      const r = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) await walk(join(dir, e.name), r, depth + 1);
      else if (AUDIO.has(extname(e.name).toLowerCase())) out.push(r);
    }
  }
  await walk(mediaDir, '', 0);
  return out.sort((a, b) => a.localeCompare(b));
}

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    const path = decodeURIComponent(url.pathname);
    if (path === '/media-list') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(await listMedia()));
      return;
    }
    let file;
    if (path.startsWith('/media/') && mediaDir) file = inside(mediaDir, path.slice(7));
    else file = inside(root, path === '/' ? 'index.html' : path.slice(1));
    if (!file) { res.writeHead(403); res.end(); return; }
    const info = await stat(file).catch(() => null);
    if (!info || !info.isFile()) { res.writeHead(404); res.end('not found'); return; }
    const type = TYPES[extname(file).toLowerCase()] || 'application/octet-stream';
    if (AUDIO.has(extname(file).toLowerCase())) {
      res.writeHead(200, { 'content-type': type, 'content-length': info.size, 'cache-control': 'no-store' });
      createReadStream(file).pipe(res);
      return;
    }
    res.writeHead(200, { 'content-type': type, 'cache-control': 'no-store' });
    res.end(await readFile(file));
  } catch (err) {
    res.writeHead(500);
    res.end(String(err));
  }
});

server.listen(port, '127.0.0.1', () => {
  console.log(`Virtual bass prototype: http://localhost:${port}/`);
  if (mediaDir) console.log(`Library: ${mediaDir}`);
});
