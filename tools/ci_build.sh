#!/usr/bin/env bash
## CI-side release build for .github/workflows/attest.yml (main-push
## attestation). tools/build.sh stays the canonical git-local build gate and is
## neither modified nor weakened by this file; there is no shared flag and no
## --allow-dirty escape hatch here either. This is a separate path because a CI
## checkout is a detached HEAD at the exact pushed SHA, so the local
## "abbrev-ref is main" check cannot apply verbatim. Instead, this script
## requires the caller to name that SHA and re-derives every guarantee:
##
##   CI_BUILD_SHA  required  exact 40-hex main SHA the push event named.
##                           HEAD must equal it, so the build checkout is
##                           byte-identical to the main push SHA.
##   CI_BUILD_REF  required  must be "main": attest.yml only fires on
##                           refs/heads/main and passes that claim down.
##   CI_BUILD_OUT  required  isolated output directory the workflow created
##                           empty and unique under RUNNER_TEMP and exported
##                           via GITHUB_ENV. Contract, all fail-closed:
##                             - absolute path,
##                             - OUTSIDE this repository (never inside it),
##                             - new or empty,
##                             - $CI_BUILD_OUT/hongscanner must not exist.
##                           The build writes only these, both new:
##                             $CI_BUILD_OUT/hongscanner  the release binary
##                             $CI_BUILD_OUT/nimcache/    the compile cache
##                           Nothing inside the repository is written: an
##                           existing ./hongscanner (a canonical
##                           tools/build.sh product, gitignored) is never
##                           clobbered, and no test artifact can be mistaken
##                           for the attested binary. Local manual runs must
##                           supply their own fresh directory, e.g.
##                           CI_BUILD_OUT="$(mktemp -d)".
##
## Guards (each refuses the build, exit 1):
##   origin remote is wintrover/hong-scanner (public repo, so the anonymous
##     https fetch below needs no credentials),
##   clean tree -- untracked files count as dirty, exactly like tools/build.sh,
##   HEAD == CI_BUILD_SHA,
##   origin/main re-fetched HERE still equals CI_BUILD_SHA, so the pushed SHA
##     is main's live tip at build time; a re-run of a stale event refuses
##     instead of attesting a SHA main has moved past,
##   nim is the pinned 2.2.10 (verified, not assumed).
##
## The -d defines below are the contract src/hs/binfo.nim consumes (see
## tools/build.sh for the canonical injection). After the build, every
## consumer in attest.yml -- doctor, selftest, the attestation subject, the
## checksum, the build report and the artifact uploads -- uses this exact
## path: $CI_BUILD_OUT/hongscanner.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${CI_BUILD_SHA:-}" ] || [ -z "${CI_BUILD_REF:-}" ] || [ -z "${CI_BUILD_OUT:-}" ]; then
  echo "BUILD REFUSED: CI_BUILD_SHA, CI_BUILD_REF and CI_BUILD_OUT must be set" >&2
  exit 1
fi
if ! printf '%s' "$CI_BUILD_SHA" | grep -qE '^[0-9a-f]{40}$'; then
  echo "BUILD REFUSED: CI_BUILD_SHA is not a 40-hex sha: $CI_BUILD_SHA" >&2
  exit 1
fi
if [ "$CI_BUILD_REF" != "main" ]; then
  echo "BUILD REFUSED: CI_BUILD_REF=$CI_BUILD_REF (must be main)" >&2
  exit 1
