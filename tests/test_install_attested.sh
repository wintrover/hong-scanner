#!/usr/bin/env bash
## Control-flow tests for tools/install-attested.sh (GATES.md P13 path).
##
## A mock `gh` is prepended to PATH for these tests. The mock only records the
## arguments it was called with (and can be told to fail, or to mutate the
## artifact mid-"verify" to drive the TOCTOU branch); it does not, and must
## not, verify anything. These tests therefore cover the installer's LOCAL
## control flow only: argument/digest validation, the exact pinned flags
## handed to gh (including bare-hex digest normalization), fail-closed
## behaviour on verify failure, binary change during verification (TOCTOU),
## pre-existing version directories, a `current` that is not a symlink,
## concurrent installs, atomic `current` switching, never deleting or
## overwriting existing versions, recording the verified binary's actual
## sha256, hardening against a hostile environment (a caller's umask 000,
## group/other-writable or symlinked install roots, symlink traps planted
## into the freshly created version directory, and tampering with the
## finalized binary before the `current` switch).
##
## The symlink-trap and pre-switch tampering cases replay the reproduced
## attack shapes against a synthetic attacker: a background poller that
## waits for the installer to create its version directory (or its SHA256
## file) and then plants symlinks or appends bytes, using a large dummy
## "binary" so the copy/hash window is wide enough to land in reliably.
##
## Real GitHub attestation verification (`gh attestation verify` against
## wintrover/hong-scanner with signer workflow .github/workflows/attest.yml,
## ref refs/heads/main, the exact source digest of main, GitHub-hosted
## runners only) is NOT performed here: it requires the real gh, the real
## attest.yml workflow and a real attested binary, and is executed by the
## maintainer (parent agent) after merge. Nothing here substitutes for it.
## No service, timer or scheduler is installed or tested either.
##
## Run: bash tests/test_install_attested.sh
set -euo pipefail
umask 022 # deterministic fixture modes; the runner's umask (e.g. 002) must
          # not make test-created roots group-writable, which the installer
          # legitimately refuses

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$REPO_ROOT/tools/install-attested.sh"
DIGEST="0e8fa88f12e3f2efc250fee043c69dc4867f171a"
DIGEST64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

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

assert_not_contains() { # desc haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then
    echo "FAIL $1: [$2] unexpectedly contains [$3]"; FAILED=$((FAILED + 1))
  else
    echo "ok   $1"; PASS=$((PASS + 1))
  fi
}

assert_file() { # desc path
  if [ -e "$2" ]; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: $2 is gone"; FAILED=$((FAILED + 1))
  fi
}

assert_absent() { # desc path
  if [ ! -e "$2" ] && [ ! -L "$2" ]; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: $2 unexpectedly exists"; FAILED=$((FAILED + 1))
  fi
}

