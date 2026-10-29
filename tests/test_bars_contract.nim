## Bar/gap/session-290 contract regressions for VS-1. Synthetic inputs only:
## no network, no real market data, no wall clock.
## Covers docs/REPLAY_CONTRACT.md §3 (gap/session_end record shape), §4
## (session-class table, conflict degradation of existing bars, 0.5%
## threshold) and §5 (bar index, boundary-difference volume, gap edges,
## late tick, session_end fail-closed gaps: a symbol whose gap is still
## pending at session_end never lets the run pass as OK — UnresolvedGapError
## distinguishes a symbol-specific gap from a connection-wide one).
## Kiwoom documents tic_scope "3" as a three-minute bar, cntr_tm as the bar
## start, and WS TR 0B fields 290 and 13 as session flag and cumulative volume.
## WS-to-REST alignment and cumulative-volume semantics remain unverified.
## Run: nim c -r --path:src tests/test_bars_contract.nim
import std/[os, strutils, tempfiles]
import hs/[hcj, records, calendars, bars, replay, engine]

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
  result = createTempDir("hs-barseg-" & name & "-", "")

proc materialize(dir, name: string; lines: seq[string]): string =
  result = dir / name
  writeFile(result, joinLines(lines))

proc recLines(pairs: seq[tuple[k: Kind, raw: HcjValue]]): seq[string] =
  for i, p in pairs:
    result.add(makeRecordLine(i + 1, p.k, p.raw))

proc runPairs(name: string;
              pairs: seq[tuple[k: Kind, raw: HcjValue]]): CoreResult =
  let path = materialize(workDir(name), "in.hcj.jsonl", recLines(pairs))
  runCore(loadRecords(path))

proc runOrGap(name: string;
              pairs: seq[tuple[k: Kind, raw: HcjValue]]): tuple[
                gapMsg: string; res: CoreResult] =
  ## res is meaningful only when gapMsg == "" (no UnresolvedGapError).
  try:
    result.res = runPairs(name, pairs)
  except UnresolvedGapError as e:
    result.gapMsg = e.msg

proc findBar(res: CoreResult; symbol: string; idx: int): Bar =
  for bar in res.bars:
    if bar.symbol == symbol and bar.index == idx:
      return bar
  Bar(symbol: symbol, index: -1)

proc findBarLocal(b: BarsBuilder; symbol: string; idx: int): Bar =
  for bar in closedBars(b):
    if bar.symbol == symbol and bar.index == idx:
      return bar
  Bar(symbol: symbol, index: -1)

proc heldReason(res: CoreResult; symbol: string; idx: int): string =
  for s in res.signals:
    if s.symbol == symbol and s.barIndex == idx and s.signal == "SIGNAL_HELD":
      return s.reason
  ""

proc hms(secOfDay: int): string =
  align($(secOfDay div 3600), 2, '0') & ":" &
  align($((secOfDay mod 3600) div 60), 2, '0') & ":" &
  align($(secOfDay mod 60), 2, '0') & "+09:00"

proc calRaw(): HcjValue =
  hObj(("days", hObj(
    ("2026-10-29", hObj(("close", hStr("15:30:00+09:00")),
                        ("open", hStr("09:00:00+09:00")))))),
    ("version", hStr("CAL-BARS-REG")))

proc cfgRaw(date = "2026-10-29"): HcjValue =
  hObj(("params", hObj()), ("session_date", hStr(date)))

proc tickRaw(sym, t: string; price, vol: int64; m = "2"): HcjValue =
  hObj(("m", hStr(m)), ("price", hInt(price)), ("symbol", hStr(sym)),
       ("t", hStr(t)), ("vol", hInt(vol)))

proc tickNoM(sym, t: string; price, vol: int64): HcjValue =
  hObj(("price", hInt(price)), ("symbol", hStr(sym)),
       ("t", hStr(t)), ("vol", hInt(vol)))

proc gapRaw(symbol: HcjValue): HcjValue =
  hObj(("reason", hStr("ws_disconnect")), ("symbol", symbol))

