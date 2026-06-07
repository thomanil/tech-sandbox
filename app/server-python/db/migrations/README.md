# Database migrations (dbmate)

Schema changes for the timeline server live here as plain, versioned SQL files and
are applied with [dbmate](https://github.com/amacneil/dbmate) — a single static Go
binary, language-agnostic, plain SQL up/down migrations. It fits this project's
"simple SQL, no ORM" stance and reads the **same `DATABASE_URL`** the app uses
(`postgres://…`), so nothing is translated between environments.

Current migrations:

- `0001_create_timeline_schema.sql` — the `timeline` schema; all app tables live
  under it from here on.
- `0002_create_client_state.sql` — `timeline.client_state`, the per-client model
  snapshot the server upserts on each tick/command and loads on startup (so clients
  resume after a pod restart). See `../../timeline_server.py`.

## How it runs

The server applies pending migrations **automatically on startup** —
`run_migrations()` in `../../timeline_server.py` shells out to `dbmate migrate`
before it serves any request, so the schema is ready before traffic. The `dbmate`
binary is baked into the image (see the `Dockerfile`); migrations land at
`/app/db/migrations`. A failed migration (or an unreachable DB) makes dbmate exit
non-zero, which aborts startup loudly; in k8s the pod then CrashLoops until fixed.

dbmate tracks applied versions in a `schema_migrations` table (just the version
string per applied file), so a re-run is a no-op once everything's applied.

Run it by hand (same files, same DB) — `DATABASE_URL` is read from the environment:

```
DATABASE_URL=postgres://… dbmate --migrations-dir ./app/server-python/db/migrations migrate   # apply pending
DATABASE_URL=postgres://… dbmate --migrations-dir ./app/server-python/db/migrations status    # list applied/pending
DATABASE_URL=postgres://… dbmate --migrations-dir ./app/server-python/db/migrations rollback  # undo the last one
```

We use `migrate` (not `up`) so dbmate never tries to CREATE the database — it always
already exists (the compose `postgres` container, or the UpCloud managed service).

## File format

One file per migration, applied in version order. dbmate takes the version from the
leading digits before the first underscore, and each file has an up and a down
section:

```sql
-- migrate:up
CREATE TABLE timeline.example (id BIGINT PRIMARY KEY);

-- migrate:down
DROP TABLE timeline.example;
```

Add the next change as `0003_<name>.sql` (keep the zero-padded numeric prefix so
ordering is lexicographic). `dbmate new <name>` can scaffold one, but it defaults to
a 14-digit timestamp prefix — either is fine as long as it sorts correctly.

## Concurrency & locking

dbmate guards against two processes migrating at once with a **PostgreSQL advisory
lock** (`pg_advisory_lock`): the first process to start migrating holds it, others
block until it's released, then find nothing pending and no-op. Crucially, an
advisory lock is tied to the session and is **released automatically when the
connection drops** — so a process that crashes mid-migration does *not* leave a
stale lock behind (a sharp edge that table-based lock schemes have).

Today the server is single-replica with a `Recreate` strategy, so in practice only
one process ever migrates. The advisory lock makes migrate-on-startup safe for more
nodes too, should that ever change — though note the app must not scale past one
replica regardless while state is in-process (see `../../timeline_server.py`).
