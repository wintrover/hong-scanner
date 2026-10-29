## Run artifacts, checksums and replay verification (plan §3.4).
##
## Deterministic artifacts (checksummed): input.hcj.jsonl, bars.hcj.jsonl,
## signals.hcj.jsonl. Non-deterministic metadata (run.json) is excluded from
## CHECKSUMS.sha256, but `verify` still reconciles it against the input stream
## and the binary's embedded build info before declaring VERDICT MATCH.
import std/[strutils, os, times, algorithm]
import hcj, records, calendars, bars, engine, replay, digest, binfo

type
  Verdict* = enum
    vMatch, vContract, vCalendar, vIncomplete, vInvalid, vUnreliable,
    vMismatch, vInvalidProvenance

  VerifyResult* = object
    verdict*: Verdict
    issues*: seq[string]
    matched*: bool

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

proc writeRun*(dir: string; inputPath: string; res: CoreResult;
               bi: BuildInfo = buildInfo): string =
  createDir(dir)
  copyFile(inputPath, dir / inputFile)
  var barLines: seq[string]
  for bar in res.bars: barLines.add(barLine(bar))
  writeFile(dir / barsFile, linesText(barLines))
  var sigLines: seq[string]
  for s in res.signals: sigLines.add(signalLine(s))
  writeFile(dir / signalsFile, linesText(sigLines))

  let recs = loadRecords(inputPath)
  let runJson = hObj(
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
  writeFile(dir / runFile, canonical(runJson) & "\n")
  writeFile(dir / checksumsFile, checksums(dir))
  result = dir

proc runVerdictFromException(e: ref CatchableError): Verdict =
  if e of LateTickError: vInvalid
  elif e of CoverageError or e of AlignError: vCalendar
  elif e of RecordError or e of HcjError: vContract
  else: vContract

proc artifactsOk(dir: string; res: CoreResult; issues: var seq[string]) =
  if not fileExists(dir / checksumsFile):
    issues.add("CHECKSUMS.sha256 missing")
  elif readFile(dir / checksumsFile) != checksums(dir):
    issues.add("CHECKSUMS.sha256 does not match artifacts")
  var barLines: seq[string]
  for bar in res.bars: barLines.add(barLine(bar))
  if readFile(dir / barsFile) != linesText(barLines):
    issues.add("bars.hcj.jsonl differs from replay")
  var sigLines: seq[string]
  for s in res.signals: sigLines.add(signalLine(s))
  if readFile(dir / signalsFile) != linesText(sigLines):
    issues.add("signals.hcj.jsonl differs from replay")

proc provenanceOk(dir: string; recs: seq[Record]; bi: BuildInfo;
                  issues: var seq[string]) =
  let runPath = dir / runFile
  if not fileExists(runPath):
    issues.add("run.json missing")
    return
  var rj: HcjValue
  try:
    rj = parseDoc(readFile(runPath))
  except HcjError as e:
    issues.add("run.json unreadable: " & e.msg)
    return
  if rj.kind != hkObj:
    issues.add("run.json is not an object")
    return
  let codeCommit = if rj.has("code_commit"): rj.get("code_commit").asStr else: ""
  if codeCommit != bi.codeCommit:
    issues.add("code_commit: run=" & codeCommit & " binary=" & bi.codeCommit)
  let build = if rj.has("build"): rj.get("build") else: hNull()
  if build.kind != hkObj:
    issues.add("run.json build object missing")
  else:
    if build.has("dirty") and build.get("dirty").asBool:
      issues.add("run recorded a dirty build")
    if bi.dirty:
      issues.add("binary was built from a dirty tree")
    let nimV = if build.has("nim_version"): build.get("nim_version").asStr else: ""
    if nimV != bi.nimVersion:
      issues.add("nim_version: run=" & nimV & " binary=" & bi.nimVersion)
    let srcRef = if build.has("source_ref"): build.get("source_ref").asStr else: ""
    let oms = if build.has("origin_main_sha"): build.get("origin_main_sha").asStr else: ""
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
    let calHash = if rj.has("calendar_sha256"): rj.get("calendar_sha256").asStr else: ""
    let cfgHash = if rj.has("config_sha256"): rj.get("config_sha256").asStr else: ""
    if calHash != sha256OfCanonical(recs[0].raw):
      issues.add("calendar_sha256 does not match input record 1")
    if cfgHash != sha256OfCanonical(recs[1].raw):
      issues.add("config_sha256 does not match input record 2")
    let sd = if rj.has("session_date"): rj.get("session_date").asStr else: ""
    let cfg = parseConfig(recs[1].raw)
    if sd != cfg.sessionDate:
      issues.add("run.session_date != config.session_date")

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