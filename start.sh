#!/bin/sh
# 9router — persistent-payload bootstrap for Pterodactyl / bare hosts.
#
# Installs the app payload ONCE, then just boots. Re-running when the payload
# is already present does no network work.
#
# Where things live:
#   PAYLOAD  a 9router-payload.tar.gz, ideally uploaded via the panel's file
#            manager into /home/container (persistent across reboots).
#   APPDIR   where the payload is expanded. Prefers a persistent+writable
#            location; falls back to a tmpfs when the panel gives us none.
#   DATA     SQLite database + generated secrets.
#
# Env overrides:
#   INSTALL_DIR   where to expand the payload
#   DATA_DIR      where the DB and secrets live
#   SERVER_PORT   port to bind
#   INITIAL_PASSWORD / JWT_SECRET   pin these to survive reboots

set -eu

PAYLOAD_VERSION="${PAYLOAD_VERSION:-1}"
PAYLOAD_URL="${PAYLOAD_URL:-https://github.com/therealfreddied/9router-payload/releases/download/v1/9router-payload.tar.gz}"

need() { command -v "$1" >/dev/null 2>&1; }

need node || { echo "[9router] ERROR: node not found on PATH" >&2; exit 1; }

NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$NODE_MAJOR" -lt 20 ]; then
  echo "[9router] ERROR: Node >= 20.9 required, found $(node -v)" >&2
  exit 1
fi

writable() { d="$1"; [ -n "$d" ] || return 1
  mkdir -p "$d" 2>/dev/null || return 1
  ( : > "$d/.wtest.$$" ) 2>/dev/null || return 1
  rm -f "$d/.wtest.$$" 2>/dev/null; return 0; }

# ---------- where can we actually write? ----------
# Pterodactyl's /home/container is persistent but often not writable by the
# runtime user (Wispbyte: dir owned by 999:995, runtime uid 1001). The panel's
# file manager CAN write there, which is how the payload gets uploaded.
WRITE_BASE=""
for cand in "${INSTALL_DIR:-}" "/home/container" "$HOME" "/home/node" "/tmp" "/var/tmp"; do
  if writable "$cand"; then WRITE_BASE="$cand"; break; fi
done
[ -n "$WRITE_BASE" ] || { echo "[9router] ERROR: no writable directory" >&2; exit 1; }

# Payload source: a file the panel gave us, else the published release.
PAYLOAD_TGZ=""
for t in "/home/container/9router-payload.tar.gz" "/home/container/9router/9router-payload.tar.gz" \
         "$WRITE_BASE/9router-payload.tar.gz" "$WRITE_BASE/9router/9router-payload.tar.gz" \
         "$PWD/9router-payload.tar.gz"; do
  if [ -f "$t" ]; then PAYLOAD_TGZ="$t"; break; fi
done

# Extraction target: persistent if we can write there, else a tmpfs.
APPDIR="$WRITE_BASE/9router"
if ! writable "$APPDIR"; then
  APPDIR="/tmp/9router"
  mkdir -p "$APPDIR"
  echo "[9router] no persistent writable dir; expanding into $APPDIR (resets each reboot)"
fi

# The app payload lives at <APPDIR>/app.
APP="$APPDIR/app"
MARK="$APPDIR/.installed"

# ---------- port ----------
PORT="${SERVER_PORT:-}"
[ -z "$PORT" ] && PORT="${SERVER_ALLOCATION_PORT:-}"
[ -z "$PORT" ] && PORT="${LISTEN_PORT:-}"
[ -z "$PORT" ] && PORT="${PORT:-}"
if [ -z "$PORT" ] && [ -f "$WRITE_BASE/.port" ]; then
  PORT=$(tr -d ' \t\r\n' < "$WRITE_BASE/.port" 2>/dev/null || true)
fi
if [ -z "$PORT" ]; then
  if [ -t 0 ] && [ -t 1 ]; then
    printf '[9router] Port to listen on [10000]: '
    read -r PORT_IN || PORT_IN=""
    PORT="${PORT_IN:-10000}"
  else
    PORT=10000
    echo "[9router] WARN: no port from panel; using $PORT"
  fi
