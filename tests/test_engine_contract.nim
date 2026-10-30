## Engine contract regression (REPLAY_CONTRACT.md §6 Signals, v6.2).
## Synthetic bars only: no fixtures, no network, no clock. Run:
##   nim c -r --path:src tests/test_engine_contract.nim
##
## Fail-closed rules enforced here (fix, regression-tested):
##   - a degraded bar never yields a machine verdict; holdOnDegraded only
##     decides whether the hold is *reported* (SIGNAL_HELD) or skipped
##   - a verdict must not be derived from an empty_gap bar's placeholder
##     prices (OHLC 0 by construction) as trend reference or recovery base
##   - a verdict must not be derived from an evidence window that still
##     contains a degraded/vol_partial/gap/empty bar. Each machine checks
##     only the bars it actually reads (bullish: 2L bars back through the
##     priorHigh scan, prev and refBar; bearish: L bars back through the
##     priorLow/maxHigh scan and refBar) and resumes only after the last
##     tainted bar has slid out of *that* window. A suppressed verdict is
##     reported as SIGNAL_HELD carrying the most recent tainted bar's
##     reason; holdOnDegraded=false suppresses it silently.
##   - breakdownBp has no approved reference price or comparison rule, so
##     the bearish verdict fails closed: a clean window reaches the
##     breakdown gate and reports SIGNAL_HELD reason="breakdown_unverified"
##     (silent when holdOnDegraded=false). A tainted window keeps reporting
##     the taint's own reason — the contamination window handling has
##     priority and is unchanged. The bullish machine is unaffected.
##
## Documented gaps pinned here (current behavior; changing them needs a plan,
##   not a silent patch):
##   - breakdownBp is parsed from config but no code path reads it, and no
##     meaning/formula may be invented for it before the strategy contract
##     approves one; bearish_rebound_failure is unreachable until then
##   - tainted bars stay in history and keep their prices; only verdicts
##     derived from a window containing them are held
##   - a bare `degraded` bar is held as flag_conflict; the degraded_bar
##     reason is the fallback for a vol_partial-only taint (Bar carries no
##     cause field for it)
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

proc emptyGap(symbol: string; index: int): Bar =
  mkBar(symbol, index, 0, 0, 0, 0, degraded = true, empty = true,
        pos = "empty_gap", gapEdge = "both")

proc engineOf(pullbackMinBp, recoveryBp, reboundMinBp, breakdownBp: int;
              lookback = 3; warmupBars = 0;
              holdOnDegraded = true): Engine =
  initEngine(Params(lookback: lookback, pullbackMinBp: pullbackMinBp,
                    recoveryBp: recoveryBp, reboundMinBp: reboundMinBp,
                    breakdownBp: breakdownBp, warmupBars: warmupBars,
                    holdOnDegraded: holdOnDegraded), "2026-10-29")

proc feed(e: var Engine; bars: seq[Bar]) =
  for b in bars: e.onBar(b)

# ------------------------------------------------- held replaces a verdict
block heldVocabulary:
  ## Thresholds are unreachable so no machine verdict can interfere; only
  ## the hold path is exercised over every degrade flavor of §5/§6.
  var e = engineOf(20000, 20000, 20000, 30, lookback = 2)
  feed(e, @[
    mkBar("AAA", 0, 100, 100, 100, 100, degraded = true,
          pos = "first_after_sub"),
    mkBar("AAA", 1, 100, 100, 100, 100),
    emptyGap("AAA", 2),
    mkBar("AAA", 3, 100, 100, 100, 100, degraded = true, outOfOrder = true),
    mkBar("AAA", 4, 100, 100, 100, 100, degraded = true, pos = "after_gap",
          gapEdge = "after"),
    mkBar("AAA", 5, 100, 100, 100, 100, degraded = true),
    mkBar("AAA", 6, 100, 100, 100, 100)])
  check("each degraded bar is held once with its §6 reason",
        showAll(e.sortedSignals()) ==
          "AAA/0/SIGNAL_HELD/first_after_sub,AAA/2/SIGNAL_HELD/empty_gap," &
          "AAA/3/SIGNAL_HELD/out_of_order,AAA/4/SIGNAL_HELD/gap," &
          "AAA/5/SIGNAL_HELD/flag_conflict,",
        "got " & showAll(e.sortedSignals()))

