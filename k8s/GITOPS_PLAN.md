# Timeline-server GitOps migration — PLAN & OPEN QUESTIONS

Status: **work-in-progress scaffold.** This branch adds a Kustomize base/overlays
layout, two Argo CD `Application` manifests (local + upcloud), and helper scripts
to open each cluster's Argo UI. It does **not** yet flip the live deploy path from
push (CI runs `deploy-upcloud.sh`) to pull (Argo syncs from Git). The open
questions below must be answered before that switch.

The base/overlays **faithfully reproduce** the three legacy `k8s/timeline-server-*.yaml`
manifests — verified by rendering each overlay with `kustomize build` and
deep-diffing against the legacy file (see "Verification" at the bottom). The
legacy files are left in place and remain the live deploy targets until the pull
path is proven.

Context discovered from the existing repo:
- CI (`.github/workflows/build-image.yml`) **already pushes an immutable SHA tag**
  (`type=sha,format=long`) alongside `:latest`. So SHA tags already exist in GHCR.
- Current CD is **push**: the `deploy-upcloud` job runs `scripts/deploy-upcloud.sh`,
  which `kubectl apply`s the manifest and forces a rollout. Migrating to pull means
  this job goes away (or is reduced to "build + push only").
- The manifests currently reference `:latest`, not the SHA — so even though SHA
  tags exist, nothing pins or traces the running version yet.

## Layout added by this branch

```
k8s/timeline-server/base/                 # shared Deployment + Service (every-env invariants)
k8s/timeline-server/overlays/local/       # minikube: local image (Never) + bundled in-cluster Postgres + cpu "2" + NodePort 30080
k8s/timeline-server/overlays/published/   # minikube TEST path: GHCR image (IfNotPresent) + host.minikube.internal DB + NodePort 30080
k8s/timeline-server/overlays/upcloud/     # prod: GHCR image (Always) + timeline-db Secret + LoadBalancer 80/443 + pinned TLS bundle
k8s/argocd/application-local.yaml         # Argo Application -> overlays/local   (no image-automation)
k8s/argocd/application-upcloud.yaml       # Argo Application -> overlays/upcloud (gets image-automation)
scripts/argo-web-console-local.sh         # port-forward + open Argo UI (minikube)
scripts/argo-web-console-upcloud.sh       # port-forward + open Argo UI (upcloud)
```

Note: `published` is the manual test path (`test-latest-main-image-on-minikube.sh`),
not an Argo-managed environment, so it intentionally has **no Argo Application**.

---

## Open questions (blockers / decisions before going live)

### 1. Two clusters writing to the same Git path (THE BIG ONE)
If both minikube's Argo and upcloud's Argo run image-automation against the same
overlay/image/policy, they race to commit tag bumps to `main` and deploy each
other's builds.
**Proposed default:** only **upcloud** runs image-automation (it tracks real CI
builds from GHCR). **local** minikube deploys a locally-built image (no registry,
no automation), matching the original `timeline-server-local.yaml` behaviour.
- [ ] Confirm: local does NOT auto-update from GHCR. (If it must, give the two
      clusters separate tag streams / policies / paths so commits never collide.)

### 2. minikube cannot provision a LoadBalancer
The upcloud overlay uses `type: LoadBalancer` + the UpCloud LB-config annotation;
on minikube that Service stays `<pending>` forever. This is WHY the local overlay
uses NodePort 30080. Exposure is the one thing that legitimately differs between
the clusters — do not "unify" it.
- [ ] Confirm NodePort-local / LoadBalancer-upcloud split is accepted as final.

### 3. Target namespace + auto-create
Applications target namespace `timeline`. Argo must create it.
- [ ] Confirm namespace name `timeline` is desired.
- [x] `syncOptions: [CreateNamespace=true]` set in both Application manifests.

### 4. Bootstrapping — who applies the Application objects?
The Application YAMLs must be applied to each cluster once, by hand, against the
right context. (App-of-apps is overkill for two clusters.)
- [ ] `kubectl --context minikube apply -f k8s/argocd/application-local.yaml`
- [ ] `kubectl --context kubernetes-admin@tech-sandbox-upcloud-k8s-cluster apply -f k8s/argocd/application-upcloud.yaml`

