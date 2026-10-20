#!/usr/bin/env node
'use strict';

/**
 * Pterodactyl entrypoint shim.
 *
 * The egg's startup command ends with:
 *     /usr/local/bin/node /home/container/server.js
 *
 * So this file must exist at the repo root. It delegates to start.sh, which
 * installs the latest 9router from npm and launches the bundled Next.js server.
 *
 * Note: the installed app also ships a file called server.js, but it lives in
 * the global npm root (or $DATA_DIR/app), so there is no collision with this
 * root-level shim.
 */

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const dir = __dirname;
const script = path.join(dir, 'start.sh');

if (!fs.existsSync(script)) {
  console.error('[9router] ERROR: start.sh not found next to server.js');
  process.exit(1);
}

// Fail early with a readable message instead of a Next.js stack trace.
const major = Number(process.versions.node.split('.')[0]);
if (major < 20) {
  console.error(
    '[9router] ERROR: Node >= 20.9 required, this egg has v' + process.versions.node
  );
  console.error('[9router] Switch the egg image or install Node 22, then restart.');
  process.exit(1);
}

const child = spawn('sh', [script], {
  stdio: 'inherit',
  cwd: dir,
  env: Object.assign({}, process.env, {
    PWD: dir,
    INSTALL_DIR: process.env.INSTALL_DIR || dir,
  }),
});

child.on('error', (err) => {
  console.error('[9router] failed to launch start.sh:', err.message);
  process.exit(1);
});

child.on('exit', (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code === null ? 1 : code);
});

for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
  process.on(sig, () => {
    try {
      child.kill(sig);
    } catch (_) {
      /* already gone */
    }
  });
}
