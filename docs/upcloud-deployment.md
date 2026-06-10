# Public remote deployment on UpCloud

The timeline server's public deployment runs on **UpCloud Managed Kubernetes**,
running the exact image that CI builds on every push to `main`. Nothing is built
or pushed from a developer machine, and — since the cutover to GitOps — nothing is
deployed from a developer machine or from CI either. CI's job ends once the image
is in GHCR; **Argo CD** running *inside* the cluster pulls the published artifact
straight from GHCR (it can, because the package is public) and rolls it out. So
`main` is still the single source of truth for what runs remotely — but it's now
the *git* state of `k8s/timeline-server/overlays/upcloud/` (the pinned image tag),
reconciled by Argo CD, rather than something a push script applies.

CI publishes **only immutable `ghcr.io/thomanil/timeline-server:sha-<commit>` tags**
(the full 40-char commit SHA). There is no `:latest` tag anymore — the deployed
version is always named explicitly by a `sha-<commit>` tag, both in GHCR and in
git.

> **Related:**
> - Recreating the cluster from scratch → [`upcloud-create-cluster.md`](upcloud-create-cluster.md).
> - Custom domain + TLS cert → [`upcloud-custom-domain-tls.md`](upcloud-custom-domain-tls.md).

## How a deploy happens (pull-based GitOps)

There is no deploy command to run. The end-to-end flow on a merge to `main` is:

1. **CI builds & pushes.** The `build-and-push` job in the *Build and push server
   image* workflow builds the multi-arch image and pushes it to GHCR as
   `ghcr.io/thomanil/timeline-server:sha-<commit>`. CI does not touch the cluster.
2. **Argo CD Image Updater bumps the tag.** Image Updater (running in the cluster)
   watches GHCR for the newest `sha-*` build and commits the new tag into
   `k8s/timeline-server/overlays/upcloud/kustomization.yaml` (the `images:`
   `newTag` field) on `main`.
3. **Argo CD syncs.** Argo sees the changed git state for the upcloud overlay and
   reconciles the cluster to match — rolling the single pod to the new image.

So: merge to `main` → CI builds & pushes `sha-<commit>` → Image Updater commits the
bump → Argo syncs → pod rolls. (Previously this was push-based: merge → CI built
`:latest` → a CI `deploy-upcloud` job ran `scripts/deploy-upcloud.sh` against the
cluster to force a rollout. That script and that CI job are both gone.)

Note the trade-off, unchanged by the cutover: each rollout restarts the single,
in-memory-stateful pod, so connected clients drop and (without a DB) state resets
on every deployed push to `main`. With managed Postgres configured, the new pod
reloads client state on startup, so clients resume.

### The deployed commit is a single line in git

`overlays/upcloud/kustomization.yaml`'s `images:` `newTag` is **the single source
of truth for the deployed commit**. Image Updater keeps it current automatically;
to pin or roll back to a specific commit, edit that one line by hand (set it to the
desired `sha-<commit>`) and commit — Argo will reconcile the cluster to it.

### Manual rollout / restart

There's no longer a push script, but you can still bounce the pod without changing
the image (e.g. to clear in-memory state or pick up a Secret change):

```
./scripts/upcloud-restart-pods.sh
```

It does a `kubectl rollout restart` pinned to the UpCloud kubeconfig, respecting
the `Recreate` strategy.

### Watching it

```
./scripts/logs-upcloud.sh                 # follow server logs (pinned to one pod)
./scripts/argo-web-console-upcloud.sh     # port-forward + open the Argo CD web UI
```

The Argo CD web console is the place to watch sync status, see what commit is
live, and trigger/inspect syncs.

## Kubeconfig (cluster-admin creds — kept out of the repo)

The remote helper scripts (`logs-upcloud.sh`, `upcloud-restart-pods.sh`,
`argo-web-console-upcloud.sh`) read the UpCloud kubeconfig from `$KUBECONFIG` if
set, otherwise from a file kept **outside the repo** at
`~/.secrets/tech-sandbox-upcloud-k8s-cluster_kubeconfig.yaml`. It is never in the
working tree, so it can't be committed.

CI no longer needs cluster credentials at all: with the deploy job removed, the
workflow only builds and pushes to GHCR, so the **`UPCLOUD_KUBECONFIG`** Actions
secret is no longer used for deploys. (Cluster access is now an in-cluster
concern: Argo CD reconciles from inside the cluster, and Image Updater's git
write-back uses the `git-creds` Secret in the `argocd` namespace — see below.)

