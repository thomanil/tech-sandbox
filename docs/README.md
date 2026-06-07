# Docs

Deep-dives the top-level [`README.md`](../README.md) links to but keeps out of its
narrative.

## UpCloud deployment

The public deployment runs on UpCloud Managed Kubernetes. For a newcomer, read in
this order:

1. **[upcloud-deployment.md](upcloud-deployment.md)** — what the remote deployment
   *is* and how a deploy works: the `deploy-upcloud.sh` script, the kubeconfig, how
   the manifest differs from the minikube one, and the CI auto-deploy on merge to
   `main`.
2. **[upcloud-create-cluster.md](upcloud-create-cluster.md)** — how to stand up (or
   recreate) the ephemeral cluster from scratch.
3. **[upcloud-custom-domain-tls.md](upcloud-custom-domain-tls.md)** — point the
   custom domain at the load balancer and get an HTTPS/WSS cert that survives CCM
   reconciliation. Start with its **TL;DR**.
