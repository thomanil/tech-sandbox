#!/usr/bin/env bash
# Static "does it even hold together?" check for the whole repo — run this before
# committing or in CI. It is the stable entrypoint for "is the code sound?": the
# checks below may change, but callers keep running one command.
#
# This script is read-only: it reports problems and never edits your files. To
# auto-fix the fixable lint/formatting issues it surfaces, run the sibling
# scripts/autofix_lint_formatting.sh.
#
# It never starts the app or hits the network for app state; it only reads the
# source. Two halves:
#
#   Web client (app/client-web, TypeScript/React)
#     - tsc -b ........ full type-check (project refs, noEmit) — catches type
#                       errors, unused locals/params, bad imports.
#     - eslint . ...... lint (the repo's flat eslint.config.js, react-hooks etc).
#
#   Python (app/server-python + app/client-python-qt)
#     - py_compile .... parse/compile every module → hard syntax/AST errors.
#     - ruff check .... lint + error analysis (pyflakes F-rules catch undefined
#                       names, unused imports/vars; pycodestyle E-rules catch
#                       style errors). Run via `uvx`, so nothing to pre-install.
#     - ruff format ... formatting drift (check-only, never rewrites here).
#
# All checks run even if an earlier one fails, so you see every problem in one
# pass; the script exits non-zero if any check failed.
set -uo pipefail

# Run from the repo root regardless of where the script is invoked from.
cd "$(dirname "$0")/.." || exit 1

# Collect the names of failed checks so we can report them all at the end.
FAILURES=()
section() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
run() {
  # run <label> <cmd...> — execute a check, remember it if it fails.
  local label="$1"; shift
  if "$@"; then
    printf '\033[32m  ✓ %s\033[0m\n' "$label"
  else
    printf '\033[31m  ✗ %s\033[0m\n' "$label"
    FAILURES+=("$label")
  fi
}

# --- Web client: TypeScript + ESLint ----------------------------------------
section "Web client (app/client-web)"
(
  cd app/client-web || exit 1
  # A fresh checkout has no node_modules — install from the lockfile so tsc/eslint
  # don't fail on missing deps (mirrors start-web-client.sh).
  if [ ! -d node_modules ]; then
    echo "Installing web client dependencies (first run)…"
    npm ci
  fi
)
run "tsc (web type-check)" bash -c 'cd app/client-web && npx --no-install tsc -b'
run "eslint (web lint)"    bash -c 'cd app/client-web && npx --no-install eslint .'

# --- Python: AST/compile + ruff lint + ruff format --------------------------
section "Python (app/server-python, app/client-python-qt)"

# Every .py under app/, excluding caches. NUL-delimited to survive odd paths.
mapfile -d '' -t PY_FILES < <(find app -name '*.py' -not -path '*/__pycache__/*' -print0)

if [ "${#PY_FILES[@]}" -eq 0 ]; then
  echo "  (no Python files found)"
else
  # AST/syntax: compile each module. PEP 723 deps aren't needed just to parse.
  run "py_compile (Python syntax/AST)" python3 -m py_compile "${PY_FILES[@]}"

  # Lint + error analysis via uvx (fetches ruff on first use, then caches it).
  # ruff's defaults (E + F) are exactly lint + pyflakes error checks; no config
  # file required.
  run "ruff check (Python lint)"   uvx ruff check app
  run "ruff format (Python style)" uvx ruff format --check app
fi

# --- Summary ----------------------------------------------------------------
section "Summary"
if [ "${#FAILURES[@]}" -eq 0 ]; then
  printf '\033[32mAll checks passed.\033[0m\n'
  exit 0
fi
printf '\033[31m%d check(s) failed:\033[0m\n' "${#FAILURES[@]}"
printf '  - %s\n' "${FAILURES[@]}"
printf '\nTo auto-fix the fixable lint/formatting issues, run:\n'
printf '  scripts/autofix_lint_formatting.sh\n'
exit 1