# ------------------------------------------------------- §4 session classes
block sessionClassTable:
  let spec = sessionFor(calRaw(), "2026-10-29")
  let inWin = hmsToSec("10:00:00+09:00") - spec.openSec
  let pre = hmsToSec("08:59:59+09:00") - spec.openSec
  let post = hmsToSec("15:30:01+09:00") - spec.openSec

  var b = initBars(spec)
  feedTick(b, "A", inWin, 100, 1000, "2")
  check("m=2 inside the window enters a bar", b.openBarCount == 1)

  var b2 = initBars(spec)
  feedTick(b2, "A", post, 100, 1000, "2")
  check("m=2 after close is a conflict, never a bar",
        b2.conflicts == 1 and b2.frames == 1 and b2.openBarCount == 0)

  var b3 = initBars(spec)
  feedTick(b3, "A", pre, 100, 1000, "1")
  check("m=1 before open is out_of_session, not a conflict",
        b3.outOfSession == 1 and b3.conflicts == 0 and b3.openBarCount == 0)

  var b4 = initBars(spec)
  feedTick(b4, "A", post, 100, 1000, "3")
  check("m=3 after close is out_of_session, not a conflict",
        b4.outOfSession == 1 and b4.conflicts == 0)

  var b5 = initBars(spec)
  feedTick(b5, "A", inWin, 100, 1000, "1")
  check("m=1 inside the window is a conflict",
        b5.conflicts == 1 and b5.openBarCount == 0)

  var b6 = initBars(spec)
  feedTick(b6, "A", inWin, 100, 1000, "9")
  check("an unknown m value is excluded and counted",
        b6.conflicts == 1 and b6.openBarCount == 0)

  var b7 = initBars(spec)
  feedTick(b7, "A", inWin, 100, 1000, "")
  check("a missing m is excluded and counted",
        b7.conflicts == 1 and b7.openBarCount == 0)

# ------------------------------------------------- §5 bar index and volume
block barIndexAndVolume:
  let spec = sessionFor(calRaw(), "2026-10-29")
  check("the session has 130 three-minute bars", spec.bars == 130)

  var b = initBars(spec)
  feedTick(b, "A", hmsToSec("09:03:00+09:00") - spec.openSec, 100, 100, "2")
  check("09:03:00 belongs to bar 1 (bar-start convention)",
        b.currentBarIndex("A") == 1)

  var b2 = initBars(spec)
  let closeT = hmsToSec("15:30:00+09:00") - spec.openSec
  feedTick(b2, "A", closeT, 100, 100, "2")
  check("15:30:00 is the last bar with close_boundary",
        b2.currentBarIndex("A") == 129 and b2.currentBarBoundary("A"))

  var b3 = initBars(spec)
  feedTick(b3, "A", hmsToSec("09:00:30+09:00") - spec.openSec, 100, 100, "2")
  feedTick(b3, "A", hmsToSec("09:01:00+09:00") - spec.openSec, 101, 150, "2")
  feedTick(b3, "A", hmsToSec("09:03:10+09:00") - spec.openSec, 102, 300, "2")
  feedTick(b3, "A", hmsToSec("09:04:00+09:00") - spec.openSec, 103, 250, "2")
  closeAtSessionEnd(b3)
  let bars = closedBars(b3)
  check("four ticks in two adjacent intervals close as two bars",
        bars.len == 2)
  check("the first observation's delta is 0 and the bar stays vol_partial",
        bars[0].vol == 50 and bars[0].volPartial)
  check("the first bar is first_after_sub and degraded",
        bars[0].pos == "first_after_sub" and bars[0].degraded)
  check("volume is the boundary difference of the cumulative field",
        bars[1].vol == 150)
  check("a negative cumulative delta clamps to 0 and degrades the bar",
        bars[1].degraded)

