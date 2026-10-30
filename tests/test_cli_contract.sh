#!/usr/bin/env bash
## CLI-level contract tests for the hongscanner binary.
##
## Compiles the real CLI from src/ and exercises it end to end: selftest
## scratch-directory safety, doctor calendar validation, and the replay /
## verify exit-code contract (docs/REPLAY_CONTRACT.md §9).
##
## Everything runs inside one private mktemp(1) sandbox that the script
## creates and removes itself; no path outside the sandbox is ever removed
## or written. Calendars and fixtures are copies constructed in the sandbox,
## so the suite works on a fresh clone. `DOCTOR RESULT=OK` itself is not
## asserted here: it requires a canonical tools/build.sh build inside the
## repository (docs/GATES.md P7), which a test binary can never be.
##
## Run: bash tests/test_cli_contract.sh
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
    echo "FAIL $1: [$2] does not contain [$3]"; FAILED=$((FAILED + 1))
  fi
}

assert_file() { # desc path
  if [ -f "$2" ]; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: $2 is gone"; FAILED=$((FAILED + 1))
  fi
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hs-cli-test.XXXXXX")"
cleanup() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

BIN="$SANDBOX/hongscanner"
WORK="$SANDBOX/work"
FIXED_TMP="$SANDBOX/tmp/hongscanner-selftest" # legacy fixed selftest path
mkdir -p "$WORK/calendars" "$SANDBOX/tmp"

echo "compiling CLI from $REPO_ROOT/src"
(cd "$REPO_ROOT" && nim c --hints:off --warnings:off \
  --path:"$REPO_ROOT/src" --nimcache:"$SANDBOX/nimcache" \
  -o:"$BIN" src/hongscanner.nim) > "$SANDBOX/compile.log" 2>&1 || {
    echo "FAIL CLI does not compile:"; cat "$SANDBOX/compile.log"; exit 1; }
echo "ok   CLI compiles"; PASS=$((PASS + 1))

cp -r "$REPO_ROOT/fixtures" "$WORK/fixtures"

# Hermetic calendars: two small files, index generated in the sandbox with
# repo-relative paths, in the same "<sha256>  <name>" format as the
# committed calendars/CALENDAR_INDEX.sha256.
regen_index() {
  (cd "$WORK" && : > calendars/CALENDAR_INDEX.sha256 &&
    for f in calendars/*.json; do
      printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f" \
        >> calendars/CALENDAR_INDEX.sha256
    done)
}

write_calendars() {
  cat > "$WORK/calendars/krx-2026q4.json" <<'EOF'
{"days":{"2026-10-29":{"close":"15:30:00+09:00","open":"09:00:00+09:00"}},
 "version":"CAL-TEST"}
EOF
  cat > "$WORK/calendars/krx-2027.json" <<'EOF'
{"days":{"2027-01-04":{"close":"15:30:00+09:00","open":"09:00:00+09:00"}},
 "version":"CAL-TEST"}
EOF
  regen_index
}

selftest() { (cd "$WORK" && TMPDIR="$SANDBOX/tmp" "$BIN" selftest); }
doctor() { (cd "$WORK" && "$BIN" doctor); }

# ---------------------------------------------------------------- selftest
echo "--- selftest"
RC=0; OUT="$(selftest)" || RC=$?
assert_eq "selftest exits 0" 0 "$RC"
assert_contains "selftest reports bytes OK" "$OUT" "SELFTEST bytes=OK bars=22 signals=8"
assert_contains "selftest reports non-canonical provenance" "$OUT" "SELFTEST provenance=NOT_CANONICAL"
LEFT="$(find "$SANDBOX/tmp" -maxdepth 1 -name 'hongscanner-selftest-*' | wc -l)"
assert_eq "selftest cleans up its unique scratch dir" 0 "$LEFT"

# Regression guard: a pre-existing directory at the legacy fixed path must
# never be recursively deleted again (the old selftest removed it).
mkdir -p "$FIXED_TMP"
echo keepme > "$FIXED_TMP/canary.txt"
RC=0; OUT="$(selftest)" || RC=$?
assert_eq "selftest with fixed-path canary still exits 0" 0 "$RC"
assert_file "fixed-path canary survives selftest" "$FIXED_TMP/canary.txt"
rm -rf "$FIXED_TMP"

# Regression guard: a symlink planted at the legacy fixed path must not be
# followed into the target (the old selftest deleted files through it).
mkdir -p "$SANDBOX/victim"
echo precious > "$SANDBOX/victim/precious.txt"
ln -s "$SANDBOX/victim" "$FIXED_TMP"
RC=0; OUT="$(selftest)" || RC=$?
assert_eq "selftest with symlink at fixed path still exits 0" 0 "$RC"
assert_file "symlink target survives selftest" "$SANDBOX/victim/precious.txt"
rm -f "$FIXED_TMP"

# Concurrent runs each get a unique scratch dir and must not clobber.
selftest > "$SANDBOX/conc1.log" 2>&1 & P1=$!
selftest > "$SANDBOX/conc2.log" 2>&1 & P2=$!
wait "$P1"; R1=$?
wait "$P2"; R2=$?
assert_eq "concurrent selftest run 1 exits 0" 0 "$R1"
assert_eq "concurrent selftest run 2 exits 0" 0 "$R2"

# Corrupt fixture (only the calendar record survives): contract exit 2.
cp "$REPO_ROOT/fixtures/smoke/input.hcj.jsonl" "$SANDBOX/input.bak"
head -1 "$SANDBOX/input.bak" > "$WORK/fixtures/smoke/input.hcj.jsonl"
RC=0; ERR="$(selftest 2>&1 >/dev/null)" || RC=$?
assert_eq "selftest rejects a too-short fixture with exit 2" 2 "$RC"
assert_contains "selftest reports the rejection" "$ERR" "SELFTEST REJECT"

# Incomplete fixture (no session_end): contract exit 4.
cp "$REPO_ROOT/fixtures/smoke/incomplete_input.hcj.jsonl" \
   "$WORK/fixtures/smoke/input.hcj.jsonl"
RC=0; ERR="$(selftest 2>&1 >/dev/null)" || RC=$?
assert_eq "selftest on incomplete fixture exits 4" 4 "$RC"
cp "$SANDBOX/input.bak" "$WORK/fixtures/smoke/input.hcj.jsonl"

# ---------------------------------------------------------------- doctor
echo "--- doctor"
write_calendars
RC=0; OUT="$(doctor)" || RC=$?
assert_contains "doctor validates the calendar index" "$OUT" "CALENDAR_INDEX=OK files=2"
assert_contains "doctor without git degrades on build, not calendar" "$OUT" "DOCTOR RESULT=DEGRADED build"
assert_eq "doctor without git exits 7" 7 "$RC"

: > "$WORK/calendars/CALENDAR_INDEX.sha256"
RC=0; OUT="$(doctor)" || RC=$?
assert_contains "empty index is rejected" "$OUT" "CALENDAR_INDEX=EMPTY files=0"
assert_contains "empty index degrades the calendar" "$OUT" "DOCTOR RESULT=DEGRADED calendar"
assert_eq "empty index exits 3" 3 "$RC"

write_calendars
printf 'abc  calendars/x.json\r\n' > "$WORK/calendars/CALENDAR_INDEX.sha256"
RC=0; OUT="$(doctor 2>"$SANDBOX/doctor.err")" || RC=$?
assert_contains "CRLF index is rejected" "$OUT" "CALENDAR_INDEX=UNREADABLE"
assert_eq "CRLF index exits 3" 3 "$RC"
assert_eq "CRLF index produces no traceback" 0 "$(wc -l < "$SANDBOX/doctor.err")"

write_calendars
echo '{"days":{},"version":"CAL-TEST"}' > "$WORK/calendars/krx-2026q4.json"
regen_index
RC=0; OUT="$(doctor)" || RC=$?
assert_contains "calendar without days is rejected" "$OUT" \
  "CALENDAR calendars/krx-2026q4.json EMPTY: no days"
assert_eq "calendar without days exits 3" 3 "$RC"

write_calendars
echo '{"days":123,"version":"CAL-TEST"}' > "$WORK/calendars/krx-2026q4.json"
regen_index
RC=0; OUT="$(doctor)" || RC=$?
assert_contains "calendar with non-object days is rejected" "$OUT" \
  "CALENDAR calendars/krx-2026q4.json UNREADABLE"
assert_eq "calendar with non-object days exits 3" 3 "$RC"

write_calendars
sed -i 's/^./0/' "$WORK/calendars/CALENDAR_INDEX.sha256"
RC=0; OUT="$(doctor)" || RC=$?
assert_contains "index hash mismatch is rejected" "$OUT" "CALENDAR_INDEX=MISMATCH"
assert_eq "index hash mismatch exits 3" 3 "$RC"

write_calendars
rm "$WORK/calendars/CALENDAR_INDEX.sha256"
RC=0; OUT="$(doctor)" || RC=$?
assert_contains "missing index is rejected" "$OUT" "CALENDAR_INDEX=MISSING"
assert_eq "missing index exits 3" 3 "$RC"
write_calendars

# ---------------------------------------------------------------- replay/verify
echo "--- replay/verify"
mkdir -p "$WORK/runs"
RC=0; OUT="$(cd "$WORK" && "$BIN" replay --in fixtures/smoke/input.hcj.jsonl --out runs/base)" || RC=$?
assert_eq "replay of the smoke fixture exits 0" 0 "$RC"
assert_contains "replay reports the tuned counts" "$OUT" "REPLAY OK bars=22 signals=8"

BEFORE="$(sha256sum "$WORK/runs/base/input.hcj.jsonl")"
RC=0; ERR="$(cd "$WORK" && "$BIN" replay --in runs/base/input.hcj.jsonl --out runs/base 2>&1)" || RC=$?
assert_eq "replay refuses to overwrite an existing run" 2 "$RC"
assert_eq "refused replay preserves its input" "$BEFORE" "$(sha256sum "$WORK/runs/base/input.hcj.jsonl")"
assert_contains "refused replay reports the output error" "$ERR" "REFUSED"

RC=0; OUT="$(cd "$WORK" && "$BIN" verify --run runs/base 2>/dev/null)" || RC=$?
assert_eq "verify of a test-binary run exits 7 (dev provenance)" 7 "$RC"
assert_contains "verify prints a verdict" "$OUT" "VERDICT"

printf 'tamper\n' >> "$WORK/runs/base/bars.hcj.jsonl"
RC=0; OUT="$(cd "$WORK" && "$BIN" verify --run runs/base 2>/dev/null)" || RC=$?
assert_eq "verify of tampered artifacts exits 6" 6 "$RC"

RC="$(cd "$WORK" && "$BIN" replay --in fixtures/smoke/incomplete_input.hcj.jsonl --out runs/inc >/dev/null 2>&1; echo $?)"
assert_eq "replay without session_end exits 4" 4 "$RC"

RC="$(cd "$WORK" && "$BIN" replay --in fixtures/smoke/late_tick_input.hcj.jsonl --out runs/late >/dev/null 2>&1; echo $?)"
assert_eq "replay with a late tick exits 5" 5 "$RC"

python3 - "$WORK/fixtures/smoke/input.hcj.jsonl" "$WORK/unresolved.hcj.jsonl" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    records = [json.loads(line) for line in f]
records.insert(-1, {"kind": "gap", "raw": {"symbol": "005930"}})
with open(sys.argv[2], "w", encoding="utf-8") as f:
    for seq, record in enumerate(records, 1):
        record["seq"] = seq
        f.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY
RC=0; ERR="$(cd "$WORK" && "$BIN" replay --in unresolved.hcj.jsonl --out runs/unresolved 2>&1)" || RC=$?
assert_eq "unresolved gap exits incomplete" 4 "$RC"
assert_contains "unresolved gap reports incomplete" "$ERR" "REPLAY INCOMPLETE: UNRESOLVED_GAP"
assert_absent="$(test ! -e "$WORK/runs/unresolved" && printf yes || printf no)"
assert_eq "unresolved gap produces no run" yes "$assert_absent"

RC="$("$BIN" replay >/dev/null 2>&1; echo $?)"
assert_eq "replay without flags exits 2" 2 "$RC"

RC="$("$BIN" frobnicate >/dev/null 2>&1; echo $?)"
assert_eq "unknown command exits 2" 2 "$RC"

# ------------------------------------------- environment + commit marker
echo "--- environment + commit marker"

# The durable-recorder verify rules: a stream whose config declares
# environment requires a COMMITTED marker next to input.hcj.jsonl —
# sealed + VALID marker = completable, marker ABSENT = INCOMPLETE (exit
# 4), marker not matching the log = REJECT (exit 2). The marker here is
# hand-built the way any external verifier would: from the log's own
# bytes. Synthetic streams (no environment) keep their behavior
# unchanged and only get the marker reported.

python3 - "$REPO_ROOT/fixtures/smoke/input.hcj.jsonl" "$WORK/envstream.hcj.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    records = [json.loads(line) for line in f]
records[1]["raw"]["environment"] = "demo"
with open(sys.argv[2], "w", encoding="utf-8") as f:
    for seq, record in enumerate(records, 1):
        record["seq"] = seq
        f.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY

python3 - "$REPO_ROOT/fixtures/smoke/input.hcj.jsonl" "$WORK/envbad.hcj.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    records = [json.loads(line) for line in f]
records[1]["raw"]["environment"] = "staging"
with open(sys.argv[2], "w", encoding="utf-8") as f:
    for seq, record in enumerate(records, 1):
        record["seq"] = seq
        f.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY

# The environment field is validated at replay: only "demo"/"prod".
RC=0; (cd "$WORK" && "$BIN" replay --in envstream.hcj.jsonl --out runs/envbase >/dev/null 2>&1) || RC=$?
assert_eq "replay accepts an environment-declaring stream" 0 "$RC"
RC=0; ERR="$(cd "$WORK" && "$BIN" replay --in envbad.hcj.jsonl --out runs/envbad 2>&1)" || RC=$?
assert_eq "replay rejects an invalid environment with exit 2" 2 "$RC"
assert_contains "the rejection names config.environment" "$ERR" "config.environment is not demo|prod"

write_marker() { # $1 = run dir whose input artifact the marker pins
  python3 - "$1" <<'PY'
import hashlib, json, os, sys
run = sys.argv[1]
inp = os.path.join(run, "input.hcj.jsonl")
n = sum(1 for _ in open(inp, encoding="utf-8"))
sha = hashlib.sha256(open(inp, "rb").read()).hexdigest()
marker = {"run_id": os.path.basename(run),
          "schema": "hong-scanner-commit/1", "seq": n, "sha256": sha,
          "t": "2026-10-29T15:30:00+09:00"}
with open(inp + ".committed", "w", encoding="utf-8") as f:
    f.write(json.dumps(marker, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

RC=0; OUT="$(cd "$WORK" && "$BIN" verify --run runs/envbase 2>"$SANDBOX/env.err")" || RC=$?
assert_eq "environment without a marker verifies INCOMPLETE exit 4" 4 "$RC"
assert_contains "the ABSENT marker is reported" "$OUT" "COMMIT=ABSENT"
assert_contains "the ABSENT issue explains durability" "$(cat "$SANDBOX/env.err")" "commit marker absent"

write_marker "$WORK/runs/envbase"
RC=0; OUT="$(cd "$WORK" && "$BIN" verify --run runs/envbase 2>/dev/null)" || RC=$?
assert_eq "environment + VALID marker keeps the success path (7 dev provenance)" 7 "$RC"
assert_contains "the VALID marker is reported" "$OUT" "COMMIT=VALID"

python3 - "$WORK/runs/envbase/input.hcj.jsonl.committed" <<'PY'
import json, sys
p = sys.argv[1]
m = json.load(open(p, encoding="utf-8"))
m["sha256"] = "0" * 64
with open(p, "w", encoding="utf-8") as f:
    f.write(json.dumps(m, sort_keys=True, separators=(",", ":")) + "\n")
PY
RC=0; OUT="$(cd "$WORK" && "$BIN" verify --run runs/envbase 2>"$SANDBOX/inv.err")" || RC=$?
assert_eq "environment + mismatching marker verifies REJECT exit 2" 2 "$RC"
assert_contains "the INVALID marker is reported" "$OUT" "COMMIT=INVALID"
assert_contains "the INVALID issue explains the mismatch" "$(cat "$SANDBOX/inv.err")" "commit marker INVALID"

python3 - "$WORK/runs/envbase/input.hcj.jsonl.committed" <<'PY'
import json, sys
p = sys.argv[1]
m = json.load(open(p, encoding="utf-8"))
m["seq"] = 3
with open(p, "w", encoding="utf-8") as f:
    f.write(json.dumps(m, sort_keys=True, separators=(",", ":")) + "\n")
PY
RC="$(cd "$WORK" && "$BIN" verify --run runs/envbase >/dev/null 2>&1; echo $?)"
assert_eq "a marker seq mismatch is also REJECT exit 2" 2 "$RC"

# Torn tail on an environment stream: crashed run, INCOMPLETE (never an
# approval, never the synthetic line-discipline REJECT).
RC=0; (cd "$WORK" && "$BIN" replay --in envstream.hcj.jsonl --out runs/envtorn >/dev/null 2>&1) || RC=$?
assert_eq "the torn-tail run replays cleanly first" 0 "$RC"
printf '{' >> "$WORK/runs/envtorn/input.hcj.jsonl"
RC=0; ERR="$(cd "$WORK" && "$BIN" verify --run runs/envtorn 2>&1 >/dev/null)" || RC=$?
assert_eq "a torn tail on an environment stream is INCOMPLETE exit 4" 4 "$RC"
assert_contains "the torn tail is named as a crashed run" "$ERR" "torn tail"

# Synthetic stream: behavior unchanged, marker only reported.
RC=0; (cd "$WORK" && "$BIN" replay --in fixtures/smoke/input.hcj.jsonl --out runs/plain >/dev/null 2>&1) || RC=$?
assert_eq "the synthetic stream replays as before" 0 "$RC"
RC=0; OUT="$(cd "$WORK" && "$BIN" verify --run runs/plain 2>/dev/null)" || RC=$?
assert_eq "a synthetic stream verifies as before (7 dev provenance)" 7 "$RC"
assert_contains "its absent marker is only reported" "$OUT" "COMMIT=ABSENT"

# ---------------------------------------------------------------- summary
echo ""
echo "$PASS passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
