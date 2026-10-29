#!/usr/bin/env bash
## Build-path contract tests for hongscanner.nimble / tools/build.sh.
##
## The ./hongscanner at the repo root is an operational binary: neither a
## dev `nimble build` nor the canonical tools/build.sh may create or
## overwrite it. Dev builds land in build/ (binDir in hongscanner.nimble)
## and keep the non-canonical marker; the canonical build lands in a
## versioned local directory runs/local-builds/hongscanner-<version>-<commit>
## with a CHECKSUMS.sha256 manifest (same format as runs/accept-*), and
## refuses to rebuild a path that already exists.
##
## The dev-build section runs a real `nimble build` in this repository; it
## writes only to build/, which is gitignored, and never removes anything.
## The formal-build sections work inside one private mktemp(1) sandbox: a
## clone of this repository is dirtied to prove the refusal, then committed
## against a local bare origin so every guard passes and the full canonical
## build is exercised without touching the network or this checkout.
##
## Run: bash tests/test_build_contract.sh
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

assert_absent() { # desc path
  if [ ! -e "$2" ]; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: $2 exists"; FAILED=$((FAILED + 1))
  fi
}

sha_of() { sha256sum "$1" | cut -d' ' -f1; }

# ------------------------------------------------------- dev build (nimble)
echo "--- nimble build never touches the root binary"
ROOT_BIN="$REPO_ROOT/hongscanner"
DEV_BIN="$REPO_ROOT/build/hongscanner"
HAD_ROOT=0
ROOT_SHA=""
if [ -f "$ROOT_BIN" ]; then
  HAD_ROOT=1
  ROOT_SHA="$(sha_of "$ROOT_BIN")"
fi

RC=0; OUT="$(cd "$REPO_ROOT" && nimble build --hints:off 2>&1)" || RC=$?
assert_eq "nimble build exits 0" 0 "$RC"

assert_file "nimble build writes the dev binary to build/" "$DEV_BIN"
if [ "$HAD_ROOT" -eq 1 ]; then
  assert_eq "nimble build leaves the existing root binary byte-identical" \
    "$ROOT_SHA" "$(sha_of "$ROOT_BIN")"
else
  assert_absent "nimble build must not create the root binary" "$ROOT_BIN"
fi

RC=0; DOUT="$(cd "$REPO_ROOT" && "$DEV_BIN" doctor 2>/dev/null)" || RC=$?
assert_contains "dev binary self-reports the non-canonical marker" \
  "$DOUT" "source_ref=dev"

# ------------------------------------------------- formal build: dirty tree
echo "--- tools/build.sh refuses a dirty tree"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hs-build-test.XXXXXX")"
cleanup() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

git clone --quiet "$REPO_ROOT" "$SANDBOX/repo"
# CI checkouts can be detached; the gate requires branch "main".
git -C "$SANDBOX/repo" checkout -q -B main
# Overlay the in-development build files: a clean clone plus local
# modifications is exactly the dirty state the gate must refuse.
cp "$REPO_ROOT/hongscanner.nimble" "$REPO_ROOT/.gitignore" "$SANDBOX/repo/"
cp "$REPO_ROOT/tools/build.sh" "$SANDBOX/repo/tools/build.sh"

# Canary: the root operational binary the build must never touch.
head -c 4096 /dev/urandom > "$SANDBOX/repo/hongscanner"
CANARY_SHA="$(sha_of "$SANDBOX/repo/hongscanner")"

RC=0; ERR="$(bash "$SANDBOX/repo/tools/build.sh" 2>&1 >/dev/null)" || RC=$?
assert_eq "build.sh refuses a dirty tree with exit 1" 1 "$RC"
assert_contains "refusal names the dirty tree" \
  "$ERR" "BUILD REFUSED: working tree is dirty"
assert_eq "refused build preserves the root binary canary" \
  "$CANARY_SHA" "$(sha_of "$SANDBOX/repo/hongscanner")"
assert_absent "refused build leaves no local build output" \
  "$SANDBOX/repo/runs/local-builds"

# ------------------------------------------- formal build: versioned local output
echo "--- tools/build.sh builds into a versioned local path"
# Commit the overlay and re-point origin at a local bare clone so the
# checkout is main, clean, and identical to origin/main: every guard
# passes and the canonical build runs end to end, offline.
git -C "$SANDBOX/repo" add -A
git -C "$SANDBOX/repo" -c user.email=build-test@local \
  -c user.name="build contract test" \
  commit --quiet -m "test: build-path contract fixture"
git clone --quiet --bare "$SANDBOX/repo" "$SANDBOX/origin.git"
git -C "$SANDBOX/repo" remote set-url origin "$SANDBOX/origin.git"
git -C "$SANDBOX/repo" fetch --quiet origin main

CLONE_HEAD="$(git -C "$SANDBOX/repo" rev-parse HEAD)"
RC=0; OUT="$(bash "$SANDBOX/repo/tools/build.sh" 2>&1)" || RC=$?
assert_eq "build.sh completes the canonical build" 0 "$RC"

version="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$SANDBOX/repo/hongscanner.nimble" | head -n1)"
short="$(git -C "$SANDBOX/repo" rev-parse --short=12 HEAD)"
expected="runs/local-builds/hongscanner-$version-$short"
assert_contains "BUILD OK names the local build path" "$OUT" "local_build=$expected"
assert_file "local build binary exists" "$SANDBOX/repo/$expected/hongscanner"
assert_file "local build checksum manifest exists" \
  "$SANDBOX/repo/$expected/CHECKSUMS.sha256"
RC=0; (cd "$SANDBOX/repo/$expected" && sha256sum -c CHECKSUMS.sha256 \
  >/dev/null 2>&1) || RC=$?
assert_eq "local build checksum manifest verifies" 0 "$RC"
assert_eq "canonical build preserves the root binary canary" \
  "$CANARY_SHA" "$(sha_of "$SANDBOX/repo/hongscanner")"

RC=0; BOUT="$(cd "$SANDBOX/repo" && \
  "$SANDBOX/repo/$expected/hongscanner" doctor 2>/dev/null)" || RC=$?
assert_contains "local binary self-reports the canonical commit" \
  "$BOUT" "BUILD commit=$CLONE_HEAD source_ref=main"
assert_contains "local binary self-reports clean provenance" \
  "$BOUT" "dirty=false"

# ------------------------------------------------- local path immutability
echo "--- tools/build.sh refuses to rebuild an existing local path"
RC=0; ERR="$(bash "$SANDBOX/repo/tools/build.sh" 2>&1 >/dev/null)" || RC=$?
assert_eq "rebuilding an existing local path is refused" 1 "$RC"
assert_contains "rebuild refusal names the local path" \
  "$ERR" "BUILD REFUSED: build directory already exists"

# ---------------------------------------------------------------- summary
echo ""
echo "$PASS passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
