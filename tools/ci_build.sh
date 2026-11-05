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
##                             - $CI_BUILD_OUT/hongscanner must not exist,
##                             - $CI_BUILD_OUT/collector must not exist.
##                           The build writes only these, all new:
##                             $CI_BUILD_OUT/hongscanner  the release binary
##                             $CI_BUILD_OUT/collector    the release collector
##                             $CI_BUILD_OUT/nimcache/    the hongscanner cache
##                             $CI_BUILD_OUT/nimcache-collector/  the
##                                 collector cache (separate on purpose: one
##                                 cache directory per -d set, no reuse)
##                           Nothing inside the repository is written: an
##                           existing ./hongscanner (a canonical
##                           tools/build.sh product, gitignored) is never
##                           clobbered, and no test artifact can be mistaken
##                           for an attested binary. Local manual runs must
##                           supply their own fresh directory, e.g.
##                           CI_BUILD_OUT="$(mktemp -d)".
##
## Guards (each refuses the build, exit 1):
##   origin remote is wintrover/hongscanner (the refetch below authenticates
##     with CI_GIT_TOKEN through a per-command http.extraheader when that env
##     is set -- required since the repository went private -- and stays
##     anonymous otherwise, so local and public-repository callers are
##     unchanged),
##   clean tree -- untracked files count as dirty, exactly like tools/build.sh,
##   HEAD == CI_BUILD_SHA,
##   origin/main re-fetched HERE still equals CI_BUILD_SHA, so the pushed SHA
##     is main's live tip at build time; a re-run of a stale event refuses
##     instead of attesting a SHA main has moved past,
##   nim is the pinned 2.2.10 (verified, not assumed).
##
## The -d defines below are the contract src/hs/binfo.nim consumes (see
## tools/build.sh for the canonical injection) and only the hongscanner
## binary carries them: the collector entry point
## (tools/collector/collector.nim) imports no binfo/verify module, so
## those defines would be dead metadata there -- the collector's
## provenance evidence is its own attestation subject
## (collector-linux-<arch> in attest.yml), not embedded metadata. After
## the build, every consumer in attest.yml -- doctor, selftest, the
## attestation subjects, the checksums, the build reports, the artifact
## uploads and the image staging -- uses exactly these two paths:
## $CI_BUILD_OUT/hongscanner and $CI_BUILD_OUT/collector.
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
  *github.com[:/]wintrover/hongscanner|*github.com[:/]wintrover/hongscanner.git) ;;
  *)
    echo "BUILD REFUSED: origin is not wintrover/hongscanner: $origin_url" >&2
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
if [ -e "$CI_BUILD_OUT/collector" ]; then
  echo "BUILD REFUSED: refusing to overwrite existing $CI_BUILD_OUT/collector" >&2
  exit 1
fi

## Read-only refetch of main. Verbose on purpose: the fetched range is
## evidence in the CI log. Authentication is per-command only: when
## CI_GIT_TOKEN is set the token rides a one-shot http.extraheader -- the
## same AUTHORIZATION: basic base64("x-access-token:<token>") form
## actions/checkout authenticates git with -- never the URL, the remote
## config or an echo, so nothing is persisted after this command. attest.yml
## supplies the job's GITHUB_TOKEN because the repository is private;
## without the env the fetch stays anonymous (local callers keep using their
## own credential helpers). A failed fetch still refuses the build --
## fail-closed either way.
if [ -n "${CI_GIT_TOKEN:-}" ]; then
  git -c http.extraheader="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$CI_GIT_TOKEN" | base64)" \
    fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main
else
  git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main
fi
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

## The collector release binary (PR-5): the same guards, the same fail-
## closed posture, one more subject. No hsBuild* injection here -- see the
## header: tools/collector/collector.nim consumes none of those defines
## (its import graph has no binfo/verify), and a define nothing reads is
## not provenance. Its own nimcache keeps the two builds' -d sets apart.
nim c -d:release --hints:off --warnings:off --path:src \
  --nimcache:"$CI_BUILD_OUT/nimcache-collector" \
  -o:"$CI_BUILD_OUT/collector" tools/collector/collector.nim

if [ ! -x "$CI_BUILD_OUT/collector" ]; then
  echo "BUILD REFUSED: $CI_BUILD_OUT/collector was not produced" >&2
  exit 1
fi

echo "CI BUILD OK out=$CI_BUILD_OUT commit=$head source_ref=main origin_main=$origin_main nim=$nim_line binaries=hongscanner,collector"
