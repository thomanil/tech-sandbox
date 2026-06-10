# (Re)creating the deployment env in UpCloud

The project deploys to a managed Kubernetes cluster in the Finnish cloud provider
UpCloud. The cluster itself is ephemeral and can be torn down and recreated
quickly. The steps, in order:

1. **Delete the old cluster** (if one exists) in the UpCloud web console. You may
   need to delete a dangling load balancer afterwards as well.
2. **Create a new cluster.** Allow IP access for all IPs, so that ingress works for
   the GitHub Actions build pipeline.
3. **Save the kubeconfig** at the exact path the scripts expect:
   `~/.secrets/tech-sandbox-upcloud-k8s-cluster_kubeconfig.yaml`. It lives outside
   the repo on purpose (cluster-admin creds — never in the working tree). This is
   the only local copy; the remote helper scripts (`logs-upcloud.sh`,
   `upcloud-restart-pods.sh`, `argo-web-console-upcloud.sh`) fall back to it when
   `$KUBECONFIG` isn't already set.
4. **Update the context guard if the name changed.** A new cluster may get a new
   context name; if it changed, update `EXPECTED_CONTEXT` in the remote helper
   scripts (`scripts/logs-upcloud.sh`, `scripts/upcloud-restart-pods.sh`) to match
   (they refuse to run unless the context matches, guarding against the wrong
   cluster).
5. **Install Argo CD + Image Updater and bootstrap the Applications.** The deploy
   is now pull-based: Argo CD runs *in* the cluster and reconciles the upcloud
   overlay from `main`. Install Argo CD and Argo CD Image Updater, then apply the
   Application manifest once:
   `kubectl --context kubernetes-admin@tech-sandbox-upcloud-k8s-cluster apply -f k8s/argocd/application-upcloud.yaml`.
   Also create the **`git-creds` Secret** (a write-scoped git deploy key/token) in
   the `argocd` namespace — Image Updater commits the image-tag bump back to the
   repo and can't write without it. CI no longer deploys, so there is **no
   `UPCLOUD_KUBECONFIG` Actions secret to set** for deploys; CI's job ends once the
   `sha-<commit>` image is in GHCR. Deploy mechanics and the Argo annotations:
   [`upcloud-deployment.md`](upcloud-deployment.md).
6. **Provision managed Postgres + create the `timeline-db` Secret.** On a fresh
   cluster/account, create (or confirm) the managed Postgres 18 service and allow the
   cluster's access, then create the `timeline-db` Secret holding the `DATABASE_URL`.
   The Deployment references it via `secretKeyRef` and **won't start without it**
   (it'd sit in `CreateContainerConfigError`), so do this before deploying:
   ```bash
   kubectl --kubeconfig ~/.secrets/tech-sandbox-upcloud-k8s-cluster_kubeconfig.yaml \
     create secret generic timeline-db \
     --from-literal=DATABASE_URL='postgres://upadmin:<PASSWORD>@postgres-sydqtmadgayy.db.upclouddatabases.com:11569/defaultdb?sslmode=require'
   ```
   `sslmode=require` is mandatory (UpCloud enforces TLS); URL-encode the password if
   it has special characters. Verify with `kubectl ... get secret timeline-db`.
   Provisioning details, rotation, and connection specifics:
   [`upcloud-postgres.md`](upcloud-postgres.md).
7. **Let Argo do the first sync** to provision the app load balancer and learn its
   public hostname. With `application-upcloud.yaml` applied (step 5) and the
   `timeline-db` Secret in place (step 6), Argo CD reconciles the upcloud overlay
   from `main`, which creates the `Service` and so the LB. Watch it land via the
   Argo web console (`./scripts/argo-web-console-upcloud.sh`) or read the LB
   hostname directly:
   `KUBECONFIG=~/.secrets/tech-sandbox-upcloud-k8s-cluster_kubeconfig.yaml kubectl get svc timeline-server -o wide`.
   The client URL is `wss://<lb-host>/ws`. (The LB hostname is brand-new on a
   recreated cluster, and the API-server LB in the kubeconfig is a separate one —
   use the workload `Service`'s hostname, not the one in the kubeconfig.)
8. **Re-point the custom domain + TLS** at the new LB: update the DNSimple ALIAS to
   the new hostname, recreate the dynamic cert bundle, and put its new UUID in
   `k8s/timeline-server/overlays/upcloud/kustomization.yaml`. Full steps:
   [`upcloud-custom-domain-tls.md`](upcloud-custom-domain-tls.md). (Clients target
   the stable domain `wss://tknilsson-sandbox.com/ws`, so the `SERVERS` lists don't
   change on recreate.)
9. **Run `./scripts/error_check.sh`**, then commit (the UUID edit is git state Argo
   will sync).
10. **Smoke-test the pipeline:** push a trivial change to `main` and confirm it flows
    through — CI builds & pushes a `sha-<commit>` image, Argo CD Image Updater
    commits the tag bump into `overlays/upcloud/kustomization.yaml`, and Argo rolls
    out the new pod / web app.

> **Related:** deploy mechanics (Argo CD, Image Updater, kubeconfig) →
> [`upcloud-deployment.md`](upcloud-deployment.md); custom domain + cert →
> [`upcloud-custom-domain-tls.md`](upcloud-custom-domain-tls.md).
