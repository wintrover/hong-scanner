## Recorder contract regression tests (VS-2 recorder slice:
## exclusive create at 0o600, single-writer handle state, ordered
## complete-LF records, the durable-completion finish protocol (data fsync
## -> seal -> seal fsync -> directory fsync -> COMMITTED marker -> marker
## fsync -> directory fsync -> close), syncNow heartbeat, non-destructive
## abnormal termination / INCOMPLETE, fail-closed torn writes, torn-tail
## refusal, and readCommitMarker's VALID/ABSENT/INVALID verdicts — the
## marker is the evidence that distinguishes a durable finish from a
## seal whose durability is unconfirmed).
## Synthetic only: no network, no real market data. Marker timestamps are
## checked for format, never for their wall-clock values. Every case
## works in its own unique temp dir (createTempDir, never removed) —
## nothing here deletes anything or follows anything outside its dir.
## Coverage note: the fsync-failure raise paths (SealUnverifiedError) have
## no synthetic trigger on this platform; that protocol half is pinned
## instead through its observable outcomes — the marker's presence,
## content and the ABSENT/INVALID verdicts it yields.
## Run: nim c -r --path:src tests/test_recorder_contract.nim
import std/[os, strutils, tempfiles, posix]
import hs/[hcj, digest, records, replay, verify, recorder, sub_input]

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

proc caught(body: proc ()): ref CatchableError =
  ## nil when body returned normally; a Defect is reported as a failure
  ## condition instead of crashing the suite.
  result = nil
  try:
    body()
  except CatchableError as e:
    result = e
  except Defect as e:
    result = newException(CatchableError,
      "defect escaped: " & $e.name & ": " & e.msg)

proc checkErr(name: string; body: proc ()) =
  let e = caught(body)
  check(name, e != nil and e of RecorderError)

proc checkTail(name: string; body: proc ()) =
  let e = caught(body)
  check(name, e != nil and e of PartialTailError)

proc checkErrNotTail(name: string; body: proc ()) =
  let e = caught(body)
  check(name, e != nil and e of RecorderError and not (e of PartialTailError))

proc workDir(name: string): string =
  ## Unique, exclusively created scratch dir: a fixed predictable path plus
  ## removeDir would follow a pre-planted symlink and destroy foreign data.
  createTempDir("hs-rec-" & name & "-", "")

proc joinLines(lines: seq[string]): string =
  for l in lines: result.add(l & "\n")

proc validates(recs: seq[Record]): bool =
  try:
    validateRecords(recs)
    result = true
  except CatchableError:
    result = false

proc tryCoreStatus(recs: seq[Record]): tuple[ok: bool; status: RunStatus] =
  ## runCore must answer, never crash the suite.
  try:
    result = (true, runCore(recs).status)
  except CatchableError as e:
    echo "     runCore raised: ", e.msg
    result = (false, rsIncomplete)

proc day(o, c: string): HcjValue = hObj(("close", hStr(c)), ("open", hStr(o)))

let goodCal = hObj(("days", hObj(
  ("2026-10-29", day("09:00:00+09:00", "15:30:00+09:00")))))
let cfgRaw = hObj(("session_date", hStr("2026-10-29")))

proc frame(price: int): HcjValue =
  hObj(("m", hStr("2")), ("price", hInt(price)), ("symbol", hStr("005930")),
       ("t", hStr("09:00:30+09:00")), ("vol", hInt(1)))

# ------------------------------------------------------- private file mode
block privateMode:
  let d = workDir("mode")
  let p = d / "input.hcj.jsonl"
  var r = openRecorder(p)
  check("the recorder file is created 0o600 (user-only)",
        getFilePermissions(p) == {fpUserRead, fpUserWrite})
  discard r.append(kCalendar, goodCal)
  check("the mode stays 0o600 after records land",
        getFilePermissions(p) == {fpUserRead, fpUserWrite})
  r.abandon()

