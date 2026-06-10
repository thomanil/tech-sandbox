# Timeline-server GitOps — DESIGN, DECISIONS & BOOTSTRAP

Status: **cutover implemented in the repo; pending one-time cluster bootstrap.**

The UpCloud deploy path has been flipped from **push** (CI ran `deploy-upcloud.sh`)
to **pull** (Argo CD syncs Git). All repo-side changes are done; the only thing
left is the one-time, in-cluster bootstrap (install Argo CD + Image Updater,
create the write credential, apply the `Application`) — see the runbook below.
Until that bootstrap runs in the live cluster, nothing auto-deploys.

## Decisions (resolved)

| # | Question | Decision |
|---|----------|----------|
| 1 | Image-automation scope | **Only upcloud** automates; local deploys a locally-built image |
| 6 | Automation tool | **Argo CD Image Updater** (git write-back) |
| 8 | Secrets under GitOps | **Keep out-of-band** (`timeline-db` + TLS bundle stay manual; add `git-creds`) |
| 2 | Exposure | **Keep the split** — NodePort 30080 local / LoadBalancer + TLS upcloud |
| 3 | Namespace | **`default`** (parity with the old push manifests) |
| 7 | `:latest` tag | **Dropped** — CI publishes only immutable `sha-<commit>` |

## What runs where

```
k8s/timeline-server/base/                 # every-environment invariants (replicas:1+Recreate, split /readyz+/healthz probes, non-root, resource floors)
k8s/timeline-server/overlays/local/       # minikube: locally-built image (Never) + bundled in-cluster Postgres + cpu "2" + NodePort 30080
k8s/timeline-server/overlays/published/   # minikube TEST of the GHCR image (IfNotPresent) + host.minikube.internal DB + NodePort 30080
k8s/timeline-server/overlays/upcloud/     # prod: GHCR image by sha (Always) + timeline-db Secret + LoadBalancer 80/443 + pinned TLS bundle
k8s/argocd/application-local.yaml         # Argo Application -> overlays/local   (NO image-automation), namespace default
k8s/argocd/application-upcloud.yaml       # Argo Application -> overlays/upcloud (Image Updater annotations), namespace default
scripts/argo-web-console-local.sh         # port-forward + open Argo UI (minikube)
scripts/argo-web-console-upcloud.sh       # port-forward + open Argo UI (upcloud)
```

The three legacy `k8s/timeline-server-*.yaml` and `scripts/deploy-upcloud.sh` are
**deleted** (superseded by the overlays + Argo). `deploy-minikube.sh` and
`test-latest-main-image-on-minikube.sh` now `apply -k` the overlays.

## The deploy loop (upcloud)

```
merge to main
  → CI (build-image.yml) builds & pushes ghcr.io/thomanil/timeline-server:sha-<commit>   (no :latest)
  → Argo CD Image Updater sees the newest sha-* build, commits the newTag bump
    into overlays/upcloud/kustomization.yaml on main
  → Argo CD syncs the overlay (selfHeal + prune) and rolls the single pod
```

`overlays/upcloud/kustomization.yaml`'s `images[].newTag` is the **single source of
truth for the deployed commit**. To pin/rollback by hand, edit that line to a
specific `sha-<commit>` and push; Argo deploys it. (Image Updater will resume
bumping from the newest build after that.)

---

## Bootstrap runbook (one-time, per cluster)

These are operational steps run against the live cluster — not in this repo.

### UpCloud (production — the pull path)
1. **Install Argo CD** into the `argocd` namespace:
   `kubectl create namespace argocd && kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml`
