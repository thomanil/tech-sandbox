#!/usr/bin/env bash
# Start the timeline GUI client for local dev, restarting on source changes.
#
# This is the stable entrypoint for "run the client" — the dev workflow stays
# the same even if the implementation changes. Today it's a PySide6/Qt app run
# via uv, with entr restarting it on edits to its own source. When the client
# becomes web-based, swap the command below and callers don't have to care.
#
# Run it again in a second terminal for a second window — the server keeps all
# clients in sync.
set -euo pipefail

# Run from the repo root regardless of where the script is invoked from.
cd "$(dirname "$0")/.."

echo timeline_client.py | entr -r uv run timeline_client.py
