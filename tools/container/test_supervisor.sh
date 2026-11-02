#!/usr/bin/env bash
## cloud runtime supervisor contract suite (tools/container/README.md §7):
## deterministic unittest with fake child processes and an injected
## clock (no real collector/worker runs), real HTTP probes on an
## ephemeral loopback port, and one real serve.py child plus one real
## cloud_supervisor process (loopback only — no market data, no
## credentials). The suite reaps every process it starts.
##
## Interpreter resolution order: $HSCOLLECTOR_PYTHON, then python3.13,
## then `uv python find 3.13` (the api/collector/notify suites' order).
## Pure standard library on both sides. No Python, no suite: this exits
## non-zero, it never reports a pass.
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
  echo "test_supervisor.sh: no Python 3.13 interpreter found (tried" \
       "\$HSCOLLECTOR_PYTHON, python3.13, 'uv python find 3.13')" >&2
  exit 1
fi

echo "=== cloud supervisor contract suite ($PY) ==="
exec "$PY" -m unittest tools/container/test_supervisor.py
