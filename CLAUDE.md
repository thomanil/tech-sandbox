# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A tech-learning sandbox built around one tiny app: a scrolling-number timeline
with playback controls (back / play / stop / forward). The app is deliberately
trivial — the point of the repo is the **deployment evolution** around it,
documented as eight iterations in `README.md` (local Qt script → WebSocket state
server → Docker → minikube → GHCR/CI → UpCloud managed k8s → web client → Postgres
persistence base case). When
making changes, read the relevant README iteration section first; it explains the
*why* behind each manifest, script, and Dockerfile stage in far more depth than
the code comments.

## Architecture

Three deployables, one wire protocol:

- **`app/server-python/`** — the authoritative state server. `timeline_server.py`
  (FastAPI/uvicorn) owns all state and the playback ticker; `timeline_model.py`
  is the pure domain model (sequences + position). The server imports the model
  as a **sibling module** (`from timeline_model import ...`), so the two files
  must stay side by side — the Dockerfile flattens both into `/app`.
- **`app/client-python-qt/`** — `timeline_client.py`, a thin PySide6 GUI renderer.
  Holds no state; sends commands, draws whatever window the server pushes. Not
  containerized — runs on the desktop, connects to a published port.
- **`app/client-web/`** — a thin React/TS/Vite renderer (shadcn/ui + Tailwind v4),
  feature-equivalent to the Qt client. In the shipped image it is **baked into
  the server image** and served from the same origin as `/ws` (no second service,
  no CORS).

Key invariants to preserve:

- **State is per-client; in-memory is the source of truth, Postgres is its mirror.**
  Each client generates a random integer seed sent as `?client_id=` on the WebSocket
  URL; the server keeps one `TimelineModel` + play flag per seed in
  `states: dict[int, ClientState]` (never evicted). When a DB is configured, that
  state is mirrored to `timeline.client_state` — loaded into `states` on startup and
  written through fire-and-forget on every change (tick/command/new-connect) — so
  clients resume after a process/pod restart. Without a DB it still works, just
  resets on restart. `states` stays authoritative at runtime; the table is a
  restart-resume mirror, NOT a shared live store (see the single-replica rule).
- **Single asyncio event loop, no locks.** The WS handlers, the `ticker()` task,
  and broadcasts are cooperatively scheduled — never truly parallel — so shared
  state needs no locking. Don't introduce threads or blocking calls.
- **Must never scale past one replica.** Because state is in-process, every k8s
  manifest is `replicas: 1` with a `Recreate` strategy. A second pod would keep
  its own independent state — and DB persistence does NOT change this: two replicas
  would each load all rows and clobber each other's write-through updates. Horizontal
  scaling would require making the DB the live source of truth, not just a mirror.
- **One message shape.** The server pushes `state_message()` on connect and every
  change; both clients render it. Changing the protocol means touching all three.
- **Probes are split.** `GET /healthz` is the **liveness** probe — keep it cheap and
  side-effect-free (never touch the DB, or a DB blip restart-loops a healthy pod).
  `GET /readyz` is the **readiness** probe (and the compose healthcheck): it pings
  the DB and 503s when it's down, so an outage de-registers the pod without killing
  it.
- **DB access is transparent via one `DATABASE_URL`** (a libpq conninfo string),
  read by the server with no env branching: compose's same-network Postgres and
  minikube's own in-cluster Postgres (both defined in their manifests/compose
  file) → cleartext, `sslmode=disable`; UpCloud managed Postgres → a k8s Secret,
  `sslmode=require`. Every environment talks to a DB on its *own* internal network
  — minikube deliberately does NOT reach the host's compose DB over
  host.minikube.internal, because the server's open psycopg pool over that host
  hop stalled the single event loop ~190ms per WebSocket send and dragged playback
  to ~3 ticks/s (see `k8s/timeline-server-local.yaml`). Unset means "no DB" and the server still boots. On startup it
  applies pending migrations with **dbmate** (a single static Go binary baked into
  the image; `run_migrations()` shells out to `dbmate migrate`), fatal on failure.
  Migrations are plain SQL up/down files in `app/server-python/db/migrations/` (see
  its README for format + the advisory-lock concurrency story). Client state is then
  loaded from / written through to `timeline.client_state` via a `psycopg-pool`
  pool (psycopg 3; writes are fire-and-forget, never block a tick/command).

The server's three new-backend addresses live in **two parallel lists** that must
be kept in sync when an environment changes: `SERVERS` in
`app/client-python-qt/timeline_client.py` and `SERVERS` in
`app/client-web/src/lib/servers.ts`.

## Common commands

Dev (each script is the stable interface and live-reloads; they hide the
underlying tech). Start the server first, then one or more clients:

```
./scripts/start-local-dev-server.sh        # state server on 127.0.0.1:8000 (docker compose watch)
./scripts/start-python-client.sh # Qt GUI client (run again for a second window)
./scripts/start-local-dev-web-client.sh    # Vite/React web client w/ HMR on http://localhost:5173
```

`uv run app/server-python/timeline_server.py` also boots the backend directly
(no web client served) for quick Python-only dev.

Quality checks (cover both halves of the codebase):

```
./scripts/error_check.sh             # READ-ONLY: tsc -b + eslint (web), py_compile + ruff check/format (python). Runs all checks even if one fails, exits non-zero on any failure.
./scripts/autofix_lint_formatting.sh # write counterpart: eslint --fix, ruff check --fix, ruff format
```

A **pre-push hook** (`.githooks/pre-push`) runs `error_check.sh`. Activate once
per clone with `git config core.hooksPath .githooks`. Bypass with
`git push --no-verify`. Run `error_check.sh` before finishing any change.

Deploy / test the real artifact:

```
./scripts/deploy-minikube.sh                    # build into minikube + apply k8s/timeline-server-local.yaml
./scripts/test-latest-main-image-on-minikube.sh # pull GHCR :latest, apply k8s/timeline-server-published.yaml
./scripts/deploy-upcloud.sh                      # apply k8s/timeline-server-upcloud.yaml to UpCloud (pinned kubeconfig)
./scripts/logs-minikube.sh                       # follow server logs (kubectl logs -f, bound to one pod)
```

## Conventions

- **PEP 723 inline dependencies.** Both Python entrypoints declare their deps in a
  `# /// script` header at the top of the file — this is the single source of
  truth. `uv` resolves them into an ephemeral env at runtime; the Dockerfile runs
  `uv export --script` to install them at build time. Add/change a dep by editing
  that header, not a separate requirements file.
- **`tsc -b` then `vite build`** is the web build (see `package.json` scripts);
  the Dockerfile's `web-build` stage runs `npm ci && vite build` and copies
  `dist/` to `app/server-python/static/`, which the server mounts at `/`.
  `static/` is generated, never committed (gitignored).
- **Dockerfile base images are digest-pinned**, with the readable tag kept as a
  comment and refresh instructions inline. The image is multi-arch (amd64 + arm64).
- **CI** (`.github/workflows/build-image.yml`) builds + pushes
  `ghcr.io/thomanil/timeline-server:{latest,sha-…}` on pushes to `main` touching
  the server/Dockerfile, then runs a `deploy-upcloud` job — so a merge to `main`
  auto-deploys (and resets the single stateful pod). `main` is the source of truth
  for what runs remotely.

## Workflow rules

- Never git commit or push anything, those are done by human so diff is always reviewed
