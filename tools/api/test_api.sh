#!/usr/bin/env bash
## read-only API contract suite (tools/api/README.md): unittest with a
## real serve.py process on loopback (127.0.0.1 default, one --bind
## case on 127.0.0.2) on an ephemeral port, synthetic
## fixture run directories and ledgers in a mktemp sandbox — loopback
## only, no market data, no credentials. The suite reaps every server
## it starts and asserts a clean SIGTERM exit.
##
## Interpreter resolution order: $HSCOLLECTOR_PYTHON, then python3.13,
## then `uv python find 3.13` (the collector and notify suites' order).
## Pure standard library: no dependency bootstrap, no venv needed. No
## Python, no suite: this exits non-zero, it never reports a pass.
set -euo pipefail
cd "$(dirname "$0")/../.."

PY=""
if [ -n "${HSCOLLECTOR_PYTHON:-}" ]; then
  PY="$HSCOLLECTOR_PYTHON"
elif command -v python3.13 >/dev/null 2>&1; then
  PY="python3.13"
elif command -v uv >/dev/null 2>&1; then
  PY="$(uv python find 3.13)"
fi
if [ -z "$PY" ]; then
  echo "test_api.sh: no Python 3.13 interpreter found (tried" \
       "\$HSCOLLECTOR_PYTHON, python3.13, 'uv python find 3.13')" >&2
  exit 1
fi

echo "=== read-only api contract suite ($PY) ==="
exec "$PY" -m unittest tools/api/test_api.py
