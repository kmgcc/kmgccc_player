#!/usr/bin/env node
// Static server for the progressive-blur lab.
//
//   node serve.mjs [--port 8724] [--library <library root>]
//
// Without --library it reads the active library from the App's
// LibraryRegistry.json. Covers are served read-only at /art/<n>; identical
// files (album siblings) are listed once.

import { createServer } from 'node:http';
import { readFile, readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { homedir } from 'node:os';
import { extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(fileURLToPath(new URL('.', import.meta.url)));
const args = process.argv.slice(2);
const arg = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : def;
};
const port = Number(arg('port', process.env.PORT || 8724));

const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json',
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp',
};

async function activeLibraryRoot() {
  if (arg('library', '')) return resolve(arg('library', ''));
  const registryURL = join(homedir(), 'Library/Application Support/kmgccc.player/LibraryRegistry.json');
  const registry = JSON.parse(await readFile(registryURL, 'utf8'));
  const lib = registry.libraries.find((l) => l.id === registry.activeLibraryID) ?? registry.libraries[0];
  return lib.lastKnownPath;
}

async function loadCovers(libraryRoot) {
  const tracksDir = join(libraryRoot, 'Tracks');
  const seen = new Set();
  const covers = [];
  for (const id of (await readdir(tracksDir)).sort()) {
    let meta;
    try { meta = JSON.parse(await readFile(join(tracksDir, id, 'meta.json'), 'utf8')); } catch { continue; }
    const names = [meta.artworkFileName, 'artwork.jpg', 'artwork.png'].filter(Boolean);
    for (const name of names) {
      let data;
      try { data = await readFile(join(tracksDir, id, name)); } catch { continue; }
      const hash = createHash('sha1').update(data).digest('hex');
      if (!seen.has(hash)) {
        seen.add(hash);
        covers.push({ file: join(tracksDir, id, name), title: meta.title ?? '', artist: meta.artist ?? '', album: meta.album ?? '' });
      }
      break;
    }
  }
  covers.sort((a, b) => (a.album + a.title).localeCompare(b.album + b.title, 'zh'));
  return covers;
}

const libraryRoot = await activeLibraryRoot();
const covers = await loadCovers(libraryRoot);
console.log(`library: ${libraryRoot}\ncovers: ${covers.length}`);

createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  try {
    if (url.pathname === '/api/covers') {
      res.writeHead(200, { 'Content-Type': TYPES['.json'] });
      res.end(JSON.stringify(covers.map(({ title, artist, album }, i) => ({ i, title, artist, album }))));
      return;
    }
    const art = url.pathname.match(/^\/art\/(\d+)$/);
    if (art) {
      const cover = covers[Number(art[1])];
      if (!cover) throw new Error('missing');
      res.writeHead(200, { 'Content-Type': TYPES[extname(cover.file).toLowerCase()] ?? 'application/octet-stream', 'Cache-Control': 'max-age=3600' });
      res.end(await readFile(cover.file));
      return;
    }
    const name = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
    if (!/^[\w.-]+$/.test(name)) throw new Error('bad path');
    const body = await readFile(join(root, name));
    res.writeHead(200, { 'Content-Type': TYPES[extname(name)] ?? 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end('not found');
  }
}).listen(port, '127.0.0.1', () => console.log(`http://localhost:${port}`));
