# Managed Postgres on UpCloud

The public deployment persists to a **managed Postgres 18** service on UpCloud —
provisioned out of band in the UpCloud Hub, the same way the managed Kubernetes
cluster is (it is **not** a pod in the cluster). The server reaches it over TLS and
applies any pending migrations on startup.

> **Related:**
> - Deploy mechanics (Argo CD, Image Updater, kubeconfig) → [`upcloud-deployment.md`](upcloud-deployment.md).
> - Recreating the cluster from scratch → [`upcloud-create-cluster.md`](upcloud-create-cluster.md).
> - Migrations + the concurrency/locking story → [`../app/server-python/db/migrations/README.md`](../app/server-python/db/migrations/README.md).

## The transparency model: one `DATABASE_URL`

The server never branches on environment. It reads a single `DATABASE_URL` env var
(a libpq connection string) and behaves identically everywhere; only the *source*
of that var and one token inside it differ:

| Environment | Source of `DATABASE_URL` | TLS |
| --- | --- | --- |
| Local docker-compose | plain `environment:` value, cleartext, in version control | `sslmode=disable` |
| Local minikube (`overlays/local`) | plain `env.value` in the overlay, pointing at an **in-cluster** `timeline-postgres` the overlay bundles (PVC + Deployment + Service) | `sslmode=disable` |
| Published-image minikube (`overlays/published`) | plain `env.value` pointing at the host's compose Postgres via `host.minikube.internal.:5432` | `sslmode=disable` |
| **UpCloud** | **k8s Secret `timeline-db`** (carries the password, never committed) | **`sslmode=require`** |

Unset `DATABASE_URL` means "no DB": the server still boots and skips migrations
(handy for quick `uv run timeline_server.py` dev). Set-but-unreachable is **fatal**
on startup — the pod CrashLoops rather than serving on a missing schema.

## Provisioning the managed service

1. In the UpCloud Hub, create a **Managed Database → PostgreSQL**, version **18**.
2. Allow access from the Kubernetes cluster (add the cluster's egress IP / network
   to the database's allowed-IP list; for a quick start UpCloud also offers "allow
   all", same trade-off as the cluster's IP access).
3. From the service's **Connection details**, note `host`, `port`, `username`
   (`upadmin`), `password`, and the default database (`defaultdb`). These compose
   the `DATABASE_URL` below. The current service:
   - host: `postgres-sydqtmadgayy.db.upclouddatabases.com`
   - port: `11569`
   - user: `upadmin`
   - db: `defaultdb`

## The `timeline-db` Secret

The DSN carries the DB password, so it lives in a k8s Secret created out of band
(like the kubeconfig and the TLS cert bundle), never in the repo. The upcloud
overlay's Deployment patch
(`k8s/timeline-server/overlays/upcloud/kustomization.yaml`) references it via
`secretKeyRef`, so **the Secret must exist before the first deploy** (before Argo
CD first syncs) or the pod stays in `CreateContainerConfigError`.

Create it (note `sslmode=require` — UpCloud enforces TLS):

```bash
kubectl --kubeconfig ~/.secrets/tech-sandbox-upcloud-k8s-cluster_kubeconfig.yaml \
  create secret generic timeline-db \
  --from-literal=DATABASE_URL='postgres://upadmin:<PASSWORD>@postgres-sydqtmadgayy.db.upclouddatabases.com:11569/defaultdb?sslmode=require'
```

Rotate it (e.g. after a password reset) by replacing the Secret and restarting the
pod so it re-reads the value:

```bash
kubectl --kubeconfig ~/.secrets/...kubeconfig.yaml delete secret timeline-db
kubectl --kubeconfig ~/.secrets/...kubeconfig.yaml create secret generic timeline-db \
  --from-literal=DATABASE_URL='postgres://upadmin:<NEW_PASSWORD>@...:11569/defaultdb?sslmode=require'
kubectl --kubeconfig ~/.secrets/...kubeconfig.yaml rollout restart deployment/timeline-server
```

## How the server uses it

On startup the server applies pending migrations against `DATABASE_URL`
(`run_migrations()` in `app/server-python/timeline_server.py`, which shells out to
[dbmate](https://github.com/amacneil/dbmate)) before it serves any request. The
readiness probe (`GET /readyz`) re-checks reachability on every poll; the liveness
probe (`GET /healthz`) stays cheap and DB-free, so a DB outage de-registers the pod
from the load balancer without restart-looping it. Migration conventions and the
advisory-lock concurrency behavior are documented in
[`../app/server-python/db/migrations/README.md`](../app/server-python/db/migrations/README.md).

## Verifying

```bash
kubectl --kubeconfig ~/.secrets/...kubeconfig.yaml logs deployment/timeline-server --timestamps
```

Expect, near startup:

```
MIGRATIONS: applying from /app/db/migrations
MIGRATIONS: N known, M pending
MIGRATIONS: done (M applied); schema up to date
```

That line confirms the managed DB is reachable over TLS and migrations ran. On an
outage you'll instead see a loud `READINESS FAILED: database unreachable: ...` and
the pod will report `0/1` ready (but keep running). A startup that can't reach the
DB logs `MIGRATIONS: FAILED — aborting startup` and CrashLoops.

## Local equivalent

For dev, `docker-compose.yml` stands up a `postgres:18` container and points the
server's `DATABASE_URL` at it (`sslmode=disable`, cleartext creds). The two
minikube overlays differ in where Postgres lives: `overlays/local` bundles its
**own** in-cluster `postgres:18` (a PVC + Deployment + Service named
`timeline-postgres`) and points at it on the pod network, while
`overlays/published` reuses the host's compose container via
`host.minikube.internal.:5432`. (`overlays/local` deliberately does NOT use the
host hop — holding a psycopg pool open across it stalled the single event loop
~190ms per WebSocket send; see the overlay's `postgres.yaml` comment.) So the only
real difference remotely is the managed service + the Secret + `sslmode=require`.
