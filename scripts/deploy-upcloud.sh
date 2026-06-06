#!/usr/bin/env bash
# Deploy the timeline state server to the remote UpCloud Managed Kubernetes
# cluster, pulling the published image from GHCR.
#
# This is the public-remote counterpart to the minikube scripts:
#   - deploy-minikube.sh                  builds from the working tree into minikube.
#   - test-latest-main-image-on-minikube  pulls ghcr.io :latest and runs it on minikube.
#   - deploy-upcloud.sh (this)            applies the same GHCR :latest to UpCloud and
#                                         exposes it publicly via a load balancer.
#
# It does NOT build or push anything — UpCloud pulls ghcr.io/thomanil/timeline-server:latest
# straight from GHCR, which CI publishes on every push to main
# (.github/workflows/build-image.yml). So the deploy is: apply the manifest,
# force a rollout (so a fresh :latest is pulled), wait for readiness, then wait
# for the load balancer's public hostname and print the client URL.
#
# All kubectl calls are pinned to the UpCloud kubeconfig via KUBECONFIG, so this
# never touches whatever your default kubectl context happens to be (e.g. a local
# minikube). As a guard it also asserts the expected cluster context before
# changing anything.
#
# Prerequisites: kubectl, and the UpCloud kubeconfig committed at
# k8s/upcloud_timeline-public_kubeconfig.yaml. The GHCR package must be PUBLIC
# (it is) so the kubelet can pull without credentials.
set -euo pipefail

# Run from the repo root regardless of where the script is invoked from.
cd "$(dirname "$0")/.."

KUBECONFIG_FILE="k8s/upcloud_timeline-public_kubeconfig.yaml"
MANIFEST="k8s/timeline-server-upcloud.yaml"
EXPECTED_CONTEXT="kubernetes-admin@timeline-public"

# --- Preflight: required tooling and config --------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found. Install it: https://kubernetes.io/docs/tasks/tools/" >&2
  exit 1
fi
if [[ ! -f "$KUBECONFIG_FILE" ]]; then
  echo "UpCloud kubeconfig not found at $KUBECONFIG_FILE" >&2
  exit 1
fi

# Pin every kubectl call below to the UpCloud cluster — not the user's default.
export KUBECONFIG="$PWD/$KUBECONFIG_FILE"

# --- Safety guard: make sure we're aimed at the right cluster ---------------
CURRENT_CONTEXT="$(kubectl config current-context)"
if [[ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]]; then
  echo "Refusing to deploy: kubeconfig context is '$CURRENT_CONTEXT', expected '$EXPECTED_CONTEXT'." >&2
  exit 1
fi

# Confirm the API server is actually reachable before we start changing things.
if ! kubectl get nodes >/dev/null 2>&1; then
  echo "Cannot reach the UpCloud cluster API. Check network and that the kubeconfig is current." >&2
  exit 1
fi

# --- Apply manifests and roll out ------------------------------------------
echo "Applying $MANIFEST to $EXPECTED_CONTEXT..."
kubectl apply -f "$MANIFEST"

# Force a new pod so the freshest :latest is pulled (imagePullPolicy: Always);
# an unchanged manifest wouldn't otherwise restart the pod. Mirrors the minikube
# scripts.
echo "Rolling out..."
kubectl rollout restart deployment/timeline-server
kubectl rollout status deployment/timeline-server --timeout=180s

# --- Wait for the load balancer's public address ---------------------------
# UpCloud provisions the load balancer asynchronously after the Service is
# created, so its public hostname/IP appears a little later. Poll for it.
echo "Waiting for the load balancer to be provisioned (can take a minute)..."
LB_HOST=""
for _ in $(seq 1 60); do
  LB_HOST="$(kubectl get service timeline-server \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
  if [[ -n "$LB_HOST" ]]; then
    break
  fi
  sleep 5
done

echo
if [[ -z "$LB_HOST" ]]; then
  echo "Deployment is up, but the load balancer has no external address yet." >&2
  echo "Check again with:  kubectl --kubeconfig $KUBECONFIG_FILE get service timeline-server -w" >&2
  exit 1
fi

echo "timeline-server is live on UpCloud. Point the client at:"
echo "    ws://${LB_HOST}/ws"
echo
echo "Health check:  curl -fsS http://${LB_HOST}/healthz"
echo "Logs:          kubectl --kubeconfig $KUBECONFIG_FILE logs -f deployment/timeline-server --timestamps"
