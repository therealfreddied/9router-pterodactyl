#!/bin/sh
# 9router — persistent-payload bootstrap for Pterodactyl / bare hosts.
#
# Installs ONCE into a persistent directory, then boots. Re-running after the
# payload is in place does no network work at all.
#
# Order of preference for the install directory:
#   1. $INSTALL_DIR            (explicit; use this for a persistent volume)
#   2. /home/container         (Pterodactyl's persistent server dir)
#   3. /home/node, /tmp, /var/tmp
#
# Payload source, first match wins:
#   1. a local 9router-payload.tar.gz in the install dir (upload via file manager)
#   2. the GitHub release asset (downloaded once)

set -eu

PAYLOAD_VERSION="${PAYLOAD_VERSION:-1}"
RELEASE_BASE="${RELEASE_BASE:-https://github.com/therealfreddied/9router-payload/releases/download/v1}"
PAYLOAD_URL="${PAYLOAD_URL:-$RELEASE_BASE/9router-payload.tar.gz}"

need() { command -v "$1" >/dev/null 2>&1; }

need node || { echo "[9router] ERROR: node not found on PATH" >&2; exit 1; }

NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$NODE_MAJOR" -lt 20 ]; then
  echo "[9router] ERROR: Node >= 20.9 required, found $(node -v)" >&2
  exit 1
fi

# ---------- pick the install dir ----------
writable() { d="$1"; [ -n "$d" ] || return 1; mkdir -p "$d" 2>/dev/null || return 1
  ( : > "$d/.wtest.$$" ) 2>/dev/null || return 1; rm -f "$d/.wtest.$$" 2>/dev/null; return 0; }

BASE=""
for cand in "${INSTALL_DIR:-}" "/home/container" "$HOME" "/home/node" "/tmp" "/var/tmp"; do
  if writable "$cand"; then BASE="$cand"; break; fi
done
[ -n "$BASE" ] || { echo "[9router] ERROR: no writable install directory" >&2; exit 1; }
echo "[9router] install dir: $BASE"

APP="$BASE/9router/app"
MARK="$BASE/9router/.installed"

# ---------- port ----------
PORT="${SERVER_PORT:-}"
[ -z "$PORT" ] && PORT="${SERVER_ALLOCATION_PORT:-}"
[ -z "$PORT" ] && PORT="${LISTEN_PORT:-}"
[ -z "$PORT" ] && PORT="${PORT:-}"
if [ -z "$PORT" ] && [ -f "$BASE/.port" ]; then
  PORT=$(tr -d ' \t\r\n' < "$BASE/.port" 2>/dev/null || true)
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
printf '%s' "$PORT" > "$BASE/.port" 2>/dev/null || true

# ---------- install (only if missing) ----------
if [ -f "$APP/server.js" ] && [ -f "$MARK" ]; then
  echo "[9router] payload already installed ($(cat "$MARK" 2>/dev/null || echo unknown))"
else
  echo "[9router] installing payload (one time)..."
  mkdir -p "$BASE/9router"

  LOCAL_TGZ=""
  for t in "/home/container/9router-payload.tar.gz" "$BASE/9router-payload.tar.gz" "$BASE/9router/9router-payload.tar.gz" "$PWD/9router-payload.tar.gz"; do
    if [ -f "$t" ]; then LOCAL_TGZ="$t"; break; fi
  done

  EXTRACT=""
  for e in "$BASE/9router/extract.js" "$(dirname "$0")/extract.js" "$PWD/extract.js" "/tmp/extract.js"; do
    if [ -f "$e" ]; then EXTRACT="$e"; break; fi
  done
  if [ -z "$EXTRACT" ]; then
    echo "[9router] ERROR: extract.js not found (bootstrap should fetch it)" >&2
    exit 1
  fi
  echo "[9router] using extractor: $EXTRACT"

  if [ -n "$LOCAL_TGZ" ]; then
    echo "[9router] using local payload: $LOCAL_TGZ"
    node "$EXTRACT" "$LOCAL_TGZ" "$BASE" || { echo "[9router] ERROR: extract failed" >&2; exit 1; }
  else
    echo "[9router] downloading payload from $PAYLOAD_URL"
    node "$EXTRACT" "$PAYLOAD_URL" "$BASE" || {
      echo "[9router] ERROR: payload download/extract failed" >&2
      echo "[9router] hint: upload 9router-payload.tar.gz to $BASE via the file manager" >&2
      exit 1
    }
  fi

  [ -f "$APP/server.js" ] || { echo "[9router] ERROR: payload missing server.js" >&2; exit 1; }
  printf '%s' "$PAYLOAD_VERSION" > "$MARK"
  echo "[9router] payload installed"
fi

# ---------- data dir ----------
DATA="${DATA_DIR:-$BASE/9router/data}"
mkdir -p "$DATA" 2>/dev/null || DATA="$BASE/data" && mkdir -p "$DATA"

# ---------- secrets (persist so restarts keep the same password) ----------
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
  if [ -f "$DATA/initial-password" ]; then
    INITIAL_PASSWORD=$(cat "$DATA/initial-password")
  else
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

cd "$BASE/9router"
echo "[9router] starting on 0.0.0.0:${PORT} (data: $DATA)"
exec node app/server.js
