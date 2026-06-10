#!/usr/bin/env bash
# Open the Argo CD web console for the UPCLOUD cluster.
#
# Same behaviour as the local script, but targets the UpCloud cluster. It reuses
# the SAME kubeconfig deploy-upcloud.sh uses — which lives OUTSIDE the repo (the
# repo's .gitignore blocks *kubeconfig*.yaml, so a cluster-admin kubeconfig is
# never committed):
#
#   ~/.secrets/tech-sandbox-upcloud-k8s-cluster_kubeconfig.yaml
#
# Override either piece if your setup differs:
#   KUBECONFIG=/path/to/kubeconfig scripts/argo-web-console-upcloud.sh
#   CONTEXT=my-ctx                 scripts/argo-web-console-upcloud.sh
#
# Usage: scripts/argo-web-console-upcloud.sh
set -euo pipefail

# --- config ---------------------------------------------------------------
# Default to the out-of-repo UpCloud kubeconfig (same one deploy-upcloud.sh uses).
# Honor an already-exported KUBECONFIG first.
DEFAULT_KUBECONFIG_FILE="$HOME/.secrets/tech-sandbox-upcloud-k8s-cluster_kubeconfig.yaml"
export KUBECONFIG="${KUBECONFIG:-$DEFAULT_KUBECONFIG_FILE}"

# Context: default to the UpCloud admin context deploy-upcloud.sh asserts; allow
# override. Fall back to the kubeconfig's current-context if that name isn't present.
CONTEXT="${CONTEXT:-kubernetes-admin@tech-sandbox-upcloud-k8s-cluster}"
NAMESPACE="argocd"
LOCAL_PORT="8081"         # different port from the local script so both can run at once
URL="https://localhost:${LOCAL_PORT}"

# --- sanity checks --------------------------------------------------------
if [[ ! -f "${KUBECONFIG}" ]]; then
  echo "ERROR: kubeconfig not found at ${KUBECONFIG}." >&2
  echo "Put your UpCloud kubeconfig there, or export KUBECONFIG to point at it." >&2
  exit 1
fi

if ! kubectl config get-contexts -o name | grep -qx "${CONTEXT}"; then
  # Named context not in this kubeconfig — fall back to whatever it defaults to.
  FALLBACK="$(kubectl config current-context 2>/dev/null || true)"
  if [[ -z "${FALLBACK}" ]]; then
    echo "ERROR: context '${CONTEXT}' not found and no current-context set." >&2
    echo "Set one explicitly: CONTEXT=<name> $0" >&2
    echo "Available contexts:" >&2
    kubectl config get-contexts -o name >&2
    exit 1
  fi
  echo "NOTE: context '${CONTEXT}' not found; using '${FALLBACK}' from ${KUBECONFIG}." >&2
  CONTEXT="${FALLBACK}"
fi

if ! kubectl --context "${CONTEXT}" get deploy argocd-server -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: argocd-server not found in '${NAMESPACE}' on context '${CONTEXT}'." >&2
  echo "Is Argo CD installed in the UpCloud cluster? (KUBECONFIG=${KUBECONFIG})" >&2
  exit 1
fi

# --- admin password (best effort) ----------------------------------------
echo "Argo CD (upcloud / ${CONTEXT})"
PW="$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" \
      get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
if [[ -n "${PW}" ]]; then
  echo "  user: admin"
  echo "  pass: ${PW}"
else
  echo "  (initial admin secret not found — password was likely already rotated)"
fi

# --- port-forward + open browser -----------------------------------------
echo "  forwarding ${URL}  (Ctrl-C to stop)"
kubectl --context "${CONTEXT}" -n "${NAMESPACE}" \
  port-forward svc/argocd-server "${LOCAL_PORT}:443" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/${LOCAL_PORT}") 2>/dev/null; then
    exec 3>&- 3<&- 2>/dev/null || true
    break
  fi
  sleep 0.2
done

xdg-open "${URL}" >/dev/null 2>&1 || echo "  open ${URL} manually"
wait "${PF_PID}"
