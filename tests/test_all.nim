## VS-1 contract tests. Synthetic inputs only: no network, no real market
## data, no wall clock. Run: nimble test
import std/[os, strutils, tables, tempfiles]
import hs/[hcj, digest, records, calendars, bars, engine, replay, verify, binfo]

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

proc checkRaises(name: string; body: proc ()) =
  var raised = false
  try:
    body()
  except CatchableError:
    raised = true
  check(name, raised)

proc joinLines(lines: seq[string]): string =
  for l in lines: result.add(l & "\n")

proc workDir(name: string): string =
  createTempDir("hs-test-" & name & "-", "")

proc materialize(dir, name: string; lines: seq[string]): string =
  result = dir / name
  writeFile(result, joinLines(lines))

proc recLines(pairs: seq[tuple[k: Kind, raw: HcjValue]]): seq[string] =
  for i, p in pairs:
    result.add(makeRecordLine(i + 1, p.k, p.raw))

proc pairsOf(lines: seq[string]): seq[tuple[k: Kind, raw: HcjValue]] =
  let path = materialize(workDir("pairs-src"), "in.hcj.jsonl", lines)
  for r in loadRecords(path): result.add((r.kind, r.raw))

proc coreBytes(pairs: seq[tuple[k: Kind, raw: HcjValue]]): string =
  let path = materialize(workDir("corebytes"), "in.hcj.jsonl", recLines(pairs))
  let res = runCore(loadRecords(path))
  for b in res.bars: result.add(barLine(b) & "\n")
  result.add("--\n")
  for s in res.signals: result.add(signalLine(s) & "\n")

proc findTick(pairs: seq[tuple[k: Kind, raw: HcjValue]];
              sym, tPrefix: string): int =
  for i, p in pairs:
    if p.k == kWsFrame and p.raw.get("symbol").asStr == sym and
       p.raw.get("t").asStr.startsWith(tPrefix):
      return i
  -1

proc setField(raw: HcjValue; key: string; v: HcjValue) =
  for p in raw.pairs.mitems:
    if p.k == key: p.v = v

proc calRaw(): HcjValue =
  hObj(("days", hObj(
    ("2026-10-29", hObj(("close", hStr("15:30:00+09:00")),
                        ("open", hStr("09:00:00+09:00")))),
    ("2026-11-02", hObj(("close", hStr("12:00:00+09:00")),
                        ("open", hStr("09:00:00+09:00")))))),
    ("version", hStr("CAL-TEST")))

proc cfgRaw(date = "2026-10-29"): HcjValue =
  hObj(("params", hObj()), ("session_date", hStr(date)))

proc tickRaw(sym, t: string; price, vol: int64; m = "2"): HcjValue =
  hObj(("m", hStr(m)), ("price", hInt(price)), ("symbol", hStr(sym)),
       ("t", hStr(t)), ("vol", hInt(vol)))

let fixtureDir = "fixtures/smoke"
let baseLines = readHcjTextLines(fixtureDir / "input.hcj.jsonl")
let gapLines = readHcjTextLines(fixtureDir / "gap_input.hcj.jsonl")
let lateLines = readHcjTextLines(fixtureDir / "late_tick_input.hcj.jsonl")
let incLines = readHcjTextLines(fixtureDir / "incomplete_input.hcj.jsonl")

# ---------------------------------------------------------------- HCJ
block hcjVectors:
  let v = hObj(("b", hInt(2)), ("a", hStr("x")))
  check("hcj canonical sorts keys", canonical(v) == """{"a":"x","b":2}""")
  check("hcj roundtrip", canonical(parseLine(canonical(v))) == canonical(v))
  checkRaises("hcj rejects floats", proc () = discard parseLine("1.5"))
  checkRaises("hcj rejects trailing content", proc () = discard parseLine("{} {}"))
  checkRaises("hcj rejects unescaped control", proc () = discard parseLine("\"a" & '\n' & "b\""))

  let dir = workDir("hcj-lines")
  writeFile(dir / "crlf", "{\"a\":1}\r\n")
  checkRaises("readHcjTextLines rejects CRLF", proc () = discard readHcjTextLines(dir / "crlf"))
  writeFile(dir / "nolf", "{\"a\":1}")
  checkRaises("readHcjTextLines requires final LF", proc () = discard readHcjTextLines(dir / "nolf"))
  writeFile(dir / "bom", "\xef\xbb\xbf{\"a\":1}\n")
  checkRaises("readHcjTextLines rejects BOM", proc () = discard readHcjTextLines(dir / "bom"))
  writeFile(dir / "blank", "{\"a\":1}\n\n")
  checkRaises("readHcjTextLines rejects empty line", proc () = discard readHcjTextLines(dir / "blank"))

