#!/usr/bin/env bash
# Start the timeline state server for local dev.
#
# This is the stable entrypoint for "run the server" — the dev workflow stays
# the same even if the implementation changes. Today it's a containerized
# FastAPI/uvicorn server with hot reload (Compose syncs source into the running
# container and uvicorn --reload picks it up); swap the command below if that
# changes and callers don't have to care.
set -euo pipefail

# Run from the repo root regardless of where the script is invoked from.
cd "$(dirname "$0")/.."

exec docker compose watch
