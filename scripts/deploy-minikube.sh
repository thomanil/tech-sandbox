#!/usr/bin/env bash
# Deploy the timeline state server to a local minikube cluster.
# Use for local testing of k8s configs.
# For more rapid local dev with live reloads etc, use start-local-dev-server.sh instead (docker compose)
#
# This is the stable entrypoint for "run the server in kubernetes locally". It
# builds the image straight into minikube (no registry/push), applies the
# manifests in k8s/, forces a rollout so a rebuilt :latest image is actually
# picked up, waits for readiness, and prints the WebSocket URL the desktop
# client should use.
#
# Prerequisites: minikube and kubectl. If either is missing the script stops
# and tells you where to get it — it does not install anything for you.
set -euo pipefail

# Run from the repo root regardless of where the script is invoked from.
cd "$(dirname "$0")/.."

# --- Preflight: required tooling -------------------------------------------
if ! command -v minikube >/dev/null 2>&1; then
  echo "minikube not found. Install it: https://minikube.sigs.k8s.io/docs/start/" >&2
  exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found. Install it: https://kubernetes.io/docs/tasks/tools/" >&2
  exit 1
fi

# --- Ensure the cluster is running -----------------------------------------
if ! minikube status >/dev/null 2>&1; then
  echo "Starting minikube..."
  minikube start
fi

# --- Build the image into minikube -----------------------------------------
# Build inside minikube's own runtime so the image lands exactly where the
# kubelet looks for it (and the arch always matches the node — matters on arm64).
echo "Building timeline-server:latest into minikube..."
minikube image build -t timeline-server:latest .

# --- Apply manifests and roll out ------------------------------------------
# Render the local Kustomize overlay (server with imagePullPolicy: Never + the
# in-cluster Postgres + wait-for-db init + NodePort 30080) and apply it. This is
# the same overlay Argo CD would sync on a minikube with Argo installed; applying
# it by hand here keeps the fast no-Argo inner loop working.
echo "Applying manifests..."
kubectl apply -k k8s/timeline-server/overlays/local

# `kubectl apply` won't restart pods if the manifest text is unchanged, even
# though we just rebuilt the :latest image. Force a new pod so the fresh image
# is actually used.
echo "Rolling out..."
kubectl rollout restart deployment/timeline-server
kubectl rollout status deployment/timeline-server --timeout=120s

# --- Report the client URL -------------------------------------------------
MINIKUBE_IP="$(minikube ip)"
echo
echo "timeline-server is up. Point the client's 'Local minikube' entry at:"
echo "    ws://${MINIKUBE_IP}:30080/ws"
echo
echo "Health check:  curl -fsS http://${MINIKUBE_IP}:30080/healthz"
