## Input-contract regression tests for hcj / records / calendars (v6.2).
## Synthetic only: no fixtures, no network, no wall clock.
## Run: nim c -r --path:src tests/test_input_contract.nim
import std/[os, tempfiles]
import hs/[hcj, records, calendars, replay, verify]

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

proc checkNotRaises(name: string; body: proc ()) =
  var ok = true
  try:
    body()
  except CatchableError as e:
    ok = false
    echo "     unexpected ", e.name, ": ", e.msg
  check(name, ok)

proc raisesCoverage(name: string; body: proc ()) =
  var hit = false
  try:
    body()
  except CoverageError:
    hit = true
  except CatchableError as e:
    echo "     wrong class ", e.name, ": ", e.msg
  check(name, hit)

proc raisesHcj(name: string; body: proc ()) =
  var hit = false
  try:
    body()
  except HcjError:
    hit = true
  except CatchableError as e:
    echo "     wrong class ", e.name, ": ", e.msg
  check(name, hit)

proc rejectsTimestamp(s: string): bool =
  try:
    discard hmsToSec(s)
    result = false
  except CatchableError:
    result = true

proc tmpRunDir(name: string; lines: seq[string]): string =
  ## dir/input.hcj.jsonl with LF discipline; returns the run dir.
  result = createTempDir("hs-input-" & name & "-", "")
  var content = ""
  for l in lines: content.add(l & "\n")
  writeFile(result / inputFile, content)

proc day(o, c: string): HcjValue =
  hObj(("close", hStr(c)), ("open", hStr(o)))

proc calRaw(days: HcjValue): HcjValue = hObj(("days", days))

let goodCal = calRaw(hObj(
  ("2026-10-29", day("09:00:00+09:00", "15:30:00+09:00")),
  ("2026-10-30", hObj(("close", hNull()), ("open", hNull()))),
  ("2026-11-02", day("09:00:00+09:00", "12:00:00+09:00"))))

let cfgRaw = hObj(("session_date", hStr("2026-10-29")))

