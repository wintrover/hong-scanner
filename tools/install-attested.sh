#!/usr/bin/env bash
## Minimal atomic install path for the GitHub-attested binary (GATES.md P13).
##
## Verifies a downloaded hongscanner binary by delegating entirely to
## `gh attestation verify`, pinned to: repo wintrover/hong-scanner, signer
## workflow .github/workflows/attest.yml (gh's [host/]<owner>/<repo>/<path>
## form: wintrover/hong-scanner/.github/workflows/attest.yml), source ref
## refs/heads/main, the exact source digest given as an argument, and
## GitHub-hosted runners only (--deny-self-hosted-runners). This script never
## reimplements, replaces or fakes any part of attestation verification: if
## `gh` is unavailable, or gh refuses the artifact, nothing is installed.
## Real GitHub attestation verification is not covered by the repo's tests;
## it is executed on the attested binary after merge.
##
## On success it creates (and never deletes or overwrites anything):
##   INSTALL_ROOT/versions/VERSION/hongscanner    0755, the verified bytes
##   INSTALL_ROOT/versions/VERSION/SHA256         actual sha256 of the
##                                                verified binary,
##                                                `sha256sum -c` format
##   INSTALL_ROOT/versions/VERSION/PROVENANCE.txt the pinned verification facts
##   INSTALL_ROOT/current -> versions/VERSION     atomic switch via rename(2)
##
## Fail-closed policy:
##   - An existing versions/VERSION, or a `current` that is not a symlink,
##     refuses the install. Existing versions and any user data are never
##     deleted or overwritten; a failed install removes only its own
##     uniquely named temp files and leaves everything else exactly as is.
##   - No lock file: a version directory is claimed with mkdir(1), so the
##     loser of a same-version race fails with EEXIST, and `current` is
##     replaced only by renaming a uniquely named temp symlink over it
##     (mv -T). Concurrent installs therefore cannot interleave, and a
##     reader always sees either the old or the new complete version.
##   - TOCTOU: the binary is hashed before verification, re-hashed after
##     it, the staged copy is hashed before being finalized, and the
##     finalized version is re-read (metadata re-compared, binary
##     re-hashed) immediately before the `current` switch; any difference
##     refuses the install and the version is left unselected.
##   - Install-path safety: the script runs with umask 022 (directories
##     0755, files 0644) whatever the caller's umask is, so a umask-000
##     caller cannot leave a group/other-writable tree that anyone could
##     plant files or symlink traps in. INSTALL_ROOT and INSTALL_ROOT/versions
##     must be real directories (never symlinks) and must not be group- or
##     other-writable -- inherited default ACLs count and are checked after
##     creation; such roots are refused (exit 6) before anything is written.
##     SHA256 and PROVENANCE.txt are created with O_EXCL (set -C), so an
##     existing path -- a planted symlink in particular -- is never
##     followed or truncated. Keeping INSTALL_ROOT/versions non-writable
##     by others after this script exits is an operational requirement the
##     script cannot enforce.
##   - SOURCE_DIGEST: gh compares --source-digest verbatim (string
##     equality) with the certificate's SourceRepositoryDigest extension,
##     and GitHub OIDC emits that value as bare hex, so a sha1:/sha256:-
##     prefixed value could never match. The prefix is accepted as input
##     convenience only and stripped before gh is invoked: gh always
##     receives the bare 40- or 64-hex digest.
##
## This script installs files only. It deliberately installs, enables or
## schedules no service, timer or cron job.
##
## Linux (GNU coreutils) only: mv -T, mktemp --, stat -c, sha256sum.
##
## Exit codes: 0 installed; 1 filesystem failure; 2 usage error; 3 gh
## missing; 4 attestation verification failed; 5 installed files changed
## during install (TOCTOU); 6 install conflict (existing version,
## non-symlink current, or a symlinked / group- or other-writable install
## path).
set -euo pipefail
umask 022 # dirs 0755, files 0644: no group/other-writable paths even under umask 000/002
set -C    # O_EXCL on shell redirections: never write through an existing path or symlink

readonly REPO="wintrover/hong-scanner"
readonly SIGNER_WORKFLOW="wintrover/hong-scanner/.github/workflows/attest.yml"
readonly SOURCE_REF="refs/heads/main"