# ------------------------------------------------------ exclusive creation
block exclusiveCreate:
  let d = workDir("xc")
  let fresh = d / "input.hcj.jsonl"
  var r = openRecorder(fresh)
  check("openRecorder creates the file exclusively (empty)",
        fileExists(fresh) and readFile(fresh).len == 0)
  check("a fresh recorder starts at seq 0, unsealed",
        r.seqNo() == 0 and not r.finished())
  checkErr("a second recorder on the live path is refused", proc () =
    discard openRecorder(fresh))
  check("the refusal left the live file untouched", readFile(fresh).len == 0)
  check("the first recorder still owns the file after the refused twin",
        r.append(kCalendar, goodCal) == 1)
  r.abandon()

  let keep = d / "keep.hcj.jsonl"
  writeFile(keep, "previous evidence\n")
  checkErr("an existing non-empty file is refused, not truncated", proc () =
    discard openRecorder(keep))
  check("existing file bytes are untouched",
        readFile(keep) == "previous evidence\n")

  let empty = d / "empty.hcj.jsonl"
  writeFile(empty, "")
  checkErr("an existing empty file is refused too", proc () =
    discard openRecorder(empty))
  checkErr("an existing directory at the log path is refused", proc () =
    discard openRecorder(d))

  let precious = d / "precious.bin"
  writeFile(precious, "do not follow\n")
  let link = d / "link.hcj.jsonl"
  createSymlink(precious, link)
  checkErr("a symlink at the log path is refused, not followed", proc () =
    discard openRecorder(link))
  check("the symlink survived the refusal (no target write via the link)",
        symlinkExists(link) and readFile(precious) == "do not follow\n")

  checkErr("a missing parent directory fails as a clean error", proc () =
    discard openRecorder(d / "no-such-dir" / "x.hcj.jsonl"))

# ------------------------------------- single-writer handle (ref, private)
block handleAliasing:
  ## Recorder is a ref object with private fields: a copied handle aliases
  ## the same state (no forked fd, no private seq counter) and no field is
  ## mutable from outside the module — this suite itself can only observe
  ## state through the accessors and the three state-changing procs.
  let d = workDir("alias")
  let p = d / "input.hcj.jsonl"
  var r = openRecorder(p)
  discard r.append(kCalendar, goodCal)
  let alias = r
  discard alias.append(kConfig, cfgRaw)
  check("an alias sees one seq counter (no forked state)",
        r.seqNo() == 2 and alias.seqNo() == 2)
  r.abandon()
  checkErr("the closed state is shared through every alias", proc () =
    discard alias.append(kPong, hNull()))
  checkErr("finish through any alias is refused too", proc () =
    discard alias.finish())

# ---------------------------------------------- write order / LF records
block writeOrder:
  let d = workDir("order")
  let path = d / "input.hcj.jsonl"
  let exotic = hObj(
    ("esc", hStr("nl:\n tab:\t q:\" bs:\\ ctl:\x01 kr:가")),
    ("big", hInt(9007199254740991)))
  let items: seq[tuple[k: Kind, raw: HcjValue]] = @[
    (kCalendar, goodCal), (kConfig, cfgRaw), (kWsFrame, frame(100)),
    (kPong, exotic)]
  var r = openRecorder(path)
  var seqs: seq[int]
  for it in items:
    seqs.add(r.append(it.k, it.raw))
  check("seq numbers are assigned by the recorder in write order",
        seqs == @[1, 2, 3, 4] and r.seqNo() == 4)
  var expected: seq[string]
  for i, it in items:
    expected.add(makeRecordLine(i + 1, it.k, it.raw))
  check("file bytes are exactly the canonical lines in append order",
        readFile(path) == joinLines(expected))
  check("the in-progress file ends with LF", readFile(path).endsWith("\n"))
  check("a raw \\n inside a value cannot split a record (canonical escapes it)",
        readHcjTextLines(path).len == 4)
  let recs = loadRecords(path)
  check("recorded stream round-trips kinds, seqs and raw values",
        recs.len == 4 and recs[2].kind == kWsFrame and
        recs[3].raw.get("esc").asStr == "nl:\n tab:\t q:\" bs:\\ ctl:\x01 kr:가" and
        recs[3].raw.get("big").asInt == 9007199254740991)
  checkErr("the caller cannot append session_end (finish owns the seal)",
           proc () = discard r.append(kSessionEnd, hNull()))
  let mid = readRecorderFile(path)
  check("an in-progress file reads back its complete records, unsealed",
        mid.len == 4 and not isSealed(mid))
  r.abandon()

