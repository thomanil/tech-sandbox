# Database migrations (yoyo-migrations)

Schema changes for the timeline server live here as plain, versioned SQL files and
are applied with [yoyo-migrations](https://ollycope.com/software/yoyo/). yoyo is the
closest Python analogue to Flyway: hand-written SQL, explicit version ordering, no
ORM — which matches this project's "simple SQL, no ORM" stance.

> The migration set starts **empty**: this iteration wires up the runner (so the
> deployment plumbing and concurrency story are settled), but doesn't yet persist
> any timeline state. Drop a `.sql` file in here and it applies on the next start.

## How it runs

The server applies pending migrations **automatically on startup** —
`run_migrations()` in `../../timeline_server.py`, called from the FastAPI `lifespan`
before it serves any request, so the schema is ready before traffic. It reads this
directory and connects with the same transparent `DATABASE_URL` the rest of the app
uses (rewritten to the `postgresql+psycopg://` scheme so yoyo reuses our psycopg 3
driver — no psycopg2). A failed migration (or an unreachable DB) aborts startup
loudly; in k8s the pod then CrashLoops until it's fixed.

Ad-hoc / manual run (same files, same DB) with the yoyo CLI:

```
yoyo apply   --database "$DATABASE_URL" ./app/server-python/db/migrations
yoyo rollback --database "$DATABASE_URL" ./app/server-python/db/migrations
yoyo list    --database "$DATABASE_URL" ./app/server-python/db/migrations
```

yoyo tracks applied versions in the `_yoyo_migration` table and creates its
bookkeeping tables (`_yoyo_migration`, `_yoyo_log`, `_yoyo_version`, `yoyo_lock`) in
the target database on first run.

## Naming convention

One file per migration, applied in lexicographic order — so zero-pad the prefix
(Flyway's `V1__init.sql` becomes `0001_init.sql`):

```
0001_create_timeline_state.sql            # the "up" / apply SQL
0001_create_timeline_state.rollback.sql   # the matching "down" / rollback SQL
```

yoyo only picks up `*.sql` and `*.py` files, so the `*.sql.example` template in this
directory is inert — rename it (dropping `.example`) to turn it into a real, applied
migration.

## Concurrency & locking (read before scaling past one node)

yoyo prevents two processes from migrating at once with a **lock table**, not a
Postgres advisory lock. Before applying, it `INSERT`s a single row into a
`yoyo_lock` table inside a transaction. The mechanics (verified against yoyo's
source):

- A second/concurrent process's `INSERT` collides with the existing row and fails;
  yoyo **retries every ~0.5s for up to a 10s default timeout**, then raises
  `yoyo.exceptions.LockTimeout`. So a concurrent starter **waits**, and then either
  acquires the lock (finds nothing pending → no-op) or times out.
- Each migration runs in **its own transaction** (PostgreSQL has transactional DDL;
  savepoints isolate steps within a migration), so a failed migration rolls back
  cleanly — no half-applied migration is left behind.
- **Sharp edge:** because the lock is a table row — not an advisory lock that the
  database auto-releases when the connection drops — a process that **crashes
  mid-migration leaves a stale lock**. Later starts then `LockTimeout` until someone
  clears it:

  ```
  yoyo break-lock --database "$DATABASE_URL" ./app/server-python/db/migrations
  ```

### Today vs. future

Today the server is **single-replica with a `Recreate` strategy** — the old pod is
gone before the new one starts — so there is **no real concurrency**: exactly one
process ever migrates. yoyo's lock makes migrate-on-startup safe for a handful of
nodes too, but it has rough edges at scale: every replica races for the lock on each
rollout; a migration that runs longer than the 10s lock timeout CrashLoops the late
waiters; a crash leaves a stale lock; and a rolling deploy can briefly run old and
new code against a freshly-migrated schema.

The robust pattern when that day comes: run migrations as a **one-shot Kubernetes
Job (or an initContainer)** using this same image — gated to run once before the app
rollout — so the application pods never migrate and never race. The migrations are
deliberately baked into the image (`COPY app/server-python/db ./db` in the
`Dockerfile`, landing at `/app/db/migrations`) precisely so that Job can reuse them.
Note this is moot until the in-memory state is externalized, since the app must not
scale past one replica regardless (see `../../timeline_server.py`).
