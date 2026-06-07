# Public remote deployment on UpCloud

The timeline server's public deployment runs on **UpCloud Managed Kubernetes**,
pulling the exact same `ghcr.io/thomanil/timeline-server:latest` that CI builds on
every push to `main`. Nothing is built or pushed from a developer machine —
UpCloud pulls the published artifact straight from GHCR (it can, because the
package is public), so `main` is the single source of truth for what runs
remotely.

> **Related:**
> - Recreating the cluster from scratch → [`upcloud-create-cluster.md`](upcloud-create-cluster.md).
> - Custom domain + TLS cert → [`upcloud-custom-domain-tls.md`](upcloud-custom-domain-tls.md).

## Deploying

```
./scripts/deploy-upcloud.sh
```

It pins every `kubectl` call to the UpCloud kubeconfig so it can never touch a
local context by accident, asserts it's aimed at the expected cluster, applies
`k8s/timeline-server-upcloud.yaml`, forces a rollout (so the freshest `:latest`
is pulled), waits for readiness, then waits for the load balancer's public
hostname and prints the client URL.

## Kubeconfig (cluster-admin creds — kept out of the repo)

The script reads the UpCloud kubeconfig from `$KUBECONFIG` if set, otherwise from
a file kept **outside the repo** at
`~/.secrets/tech-sandbox-upcloud-k8s-cluster_kubeconfig.yaml`. It is never in the
working tree, so it can't be committed. CI gets the same kubeconfig from the
**`UPCLOUD_KUBECONFIG`** Actions secret — the workflow writes it to a temp file and
exports `KUBECONFIG` before calling the script. One-time setup: add the secret with
the file's contents under *Settings → Secrets and variables → Actions → New
repository secret* (or
`gh secret set UPCLOUD_KUBECONFIG < ~/.secrets/tech-sandbox-upcloud-k8s-cluster_kubeconfig.yaml`).

## Manifest: differences from the minikube siblings

The UpCloud manifest is the public-remote sibling of the minikube ones — same
single-replica/`Recreate` rules and the same GHCR image — with three deliberate
differences for a real cluster:

- **`Service` type `LoadBalancer`** (not `NodePort`). UpCloud's cloud controller
  provisions a managed load balancer with its own stable public hostname,
  forwarding both `443` and `80` to the container's `8000`, so the client
  connects at `wss://<lb-host>/ws` from anywhere. The load balancer is
  provisioned **once** and persists with a fixed hostname across redeploys —
  re-running the script just re-applies and rolls out, it does not create a new
  one. (It only goes away, and the hostname changes, if you delete the `Service`:
  `kubectl --kubeconfig ~/.secrets/tech-sandbox-upcloud-k8s-cluster_kubeconfig.yaml delete -f k8s/timeline-server-upcloud.yaml`
  — which also stops the load balancer's running cost.)
- **TLS terminated at the load balancer, on a custom domain.** The `Service`
  annotation puts the `443` frontend in `http` mode (which also carries the
  WebSocket upgrade) and attaches a dynamic, auto-renewing cert for the custom
  domain, so the secure client URL is `wss://tknilsson-sandbox.com/ws`. Plain `:80`
  is kept alongside for `curl`/healthz checks. Cert setup, the CCM gotcha, and
  recreate steps: [`upcloud-custom-domain-tls.md`](upcloud-custom-domain-tls.md).
- **`imagePullPolicy: Always`.** Unlike minikube (image pre-pulled, so
  `IfNotPresent`/`Never`), this cluster pulls from GHCR over the internet, so a
  rollout restart always lands the newest `:latest`.

## Continuous deployment via CI

This deploy is also wired into CI for true continuous deployment: after the
build-and-push job publishes a new `:latest`, a `deploy-upcloud` job in the same
workflow runs `scripts/deploy-upcloud.sh` against the cluster, forcing the
rollout that pulls the new image. Without that step nothing would update on its
own — `imagePullPolicy: Always` only re-pulls when a pod is *created*; nothing
polls GHCR. The job is gated to `main` and serialized so two quick pushes don't
race rollouts. You can still run `deploy-upcloud.sh` by hand for an out-of-band
deploy. Note the trade-off: each auto-rollout restarts the single,
in-memory-stateful pod, so connected clients drop and state resets on every
deployed push to `main`.

(The CI/deploy architecture diagram lives in the README's "(Sixth iteration)"
section.)