# ------------------------------------- §4 conflict degrades existing bars
# Every stream in this section keeps conflicts <= 0.5% of frames (200
# in-session frames + 1 conflict = 201 frames), so the round is not aborted.
block conflictDegradesClosedBar:
  var pairs: seq[tuple[k: Kind, raw: HcjValue]]
  pairs.add((kCalendar, calRaw()))
  pairs.add((kConfig, cfgRaw()))
  for i in 0 ..< 200:
    pairs.add((kWsFrame, tickRaw("A", hms(9 * 3600 + i * 2), 100, int64(i + 1))))
  pairs.add((kWsFrame, tickRaw("A", "09:04:00+09:00", 999, 999, "1")))
  pairs.add((kSessionEnd, hNull()))
  let res = runPairs("closed-conflict", pairs)
  check("a run with one conflict in 201 frames stays OK", res.status == rsOk)
  check("the conflict tick is excluded and counted",
        res.conflicts == 1 and res.frames == 201)
  check("a conflict on a closed interval degrades that closed bar",
        findBar(res, "A", 1).degraded)
  check("the conflict price never enters any bar",
        findBar(res, "A", 1).high == 100)
  check("the degraded closed bar is held with reason flag_conflict",
        heldReason(res, "A", 1) == "flag_conflict")
  check("no extra bar is invented for the conflict", res.bars.len == 3)
  check("the first bar is held as first_after_sub",
        heldReason(res, "A", 0) == "first_after_sub")

block unknownDegradesClosedBar:
  var pairs: seq[tuple[k: Kind, raw: HcjValue]]
  pairs.add((kCalendar, calRaw()))
  pairs.add((kConfig, cfgRaw()))
  for i in 0 ..< 200:
    pairs.add((kWsFrame, tickRaw("A", hms(9 * 3600 + i * 2), 100, int64(i + 1))))
  pairs.add((kWsFrame, tickNoM("A", "09:04:00+09:00", 999, 999)))
  pairs.add((kSessionEnd, hNull()))
  let res = runPairs("closed-unknown", pairs)
  check("a missing m on a closed interval also degrades that bar",
        findBar(res, "A", 1).degraded and res.conflicts == 1)
  check("the unknown-affected bar is held with reason flag_conflict",
        heldReason(res, "A", 1) == "flag_conflict")

block conflictDegradesBarOpenedLater:
  var pairs: seq[tuple[k: Kind, raw: HcjValue]]
  pairs.add((kCalendar, calRaw()))
  pairs.add((kConfig, cfgRaw()))
  pairs.add((kWsFrame, tickRaw("A", hms(9 * 3600), 100, 1)))
  pairs.add((kWsFrame, tickRaw("A", "09:07:00+09:00", 999, 2, "1")))
  for i in 1 ..< 200:
    pairs.add((kWsFrame, tickRaw("A", hms(9 * 3600 + i * 2), 100, int64(i + 2))))
  pairs.add((kSessionEnd, hNull()))
  let res = runPairs("later-conflict", pairs)
  check("a conflict on a not-yet-open interval degrades the bar opened there",
        findBar(res, "A", 2).degraded)

block noBarInventedForConflict:
  var pairs: seq[tuple[k: Kind, raw: HcjValue]]
  pairs.add((kCalendar, calRaw()))
  pairs.add((kConfig, cfgRaw()))
  for i in 0 ..< 200:
    pairs.add((kWsFrame, tickRaw("A", hms(9 * 3600 + i), 100, int64(i + 1))))
  pairs.add((kWsFrame, tickRaw("A", "09:30:00+09:00", 999, 999, "1")))
  pairs.add((kSessionEnd, hNull()))
  let res = runPairs("invented-conflict", pairs)
  check("no bar is invented for an interval that never gets one",
        res.bars.len == 2 and res.conflicts == 1)

block outOfSessionDoesNotDegrade:
  var pairs: seq[tuple[k: Kind, raw: HcjValue]]
  pairs.add((kCalendar, calRaw()))
  pairs.add((kConfig, cfgRaw()))
  pairs.add((kWsFrame, tickRaw("A", "09:00:10+09:00", 100, 10)))
  pairs.add((kWsFrame, tickRaw("A", "09:03:10+09:00", 101, 20)))
  pairs.add((kWsFrame, tickRaw("A", "08:59:00+09:00", 999, 25, "1")))
  pairs.add((kSessionEnd, hNull()))
  let res = runPairs("oos-nodegrade", pairs)
  check("an out-of-session tick is excluded without degrading any bar",
        res.conflicts == 0 and res.frames == 3 and
        not findBar(res, "A", 1).degraded)

