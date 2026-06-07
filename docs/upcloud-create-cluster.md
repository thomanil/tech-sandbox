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
   the only local copy; `deploy-upcloud.sh` / `logs-upcloud.sh` fall back to it
   when `$KUBECONFIG` isn't already set.
4. **Update the context guard if the name changed.** A new cluster may get a new
   context name; if it changed, update `EXPECTED_CONTEXT` in **both**
   `scripts/deploy-upcloud.sh` and `scripts/logs-upcloud.sh` to match (the scripts
   refuse to deploy unless the context matches, guarding against the wrong cluster).
5. **Point CI at the new cluster** by re-setting the GitHub Actions secret CI reads
   its kubeconfig from (the workflow writes it to a temp file at deploy time):
   `gh secret set UPCLOUD_KUBECONFIG < ~/.secrets/tech-sandbox-upcloud-k8s-cluster_kubeconfig.yaml`
6. **Deploy once** to provision the app load balancer and learn its public hostname:
   `./scripts/deploy-upcloud.sh`. It applies `k8s/timeline-server-upcloud.yaml`,
   waits for the LB, and prints the client URL `wss://<lb-host>/ws`. (The LB
   hostname is brand-new on a recreated cluster, and the API-server LB in the
   kubeconfig is a separate one — use the hostname the script prints, not the one
   in the kubeconfig.)
7. **Re-point the custom domain + TLS** at the new LB: update the DNSimple ALIAS to
   the new hostname, recreate the dynamic cert bundle, and put its new UUID in
   `k8s/timeline-server-upcloud.yaml`. Full steps:
   [`upcloud-custom-domain-tls.md`](upcloud-custom-domain-tls.md). (Clients target
   the stable domain `wss://tknilsson-sandbox.com/ws`, so the `SERVERS` lists don't
   change on recreate.)
8. **Run `./scripts/error_check.sh`**, then commit.
9. **Smoke-test the pipeline:** push a trivial change to `main` and confirm it flows
   through CI to the live deploy / web app.

> **Related:** deploy mechanics (script, kubeconfig, CI wiring) →
> [`upcloud-deployment.md`](upcloud-deployment.md); custom domain + cert →
> [`upcloud-custom-domain-tls.md`](upcloud-custom-domain-tls.md).