# ------------------------------------------ explicit finish (seal + fsync)
block finishAndFsync:
  let d = workDir("finish")
  let path = d / "input.hcj.jsonl"
  var r = openRecorder(path)
  discard r.append(kCalendar, goodCal)
  discard r.append(kConfig, cfgRaw)
  discard r.append(kWsFrame, frame(100))
  check("finish returns the sealed record count", r.finish() == 4)
  check("finish marks the recorder sealed, not failed",
        r.finished() and r.seqNo() == 4 and not r.failed())
  let items: seq[tuple[k: Kind, raw: HcjValue]] = @[
    (kCalendar, goodCal), (kConfig, cfgRaw), (kWsFrame, frame(100)),
    (kSessionEnd, hNull())]
  var expected: seq[string]
  for i, it in items:
    expected.add(makeRecordLine(i + 1, it.k, it.raw))
  check("finish appended the session_end seal as the last LF line",
        readFile(path) == joinLines(expected))
  let recs = loadRecords(path)
  check("the sealed stream is sealed and passes the records contract",
        isSealed(recs) and validates(recs))
  let core = tryCoreStatus(recs)
  check("core classifies the sealed stream as rsOk, not INCOMPLETE",
        core.ok and core.status == rsOk)
  checkErr("append after finish is refused", proc () =
    discard r.append(kPong, hNull()))
  checkErr("finish after finish is refused", proc () = discard r.finish())
  checkErr("abandon after finish is refused", proc () = r.abandon())
  check("refused post-finish calls changed no byte",
        readFile(path) == joinLines(expected))

# --------------------------------- torn write: poison, forbid, preserve
block tornWritePoison:
  ## Force a real partial write with RLIMIT_FSIZE (Linux): the kernel
  ## accepts bytes up to the limit (a torn record) and the next write fails
  ## with EFBIG (SIGXFSZ ignored). The recorder must poison itself and
  ## refuse every further append/finish — no seal may land behind a torn
  ## line — while the torn bytes stay on disk verbatim.
  const RLIMIT_FSIZE = cint(1) # Linux; std/posix exports only NOFILE/STACK
  let d = workDir("torn")
  let p = d / "input.hcj.jsonl"
  let line1 = makeRecordLine(1, kCalendar, goodCal) & "\n"
  let line2 = makeRecordLine(2, kConfig, cfgRaw) & "\n"
  var r = openRecorder(p)
  discard r.append(kCalendar, goodCal) # one complete record first
  var old: RLimit
  discard getrlimit(RLIMIT_FSIZE, old)
  let oldHandler = signal(SIGXFSZ, SIG_IGN) # default action kills the process
  var lim = RLimit(rlim_cur: line1.len + 8, rlim_max: old.rlim_max)
  discard setrlimit(RLIMIT_FSIZE, lim)
  let e = caught(proc () = discard r.append(kConfig, cfgRaw))
  discard setrlimit(RLIMIT_FSIZE, old) # restore before anything else
  discard signal(SIGXFSZ, oldHandler)
  check("a write that fails partway raises RecorderError",
        e != nil and e of RecorderError)
  check("the recorder is poisoned after the torn write", r.failed())
  checkErr("append after a torn write is refused", proc () =
    discard r.append(kConfig, cfgRaw))
  checkErr("finish after a torn write is refused (no seal behind a torn line)",
           proc () = discard r.finish())
  let torn = readFile(p)
  check("the torn record is preserved on disk (partial bytes, no LF)",
        torn == line1 & line2[0 .. 7] and not torn.endsWith("\n"))
  checkTail("inspecting the torn file refuses as PartialTailError",
            proc () = discard readRecorderFile(p))
  check("inspection preserved the torn bytes verbatim", readFile(p) == torn)
  let e2 = caught(proc () = r.abandon())
  check("abandon still tears down a poisoned recorder (it writes nothing)",
        e2 == nil)
  check("teardown changed no byte of the torn file", readFile(p) == torn)

