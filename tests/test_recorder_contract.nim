## Recorder contract regression tests (VS-2 smallest recorder slice:
## exclusive create at 0o600, single-writer handle state, ordered
## complete-LF records, explicit finish + fsync, non-destructive abnormal
## termination / INCOMPLETE, fail-closed torn writes, torn-tail refusal,
## and the pinned — NOT solved — seal/durability ambiguity).
## Synthetic only: no network, no real market data, no wall clock. Every
## case works in its own unique temp dir (createTempDir, never removed) —
## nothing here deletes anything or follows anything outside its dir.
## Coverage note: the fsync-failure raise path (SealUnverifiedError) has no
## synthetic trigger on this platform; that ambiguity is pinned here
## instead as a byte-identical indistinguishability fact.
## Run: nim c -r --path:src tests/test_recorder_contract.nim
import std/[os, strutils, tempfiles, posix]
import hs/[hcj, records, replay, verify, recorder]

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

# --------------------------- seal vs durable completion (pinned limit)
block sealAmbiguityLimit:
  ## Pinned as an executable fact, NOT solved: finish() writes the
  ## session_end bytes before it fsyncs, so a failed fsync leaves a file
  ## that looks normally sealed — byte-identical to a durable finish. No
  ## inspection this module offers (readRecorderFile, isSealed, the core)
  ## can tell the two apart, this module produces no separate
  ## durable-completion evidence and no atomic completion protocol is
  ## claimed: approving a sealed file as a complete run needs evidence from
  ## outside this module.
  let d = workDir("seal-ambiguity")
  let durablePath = d / "durable.hcj.jsonl"
  var a = openRecorder(durablePath)
  discard a.append(kCalendar, goodCal)
  discard a.append(kConfig, cfgRaw)
  check("the durable recorder finished its protocol",
        a.finish() == 3 and a.finished() and not a.failed())

  let suspectPath = d / "suspect.hcj.jsonl"
  var b = openRecorder(suspectPath)
  discard b.append(kCalendar, goodCal)
  discard b.append(kConfig, cfgRaw)
  b.abandon() # crash before any seal
  # The on-disk state a failed fsync leaves behind: seal bytes present,
  # durability unknown.
  writeFile(suspectPath, readFile(suspectPath) &
            makeRecordLine(3, kSessionEnd, hNull()) & "\n")

  check("the suspect file is byte-identical to the durable one",
        readFile(suspectPath) == readFile(durablePath))
  let rd = readRecorderFile(durablePath)
  let rs = readRecorderFile(suspectPath)
  check("no file-level inspection in this module tells them apart",
        isSealed(rd) and isSealed(rs) and validates(rd) and validates(rs))
  let cd = tryCoreStatus(rd)
  let cs = tryCoreStatus(rs)
  check("the core would approve both equally (the pinned hazard)",
        cd.ok and cs.ok and cd.status == rsOk and cs.status == rsOk)

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
