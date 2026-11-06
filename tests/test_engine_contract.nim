## Engine contract regression (REPLAY_CONTRACT.md §6, frozen VS-A — the
## symmetric rewrite). Synthetic bars only: no fixtures, no network, no
## clock. Run: nim c -r --path:src tests/test_engine_contract.nim
##
## What this suite pins:
##   - §6 symmetry acceptance: mirroring an input stream's prices around the
##     declared reference (P -> 2·P_ref − P) produces the opposite-direction
##     signal at the same bar indices under the same absolute thresholds,
##     both ways (up->down and down->up)
##   - shared absolute thresholds: each threshold boundary (exactly at the
##     value passes, one price unit below fails) behaves identically in both
##     directions
##   - bearish_rebound_failure is reachable and real (reason:""): the legacy
##     breakdown_unverified hold path no longer exists anywhere
##   - taint handling is symmetric: a tainted evidence bar holds the verdict
##     in both directions with the same reason at the same index, and the
##     judgment resumes only after the taint slides out of the shared window
##   - a degraded bar never yields a machine verdict; holdOnDegraded only
##     decides whether a hold is *reported* (SIGNAL_HELD) or skipped
##   - warmup bars are judgment-gated, not taints
##   - feed order never leaks; signals sort by (symbol, bar_index); real
##     signals carry reason:"" and reference a closed, non-degraded bar
import std/[strutils, algorithm]
import hs/[bars, engine]

var failures = 0
var passes = 0

proc check(name: string; cond: bool; detail = "") =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name, (if detail.len > 0: "  " & detail else: "")

proc show(s: Signal): string =
  s.symbol & "/" & $s.barIndex & "/" & s.signal & "/" & s.reason

proc showAll(ss: seq[Signal]): string =
  for s in ss: result.add(show(s) & ",")

proc mkBar(symbol: string; index: int; o, h, l, c: int64; degraded = false;
           empty = false; pos = "steady"; gapEdge = "";
           outOfOrder = false; volPartial = false): Bar =
  Bar(symbol: symbol, index: index, open: o, high: h, low: l, close: c,
      vol: 100, ticks: 1, pos: pos, sessionClass: "in_session",
      volPartial: volPartial, degraded: degraded, gapEdge: gapEdge,
      outOfOrder: outOfOrder, closeBoundary: false, empty: empty,
      closed: true)

proc flat(symbol: string; index: int; price: int64; degraded = false;
          empty = false; pos = "steady"; gapEdge = "";
          outOfOrder = false; volPartial = false): Bar =
  mkBar(symbol, index, price, price, price, price, degraded, empty, pos,
        gapEdge, outOfOrder, volPartial)

proc emptyGap(symbol: string; index: int): Bar =
  flat(symbol, index, 0, degraded = true, empty = true, pos = "empty_gap",
       gapEdge = "both")

proc engineOf(trendMinBp, countermoveMinBp, triggerBp: int;
              lookbackBars = 3; warmupBars = 0;
              holdOnDegraded = true): Engine =
  initEngine(Params(warmupBars: warmupBars, lookbackBars: lookbackBars,
                    trendMinBp: trendMinBp,
                    countermoveMinBp: countermoveMinBp,
                    directionalTriggerBp: triggerBp,
                    holdOnDegraded: holdOnDegraded), "2026-10-29")

proc feed(e: var Engine; bars: seq[Bar]) =
  for b in bars: e.onBar(b)

proc mirror(bars: seq[Bar]; k: int64): seq[Bar] =
  ## P -> 2k − P for every price; flags are untouched, so bar eligibility
  ## and taint stay identical (equal-magnitude opposite moves, §6).
  for b in bars:
    result.add(Bar(symbol: b.symbol, index: b.index,
                   open: 2 * k - b.open, high: 2 * k - b.low,
                   low: 2 * k - b.high, close: 2 * k - b.close,
                   vol: b.vol, ticks: b.ticks, pos: b.pos,
                   sessionClass: b.sessionClass, volPartial: b.volPartial,
                   degraded: b.degraded, gapEdge: b.gapEdge,
                   outOfOrder: b.outOfOrder, closeBoundary: b.closeBoundary,
                   empty: b.empty, closed: b.closed))

