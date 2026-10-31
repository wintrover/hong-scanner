#!/usr/bin/env bash
## Collector pipe-level contract test: the REAL collector binary consuming
## a sidecar stdout pipe one LF-terminated line at a time
## (tools/collector/collector.nim PipeReader/readLine/pollFd).
##
## Reproduces TWO pipe defects the process-pair drill found
## (tools/collector/drill/drill_pair.sh), both exposed by one stub
## session whose sidecar emits two DISTINCT lines and then exits:
##
##  1. readLine returned a line WITHOUT consuming it from its
##     accumulator, so the same first line was re-delivered on every
##     later call and no session could get past its first event. With
##     the defect the collector contracts out on the re-delivered ready
##     (exit 2 "unexpected ready event in phase phConnecting").
##  2. pollFd only accepted POLLIN, but a pipe whose last writer closed
##     reports POLLHUP without POLLIN (measured on kernel 6.17), so the
##     end-of-file was seen as an endless series of timeouts and the
##     collector spun forever instead of going honestly INCOMPLETE when
##     the sidecar dies mid-session.
##
## With both fixed the collector consumes both lines exactly once and
## then reports the honest INCOMPLETE (exit 4, unsealed file preserved)
## when the stub's pipe closes without the termination protocol.
##
## Everything runs inside one private mktemp(1) sandbox that the script
## creates and removes itself. No network, no live data, no credentials;
## the stub replaces sidecar.py via sidecarScript()'s first candidate
## (a sidecar.py next to the binary), so the repository is never
## modified. Run: bash tests/test_collector_pipe_contract.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAILED=0

assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: expected [$2] got [$3]"; FAILED=$((FAILED + 1))
  fi
}

assert_contains() { # desc haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: [$3] not found"; FAILED=$((FAILED + 1))
  fi
}

assert_not_contains() { # desc haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then
    echo "FAIL $1: [$3] must be absent"; FAILED=$((FAILED + 1))
  else
    echo "ok   $1"; PASS=$((PASS + 1))
  fi
}

assert_file() {
  if [ -f "$2" ]; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: $2 is gone"; FAILED=$((FAILED + 1))
  fi
}

assert_absent_file() {
  if [ -e "$2" ]; then
    echo "FAIL $1: $2 must not exist"; FAILED=$((FAILED + 1))
  else
    echo "ok   $1"; PASS=$((PASS + 1))
  fi
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hs-pipe-test.XXXXXX")"
cleanup() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

BIN="$SANDBOX/collector"
echo "compiling the collector from $REPO_ROOT/tools/collector"
(cd "$REPO_ROOT" && nim c -d:release --hints:off --warnings:off \
  --path:"$REPO_ROOT/src" --nimcache:"$SANDBOX/nimcache" \
  -o:"$BIN" tools/collector/collector.nim) > "$SANDBOX/compile.log" 2>&1 || {
    echo "FAIL collector does not compile:"; cat "$SANDBOX/compile.log"; exit 1; }
echo "ok   collector compiles"; PASS=$((PASS + 1))

# Hermetic calendar (the test_cli_contract.sh format), one trading day.
cat > "$SANDBOX/cal.json" <<'EOF'
{"days":{"2026-10-30":{"close":"15:30:00+09:00","open":"09:00:00+09:00"}},
 "version":"CAL-TEST"}
EOF

# The stub sidecar: two distinct lines, then consume the two directives
# the collector sends (init + connect) before exiting, so no directive
# send can race the stub's exit and the collector's next read is a pure
# pipe-EOF. The second line ("token") must NEVER come back as "ready".
cat > "$SANDBOX/sidecar.py" <<'EOF'
import sys

t = "2026-10-30T09:00:00+09:00"
out = sys.stdout
out.write('{"ev":"ready","t":"%s"}\n' % t)
out.write('{"ev":"token","t":"%s"}\n' % t)
out.flush()
sys.stdin.readline()  # init
sys.stdin.readline()  # connect
sys.exit(0)
EOF

RUN="$SANDBOX/run"
RC=0
(cd "$SANDBOX" && HSCOLLECTOR_PYTHON=python3 PYTHONDONTWRITEBYTECODE=1 \
  "$BIN" --profile=pipe-test --session-date=2026-10-30 \
  --calendar="$SANDBOX/cal.json" --out="$RUN" \
  > "$SANDBOX/collector.stdout" 2> "$SANDBOX/collector.stderr") || RC=$?
ERR="$(cat "$SANDBOX/collector.stderr")"

assert_eq "collector exit is the honest INCOMPLETE (4)" 4 "$RC"
assert_contains "collector names the closed pipe (both lines were consumed)" \
  "$ERR" "the sidecar pipe closed before the termination protocol completed"
assert_not_contains "the first line is never re-delivered (old bug exits 2 here)" \
  "$ERR" "unexpected ready event"
assert_file "unsealed stream preserved for inspection" "$RUN/input.hcj.jsonl"
assert_absent_file "no COMMITTED marker (durability never claimed)" \
  "$RUN/input.hcj.jsonl.committed"
LINES="$(wc -l < "$RUN/input.hcj.jsonl" | tr -d ' ')"
assert_eq "preamble + one closing gap record (calendar+config+gap)" 3 "$LINES"
LAST="$(tail -n 1 "$RUN/input.hcj.jsonl")"
assert_contains "the final record is the connection-wide gap" "$LAST" '"kind":"gap"'
assert_contains "the gap records the honest close reason" "$LAST" \
  "the sidecar pipe closed before the termination protocol completed"
assert_contains "the gap closes as incomplete (never success)" "$LAST" \
  '"what":"incomplete"'

echo
if [ "$FAILED" -eq 0 ]; then
  echo "COLLECTOR PIPE CONTRACT PASSED ($PASS checks)"
else
  echo "COLLECTOR PIPE CONTRACT FAILED ($FAILED failed / $PASS passed)"
  exit 1
fi
