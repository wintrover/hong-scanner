## Run artifacts, checksums and replay verification (plan §3.4).
##
## Deterministic artifacts (checksummed): input.hcj.jsonl, bars.hcj.jsonl,
## signals.hcj.jsonl. Non-deterministic metadata (run.json) is excluded from
## CHECKSUMS.sha256, but `verify` still reconciles it against the input stream
## and the binary's embedded build info before declaring VERDICT MATCH.
##
## writeRun is non-destructive by construction on POSIX: the output directory
## is pinned with O_NOFOLLOW and every artifact is created exclusively with
## O_CREAT|O_EXCL, so a guard-to-write race or a planted symlink can only
## end in a refusal, never in a truncated or overwritten file.
import std/[strutils, os, times, algorithm, options]
import hcj, records, calendars, bars, engine, replay, digest, binfo
when defined(posix):
  import std/posix

type
  Verdict* = enum
    vMatch, vContract, vCalendar, vIncomplete, vInvalid, vUnreliable,
    vMismatch, vInvalidProvenance

  VerifyResult* = object
    verdict*: Verdict
    issues*: seq[string]
    matched*: bool

  OutputGuardError* = object of CatchableError
  RunArtifact* = tuple[name, data: string]

const
  inputFile* = "input.hcj.jsonl"
  barsFile* = "bars.hcj.jsonl"
  signalsFile* = "signals.hcj.jsonl"
  runFile* = "run.json"
  checksumsFile* = "CHECKSUMS.sha256"

proc exitCode*(v: Verdict): int =
  case v
  of vMatch: 0
  of vContract: 2
  of vCalendar: 3
  of vIncomplete: 4
  of vInvalid, vUnreliable: 5
  of vMismatch: 6
  of vInvalidProvenance: 7

proc linesText(lines: seq[string]): string =
  ## LF after every line, including the last one. Empty input -> empty file.
  for l in lines: result.add(l & "\n")

proc checksums*(dir: string): string =
  ## sha256 manifest over the deterministic artifacts, sorted by file name.
  var rows: seq[string]
  for name in [barsFile, inputFile, signalsFile]:
    let path = dir / name
    if not fileExists(path):
      raise newException(IOError, "missing artifact: " & path)
    rows.add(sha256Hex(readFile(path)) & "  " & name)
  rows.sort()
  result = linesText(rows)

proc sha256OfCanonical*(v: HcjValue): string =
  ## Logical fingerprint of a preamble record: canonical value bytes, no LF.
  sha256Hex(canonical(v))

proc dirProvablyEmpty(dir: string): bool =
  ## False unless the directory is provably empty: an unreadable directory
  ## counts as non-empty so the fail-closed guard refuses it.
  try:
    for _ in walkDir(dir):
      return false
  except OSError:
    return false
  result = true

proc guardOutputDir(dir, inputPath: string) =
  ## writeRun must never overwrite existing data. Refuse (before a single
  ## byte is written) when the output path is a file or a symlink, when the
  ## output directory already holds anything (an existing run or any other
  ## data), or when the input is the run's own `input.hcj.jsonl` -- copying
  ## a file onto itself truncates it to zero bytes.
  if fileExists(dir):
    raise newException(OutputGuardError,
      "output path exists as a file, refusing to overwrite: " & dir)
  if symlinkExists(dir):
    raise newException(OutputGuardError,
      "output path is a symlink, refusing to follow it: " & dir)
  if fileExists(inputPath) and fileExists(dir / inputFile) and
     sameFile(inputPath, dir / inputFile):
    raise newException(OutputGuardError,
      "refusing to replay a run onto its own input: " & inputPath)
  if dirExists(dir) and not dirProvablyEmpty(dir):
    raise newException(OutputGuardError,
      "output directory is not empty, refusing to overwrite: " & dir)