usage() {
  printf 'usage: tools/install-attested.sh BINARY VERSION SOURCE_DIGEST INSTALL_ROOT\n\n' >&2
  printf '  BINARY         downloaded hongscanner binary to verify and install\n' >&2
  printf '  VERSION        version label used for INSTALL_ROOT/versions/VERSION\n' >&2
  printf '  SOURCE_DIGEST  exact expected source commit digest: bare 40- or\n' >&2
  printf '                 64-hex sha. A sha1:/sha256: prefix is accepted and\n' >&2
  printf '                 stripped, because gh matches the digest verbatim\n' >&2
  printf '                 against the bare-hex certificate extension\n' >&2
  printf '  INSTALL_ROOT   install root; created if missing, never cleaned;\n' >&2
  printf '                 must be a real directory (not a symlink) and not\n' >&2
  printf '                 group- or other-writable\n' >&2
}

die() { # exit-code message...
  local code="$1"; shift
  printf 'INSTALL REFUSED: %s\n' "$*" >&2
  exit "$code"
}

require_safe_dir() { # path label -- real dir, not a symlink, not group/other-writable
  local mode
  if [ -L "$1" ]; then
    die 6 "$2 [$1] is a symlink; installs never follow symlinks out of the install root"
  fi
  mode="$(stat -c '%a' -- "$1")" || die 1 "cannot stat $2 [$1]"
  if [ $(( 8#$mode & 8#022 )) -ne 0 ]; then
    die 6 "$2 [$1] is group- or other-writable (mode $mode); chmod g-w,o-w it and retry so nobody else can plant files or symlink traps inside it"
  fi
}

if [ "$#" -ne 4 ]; then usage; exit 2; fi
binary="$1"; version="$2"; source_digest="$3"; root="$4"

if ! [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]]; then
  die 2 "invalid VERSION [$version]: must match ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}\$"
fi
source_digest="${source_digest,,}"
if ! [[ "$source_digest" =~ ^(sha(1|256):)?([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
  die 2 "invalid SOURCE_DIGEST: must be a 40- or 64-hex sha, optionally sha1:/sha256: prefixed"
fi
source_digest="${source_digest#sha1:}"
source_digest="${source_digest#sha256:}"
while [ "$root" != "/" ] && [ "${root%/}" != "$root" ]; do root="${root%/}"; done
[ -n "$root" ] || die 2 "INSTALL_ROOT must not be empty"
[ -f "$binary" ] || die 2 "BINARY [$binary] is not a regular file"
command -v gh >/dev/null 2>&1 \
  || die 3 "gh not found in PATH; attestation verification is delegated to gh and cannot be skipped"

if [ -L "$root" ]; then
  die 6 "INSTALL_ROOT [$root] is a symlink; installs never follow symlinks out of the install root"
fi
if [ -e "$root" ] && [ ! -d "$root" ]; then
  die 2 "INSTALL_ROOT [$root] exists and is not a directory"
fi
[ ! -d "$root" ] || require_safe_dir "$root" "install root"

# A relative BINARY starting with '-' would be parsed as a gh flag.
case "$binary" in -*) binary="./$binary" ;; esac

sha256_of() { # file -> sha256 hex digest on stdout
  local line
  line="$(sha256sum -- "$1")" || return 1
  printf '%s' "${line%% *}"
}

digest_verified="$(sha256_of "$binary")" || die 1 "cannot hash BINARY [$binary]"

gh attestation verify "$binary" \
  --repo "$REPO" \
  --signer-workflow "$SIGNER_WORKFLOW" \
  --source-ref "$SOURCE_REF" \
  --source-digest "$source_digest" \
  --deny-self-hosted-runners \
  || die 4 "gh attestation verify failed (exit $?); nothing was installed"

digest_recheck="$(sha256_of "$binary")" || die 1 "cannot re-hash BINARY [$binary]"
[ "$digest_verified" = "$digest_recheck" ] || die 5 \
  "binary changed during verification (TOCTOU): $digest_verified -> $digest_recheck"

staged=""
tmplink=""
cleanup() {
  if [ -n "$staged" ] && [ -f "$staged" ]; then rm -f -- "$staged"; fi
  if [ -n "$tmplink" ] && [ -L "$tmplink" ]; then rm -f -- "$tmplink"; fi
}
trap cleanup EXIT

mkdir -p -- "$root/versions" || die 1 "cannot create $root/versions"
require_safe_dir "$root" "install root"
require_safe_dir "$root/versions" "versions directory"
vdir="$root/versions/$version"
if [ -e "$vdir" ] || [ -L "$vdir" ]; then
  die 6 "version $version already exists at $vdir; existing versions are never overwritten"
fi
mkdir -- "$vdir" \
  || die 6 "lost the concurrent race for $vdir; nothing was overwritten"

staged="$(mktemp -- "$vdir/.incoming.XXXXXX")" \
  || die 1 "cannot create a staging temp file in $vdir"
cp -- "$binary" "$staged" || die 1 "cannot stage a copy of BINARY [$binary]"
digest_staged="$(sha256_of "$staged")" || die 1 "cannot hash the staged copy"
[ "$digest_staged" = "$digest_verified" ] || die 5 \
  "staged copy differs from the verified binary (TOCTOU): $digest_verified -> $digest_staged"

chmod 0755 "$staged" || die 1 "cannot set 0755 on the staged copy"
final="$vdir/hongscanner"
[ ! -e "$final" ] || die 6 "unexpected existing file at $final"
mv -T -- "$staged" "$final" || die 1 "cannot finalize $final"
staged=""

sha_line="$(printf '%s  hongscanner' "$digest_verified")"
if ! printf '%s\n' "$sha_line" > "$vdir/SHA256"; then
  die 6 "cannot create $vdir/SHA256: the path already exists (a planted symlink is never followed or truncated); version $version is left incomplete and unselected"
fi
prov_content="$(
  printf 'installed_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'repo=%s\n' "$REPO"
  printf 'signer_workflow=%s\n' "$SIGNER_WORKFLOW"
  printf 'source_ref=%s\n' "$SOURCE_REF"
  printf 'source_digest=%s\n' "$source_digest"
  printf 'runner_policy=github-hosted-only (--deny-self-hosted-runners)\n'
  printf 'verifier=gh attestation verify (delegated, never reimplemented)\n'
  printf 'sha256=%s\n' "$digest_verified"
)" || die 1 "cannot render the provenance record"
if ! printf '%s\n' "$prov_content" > "$vdir/PROVENANCE.txt"; then
  die 6 "cannot create $vdir/PROVENANCE.txt: the path already exists (a planted symlink is never followed or truncated); version $version is left incomplete and unselected"
fi

# Close the in-script window before the switch: anything able to write to
# $root/versions could have swapped the finalized version wholesale by now.
sha_now="$(cat -- "$vdir/SHA256")" || true
prov_now="$(cat -- "$vdir/PROVENANCE.txt")" || true
if [ "$sha_now" != "$sha_line" ] || [ "$prov_now" != "$prov_content" ]; then
  die 5 "version $version metadata changed after being written (TOCTOU); it is left unselected"
fi
digest_final="$(sha256_of "$final")" || die 1 "cannot re-hash $final"
[ "$digest_final" = "$digest_verified" ] || die 5 \
  "installed binary changed before the current switch (TOCTOU): $digest_verified -> $digest_final; version $version is left unselected"

if [ -e "$root/current" ] && [ ! -L "$root/current" ]; then
  die 6 "$root/current exists and is not a symlink; version $version was installed but left unselected"
fi
tmplink="$root/.current.tmp.$$.$RANDOM"
ln -s "versions/$version" "$tmplink" || die 1 "cannot create the temp symlink"
if ! mv -T -- "$tmplink" "$root/current"; then
  rm -f -- "$tmplink"; tmplink=""
  die 6 "cannot atomically switch $root/current; version $version was installed but left unselected"
fi
tmplink=""

printf 'INSTALL VERIFY OK repo=%s signer=%s ref=%s source_digest=%s runner=github-hosted-only\n' \
  "$REPO" "$SIGNER_WORKFLOW" "$SOURCE_REF" "$source_digest"
printf 'INSTALL OK version=%s sha256=%s current=%s\n' \
  "$version" "$digest_verified" "$root/current"
