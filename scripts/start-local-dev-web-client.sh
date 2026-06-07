#!/usr/bin/env bash
# Start the Vite/React web client for local dev with hot-module reload.
#
# This is the stable entrypoint for "run the web client" — the web analog of
# start-python-client.sh. It launches Vite's dev server (HMR built in: a save to
# any source under app/client-web instantly patches the running page, no manual
# restart). Open the printed http://localhost:5173 URL in a browser.
#
# Vite proxies /ws to the backend on :8000 (see app/client-web/vite.config.ts),
# so run start-local-dev-server.sh in another terminal and the web client talks to it on
# the same origin — exactly as it will in the baked image, where the server
# serves the production `vite build` at / instead.
#
# Note: this is dev-only. The shipped path is the static `vite build` baked into
# the server image (see Dockerfile) and served by timeline_server.py.
set -euo pipefail

# Run from the web client dir regardless of where the script is invoked from.
cd "$(dirname "$0")/../app/client-web"

# First run (or a fresh checkout) won't have node_modules — install from the
# lockfile so `npm run dev` doesn't fail on missing deps.
if [ ! -d node_modules ]; then
  echo "Installing web client dependencies (first run)…"
  npm ci
fi

exec npm run dev