# --------------------- durable completion: seal + COMMITTED marker
block commitMarkerDurability:
  ## The durable-completion contract, observed through its on-disk
  ## outcomes: a real finish() creates the sibling COMMITTED marker whose
  ## run_id/seq/sha256 match the sealed log, and a sealed file *without* a
  ## marker — the state a failed fsync or a crash mid-protocol leaves, and
  ## the state the old "suspect file" test pinned — stays byte-identical
  ## to the durable log at the file level, so the marker is the ONLY
  ## distinguishing evidence between "durable finish" and "termination
  ## recorded, durability unconfirmed".

  proc markerFor(path: string): HcjValue =
    ## The marker content finish() must produce for `path`, computed the
    ## way an external verifier would: from the log's own bytes.
    hObj(("run_id", hStr(lastPathPart(parentDir(path)))),
         ("schema", hStr(commitMarkerSchema)),
         ("seq", hInt(loadRecords(path).len)),
         ("sha256", hStr(sha256Hex(readFile(path)))),
         ("t", hStr("2026-10-29T15:30:00+09:00")))

  let d = workDir("commit")
  let durablePath = d / "input.hcj.jsonl"
  var a = openRecorder(durablePath)
  discard a.append(kCalendar, goodCal)
  discard a.append(kConfig, cfgRaw)
  check("the durable recorder finished its protocol",
        a.finish() == 3 and a.finished() and not a.failed())
  let markerPath = durablePath & ".committed"
  check("finish created the sibling COMMITTED marker", fileExists(markerPath))
  let markerLine = readFile(markerPath)
  check("the marker is one canonical HCJ line + LF",
        markerLine == canonical(parseDoc(markerLine)) & "\n")
  let m = parseDoc(markerLine)
  check("the marker carries exactly the declared schema fields",
        m.has("run_id") and m.has("schema") and m.has("seq") and
        m.has("sha256") and m.has("t") and m.pairs.len == 5)
  check("the marker names the log's run directory as run_id",
        m.get("run_id").asStr == lastPathPart(parentDir(durablePath)))
  check("the marker pins the schema version",
        m.get("schema").asStr == commitMarkerSchema)
  check("the marker's seq is the sealed record count, seal included",
        m.get("seq").asInt == 3)
  check("the marker's sha256 matches the sealed log bytes",
        m.get("sha256").asStr == sha256Hex(readFile(durablePath)))
  check("the marker's t is an ISO 8601 timestamp with a numeric offset",
        validIso8601Offset(parseDoc(markerLine).get("t").asStr))
  let cm = readCommitMarker(durablePath)
  check("readCommitMarker verdicts the finished log VALID",
        cm.status == csValid and cm.reason == "")
  check("the VALID verdict carries the marker's own fields",
        cm.runId == lastPathPart(parentDir(durablePath)) and cm.seq == 3 and
        cm.sha256 == sha256Hex(readFile(durablePath)))
  check("finish refused to run twice on the sealed recorder",
        caught(proc () = discard a.finish()) != nil)
  checkErr("append after finish is still refused", proc () =
    discard a.append(kPong, hNull()))

  # The old pinned hazard, now resolvable: a sealed file with no marker —
  # exactly what a failed fsync / crashed finish leaves — is byte-level
  # indistinguishable from the durable log, but the marker verdicts split
  # them.
  let suspectPath = d / "suspect.hcj.jsonl"
  var b = openRecorder(suspectPath)
  discard b.append(kCalendar, goodCal)
  discard b.append(kConfig, cfgRaw)
  b.abandon() # crash before any seal
  writeFile(suspectPath, readFile(suspectPath) &
            makeRecordLine(3, kSessionEnd, hNull()) & "\n")
  check("the suspect file is byte-identical to the durable one",
        readFile(suspectPath) == readFile(durablePath))
  let rd = readRecorderFile(durablePath)
  let rs = readRecorderFile(suspectPath)
  check("file-level inspection still cannot tell them apart",
        isSealed(rd) and isSealed(rs) and validates(rd) and validates(rs))
  let cd = tryCoreStatus(rd)
  let cs = tryCoreStatus(rs)
  check("the core still approves both equally on the bytes alone",
        cd.ok and cs.ok and cd.status == rsOk and cs.status == rsOk)
  let vd = readCommitMarker(durablePath)
  let vs = readCommitMarker(suspectPath)
  check("the marker verdict separates them: VALID vs ABSENT",
        vd.status == csValid and vs.status == csAbsent)
  check("ABSENT states the durability boundary",
        "no commit marker file" in vs.reason)

  # A marker already at the marker path is prior evidence: finish refuses
  # instead of overwriting it, and the planted bytes survive.
  let foreignPath = d / "foreign.hcj.jsonl"
  var c = openRecorder(foreignPath)
  discard c.append(kCalendar, goodCal)
  writeFile(foreignPath & ".committed",
            canonical(markerFor(foreignPath)) & "\n")
  let planted = readFile(foreignPath & ".committed")
  checkErr("finish refuses a pre-existing marker instead of overwriting",
           proc () = discard c.finish())
  check("the refusal left the planted marker untouched",
        readFile(foreignPath & ".committed") == planted)
  check("the refused finish left the recorder closed and unfinished",
        not c.finished() and caught(proc () = c.abandon()) != nil)

