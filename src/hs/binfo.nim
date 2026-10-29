## Build provenance.
##
## `tools/build.sh` (main + clean + HEAD == origin/main) injects the real
## values with -d switches. Any plain `nimble build` / `nim c` keeps these
## defaults, which `verify` rejects as INVALID_PROVENANCE. `hsBuildDirty`
## defaults to true so a hand-injected commit string cannot fake a clean
## build; the build gate must pass -d:hsBuildDirty=false explicitly.
type
  BuildInfo* = object
    codeCommit*: string
    sourceRef*: string
    originMainSha*: string
    dirty*: bool
    nimVersion*: string
    buildTime*: string

const
  hsBuildCommit {.strdefine.} = "dev"
  hsBuildSourceRef {.strdefine.} = "dev"
  hsBuildOriginMain {.strdefine.} = "dev"
  hsBuildTime {.strdefine.} = "dev"
  hsBuildDirty {.booldefine.} = true

const buildInfo* = BuildInfo(
  codeCommit: hsBuildCommit,
  sourceRef: hsBuildSourceRef,
  originMainSha: hsBuildOriginMain,
  dirty: hsBuildDirty,
  nimVersion: NimVersion,
  buildTime: hsBuildTime)