# ------------------------------------------------------- §4 0.5% threshold
block flagThreshold:
  proc streamWithConflicts(n: int): seq[tuple[k: Kind, raw: HcjValue]] =
    result.add((kCalendar, calRaw()))
    result.add((kConfig, cfgRaw()))
    var cum = 0'i64
    for i in 0 ..< 199:
      inc cum
      let t = 9 * 3600 + (i div 2) * 180 + (i mod 2) * 60
      result.add((kWsFrame, tickRaw("A", hms(t), 100, cum)))
    for j in 0 ..< n:
      result.add((kWsFrame, tickRaw("A", hms(9 * 3600 + 600 + j), 100,
                                    999 + j, "1")))
    result.add((kSessionEnd, hNull()))
  check("1 conflict in 200 frames (exactly 0.5%) does not abort the round",
        runPairs("thresh-edge", streamWithConflicts(1)).status == rsOk)
  check("2 conflicts in 201 frames (about 1%) abort the round",
        runPairs("thresh-over", streamWithConflicts(2)).status == rsUnreliableFlag)

# ----------------------------------------------------------- §5 gap records
block gapEdges:
  var pairs: seq[tuple[k: Kind, raw: HcjValue]]
  pairs.add((kCalendar, calRaw()))
  pairs.add((kConfig, cfgRaw()))
  pairs.add((kWsFrame, tickRaw("A", "09:00:30+09:00", 100, 100)))
  pairs.add((kWsFrame, tickRaw("A", "09:03:30+09:00", 101, 110)))
  pairs.add((kGap, gapRaw(hStr("A"))))
  pairs.add((kWsFrame, tickRaw("A", "09:06:30+09:00", 102, 130)))
  pairs.add((kSessionEnd, hNull()))
  let res = runPairs("gap-edges", pairs)
  check("a gap run stays OK", res.status == rsOk)
  check("the gap closes the open bar as gap_edge before and degrades it",
        findBar(res, "A", 1).gapEdge == "before" and
        findBar(res, "A", 1).degraded)
  let rel = findBar(res, "A", 2)
  check("the release bar is after_gap, degraded, vol_partial, gap_edge after",
        rel.pos == "after_gap" and rel.degraded and rel.volPartial and
        rel.gapEdge == "after")
  check("volume across the gap is still a boundary difference",
        rel.vol == 20)
  check("the gap-closed bar is held with reason gap",
        heldReason(res, "A", 1) == "gap")

block globalGapPerSymbolRelease:
  var pairs: seq[tuple[k: Kind, raw: HcjValue]]
  pairs.add((kCalendar, calRaw()))
  pairs.add((kConfig, cfgRaw()))
  pairs.add((kWsFrame, tickRaw("A", "09:00:30+09:00", 100, 100)))
  pairs.add((kWsFrame, tickRaw("B", "09:00:30+09:00", 200, 500)))
  pairs.add((kWsFrame, tickRaw("A", "09:03:30+09:00", 101, 110)))
  pairs.add((kWsFrame, tickRaw("B", "09:03:30+09:00", 201, 510)))
  pairs.add((kGap, gapRaw(hNull())))
  pairs.add((kWsFrame, tickRaw("A", "09:06:30+09:00", 102, 130)))
  pairs.add((kWsFrame, tickRaw("B", "09:09:30+09:00", 202, 530)))
  pairs.add((kSessionEnd, hNull()))
  let res = runPairs("global-gap", pairs)
  check("a connection-wide gap fully released by every symbol stays OK",
        res.status == rsOk)
  check("a connection-wide gap closes both symbols' bars as before edges",
        findBar(res, "A", 1).gapEdge == "before" and
        findBar(res, "B", 1).gapEdge == "before")
  check("release is per symbol, at each symbol's own first later frame",
        findBar(res, "A", 2).pos == "after_gap" and
        findBar(res, "B", 3).pos == "after_gap")

