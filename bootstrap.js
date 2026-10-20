#!/usr/bin/env node
'use strict';

/**
 * Self-contained bootstrap for stripped Pterodactyl eggs.
 *
 * Some panels ship a Debian slim image with Node but NO curl and NO wget
 * (exit 127: "wget: command not found"). Node's built-in fetch is the only
 * reliable network client there, so this file fetches the rest of the repo
 * using nothing but Node, then hands off to server.js.
 *
 * Usage as the panel startup command:
 *   node -e "fetch('https://raw.githubusercontent.com/therealfreddied/9router-pterodactyl/main/bootstrap.js').then(r=>r.text()).then(t=>require('fs').writeFileSync('bootstrap.js',t))" && node bootstrap.js
 *
 * On later boots, once files exist, `node server.js` alone is enough.
 */

const fs = require('fs');
const path = require('path');

const BASE = process.env.REPO_RAW_BASE
  || 'https://raw.githubusercontent.com/therealfreddied/9router-pterodactyl/main/';

const FILES = ['start.sh', 'server.js', 'extract.js'];

// The panel may mount the cwd read-only for the runtime user (Wispbyte does:
// EACCES on writeFileSync in /home/container). Pick a writable work dir.
function pickDir() {
  const candidates = [
    process.env.INSTALL_DIR,
    process.cwd(),
    process.env.HOME,
    '/tmp',
    '/var/tmp',
  ].filter(Boolean);
  for (const d of candidates) {
    try {
      fs.mkdirSync(d, { recursive: true });
      const probe = path.join(d, '.wtest.' + process.pid);
      fs.writeFileSync(probe, 'x');
      fs.unlinkSync(probe);
      return d;
    } catch (_) {
      /* try next */
    }
  }
  return null;
}

const outDir = pickDir();

async function grab(name) {
  const url = BASE + name + '?t=' + Date.now();
  const res = await fetch(url, { redirect: 'follow' });
  if (!res.ok) throw new Error(name + ' -> HTTP ' + res.status);
  const body = await res.text();
  if (!body || body.length < 50) throw new Error(name + ' -> empty response');
  const dest = path.join(outDir, name);
  fs.writeFileSync(dest, body);
  if (name.endsWith('.sh')) {
    try { fs.chmodSync(dest, 0o755); } catch (_) {}
  }
  console.log('[bootstrap] fetched ' + name + ' (' + body.length + ' bytes)');
}

(async () => {
  console.log('[bootstrap] using node ' + process.versions.node);
  if (typeof fetch !== 'function') {
    console.error('[bootstrap] ERROR: this Node has no global fetch (need >= 18)');
    process.exit(1);
  }
  if (!outDir) {
    console.error('[bootstrap] ERROR: no writable directory for install files');
    process.exit(1);
  }
  console.log('[bootstrap] install dir: ' + outDir);
  try {
    for (const f of FILES) await grab(f);
  } catch (err) {
    console.error('[bootstrap] ERROR: ' + err.message);
    console.error('[bootstrap] hint: check outbound HTTPS access from this egg');
    process.exit(1);
  }
  process.env.PWD = outDir;
  process.env.INSTALL_DIR = outDir;
  require(path.join(outDir, 'server.js'));
})();