# --------------------------------------- empty_gap reference fabricates nothing
block emptyGapNoFabricatedTrend:
  ## The market falls 50000 -> 10000 (-80%); the only "uptrend" evidence is
  ## the empty_gap reference bar's placeholder close of 0. The bullish gate
  ## must not pass on that (pre-fix it emitted bullish_pullback_reversal).
  var e = engineOf(50, 30, 50, 30)
  feed(e, @[
    mkBar("AAA", 0, 50000, 50000, 50000, 50000, degraded = true,
          pos = "first_after_sub"),
    mkBar("AAA", 1, 40000, 40000, 40000, 40000),
    mkBar("AAA", 2, 30000, 30000, 30000, 30000),
    mkBar("AAA", 3, 25000, 25000, 25000, 25000),
    emptyGap("AAA", 4),
    mkBar("AAA", 5, 20000, 20000, 20000, 20000),
    mkBar("AAA", 6, 10500, 10500, 9900, 10000),
    mkBar("AAA", 7, 10000, 10450, 9900, 10400)])
  check("no verdict derives from an empty_gap reference bar",
        showAll(e.sortedSignals()) ==
          "AAA/0/SIGNAL_HELD/first_after_sub,AAA/4/SIGNAL_HELD/empty_gap,",
        "got " & showAll(e.sortedSignals()))

# ------------------------------------- degraded bars never yield real verdicts
block degradedNeverVerdict:
  proc stream(): seq[Bar] =
    @[mkBar("AAA", 0, 20000, 20000, 20000, 20000),
      mkBar("AAA", 1, 15000, 15000, 15000, 15000),
      mkBar("AAA", 2, 12000, 12000, 12000, 12000),
      mkBar("AAA", 3, 11500, 11500, 11000, 11000, degraded = true,
            outOfOrder = true)]
  var held = engineOf(50, 30, 50, 30, lookback = 2, holdOnDegraded = true)
  feed(held, stream())
  check("degraded bar is held when holdOnDegraded=true",
        showAll(held.sortedSignals()) == "AAA/3/SIGNAL_HELD/out_of_order,",
        "got " & showAll(held.sortedSignals()))
  var silent = engineOf(50, 30, 50, 30, lookback = 2, holdOnDegraded = false)
  feed(silent, stream())
  check("holdOnDegraded=false skips the bar and never emits a verdict",
        silent.sortedSignals().len == 0,
        "got " & showAll(silent.sortedSignals()))

# ---------------------------------------- breakdown_unverified fail-close
block breakdownBpUnverified:
  ## breakdownBp's reference price and comparison rule are unapproved, so
  ## the bearish decision fails closed rather than firing a threshold-less
  ## breakdown: SIGNAL_HELD reason="breakdown_unverified", silent when
  ## holdOnDegraded=false. No code path reads breakdownBp, so the outcome is
  ## invariant to its value — the pre-fix behavior (bearish firing on a
  ## 1-unit break regardless of breakdown_bp=9000) was exactly the safety
  ## hole this pins shut.
  proc stream(): seq[Bar] =
    @[mkBar("AAA", 0, 10000, 10000, 10000, 10000),
      mkBar("AAA", 1, 9000, 9000, 9000, 9000),
      mkBar("AAA", 2, 9900, 9900, 9900, 9900),
      mkBar("AAA", 3, 9000, 9000, 8999, 8999)]
  var outputs: seq[string]
  for bd in [0, 30, 9000]:
    var e = engineOf(50, 30, 50, bd, lookback = 2)
    feed(e, stream())
    outputs.add(showAll(e.sortedSignals()))
    check("breakdown_bp=" & $bd &
          ": no bearish verdict fires, the hold is explicit",
          outputs[^1] == "AAA/3/SIGNAL_HELD/breakdown_unverified,",
          "got " & outputs[^1])
  var trivial = engineOf(50, 30, 0, 9000, lookback = 2)
  feed(trivial, stream())
  check("a trivially-met rebound threshold still fails closed",
        showAll(trivial.sortedSignals()) ==
          "AAA/3/SIGNAL_HELD/breakdown_unverified,",
        "got " & showAll(trivial.sortedSignals()))
  check("output is invariant to breakdown_bp (no code path reads it)",
        outputs[0] == outputs[1] and outputs[1] == outputs[2],
        outputs.join(" | "))
  var silent = engineOf(50, 30, 50, 9000, lookback = 2, holdOnDegraded = false)
  feed(silent, stream())
  check("holdOnDegraded=false silences the breakdown_unverified hold",
        silent.sortedSignals().len == 0,
        "got " & showAll(silent.sortedSignals()))