# ------------------------------------- syncNow: heartbeat without a seal
block syncNowHeartbeat:
  let d = workDir("syncnow")
  let path = d / "input.hcj.jsonl"
  var r = openRecorder(path)
  discard r.append(kCalendar, goodCal)
  let before = readFile(path)
  syncNow(r)
  check("syncNow wrote nothing — no seal, no marker, same bytes",
        readFile(path) == before and
        not fileExists(path & ".committed"))
  discard r.append(kConfig, cfgRaw)
  let mid = readRecorderFile(path)
  check("the recorder stays usable after syncNow (no poisoning)",
        r.seqNo() == 2 and mid.len == 2 and not isSealed(mid))
  r.abandon()
  checkErr("syncNow after abandon is refused", proc () = syncNow(r))
  var f = openRecorder(d / "finished.hcj.jsonl")
  discard f.append(kCalendar, goodCal)
  discard f.finish()
  checkErr("syncNow after finish is refused", proc () = syncNow(f))

# ----------------------- readCommitMarker: schema + log cross-checks
block commitMarkerVerdicts:
  let d = workDir("verdicts")
  let path = d / "input.hcj.jsonl"
  var r = openRecorder(path)
  discard r.append(kCalendar, goodCal)
  discard r.append(kConfig, cfgRaw)
  discard r.finish()
  let markerPath = path & ".committed"
  let goodMarker = readFile(markerPath)

  proc plantMarker(content: string) =
    writeFile(markerPath, content)

  proc verdictIs(status: CommitStatus; needle: string) =
    let cm = readCommitMarker(path)
    if cm.status != status:
      check("verdict " & $status & " (" & needle & ")", false)
      echo "     got ", $cm.status, ": ", cm.reason
    else:
      check("verdict " & $status & " (" & needle & ")",
            needle.len == 0 or needle in cm.reason)

  verdictIs(csValid, "")

  # A log tampered after the marker: torn tail -> the marker cannot
  # honestly match -> INVALID with the reason preserved.
  plantMarker(goodMarker)
  let good = readFile(path)
  writeFile(path, good & "{")
  verdictIs(csInvalid, "not a readable record stream")
  writeFile(path, good)

  # A marker whose fields disagree with the log, one field at a time.
  proc mutateField(name: string; value: HcjValue) =
    var m = parseDoc(goodMarker)
    for p in m.pairs.mitems:
      if p.k == name: p.v = value
    plantMarker(canonical(m) & "\n")

  plantMarker(goodMarker)
  mutateField("sha256", hStr(repeat('0', 64)))
  verdictIs(csInvalid, "sha256 does not match")
  plantMarker(goodMarker)
  mutateField("seq", hInt(7))
  verdictIs(csInvalid, "seq does not match")
  plantMarker(goodMarker)
  mutateField("run_id", hStr("elsewhere"))
  verdictIs(csInvalid, "run_id does not name")
  plantMarker(goodMarker)
  mutateField("schema", hStr("hong-scanner-commit/2"))
  verdictIs(csInvalid, "schema is not")
  plantMarker(goodMarker)
  mutateField("t", hStr("2026-10-29T15:30:00"))
  verdictIs(csInvalid, "not an ISO 8601")
  plantMarker(goodMarker)
  mutateField("seq", hInt(0))
  verdictIs(csInvalid, "must be >= 1")
  plantMarker(goodMarker)
  mutateField("sha256", hStr("DEADBEEF"))
  verdictIs(csInvalid, "64 lowercase hex")

  var m = parseDoc(goodMarker)
  m.pairs.add(("extra", hStr("x")))
  plantMarker(canonical(m) & "\n")
  verdictIs(csInvalid, "unknown marker field: extra")

  m = parseDoc(goodMarker)
  var keep: seq[HcjPair]
  for p in m.pairs:
    if p.k != "t": keep.add(p)
  m.pairs = keep
  plantMarker(canonical(m) & "\n")
  verdictIs(csInvalid, "missing field: t")

  m = parseDoc(goodMarker)
  for p in m.pairs.mitems:
    if p.k == "seq": p.v = hStr("3")
  plantMarker(canonical(m) & "\n")
  verdictIs(csInvalid, "seq is not an integer")

  plantMarker("{\"kind\": \"marker\", ")
  verdictIs(csInvalid, "not valid HCJ JSON")

  plantMarker(canonical(hNull()))
  verdictIs(csInvalid, "not a JSON object")

  # A marker whose log is missing entirely: INVALID, not ABSENT — the
  # marker refers to a log that is not there (no deletion involved: the
  # log is simply never created at this path).
  let ghost = d / "ghost.hcj.jsonl"
  writeFile(ghost & ".committed",
            canonical(hObj(("run_id", hStr(lastPathPart(d))),
                           ("schema", hStr(commitMarkerSchema)),
                           ("seq", hInt(3)), ("sha256", hStr(repeat('a', 64))),
                           ("t", hStr("2026-10-29T15:30:00+09:00")))) & "\n")
  let ghostV = readCommitMarker(ghost)
  check("a marker without its log is INVALID, not ABSENT",
        ghostV.status == csInvalid and
        "not a readable record stream" in ghostV.reason)

  # ABSENT needs no marker file at all (the pre-marker contract shape).
  let bare = d / "bare.hcj.jsonl"
  var b = openRecorder(bare)
  discard b.append(kCalendar, goodCal)
  b.abandon()
  let bareV = readCommitMarker(bare)
  check("a log with no marker file is ABSENT",
        bareV.status == csAbsent and
        "no commit marker file" in bareV.reason)

