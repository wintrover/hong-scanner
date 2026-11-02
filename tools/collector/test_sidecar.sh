#!/usr/bin/env bash
## sidecar contract suite (tools/collector/README.md §11): unittest with a
## fake websockets module, a fake core pipe and a loopback-only fake token
## HTTP server — no live API call, no credential value printed.
##
## Interpreter resolution order: $HSCOLLECTOR_PYTHON, then python3.13,
## then `uv python find 3.13`. The single websockets dependency is
## bootstrapped into tools/collector/.venv (gitignored) when the chosen
## interpreter lacks it. No Python, no suite: this exits non-zero, it
## never reports a pass.
##
## Leak gate (README §5 MUST): the suite output is captured and grepped
## for every credential/token fixture value defined in the test module —
## a single hit fails the suite, and the reported line names the fixture
## variable, never its value.
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
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
if ! "$PY" -m unittest tools/collector/test_sidecar.py >"$OUT" 2>&1; then
  cat "$OUT" >&2
  exit 1
fi

# The fixture literals are read from the test module itself so this grep
# cannot go stale when a fixture changes.
SENTINELS="$("$PY" - <<'PYEOF'
import sys
sys.path.insert(0, "tools/collector")
import test_sidecar as t
for name in t.ENV_SECRET_FIXTURES:
    value = getattr(t, name)
    assert isinstance(value, str) and value, name
    print("%s\t%s" % (name, value))
PYEOF
)"
LEAKED=""
while IFS="$(printf '\t')" read -r name value; do
  [ -n "${name:-}" ] || continue
  if grep -qF -- "$value" "$OUT"; then
    LEAKED="$LEAKED $name"
  fi
done <<<"$SENTINELS"
if [ -n "$LEAKED" ]; then
  echo "test_sidecar.sh: credential fixture values leaked into the" \
       "suite output (variables:$LEAKED )" >&2
  exit 1
fi
cat "$OUT"
