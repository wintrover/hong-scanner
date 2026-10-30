## rest_resp fail-closed contract tests (undeclared/legacy payloads).
##
## The validated acceptance path for schema-conforming rest_resp records
## lives in test_rest_resp_contract.nim (REPLAY_CONTRACT §12.1: declared
## request scope, page chain, preserved body bytes). These tests pin the
## complementary rule: a rest_resp that does not parse against that declared
## schema -- legacy payloads, empty objects, wrong types -- still rejects the
## run (exit 2) at its own seq; nothing is silently accepted. Streams without
## rest_resp keep their exact VS-1 behavior. Synthetic payloads only: no
## network, no vendor data, no wall clock.
## Run: nim c -r --path:src tests/test_rest_failure_contract.nim
import std/[os, strutils, tempfiles]
import hs/[hcj, records, calendars, replay, verify, binfo]

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

proc rejectsWith(name, needle: string; body: proc ()) =
  ## The body must raise a RecordError whose message mentions the needle:
  ## the rejection must be explicit and self-explaining, not a silent crash
  ## or an unrelated exception class.
  var msg = ""
  var raised = false
  try:
    body()
  except RecordError as e:
    raised = true
    msg = e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name, raised and needle in msg)

proc writeStream(name: string; lines: seq[string]): string =
  ## dir/input.hcj.jsonl with LF discipline; returns the run dir.
  result = createTempDir("hs-rest-" & name & "-", "")
  var content = ""
  for l in lines: content.add(l & "\n")
  writeFile(result / inputFile, content)

proc day(o, c: string): HcjValue =
  hObj(("close", hStr(c)), ("open", hStr(o)))

proc calRaw(): HcjValue =
  hObj(("days", hObj(
    ("2026-10-29", day("09:00:00+09:00", "15:30:00+09:00")))))

proc cfgRaw(): HcjValue = hObj(("session_date", hStr("2026-10-29")))

proc tickRaw(sym, t: string; price, vol: int64): HcjValue =
  hObj(("m", hStr("2")), ("price", hInt(price)), ("symbol", hStr(sym)),
       ("t", hStr(t)), ("vol", hInt(vol)))

proc baseLines(): seq[string] =
  ## Minimal valid session: two symbols, two bars each, normal close.
  result = @[
    makeRecordLine(1, kCalendar, calRaw()),
    makeRecordLine(2, kConfig, cfgRaw()),
    makeRecordLine(3, kWsFrame, tickRaw("005930", "09:00:00+09:00", 10000, 100)),
    makeRecordLine(4, kWsFrame, tickRaw("000660", "09:00:00+09:00", 20000, 500)),
    makeRecordLine(5, kWsFrame, tickRaw("005930", "09:03:00+09:00", 10100, 200)),
    makeRecordLine(6, kWsFrame, tickRaw("000660", "09:03:00+09:00", 20100, 700)),
    makeRecordLine(7, kSessionEnd, hNull())]

proc withRecAt(lines: seq[string]; idx: int; k: Kind; raw: HcjValue): seq[string] =
  ## Insert one record at position idx (0-based) and renumber seq 1..N.
  var recs: seq[tuple[k: Kind, raw: HcjValue]]
  for i, l in lines:
    let r = parseRecord(l, i + 1)
    recs.add((r.kind, r.raw))
  recs.insert((k, raw), idx)
  for i, p in recs:
    result.add(makeRecordLine(i + 1, p.k, p.raw))

proc coreBytes(lines: seq[string]): string =
  let res = runCore(loadRecords(writeStream("core", lines) / inputFile))
  for b in res.bars: result.add(barLine(b) & "\n")
  result.add("--\n")
  for s in res.signals: result.add(signalLine(s) & "\n")

proc runOf(name: string; lines: seq[string]): CoreResult =
  runCore(loadRecords(writeStream(name, lines) / inputFile))

# ------------------------------------------------------ no rest_resp (regression)
block noRestRegression:
  let res = runCore(loadRecords("fixtures/smoke/input.hcj.jsonl"))
  check("committed fixture (no rest_resp) is still rsOk", res.status == rsOk)
  check("committed fixture bars/signals unchanged",
        res.bars.len == 22 and res.signals.len == 8)
  check("synthetic base stream (no rest_resp) is rsOk",
        runOf("synth", baseLines()).status == rsOk)