proc upStream(): seq[Bar] =
  ## Clean up pattern with L = 3, anchor A = close(bar 0) = 10000, so one
  ## price unit is exactly 1 bp: rise to a 500 bp pivot (bar 5), pull back
  ## 300 bp (bar 7), recover 200 bp (bar 8). Fires at bar 8 with
  ## T=50, C=50, G=30 — and only there.
  @[flat("AAA", 0, 10000), flat("AAA", 1, 10100), flat("AAA", 2, 10200),
    flat("AAA", 3, 10300), flat("AAA", 4, 10400), flat("AAA", 5, 10500),
    flat("AAA", 6, 10350), flat("AAA", 7, 10200), flat("AAA", 8, 10400)]

proc downStream(): seq[Bar] =
  ## The independent down pattern (not mirror(upStream)): fall to a 500 bp
  ## pivot (bar 5), rebound 300 bp (bar 7), break down 200 bp (bar 8).
  @[flat("AAA", 0, 10000), flat("AAA", 1, 9900), flat("AAA", 2, 9800),
    flat("AAA", 3, 9700), flat("AAA", 4, 9600), flat("AAA", 5, 9500),
    flat("AAA", 6, 9650), flat("AAA", 7, 9800), flat("AAA", 8, 9600)]

# ------------------------------------------------ §6 mirror acceptance
block mirrorAcceptance:
  ## The acceptance test of the rewrite: mirroring around the declared
  ## reference must flip the verdict direction at identical bar indices,
  ## with identical thresholds — both ways.
  var up = engineOf(50, 50, 30)
  feed(up, upStream())
  check("the clean up pattern fires bullish at bar 8",
        showAll(up.sortedSignals()) == "AAA/8/bullish_pullback_reversal/,",
        "got " & showAll(up.sortedSignals()))

  var upMirrored = engineOf(50, 50, 30)
  feed(upMirrored, mirror(upStream(), 10000))
  check("mirroring the up stream fires bearish at the same bar index",
        showAll(upMirrored.sortedSignals()) == "AAA/8/bearish_rebound_failure/,",
        "got " & showAll(upMirrored.sortedSignals()))

  var down = engineOf(50, 50, 30)
  feed(down, downStream())
  check("the clean down pattern fires bearish at bar 8",
        showAll(down.sortedSignals()) == "AAA/8/bearish_rebound_failure/,",
        "got " & showAll(down.sortedSignals()))

  var downMirrored = engineOf(50, 50, 30)
  feed(downMirrored, mirror(downStream(), 10000))
  check("mirroring the down stream fires bullish at the same bar index",
        showAll(downMirrored.sortedSignals()) == "AAA/8/bullish_pullback_reversal/,",
        "got " & showAll(downMirrored.sortedSignals()))