## The Kustomize layout: overlays, not standalone manifests

The old standalone manifests (`k8s/timeline-server-upcloud.yaml`,
`k8s/timeline-server-local.yaml`, `k8s/timeline-server-published.yaml`) are gone,
replaced by a Kustomize base/overlays tree under `k8s/timeline-server/`:

- **`base/`** — the shared `Deployment` + `Service` (single-replica/`Recreate`
  rules, split probes, the GHCR image name).
- **`overlays/local/`** — minikube with a locally-built image, bundled in-cluster
  Postgres, exposed via `NodePort` 30080. Applied by `scripts/deploy-minikube.sh`
  (`kubectl apply -k k8s/timeline-server/overlays/local`).
- **`overlays/published/`** — minikube test of the published GHCR image; applied by
  `scripts/test-latest-main-image-on-minikube.sh`, which resolves a `sha-<commit>`
  from git and pins it.
- **`overlays/upcloud/`** — production. The public-remote sibling of the minikube
  overlays — same base rules and image name — with the deliberate differences for a
  real cluster (below). The running version is pinned by the `sha-<commit>`
  `newTag` in `overlays/upcloud/kustomization.yaml`.

### upcloud overlay: differences from the minikube siblings

- **`Service` type `LoadBalancer`** (not `NodePort`). UpCloud's cloud controller
  provisions a managed load balancer with its own stable public hostname,
  forwarding both `443` and `80` to the container's `8000`, so the client
  connects at `wss://<lb-host>/ws` from anywhere. The load balancer is
  provisioned **once** and persists with a fixed hostname across redeploys —
  Argo re-applying the overlay does not create a new one. (It only goes away, and
  the hostname changes, if the `Service` is deleted — which also stops the load
  balancer's running cost.)
- **TLS terminated at the load balancer, on a custom domain.** The `Service`
  annotation puts the `443` frontend in `http` mode (which also carries the
  WebSocket upgrade) and attaches a dynamic, auto-renewing cert for the custom
  domain by its `certificate_bundle_uuid`, so the secure client URL is
  `wss://tknilsson-sandbox.com/ws`. Plain `:80` is kept alongside for
  `curl`/healthz checks. Cert setup, the CCM gotcha, and recreate steps:
  [`upcloud-custom-domain-tls.md`](upcloud-custom-domain-tls.md).
- **`imagePullPolicy: Always`.** Unlike minikube (image pre-pulled, so
  `IfNotPresent`/`Never`), this cluster pulls from GHCR over the internet. A
  rollout always lands the `sha-<commit>` image that `kustomization.yaml` names.
- **`DATABASE_URL` from the `timeline-db` Secret** (managed Postgres,
  `sslmode=require`, password not committed). The Secret is created out of band and
  must exist before the first deploy — see [`upcloud-postgres.md`](upcloud-postgres.md).

## Argo CD: the thing that actually deploys

Two Argo CD `Application` manifests live in `k8s/argocd/`:

- **`application-upcloud.yaml`** — syncs `overlays/upcloud` from `main` into the
  `default` namespace (the same namespace the old push manifests used). It carries
  the Argo CD Image Updater annotations that drive the automation:
  - `image-list: timeline=ghcr.io/thomanil/timeline-server`
  - `update-strategy: newest-build` (sha tags aren't semver-sortable, so pick the
    most recently *built* image, not the lexically newest tag)
  - `allow-tags: regexp:^sha-[0-9a-f]{40}$` (only full-SHA tags are eligible)
  - `write-back-method: git:secret:argocd/git-creds` (commit the bump back to the
    repo, using the `git-creds` push credential)
  - `write-back-target: kustomization` (edit the overlay's `newTag` in place)
  - `git-branch: main`
- **`application-local.yaml`** — the minikube Argo `Application`; no image
  automation (the local overlay is built from your working tree).

Each is applied once to its cluster's Argo CD. After that, the loop is autonomous.

### The `git-creds` Secret (new requirement)

Image Updater commits the tag bump back to the repo, so it needs push access. A
**`git-creds` Secret** (a write-scoped git deploy key or token) must exist in the
`argocd` namespace; it's created out of band like the other secrets and is never in
the repo. Without it, Image Updater can detect a new image but can't write the bump
back, so nothing rolls.

(The other out-of-band secrets — the `timeline-db` Postgres Secret and the TLS
certificate bundle — are unchanged by the cutover.)

(The CD architecture diagram lives in the README's "(Sixth iteration)" section.)
