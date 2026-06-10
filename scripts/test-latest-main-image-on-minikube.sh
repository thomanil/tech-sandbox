#!/usr/bin/env bash
# Pull a main-built server image from GitHub Container Registry (GHCR) and run it
# on local minikube — an end-to-end test of the PUBLISHED artifact.
#
# Counterpart to deploy-minikube.sh:
#   - deploy-minikube.sh         builds the image from your working tree into
#                                minikube (fast inner-loop, tests local source).
#   - test-latest-main-image-... pulls a published ghcr.io/thomanil/timeline-server
#                                sha-<commit> image (what build-image.yml pushes on
#                                every push to main) and runs THAT — so it verifies
#                                the real published image, CI included.
#
# There is no :latest tag anymore (CI publishes only immutable sha-<commit> tags),
# so this resolves the commit to test:
#   - default: the tip of origin/main (the newest build CI should have produced).
#   - or pass an explicit git ref / full SHA as $1 to pin a specific build,
#     e.g. ./scripts/test-latest-main-image-on-minikube.sh 2ced2ce
#
# The GHCR package must be PUBLIC for this unauthenticated pull to work (a one-
# time setting on the package; see README). Prerequisites: minikube, kubectl, git.
# If any is missing the script stops and tells you where to get it.
set -euo pipefail

# Run from the repo root regardless of where the script is invoked from.
cd "$(dirname "$0")/.."

IMAGE_REPO="ghcr.io/thomanil/timeline-server"

# Resolve the commit to test to a FULL 40-hex SHA, then build the sha-<...> tag
# that docker/metadata-action (type=sha,format=long) publishes. Default to the
# tip of origin/main; honor an explicit ref/SHA in $1.
REF="${1:-origin/main}"
GIT_SHA="$(git rev-parse --verify --quiet "${REF}^{commit}" || true)"
if [[ -z "${GIT_SHA}" ]]; then
  echo "Could not resolve git ref '${REF}' to a commit." >&2
  echo "Pass a valid ref/SHA, or run 'git fetch origin main' first." >&2
  exit 1
fi
IMAGE="${IMAGE_REPO}:sha-${GIT_SHA}"

# --- Preflight: required tooling -------------------------------------------
if ! command -v git >/dev/null 2>&1; then
  echo "git not found. Install it: https://git-scm.com/downloads" >&2
  exit 1
fi
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
  echo "Starting minikube.."
  minikube start
fi

# --- Pull the published image into minikube --------------------------------
# Pull the resolved sha-<commit> image into minikube's own runtime up front. This
# fails fast with a clear error if that build is missing or the package is still
# private — rather than an opaque ImagePullBackOff later.
echo "Pulling ${IMAGE} into minikube..."
if ! minikube image pull "${IMAGE}"; then
  echo >&2
  echo "Failed to pull ${IMAGE}." >&2
  echo "Has the build workflow finished for this commit, and is the GHCR package public?" >&2
  echo "(A docs-only commit produces no new image — pass an earlier built SHA as \$1.)" >&2
  echo "Check: https://github.com/thomanil/tech-sandbox/pkgs/container/timeline-server" >&2
  exit 1
fi

# --- Apply manifests and roll out ------------------------------------------
# Render the published overlay and pin its image to the exact sha we just pulled,
# then apply. Done via a stream edit (not `kustomize edit set image`) so the
# working tree's committed overlay stays clean. Uses kubectl's built-in kustomize.
echo "Applying manifests (image pinned to sha-${GIT_SHA})..."
kubectl kustomize k8s/timeline-server/overlays/published \
  | sed -E "s#(${IMAGE_REPO}):[A-Za-z0-9._-]+#\1:sha-${GIT_SHA}#" \
  | kubectl apply -f -

# Force a new pod so the freshly-pulled image is actually used (an unchanged
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