# ------------------ taint reason priority over the breakdown gate (bearish)
block breakdownVsTaintPriority:
  ## The same would-fire bearish pattern at bar 7, three windows:
  ##   AAA: tainted refBar at 4        -> reason flag_conflict (taint wins)
  ##   BBB: clean window               -> reason breakdown_unverified
  ##   CCC: taints at 4 and at 5       -> reason gap (most recent taint)
  ## The contamination window handling keeps its own reason and priority;
  ## the breakdown gate only speaks for a clean window.
  proc flat(sym: string; index: int; price: int64; degraded = false): Bar =
    mkBar(sym, index, price, price, price, price, degraded = degraded)
  var e = engineOf(50, 30, 50, 30)
  feed(e, @[
    flat("AAA", 0, 10000), flat("AAA", 1, 10000), flat("AAA", 2, 10000),
    flat("AAA", 3, 10000), flat("AAA", 4, 10000, degraded = true),
    flat("AAA", 5, 9000), flat("AAA", 6, 9900),
    mkBar("AAA", 7, 9000, 9000, 8999, 8999),
    flat("BBB", 0, 10000), flat("BBB", 1, 10000), flat("BBB", 2, 10000),
    flat("BBB", 3, 10000), flat("BBB", 4, 10000), flat("BBB", 5, 9000),
    flat("BBB", 6, 9900),
    mkBar("BBB", 7, 9000, 9000, 8999, 8999),
    flat("CCC", 0, 10000), flat("CCC", 1, 10000), flat("CCC", 2, 10000),
    flat("CCC", 3, 10000), flat("CCC", 4, 10000, degraded = true),
    mkBar("CCC", 5, 9000, 9000, 9000, 9000, degraded = true,
          pos = "after_gap", gapEdge = "after", volPartial = true),
    flat("CCC", 6, 9900),
    mkBar("CCC", 7, 9000, 9000, 8999, 8999)])
  check("a tainted window reports the taint reason, not breakdown_unverified",
        showAll(e.sortedSignals()) ==
          "AAA/4/SIGNAL_HELD/flag_conflict," &
          "AAA/7/SIGNAL_HELD/flag_conflict," &
          "BBB/7/SIGNAL_HELD/breakdown_unverified," &
          "CCC/4/SIGNAL_HELD/flag_conflict,CCC/5/SIGNAL_HELD/gap," &
          "CCC/7/SIGNAL_HELD/gap,",
        "got " & showAll(e.sortedSignals()))

# ------------------------------------- degraded evidence fails the verdict
block degradedEvidenceFailsClosed:
  ## A degraded bar stays in history, but a verdict whose window contains it
  ## is held (pre-fix bar 4 emitted bullish_pullback_reversal with the
  ## out_of_order bar 3 as its recovery base). The hold carries the tainted
  ## evidence's own reason.
  var e = engineOf(50, 30, 50, 30)
  feed(e, @[
    mkBar("AAA", 0, 10000, 10000, 10000, 10000),
    mkBar("AAA", 1, 11000, 11000, 11000, 11000),
    mkBar("AAA", 2, 12000, 12000, 12000, 12000),
    mkBar("AAA", 3, 12100, 12100, 11700, 11800, degraded = true,
          outOfOrder = true),
    mkBar("AAA", 4, 11600, 12200, 11600, 12200)])
  check("a verdict over a degraded evidence bar is held with its reason",
        showAll(e.sortedSignals()) ==
          "AAA/3/SIGNAL_HELD/out_of_order,AAA/4/SIGNAL_HELD/out_of_order,",
        "got " & showAll(e.sortedSignals()))

# -------------------------- empty_gap inside the evidence window (bullish)
block emptyGapEvidenceWindow:
  ## The empty bar's placeholder close (0) never raises priorHigh, so the
  ## old machine silently fired a bullish verdict whose 2L-bar lookback
  ## contained a bar that never traded (pre-fix bar 4 emitted
  ## bullish_pullback_reversal). The window rule holds it instead.
  var e = engineOf(50, 30, 50, 30)
  feed(e, @[
    mkBar("AAA", 0, 10000, 10000, 10000, 10000),
    mkBar("AAA", 1, 11000, 11000, 11000, 11000),
    emptyGap("AAA", 2),
    mkBar("AAA", 3, 12000, 12000, 12000, 12000),
    mkBar("AAA", 4, 11600, 12200, 11600, 12200)])
  check("an empty_gap bar inside the priorHigh window holds the verdict",
        showAll(e.sortedSignals()) ==
          "AAA/2/SIGNAL_HELD/empty_gap,AAA/4/SIGNAL_HELD/empty_gap,",
        "got " & showAll(e.sortedSignals()))

