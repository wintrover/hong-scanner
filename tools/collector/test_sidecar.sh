#!/usr/bin/env bash
## sidecar contract suite (tools/collector/README.md §11): unittest with a
## fake websockets module and a fake core pipe — no live API call, no
## credential value printed.
##
## Interpreter resolution order: $HSCOLLECTOR_PYTHON, then python3.13,
## then `uv python find 3.13`. The single websockets dependency is
## bootstrapped into tools/collector/.venv (gitignored) when the chosen
## interpreter lacks it. No Python, no suite: this exits non-zero, it
## never reports a pass.
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
  echo "test_sidecar.sh: no Python 3.13 interpreter found (tried" \
       "\$HSCOLLECTOR_PYTHON, python3.13, 'uv python find 3.13')" >&2
  exit 1
fi

if ! "$PY" -c 'import websockets' >/dev/null 2>&1; then
  VENV="tools/collector/.venv"
  if [ ! -x "$VENV/bin/python" ]; then
    if command -v uv >/dev/null 2>&1; then
      uv venv "$VENV" --python 3.13
    else
      "$PY" -m venv "$VENV"
    fi
  fi
  VPY="$VENV/bin/python"
  if command -v uv >/dev/null 2>&1; then
    uv pip install --python "$VPY" -q -r tools/collector/requirements.txt
  else
    "$VPY" -m pip install -q -r tools/collector/requirements.txt
  fi
  PY="$VPY"
fi

echo "=== sidecar contract suite ($PY) ==="
exec "$PY" -m unittest tools/collector/test_sidecar.py
