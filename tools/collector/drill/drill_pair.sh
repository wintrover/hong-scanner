#!/usr/bin/env bash
## Process-pair drill: the REAL collector binary (tools/collector/
## collector.nim) driving the REAL sidecar.py over real OS pipes against
## a simulated Kiwoom demo wire — no network, no live data, no
## credentials (tools/collector/README.md §0-§9, §11).
##
## Fakes (tools/collector/drill/fakesite/, shape sources in
## drill_fixtures.py):
##   - fake `websockets` package on PYTHONPATH = the WS server (LOGIN/
##     REG/REMOVE acks, PING probe + client echo, 0B ticks, 0s FID 215);
##   - sitecustomize.py = the ka10027 REST endpoint, patched into
##     urllib.request.urlopen ONLY while HSDRILL=1 (stdlib urllib cannot
##     be shadowed via PYTHONPATH; inert everywhere else);
##   - seeded token cache (kwcli FileTokenStore layout) + fake
##     `kiwoomcli` on PATH = the credential path (README §5).
##
## Scenarios:
##   A  normal full session: init -> ready -> connect -> 0s REG/ack ->
##      rest up/down -> 0B REG/ack -> PING/0B/0s(215=4) -> teardown
##      REMOVE/ack -> wait_drain -> drain_done -> recorder.finish()
##      (seal + COMMITTED marker) -> stop -> sidecar exit 0 -> exit 0;
##   B  SIGKILL the collector mid-session -> unsealed file, no marker ->
##      replay/verify must say INCOMPLETE (never a forged normal close);
##   C  replay + verify of A: REPLAY OK, COMMIT=VALID. The drill binary
##      is a plain `nim c` dev build, so provenance=OK is impossible by
##      contract (docs/REPLAY_CONTRACT.md §8) — the honest ceiling is
##      VERDICT MISMATCH provenance=INVALID with zero byte issues.
##
## Wall-clock constraint: the pinned watchdog is 15:40 KST and a moment
## already past fires immediately (sidecar.py parse_watchdog_seconds),
## so the drill refuses to start between 15:40 and 24:00 KST.
##
## Usage: bash tools/collector/drill/drill_pair.sh
## Evidence: runs/drill-pair-<ts>/ (gitignored): per-scenario collector
## stdout/stderr, wire logs, run directories, input streams.
set -euo pipefail
cd "$(dirname "$0")/../../.."

PASS=0
FAIL=0
ok()  { echo "ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

check_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else
    bad "$1: expected [$2] got [$3]"; fi
}
check_contains() { # desc haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else
    bad "$1: [$3] not found"; fi
}
check_not_contains() { # desc haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then
    bad "$1: [$3] must be absent"; else ok "$1"; fi
}

# ---------------------------------------------------------- 0. clock guard
ORIG_PATH="$PATH"
KST_HOUR=$(python3 -c 'from datetime import datetime,timezone,timedelta; print(datetime.now(timezone(timedelta(hours=9))).strftime("%H%M"))')
if [ "$((10#$KST_HOUR))" -ge 1540 ]; then
  echo "drill: KST $KST_HOUR is at/after the 15:40 watchdog (it fires" \
       "immediately once past, sidecar.py parse_watchdog_seconds)." \
       "Run the drill between 00:00 and 15:39 KST." >&2
  exit 3
fi
echo "=== process-pair drill (KST $KST_HOUR, watchdog 15:40 KST) ==="

# ------------------------------------------- 1. interpreter (test_sidecar.sh order)
PY=""
if [ -n "${HSCOLLECTOR_PYTHON:-}" ]; then
  PY="$HSCOLLECTOR_PYTHON"
elif command -v python3.13 >/dev/null 2>&1; then
  PY="python3.13"
elif command -v uv >/dev/null 2>&1; then
  PY="$(uv python find 3.13)"
fi
if [ -z "$PY" ]; then
  echo "drill: no Python 3.13 interpreter found (tried" \
       "\$HSCOLLECTOR_PYTHON, python3.13, 'uv python find 3.13')" >&2
  exit 1
