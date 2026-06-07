#!/usr/bin/env bash

# Resolve the repo root from this script's location so it works from any CWD.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Honor a KUBECONFIG from the environment; otherwise fall back to the local,
# gitignored copy (no longer committed — see README).
export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/k8s/upcloud_timeline-public_kubeconfig.yaml}" && kubectl config view