fi
case "$CI_BUILD_OUT" in
  /*) ;;
  *)
    echo "BUILD REFUSED: CI_BUILD_OUT must be an absolute path: $CI_BUILD_OUT" >&2
    exit 1
    ;;
esac

if ! origin_url="$(git remote get-url origin 2>/dev/null)"; then
  echo "BUILD REFUSED: no origin remote" >&2
  exit 1
fi
case "$origin_url" in
  *github.com[:/]wintrover/hong-scanner|*github.com[:/]wintrover/hong-scanner.git) ;;
  *)
    echo "BUILD REFUSED: origin is not wintrover/hong-scanner: $origin_url" >&2
    exit 1
    ;;
esac

if [ -n "$(git status --porcelain)" ]; then
  echo "BUILD REFUSED: working tree is dirty" >&2
  git status --porcelain >&2 || true
  exit 1
fi

head="$(git rev-parse HEAD)"
if [ "$head" != "$CI_BUILD_SHA" ]; then
  echo "BUILD REFUSED: HEAD=$head != CI_BUILD_SHA=$CI_BUILD_SHA (checkout must be the exact pushed main SHA)" >&2
  exit 1
fi

## Output isolation: resolve both paths and refuse anything inside the repo.
repo_root="$(git rev-parse --show-toplevel)"
out_real="$(realpath -m -- "$CI_BUILD_OUT")"
case "$out_real" in
  "$repo_root"|"$repo_root"/*)
    echo "BUILD REFUSED: CI_BUILD_OUT ($out_real) is inside the repository ($repo_root); the build must write outside it" >&2
    exit 1
    ;;
esac
if [ -e "$CI_BUILD_OUT" ] && [ ! -d "$CI_BUILD_OUT" ]; then
  echo "BUILD REFUSED: CI_BUILD_OUT exists and is not a directory: $CI_BUILD_OUT" >&2
  exit 1
fi
if [ -d "$CI_BUILD_OUT" ] && [ -n "$(find "$CI_BUILD_OUT" -mindepth 1 -print -quit)" ]; then
  echo "BUILD REFUSED: CI_BUILD_OUT is not empty (nothing may be overwritten): $CI_BUILD_OUT" >&2
  exit 1
fi
if [ -e "$CI_BUILD_OUT/hongscanner" ]; then
  echo "BUILD REFUSED: refusing to overwrite existing $CI_BUILD_OUT/hongscanner" >&2
  exit 1
fi

## Read-only refetch of main. Verbose on purpose: the fetched range is
## evidence in the CI log.
git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main
origin_main="$(git rev-parse refs/remotes/origin/main)"
if [ "$origin_main" != "$CI_BUILD_SHA" ]; then
  echo "BUILD REFUSED: origin/main=$origin_main != CI_BUILD_SHA=$CI_BUILD_SHA (main moved on; refusing to attest a stale SHA)" >&2
  exit 1
fi

## Toolchain pin. Prefer the local choosenim layout when present (dev parity
## with tools/build.sh); on the runner, setup-nim-action puts nim on PATH.
## The version check below is the actual pin either way.
if [ -d "$HOME/.choosenim/toolchains/nim-2.2.10/bin" ]; then
  export PATH="$HOME/.choosenim/toolchains/nim-2.2.10/bin:$PATH"
fi
nim_line="$(nim --version | head -1)"
if ! printf '%s\n' "$nim_line" | grep -qE 'Version 2\.2\.10([^0-9]|$)'; then
  echo "BUILD REFUSED: nim is not the pinned 2.2.10: $nim_line" >&2
  exit 1
fi

[ -d "$CI_BUILD_OUT" ] || mkdir -- "$CI_BUILD_OUT"

nim c -d:release --hints:off --warnings:off --path:src \
  --nimcache:"$CI_BUILD_OUT/nimcache" \
  -d:hsBuildCommit="$head" \
  -d:hsBuildSourceRef="main" \
  -d:hsBuildOriginMain="$origin_main" \
  -d:hsBuildTime="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -d:hsBuildDirty=false \
  -o:"$CI_BUILD_OUT/hongscanner" src/hongscanner.nim

if [ ! -x "$CI_BUILD_OUT/hongscanner" ]; then
  echo "BUILD REFUSED: $CI_BUILD_OUT/hongscanner was not produced" >&2
  exit 1
fi

echo "CI BUILD OK out=$CI_BUILD_OUT commit=$head source_ref=main origin_main=$origin_main nim=$nim_line"