proc buildRunJson(res: CoreResult; bi: BuildInfo; recs: seq[Record]): HcjValue =
  hObj(
    ("bar_count", hInt(res.bars.len)),
    ("build", hObj(
      ("build_time", hStr(bi.buildTime)),
      ("dirty", hBool(bi.dirty)),
      ("nim_version", hStr(bi.nimVersion)),
      ("origin_main_sha", hStr(bi.originMainSha)),
      ("source_ref", hStr(bi.sourceRef)))),
    ("calendar_sha256", hStr(sha256OfCanonical(recs[0].raw))),
    ("code_commit", hStr(bi.codeCommit)),
    ("config_sha256", hStr(sha256OfCanonical(recs[1].raw))),
    ("egress_ip", hNull()),
    ("host", hStr(getEnv("HOSTNAME", "unknown"))),
    ("pid", hInt(getCurrentProcessId())),
    ("run_id", hStr($int(epochTime()) & "-" & $getCurrentProcessId())),
    ("session_date", hStr(res.config.sessionDate)),
    ("signal_count", hInt(res.signals.len)),
    ("started_at", hStr($now())))

proc manifestText(artifacts: openArray[RunArtifact]): string =
  ## CHECKSUMS.sha256 over the exact artifact bytes this run is about to
  ## create. Hashing the bytes in hand instead of reading them back makes
  ## the manifest a function of what we wrote, immune to a mid-write swap;
  ## on a clean run it is byte-identical to `checksums(dir)`.
  var rows: seq[string]
  for a in artifacts:
    rows.add(sha256Hex(a.data) & "  " & a.name)
  rows.sort()
  result = linesText(rows)

when defined(posix):
  proc openat(dirfd: cint; name: cstring; flags: cint;
              mode: cint): cint {.importc, header: "<fcntl.h>".}
    ## POSIX.1-2008 but not exported by Nim 2.2.10's std/posix.
  const
    oDirectory = cint(0o200000) ## Linux `O_DIRECTORY`; not in std/posix.
    oNoFollow = cint(0o400000) ## Linux `O_NOFOLLOW`; not in std/posix.

  proc writeAll(fd: cint; data: string) =
    ## Raw write(2) loop with EINTR retry: short writes are continued, a
    ## hard error aborts (the exclusively created partial artifacts stay
    ## behind, fail-closed: verify reports MISMATCH and a retry is refused).
    var off = 0
    while off < data.len:
      let n = write(fd, addr data[off], data.len - off)
      if n > 0:
        inc off, n
      elif n < 0 and errno == EINTR:
        discard
      else:
        raise newException(IOError, "write failed: " & $strerror(errno))

  proc exclCreateAt(dirfd: cint; name, data: string) =
    ## Create one artifact exclusively inside the pinned run directory.
    ## O_CREAT|O_EXCL is the atomic create-or-fail primitive: a name already
    ## occupied by anything -- a racing writer's file, or a planted symlink,
    ## dangling or not -- fails with EEXIST instead of being followed and
    ## truncated. No existing byte can be modified through this path.
    let fd = openat(dirfd, name,
                    O_WRONLY or O_CREAT or O_EXCL or oNoFollow or O_CLOEXEC,
                    0o644)
    if fd < 0:
      if errno == EEXIST:
        raise newException(OutputGuardError,
          "output artifact already exists, refusing to overwrite: " & name)
      raise newException(OSError,
        "cannot create output artifact " & name & ": " & $strerror(errno))
    try:
      writeAll(fd, data)
      if close(fd) != 0:
        raise newException(IOError,
          "cannot close output artifact " & name & ": " & $strerror(errno))
    except CatchableError:
      discard close(fd)
      raise

  proc acquireOutputDir(dir: string): cint =
    ## Atomically pin `dir` as a real directory and return its fd. mkdir(2)
    ## is the creator: it is exclusive and never follows a trailing symlink,
    ## so it either wins the race outright or reports EEXIST. An existing
    ## path (the documented empty-mktemp-dir case) is accepted only by
    ## opening it as a real directory with O_NOFOLLOW|O_DIRECTORY: a symlink
    ## at the output path is refused, and the fd pins the inode so a later
    ## path swap cannot redirect the artifact writes. Emptiness is
    ## deliberately not re-checked here -- after `guardOutputDir` any such
    ## check would already be stale; the exclusive artifact creation is what
    ## fuses the guard and the use into one atomic sequence.
    var rc = mkdir(dir, 0o755.Mode)
    if rc != 0 and errno == ENOENT:
      # createDir compatibility: only missing intermediate components are
      # auto-created, which is pure creation and cannot destroy anything.
      let parent = parentDir(dir)
      if parent.len > 0:
        createDir(parent)
      rc = mkdir(dir, 0o755.Mode)
    if rc != 0 and errno != EEXIST:
      raise newException(OSError,
        "cannot create output directory " & dir & ": " & $strerror(errno))
    result = open(dir, O_RDONLY or oDirectory or oNoFollow or O_CLOEXEC)
    if result < 0:
      if errno == ELOOP or errno == ENOTDIR:
        raise newException(OutputGuardError,
          "output path is a symlink or not a directory, refusing: " & dir &
          " (" & $strerror(errno) & ")")
      raise newException(OSError,
        "cannot open output directory " & dir & ": " & $strerror(errno))

  proc exclusiveWriteRun(dir: string; artifacts: openArray[RunArtifact]) =
    ## All-or-refuse artifact creation. The first artifact (the input copy)
    ## doubles as the claim on the directory: among any number of concurrent
    ## writeRun calls on the same empty directory exactly one creates it and
    ## the rest fail with EEXIST before writing a single byte. The final
    ## stat pins the run to the directory acquired above: an attacker who
    ## removed or replaced `dir` mid-run left our fd on a dead inode, which
    ## is reported as a refusal instead of a silently lost run.
    let dirfd = acquireOutputDir(dir)
    var stDir: Stat
    try:
      if fstat(dirfd, stDir) != 0:
        raise newException(OSError,
          "cannot stat output directory: " & $strerror(errno))
      for a in artifacts:
        exclCreateAt(dirfd, a.name, a.data)
    finally:
      discard close(dirfd)
    var stPath: Stat
    if stat(dir, stPath) != 0 or stPath.st_ino != stDir.st_ino or
       stPath.st_dev != stDir.st_dev:
      raise newException(OutputGuardError,
        "output directory was replaced or removed during the write, " &
        "refusing: " & dir)

