#!/usr/bin/env bash
# Auto-fix the lint and formatting issues that scripts/error_check.sh reports —
# the write counterpart to that read-only checker. Run this to clean up, then
# run error_check.sh to confirm what's left (type errors and unsafe lint hits
# that can't be fixed mechanically still need a human).
#
# It edits files in place, so review the diff afterwards. Same scope as the
# checker:
#
#   Web client (app/client-web, TypeScript/React)
#     - eslint . --fix .... apply ESLint's auto-fixable rules.
#
#   Python (app/server-python + app/client-python-qt)
#     - ruff check --fix .. apply ruff's safe lint fixes (unsafe fixes are left
#                           for you; error_check.sh will still flag them).
#     - ruff format ....... rewrite files to ruff's format.
#
# Note: there is no type-check fixer here — tsc errors are reported by
# error_check.sh and fixed by hand.
set -uo pipefail

# Run from the repo root regardless of where the script is invoked from.
cd "$(dirname "$0")/.." || exit 1

section() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# --- Web client: ESLint --fix -----------------------------------------------
section "Web client (app/client-web)"
(
  cd app/client-web || exit 1
  # A fresh checkout has no node_modules — install from the lockfile so eslint
  # doesn't fail on missing deps (mirrors start-web-client.sh).
  if [ ! -d node_modules ]; then
    echo "Installing web client dependencies (first run)…"
    npm ci
  fi
)
( cd app/client-web && npx --no-install eslint . --fix )

# --- Python: ruff --fix + ruff format ---------------------------------------
section "Python (app/server-python, app/client-python-qt)"

# Every .py under app/, excluding caches.
if find app -name '*.py' -not -path '*/__pycache__/*' -print -quit | grep -q .; then
  # Run via uvx (fetches ruff on first use, then caches it).
  uvx ruff check --fix app
  uvx ruff format app
else
  echo "  (no Python files found)"
fi

section "Done"
printf 'Auto-fixes applied. Review the diff, then run scripts/error_check.sh to verify.\n'
