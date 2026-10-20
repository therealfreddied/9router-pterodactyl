#!/bin/sh
# 9router — zero-build bootstrap for Pterodactyl / bare hosts.
# Installs the LATEST official npm package and serves the dashboard.
#
# Why not the CLI? `9router` refuses to bind 0.0.0.0 in CLI mode. We install the
# package for its app payload, then launch its bundled Next.js server directly.

set -eu
cd "$(dirname "$0")"

PORT="${SERVER_PORT:-${PORT:-10000}}"
DATA="${DATA_DIR:-./data}"
APP_HOME="$PWD/app-home"
mkdir -p "$DATA" "$APP_HOME"

need() { command -v "$1" >/dev/null 2>&1; }

need node || { echo "[9router] ERROR: node not found on PATH" >&2; exit 1; }

NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$NODE_MAJOR" -lt 20 ]; then
  echo "[9router] ERROR: Node >= 20.9 required, found $(node -v)" >&2
  echo "[9router] hint: switch the egg image, or install Node 22" >&2
  exit 1
fi

# ---------- install / update ----------
WANT="${NINEROUTER_VERSION:-latest}"
MARK="$APP_HOME/.installed_version"
CUR=""
[ -f "$MARK" ] && CUR=$(cat "$MARK" 2>/dev/null || true)

if [ "$WANT" = "latest" ]; then
  TARGET=$(npm view 9router version --silent 2>/dev/null || true)
  [ -z "$TARGET" ] && TARGET="$CUR"
else
  TARGET="$WANT"
fi

GLOBAL_APP="$(npm root -g 2>/dev/null)/9router/app"
if [ -d "$GLOBAL_APP" ]; then
  APP="$GLOBAL_APP"
  echo "[9router] using global install at $APP"
else
  echo "[9router] installing 9router@${TARGET:-latest} (first run takes a few minutes)"
  npm install -g "9router@${TARGET:-latest}" --no-audit --no-fund --loglevel=error
  GLOBAL_APP="$(npm root -g)/9router/app"
  APP="$GLOBAL_APP"
fi

[ -d "$APP" ] || { echo "[9router] ERROR: app payload missing at $APP" >&2; exit 1; }
[ -n "$TARGET" ] && echo "$TARGET" > "$MARK" 2>/dev/null || true

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
