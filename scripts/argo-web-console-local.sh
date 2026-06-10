#!/usr/bin/env bash
# Open the Argo CD web console for the LOCAL minikube cluster.
#
# Port-forwards argocd-server and opens it in your browser on Linux. Targets the
# minikube context explicitly so it never forwards to the wrong cluster (the most
# likely bug in a script like this). Prints the admin password for convenience.
# Ctrl-C tears the port-forward down cleanly.
#
# Usage: scripts/argo-web-console-local.sh
set -euo pipefail

# --- config ---------------------------------------------------------------
CONTEXT="minikube"        # kube-context for the local cluster
NAMESPACE="argocd"        # where Argo CD is installed
LOCAL_PORT="8080"         # localhost port to forward to
URL="https://localhost:${LOCAL_PORT}"

# --- sanity checks --------------------------------------------------------
if ! kubectl config get-contexts -o name | grep -qx "${CONTEXT}"; then
  echo "ERROR: kube-context '${CONTEXT}' not found." >&2
  echo "Available contexts:" >&2
  kubectl config get-contexts -o name >&2
  exit 1
fi

if ! kubectl --context "${CONTEXT}" get deploy argocd-server -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: argocd-server not found in '${NAMESPACE}' on context '${CONTEXT}'." >&2
  echo "Is Argo CD installed in this cluster?" >&2
  exit 1
fi

# --- admin password (best effort) ----------------------------------------
echo "Argo CD (local / ${CONTEXT})"
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
# Start the forward in the background, remember its PID, and make sure we kill
# it whenever this script exits (normal exit, Ctrl-C, or error).
echo "  forwarding ${URL}  (Ctrl-C to stop)"
kubectl --context "${CONTEXT}" -n "${NAMESPACE}" \
  port-forward svc/argocd-server "${LOCAL_PORT}:443" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT

# Wait until the local port is actually accepting connections before opening.
for _ in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/${LOCAL_PORT}") 2>/dev/null; then
    exec 3>&- 3<&- 2>/dev/null || true
    break
  fi
  sleep 0.2
done

# Open in the default browser (Linux). The cert is self-signed — accept the
# warning; that's expected for a port-forwarded argocd-server.
xdg-open "${URL}" >/dev/null 2>&1 || echo "  open ${URL} manually"

# Keep the script (and thus the port-forward) alive until the user quits.
wait "${PF_PID}"