# ---------------------------------------------------------------- SHA-256
block shaVectors:
  check("sha256 empty",
    sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  check("sha256 abc",
    sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  check("sha256 448-bit block",
    sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")

# ---------------------------------------------------------------- records
block recordContract:
  let dir = workDir("records")
  checkRaises("reject seq swap", proc () =
    let ls = @[baseLines[0], baseLines[1], baseLines[3], baseLines[2]] & baseLines[4 .. ^1]
    discard loadRecords(materialize(dir, "swap.hcj.jsonl", ls)))
  checkRaises("reject duplicate seq", proc () =
    var ls = baseLines
    ls[3] = makeRecordLine(3, kWsFrame, parseRecord(baseLines[3], 4).raw)
    discard loadRecords(materialize(dir, "dup.hcj.jsonl", ls)))
  checkRaises("reject unknown kind", proc () =
    var ls = baseLines
    ls[2] = ls[2].replace("\"kind\":\"ws_frame\"", "\"kind\":\"mystery\"")
    discard loadRecords(materialize(dir, "unknown.hcj.jsonl", ls)))
  checkRaises("reject preamble violation", proc () =
    var ls = baseLines
    ls[2] = makeRecordLine(3, kCalendar, calRaw())
    discard runCore(loadRecords(materialize(dir, "preamble.hcj.jsonl", ls))))
  checkRaises("reject session_end not last", proc () =
    var ls = baseLines
    ls.add(makeRecordLine(ls.len + 1, kWsFrame, tickRaw("005930", "09:33:00+09:00", 10000, 1200)))
    discard runCore(loadRecords(materialize(dir, "endlast.hcj.jsonl", ls))))

# ---------------------------------------------------------------- calendar
block calendarContract:
  let cal = calRaw()
  let spec = sessionFor(cal, "2026-10-29")
  check("session 2026-10-29 has 130 bars", spec.bars == 130)
  check("half day has 60 bars", sessionFor(cal, "2026-11-02").bars == 60)
  check("holiday is not a trading day", not cal.isTradingDay("2026-10-30"))
  checkRaises("date outside coverage is CALENDAR_COVERAGE_UNKNOWN", proc () =
    discard sessionFor(cal, "2027-01-04"))
  var bad = calRaw()
  bad.get("days").get("2026-10-29").pairs[0].v = hStr("15:31:00+09:00")
  checkRaises("unaligned session is SESSION_NOT_BAR_ALIGNED", proc () =
    discard sessionFor(bad, "2026-10-29"))

# ---------------------------------------------------------------- bar boundary
block barBoundary:
  let spec = sessionFor(calRaw(), "2026-10-29")
  var b = initBars(spec)
  feedTick(b, "A", hmsToSec("09:03:00+09:00") - spec.openSec, 100, 1000, "2")
  check("09:03:00 belongs to bar 1",
        b.openBarCount == 1 and b.currentBarIndex("A") == 1)
  var b2 = initBars(spec)
  let tClose = hmsToSec("15:30:00+09:00") - spec.openSec
  feedTick(b2, "A", tClose, 100, 1000, "2")
  check("15:30:00 is the last bar with close_boundary",
        b2.currentBarIndex("A") == 129 and b2.currentBarBoundary("A"))
  var b3 = initBars(spec)
  feedTick(b3, "A", tClose + 1, 100, 1000, "2")
  check("15:30:01 with 290=2 is a conflict, not in-session",
        b3.conflicts == 1 and b3.frames == 1 and b3.openBarCount == 0)
  let half = sessionFor(calRaw(), "2026-11-02")
  var b4 = initBars(half)
  feedTick(b4, "A", hmsToSec("12:00:00+09:00") - half.openSec, 100, 1000, "2")
  check("half day 12:00:00 is bar 59 with close_boundary",
        b4.currentBarIndex("A") == 59 and b4.currentBarBoundary("A"))

# ---------------------------------------------------------------- replay
block baseReplay:
  let pairs = pairsOf(baseLines)
  let path = materialize(workDir("base"), "in.hcj.jsonl", recLines(pairs))
  let res = runCore(loadRecords(path))
  check("base replay is OK", res.status == rsOk)
  check("base replay yields 22 bars", res.bars.len == 22)
  var got: seq[string]
  for s in res.signals: got.add(s.symbol & "/" & $s.barIndex & "/" & s.signal)
  check("base signals hold unverified bearish decisions", got.join(",") ==
    "000660/0/SIGNAL_HELD,000660/4/SIGNAL_HELD," &
    "000660/5/SIGNAL_HELD,000660/9/SIGNAL_HELD," &
    "005930/0/SIGNAL_HELD,005930/7/SIGNAL_HELD," &
    "005930/8/SIGNAL_HELD,005930/9/bullish_pullback_reversal")
  check("held bar reports its reason", res.signals[0].reason == "first_after_sub")
  var closedAll = true
  for bar in res.bars:
    if not bar.closed: closedAll = false
  check("every emitted bar is closed", closedAll)
  var inv = true
  for s in res.signals:
    var found = false
    for bar in res.bars:
      if bar.symbol == s.symbol and bar.index == s.barIndex and bar.closed: found = true
    if not found: inv = false
  check("no signal references an open bar", inv)

block incompleteRun:
  let dir = workDir("incomplete")
  let path = materialize(dir, "input.hcj.jsonl", incLines)
  check("missing session_end is INCOMPLETE",
        runCore(loadRecords(path)).status == rsIncomplete)
  let res = runCore(loadRecords(path))
  let runDir = dir / "run"
  discard writeRun(runDir, path, res)
  let v = verifyRun(runDir)
  check("verify reports INCOMPLETE exit 4",
        v.verdict == vIncomplete and exitCode(v.verdict) == 4)

block lateTick:
  let dir = workDir("late")
  let path = materialize(dir, "input.hcj.jsonl", lateLines)
  checkRaises("late tick into a closed bar raises", proc () =
    discard runCore(loadRecords(path)))
  let v = verifyRun(dir)
  check("verify reports INVALID exit 5",
        v.verdict == vInvalid and exitCode(v.verdict) == 5)

block gapRun:
  let pairs = pairsOf(gapLines)
  let path = materialize(workDir("gap"), "in.hcj.jsonl", recLines(pairs))
  let res = runCore(loadRecords(path))
  check("gap replay is OK", res.status == rsOk)
  var before, after, held = 0
  for bar in res.bars:
    if bar.gapEdge == "before" and bar.degraded: inc before
    if bar.pos == "after_gap" and bar.degraded: inc after
  for s in res.signals:
    if s.signal == "SIGNAL_HELD" and s.reason == "gap": inc held
  check("gap closes the previous bar as degraded", before == 2)
  check("gap opens the next bar as after_gap", after == 2)
  check("gap bars are held with a reason", held >= 2)

# ---------------------------------------------------------------- refutation
block noEffect:
  ## Insert diagnostic records after the fixed preamble, renumber everything,
  ## and require byte-identical Core output.
  let plain = pairsOf(baseLines)
  var withDiag = pairsOf(baseLines)
  withDiag.insert((kWsConn, hObj(("state", hStr("reconnecting")))), 2)
  withDiag.insert((kPong, hNull()), 3)
  check("NO_EFFECT: inserting diagnostic records changes no output byte",
        coreBytes(plain) == coreBytes(withDiag))
  var changedPayload = pairsOf(baseLines)
  changedPayload.insert((kWsConn, hObj(("state", hStr("closed")))), 2)
  changedPayload.insert((kPong, hObj(("x", hInt(1)))), 3)
  check("NO_EFFECT: changing diagnostic payloads changes no output byte",
        coreBytes(plain) == coreBytes(changedPayload))

block expectedDelta:
  var pairs = pairsOf(baseLines)
  let i = findTick(pairs, "005930", "09:15")
  check("EXPECTED_DELTA: target tick found", i >= 0)
  setField(pairs[i].raw, "price", hInt(int64(pairs[i].raw.get("price").asInt + 1000)))
  check("EXPECTED_DELTA: a price change changes the bars",
        coreBytes(pairsOf(baseLines)) != coreBytes(pairs))

block volumeRegression:
  var pairs = pairsOf(baseLines)
  let i = findTick(pairs, "000660", "09:12")
  setField(pairs[i].raw, "vol", hInt(int64(4000)))
  let path = materialize(workDir("vol"), "in.hcj.jsonl", recLines(pairs))
  let res = runCore(loadRecords(path))
  var held = 0
  for s in res.signals:
    if s.signal == "SIGNAL_HELD" and s.barIndex == 4: inc held
  check("EXPECTED_DELTA: a volume regression holds that bar", held == 1)

block flagConflict:
  ## 1 conflict in 500 frames = 0.2% < 0.5% threshold, so the round survives.
  proc hms(sec: int): string =
    align($(sec div 3600), 2, '0') & ":" &
    align($((sec mod 3600) div 60), 2, '0') & ":" &
    align($(sec mod 60), 2, '0') & "+09:00"
  var pairs: seq[tuple[k: Kind, raw: HcjValue]]
  pairs.add((kCalendar, calRaw()))
  pairs.add((kConfig, cfgRaw()))
  var vol = 0'i64
  for bar in 0 .. 9:
    for k in 0 .. 49:
      inc vol
      let m = if bar == 5 and k == 10: "1" else: "2"
      pairs.add((kWsFrame, tickRaw("A", hms(9 * 3600 + bar * 180 + k * 3), 100, vol, m)))
  pairs.add((kSessionEnd, hNull()))
  let path = materialize(workDir("flag"), "in.hcj.jsonl", recLines(pairs))
  let res = runCore(loadRecords(path))
  check("EXPECTED_DELTA: 290 conflict is counted",
        res.status == rsOk and res.conflicts == 1)
  var held = 0
  for s in res.signals:
    if s.signal == "SIGNAL_HELD" and s.reason == "flag_conflict": inc held
  check("flag conflict emits SIGNAL_HELD flag_conflict", held == 1)

block flagUnreliable:
  var pairs: seq[tuple[k: Kind, raw: HcjValue]]
  pairs.add((kCalendar, calRaw()))
  pairs.add((kConfig, cfgRaw()))
  pairs.add((kWsFrame, tickRaw("A", "09:00:00+09:00", 100, 1, "1")))
  pairs.add((kSessionEnd, hNull()))
  let path = materialize(workDir("unreliable"), "in.hcj.jsonl", recLines(pairs))
  check("conflict ratio above 0.5% aborts the round",
        runCore(loadRecords(path)).status == rsUnreliableFlag)

block clockInvariant:
  let a = coreBytes(pairsOf(baseLines))
  putEnv("TZ", "UTC")
  let b = coreBytes(pairsOf(baseLines))
  putEnv("TZ", "Asia/Seoul")
  check("CLOCK_INVARIANT: TZ does not affect output", a == b)

# ---------------------------------------------------------------- verify
block verifyProvenance:
  let dir = workDir("verify")
  let path = materialize(dir, "input.hcj.jsonl", recLines(pairsOf(baseLines)))
  let res = runCore(loadRecords(path))
  let okInfo = BuildInfo(codeCommit: "abc123", sourceRef: "main",
    originMainSha: "abc123", dirty: false, nimVersion: NimVersion,
    buildTime: "t")
  let runDir = dir / "run"
  discard writeRun(runDir, path, res, okInfo)
  let good = verifyRun(runDir, okInfo)
  check("canonical run verifies as MATCH provenance=OK",
        good.verdict == vMatch and good.matched and
        verdictLine(good) == "VERDICT MATCH provenance=OK")
  let dirtyInfo = BuildInfo(codeCommit: "abc123", sourceRef: "main",
    originMainSha: "abc123", dirty: true, nimVersion: NimVersion,
    buildTime: "t")
  check("dirty binary is INVALID_PROVENANCE",
        verifyRun(runDir, dirtyInfo).verdict == vInvalidProvenance)
  let featureInfo = BuildInfo(codeCommit: "abc123", sourceRef: "feat/x",
    originMainSha: "abc123", dirty: false, nimVersion: NimVersion,
    buildTime: "t")
  check("feature-branch build is INVALID_PROVENANCE",
        verifyRun(runDir, featureInfo).verdict == vInvalidProvenance)
  let otherNim = BuildInfo(codeCommit: "abc123", sourceRef: "main",
    originMainSha: "abc123", dirty: false, nimVersion: "2.2.9",
    buildTime: "t")
  check("toolchain mismatch is INVALID_PROVENANCE",
        verifyRun(runDir, otherNim).verdict == vInvalidProvenance)
  var lines = readHcjTextLines(runDir / "signals.hcj.jsonl")
  lines[0] = lines[0].replace("\"price\":", "\"price\":1")
  writeFile(runDir / "signals.hcj.jsonl", joinLines(lines))
  let bad = verifyRun(runDir, okInfo)
  check("artifact tampering is MISMATCH exit 6",
        bad.verdict == vMismatch and exitCode(bad.verdict) == 6)
  check("checked-in dev build info is never canonical", buildInfo.dirty)

echo ""
echo passes, " passed, ", failures, " failed"
if failures > 0: quit(1)