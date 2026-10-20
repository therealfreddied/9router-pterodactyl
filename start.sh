#!/bin/sh
# 9router — zero-build bootstrap for Pterodactyl / bare hosts.
# Installs the LATEST official npm package and serves the dashboard.
#
# Why not the CLI? `9router` refuses to bind 0.0.0.0 in CLI mode. We install the
# package for its app payload, then launch its bundled Next.js server directly.

set -eu

# Panels sometimes mount /home/container read-only for the runtime user, so we
# cannot assume the script's own directory is writable. Pick the first writable
# location: explicit INSTALL_DIR, cwd, HOME, then temp dirs.
pick_dir() {
  for d in "${INSTALL_DIR:-}" "$PWD" "${HOME:-}" /tmp /var/tmp; do
    [ -n "$d" ] || continue
    mkdir -p "$d" 2>/dev/null || continue
    if ( : > "$d/.wtest.$$" ) 2>/dev/null; then
      rm -f "$d/.wtest.$$" 2>/dev/null || true
      printf '%s' "$d"
      return 0
    fi
  done
  return 1
}

WORK="$(pick_dir || true)"
if [ -z "$WORK" ]; then
  echo "[9router] ERROR: no writable directory (tried INSTALL_DIR, \$PWD, \$HOME, /tmp, /var/tmp)" >&2
  exit 1
fi
cd "$WORK"
[ "$WORK" = "$PWD" ] || echo "[9router] working directory: $WORK"

PORT="${SERVER_PORT:-}"
[ -z "$PORT" ] && PORT="${SERVER_ALLOCATION_PORT:-}"
[ -z "$PORT" ] && PORT="${LISTEN_PORT:-}"
[ -z "$PORT" ] && PORT="${PORT:-}"

# Panels like Wispbyte hand every user a different allocation, and not all eggs
# export SERVER_PORT. Fall back to a remembered port, then ask, then default.
if [ -z "$PORT" ] && [ -f ".port" ]; then
  PORT=$(tr -d ' \t\r\n' < .port 2>/dev/null || true)
fi

if [ -z "$PORT" ]; then
  if [ -t 0 ] && [ -t 1 ]; then
    echo "[9router] No SERVER_PORT from the panel."
    printf '[9router] Port to listen on [10000]: '
    read -r PORT_IN || PORT_IN=""
    PORT="${PORT_IN:-10000}"
  else
    PORT=10000
    echo "[9router] WARN: panel provided no port; defaulting to $PORT (set SERVER_PORT to override)"
  fi
fi

case "$PORT" in
  ''|*[!0-9]*)
    echo "[9router] ERROR: invalid port '$PORT' (must be numeric)" >&2
    exit 1
    ;;
esac
printf '%s' "$PORT" > .port 2>/dev/null || true
DATA="${DATA_DIR:-./data}"
APP_HOME="$PWD/app-home"
mkdir -p "$DATA" "$APP_HOME"

# npm resolves its cache as $HOME/.npm. On Wispbyte $HOME is the read-only
# /home/container, so npm dies with EACCES before it downloads anything.
# Pin every npm path into our writable work dir instead.
NPM_CACHE="$APP_HOME/.npm-cache"
NPM_TMP="$APP_HOME/.npm-tmp"
PREFIX="$APP_HOME/npm"
mkdir -p "$NPM_CACHE" "$NPM_TMP" "$PREFIX" 2>/dev/null || true
export npm_config_cache="$NPM_CACHE"
export npm_config_tmp="$NPM_TMP"
export npm_config_prefix="$PREFIX"
export npm_config_update_notifier=false
export TMPDIR="$NPM_TMP"

# If $HOME itself is unwritable, repoint it so anything else that follows the
# convention ($HOME/.config, $HOME/.cache) lands somewhere usable.
if [ -n "${HOME:-}" ] && [ ! -w "$HOME" ]; then
  export HOME="$PWD"
  echo "[9router] HOME was read-only; using $HOME"
fi

need() { command -v "$1" >/dev/null 2>&1; }

need node || { echo "[9router] ERROR: node not found on PATH" >&2; exit 1; }

NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$NODE_MAJOR" -lt 20 ]; then
  echo "[9router] ERROR: Node >= 20.9 required, found $(node -v)" >&2
  echo "[9router] hint: switch the egg image, or install Node 22" >&2
  exit 1
fi

# ---------- install / update ----------
# npm install needs the cache, a staging tree, AND the final tree simultaneously.
# On a small egg that is what triggers ENOSPC. Fetching the registry tarball and
# extracting it in one pass costs ~53 MB total instead of several hundred.
WANT="${NINEROUTER_VERSION:-latest}"
MARK="$APP_HOME/.installed_version"
CUR=""
[ -f "$MARK" ] && CUR=$(cat "$MARK" 2>/dev/null || true)

APP="$APP_HOME/pkg/package/app"

