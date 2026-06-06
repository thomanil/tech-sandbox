#!/usr/bin/env bash
# Pull the latest main-built server image from GitHub Container Registry (GHCR)
# and run it on local minikube — an end-to-end test of the PUBLISHED artifact.
#
# Counterpart to deploy-minikube.sh:
#   - deploy-minikube.sh         builds the image from your working tree into
#                                minikube (fast inner-loop, tests local source).
#   - test-latest-main-image-... pulls ghcr.io/thomanil/timeline-server:latest
#                                (what .github/workflows/build-image.yml pushes
#                                on every push to main) and runs THAT — so it
#                                verifies the real published image, CI included.
#
# The GHCR package must be PUBLIC for this unauthenticated pull to work (a one-
# time setting on the package; see README). Prerequisites: minikube and kubectl.
# If either is missing the script stops and tells you where to get it.
set -euo pipefail

# Run from the repo root regardless of where the script is invoked from.
cd "$(dirname "$0")/.."

IMAGE="ghcr.io/thomanil/timeline-server:latest"

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

# --- Pull the published image into minikube --------------------------------
# Pull into minikube's own runtime up front. This refreshes the cached :latest
# to the newest pushed build and fails fast with a clear error if the package
# is missing or still private — rather than an opaque ImagePullBackOff later.
echo "Pulling ${IMAGE} into minikube..."
if ! minikube image pull "${IMAGE}"; then
  echo >&2
  echo "Failed to pull ${IMAGE}." >&2
  echo "Is the GHCR package public, and has the build workflow run on main yet?" >&2
  echo "Check: https://github.com/thomanil/tech-sandbox/pkgs/container/timeline-server" >&2
  exit 1
fi

# --- Apply manifests and roll out ------------------------------------------
echo "Applying manifests..."
kubectl apply -f k8s/timeline-server-published.yaml

# Force a new pod so the freshly-pulled :latest is actually used (an unchanged
# manifest wouldn't otherwise restart the pod). Mirrors deploy-minikube.sh.
echo "Rolling out..."
kubectl rollout restart deployment/timeline-server
kubectl rollout status deployment/timeline-server --timeout=120s

# --- Report the client URL -------------------------------------------------
MINIKUBE_IP="$(minikube ip)"
echo
echo "Published timeline-server is up (pulled from GHCR). Point the client's"
echo "'Local minikube' entry at:"
echo "    ws://${MINIKUBE_IP}:30080/ws"
echo
echo "Health check:  curl -fsS http://${MINIKUBE_IP}:30080/healthz"
echo "Logs:          ./scripts/logs-minikube.sh"