fi
case "$PORT" in
  ''|*[!0-9]*) echo "[9router] ERROR: invalid port '$PORT'" >&2; exit 1 ;;
esac
printf '%s' "$PORT" > "$WRITE_BASE/.port" 2>/dev/null || true

# ---------- install (skip if already present) ----------
if [ -f "$APP/server.js" ] && [ -f "$MARK" ]; then
  echo "[9router] payload present ($(cat "$MARK" 2>/dev/null || echo unknown)) - skipping install"
else
  EXTRACT=""
  for e in "/home/container/9router/extract.js" "$WRITE_BASE/9router/extract.js" \
           "$WRITE_BASE/extract.js" "$(dirname "$0")/extract.js" "$PWD/extract.js" "/tmp/extract.js"; do
    if [ -f "$e" ]; then EXTRACT="$e"; break; fi
  done
  if [ -z "$EXTRACT" ]; then
    echo "[9router] ERROR: extract.js not found (bootstrap should fetch it)" >&2
    exit 1
  fi

  mkdir -p "$APPDIR"
  rm -rf "$APP" 2>/dev/null || true

  if [ -n "$PAYLOAD_TGZ" ]; then
    echo "[9router] expanding local payload: $PAYLOAD_TGZ"
    node "$EXTRACT" "$PAYLOAD_TGZ" "$APPDIR" || { echo "[9router] ERROR: extract failed" >&2; exit 1; }
  else
    echo "[9router] downloading payload (one time) from $PAYLOAD_URL"
    node "$EXTRACT" "$PAYLOAD_URL" "$APPDIR" || {
      echo "[9router] ERROR: payload download/extract failed" >&2
      echo "[9router] hint: upload 9router-payload.tar.gz via the file manager" >&2
      exit 1
    }
    # Cache it so a later boot never needs the network.
    cp "$APPDIR/9router-payload.tar.gz" "$WRITE_BASE/9router-payload.tar.gz" 2>/dev/null || true
  fi

  [ -f "$APP/server.js" ] || { echo "[9router] ERROR: payload missing server.js" >&2; exit 1; }
  printf '%s' "$PAYLOAD_VERSION" > "$MARK"
  echo "[9router] payload ready at $APP"
fi

# ---------- data dir ----------
DATA="${DATA_DIR:-$WRITE_BASE/9router-data}"
if ! writable "$DATA"; then
  DATA="$WRITE_BASE/data"
  mkdir -p "$DATA" 2>/dev/null || true
fi

# ---------- secrets ----------
if [ -z "${JWT_SECRET:-}" ]; then
  if [ -f "$DATA/jwt-secret" ]; then
    JWT_SECRET=$(cat "$DATA/jwt-secret")
  else
    JWT_SECRET=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    printf '%s' "$JWT_SECRET" > "$DATA/jwt-secret" 2>/dev/null || true
  fi
fi
export JWT_SECRET

if [ -z "${INITIAL_PASSWORD:-}" ]; then
  if [ -f "$DATA/initial-password" ]; then
    INITIAL_PASSWORD=$(cat "$DATA/initial-password")
  else
    INITIAL_PASSWORD="admin-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s' "$INITIAL_PASSWORD" > "$DATA/initial-password" 2>/dev/null || true
    echo ""
    echo "=============================================================="
    echo "  9router dashboard password (saved to $DATA/initial-password)"
    echo "  $INITIAL_PASSWORD"
    echo "=============================================================="
    echo ""
  fi
fi
export INITIAL_PASSWORD

# ---------- boot ----------
export PORT
export HOSTNAME="0.0.0.0"
export NODE_ENV="production"
export DATA_DIR="$DATA"
export NEXT_TELEMETRY_DISABLED=1
export AUTH_COOKIE_SECURE="${AUTH_COOKIE_SECURE:-false}"
export NODE_OPTIONS="--max-old-space-size=${NODE_MAX_OLD_SPACE:-320}"

cd "$APPDIR"
echo "[9router] starting on 0.0.0.0:${PORT} (app: $APP, data: $DATA)"
exec node app/server.js