# --------------------------------------- boundary thresholds, both ways
block thresholdBoundaries:
  ## One price unit is 1 bp (anchor 10000). Each stage keeps its move fixed
  ## and probes the threshold at exactly the move (>= passes) and one unit
  ## above it (fails), in both directions — the mirrored stream shares the
  ## probe, so both directions sit on the identical boundary.
  proc probeTrend(trendBp: int; up: bool): string =
    ## Fixed move: the pivot stands exactly 500 bp above the anchor.
    var hs: seq[Bar] = @[flat("AAA", 0, 10000), flat("AAA", 1, 10100),
      flat("AAA", 2, 10200), flat("AAA", 3, 10300), flat("AAA", 4, 10400),
      flat("AAA", 5, 10500), flat("AAA", 6, 10350), flat("AAA", 7, 10200),
      flat("AAA", 8, 10400)]
    if not up: hs = mirror(hs, 10000)
    var e = engineOf(trendBp, 50, 30)
    feed(e, hs)
    showAll(e.sortedSignals())
  for up in [true, false]:
    let dir = if up: "up" else: "down"
    check("trend at exactly trend_min_bp confirms (" & dir & ")",
          probeTrend(500, up) ==
            (if up: "AAA/8/bullish_pullback_reversal/," else: "AAA/8/bearish_rebound_failure/,"),
          "got " & probeTrend(500, up))
    check("trend one unit below trend_min_bp fails (" & dir & ")",
          probeTrend(501, up) == "", "got " & probeTrend(501, up))

  proc probeCountermove(countermoveBp: int; up: bool): string =
    ## Fixed move: the pullback/rebound retraces exactly 300 bp (pivot
    ## 10500 -> counter-move extreme 10200).
    var hs: seq[Bar] = @[flat("AAA", 0, 10000), flat("AAA", 1, 10100),
      flat("AAA", 2, 10200), flat("AAA", 3, 10300), flat("AAA", 4, 10400),
      flat("AAA", 5, 10500), flat("AAA", 6, 10350), flat("AAA", 7, 10200),
      flat("AAA", 8, 10400)]
    if not up: hs = mirror(hs, 10000)
    var e = engineOf(50, countermoveBp, 30)
    feed(e, hs)
    showAll(e.sortedSignals())
  for up in [true, false]:
    let dir = if up: "up" else: "down"
    check("countermove at exactly countermove_min_bp confirms (" & dir & ")",
          probeCountermove(300, up) ==
            (if up: "AAA/8/bullish_pullback_reversal/," else: "AAA/8/bearish_rebound_failure/,"),
          "got " & probeCountermove(300, up))
    check("countermove one unit below countermove_min_bp fails (" & dir & ")",
          probeCountermove(301, up) == "", "got " & probeCountermove(301, up))

  proc probeTrigger(triggerBp: int; up: bool): string =
    ## Fixed move: the current close recovers exactly 200 bp from the
    ## counter-move extreme (10200 -> 10400).
    var hs: seq[Bar] = @[flat("AAA", 0, 10000), flat("AAA", 1, 10100),
      flat("AAA", 2, 10200), flat("AAA", 3, 10300), flat("AAA", 4, 10400),
      flat("AAA", 5, 10500), flat("AAA", 6, 10350), flat("AAA", 7, 10200),
      flat("AAA", 8, 10400)]
    if not up: hs = mirror(hs, 10000)
    var e = engineOf(50, 50, triggerBp)
    feed(e, hs)
    showAll(e.sortedSignals())
  for up in [true, false]:
    let dir = if up: "up" else: "down"
    check("trigger at exactly directional_trigger_bp fires (" & dir & ")",
          probeTrigger(200, up) ==
            (if up: "AAA/8/bullish_pullback_reversal/," else: "AAA/8/bearish_rebound_failure/,"),
          "got " & probeTrigger(200, up))
    check("trigger one unit below directional_trigger_bp fails (" & dir & ")",
          probeTrigger(201, up) == "", "got " & probeTrigger(201, up))

# -------------------------- the bearish verdict is real, not held, forever
block bearishReachable:
  ## The legacy engine held every bearish candidate as
  ## SIGNAL_HELD reason="breakdown_unverified". The symmetric rewrite fires
  ## the real verdict; no output may ever carry that reason again.
  var held = engineOf(50, 50, 30)
  feed(held, downStream())
  check("bearish_rebound_failure fires with reason \"\"",
        showAll(held.sortedSignals()) == "AAA/8/bearish_rebound_failure/,",
        "got " & showAll(held.sortedSignals()))
  check("the real bearish verdict survives holdOnDegraded=false",
        block:
          var silent = engineOf(50, 50, 30, holdOnDegraded = false)
          feed(silent, downStream())
          showAll(silent.sortedSignals()) == "AAA/8/bearish_rebound_failure/,")
  var sawLegacyHold = false
  for src in [upStream(), downStream(), mirror(upStream(), 10000),
              mirror(downStream(), 10000)]:
    var e = engineOf(50, 50, 30)
    feed(e, src)
    for s in e.sortedSignals():
      if s.reason.contains("breakdown_unverified"): sawLegacyHold = true
  check("no output ever carries the legacy breakdown_unverified reason",
        not sawLegacyHold)

# ------------------------------------------- held replaces a verdict
block heldVocabulary:
  ## Thresholds are unreachable so no verdict can interfere; only the hold
  ## path is exercised over every degrade flavor of §5/§6.
  var e = engineOf(20000, 20000, 20000, lookbackBars = 2)
  feed(e, @[
    flat("AAA", 0, 100, degraded = true, pos = "first_after_sub"),
    flat("AAA", 1, 100),
    emptyGap("AAA", 2),
    flat("AAA", 3, 100, degraded = true, outOfOrder = true),
    flat("AAA", 4, 100, degraded = true, pos = "after_gap", gapEdge = "after"),
    flat("AAA", 5, 100, degraded = true),
    flat("AAA", 6, 100)])
  check("each degraded bar is held once with its §6 reason",
        showAll(e.sortedSignals()) ==
          "AAA/0/SIGNAL_HELD/first_after_sub,AAA/2/SIGNAL_HELD/empty_gap," &
          "AAA/3/SIGNAL_HELD/out_of_order,AAA/4/SIGNAL_HELD/gap," &
          "AAA/5/SIGNAL_HELD/flag_conflict,",
        "got " & showAll(e.sortedSignals()))

