# Database & persistence

The persistence base case (README's eighth iteration): the server talks to Postgres
the **same way in every environment**, driven by a single `DATABASE_URL`. On startup
it applies migrations and **loads each client's saved model state**, and at runtime
it **writes that state through on every change**, so clients resume after a pod
restart/redeploy. The in-process `states` dict is still the source of truth while
running — Postgres is its durable mirror — and the single-replica/`Recreate` rule is
unchanged (see "Persistence doesn't mean scale-out" below).

> **Related:**
> - Remote managed DB: provisioning + the password Secret → [`upcloud-postgres.md`](upcloud-postgres.md).
> - Migration conventions + concurrency/locking → [`../app/server-python/db/migrations/README.md`](../app/server-python/db/migrations/README.md).

## The transparency model: one `DATABASE_URL`

The server never branches on environment. It reads a single `DATABASE_URL` env var
(a libpq connection string) and behaves identically everywhere; only the *source* of
that variable and one token inside it (`sslmode`) change:

| Environment | Source of `DATABASE_URL` | TLS |
| --- | --- | --- |
| Local docker-compose | plain `environment:` value, cleartext, in version control | `sslmode=disable` |
| Local minikube | plain `env.value` in the manifest, pointing at the compose Postgres via `host.minikube.internal:5432` | `sslmode=disable` |
| **UpCloud** | **k8s Secret `timeline-db`** (carries the password, never committed) | **`sslmode=require`** |

Unset `DATABASE_URL` means "no DB": the server still boots and skips migrations
(handy for quick `uv run app/server-python/timeline_server.py` dev). Set but
unreachable is **fatal** on startup.

Because the local Postgres is published on the host's `:5432`, the minikube pods
reach that **same** container via `host.minikube.internal` — so `docker compose up`
must be running for a minikube deploy to come up.

## Drivers

The app's runtime DB access uses **psycopg 3** (`psycopg[binary]` + `psycopg-pool`):
libpq-native, so the connection string UpCloud hands you drops in verbatim and the
`sslmode` token is honored straight from the URL — no code branch between local
(`disable`) and remote (`require`). The binary wheel means no compiler or libpq on
the slim image.

Migrations are run by **dbmate** (below), a separate single static Go binary — not a
Python dependency.

## Migrations on startup

On startup the server applies any pending migrations with
[dbmate](https://github.com/amacneil/dbmate) (a single static binary baked into the
image; plain SQL up/down files) **before** it serves a request, so the schema is
ready before traffic. `run_migrations()` in `../app/server-python/timeline_server.py`
shells out to `dbmate migrate`.

- It's **fatal**: a missing/unreachable DB or a failing migration makes dbmate exit
  non-zero, which aborts startup and (in k8s) CrashLoops the pod, rather than serving
  on a bad/half-applied schema.
- It's **logged**: look for `MIGRATIONS: running dbmate migrate …` → dbmate's own
  `Applying:`/`Applied:` lines → `MIGRATIONS: done — schema up to date`.
- dbmate uses the same `DATABASE_URL` the app does (no translation) and tracks
  applied versions in a `schema_migrations` table; re-runs are no-ops.
- Concurrency is handled by a **PostgreSQL advisory lock** that auto-releases on
  disconnect (no stale-lock problem). Current migrations create the `timeline`
  schema (`0001`) and the `timeline.client_state` table (`0002`). Conventions +
  the full locking story are in
  [`../app/server-python/db/migrations/README.md`](../app/server-python/db/migrations/README.md).

## Client state persistence

So a client resumes after a pod restart/redeploy, each client's model state is
mirrored to `timeline.client_state` (one row per `client_id` seed — the active
sequence, every sequence's remembered position as JSONB, and the play flag).

- **Load on startup.** After migrations, `open_state_pool()` loads every row back
  into the in-memory `states` dict (`STATE: loaded N persisted client model(s)`), so
  a client reconnecting with its seed picks up where it left off.
- **Write-through, fire-and-forget.** State is upserted on every change — each tick
  of a playing client, each command, and a new client's first connect — via
  `persist_state_bg()`, which schedules the write and returns immediately. A
  tick/command never waits on the DB, and a failed write is logged, never fatal.
- **Connection pool.** Writes go through a small `psycopg-pool` `AsyncConnectionPool`
  (opened in `lifespan`) rather than one shared connection, since fire-and-forget
  writes can overlap; the pool also reconnects transparently if the DB bounces and
  backs the `/readyz` check.

### Persistence doesn't mean scale-out

Persisting state does **not** make the server horizontally scalable. Two replicas
would each load all rows on startup and then clobber each other's write-through
updates (last-writer-wins, diverging in-memory state). State is still owned by one
process; the table is a restart-resume mirror, not a shared store. So the
`replicas: 1` + `Recreate` rule stands — scaling out would require making the DB
(or another store) the live source of truth, not just a mirror.

## Health probes are split

Liveness and readiness now use different endpoints, so a DB outage degrades rather
than restart-loops:

- **`GET /healthz`** (liveness) — cheap and DB-free. A DB blip must never restart a
  healthy process.
- **`GET /readyz`** (readiness, and the compose healthcheck) — pings the DB and
  returns **503** when it's down, logging a loud `READINESS FAILED: …` line. k8s
  then pulls the pod from the load balancer (clients rejected) without killing it.

## Operational notes

### minikube → host Postgres needs a trailing-dot FQDN

The minikube manifests point `DATABASE_URL` at `host.minikube.internal.` — **with a
trailing dot**. That's deliberate: the pod's `resolv.conf` uses `ndots:5` plus
several search domains (including, on this dev box, a Tailscale one), so the short
name `host.minikube.internal` gets tried against every search domain first, and a
slow one adds ~6s to *every* lookup. That delay isn't bounded by `connect_timeout`
(it's DNS, before the connect), so it blows past the `/readyz` 3s probe timeout and
the pod never becomes `Ready` — the NodePort Service then has no endpoints and
clients silently can't connect (even though startup migrations and `/healthz`
succeed). The trailing dot makes the name a FQDN, so the resolver skips the search
domains and resolves in ~0ms. Don't "tidy up" the dot.