proc writeRun*(dir: string; inputPath: string; res: CoreResult;
               bi: BuildInfo = buildInfo): string =
  ## Fail-closed output: `guardOutputDir` must accept the destination and
  ## the input must load before anything is written, so a refusal can never
  ## leave a partially clobbered run directory behind. On POSIX the write
  ## itself is exclusive (see `exclusiveWriteRun`): anything that appears at
  ## the destination between the guard and the write -- a concurrent
  ## writer's artifact or a planted symlink -- produces EEXIST, not a
  ## truncation. No byte of pre-existing data is ever modified.
  guardOutputDir(dir, inputPath)
  let recs = loadRecords(inputPath)
  if recs.len < 2:
    raise newException(RecordError,
      "input stream too short for a run: " & $recs.len)
  var barLines: seq[string]
  for bar in res.bars: barLines.add(barLine(bar))
  var sigLines: seq[string]
  for s in res.signals: sigLines.add(signalLine(s))
  let inputBytes = readFile(inputPath)
  let barsText = linesText(barLines)
  let sigsText = linesText(sigLines)
  let manifest = manifestText([(name: inputFile, data: inputBytes),
                               (name: barsFile, data: barsText),
                               (name: signalsFile, data: sigsText)])
  let artifacts: seq[RunArtifact] = @[
    (name: inputFile, data: inputBytes),
    (name: barsFile, data: barsText),
    (name: signalsFile, data: sigsText),
    (name: runFile, data: canonical(buildRunJson(res, bi, recs)) & "\n"),
    (name: checksumsFile, data: manifest)]
  when defined(posix):
    exclusiveWriteRun(dir, artifacts)
  else:
    # Non-POSIX keeps the historical non-atomic write path: the guarantees
    # above are POSIX-only. CI and the build gate are Linux.
    createDir(dir)
    for a in artifacts:
      writeFile(dir / a.name, a.data)
  result = dir