# ------------------------ empty_gap reference fabricates no trend (either way)
block emptyGapNoFabricatedTrend:
  ## The market falls 50000 -> 10000 (-80%); the only "uptrend" evidence is
  ## the empty_gap bar's placeholder close of 0. The anchor skips tainted
  ## bars (it is bar 1, 40000), so no bullish trend can confirm; mirroring
  ## the stream confirms no bearish trend either, because the anchor of the
  ## mirror is the mirror of the anchor.
  proc stream(): seq[Bar] =
    @[flat("AAA", 0, 50000, degraded = true, pos = "first_after_sub"),
      flat("AAA", 1, 40000), flat("AAA", 2, 30000), flat("AAA", 3, 25000),
      emptyGap("AAA", 4), flat("AAA", 5, 20000), flat("AAA", 6, 10000),
      mkBar("AAA", 7, 10000, 10450, 9900, 10400)]
  var e = engineOf(50, 50, 30)
  feed(e, stream())
  check("no verdict derives from an empty_gap reference bar",
        showAll(e.sortedSignals()) ==
          "AAA/0/SIGNAL_HELD/first_after_sub,AAA/4/SIGNAL_HELD/empty_gap,",
        "got " & showAll(e.sortedSignals()))
  var m = engineOf(50, 50, 30)
  feed(m, mirror(stream(), 40000))
  check("the mirrored stream fabricates no trend either",
        showAll(m.sortedSignals()) ==
          "AAA/0/SIGNAL_HELD/first_after_sub,AAA/4/SIGNAL_HELD/empty_gap,",
        "got " & showAll(m.sortedSignals()))

# ------------------------------------- degraded bars never yield verdicts
block degradedNeverVerdict:
  proc stream(): seq[Bar] =
    @[flat("AAA", 0, 20000), flat("AAA", 1, 15000), flat("AAA", 2, 12000),
      flat("AAA", 3, 11000, degraded = true, outOfOrder = true)]
  var held = engineOf(50, 30, 50, lookbackBars = 2)
  feed(held, stream())
  check("degraded bar is held when holdOnDegraded=true",
        showAll(held.sortedSignals()) == "AAA/3/SIGNAL_HELD/out_of_order,",
        "got " & showAll(held.sortedSignals()))
  var silent = engineOf(50, 30, 50, lookbackBars = 2, holdOnDegraded = false)
  feed(silent, stream())
  check("holdOnDegraded=false skips the bar and never emits a verdict",
        silent.sortedSignals().len == 0,
        "got " & showAll(silent.sortedSignals()))

# --------------------------------------------- taint holds both directions
block taintSymmetry:
  ## The same vol_partial taint inside the shared window of the would-fire
  ## bar holds the verdict in both directions — same index, same reason —
  ## and the identical clean stream fires.
  proc stream(taint: bool): seq[Bar] =
    @[flat("AAA", 0, 10000), flat("AAA", 1, 10100), flat("AAA", 2, 10200),
      flat("AAA", 3, 10300), flat("AAA", 4, 10400), flat("AAA", 5, 10500),
      flat("AAA", 6, 10350, volPartial = taint), flat("AAA", 7, 10200),
      flat("AAA", 8, 10400)]
  var tainted = engineOf(50, 50, 30)
  feed(tainted, stream(true))
  check("a vol_partial bar in the window holds the up verdict (degraded_bar)",
        showAll(tainted.sortedSignals()) == "AAA/8/SIGNAL_HELD/degraded_bar,",
        "got " & showAll(tainted.sortedSignals()))
  var taintedMirror = engineOf(50, 50, 30)
  feed(taintedMirror, mirror(stream(true), 10000))
  check("the mirrored taint holds the down verdict identically",
        showAll(taintedMirror.sortedSignals()) == "AAA/8/SIGNAL_HELD/degraded_bar,",
        "got " & showAll(taintedMirror.sortedSignals()))
  var clean = engineOf(50, 50, 30)
  feed(clean, stream(false))
  check("the same stream without vol_partial still fires",
        showAll(clean.sortedSignals()) == "AAA/8/bullish_pullback_reversal/,",
        "got " & showAll(clean.sortedSignals()))