fi
# No venv bootstrap needed: the drill's fake websockets package shadows
# the real one on PYTHONPATH (README §11 keeps the real dependency for
# the live path and the unit suite).
FAKESITE="$PWD/tools/collector/drill/fakesite"
PY_SHADOW="$(D="$FAKESITE" PYTHONDONTWRITEBYTECODE=1 "$PY" -c 'import os,sys; sys.path.insert(0, os.environ["D"]); import websockets; print(websockets.__file__)')"
case "$PY_SHADOW" in
  "$FAKESITE"/*) ok "fake websockets shadows the real package on PYTHONPATH ($PY_SHADOW)" ;;
  *) bad "fake websockets not importable from PYTHONPATH: $PY_SHADOW"; exit 1 ;;
esac

# ------------------------------------------------------------- 2. builds
echo "--- building the collector binary (nim c, dev marker; README §11)"
nim c -d:release --hints:off --warnings:off --path:src \
  -o:tools/collector/collector tools/collector/collector.nim
echo "--- building the hongscanner replay/verify binary (nim c, dev marker)"
nim c -d:release --hints:off --warnings:off --path:src \
  -o:build/hongscanner src/hongscanner.nim
COLLECTOR="$PWD/tools/collector/collector"
HS="$PWD/build/hongscanner"

CAL="calendars/krx-2026q4.json"
if [ ! -f "$CAL" ]; then
  # Calendar JSONs are gitignored (worktree has only the index): read the
  # approved snapshot from the sibling main checkout, read-only.
  CAL="$(dirname "$PWD")/HongScanner/calendars/krx-2026q4.json"
fi
[ -f "$CAL" ] || { echo "drill: approved calendar not found" >&2; exit 1; }
ok "calendar (read-only): $CAL"

OUT="runs/drill-pair-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
echo "=== evidence directory: $OUT"

drill_env() { # $1 = scenario cache/log dir
  export HSDRILL=1
  export HSDRILL_WIRELOG="$1/wire.log"
  export HSDRILL_TOKEN_CACHE="$1/cache"
  export XDG_CACHE_HOME="$1/cache"
  export PYTHONPATH="$FAKESITE"
  export PATH="$PWD/tools/collector/drill/fakebin:$PATH"
  export PYTHONDONTWRITEBYTECODE=1
  export HSCOLLECTOR_PYTHON="$PY"
}
clear_drill_env() {
  unset HSDRILL HSDRILL_WIRELOG HSDRILL_TOKEN_CACHE XDG_CACHE_HOME \
        PYTHONPATH PYTHONDONTWRITEBYTECODE HSCOLLECTOR_PYTHON
  export PATH="$ORIG_PATH"
}
seed_cache() { # $1 = cache dir
  mkdir -p "$1"
  env -u PYTHONPATH -u HSDRILL "$PY" -c '
import sys
sys.path.insert(0, sys.argv[1])
import drill_fixtures as fx
print(fx.seed_token_cache(sys.argv[2], sys.argv[3], "DRILL-FAKE-TOKEN"))' \
    "$FAKESITE" "$1" drill-demo >/dev/null
}

record_census() { # $1 = input.hcj.jsonl, $2 = label — structural asserts
  env -u PYTHONPATH -u HSDRILL python3 - "$1" "$2" <<'PYEOF'
import json, sys
from collections import Counter

path, label = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
lines = text.splitlines()
recs = [json.loads(l) for l in lines]
kinds = [r["kind"] for r in recs]
n = Counter(kinds)
fails = []

def ck(name, cond, extra=""):
    print(("ok   " if cond else "FAIL ") + label + " " + name +
          ("" if cond else ": " + extra))
    if not cond:
        fails.append(name)

ck("input is LF-terminated", text.endswith("\n"))
ck("seq gauge 1..N",
   [r["seq"] for r in recs] == list(range(1, len(recs) + 1)))
ck("record 1 is calendar", kinds[0] == "calendar")
ck("record 2 is config", kinds[1] == "config")
ck("ws_conn=1 with state open",
   n["ws_conn"] == 1 and
   any(r["raw"].get("state") == "open"
       for r in recs if r["kind"] == "ws_conn"))
ck("gap=0 (no conn_closed/stale/send/rest failures)", n["gap"] == 0)
ck("rest_resp=2", n["rest_resp"] == 2)
ck("sub=6", n["sub"] == 6)
ck("session_end=1 and last with raw null",
   n["session_end"] == 1 and kinds[-1] == "session_end" and
   recs[-1]["raw"] is None)

wsraw = [r for r in recs if r["kind"] == "ws_raw"]
chans = Counter(r["raw"]["channel"] for r in wsraw)
ck("ws_raw LOGIN=1 REG=2 REMOVE=1 PING=1 0B=4 0s=1",
   (chans["LOGIN"], chans["REG"], chans["REMOVE"], chans["PING"],
    chans["0B"], chans["0s"]) == (1, 2, 1, 1, 4, 1), str(dict(chans)))
ck("all ws_raw on conn 1", all(r["raw"]["conn"] == 1 for r in wsraw))

subs = [r for r in recs if r["kind"] == "sub"]
if len(subs) == 6:
    s0, s1, s2, s3, s4, s5 = subs
    ck("sub[0] = (reg,req) 0s channel-only, refresh 1 (own REG)",
       s0["raw"]["action"] == "reg" and s0["raw"]["phase"] == "req" and
       s0["raw"]["types"] == ["0s"] and s0["raw"]["codes"] == [] and
       s0["raw"]["refresh"] == "1")
    ck("sub[1] = (reg,ack) code 0 pairing the 0s gen",
       s1["raw"]["phase"] == "ack" and s1["raw"]["action"] == "reg" and
       s1["raw"]["return_code"] == 0 and s1["raw"]["gen"] == s0["raw"]["gen"])
    ck("sub[2] = (reg,req) 0B candidates up+down, refresh 1",
       s2["raw"]["action"] == "reg" and s2["raw"]["phase"] == "req" and
       s2["raw"]["types"] == ["0B"] and
       s2["raw"]["codes"] == ["005930", "000660"] and
       s2["raw"]["refresh"] == "1")
    ck("sub[3] = (reg,ack) code 0", s3["raw"]["phase"] == "ack" and
       s3["raw"]["return_code"] == 0 and s3["raw"]["gen"] == s2["raw"]["gen"])
    ck("sub[4] = (remove,req) teardown naming the full active generation, no refresh",
       s4["raw"]["action"] == "remove" and s4["raw"]["phase"] == "req" and
       # active0BCodes is the documented active-set view, sorted ascending
       # (src/hs/subcheck.nim:83): the teardown names the whole generation
       # in that order.
       s4["raw"]["codes"] == ["000660", "005930"] and
       "refresh" not in s4["raw"])
    ck("sub[5] = (remove,ack) code 0", s5["raw"]["phase"] == "ack" and
       s5["raw"]["action"] == "remove" and s5["raw"]["return_code"] == 0)
    ck("sub gens monotonic 1,1,2,2,3,3",
       [s["raw"]["gen"] for s in subs] == [1, 1, 2, 2, 3, 3])
else:
    ck("sub records unpackable for structural asserts", False,
       "need 6 sub records, got %d" % len(subs))

rests = [r for r in recs if r["kind"] == "rest_resp"]
if len(rests) >= 2:
    ck("rest[0] up page 1 terminal sort_tp 1 status 200",
       rests[0]["raw"]["query"]["sort_tp"] == "1" and
       rests[0]["raw"]["page"] == 1 and rests[0]["raw"]["cont_yn"] == "N" and
       rests[0]["raw"]["status"] == 200)
    ck("rest[1] down page 1 terminal sort_tp 3",
       rests[1]["raw"]["query"]["sort_tp"] == "3" and
       rests[1]["raw"]["page"] == 1 and rests[1]["raw"]["cont_yn"] == "N")
else:
    ck("rest records unpackable for structural asserts", False,
       "need 2 rest_resp records, got %d" % len(rests))

tick_idx = [i for i, r in enumerate(recs)
            if r["kind"] == "ws_raw" and r["raw"]["channel"] == "0B"]
close_idx = [i for i, r in enumerate(recs)
             if r["kind"] == "ws_raw" and r["raw"]["channel"] == "0s"]
remove_req = [i for i, r in enumerate(recs)
              if r["kind"] == "sub" and r["raw"]["action"] == "remove"
              and r["raw"]["phase"] == "req"]
if tick_idx and close_idx and remove_req:
    ck("0B ticks precede the 0s close evidence",
       max(tick_idx) < close_idx[0])
    ck("teardown REMOVE follows the 0s close evidence",
       remove_req[0] > close_idx[0])
else:
    ck("0B/0s/remove records present for ordering asserts", False,
       "0B=%d 0s=%d remove_req=%d" % (len(tick_idx), len(close_idx),
                                      len(remove_req)))

print(label + " record count = %d" % len(recs))
sys.exit(1 if fails else 0)
PYEOF
}

# ============================================================ scenario A
echo "=== scenario A: normal full session (collector x sidecar, fake wire)"
mkdir -p "$OUT/a/cache"
drill_env "$OUT/a"
seed_cache "$OUT/a/cache"
set +e
# The collector's arg parser (tools/collector/collector.nim argValue)
# accepts the --name=value form only.
"$COLLECTOR" --profile=drill-demo --session-date=2026-10-30 \
  --calendar="$CAL" --out="$OUT/a/session" \
  >"$OUT/a/collector.stdout" 2>"$OUT/a/collector.stderr"
CODE_A=$?
set -e
clear_drill_env

check_eq "A: collector exit code" 0 "$CODE_A"
check_contains "A: collector prints DONE" \
  "$(cat "$OUT/a/collector.stdout")" "COLLECTOR DONE records="
check_not_contains "A: collector stderr is empty of INCOMPLETE" \
  "$(cat "$OUT/a/collector.stderr")" "INCOMPLETE"
# A collector exit 0 IS the sidecar exit 0 evidence: the binary waits for
# the sidecar after stop and exits 4 on any non-zero sidecar exit
# (tools/collector/collector.nim: "the sidecar exited ... after stop").

INPUT_A="$OUT/a/session/input.hcj.jsonl"
MARKER_A="$INPUT_A.committed"
# The census prints its own ok/FAIL lines; its exit status is recorded as
# a named check so a structural mismatch never aborts scenarios B and C.
if record_census "$INPUT_A" "A:"; then
  ok "A: census exit (all structural asserts ok)"
else
  bad "A: census exit (structural asserts above)"
fi
[ -f "$MARKER_A" ] && ok "A: COMMITTED marker exists" \
  || bad "A: COMMITTED marker missing"
LINES_A=$(wc -l < "$INPUT_A" | tr -d ' ')
SEQ_A=$(env -u PYTHONPATH python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["seq"])' "$MARKER_A")
check_eq "A: marker seq == record count (seal included)" "$LINES_A" "$SEQ_A"
SHA_FILE=$(sha256sum "$INPUT_A" | cut -d' ' -f1)
SHA_MARKER=$(env -u PYTHONPATH python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$MARKER_A")
check_eq "A: marker sha256 == sealed log bytes" "$SHA_FILE" "$SHA_MARKER"

# Wire-log evidence (fake server view).
WIRE_A=$(cat "$OUT/a/wire.log")
check_contains "A: wire: client sent LOGIN" "$WIRE_A" '"ev": "ws_send", "trnm": "LOGIN"'
check_contains "A: wire: client sent REG" "$WIRE_A" '"ev": "ws_send", "trnm": "REG"'
check_contains "A: wire: client sent REMOVE" "$WIRE_A" '"ev": "ws_send", "trnm": "REMOVE"'
check_contains "A: wire: server PING probe delivered" "$WIRE_A" '"ev": "ws_deliver", "trnm": "PING"'
check_contains "A: wire: client echoed PING verbatim" "$WIRE_A" '"trnm": "PING", "echo": true'
check_contains "A: wire: rest up requested (sort_tp 1)" "$WIRE_A" '"direction": "up"'
check_contains "A: wire: rest down requested (sort_tp 3)" "$WIRE_A" '"direction": "down"'
check_contains "A: wire: client closed with code 1000" "$WIRE_A" '"ev": "ws_close", "code": 1000'
check_not_contains "A: wire log carries no token value" "$WIRE_A" "DRILL-FAKE-TOKEN"

# ============================================================ scenario C
echo "=== scenario C: replay + verify of scenario A (deterministic, no env)"
set +e
"$HS" replay --in "$INPUT_A" --out "$OUT/a-verify/session" \
  >"$OUT/a/replay.stdout" 2>"$OUT/a/replay.stderr"
CODE_C_REPLAY=$?
# The durable-completion evidence travels with the stream: stage the
# marker BYTE-EXACT (no rewriting) BEFORE verify reads the run dir —
# replay recomputes the run but never manufactures durability evidence,
# so the drill carries A's marker over. The run directory basename is
# the collector's out basename ("session") so the marker's run_id stays
# valid (recorder.readCommitMarker binds run_id to the parent basename).
cp "$MARKER_A" "$OUT/a-verify/session/input.hcj.jsonl.committed"
"$HS" verify --run "$OUT/a-verify/session" \
  >"$OUT/a/verify.stdout" 2>"$OUT/a/verify.stderr"
CODE_C_VERIFY=$?
set -e
check_eq "C: replay exit code (0 = REPLAY OK)" 0 "$CODE_C_REPLAY"
check_contains "C: replay output" "$(cat "$OUT/a/replay.stdout")" "REPLAY OK"
check_contains "C: replay run dir has the run name" "$(cat "$OUT/a/replay.stdout")" "bars="
cmp -s "$INPUT_A" "$OUT/a-verify/session/input.hcj.jsonl" \
  && ok "C: run dir input is byte-identical to the sealed log" \
  || bad "C: run dir input differs from the sealed log"
VERIFY_A_OUT="$(cat "$OUT/a/verify.stdout")"
VERIFY_A_ERR="$(cat "$OUT/a/verify.stderr")"
check_eq "C: verify exit code (7 = provenance INVALID, the dev-build ceiling)" \
  7 "$CODE_C_VERIFY"
check_contains "C: verify COMMIT=VALID" "$VERIFY_A_OUT" "COMMIT=VALID"
check_contains "C: verify SUBCHECK quarantined=0" "$VERIFY_A_OUT" "SUBCHECK quarantined=0"
check_contains "C: verify saw the teardown (remove_acks_0b=1)" "$VERIFY_A_OUT" "remove_acks_0b=1"
check_contains "C: verify close evidence (close_values=4)" "$VERIFY_A_OUT" "close_values=4"
check_contains "C: verify verdict is the dev-build provenance ceiling" \
  "$VERIFY_A_OUT" "VERDICT MISMATCH provenance=INVALID"
check_not_contains "C: verify is NOT INCOMPLETE" \
  "$VERIFY_A_OUT$VERIFY_A_ERR" "INCOMPLETE"
check_not_contains "C: no byte mismatch issues" "$VERIFY_A_ERR" "differs from replay"
check_not_contains "C: no commit issues" "$VERIFY_A_ERR" "commit marker"

# ============================================================ scenario B
echo "=== scenario B: SIGKILL the collector mid-session"
mkdir -p "$OUT/b/cache"
drill_env "$OUT/b"
seed_cache "$OUT/b/cache"
set +e
"$COLLECTOR" --profile=drill-demo --session-date=2026-10-30 \
  --calendar="$CAL" --out="$OUT/b/session" \
  >"$OUT/b/collector.stdout" 2>"$OUT/b/collector.stderr" &
CPID=$!
INPUT_B="$OUT/b/session/input.hcj.jsonl"
LINES_B=0
for _ in $(seq 1 150); do
  if [ -f "$INPUT_B" ]; then
    LINES_B=$(wc -l < "$INPUT_B" | tr -d ' ')
    if [ "$LINES_B" -ge 12 ]; then break; fi
  fi
  sleep 0.2
done
if [ -f "$INPUT_B" ]; then
  LASTBYTE=$(tail -c 1 "$INPUT_B" | od -An -c | tr -d ' \n')
else
  LASTBYTE="(no input file)"
fi
kill -9 "$CPID" 2>/dev/null || true
wait "$CPID" 2>/dev/null
CODE_B=$?
sleep 1  # the orphaned sidecar sees stdin EOF and exits by itself (exit 4)
clear_drill_env

ok "B: collector killed with SIGKILL at $LINES_B records (exit $CODE_B)"
check_eq "B: unsealed stream (no session_end record)" \
  "0" "$(grep -c '"kind":"session_end"' "$INPUT_B" || true)"
[ ! -f "$INPUT_B.committed" ] && ok "B: no COMMITTED marker (durability never claimed)" \
  || bad "B: a COMMITTED marker exists after SIGKILL"
echo "     B: last byte of the killed log = [$LASTBYTE] (0a = complete LF record)"

set +e
"$HS" replay --in "$INPUT_B" --out "$OUT/b-verify/session" \
  >"$OUT/b/replay.stdout" 2>"$OUT/b/replay.stderr"
CODE_B_REPLAY=$?
"$HS" verify --run "$OUT/b/session" \
  >"$OUT/b/verify.stdout" 2>"$OUT/b/verify.stderr"
CODE_B_VERIFY=$?
set -e
check_eq "B: verify exit code (4 = INCOMPLETE)" 4 "$CODE_B_VERIFY"
VERIFY_B_OUT="$(cat "$OUT/b/verify.stdout")"
check_contains "B: verify verdict INCOMPLETE" "$VERIFY_B_OUT" "VERDICT INCOMPLETE"
check_contains "B: verify COMMIT=ABSENT (durability unconfirmed)" \
  "$VERIFY_B_OUT" "COMMIT=ABSENT"
case "$CODE_B_REPLAY" in
  4)
    check_contains "B: replay INCOMPLETE (session_end missing)" \
      "$(cat "$OUT/b/replay.stderr")" "REPLAY INCOMPLETE: session_end missing" ;;
  2)
    check_contains "B: replay REJECT on the torn tail (fail-closed)" \
      "$(cat "$OUT/b/replay.stderr")" "REPLAY REJECT" ;;
  *)
    bad "B: replay exit code [$CODE_B_REPLAY] is neither 4 (INCOMPLETE) nor 2 (torn REJECT)" ;;
esac

# ------------------------------------------------------------- summary
echo "=== drill summary: $PASS passed, $FAIL failed (evidence: $OUT)"
if [ "$FAIL" -eq 0 ]; then
  echo "DRILL PAIR PASSED"
  exit 0
fi
echo "DRILL PAIR FAILED"
exit 1