proc runVerdictFromException(e: ref CatchableError): Verdict =
  ## Mirrors the CLI's replay/selftest classification so `verify` never
  ## re-labels a failure the producer already classified: a gap still
  ## pending at session_end is INCOMPLETE (exit 4), not a contract breach.
  if e of LateTickError: vInvalid
  elif e of UnresolvedGapError: vIncomplete
  elif e of CoverageError or e of AlignError: vCalendar
  elif e of RecordError or e of HcjError: vContract
  else: vContract

proc artifactsOk(dir: string; res: CoreResult; issues: var seq[string]) =
  ## Artifact-level failures (missing files, byte or manifest mismatch) are
  ## MISMATCH issues. Missing artifacts are reported as issues, never raised:
  ## a broken run directory is exit 6, not a contract crash.
  var allPresent = true
  for name in [barsFile, inputFile, signalsFile]:
    if not fileExists(dir / name):
      issues.add("missing artifact: " & name)
      allPresent = false
  if not fileExists(dir / checksumsFile):
    issues.add("CHECKSUMS.sha256 missing")
  elif allPresent and readFile(dir / checksumsFile) != checksums(dir):
    issues.add("CHECKSUMS.sha256 does not match artifacts")
  var barLines: seq[string]
  for bar in res.bars: barLines.add(barLine(bar))
  if fileExists(dir / barsFile) and readFile(dir / barsFile) != linesText(barLines):
    issues.add("bars.hcj.jsonl differs from replay")
  var sigLines: seq[string]
  for s in res.signals: sigLines.add(signalLine(s))
  if fileExists(dir / signalsFile) and readFile(dir / signalsFile) != linesText(sigLines):
    issues.add("signals.hcj.jsonl differs from replay")

proc strField(parent: HcjValue; key: string; issues: var seq[string]): string =
  ## String field of run.json: absent -> "" (the comparisons catch it),
  ## wrong type -> an issue. Never raises: a malformed run.json field is
  ## INVALID_PROVENANCE, not a contract crash.
  let o = parent.getOpt(key)
  if o.isNone: return ""
  if o.get.kind != hkStr:
    issues.add("run.json " & key & " is not a string: " & kindName(o.get))
    return ""
  result = o.get.strVal

proc provenanceFields(rj: HcjValue; recs: seq[Record]; bi: BuildInfo;
                      issues: var seq[string]) =
  let codeCommit = strField(rj, "code_commit", issues)
  if codeCommit != bi.codeCommit:
    issues.add("code_commit: run=" & codeCommit & " binary=" & bi.codeCommit)
  if bi.hasDevMarker:
    issues.add("binary build info carries a dev default marker")
  let build = rj.getOpt("build")
  if build.isNone or build.get.kind != hkObj:
    issues.add("run.json build object missing")
  else:
    let b = build.get
    let dirtyV = b.getOpt("dirty")
    if dirtyV.isNone:
      issues.add("run.json build.dirty missing")
    elif dirtyV.get.kind != hkBool:
      issues.add("run.json build.dirty is not a bool: " & kindName(dirtyV.get))
    elif dirtyV.get.bval:
      issues.add("run recorded a dirty build")
    if bi.dirty:
      issues.add("binary was built from a dirty tree")
    let nimV = strField(b, "nim_version", issues)
    if nimV != bi.nimVersion:
      issues.add("nim_version: run=" & nimV & " binary=" & bi.nimVersion)
    let srcRef = strField(b, "source_ref", issues)
    let oms = strField(b, "origin_main_sha", issues)
    if srcRef != "main":
      issues.add("build.source_ref is not main: " & srcRef)
    if bi.sourceRef != "main":
      issues.add("verifying binary source_ref is not main: " & bi.sourceRef)
    if srcRef != bi.sourceRef:
      issues.add("build.source_ref: run=" & srcRef & " binary=" & bi.sourceRef)
    if oms != codeCommit:
      issues.add("origin_main_sha != code_commit: " & oms & " vs " & codeCommit)
    if oms != bi.originMainSha:
      issues.add("origin_main_sha: run=" & oms & " binary=" & bi.originMainSha)
  if recs.len >= 2:
    let calHash = strField(rj, "calendar_sha256", issues)
    let cfgHash = strField(rj, "config_sha256", issues)
    if calHash != sha256OfCanonical(recs[0].raw):
      issues.add("calendar_sha256 does not match input record 1")
    if cfgHash != sha256OfCanonical(recs[1].raw):
      issues.add("config_sha256 does not match input record 2")
    let sd = strField(rj, "session_date", issues)
    let cfg = parseConfig(recs[1].raw)
    if sd != cfg.sessionDate:
      issues.add("run.session_date != config.session_date")