### 5. Git write credentials for image-automation
The automation controller COMMITS to this repo, so it needs push rights (deploy
key or token) stored as a Secret in the upcloud cluster. Plain Argo sync only
needs read access; automation needs write.
- [ ] Create a write-scoped deploy key / token.
- [ ] Store it as a Secret in the upcloud cluster's argocd namespace.

### 6. Argo CD Image Updater is a SEPARATE install
Plain Argo CD does not include image automation. Either install Argo CD Image
Updater alongside Argo, OR use Flux's image-reflector/image-automation toolkit.
The marker-comment / annotation syntax differs between the two — pick ONE. The
`overlays/upcloud` image line carries a PLACEHOLDER marker comment today.
- [ ] Decide: Argo CD Image Updater vs Flux image automation.
- [ ] Install it in the upcloud cluster.
- [ ] Adjust the image marker in overlays/upcloud to that tool's exact syntax.

### 7. CI must point manifests at the SHA (mostly already done)
CI already produces `:sha-<long>` tags. Remaining work: the GitOps flow must
reference the SHA (not `:latest`) so Git names the exact running version, and
something must bump that SHA into Git (the image-automation controller, per #6).
- [x] CI emits immutable SHA tags (confirmed in build-image.yml).
- [ ] Overlay/image-automation references the SHA tag, not `:latest`.
- [ ] Decide whether to keep `:latest` as a convenience pointer (it's fine to).

### 8. Secrets management (live today on upcloud)
The upcloud overlay already references a Secret (`timeline-db`, the managed-Postgres
`DATABASE_URL`) created out of band, and the LB cert is a pinned bundle UUID. Argo
syncs the Deployment/Service but NOT those secrets — they must exist before sync or
the pod won't start. "Don't commit secrets" collides with GitOps the moment you'd
want the Secret itself in Git — solve with sealed-secrets or external-secrets, NOT
plaintext in Git.
- [ ] Decide how `timeline-db` is managed under GitOps (keep out-of-band, or adopt
      sealed-secrets / external-secrets so it's reconciled too).

### 9. argocd-server uses a self-signed cert
The UI is HTTPS with a self-signed cert; the browser warns every time over the
port-forward (8080/8081 -> 443). Expected; just accept it. The console scripts
forward to 443 and open https://localhost:<port>.
- [x] Scripts account for this (forward :443, open https). No fix needed.

### 10. Two Argo instances = two admin passwords
Each cluster's Argo generates its own `argocd-initial-admin-secret`. The two
console scripts log into two independent Argo installs; no shared login/state.
- [x] Scripts print each cluster's admin password on launch for convenience.
- [ ] After first login on each: change admin password, delete the initial secret.

---

## Also still TODO (not in the original 1–10, but needed to finish)
- [ ] Repoint the deploy/test scripts (`deploy-minikube.sh`,
      `test-latest-main-image-on-minikube.sh`, `deploy-upcloud.sh`) at the overlays
      (`kubectl apply -k k8s/timeline-server/overlays/<env>`), then delete the three
      legacy `k8s/timeline-server-*.yaml` files — but only once the pull path is proven.
- [ ] Decide the fate of the push CD job in build-image.yml: remove the
      `deploy-upcloud` job, or reduce it to build-and-push-only so Argo owns deploys.

## Verification (re-run after any edit to base/overlays)
```
kustomize build k8s/timeline-server/overlays/local     # == k8s/timeline-server-local.yaml
kustomize build k8s/timeline-server/overlays/published  # == k8s/timeline-server-published.yaml
kustomize build k8s/timeline-server/overlays/upcloud    # == k8s/timeline-server-upcloud.yaml
```
Each render is resource-for-resource identical to its legacy manifest. The only
byte-level delta is a single trailing newline inside the upcloud LB-config
annotation value (kustomize clips block-scalar trailing newlines); that value is
parsed as JSON by UpCloud's cloud controller, where trailing whitespace is
ignored, so the effective config is identical.
