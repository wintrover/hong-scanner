#!/usr/bin/env bash
## Canonical build gate (plan §3.4). Refuses to build unless the checkout is
## main, clean, and identical to origin/main, then injects the provenance the
## binary will claim. There is no --allow-dirty escape hatch.
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

nim c -d:release --hints:off --warnings:off --path:src \
  -d:hsBuildCommit="$head" \
  -d:hsBuildSourceRef="$ref" \
  -d:hsBuildOriginMain="$origin" \
  -d:hsBuildTime="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -d:hsBuildDirty=false \
  -o:hongscanner src/hongscanner.nim

echo "BUILD OK commit=$head source_ref=$ref origin_main=$origin nim=$(nim --version | head -1)"