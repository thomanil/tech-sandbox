# Docs

Deep-dives the top-level [`README.md`](../README.md) links to but keeps out of its
narrative.

## Persistence

- **[database.md](database.md)** — the database/persistence base case: the
  transparent `DATABASE_URL` model across compose / minikube / UpCloud, the psycopg 3
  driver, startup migrations, and the split liveness/readiness probes.

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
4. **[upcloud-postgres.md](upcloud-postgres.md)** — the managed Postgres 18 the
   deployment persists to: the transparent `DATABASE_URL` model, provisioning, and
   the `timeline-db` Secret that holds the password.