# ------------------------------------- vol_partial alone taints the window
block volPartialWindow:
  ## vol_partial without degraded never occurs in builder output, but the
  ## engine must still fail closed on it. The vol_partial bar itself is not
  ## degraded, so it is not held as a bar — only the verdict over it is.
  proc stream(volPartial: bool): seq[Bar] =
    @[mkBar("AAA", 0, 10000, 10000, 10000, 10000),
      mkBar("AAA", 1, 11000, 11000, 11000, 11000),
      mkBar("AAA", 2, 12000, 12000, 12000, 12000),
      mkBar("AAA", 3, 12100, 12100, 11700, 11800, volPartial = volPartial),
      mkBar("AAA", 4, 11600, 12200, 11600, 12200)]
  var tainted = engineOf(50, 30, 50, 30)
  feed(tainted, stream(true))
  check("a vol_partial bar in the window holds the verdict (degraded_bar)",
        showAll(tainted.sortedSignals()) == "AAA/4/SIGNAL_HELD/degraded_bar,",
        "got " & showAll(tainted.sortedSignals()))
  var clean = engineOf(50, 30, 50, 30)
  feed(clean, stream(false))
  check("the same stream without vol_partial still fires",
        showAll(clean.sortedSignals()) == "AAA/4/bullish_pullback_reversal/,",
        "got " & showAll(clean.sortedSignals()))

# ------------------ gap evidence fails closed, resumes only past the window
block gapWindowResume:
  ## One after_gap bar at index 3. The same would-fire pullback pattern is
  ## presented at bars 4, 8, 9 and 10: the bullish window is [i-2L, i] with
  ## 2L = 6, so bar 3 is inside the windows of 4..9 and outside from 10 on.
  ## Bars 5-7 stay flat to show that a held *verdict* is only reported where
  ## a verdict would actually have fired.
  var e = engineOf(50, 30, 50, 30)
  feed(e, @[
    mkBar("AAA", 0, 10000, 10000, 10000, 10000),
    mkBar("AAA", 1, 11000, 11000, 11000, 11000),
    mkBar("AAA", 2, 12000, 12000, 12000, 12000),
    mkBar("AAA", 3, 12100, 12100, 11700, 11800, degraded = true,
          pos = "after_gap", gapEdge = "after", volPartial = true),
    mkBar("AAA", 4, 11600, 12200, 11600, 12200),
    mkBar("AAA", 5, 12200, 12200, 12200, 12200),
    mkBar("AAA", 6, 12200, 12200, 12200, 12200),
    mkBar("AAA", 7, 12200, 12200, 12200, 12200),
    mkBar("AAA", 8, 12200, 12300, 11600, 12300),
    mkBar("AAA", 9, 12200, 12400, 11500, 12400),
    mkBar("AAA", 10, 12200, 12500, 11500, 12500)])
  check("gap evidence holds the verdict while inside the window, " &
        "the machine resumes only after the window slides past it",
        showAll(e.sortedSignals()) ==
          "AAA/3/SIGNAL_HELD/gap,AAA/4/SIGNAL_HELD/gap," &
          "AAA/8/SIGNAL_HELD/gap,AAA/9/SIGNAL_HELD/gap," &
          "AAA/10/bullish_pullback_reversal/,",
        "got " & showAll(e.sortedSignals()))