proc provenanceOk(dir: string; recs: seq[Record]; bi: BuildInfo;
                  issues: var seq[string]) =
  let runPath = dir / runFile
  if not fileExists(runPath):
    issues.add("run.json missing")
    return
  var rj: HcjValue
  try:
    rj = parseDoc(readFile(runPath))
  except CatchableError as e:
    issues.add("run.json unreadable: " & e.msg)
    return
  if rj.kind != hkObj:
    issues.add("run.json is not an object")
    return
  try:
    provenanceFields(rj, recs, bi, issues)
  except CatchableError as e:
    # Belt and braces: a provenance failure must stay INVALID_PROVENANCE
    # and can never re-classify the verdict as a contract violation.
    issues.add("run.json provenance check failed: " & e.msg)

proc verifyRun*(dir: string; bi: BuildInfo = buildInfo): VerifyResult =
  var recs: seq[Record]
  try:
    recs = loadRecords(dir / inputFile)
  except HcjError as e:
    result.verdict = vContract
    result.issues.add(e.msg)
    return
  except RecordError as e:
    result.verdict = vContract
    result.issues.add(e.msg)
    return
  except IOError as e:
    # The input stream is one of the three checksummed artifacts (§7):
    # a missing or unreadable one is an artifact failure, not a contract
    # violation, and it must not escape as an unhandled exception.
    result.verdict = vMismatch
    result.issues.add("input artifact unreadable: " & e.msg)
    return
  try:
    let res = runCore(recs)
    case res.status
    of rsIncomplete:
      result.verdict = vIncomplete
      result.issues.add("session_end missing: run is INCOMPLETE")
      return
    of rsUnreliableFlag:
      result.verdict = vUnreliable
      result.issues.add("SESSION_FLAG_UNRELIABLE: " & $res.conflicts & "/" & $res.frames)
      return
    of rsOk:
      discard
    var byteIssues: seq[string]
    artifactsOk(dir, res, byteIssues)
    var provIssues: seq[string]
    provenanceOk(dir, recs, bi, provIssues)
    result.issues = byteIssues & provIssues
    if byteIssues.len > 0:
      result.verdict = vMismatch
    elif provIssues.len > 0:
      result.verdict = vInvalidProvenance
    else:
      result.verdict = vMatch
      result.matched = true
  except CatchableError as e:
    result.verdict = runVerdictFromException(e)
    result.issues.add(e.msg)

proc verdictLine*(r: VerifyResult): string =
  case r.verdict
  of vMatch: "VERDICT MATCH provenance=OK"
  of vIncomplete: "VERDICT INCOMPLETE"
  of vUnreliable: "VERDICT INVALID provenance=UNRELIABLE"
  of vInvalid: "VERDICT INVALID provenance=NA"
  of vInvalidProvenance: "VERDICT MISMATCH provenance=INVALID"
  of vMismatch: "VERDICT MISMATCH provenance=OK"
  of vContract: "VERDICT REJECT contract"
  of vCalendar: "VERDICT REJECT calendar"