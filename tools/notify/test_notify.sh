#!/usr/bin/env bash
## notify contract suite (tools/notify/README.md): unittest with a fake
## urllib transport and temp ledgers — no network, no live FCM call, no
## credential value printed. The crypto path is pinned to the official
## RFC 7515 A.2 RS256 test vector.
##
## Interpreter resolution order: $HSCOLLECTOR_PYTHON, then python3.13,
## then `uv python find 3.13` (the collector suite's order). Pure
## standard library: no dependency bootstrap, no venv needed. No Python,
## no suite: this exits non-zero, it never reports a pass.
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
  echo "test_notify.sh: no Python 3.13 interpreter found (tried" \
       "\$HSCOLLECTOR_PYTHON, python3.13, 'uv python find 3.13')" >&2
  exit 1
fi

echo "=== notify contract suite ($PY) ==="
exec "$PY" -m unittest tools/notify/test_notify.py
