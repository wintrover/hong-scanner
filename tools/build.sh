#!/usr/bin/env bash
## Canonical build gate (plan §3.4). Refuses to build unless the checkout is
## main, clean, identical to origin/main, and on the pinned toolchain, then
## injects the provenance the binary will claim. There is no --allow-dirty
## escape hatch.
##
## Local canonical builds are not independently attested. Write to a new
## versioned directory and never replace an existing artifact.
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="$HOME/.choosenim/toolchains/nim-2.2.10/bin:$PATH"

if [ -n "$(git status --porcelain)" ]; then
  echo "BUILD REFUSED: working tree is dirty" >&2
  exit 1
fi

ref="$(git rev-parse --abbrev-ref HEAD)"
if [ "$ref" != "main" ]; then
  echo "BUILD REFUSED: source_ref=$ref (must be main)" >&2
  exit 1
fi

git fetch --quiet origin main
head="$(git rev-parse HEAD)"
origin="$(git rev-parse origin/main)"
if [ "$head" != "$origin" ]; then
  echo "BUILD REFUSED: HEAD=$head != origin/main=$origin" >&2
  exit 1
fi

## The PATH preference above is not a pin: verify the compiler version so a
## machine without nim-2.2.10 cannot silently build with another toolchain.
nim_line="$(nim --version | head -1)"
if ! printf '%s\n' "$nim_line" | grep -qE 'Version 2\.2\.10([^0-9]|$)'; then
  echo "BUILD REFUSED: nim is not the pinned 2.2.10: $nim_line" >&2
  exit 1
fi

version="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' hongscanner.nimble | head -n1)"
if [[ ! "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
  echo "BUILD REFUSED: invalid version in hongscanner.nimble" >&2
  exit 1
fi
short="$(git rev-parse --short=12 "$head")"
build_dir="runs/local-builds/hongscanner-$version-$short"
mkdir -p runs/local-builds
if ! mkdir "$build_dir"; then
  echo "BUILD REFUSED: build directory already exists: $build_dir" >&2
  exit 1
fi

nim c -d:release --hints:off --warnings:off --path:src \
  -d:hsBuildCommit="$head" \
  -d:hsBuildSourceRef="$ref" \
  -d:hsBuildOriginMain="$origin" \
  -d:hsBuildTime="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -d:hsBuildDirty=false \
  -o:"$build_dir/hongscanner" src/hongscanner.nim

(cd "$build_dir" && sha256sum hongscanner > CHECKSUMS.sha256)

echo "BUILD OK commit=$head source_ref=$ref origin_main=$origin nim=$nim_line local_build=$build_dir"