#!/usr/bin/env bash

# Honor a KUBECONFIG from the environment; otherwise fall back to the local
# out-of-repo copy (kept outside the working tree — see README).
export KUBECONFIG="${KUBECONFIG:-$HOME/.secrets/tech-sandbox-upcloud-k8s-cluster_kubeconfig.yaml}" && kubectl config view