# ------------------------- the window is each machine's own, not a global
block windowScopePerStrategy:
  ## Same taint position, different machines. With L = 3 at verdict bar 7:
  ## the bearish window is [4,7], the bullish window is [1,7].
  ##   BBB: taint at 3 (outside bearish window) -> window clean, so the
  ##        bearish verdict reaches the breakdown gate and is held as
  ##        breakdown_unverified (the window handling itself is unaffected)
  ##   CCC: taint at 3 (inside bullish window)  -> bullish held
  ##   DDD: taint at 0 (outside bullish window) -> bullish fires
  ##   EEE: taint at 4 (the bearish refBar)     -> bearish held with the
  ##        taint's reason, which takes priority over breakdown_unverified
  proc flat(sym: string; index: int; price: int64; degraded = false): Bar =
    mkBar(sym, index, price, price, price, price, degraded = degraded)
  var e = engineOf(50, 30, 50, 30)
  feed(e, @[
    flat("BBB", 0, 10000), flat("BBB", 1, 10000), flat("BBB", 2, 10000),
    flat("BBB", 3, 10000, degraded = true), flat("BBB", 4, 10000),
    flat("BBB", 5, 9000), flat("BBB", 6, 9900),
    mkBar("BBB", 7, 9000, 9000, 8999, 8999),
    flat("CCC", 0, 10000), flat("CCC", 1, 10000), flat("CCC", 2, 10000),
    flat("CCC", 3, 10000, degraded = true), flat("CCC", 4, 11000),
    flat("CCC", 5, 12000), flat("CCC", 6, 11500),
    mkBar("CCC", 7, 11600, 12300, 11600, 12300),
    flat("DDD", 0, 10000, degraded = true), flat("DDD", 1, 10000),
    flat("DDD", 2, 10000), flat("DDD", 3, 10000), flat("DDD", 4, 11000),
    flat("DDD", 5, 12000), flat("DDD", 6, 11500),
    mkBar("DDD", 7, 11600, 12300, 11600, 12300),
    flat("EEE", 0, 10000), flat("EEE", 1, 10000), flat("EEE", 2, 10000),
    flat("EEE", 3, 10000), flat("EEE", 4, 10000, degraded = true),
    flat("EEE", 5, 9000), flat("EEE", 6, 9900),
    mkBar("EEE", 7, 9000, 9000, 8999, 8999)])
  check("a taint outside a machine's window does not hold that machine",
        showAll(e.sortedSignals()) ==
          "BBB/3/SIGNAL_HELD/flag_conflict," &
          "BBB/7/SIGNAL_HELD/breakdown_unverified," &
          "CCC/3/SIGNAL_HELD/flag_conflict,CCC/7/SIGNAL_HELD/flag_conflict," &
          "DDD/0/SIGNAL_HELD/flag_conflict,DDD/7/bullish_pullback_reversal/," &
          "EEE/4/SIGNAL_HELD/flag_conflict,EEE/7/SIGNAL_HELD/flag_conflict,",
        "got " & showAll(e.sortedSignals()))

# ------------------- holdOnDegraded=false silences the window hold as well
block windowHoldNotReported:
  proc stream(): seq[Bar] =
    @[mkBar("CCC", 0, 10000, 10000, 10000, 10000),
      mkBar("CCC", 1, 10000, 10000, 10000, 10000),
      mkBar("CCC", 2, 10000, 10000, 10000, 10000),
      mkBar("CCC", 3, 10000, 10000, 10000, 10000, degraded = true),
      mkBar("CCC", 4, 11000, 11000, 11000, 11000),
      mkBar("CCC", 5, 12000, 12000, 12000, 12000),
      mkBar("CCC", 6, 11500, 11500, 11500, 11500),
      mkBar("CCC", 7, 11600, 12300, 11600, 12300)]
  var silent = engineOf(50, 30, 50, 30, holdOnDegraded = false)
  feed(silent, stream())
  check("holdOnDegraded=false suppresses the window hold and the verdict",
        silent.sortedSignals().len == 0,
        "got " & showAll(silent.sortedSignals()))
  var reported = engineOf(50, 30, 50, 30, holdOnDegraded = true)
  feed(reported, stream())
  check("holdOnDegraded=true reports the same window hold",
        showAll(reported.sortedSignals()) ==
          "CCC/3/SIGNAL_HELD/flag_conflict,CCC/7/SIGNAL_HELD/flag_conflict,",
        "got " & showAll(reported.sortedSignals()))

# ------------------------------------------------------------- §6 invariants
block signalInvariants:
  proc stream(sym: string): seq[Bar] =
    result.add(mkBar(sym, 0, 50000, 50000, 50000, 50000, degraded = true,
                     pos = "first_after_sub"))
    result.add(mkBar(sym, 1, 40000, 40000, 40000, 40000))
    result.add(mkBar(sym, 2, 30000, 30000, 30000, 30000))
    result.add(emptyGap(sym, 3))
    result.add(mkBar(sym, 4, 20000, 20000, 20000, 20000))
    result.add(mkBar(sym, 5, 10500, 10500, 9900, 10000))
    result.add(mkBar(sym, 6, 10000, 10450, 9900, 10400))

  var a = engineOf(50, 30, 50, 30)
  var inter: seq[Bar]
  for i in 0 .. 6:
    inter.add(stream("BBB")[i])
    inter.add(stream("ZZZ")[i])
  feed(a, inter)
  var b = engineOf(50, 30, 50, 30)
  feed(b, stream("ZZZ") & stream("BBB"))
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
                 "flag_conflict", "degraded_bar", "breakdown_unverified"]
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