2. **Install Argo CD Image Updater** (separate component, see #6):
   `kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml`
3. **Create the `git-creds` write credential** in `argocd` (a deploy key/token
   scoped to push this repo — Image Updater commits the tag bump with it):
   `kubectl -n argocd create secret generic git-creds --from-literal=username=<user> --from-literal=password=<PAT-or-deploy-token>`
   (or an SSH key per the Image Updater docs). This is the only NEW secret the
   cutover adds.
4. **Confirm the out-of-band secrets exist** (unchanged from before): the
   `timeline-db` Secret in `default` (managed-Postgres `DATABASE_URL`, see
   `docs/upcloud-postgres.md`) and the TLS certificate bundle referenced by UUID
   in the upcloud overlay (see `docs/upcloud-custom-domain-tls.md`).
5. **Apply the Application** (once):
   `kubectl --context kubernetes-admin@tech-sandbox-upcloud-k8s-cluster apply -f k8s/argocd/application-upcloud.yaml`
6. **Seed the image** (optional): the overlay ships a seed `newTag`. Image Updater
   will bump it to the newest `sha-*` within a couple of minutes; or edit it by
   hand to deploy a specific commit immediately.
7. **GitHub cleanup:** the `deploy-upcloud` CI job is gone, so the
   `UPCLOUD_KUBECONFIG` Actions secret is no longer used for deploys — remove it
   when convenient (CI no longer needs cluster credentials).
8. **First login:** open `scripts/argo-web-console-upcloud.sh`, change the admin
   password, delete `argocd-initial-admin-secret`.

### Minikube (local — optional, no automation)
Argo on minikube is optional. The fast inner loop is still
`scripts/deploy-minikube.sh` (builds into minikube + `apply -k overlays/local`,
no Argo needed). If you DO want Argo locally: install Argo CD, then
`kubectl --context minikube apply -f k8s/argocd/application-local.yaml`. It has no
image-automation (decision #1), so you still build the image into minikube
yourself; Argo just reconciles the Deployment/Service/Postgres.

---

## Reverting to the push path

The cutover is reversible — nothing here is a one-way door. The repo side is a
single `git revert` of the cutover merge (it restores `deploy-upcloud.sh`, the
three flat `k8s/timeline-server-*.yaml`, the CI `deploy-upcloud` job, and the
`:latest` tag). But a `git revert` **alone is not enough**: the live-cluster and
CI side effects aren't in Git, so you must also undo them by hand. To go fully
back to push:

1. **Do NOT delete the `UPCLOUD_KUBECONFIG` GitHub Actions secret until you are
   fully done and certain you're staying on push.** The reverted CI deploy job
   needs it — it is your cheap insurance for flipping back. Re-creating it means
   re-extracting the cluster kubeconfig (annoying, not destructive). This is why
   bootstrap step 7 above says "remove when convenient" — treat that as "only once
   you will never revert."
2. `git revert <cutover-merge>` on `main` (restores the push-based files).
3. **Tear down Argo in the cluster, or it will fight the restored push flow**
   (`selfHeal` reverts your `deploy-upcloud.sh` apply; Image Updater keeps
   committing tag bumps to `main`):
   - `kubectl -n argocd delete -f k8s/argocd/application-upcloud.yaml` — the
     Application has **no** `resources-finalizer`, so this LEAVES the running
     Deployment/Service in place (orphaned, not pruned); `deploy-upcloud.sh` then
     re-adopts them with no outage.
   - Stop/uninstall Argo CD Image Updater (and optionally Argo CD itself).
   - Delete the `git-creds` secret (no longer needed).
4. **Re-publish `:latest`:** the reverted workflow re-adds the `:latest` tag, so it
   refreshes on the next push to `main`; until then `:latest` is frozen at the last
   pre-cutover build (retag by hand if you need it sooner).
5. Run the restored `scripts/deploy-upcloud.sh` once to confirm push deploys work.

Because the overlays render identical to the old flat manifests and both modes
deploy into the **same `default` namespace**, flipping push↔pull is a control-plane
ownership change, not a workload change — the pod/Service spec doesn't churn, and
the Postgres / `timeline-db` Secret / TLS bundle are untouched either way.

---

## Operational notes / not-yet-done
- [ ] Run the UpCloud bootstrap above (the cutover is inert until then).
- [ ] After bootstrap, verify the loop end-to-end: push a trivial server change,
      confirm CI pushes `sha-<commit>`, Image Updater commits the bump, Argo rolls.
- [ ] Remove the unused `UPCLOUD_KUBECONFIG` Actions secret.
- [x] CI publishes only immutable `sha-<commit>` tags (no `:latest`).
- [x] `deploy-upcloud` CI job removed; CI ends at "image in GHCR".
- [x] Legacy flat manifests + `deploy-upcloud.sh` deleted; scripts repointed to overlays.
- Self-signed argocd-server cert: the console scripts forward `:443` and open
  `https://localhost:<port>`; accept the browser warning (expected).
- Each cluster's Argo has its own admin password (`argocd-initial-admin-secret`);
  the console scripts print it on launch.

## Verification (overlays still reproduce the pre-cutover manifests)
The base/overlays were validated to render resource-for-resource identical to the
three (now-deleted) flat manifests via `kustomize build overlays/<env>`. Re-run
after any edit to base/overlays:
```
kubectl kustomize k8s/timeline-server/overlays/local
kubectl kustomize k8s/timeline-server/overlays/published
kubectl kustomize k8s/timeline-server/overlays/upcloud
```
(The upcloud overlay's image `newTag` is now an immutable `sha-<commit>` that Image
Updater keeps current, rather than the old `:latest`.)
