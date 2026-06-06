#!/usr/bin/env bash
# Follow the timeline state server's logs from the UpCloud deployment.
#
# This is the stable entrypoint for "tail the server logs on UpCloud" — the
# remote counterpart to logs-minikube.sh. The server logs client events
# (connects, playback commands) to stdout, which the container captures, so this
# streams the roster tables as they happen on the live public cluster.
#
# Like deploy-upcloud.sh, every kubectl call is pinned to the committed UpCloud
# kubeconfig via KUBECONFIG, so this never tails whatever your default kubectl
# context happens to be (e.g. a local minikube). It also asserts the expected
# cluster context before streaming.
#
# Caveat: a follow is bound to a single pod. A deploy (deploy-upcloud.sh, or the
# CI auto-rollout on a push to main) does a rollout that replaces the pod
# (Recreate strategy), which ends the stream — just run this again once the new
# pod is ready. The old pod's logs are gone with it; use the same command with
# --previous to see the last terminated pod's output.
set -euo pipefail

# Run from the repo root regardless of where the script is invoked from.
cd "$(dirname "$0")/.."

KUBECONFIG_FILE="k8s/upcloud_timeline-public_kubeconfig.yaml"
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
  echo "Refusing to stream: kubeconfig context is '$CURRENT_CONTEXT', expected '$EXPECTED_CONTEXT'." >&2
  exit 1
fi

exec kubectl logs -f deployment/timeline-server --timestamps
