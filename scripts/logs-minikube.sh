#!/usr/bin/env bash
# Follow the timeline state server's logs from the minikube deployment.
#
# This is the stable entrypoint for "tail the server logs in k8s" — the rough
# equivalent of `docker compose logs -f` for the minikube path. The server logs
# client events (connects, playback commands) to stdout, which the container
# captures, so this streams the roster tables as they happen.
#
# Caveat: a follow is bound to a single pod. Re-running deploy-minikube.sh does
# a rollout that replaces the pod (Recreate strategy), which ends the stream —
# just run this again once the new pod is ready. The old pod's logs are gone
# with it; use `kubectl logs deployment/timeline-server --previous` to see the
# last terminated pod's output.
set -euo pipefail

# Run from the repo root regardless of where the script is invoked from.
cd "$(dirname "$0")/.."

exec kubectl logs -f deployment/timeline-server --timestamps
