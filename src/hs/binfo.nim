## Build provenance.
##
## `tools/build.sh` (main + clean + HEAD == origin/main) injects the real
## values with -d switches. Any plain `nimble build` / `nim c` keeps these
## defaults, which `verify` rejects as INVALID_PROVENANCE. `hsBuildDirty`
## defaults to true, so a partially injected build is rejected; compiler
## switches themselves do not authenticate a complete set of build claims.
## A *partial* hand injection (say only -d:hsBuildSourceRef=main and
## -d:hsBuildDirty=false) would otherwise satisfy every compared value,
## so `verify` also rejects any remaining "dev" marker outright via
## `hasDevMarker`.
type
  BuildInfo* = object
    codeCommit*: string
    sourceRef*: string
    originMainSha*: string
    dirty*: bool
    nimVersion*: string
    buildTime*: string

const
  devMarker* = "dev"
  hsBuildCommit {.strdefine.} = "dev"
  hsBuildSourceRef {.strdefine.} = "dev"
  hsBuildOriginMain {.strdefine.} = "dev"
  hsBuildTime {.strdefine.} = "dev"
  hsBuildDirty {.booldefine.} = true

proc hasDevMarker*(bi: BuildInfo): bool =
  ## True when any -d-injected string still carries the non-canonical
  ## default. Real values (a 40-hex sha, "main", an ISO-8601 timestamp)
  ## can never equal "dev", so this only fires on a build that skipped
  ## `tools/build.sh` and faked only part of the provenance.
  bi.codeCommit == devMarker or bi.sourceRef == devMarker or
    bi.originMainSha == devMarker or bi.buildTime == devMarker

const buildInfo* = BuildInfo(
  codeCommit: hsBuildCommit,
  sourceRef: hsBuildSourceRef,
  originMainSha: hsBuildOriginMain,
  dirty: hsBuildDirty,
  nimVersion: NimVersion,
  buildTime: hsBuildTime)