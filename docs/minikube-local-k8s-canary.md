# Minikube as a local Kubernetes canary

The point of the local minikube rig is to **try Kubernetes changes against a real
cluster before they reach production** — a fast, throwaway canary for manifest and
image changes. This is an imperative, working-tree loop: you do NOT need Argo CD
locally, and it is independent of the GitOps pull flow that drives UpCloud.

## TL;DR

```
./scripts/deploy-minikube.sh
```

Builds your **working-tree** image straight into minikube and applies the
`k8s/timeline-server/overlays/local` Kustomize overlay. Edit `base/` or
`overlays/local/`, re-run, see it live in seconds. Point the desktop/web client's
**Local minikube** entry at the `ws://<minikube-ip>:30080/ws` URL it prints.

## What the script actually does

`scripts/deploy-minikube.sh`:

1. Starts minikube if needed.
2. `minikube image build -t timeline-server:latest .` — builds the image from your
   **working tree** straight into minikube's runtime (no registry, no push). The
   `timeline-server:latest` here is a **local image tag**, unrelated to GHCR (CI no
   longer publishes a registry `:latest` at all).
3. `kubectl apply -k k8s/timeline-server/overlays/local` — renders and applies the
   local overlay: the shared `base/` Deployment+Service, plus the local patches
   (`imagePullPolicy: Never` so it uses the image you just built, the bumped CPU
   limit, NodePort `30080`) and the bundled in-cluster Postgres (PVC + Deployment +
   Service + a `wait-for-db` init container).
4. Forces a rollout (an unchanged manifest wouldn't otherwise restart the pod) and
   prints the client URL.

Because both the **image** and the **manifests** come from your working tree, this
canaries uncommitted changes — exactly what you want before pushing.

Follow logs with `./scripts/logs-minikube.sh`; tear down with
`kubectl delete -k k8s/timeline-server/overlays/local` (and `minikube stop` /
`minikube delete` for the cluster itself).

## What this is — and isn't — a canary for

This is a **truer** canary than the pre-GitOps setup, because minikube and UpCloud
now share the same `k8s/timeline-server/base`:

- **Changes to `base/`** — replica/`Recreate` strategy, the split `/readyz` +
  `/healthz` probes, `securityContext`, resource requests/limits, the
  Deployment/Service shape — are the **same config production runs**. Canarying
  them on minikube tests the exact bytes that will ship to UpCloud. ✅
- **Changes to `overlays/local/`** — the local-only image/DB/NodePort wiring — are
  tested directly, but they are local-specific (they do not ship to prod). ✅

What minikube **cannot** canary (this is the deliberate exposure split — minikube
has no cloud load balancer; same limitation as the old flat manifests):

- The `overlays/upcloud`-only bits: `type: LoadBalancer`, the UpCloud LB-config /
  TLS annotation, `imagePullPolicy: Always`, and the `timeline-db` Secret ref.

For those, validate that the overlay still **renders** before pushing — it won't
run locally, but a broken patch is caught here:

```
kubectl kustomize k8s/timeline-server/overlays/upcloud   # must render cleanly
```

## The canary → promote loop

```
edit base/ or overlays/local
  → ./scripts/deploy-minikube.sh        # canary on real k8s, working tree
  → happy?
  → git commit + push to main           # CI builds & pushes sha-<commit>
  → Argo CD Image Updater bumps the tag in git → Argo CD syncs UpCloud
```

So minikube is where you de-risk a manifest change; `main` is how it promotes to
production (via the pull flow — see [`upcloud-deployment.md`](upcloud-deployment.md)).

## Canarying the published image (second loop)

To canary the **published GHCR image** (CI's real artifact) rather than a
working-tree build:

```
./scripts/test-latest-main-image-on-minikube.sh            # tip of origin/main
./scripts/test-latest-main-image-on-minikube.sh <ref|sha>  # a specific commit
```

It resolves the commit to a `sha-<commit>` tag, pulls
`ghcr.io/thomanil/timeline-server:sha-<commit>` into minikube, and applies the
`overlays/published` overlay with that image pinned (the working tree stays
clean). Same NodePort `30080`, so the client's **Local minikube** entry is
unchanged. Note `overlays/published` reaches the **host's** compose Postgres via
`host.minikube.internal.:5432` (so `docker compose up` must be running), whereas
`overlays/local` bundles its own in-cluster Postgres.

## Do NOT confuse this with the local Argo `Application`

There is a `k8s/argocd/application-local.yaml`, but it is **not** the canary tool:

- It has `targetRevision: main` and `repoURL` pointing at GitHub, so if you install
  Argo on minikube and apply it, it deploys **what is committed on `main`, not your
  working tree.** That makes it a canary for the *GitOps machinery itself* (Argo
  sync/`selfHeal` behaviour), not for iterating on local edits.
- It runs **no** image-automation (decision #1 in
  [`../k8s/GITOPS_PLAN.md`](../k8s/GITOPS_PLAN.md)) — you still build the image into
  minikube yourself; Argo only reconciles the Deployment/Service/Postgres.

**For "try k8s changes directly before pushing," always use
`scripts/deploy-minikube.sh`** (imperative, working tree). Only reach for the local
Argo Application if you specifically want to rehearse how Argo will behave in the
cluster.

### Optional: rehearse the GitOps flow on minikube

If you do want to exercise Argo locally: install Argo CD into the minikube cluster,
then `kubectl --context minikube apply -f k8s/argocd/application-local.yaml`. Open
its UI with `scripts/argo-web-console-local.sh`. Remember it syncs committed `main`,
so push your branch and point `targetRevision` at it (or merge) to see changes.

## Prerequisites

`minikube` and `kubectl` (the scripts check for both and point you at install pages
if missing). Docker is the default minikube driver. For the published-image loop,
also `git`, and a running `docker compose` stack for its Postgres.