block unresolvedSymbol:
  var pairs: seq[tuple[k: Kind, raw: HcjValue]]
  pairs.add((kCalendar, calRaw()))
  pairs.add((kConfig, cfgRaw()))
  pairs.add((kWsFrame, tickRaw("A", "09:00:30+09:00", 100, 100)))
  pairs.add((kWsFrame, tickRaw("A", "09:03:30+09:00", 101, 110)))
  pairs.add((kGap, gapRaw(hNull())))
  pairs.add((kWsFrame, tickRaw("B", "09:06:30+09:00", 200, 500)))
  pairs.add((kSessionEnd, hNull()))
  let r = runOrGap("unresolved", pairs)
  check("a symbol that never returns fails the run at session_end",
        r.gapMsg.contains("UNRESOLVED_GAP") and r.gapMsg.contains("A"))
  check("a connection-wide gap origin is distinguished in the error",
        r.gapMsg.contains("connection_gap_unresolved=A"))
  check("another symbol's later frames never release the pending gap",
        not r.gapMsg.contains("B"))

block unresolvedSymbolBarShape:
  ## Same stream at builder level: the raise happens after the open bars are
  ## closed, so the unresolved edge keeps its §5 shape and no release bar is
  ## invented for the symbol that never returned.
  let spec = sessionFor(calRaw(), "2026-10-29")
  var b = initBars(spec)
  feedTick(b, "A", hmsToSec("09:00:30+09:00") - spec.openSec, 100, 100, "2")
  feedTick(b, "A", hmsToSec("09:03:30+09:00") - spec.openSec, 101, 110, "2")
  applyGap(b, "")
  feedTick(b, "B", hmsToSec("09:06:30+09:00") - spec.openSec, 200, 500, "2")
  var msg = ""
  try:
    closeAtSessionEnd(b)
  except UnresolvedGapError as e:
    msg = e.msg
  check("closeAtSessionEnd raises for the never-returning symbol",
        msg.contains("UNRESOLVED_GAP"))
  check("the unresolved bar is closed as a degraded gap_edge before",
        findBarLocal(b, "A", 1).gapEdge == "before" and
        findBarLocal(b, "A", 1).degraded)
  var aAfter = false
  for bar in closedBars(b):
    if bar.symbol == "A" and bar.pos == "after_gap": aAfter = true
  check("an unresolved symbol has no after_gap release bar", not aAfter)
  check("the returning symbol still releases its own gap",
        findBarLocal(b, "B", 2).pos == "after_gap")

block symbolGapUnresolved:
  ## A symbol-specific gap must be released by that symbol's own frame; any
  ## number of other symbols' frames leaves it pending, and session_end then
  ## fails closed instead of returning a normal result.
  var pairs: seq[tuple[k: Kind, raw: HcjValue]]
  pairs.add((kCalendar, calRaw()))
  pairs.add((kConfig, cfgRaw()))
  pairs.add((kWsFrame, tickRaw("A", "09:00:30+09:00", 100, 100)))
  pairs.add((kWsFrame, tickRaw("B", "09:00:30+09:00", 200, 500)))
  pairs.add((kGap, gapRaw(hStr("A"))))
  pairs.add((kWsFrame, tickRaw("B", "09:03:30+09:00", 201, 510)))
  pairs.add((kWsFrame, tickRaw("B", "09:06:30+09:00", 202, 520)))
  pairs.add((kSessionEnd, hNull()))
  let r = runOrGap("sym-gap-unresolved", pairs)
  check("a symbol gap never released by its own frame fails the run",
        r.gapMsg.contains("UNRESOLVED_GAP"))
  check("a symbol-specific gap origin is distinguished in the error",
        r.gapMsg.contains("symbol_gap_unresolved=A") and
        not r.gapMsg.contains("connection"))
  check("the unaffected symbol is not named as unresolved",
        not r.gapMsg.contains("B"))

  var resolved: seq[tuple[k: Kind, raw: HcjValue]]
  resolved.add((kCalendar, calRaw()))
  resolved.add((kConfig, cfgRaw()))
  resolved.add((kWsFrame, tickRaw("A", "09:00:30+09:00", 100, 100)))
  resolved.add((kGap, gapRaw(hStr("A"))))
  resolved.add((kWsFrame, tickRaw("A", "09:06:30+09:00", 102, 130)))
  resolved.add((kSessionEnd, hNull()))
  let rr = runOrGap("sym-gap-resolved", resolved)
  check("the same stream with the symbol's own release frame stays OK",
        rr.gapMsg.len == 0 and rr.res.status == rsOk)