resolve_version() {
  if [ "$WANT" != "latest" ]; then
    printf '%s' "$WANT"
    return 0
  fi
  # Prefer the registry's dist-tags over npm CLI (works with node alone).
  node -e '
    fetch("https://registry.npmjs.org/9router", {redirect:"follow"})
      .then(r => r.json())
      .then(d => { const v = d["dist-tags"] && d["dist-tags"].latest; if (v) console.log(v); })
      .catch(() => {});
  ' 2>/dev/null || true
}

TARGET="$(resolve_version)"
[ -z "$TARGET" ] && TARGET="$CUR"

if [ -d "$APP" ] && [ -n "$TARGET" ] && [ "$CUR" = "$TARGET" ]; then
  echo "[9router] already at $TARGET"
else
  [ -n "$TARGET" ] || TARGET="latest"
  echo "[9router] installing 9router@$TARGET (direct extract, no npm)"

  URL="https://registry.npmjs.org/9router/-/9router-$TARGET.tgz"

  # Drop any previous tree first; a failed extract otherwise doubles usage.
  rm -rf "$APP_HOME/pkg" 2>/dev/null || true
  mkdir -p "$APP_HOME/pkg"

  # extract.js streams the tarball through memory, so no .tgz ever lands on
  # disk. Peak usage is only the extracted tree (~53 MB).
  if ! node "$WORK/extract.js" "$URL" "$APP_HOME/pkg"; then
    echo "[9router] ERROR: install failed (out of disk space?)" >&2
    echo "[9router] need ~60 MB free in $WORK" >&2
    exit 1
  fi
fi

# ---------- repair: sql.js wasm ----------
# 9router's published tarball ships sql.js/dist/sql-wasm.js but NOT the
# sql-wasm.wasm it loads, so every driver fails with
#   [DB] No SQLite driver available (bun/better/node/sql.js all failed)
# Pull the matching wasm straight from the CDN and drop it beside the loader.
SQLJS_DIR="$APP/node_modules/sql.js/dist"
if [ -d "$SQLJS_DIR" ] && [ ! -f "$SQLJS_DIR/sql-wasm.wasm" ]; then
  SQLJS_VER=$(node -p 'require("'"$APP"'/node_modules/sql.js/package.json").version' 2>/dev/null || echo "")
  [ -z "$SQLJS_VER" ] && SQLJS_VER="1.14.2"
  echo "[9router] repairing sql.js wasm (v$SQLJS_VER)"
  if node -e '
    const fs = require("fs");
    const [url, dest] = process.argv.slice(1);
    fetch(url, {redirect:"follow"}).then(async r => {
      if (!r.ok) { console.error("HTTP " + r.status); process.exit(2); }
      const b = Buffer.from(await r.arrayBuffer());
      if (b.length < 100000) { console.error("too small: " + b.length); process.exit(3); }
      fs.writeFileSync(dest, b);
      console.log("[9router] sql wasm " + Math.round(b.length/1024) + " KB");
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "https://cdn.jsdelivr.net/npm/sql.js@${SQLJS_VER}/dist/sql-wasm.wasm" "$SQLJS_DIR/sql-wasm.wasm"; then
    echo "[9router] WARN: could not fetch sql wasm; DB features will be disabled" >&2
  fi
fi

[ -d "$APP" ] || { echo "[9router] ERROR: app payload missing at $APP" >&2; exit 1; }
[ -n "$TARGET" ] && printf '%s' "$TARGET" > "$MARK" 2>/dev/null || true

# ---------- secrets ----------
if [ -z "${JWT_SECRET:-}" ]; then
  if [ -f "$DATA/jwt-secret" ]; then
    JWT_SECRET=$(cat "$DATA/jwt-secret")
  else
    JWT_SECRET=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    printf '%s' "$JWT_SECRET" > "$DATA/jwt-secret"
    chmod 600 "$DATA/jwt-secret" 2>/dev/null || true
  fi
fi
export JWT_SECRET

if [ -z "${INITIAL_PASSWORD:-}" ]; then
  INITIAL_PASSWORD="admin-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  printf '%s' "$INITIAL_PASSWORD" > "$DATA/initial-password"
  chmod 600 "$DATA/initial-password" 2>/dev/null || true
  echo ""
  echo "=============================================================="
  echo "  9router dashboard password (saved to $DATA/initial-password)"
  echo "  $INITIAL_PASSWORD"
  echo "=============================================================="
  echo ""
fi
export INITIAL_PASSWORD

# ---------- runtime env, tuned for small hosts ----------
export PORT
export HOSTNAME="0.0.0.0"
export NODE_ENV="production"
export DATA_DIR="$DATA"
export NEXT_TELEMETRY_DISABLED=1
export AUTH_COOKIE_SECURE="${AUTH_COOKIE_SECURE:-false}"

# The bundled Next server was compiled with its own distDir; keep it intact and
# run from the package dir so relative asset paths resolve.
cd "$APP"

# Node sizes its heap from total system RAM, which is far too eager on a 512 MB
# egg. Measured steady-state here is ~79 MB.
HEAP="${NODE_MAX_OLD_SPACE:-320}"
echo "[9router] starting on 0.0.0.0:${PORT} (heap cap ${HEAP} MB)"
exec node --max-old-space-size="$HEAP" server.js