# --------------------- abnormal termination: non-destructive / INCOMPLETE
block abnormalTermination:
  let d = workDir("abrupt")
  let path = d / "input.hcj.jsonl"
  var r = openRecorder(path)
  discard r.append(kCalendar, goodCal)
  discard r.append(kConfig, cfgRaw)
  discard r.append(kWsFrame, frame(100))
  discard r.append(kWsFrame, frame(101))
  let before = readFile(path)
  r.abandon()
  check("abandon leaves the recorder unsealed and not failed",
        not r.finished() and not r.failed())
  checkErr("append after abandon is refused", proc () =
    discard r.append(kPong, hNull()))
  checkErr("finish after abandon is refused", proc () = discard r.finish())
  check("abnormal termination is non-destructive on disk",
        readFile(path) == before and readFile(path).endsWith("\n"))
  let recs = loadRecords(path)
  check("records written before the crash survive complete and parseable",
        recs.len == 4 and recs[3].seq == 4)
  check("the crashed stream is unsealed and valid (INCOMPLETE, not REJECT)",
        not isSealed(recs) and validates(recs))
  let core = tryCoreStatus(recs)
  check("core classifies the crashed stream as rsIncomplete",
        core.ok and core.status == rsIncomplete)
  let v = verifyRun(d)
  check("verify maps the crashed stream to INCOMPLETE exit 4",
        v.verdict == vIncomplete and exitCode(v.verdict) == 4)

  let e = workDir("abrupt-empty") / "input.hcj.jsonl"
  var r2 = openRecorder(e)
  r2.abandon()
  check("a recorder abandoned before any record leaves a 0-byte file",
        readFile(e).len == 0)
  let emptyRecs = readRecorderFile(e)
  check("a 0-byte recorder file reads as zero records, unsealed",
        emptyRecs.len == 0 and not isSealed(emptyRecs))