mode_of() { # path -> octal mode like 755
  stat -c '%a' -- "$1"
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hs-install-test.XXXXXX")"
cleanup() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

MOCKBIN="$SANDBOX/bin"
GHLOG="$SANDBOX/gh.log"
mkdir -p "$MOCKBIN" "$SANDBOX/tmp"
export TMPDIR="$SANDBOX/tmp" # makes the "no temp files leak into TMPDIR"
                            # assertion below watch the installer's real TMPDIR
export HS_MOCK_GH_LOG="$GHLOG"

# Mock gh: logs argv, optionally fails or mutates the artifact. It is a
# control-flow stub for these tests only; it performs no verification.
cat > "$MOCKBIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HS_MOCK_GH_LOG:?}"
if [ "${HS_MOCK_GH_FAIL:-0}" = "1" ]; then
  echo "mock gh: refusing artifact" >&2
  exit 1
fi
if [ "${HS_MOCK_GH_MUTATE:-0}" = "1" ] && [ -n "${HS_MOCK_GH_ARTIFACT:-}" ]; then
  printf 'X' >> "$HS_MOCK_GH_ARTIFACT"
fi
exit 0
EOF
chmod 0755 "$MOCKBIN/gh"
: > "$GHLOG"

make_binary() { # label path -- deterministic fake "binary"
  printf '#!/bin/sh\necho hs-test-binary %s\n' "$1" > "$2"
  chmod 0755 "$2"
}

hash_of() { # path -> sha256 hex
  local line
  line="$(sha256sum -- "$1")"
  printf '%s' "${line%% *}"
}

run_install() { # binary version digest root
  PATH="$MOCKBIN:$PATH" "$INSTALLER" "$1" "$2" "$3" "$4"
}

# Synthetic attacker: waits for the installer to create the fresh version
# directory, then plants the same symlink traps the reproduced attack used.
plant_symlink_traps() { # vdir sha_target prov_target ("" plants nothing)
  local vdir="$1" i
  for ((i = 0; i < 3000; i++)); do
    if [ -d "$vdir" ]; then break; fi
    sleep 0.001
  done
  if [ ! -d "$vdir" ]; then return 0; fi
  if [ -n "$2" ]; then ln -s -- "$2" "$vdir/SHA256" 2>/dev/null || true; fi
  if [ -n "$3" ]; then ln -s -- "$3" "$vdir/PROVENANCE.txt" 2>/dev/null || true; fi
}

# Synthetic attacker: waits for SHA256 to be written, then appends to the
# finalized binary before the installer can re-hash it and switch `current`.
tamper_final_binary() { # vdir
  local vdir="$1" i
  for ((i = 0; i < 3000; i++)); do
    if [ -f "$vdir/SHA256" ] && [ ! -L "$vdir/SHA256" ]; then break; fi
    sleep 0.001
  done
  if [ -f "$vdir/hongscanner" ] && [ ! -L "$vdir/hongscanner" ]; then
    printf 'X' >> "$vdir/hongscanner" 2>/dev/null || true
  fi
}

DUMMY="$SANDBOX/dummy.bin"
make_binary dummy "$DUMMY"

# ---------------------------------------------------------------- files
echo "--- files are executable"
if [ -x "$INSTALLER" ]; then
  echo "ok   installer is executable"; PASS=$((PASS + 1))
else
  echo "FAIL installer is not executable: chmod +x tools/install-attested.sh"; FAILED=$((FAILED + 1))
fi
if [ -x "$REPO_ROOT/tests/test_install_attested.sh" ]; then
  echo "ok   test script is executable"; PASS=$((PASS + 1))
else
  echo "FAIL test script is not executable"; FAILED=$((FAILED + 1))
fi

# ---------------------------------------------------------------- usage
echo "--- usage and argument validation"
RC=0; OUT="$("$INSTALLER" 2>&1)" || RC=$?
assert_eq "no args exits 2" 2 "$RC"
assert_contains "no args prints usage" "$OUT" "usage: tools/install-attested.sh"
RC=0; OUT="$("$INSTALLER" a b c 2>&1)" || RC=$?
assert_eq "3 args exits 2" 2 "$RC"
RC=0; OUT="$("$INSTALLER" a b c d e 2>&1)" || RC=$?
assert_eq "5 args exits 2" 2 "$RC"

for bad_version in "a/b" ".." "-x" "with space" ""; do
  ROOT="$SANDBOX/root-bad-version"
  RC=0; "$INSTALLER" "$DUMMY" "$bad_version" "$DIGEST" "$ROOT" >/dev/null 2>&1 || RC=$?
  assert_eq "invalid version [$bad_version] exits 2" 2 "$RC"
  assert_absent "invalid version [$bad_version] touches nothing" "$ROOT"
done

for bad_digest in "" "not-a-digest" "zz" \
  "0e8fa88f12e3f2efc250fee043c69dc4867f171" \
  "0e8fa88f12e3f2efc250fee043c69dc4867f171aa" "sha256:zz"; do
  ROOT="$SANDBOX/root-bad-digest"
  RC=0; "$INSTALLER" "$DUMMY" 1.0.0 "$bad_digest" "$ROOT" >/dev/null 2>&1 || RC=$?
  assert_eq "invalid digest [$bad_digest] exits 2" 2 "$RC"
  assert_absent "invalid digest [$bad_digest] touches nothing" "$ROOT"
done

ROOT="$SANDBOX/root-no-binary"
RC=0; OUT="$("$INSTALLER" "$SANDBOX/no-such-file" 1.0.0 "$DIGEST" "$ROOT" 2>&1)" || RC=$?
assert_eq "missing binary exits 2" 2 "$RC"
assert_absent "missing binary touches nothing" "$ROOT"

# ---------------------------------------------------------------- gh required
echo "--- gh is required and delegated to"
NOGH="$SANDBOX/nogh"
mkdir -p "$NOGH"
for tool in bash sha256sum mktemp cp mv ln mkdir chmod rm date stat cat; do
  p="$(command -v "$tool" || true)"
  [ -n "$p" ] && ln -s "$p" "$NOGH/$tool"
done
ROOT="$SANDBOX/root-no-gh"
RC=0; OUT="$(PATH="$NOGH" "$INSTALLER" "$DUMMY" 1.0.0 "$DIGEST" "$ROOT" 2>&1)" || RC=$?
assert_eq "missing gh exits 3" 3 "$RC"
assert_contains "missing gh explains delegation" "$OUT" "delegated to gh"
assert_absent "missing gh touches nothing" "$ROOT"

# ---------------------------------------------------------------- happy path
echo "--- successful install"
ROOT="$SANDBOX/root-ok"
B1="$SANDBOX/bin-v1"; make_binary v1 "$B1"
H1="$(hash_of "$B1")"
RC=0; OUT="$(run_install "$B1" 1.0.0 "$DIGEST" "$ROOT" 2>&1)" || RC=$?
assert_eq "successful install exits 0" 0 "$RC"
assert_contains "reports the pinned verification" "$OUT" "INSTALL VERIFY OK"
assert_contains "verify line pins the repo" "$OUT" "repo=wintrover/hong-scanner"
assert_contains "verify line pins the signer workflow" "$OUT" \
  "signer=wintrover/hong-scanner/.github/workflows/attest.yml"
assert_contains "verify line pins the ref" "$OUT" "ref=refs/heads/main"
assert_contains "verify line pins the source digest" "$OUT" "source_digest=$DIGEST"
assert_contains "reports INSTALL OK with the version" "$OUT" "INSTALL OK version=1.0.0"
assert_contains "records the verified binary's actual sha256" "$OUT" "sha256=$H1"

LASTCALL="$(tail -n 1 "$GHLOG")"
assert_contains "gh is called as attestation verify" "$LASTCALL" "attestation verify"
assert_contains "gh verifies the artifact file itself" "$LASTCALL" "$B1"
assert_contains "gh is pinned to the repo" "$LASTCALL" "--repo wintrover/hong-scanner"
assert_contains "gh is pinned to the signer workflow" "$LASTCALL" \
  "--signer-workflow wintrover/hong-scanner/.github/workflows/attest.yml"
assert_contains "gh is pinned to refs/heads/main" "$LASTCALL" "--source-ref refs/heads/main"
assert_contains "gh is pinned to the exact source digest" "$LASTCALL" "--source-digest $DIGEST"
assert_contains "gh rejects self-hosted runners" "$LASTCALL" "--deny-self-hosted-runners"

VDIR="$ROOT/versions/1.0.0"
assert_file "version dir keeps the binary" "$VDIR/hongscanner"
assert_file "version dir records SHA256" "$VDIR/SHA256"
assert_file "version dir records PROVENANCE" "$VDIR/PROVENANCE.txt"
if [ -x "$VDIR/hongscanner" ]; then
  echo "ok   installed binary is executable"; PASS=$((PASS + 1))
else
  echo "FAIL installed binary is not executable"; FAILED=$((FAILED + 1))
fi
assert_eq "SHA256 records the verified digest" "$H1" "$(cut -d' ' -f1 "$VDIR/SHA256")"
RC=0; (cd "$VDIR" && sha256sum -c SHA256 >/dev/null 2>&1) || RC=$?
assert_eq "SHA256 passes sha256sum -c" 0 "$RC"
assert_eq "installed bytes equal the verified bytes" "$H1" "$(hash_of "$VDIR/hongscanner")"
assert_eq "version dir is not group/other-writable" 755 "$(mode_of "$VDIR")"
assert_eq "SHA256 is not group/other-writable" 644 "$(mode_of "$VDIR/SHA256")"
assert_eq "PROVENANCE is not group/other-writable" 644 "$(mode_of "$VDIR/PROVENANCE.txt")"
assert_eq "installed binary is 0755" 755 "$(mode_of "$VDIR/hongscanner")"

PROV="$(cat "$VDIR/PROVENANCE.txt")"
assert_contains "provenance pins the repo" "$PROV" "repo=wintrover/hong-scanner"
assert_contains "provenance pins the signer workflow" "$PROV" \
  "signer_workflow=wintrover/hong-scanner/.github/workflows/attest.yml"
assert_contains "provenance pins the source ref" "$PROV" "source_ref=refs/heads/main"
assert_contains "provenance pins the exact source digest" "$PROV" "source_digest=$DIGEST"
assert_contains "provenance restricts to GitHub-hosted runners" "$PROV" "github-hosted-only"
assert_contains "provenance states delegation" "$PROV" "delegated"
assert_contains "provenance records the sha256" "$PROV" "sha256=$H1"

assert_eq "current is a relative symlink to the version" "versions/1.0.0" \
  "$(readlink "$ROOT/current")"
RC=0; OUT="$("$ROOT/current/hongscanner")" || RC=$?
assert_eq "current/hongscanner runs" 0 "$RC"
assert_contains "current serves the verified content" "$OUT" "hs-test-binary v1"
assert_eq "install root holds only versions and current (no service/scheduler/temp files)" \
  "current
versions" "$(LC_ALL=C ls -A "$ROOT")"
assert_eq "version dir holds exactly the three install files" \
  "PROVENANCE.txt
SHA256
hongscanner" "$(LC_ALL=C ls -A "$VDIR")"

# ---------------------------------------------------------------- verify failure
echo "--- attestation verify failure is fail-closed"
ROOT="$SANDBOX/root-verify-fail"
RC=0; OUT="$(PATH="$MOCKBIN:$PATH" HS_MOCK_GH_FAIL=1 \
  "$INSTALLER" "$B1" 1.0.0 "$DIGEST" "$ROOT" 2>&1)" || RC=$?
assert_eq "verify failure exits 4" 4 "$RC"
assert_contains "verify failure is reported" "$OUT" "gh attestation verify failed"
assert_absent "verify failure installs nothing" "$ROOT"

# ---------------------------------------------------------------- TOCTOU
echo "--- binary change around verification (TOCTOU)"
ROOT="$SANDBOX/root-toctou"
B3="$SANDBOX/bin-toctou"; make_binary toctou "$B3"
RC=0; OUT="$(PATH="$MOCKBIN:$PATH" HS_MOCK_GH_MUTATE=1 HS_MOCK_GH_ARTIFACT="$B3" \
  "$INSTALLER" "$B3" 1.0.0 "$DIGEST" "$ROOT" 2>&1)" || RC=$?
assert_eq "binary mutated during verify exits 5" 5 "$RC"
assert_contains "TOCTOU refusal explains the change" "$OUT" "changed during verification"
assert_absent "TOCTOU refusal installs nothing" "$ROOT"

# ---------------------------------------------------------------- conflicts
echo "--- existing versions are never overwritten"
ROOT="$SANDBOX/root-existing"
mkdir -p "$ROOT/versions/0.9.0"
echo canary > "$ROOT/versions/0.9.0/keep.txt"
RC=0; OUT="$(run_install "$B1" 0.9.0 "$DIGEST" "$ROOT" 2>&1)" || RC=$?
assert_eq "existing version dir exits 6" 6 "$RC"
assert_contains "existing version refusal is reported" "$OUT" "already exists"
assert_file "existing version dir is not deleted" "$ROOT/versions/0.9.0/keep.txt"
assert_absent "no binary written into the existing version" "$ROOT/versions/0.9.0/hongscanner"
assert_absent "current is not created on version conflict" "$ROOT/current"

echo "--- upgrade switches current atomically, old versions survive"
ROOT="$SANDBOX/root-upgrade"
RC=0; run_install "$B1" 1.0.0 "$DIGEST" "$ROOT" >/dev/null 2>&1 || RC=$?
assert_eq "first version installs" 0 "$RC"
B2="$SANDBOX/bin-v2"; make_binary v2 "$B2"
H2="$(hash_of "$B2")"
RC=0; OUT="$(run_install "$B2" 2.0.0 "$DIGEST" "$ROOT" 2>&1)" || RC=$?
assert_eq "second version installs" 0 "$RC"
assert_contains "upgrade reports the new version" "$OUT" "INSTALL OK version=2.0.0"
assert_eq "current now points at the new version" "versions/2.0.0" \
  "$(readlink "$ROOT/current")"
assert_eq "old version binary is untouched" "$H1" "$(hash_of "$ROOT/versions/1.0.0/hongscanner")"
assert_file "old version records survive" "$ROOT/versions/1.0.0/SHA256"
RC=0; OUT="$("$ROOT/current/hongscanner")" || RC=$?
assert_contains "current serves the new version" "$OUT" "hs-test-binary v2"

RC=0; OUT="$(run_install "$B1" 2.0.0 "$DIGEST" "$ROOT" 2>&1)" || RC=$?
assert_eq "re-installing an existing version exits 6" 6 "$RC"
assert_eq "refused re-install does not overwrite" "$H2" \
  "$(hash_of "$ROOT/versions/2.0.0/hongscanner")"
assert_eq "current is unchanged by the refusal" "versions/2.0.0" \
  "$(readlink "$ROOT/current")"

echo "--- a current that is not a symlink is never clobbered"
ROOT="$SANDBOX/root-current-dir"
mkdir -p "$ROOT/current"
echo precious > "$ROOT/current/keep.txt"
RC=0; OUT="$(run_install "$B1" 3.0.0 "$DIGEST" "$ROOT" 2>&1)" || RC=$?
assert_eq "non-symlink current exits 6" 6 "$RC"
assert_contains "non-symlink current refusal is reported" "$OUT" "not a symlink"
if [ -d "$ROOT/current" ] && [ ! -L "$ROOT/current" ]; then
  echo "ok   current stays a real directory"; PASS=$((PASS + 1))
else
  echo "FAIL current was replaced or turned into a symlink"; FAILED=$((FAILED + 1))
fi
assert_file "the directory's contents survive" "$ROOT/current/keep.txt"
assert_file "failed switch leaves the installed version (never deleted)" \
  "$ROOT/versions/3.0.0/hongscanner"
assert_eq "failed switch leaves no temp symlink behind" "current
versions" "$(LC_ALL=C ls -A "$ROOT")"

# ---------------------------------------------------------------- concurrency
echo "--- concurrent installs of different versions"
ROOT="$SANDBOX/root-conc-diff"
BA="$SANDBOX/bin-ca"; make_binary ca "$BA"
BB="$SANDBOX/bin-cb"; make_binary cb "$BB"
PATH="$MOCKBIN:$PATH" "$INSTALLER" "$BA" 9.0.0 "$DIGEST" "$ROOT" \
  > "$SANDBOX/conc-a.log" 2>&1 & PA=$!
PATH="$MOCKBIN:$PATH" "$INSTALLER" "$BB" 9.0.1 "$DIGEST" "$ROOT" \
  > "$SANDBOX/conc-b.log" 2>&1 & PB=$!
RA=0; wait "$PA" || RA=$?
RB=0; wait "$PB" || RB=$?
assert_eq "concurrent install A exits 0" 0 "$RA"
assert_eq "concurrent install B exits 0" 0 "$RB"
assert_eq "both version dirs exist" 2 "$(ls -A "$ROOT/versions" | wc -l)"
RC=0; (cd "$ROOT/versions/9.0.0" && sha256sum -c SHA256 >/dev/null 2>&1) || RC=$?
assert_eq "concurrent version 9.0.0 is complete and verified-consistent" 0 "$RC"
RC=0; (cd "$ROOT/versions/9.0.1" && sha256sum -c SHA256 >/dev/null 2>&1) || RC=$?
assert_eq "concurrent version 9.0.1 is complete and verified-consistent" 0 "$RC"
target="$(readlink "$ROOT/current")"
if [ "$target" = "versions/9.0.0" ] || [ "$target" = "versions/9.0.1" ]; then
  echo "ok   current points at one complete version"; PASS=$((PASS + 1))
else
  echo "FAIL current points at [$target]"; FAILED=$((FAILED + 1))
fi
assert_eq "concurrency leaves no temp artifacts in the root" "current
versions" "$(LC_ALL=C ls -A "$ROOT")"

echo "--- concurrent installs of the same version"
ROOT="$SANDBOX/root-conc-same"
BC1="$SANDBOX/bin-csame1"; make_binary csame "$BC1"
BC2="$SANDBOX/bin-csame2"; make_binary csame "$BC2"
H8="$(hash_of "$BC1")"
PATH="$MOCKBIN:$PATH" "$INSTALLER" "$BC1" 8.0.0 "$DIGEST" "$ROOT" \
  > "$SANDBOX/conc-s1.log" 2>&1 & PS1=$!
PATH="$MOCKBIN:$PATH" "$INSTALLER" "$BC2" 8.0.0 "$DIGEST" "$ROOT" \
  > "$SANDBOX/conc-s2.log" 2>&1 & PS2=$!
RS1=0; wait "$PS1" || RS1=$?
RS2=0; wait "$PS2" || RS2=$?
assert_eq "same-version race: exactly one winner" 1 "$(( (RS1 == 0) + (RS2 == 0) ))"
assert_eq "same-version race: exactly one loser exits 6" 1 "$(( (RS1 == 6) + (RS2 == 6) ))"
assert_eq "winner installed the verified bytes" "$H8" \
  "$(hash_of "$ROOT/versions/8.0.0/hongscanner")"
RC=0; (cd "$ROOT/versions/8.0.0" && sha256sum -c SHA256 >/dev/null 2>&1) || RC=$?
assert_eq "same-version race leaves a consistent version dir" 0 "$RC"
assert_eq "same-version race selects the version" "versions/8.0.0" \
  "$(readlink "$ROOT/current")"

# ---------------------------------------------------------------- digest form
echo "--- uppercase source digest is normalized"
ROOT="$SANDBOX/root-upper"
UPPER="$(printf '%s' "$DIGEST" | tr '[:lower:]' '[:upper:]')"
RC=0; OUT="$(run_install "$B1" 7.0.0 "$UPPER" "$ROOT" 2>&1)" || RC=$?
assert_eq "uppercase digest still installs" 0 "$RC"
LASTCALL="$(tail -n 1 "$GHLOG")"
assert_contains "gh receives the normalized lowercase digest" "$LASTCALL" \
  "--source-digest $DIGEST"

echo "--- sha1:/sha256:-prefixed digests reach gh as bare hex"
ROOT="$SANDBOX/root-prefix"
RC=0; OUT="$(run_install "$B1" 6.0.0 "sha1:$DIGEST" "$ROOT" 2>&1)" || RC=$?
assert_eq "sha1:-prefixed digest still installs" 0 "$RC"
LASTCALL="$(tail -n 1 "$GHLOG")"
assert_contains "gh receives the bare hex for a sha1:-prefixed digest" "$LASTCALL" \
  "--source-digest $DIGEST"
assert_contains "provenance records the bare digest" \
  "$(cat "$ROOT/versions/6.0.0/PROVENANCE.txt")" "source_digest=$DIGEST"

ROOT="$SANDBOX/root-prefix64"
RC=0; OUT="$(run_install "$B1" 6.0.1 "sha256:$DIGEST64" "$ROOT" 2>&1)" || RC=$?
assert_eq "sha256:-prefixed 64-hex digest still installs" 0 "$RC"
LASTCALL="$(tail -n 1 "$GHLOG")"
assert_contains "gh receives the bare 64-hex digest" "$LASTCALL" \
  "--source-digest $DIGEST64"

ROOT="$SANDBOX/root-prefix-upper"
UPPER64="$(printf '%s' "$DIGEST64" | tr '[:lower:]' '[:upper:]')"
RC=0; OUT="$(run_install "$B1" 6.0.2 "SHA256:$UPPER64" "$ROOT" 2>&1)" || RC=$?
assert_eq "uppercase sha256:-prefixed digest still installs" 0 "$RC"
LASTCALL="$(tail -n 1 "$GHLOG")"
assert_contains "gh receives the normalized bare digest" "$LASTCALL" \
  "--source-digest $DIGEST64"

# ---------------------------------------------------------------- umask hardening
echo "--- a caller's umask 000 must not leave a writable install tree"
ROOT="$SANDBOX/root-umask-zero"
RC=0; OUT="$( (umask 000 && run_install "$B1" 5.0.0 "$DIGEST" "$ROOT") 2>&1 )" || RC=$?
assert_eq "umask 000 install still exits 0" 0 "$RC"
assert_eq "umask 000: install root is 0755" 755 "$(mode_of "$ROOT")"
assert_eq "umask 000: versions is 0755" 755 "$(mode_of "$ROOT/versions")"
assert_eq "umask 000: version dir is 0755" 755 "$(mode_of "$ROOT/versions/5.0.0")"
assert_eq "umask 000: SHA256 is 0644" 644 "$(mode_of "$ROOT/versions/5.0.0/SHA256")"
assert_eq "umask 000: PROVENANCE is 0644" 644 \
  "$(mode_of "$ROOT/versions/5.0.0/PROVENANCE.txt")"
assert_eq "umask 000: binary is 0755" 755 "$(mode_of "$ROOT/versions/5.0.0/hongscanner")"

# ---------------------------------------------------------------- path safety
echo "--- group/other-writable install roots are refused"
ROOT="$SANDBOX/root-ww"
mkdir -p -- "$ROOT"
chmod 0777 "$ROOT"
RC=0; OUT="$(run_install "$B1" 1.0.0 "$DIGEST" "$ROOT" 2>&1)" || RC=$?
assert_eq "other-writable install root exits 6" 6 "$RC"
assert_contains "writable-root refusal is explained" "$OUT" "other-writable"
assert_absent "refused root gets no versions dir" "$ROOT/versions"

ROOT="$SANDBOX/root-gw-versions"
mkdir -p -- "$ROOT/versions"
chmod 0770 "$ROOT/versions"
RC=0; OUT="$(run_install "$B1" 1.0.0 "$DIGEST" "$ROOT" 2>&1)" || RC=$?
assert_eq "group-writable versions exits 6" 6 "$RC"
assert_contains "writable-versions refusal is explained" "$OUT" "group- or other-writable"
assert_absent "refused root gets no version dir" "$ROOT/versions/1.0.0"

echo "--- symlinked install paths are refused (boundary)"
TARGET="$SANDBOX/versions-target"
mkdir -p -- "$TARGET"
ROOT="$SANDBOX/root-versions-symlink"
mkdir -p -- "$ROOT"
ln -s "$TARGET" "$ROOT/versions"
RC=0; OUT="$(run_install "$B1" 1.0.0 "$DIGEST" "$ROOT" 2>&1)" || RC=$?
assert_eq "symlinked versions exits 6" 6 "$RC"
assert_contains "symlinked-versions refusal is explained" "$OUT" "symlink"
assert_absent "nothing is installed through the symlink" "$TARGET/1.0.0"
if [ -L "$ROOT/versions" ]; then
  echo "ok   the versions symlink itself is left untouched"; PASS=$((PASS + 1))
else
  echo "FAIL the versions symlink was replaced"; FAILED=$((FAILED + 1))
fi

REALROOT="$SANDBOX/real-root"
mkdir -p -- "$REALROOT"
ROOT="$SANDBOX/root-symlink"
ln -s "$REALROOT" "$ROOT"
RC=0; OUT="$(run_install "$B1" 1.0.0 "$DIGEST" "$ROOT" 2>&1)" || RC=$?
assert_eq "symlinked INSTALL_ROOT exits 6" 6 "$RC"
assert_contains "symlinked-root refusal is explained" "$OUT" "symlink"
assert_absent "nothing is created through the symlinked root" "$REALROOT/versions"

echo "--- a dangling symlink at the version path is refused"
ROOT="$SANDBOX/root-dangling-vdir"
mkdir -p -- "$ROOT/versions"
ln -s "$SANDBOX/no-such-version" "$ROOT/versions/1.0.0"
RC=0; OUT="$(run_install "$B1" 1.0.0 "$DIGEST" "$ROOT" 2>&1)" || RC=$?
assert_eq "dangling version symlink exits 6" 6 "$RC"
assert_absent "the dangling symlink target is never created" "$SANDBOX/no-such-version"

# ---------------------------------------------------------------- symlink traps
echo "--- planted SHA256/PROVENANCE symlinks never destroy their targets"
# A large dummy "binary" widens the installer's cp/hash window so the
# background attacker reliably lands its traps inside it.
BIG="$SANDBOX/big.bin"
dd if=/dev/zero of="$BIG" bs=1M count=128 status=none

ROOT="$SANDBOX/root-plant"
VICTIM_SHA="$SANDBOX/victim-sha.txt"
VICTIM_PROV="$SANDBOX/victim-prov.txt"
printf 'precious sha bytes\n' > "$VICTIM_SHA"
printf 'precious provenance bytes\n' > "$VICTIM_PROV"
plant_symlink_traps "$ROOT/versions/4.0.0" "$VICTIM_SHA" "$VICTIM_PROV" &
PLANT_PID=$!
RC=0; OUT="$(run_install "$BIG" 4.0.0 "$DIGEST" "$ROOT" 2>&1)" || RC=$?
wait "$PLANT_PID" || true
assert_eq "planted SHA256 symlink makes the install refuse (exit 6)" 6 "$RC"
assert_contains "planted-symlink refusal is reported" "$OUT" "INSTALL REFUSED"
assert_contains "refusal names the never-followed SHA256 path" "$OUT" "SHA256"
assert_not_contains "a refused install never claims INSTALL OK" "$OUT" "INSTALL OK"
assert_eq "the SHA256 victim survives untouched" "precious sha bytes" "$(cat "$VICTIM_SHA")"
assert_eq "the PROVENANCE victim survives untouched" "precious provenance bytes" \
  "$(cat "$VICTIM_PROV")"
assert_absent "current is never switched onto a refused version" "$ROOT/current"
assert_file "the finalized binary is still never deleted" "$ROOT/versions/4.0.0/hongscanner"

echo "--- a planted PROVENANCE-only symlink is also refused"
ROOT="$SANDBOX/root-plant2"
VICTIM2="$SANDBOX/victim-prov2.txt"
printf 'more precious bytes\n' > "$VICTIM2"
plant_symlink_traps "$ROOT/versions/4.1.0" "" "$VICTIM2" &
PLANT_PID=$!
RC=0; OUT="$(run_install "$BIG" 4.1.0 "$DIGEST" "$ROOT" 2>&1)" || RC=$?
wait "$PLANT_PID" || true
assert_eq "planted PROVENANCE symlink makes the install refuse (exit 6)" 6 "$RC"
assert_not_contains "no INSTALL OK on the PROVENANCE refusal" "$OUT" "INSTALL OK"
assert_eq "the PROVENANCE-only victim survives untouched" "more precious bytes" \
  "$(cat "$VICTIM2")"
assert_file "SHA256 was still written before the refusal" "$ROOT/versions/4.1.0/SHA256"
if [ -L "$ROOT/versions/4.1.0/PROVENANCE.txt" ]; then
  echo "ok   the planted PROVENANCE symlink is left in place, never followed"; PASS=$((PASS + 1))
else
  echo "FAIL the planted PROVENANCE symlink was clobbered or followed"; FAILED=$((FAILED + 1))
fi
assert_absent "current is never switched onto a refused version (2)" "$ROOT/current"

# ---------------------------------------------------------------- pre-switch TOCTOU
echo "--- tampering with the finalized binary before the switch is caught"
ROOT="$SANDBOX/root-final-toctou"
tamper_final_binary "$ROOT/versions/4.2.0" &
TAMPER_PID=$!
RC=0; OUT="$(run_install "$BIG" 4.2.0 "$DIGEST" "$ROOT" 2>&1)" || RC=$?
wait "$TAMPER_PID" || true
assert_eq "finalized-binary tampering refuses the install (exit 5)" 5 "$RC"
assert_contains "the pre-switch re-hash is reported" "$OUT" "TOCTOU"
assert_not_contains "no INSTALL OK after pre-switch tampering" "$OUT" "INSTALL OK"
assert_absent "current is never switched onto tampered bytes" "$ROOT/current"

# ---------------------------------------------------------------- hygiene
echo "--- side effects"
assert_eq "the source binary is never modified" "$H1" "$(hash_of "$B1")"
assert_eq "no temp files leak into TMPDIR" 0 "$(find "$SANDBOX/tmp" -mindepth 1 | wc -l)"

# ---------------------------------------------------------------- summary
echo ""
echo "$PASS passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