# ---------------------------------------------------------------- HCJ numbers
block hcjNumberRules:
  check("safe max int parses", parseLine("9007199254740991").asInt == 9007199254740991'i64)
  check("safe min int parses", parseLine("-9007199254740991").asInt == -9007199254740991'i64)
  checkRaises("int above 2^53-1 rejected", proc () = discard parseLine("9007199254740992"))
  checkRaises("int below -(2^53-1) rejected", proc () = discard parseLine("-9007199254740992"))
  checkRaises("int64 overflow rejected", proc () = discard parseLine("9223372036854775808"))
  checkRaises("hInt rejects out-of-range", proc () = discard hInt(9007199254740992'i64))
  checkRaises("float literal rejected", proc () = discard parseLine("1.5"))
  checkRaises("exponent literal rejected", proc () = discard parseLine("1e3"))
  checkRaises("uppercase exponent rejected", proc () = discard parseLine("1E3"))
  checkRaises("trailing dot rejected", proc () = discard parseLine("5."))
  checkRaises("plus sign rejected", proc () = discard parseLine("+1"))
  checkRaises("leading zero rejected", proc () = discard parseLine("01"))
  checkRaises("negative leading zero rejected", proc () = discard parseLine("-01"))
  checkRaises("trailing content rejected", proc () = discard parseLine("{} {}"))

# ---------------------------------------------------------------- HCJ strings
block hcjStringRules:
  checkRaises("raw tab rejected", proc () = discard parseLine("\"a\tb\""))
  checkRaises("raw newline rejected", proc () = discard parseLine("\"a\nb\""))
  checkRaises("raw DEL rejected", proc () = discard parseLine("\"a\x7fb\""))
  checkRaises("escaped DEL rejected", proc () = discard parseLine("\"\\u007f\""))
  checkRaises("lone high surrogate rejected", proc () = discard parseLine("\"\\ud800\""))
  checkRaises("lone low surrogate rejected", proc () = discard parseLine("\"\\udc00\""))
  checkRaises("broken surrogate pair rejected", proc () = discard parseLine("\"\\ud800\\ud800\""))
  check("surrogate pair decodes to UTF-8", parseLine("\"\\ud83d\\ude00\"").asStr == "\xf0\x9f\x98\x80")
  checkRaises("overlong UTF-8 rejected", proc () = discard parseLine("\"a\xe0\x80\x80\""))
  checkRaises("c0 lead byte rejected", proc () = discard parseLine("\"\xc0\x80\""))
  checkRaises("truncated UTF-8 rejected", proc () = discard parseLine("\"\xe0\""))

# ------------------------------------- escaped controls round-trip (regression)
block hcjEscapedControls:
  check("escaped tab parses", parseLine("\"x\\ty\"").asStr == "x\ty")
  check("\\u0001 escape parses", parseLine("\"\\u0001\"").asStr == "\x01")
  check("uppercase hex escape parses", parseLine("\"\\u0041\"").asStr == "A")
  check("hStr accepts a control char", hStr("a\tb").strVal == "a\tb")
  check("canonical escapes tab", canonical(hStr("a\tb")) == "\"a\\tb\"")
  check("canonical escapes \\u0001 in lowercase", canonical(hStr("\x01")) == "\"\\u0001\"")
  check("canonical escapes \\u001f in lowercase", canonical(hStr("\x1f")) == "\"\\u001f\"")
  let c = "{\"a\":\"x\\ty\",\"b\":\"\\u0001\"}"
  check("canonical round-trips escaped controls", canonical(parseLine(c)) == c)

# ---------------------------------------------------------------- HCJ keys
block hcjKeyRules:
  checkRaises("empty key rejected", proc () = discard parseLine("{\"\":1}"))
  checkRaises("hObj rejects empty key", proc () = discard hObj(("", hInt(1))))
  checkRaises("hObj rejects duplicate key", proc () =
    discard hObj(("a", hInt(1)), ("a", hInt(2))))
  checkRaises("key charset rejected", proc () = discard parseLine("{\"a.b\":1}"))
  checkRaises("duplicate key rejected", proc () = discard parseLine("{\"a\":1,\"a\":2}"))
  check("key charset [A-Za-z0-9_-] parses", parseLine("{\"a-b_C9\":1}").has("a-b_C9"))
  check("canonical key order is codepoint order",
        canonical(parseLine("{\"b\":2,\"a\":1}")) == "{\"a\":1,\"b\":2}")
  check("line with surrounding whitespace tolerated", parseLine(" {\"a\":1} ").has("a"))

# ---------------------------------------------------------------- line discipline
block hcjLineDiscipline:
  let dir = createTempDir("hs-input-lines-", "")
  proc wf(name, content: string): string =
    result = dir / name
    writeFile(result, content)
  checkRaises("CRLF line rejected", proc () = discard readHcjTextLines(wf("crlf", "{\"a\":1}\r\n")))
  checkRaises("missing final LF rejected", proc () = discard readHcjTextLines(wf("nolf", "{\"a\":1}")))
  checkRaises("BOM rejected", proc () = discard readHcjTextLines(wf("bom", "\xef\xbb\xbf{\"a\":1}\n")))
  checkRaises("blank line rejected", proc () = discard readHcjTextLines(wf("blank", "{\"a\":1}\n\n")))
  check("canonicalFileBytes appends LF", canonicalFileBytes(@["{\"a\":1}"]) == "{\"a\":1}\n")

# ---------------------------------------------------------------- seq contract
block recordSeqRules:
  check("envelope canonical order is kind,raw,seq", makeRecordLine(3, kGap, hNull()) ==
    "{\"kind\":\"gap\",\"raw\":null,\"seq\":3}")
  let line = makeRecordLine(7, kWsFrame, hObj(("symbol", hStr("005930"))))
  let r = parseRecord(line, 7)
  check("parseRecord accepts a matching seq", r.seq == 7 and r.kind == kWsFrame)
  checkRaises("seq discontinuity rejected", proc () = discard parseRecord(line, 8))
  checkRaises("seq zero rejected", proc () = discard parseRecord(
    "{\"kind\":\"gap\",\"raw\":null,\"seq\":0}", 1))
  checkRaises("non-integer seq rejected", proc () = discard parseRecord(
    "{\"kind\":\"gap\",\"raw\":null,\"seq\":\"3\"}", 3))
  checkRaises("missing seq rejected", proc () = discard parseRecord(
    "{\"kind\":\"gap\",\"raw\":null}", 1))
  checkRaises("missing raw rejected", proc () = discard parseRecord(
    "{\"kind\":\"gap\",\"seq\":1}", 1))
  checkRaises("unknown kind rejected", proc () = discard parseRecord(
    "{\"kind\":\"mystery\",\"raw\":null,\"seq\":1}", 1))
  checkRaises("non-string kind rejected", proc () = discard parseRecord(
    "{\"kind\":5,\"raw\":null,\"seq\":1}", 1))
  checkRaises("non-object record rejected", proc () = discard parseRecord("[1]", 1))

block recordStreamRules:
  let ok = @[
    makeRecordLine(1, kCalendar, goodCal),
    makeRecordLine(2, kConfig, cfgRaw),
    makeRecordLine(3, kPong, hNull()),
    makeRecordLine(4, kSessionEnd, hNull())]
  let recs = loadRecords(tmpRunDir("ok", ok) / inputFile)
  check("contiguous 1..N stream loads", recs.len == 4 and recs[3].kind == kSessionEnd)
  var swap = ok
  swap[2] = makeRecordLine(4, kPong, hNull())
  swap[3] = makeRecordLine(3, kSessionEnd, hNull())
  checkRaises("seq swap rejected", proc () =
    discard loadRecords(tmpRunDir("swap", swap) / inputFile))
  var dup = ok
  dup[3] = makeRecordLine(3, kSessionEnd, hNull())
  checkRaises("duplicate seq rejected", proc () =
    discard loadRecords(tmpRunDir("dup", dup) / inputFile))
  var extraCal = ok
  extraCal[2] = makeRecordLine(3, kCalendar, goodCal)
  checkRaises("calendar after seq 2 rejected", proc () =
    validateRecords(loadRecords(tmpRunDir("pre", extraCal) / inputFile)))
  var badFirst = ok
  badFirst[0] = makeRecordLine(1, kConfig, cfgRaw)
  checkRaises("seq 1 must be calendar", proc () =
    validateRecords(loadRecords(tmpRunDir("badfirst", badFirst) / inputFile)))
  var badSecond = ok
  badSecond[1] = makeRecordLine(2, kWsFrame, hObj(("symbol", hStr("005930"))))
  checkRaises("seq 2 must be config", proc () =
    validateRecords(loadRecords(tmpRunDir("badsecond", badSecond) / inputFile)))
  var endNotLast = ok
  endNotLast.add(makeRecordLine(5, kPong, hNull()))
  checkRaises("session_end not last rejected", proc () =
    validateRecords(loadRecords(tmpRunDir("endlast", endNotLast) / inputFile)))
  var twoEnds = ok
  twoEnds.add(makeRecordLine(5, kSessionEnd, hNull()))
  checkRaises("second session_end rejected", proc () =
    validateRecords(loadRecords(tmpRunDir("twoends", twoEnds) / inputFile)))
  checkRaises("stream shorter than the preamble rejected", proc () =
    validateRecords(loadRecords(tmpRunDir("short", ok[0 .. 0]) / inputFile)))
  checkNotRaises("missing session_end is not a REJECT", proc () =
    validateRecords(loadRecords(tmpRunDir("noend", ok[0 .. 2]) / inputFile)))

# ---------------------------------------------------------------- time format
block calendarTimeFormat:
  check("09:00:00+09:00 -> 32400", hmsToSec("09:00:00+09:00") == 32400)
  check("15:30:00+09:00 -> 55800", hmsToSec("15:30:00+09:00") == 55800)
  check("00:00:00+09:00 -> 0", hmsToSec("00:00:00+09:00") == 0)
  check("23:59:59+09:00 -> 86399", hmsToSec("23:59:59+09:00") == 86399)
  for bad in ["090:0:00+09:00", "09:60:00+09:00", "09:00:60+09:00", "24:00:00+09:00",
              "09:-1:00+09:00", "09:+1:00+09:00", "9:00:00+09:00", "09:00:00",
              "09:00:00+09:0", "09:00:00-09:00", "09:00:00Z", "09 00 00+09:00", ""]:
    check("malformed timestamp rejected: " & (if bad.len == 0: "(empty)" else: bad),
          rejectsTimestamp(bad))

# ---------------------------------------------------------------- session rules
block calendarSessionRules:
  let spec = sessionFor(goodCal, "2026-10-29")
  check("full session is 130 bars", spec.bars == 130)
  check("full session bounds come from the calendar",
        spec.openSec == 32400 and spec.closeSec == 55800)
  check("half session is 60 bars", sessionFor(goodCal, "2026-11-02").bars == 60)
  check("trading day detected", goodCal.isTradingDay("2026-10-29"))
  check("holiday is not a trading day", not goodCal.isTradingDay("2026-10-30"))
  check("unknown date is not a trading day", not goodCal.isTradingDay("2027-01-04"))
  check("coverage range is sorted dates", firstLast(goodCal) == ("2026-10-29", "2026-11-02"))
  check("inner date is in coverage", goodCal.inCoverage("2026-10-30"))
  check("later date is out of coverage", not goodCal.inCoverage("2026-11-03"))
  raisesCoverage("outside coverage raises CALENDAR_COVERAGE_UNKNOWN", proc () =
    discard sessionFor(goodCal, "2027-01-04"))
  raisesCoverage("holiday session date raises", proc () =
    discard sessionFor(goodCal, "2026-10-30"))
  var empty = calRaw(hObj(("2026-10-29", day("09:00:00+09:00", "09:00:00+09:00"))))
  raisesCoverage("close <= open raises", proc () = discard sessionFor(empty, "2026-10-29"))
  var unaligned = calRaw(hObj(("2026-10-29", day("09:00:00+09:00", "15:31:00+09:00"))))
  var gotAlign = false
  try:
    discard sessionFor(unaligned, "2026-10-29")
  except AlignError:
    gotAlign = true
  check("unaligned session raises SESSION_NOT_BAR_ALIGNED", gotAlign)
  var badOpen = calRaw(hObj(("2026-10-29", day("090:0:00+09:00", "15:30:00+09:00"))))
  raisesCoverage("malformed open time in calendar raises", proc () =
    discard sessionFor(badOpen, "2026-10-29"))

# ------------------------------------------------ calendar shape -> exit class
block calendarShapeRules:
  var noClose = calRaw(hObj(("2026-10-29", hObj(("open", hStr("09:00:00+09:00"))))))
  raisesCoverage("day without close is a calendar error", proc () =
    discard sessionFor(noClose, "2026-10-29"))
  var closeNull = calRaw(hObj(("2026-10-29",
    hObj(("close", hNull()), ("open", hStr("09:00:00+09:00"))))))
  raisesCoverage("null close with open set is a calendar error", proc () =
    discard sessionFor(closeNull, "2026-10-29"))
  var openInt = calRaw(hObj(("2026-10-29",
    hObj(("close", hStr("15:30:00+09:00")), ("open", hInt(900))))))
  raisesCoverage("non-string open is a calendar error", proc () =
    discard sessionFor(openInt, "2026-10-29"))
  var dayInt = calRaw(hObj(("2026-10-29", hInt(1))))
  raisesCoverage("non-object day is a calendar error", proc () =
    discard sessionFor(dayInt, "2026-10-29"))
  raisesCoverage("calendar without days is a calendar error", proc () =
    discard sessionFor(hObj(("market", hStr("KRX"))), "2026-10-29"))
  raisesCoverage("non-object days is a calendar error", proc () =
    discard sessionFor(hObj(("days", hArr())), "2026-10-29"))
  raisesHcj("non-object calendar raw is an HCJ error", proc () =
    discard sessionFor(hStr("oops"), "2026-10-29"))

# ---------------------------------------------------------------- end-to-end
block exitCodeRules:
  let noCloseCal = calRaw(hObj(("2026-10-29", hObj(("open", hStr("09:00:00+09:00"))))))
  let d3 = tmpRunDir("exit3", @[
    makeRecordLine(1, kCalendar, noCloseCal),
    makeRecordLine(2, kConfig, cfgRaw),
    makeRecordLine(3, kSessionEnd, hNull())])
  let v3 = verifyRun(d3)
  check("malformed calendar day verifies as exit 3", exitCode(v3.verdict) == 3)
  let d2 = tmpRunDir("exit2", @[
    makeRecordLine(2, kConfig, cfgRaw),
    makeRecordLine(1, kCalendar, goodCal),
    makeRecordLine(3, kSessionEnd, hNull())])
  let v2 = verifyRun(d2)
  check("seq order violation verifies as exit 2", exitCode(v2.verdict) == 2)

block tickTimeRules:
  let d = tmpRunDir("tick", @[
    makeRecordLine(1, kCalendar, goodCal),
    makeRecordLine(2, kConfig, cfgRaw),
    makeRecordLine(3, kWsFrame, hObj(
      ("m", hStr("2")), ("price", hInt(100)), ("symbol", hStr("005930")),
      ("t", hStr("09:60:00+09:00")), ("vol", hInt(1)))),
    makeRecordLine(4, kSessionEnd, hNull())])
  raisesCoverage("out-of-range minute in a tick timestamp is rejected", proc () =
    discard runCore(loadRecords(d / inputFile)))

echo ""
echo passes, " passed, ", failures, " failed"
if failures > 0: quit(1)