# ------------------------------- torn tail: preserve the original, fail
block partialTail:
  let d = workDir("tail")
  let l1 = makeRecordLine(1, kCalendar, goodCal)
  let l2 = makeRecordLine(2, kConfig, cfgRaw)

  proc tailCase(name, torn: string) =
    ## A complete two-record prefix plus a torn (not LF-terminated) tail:
    ## discovery must refuse, classify as PartialTailError and preserve the
    ## original bytes verbatim — never truncate back to the last good line.
    let p = d / name
    writeFile(p, l1 & "\n" & l2 & "\n" & torn)
    let before = readFile(p)
    checkTail("torn tail refused as PartialTailError: " & name,
              proc () = discard readRecorderFile(p))
    check("original bytes preserved verbatim after the refusal: " & name,
          readFile(p) == before)

  tailCase("json-cut", "{\"kind\":\"pong\",\"raw\":{\"x\":1")
  tailCase("complete-line-no-lf", "{\"kind\":\"pong\",\"raw\":null,\"seq\":3}")
  tailCase("garbage", "not json")
  tailCase("one-byte", "{")

  let whole = d / "whole-torn"
  writeFile(whole, "only a torn line")
  checkTail("a file with no complete record at all is a PartialTailError",
            proc () = discard readRecorderFile(whole))
  check("torn-only file preserved verbatim",
        readFile(whole) == "only a torn line")

  let crlf = d / "crlf.hcj.jsonl"
  writeFile(crlf, l1 & "\r\n")
  checkErrNotTail("CRLF discipline violation is RecorderError, not a tail",
                 proc () = discard readRecorderFile(crlf))
  let gap = d / "seq-gap.hcj.jsonl"
  writeFile(gap, l1 & "\n" & makeRecordLine(5, kPong, hNull()) & "\n")
  checkErrNotTail("seq discontinuity is RecorderError, not a tail",
                 proc () = discard readRecorderFile(gap))
  checkErr("a missing recorder file is RecorderError",
           proc () = discard readRecorderFile(d / "not-there"))

# ------------------- byte-exact reuse of the records.nim envelope
block fixtureRoundTrip:
  ## The smoke fixture is synthetic (tools/gen_fixture.nim via
  ## makeRecordLine): re-recording its (kind, raw) pairs must reproduce it
  ## byte-for-byte — the recorder has no serialization of its own — and
  ## replay rsOk.
  let srcPath = "fixtures/smoke/input.hcj.jsonl"
  let srcLines = readHcjTextLines(srcPath)
  var pairs: seq[tuple[k: Kind, raw: HcjValue]]
  for rec in loadRecords(srcPath):
    pairs.add((rec.kind, rec.raw))
  let d = workDir("roundtrip")
  let path = d / "input.hcj.jsonl"
  var r = openRecorder(path)
  for it in pairs[0 ..< pairs.len - 1]: # everything except the fixture's seal
    discard r.append(it.k, it.raw)
  check("finish seals the replayed fixture stream at the same count",
        r.finish() == pairs.len)
  check("re-recorded stream is byte-identical to the fixture",
        readFile(path) == joinLines(srcLines))
  let core = tryCoreStatus(loadRecords(path))
  check("re-recorded fixture replays as rsOk",
        core.ok and core.status == rsOk)

echo ""
echo passes, " passed, ", failures, " failed"
if failures > 0: quit(1)