# ------------------ taint reason priority: the most recent tainted bar wins
block taintReasonPriority:
  ## Two taints inside the window (after_gap at 5, vol_partial at 6): the
  ## hold reports the most recent one — the taint that binds the window
  ## longest. Mirrored, the identical reason appears at the identical index.
  proc stream(): seq[Bar] =
    @[flat("AAA", 0, 10000), flat("AAA", 1, 10100), flat("AAA", 2, 10200),
      flat("AAA", 3, 10300), flat("AAA", 4, 10400),
      flat("AAA", 5, 10500, degraded = true, pos = "after_gap",
           gapEdge = "after"),
      flat("AAA", 6, 10350, volPartial = true), flat("AAA", 7, 10200),
      flat("AAA", 8, 10400)]
  var e = engineOf(50, 50, 30)
  feed(e, stream())
  check("the most recent taint's reason binds the hold",
        showAll(e.sortedSignals()) ==
          "AAA/5/SIGNAL_HELD/gap,AAA/8/SIGNAL_HELD/degraded_bar,",
        "got " & showAll(e.sortedSignals()))
  var m = engineOf(50, 50, 30)
  feed(m, mirror(stream(), 10000))
  check("the mirrored stream holds with the identical reason",
        showAll(m.sortedSignals()) ==
          "AAA/5/SIGNAL_HELD/gap,AAA/8/SIGNAL_HELD/degraded_bar,",
        "got " & showAll(m.sortedSignals()))

# ------------------- the judgment resumes once the window slides past taint
block taintWindowResume:
  ## One vol_partial bar at index 5. The same would-fire pattern appears at
  ## bars 8 (window [5,8] — tainted, held) and 9 (window [6,9] — clean,
  ## fires). Bar 5 itself is not degraded, so only the verdict is held.
  proc stream(): seq[Bar] =
    @[flat("AAA", 0, 10000), flat("AAA", 1, 10100), flat("AAA", 2, 10200),
      flat("AAA", 3, 10300), flat("AAA", 4, 10400),
      flat("AAA", 5, 10500, volPartial = true), flat("AAA", 6, 10350),
      flat("AAA", 7, 10200), flat("AAA", 8, 10300), flat("AAA", 9, 10400)]
  var e = engineOf(50, 50, 30)
  feed(e, stream())
  check("the verdict is held while the taint is inside the window and " &
        "resumes once it slides out",
        showAll(e.sortedSignals()) ==
          "AAA/8/SIGNAL_HELD/degraded_bar,AAA/9/bullish_pullback_reversal/,",
        "got " & showAll(e.sortedSignals()))
  var m = engineOf(50, 50, 30)
  feed(m, mirror(stream(), 10000))
  check("mirrored: held and resumed at the identical indices",
        showAll(m.sortedSignals()) ==
          "AAA/8/SIGNAL_HELD/degraded_bar,AAA/9/bearish_rebound_failure/,",
        "got " & showAll(m.sortedSignals()))

# ------------------------------- an empty_gap bar inside the evidence window
block emptyGapEvidenceWindow:
  var e = engineOf(50, 50, 30)
  feed(e, @[
    flat("AAA", 0, 10000), flat("AAA", 1, 10100), flat("AAA", 2, 10200),
    flat("AAA", 3, 10300), flat("AAA", 4, 10400), flat("AAA", 5, 10500),
    emptyGap("AAA", 6), flat("AAA", 7, 10200), flat("AAA", 8, 10400)])
  check("an empty_gap bar inside the shared window holds the verdict",
        showAll(e.sortedSignals()) ==
          "AAA/6/SIGNAL_HELD/empty_gap,AAA/8/SIGNAL_HELD/empty_gap,",
        "got " & showAll(e.sortedSignals()))

