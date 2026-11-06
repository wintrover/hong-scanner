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
# The init line it receives is dumped verbatim: the token_source flag
# assertions below read it back (README §2.1/§5.1).
cat > "$SANDBOX/sidecar.py" <<'EOF'
import sys

t = "2026-10-30T09:00:00+09:00"
out = sys.stdout
out.write('{"ev":"ready","t":"%s"}\n' % t)
out.write('{"ev":"token","t":"%s"}\n' % t)
out.flush()
init = sys.stdin.readline()  # init
with open("initdump.txt", "w", encoding="utf-8") as f:
    f.write(init)
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

# ------------------------------------------------------- token_source flag
# The binary is the only window through which a session declares the
# sidecar credential path (README §2.1/§5.1). The stub dumped the init
# line of the default run above; an explicit --token-source=env run must
# carry the field verbatim and nothing else may change (the same honest
# INCOMPLETE). All values are synthetic: no credential ever exists here.
INIT1="$(cat "$SANDBOX/initdump.txt")"
assert_contains "default init line names the kiwoomcli token source" \
  "$INIT1" '"token_source":"kiwoomcli"'
assert_contains "the default environment stays demo (the declared default)" \
  "$INIT1" '"environment":"demo"'

RUN2="$SANDBOX/run-env"
RC2=0
(cd "$SANDBOX" && HSCOLLECTOR_PYTHON=python3 PYTHONDONTWRITEBYTECODE=1 \
  "$BIN" --profile=pipe-test --session-date=2026-10-30 \
  --calendar="$SANDBOX/cal.json" --out="$RUN2" --token-source=env \
  > "$SANDBOX/collector2.stdout" 2> "$SANDBOX/collector2.stderr") || RC2=$?
assert_eq "--token-source=env run is the same honest INCOMPLETE (4)" 4 "$RC2"
INIT2="$(cat "$SANDBOX/initdump.txt")"
assert_contains "the env run's init line names the env token source" \
  "$INIT2" '"token_source":"env"'
assert_not_contains "the env run's init line does not name kiwoomcli" \
  "$INIT2" "kiwoomcli"

RUN3="$SANDBOX/run-bad"
RC3=0
(cd "$SANDBOX" && HSCOLLECTOR_PYTHON=python3 PYTHONDONTWRITEBYTECODE=1 \
  "$BIN" --profile=pipe-test --session-date=2026-10-30 \
  --calendar="$SANDBOX/cal.json" --out="$RUN3" --token-source=bogus \
  > "$SANDBOX/collector3.stdout" 2> "$SANDBOX/collector3.stderr") || RC3=$?
assert_eq "a non-approved --token-source is refused (exit 2)" 2 "$RC3"
assert_absent_file "the refused run started nothing (no input log)" \
  "$RUN3/input.hcj.jsonl"

# ----------------------------------------------------- environment flag
# --environment selects the operating environment and every endpoint is
# derived from it (README §2.1): the stub dumps the init line, so a real
# run must carry the real domains and nothing demo. "prod" (retired) and
# any other name is a usage refusal (exit 2) — there is never a fallback
# to another environment.
RUN4="$SANDBOX/run-real"
RC4=0
(cd "$SANDBOX" && HSCOLLECTOR_PYTHON=python3 PYTHONDONTWRITEBYTECODE=1 \
  "$BIN" --profile=pipe-test --session-date=2026-10-30 \
  --calendar="$SANDBOX/cal.json" --out="$RUN4" --environment=real \
  > "$SANDBOX/collector4.stdout" 2> "$SANDBOX/collector4.stderr") || RC4=$?
assert_eq "--environment=real run is the same honest INCOMPLETE (4)" 4 "$RC4"
INIT4="$(cat "$SANDBOX/initdump.txt")"
assert_contains "the real run's init line carries the real environment" \
  "$INIT4" '"environment":"real"'
assert_contains "the real run's init line carries the real REST domain" \
  "$INIT4" '"rest_domain":"https://api.kiwoom.com"'
assert_contains "the real run's init line carries the real WS endpoint" \
  "$INIT4" '"ws_endpoint":"wss://api.kiwoom.com:10000/api/dostk/websocket"'
assert_not_contains "the real run's init line has no mock domain" \
  "$INIT4" "mockapi"
REALLOG="$(cat "$RUN4/input.hcj.jsonl")"
assert_contains "the real config record carries the real REST domain" \
  "$REALLOG" '"rest_domain":"https://api.kiwoom.com"'
assert_contains "the real config record carries the environment" \
  "$REALLOG" '"environment":"real"'
assert_not_contains "the real stream never records a mock domain" \
  "$REALLOG" "mockapi"

for BADENV in prod staging ""; do
  RUNB="$SANDBOX/run-badenv-$BADENV"
  RCB=0
  (cd "$SANDBOX" && HSCOLLECTOR_PYTHON=python3 PYTHONDONTWRITEBYTECODE=1 \
    "$BIN" --profile=pipe-test --session-date=2026-10-30 \
    --calendar="$SANDBOX/cal.json" --out="$RUNB" \
    --environment="$BADENV" \
    > "$SANDBOX/collectorb.stdout" 2> "$SANDBOX/collectorb.stderr") || RCB=$?
  assert_eq "a non-approved --environment='$BADENV' is refused (exit 2)" 2 "$RCB"
  assert_contains "the refusal names the environment rule" \
    "$(cat "$SANDBOX/collectorb.stderr")" "--environment must be demo or real"
  assert_absent_file "the refused environment run started nothing" \
    "$RUNB/input.hcj.jsonl"
done

echo
if [ "$FAILED" -eq 0 ]; then
  echo "COLLECTOR PIPE CONTRACT PASSED ($PASS checks)"
else
  echo "COLLECTOR PIPE CONTRACT FAILED ($FAILED failed / $PASS passed)"
  exit 1
fi
