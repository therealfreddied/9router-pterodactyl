# 9router — one-command deploy for Pterodactyl / bare hosts

Runs the **latest official [9router](https://www.npmjs.com/package/9router)** release.
No Docker. No build step. No repo build — it installs the published package.

## How it stays current

`npm view 9router version` resolves the newest release on every boot, compares
it against the cached marker, and reinstalls only when it changed. There are 228
published versions, so `latest` tracks upstream closely.

## Why not just run `9router`?

The CLI refuses to bind a public interface:

```
⚠ Network-exposed: reachable at http://172.17.0.3:20128 (bound 0.0.0.0)
Exiting...
```

It's built for desktop use. This repo installs the package for its app payload
and launches the bundled Next.js server (`server.js`) directly, which binds
`$PORT` on `0.0.0.0` happily.

## RAM

Measured in a hard cgroup with swap disabled:

| Metric | Value |
|---|---|
| Steady RSS | **79 MB** |
| Recommended allocation | **512 MB** |
| Absolute floor | ~256 MB, untested under load |

Node's default heap sizing assumes the whole machine is yours. This script caps
it at 320 MB so the OOM reaper doesn't take the container.

## Requirements

- **Node >= 20.9** (Next.js 16.3.4). The script checks and fails with a clear
  message rather than a stack trace.
- ~350 MB disk for the package plus data.

## Deploy

```
sh start.sh
```

Or with an explicit port:

```sh
SERVER_PORT=10000 sh start.sh
```

First run installs from npm (a few minutes). Later runs are instant.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `SERVER_PORT` | `10000` | Port to bind |
| `DATA_DIR` | `./data` | Persistent data + generated secrets |
| `JWT_SECRET` | generated | Persisted to `$DATA_DIR/jwt-secret` |
| `INITIAL_PASSWORD` | generated | Persisted to `$DATA_DIR/initial-password` |
| `NINEROUTER_VERSION` | `latest` | Pin a version |
| `NODE_MAX_OLD_SPACE` | `320` | Node heap cap in MB |
| `AUTH_COOKIE_SECURE` | `false` | Set `true` behind HTTPS |

## Verify

```sh
curl -i http://127.0.0.1:10000/api/health   # 200 {"ok":true}
```

Then open the port in a browser and log in with the printed password.

## Persistence

Everything lives in `DATA_DIR`. On a panel that wipes the container on restart,
point `DATA_DIR` at a persistent volume or keep the folder between deploys.

## Notes

- 9router is a proxy gateway. Some free hosts ban proxy workloads in their ToS —
  this is a technical deploy, not permission to run it anywhere.
- `data/`, `app-home/`, and generated secrets are gitignored.
