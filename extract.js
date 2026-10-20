#!/usr/bin/env node
'use strict';

/**
 * Minimal tar.gz extractor — no npm, no system tar, no external deps.
 *
 * Panels give us almost no disk. `npm install` needs the cache, a staging tree,
 * AND the final tree at once, which is what triggers ENOSPC on small eggs.
 * This streams the registry tarball through memory and writes only the final
 * tree, so peak disk usage is just the extracted files.
 *
 * Usage:
 *   node extract.js <archive.tgz> <destDir>
 *   node extract.js https://registry.npmjs.org/9router/-/9router-1.2.3.tgz <destDir>
 */

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const [archive, dest, ...flags] = process.argv.slice(2);
if (!archive || !dest) {
  console.error('usage: node extract.js <archive.tgz|url> <destDir> [--only <path>]');
  process.exit(2);
}

// --only <path> extracts a single member. Used to pull sql-wasm.wasm out of the
// sql.js tarball without unpacking the other 9 MB.
let only = null;
const onlyIdx = flags.indexOf('--only');
if (onlyIdx !== -1 && flags[onlyIdx + 1]) only = flags[onlyIdx + 1].replace(/^\.\//, '');

function str(b, off, len) {
  const slice = b.subarray(off, off + len);
  const end = slice.indexOf(0);
  return slice.subarray(0, end === -1 ? slice.length : end).toString('utf8');
}

function octal(b, off, len) {
  const s = str(b, off, len).trim();
  return s ? parseInt(s, 8) : 0;
}

function extract(tar) {
  fs.mkdirSync(dest, { recursive: true });
  const root = path.resolve(dest);

  let pos = 0;
  let lastLongName = null;
  let files = 0;
  let bytes = 0;
  const pendingLinks = [];

  while (pos + 512 <= tar.length) {
    const header = tar.subarray(pos, pos + 512);

    // Two zero blocks mark end of archive.
    if (header.every((v) => v === 0)) break;

    let name = str(header, 0, 100);
    const prefix = str(header, 345, 155);
    const size = octal(header, 124, 12);
    const type = String.fromCharCode(header[156] || 48);
    const linkname = str(header, 157, 100);

    if (prefix) name = prefix + '/' + name;
    if (lastLongName) {
      name = lastLongName;
      lastLongName = null;
    }

    pos += 512;
    const dataStart = pos;
    const dataEnd = dataStart + size;
    pos = dataStart + Math.ceil(size / 512) * 512;

    if (type === 'x' || type === 'g') continue;
    if (type === 'L') {
      lastLongName = tar.subarray(dataStart, dataEnd).toString('utf8').replace(/\0+$/, '');
      continue;
    }

    // Refuse path traversal.
    const rel = name.replace(/^\.\//, '');
    if (only && rel !== only) continue;

    const target = path.resolve(root, rel);
    if (target !== root && !target.startsWith(root + path.sep)) continue;

    if (type === '5') {
      fs.mkdirSync(target, { recursive: true });
    } else if (type === '0' || type === '7' || type === '\0') {
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, tar.subarray(dataStart, dataEnd));
      files++;
      bytes += size;
    } else if (type === '2') {
      pendingLinks.push([target, linkname]);
    }
  }

  for (const [link, target] of pendingLinks) {
    try {
      fs.mkdirSync(path.dirname(link), { recursive: true });
      fs.symlinkSync(target, link);
    } catch (_) {
      /* non-fatal: packages work without optional symlinks */
    }
  }

  console.log('[extract] ' + files + ' files, ' + Math.round(bytes / 1048576) + ' MB extracted');
}

(async () => {
  let tar;
  if (/^https?:\/\//i.test(archive)) {
    const res = await fetch(archive, { redirect: 'follow' });
    if (!res.ok) throw new Error('HTTP ' + res.status + ' for ' + archive);
    const body = Buffer.from(await res.arrayBuffer());
    if (!body.length) throw new Error('empty download');
    console.log('[extract] downloaded ' + Math.round(body.length / 1048576) + ' MB');
    tar = zlib.gunzipSync(body);
  } else {
    tar = zlib.gunzipSync(fs.readFileSync(archive));
  }
  extract(tar);
})().catch((err) => {
  console.error('[extract] ERROR: ' + err.message);
  process.exit(1);
});