# -------------------------------- warmup gates judgment, it is not a taint
block warmupGates:
  var gated = engineOf(50, 50, 30, warmupBars = 9)
  feed(gated, upStream())
  check("warmup_bars gates the judgment silently (no hold, no verdict)",
        gated.sortedSignals().len == 0,
        "got " & showAll(gated.sortedSignals()))
  var control = engineOf(50, 50, 30, warmupBars = 8)
  feed(control, upStream())
  check("the same stream with a lower warmup fires at bar 8",
        showAll(control.sortedSignals()) == "AAA/8/bullish_pullback_reversal/,",
        "got " & showAll(control.sortedSignals()))
  var heldWarm = engineOf(50, 50, 30, warmupBars = 8)
  feed(heldWarm, @[flat("AAA", 0, 10000, degraded = true, pos = "first_after_sub")])
  check("a degraded bar inside warmup is still held as a bar",
        showAll(heldWarm.sortedSignals()) == "AAA/0/SIGNAL_HELD/first_after_sub,",
        "got " & showAll(heldWarm.sortedSignals()))

# ----------------------------- no clean bar yet: no anchor, no verdicts
block noAnchorNoVerdict:
  ## Every bar carries a taint, so no declared reference price exists and no
  ## verdict is derivable — even with trivially-met thresholds.
  var e = engineOf(0, 0, 0)
  feed(e, @[
    flat("AAA", 0, 10000, degraded = true, pos = "first_after_sub"),
    emptyGap("AAA", 1), flat("AAA", 2, 10000, volPartial = true),
    flat("AAA", 3, 10000, volPartial = true)])
  check("without a clean anchor bar no verdict is derivable",
        showAll(e.sortedSignals()) ==
          "AAA/0/SIGNAL_HELD/first_after_sub,AAA/1/SIGNAL_HELD/empty_gap,",
        "got " & showAll(e.sortedSignals()))

# -------------------------------- holdOnDegraded=false silences holds only
block windowHoldNotReported:
  proc stream(): seq[Bar] =
    @[flat("CCC", 0, 10000), flat("CCC", 1, 10000), flat("CCC", 2, 10000),
      flat("CCC", 3, 10000), flat("CCC", 4, 10000, degraded = true),
      flat("CCC", 5, 10000, volPartial = true), flat("CCC", 6, 10000),
      flat("CCC", 7, 10000, volPartial = true)]
  var silent = engineOf(50, 50, 30, holdOnDegraded = false)
  feed(silent, stream())
  check("holdOnDegraded=false suppresses the window hold and the verdict",
        silent.sortedSignals().len == 0,
        "got " & showAll(silent.sortedSignals()))

# ------------------------------------------------------------- §6 invariants
block signalInvariants:
  proc stream(sym: string): seq[Bar] =
    result.add(flat(sym, 0, 50000, degraded = true, pos = "first_after_sub"))
    result.add(flat(sym, 1, 40000))
    result.add(flat(sym, 2, 30000))
    result.add(emptyGap(sym, 3))
    result.add(flat(sym, 4, 20000))
    result.add(flat(sym, 5, 10500))
    result.add(mkBar(sym, 6, 10000, 10450, 9900, 10400))

  var a = engineOf(50, 50, 30)
  var inter: seq[Bar]
  for i in 0 .. 6:
    inter.add(stream("BBB")[i])
    inter.add(stream("ZZZ")[i])
  inter.add(upStream())
  feed(a, inter)
  var b = engineOf(50, 50, 30)
  feed(b, stream("ZZZ") & stream("BBB") & upStream())
  let sa = a.sortedSignals()
  check("feed order never leaks into sorted output",
        showAll(sa) == showAll(b.sortedSignals()))
  var ordered = true
  for i in 1 ..< sa.len:
    let (x, y) = (sa[i - 1], sa[i])
    if cmp(x.symbol, y.symbol) > 0 or
        (x.symbol == y.symbol and x.barIndex > y.barIndex):
      ordered = false
  check("signals sort by (symbol, bar_index)", ordered)
  const vocab = ["gap", "empty_gap", "out_of_order", "first_after_sub",
                 "flag_conflict", "degraded_bar"]
  var reasonsOk = true
  var realOk = true
  for s in sa:
    if s.signal == "SIGNAL_HELD":
      if s.reason notin vocab: reasonsOk = false
    else:
      if s.reason != "": reasonsOk = false
      var found = false
      for bar in inter:
        if bar.symbol == s.symbol and bar.index == s.barIndex:
          found = bar.closed and not bar.degraded
      if not found: realOk = false
  check("held reasons stay in the §6 vocabulary, real signals carry reason \"\"",
        reasonsOk)
  check("a real signal only references a closed, non-degraded bar", realOk)

echo ""
echo passes, " passed, ", failures, " failed"
if failures > 0: quit(1)
