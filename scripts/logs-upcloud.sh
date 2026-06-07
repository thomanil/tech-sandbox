#!/usr/bin/env bash
# Follow the timeline state server's logs from the UpCloud deployment.
#
# This is the stable entrypoint for "tail the server logs on UpCloud" — the
# remote counterpart to logs-minikube.sh. The server logs client events
# (connects, playback commands) to stdout, which the container captures, so this
# streams the roster tables as they happen on the live public cluster.
#
# Like deploy-upcloud.sh, every kubectl call is pinned to the UpCloud kubeconfig
# via KUBECONFIG, so this never tails whatever your default kubectl context
# happens to be (e.g. a local minikube). It honors an already-set KUBECONFIG and
# otherwise falls back to the local out-of-repo copy. It also asserts the
# expected cluster context before streaming.
#
# Caveat: a follow is bound to a single pod. A deploy (deploy-upcloud.sh, or the
# CI auto-rollout on a push to main) does a rollout that replaces the pod
# (Recreate strategy), which ends the stream — just run this again once the new
# pod is ready. The old pod's logs are gone with it; use the same command with
# --previous to see the last terminated pod's output.
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
  echo "Refusing to stream: kubeconfig context is '$CURRENT_CONTEXT', expected '$EXPECTED_CONTEXT'." >&2
  exit 1
fi

# Stream the logs, dropping the noisy healthcheck request lines. --line-buffered
# keeps output flowing line-by-line for the follow; grep -v's exit status is
# masked so a (transient) all-filtered chunk can't trip pipefail and kill the tail.
kubectl logs -f deployment/timeline-server --timestamps \
  | { grep -v --line-buffered "GET /healthz HTTP/1.1" || true; }