block noRestNoEffect:
  ## Diagnostic insertions still change no output byte: the rejection is
  ## scoped to rest_resp, not to the NO_EFFECT diagnostic kinds.
  let plain = coreBytes(baseLines())
  check("NO_EFFECT: pong insertion changes no output byte",
        plain == coreBytes(withRecAt(baseLines(), 2, kPong, hNull())))
  check("NO_EFFECT: ws_conn insertion changes no output byte",
        plain == coreBytes(withRecAt(baseLines(), 5, kWsConn,
          hObj(("state", hStr("reconnecting"))))))

# ------------------------------------------------------ rest_resp is rejected
block restRespRejected:
  ## Inserted at index 6: the REST attempt happened during the session and
  ## the stream still closes with session_end. Before this contract the same
  ## stream was rsOk.
  proc rejected(name: string; raw: HcjValue) =
    let lines = withRecAt(baseLines(), 6, kRestResp, raw)
    rejectsWith(name, "rest_resp", proc () =
      discard runOf("rest", lines))

  rejected("success-shaped rest_resp is still REJECT (format unverified)",
    hObj(("body", hArr()), ("http_status", hInt(200)), ("status", hStr("ok"))))
  rejected("HTTP error rest_resp is REJECT",
    hObj(("http_status", hInt(503)), ("status", hStr("error"))))
  rejected("vendor error rest_resp is REJECT",
    hObj(("http_status", hInt(200)), ("status", hStr("error")),
         ("vendor_code", hStr("E1")), ("vendor_msg", hStr("rejected"))))
  rejected("timeout rest_resp is REJECT",
    hObj(("error", hStr("ETIMEDOUT")), ("status", hStr("timeout"))))
  rejected("empty-object rest_resp is REJECT", hObj())
  rejected("null rest_resp raw is REJECT", hNull())
  rejected("string rest_resp raw is REJECT", hStr("ok"))
  rejected("array rest_resp raw is REJECT", hArr(hInt(200)))

block restRespMessage:
  let lines = withRecAt(baseLines(), 6, kRestResp, hObj(("status", hStr("ok"))))
  var msg = ""
  try:
    discard runOf("msg", lines)
  except RecordError as e:
    msg = e.msg
  check("rejection names the record and its seq",
        "rest_resp" in msg and "seq 7" in msg)
  check("rejection states the unverified wire format (not hidden)",
        "unverified" in msg)

# ------------------------------------------------------ position refutations
block restPosition:
  rejectsWith("rest_resp after the preamble is REJECT", "rest_resp", proc () =
    discard runOf("pos-pre", withRecAt(baseLines(), 2, kRestResp, hObj())))
  rejectsWith("rest_resp mid-stream is REJECT", "rest_resp", proc () =
    discard runOf("pos-mid", withRecAt(baseLines(), 4, kRestResp, hObj())))
  var afterEnd = baseLines()
  afterEnd.add(makeRecordLine(afterEnd.len + 1, kRestResp, hObj()))
  rejectsWith("rest_resp after session_end is REJECT", "session_end", proc () =
    discard runOf("pos-after", afterEnd))
  let noEnd = withRecAt(baseLines(), 6, kRestResp, hObj())[0 .. ^2]
  rejectsWith("rest_resp without session_end is REJECT (not INCOMPLETE, " &
              "never success)", "rest_resp", proc () =
    discard runOf("pos-noend", noEnd))

# ------------------------------------------------------ verdict classification
block restVerdict:
  let lines = withRecAt(baseLines(), 6, kRestResp,
    hObj(("http_status", hInt(503)), ("status", hStr("error"))))
  let v = verifyRun(writeStream("verdict", lines))
  check("verify classifies a rest_resp stream as REJECT exit 2",
        v.verdict == vContract and exitCode(v.verdict) == 2 and not v.matched)
  check("verify prints VERDICT REJECT contract",
        verdictLine(v) == "VERDICT REJECT contract")
  check("verify surfaces the rest_resp reason as an issue",
        v.issues.len == 1 and "rest_resp" in v.issues[0])

  # Control: the same stream without rest_resp is a full MATCH.
  let okInfo = BuildInfo(codeCommit: "abc123", sourceRef: "main",
    originMainSha: "abc123", dirty: false, nimVersion: NimVersion,
    buildTime: "t")
  let srcDir = writeStream("good", baseLines())
  let inPath = srcDir / inputFile
  let runDir = srcDir / "run"
  discard writeRun(runDir, inPath, runCore(loadRecords(inPath)), okInfo)
  let g = verifyRun(runDir, okInfo)
  check("control: same stream without rest_resp is MATCH provenance=OK",
        g.verdict == vMatch and g.matched)

echo ""
echo passes, " passed, ", failures, " failed"
if failures > 0: quit(1)
