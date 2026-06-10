#!/usr/bin/env bash
# Force a restart of the timeline state server pod on the UpCloud deployment.
#
# This is the stable entrypoint for "bounce the server on UpCloud" — handy when
# you want a clean process without pushing a new image (e.g. to clear in-memory
# state, pick up a Secret/ConfigMap change, or recover a wedged pod). It does a
# `kubectl rollout restart`, which respects the deployment's Recreate strategy:
# the single pod is terminated and a fresh one started in its place.
#
# Because state is per-client and in-memory, this is a real (brief) interruption:
# active WebSocket clients drop and reconnect. When a DB is configured the new pod
# reloads client state from timeline.client_state on startup, so clients resume
# where they left off; without a DB, state resets.
#
# Like logs-upcloud.sh, every kubectl call is pinned to the UpCloud kubeconfig
# via KUBECONFIG, so this never bounces whatever your default
# kubectl context happens to be (e.g. a local minikube). It honors an already-set
# KUBECONFIG and otherwise falls back to the local out-of-repo copy. It also
# asserts the expected cluster context before doing anything.
set -euo pipefail

# Run from the repo root regardless of where the script is invoked from.
cd "$(dirname "$0")/.."

DEFAULT_KUBECONFIG_FILE="$HOME/.secrets/tech-sandbox-upcloud-k8s-cluster_kubeconfig.yaml"
EXPECTED_CONTEXT="kubernetes-admin@tech-sandbox-upcloud-k8s-cluster"

# --- Preflight: required tooling and config --------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found. Install it: https://kubernetes.io/docs/tasks/tools/" >&2
  exit 1
fi

# Honor a KUBECONFIG supplied by the environment; otherwise fall back to the
# local out-of-repo copy. Either way pin kubectl to the UpCloud cluster.
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ ! -f "$DEFAULT_KUBECONFIG_FILE" ]]; then
    echo "No KUBECONFIG set and $DEFAULT_KUBECONFIG_FILE not found." >&2
    echo "Put your UpCloud kubeconfig there, or export KUBECONFIG to point at it." >&2
    exit 1
  fi
  export KUBECONFIG="$DEFAULT_KUBECONFIG_FILE"
fi

# --- Safety guard: make sure we're aimed at the right cluster ---------------
CURRENT_CONTEXT="$(kubectl config current-context)"
if [[ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]]; then
  echo "Refusing to restart: kubeconfig context is '$CURRENT_CONTEXT', expected '$EXPECTED_CONTEXT'." >&2
  exit 1
fi

# --- Restart and wait for the new pod to become ready -----------------------
kubectl rollout restart deployment/timeline-server
kubectl rollout status deployment/timeline-server --timeout=120s