# ---------------------------------------------------------- §5/§3 late tick
block lateTick:
  var pairs: seq[tuple[k: Kind, raw: HcjValue]]
  pairs.add((kCalendar, calRaw()))
  pairs.add((kConfig, cfgRaw()))
  pairs.add((kWsFrame, tickRaw("A", "09:00:30+09:00", 100, 10)))
  pairs.add((kWsFrame, tickRaw("A", "09:03:30+09:00", 101, 20)))
  pairs.add((kWsFrame, tickRaw("A", "09:00:40+09:00", 100, 15)))
  pairs.add((kSessionEnd, hNull()))
  var msg = ""
  try:
    discard runPairs("late", pairs)
  except LateTickError as e:
    msg = e.msg
  check("a tick into a closed bar raises LATE_TICK_INTO_CLOSED_BAR",
        msg.contains("LATE_TICK_INTO_CLOSED_BAR"))

  var pairs2: seq[tuple[k: Kind, raw: HcjValue]]
  pairs2.add((kCalendar, calRaw()))
  pairs2.add((kConfig, cfgRaw()))
  pairs2.add((kWsFrame, tickRaw("A", "09:00:30+09:00", 100, 10)))
  pairs2.add((kGap, gapRaw(hStr("A"))))
  pairs2.add((kWsFrame, tickRaw("A", "09:00:40+09:00", 100, 15)))
  pairs2.add((kSessionEnd, hNull()))
  var msg2 = ""
  try:
    discard runPairs("late-gap", pairs2)
  except LateTickError as e:
    msg2 = e.msg
  check("a tick into a gap-closed bar is also a late tick",
        msg2.contains("LATE_TICK_INTO_CLOSED_BAR"))

# ------------------------------------------- §3 gap / session_end raw shape
block recordShape:
  proc shapeStream(gapVal, endVal: HcjValue): seq[tuple[k: Kind, raw: HcjValue]] =
    result.add((kCalendar, calRaw()))
    result.add((kConfig, cfgRaw()))
    result.add((kGap, gapVal))
    result.add((kSessionEnd, endVal))

  checkRaises("gap raw that is not an object is rejected", proc () =
    discard runPairs("gap-notobj", shapeStream(hStr("oops"), hNull())))
  checkRaises("gap raw without a symbol field is rejected", proc () =
    discard runPairs("gap-nosym",
      shapeStream(hObj(("reason", hStr("r"))), hNull())))
  checkRaises("gap symbol that is neither string nor null is rejected", proc () =
    discard runPairs("gap-badsym",
      shapeStream(hObj(("symbol", hInt(5))), hNull())))
  checkRaises("session_end raw that is not null is rejected", proc () =
    discard runPairs("end-notnull",
      shapeStream(gapRaw(hNull()), hObj(("x", hInt(1))))))

  var okNull = false
  try:
    okNull = runPairs("gap-null-ok",
      shapeStream(gapRaw(hNull()), hNull())).status == rsOk
  except CatchableError:
    okNull = false
  check("a null-symbol gap record is accepted", okNull)
  ## Documented limitation: a connection-wide gap can only mark symbols
  ## already seen. The record stream carries no subscription list, so when
  ## the gap arrives before any frame (or a subscribed symbol is never seen
  ## at all) Core cannot know which symbols to hold pending, and the run
  ## stays OK. Failing this closed needs a subscription record in the input
  ## contract, not a bars.nim change.
  check("a connection-wide gap before any known symbol stays OK " &
        "(subscribed symbols are unknowable from the stream)", okNull)
  var symGap = ""
  try:
    discard runPairs("gap-sym-ok",
      shapeStream(gapRaw(hStr("A")), hNull()))
  except UnresolvedGapError as e:
    symGap = e.msg
  check("a string-symbol gap record is accepted; the never-confirmed " &
        "symbol fails closed at session_end",
        symGap.contains("symbol_gap_unresolved=A"))

echo ""
echo passes, " passed, ", failures, " failed"
if failures > 0: quit(1)
