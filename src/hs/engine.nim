## Two independent state machines over shared closed bars.
## Output vocabulary (no "short"): bullish_pullback_reversal /
## bearish_rebound_failure, plus SIGNAL_HELD for degraded bars.
## Fail-closed rules (contract §6): a degraded bar never yields a machine
## verdict (holdOnDegraded only decides whether the hold is reported), no
## verdict is derived from an empty_gap bar's placeholder prices, and no
## verdict is derived from an evidence window that still contains a
## degraded/vol_partial/gap/empty bar: each machine checks only the bars it
## actually reads and resumes once the last tainted bar has slid out of that
## window. A verdict suppressed this way is reported as SIGNAL_HELD carrying
## the most recent tainted bar's reason (the taint that binds the window
## longest); holdOnDegraded=false suppresses it silently, as for the bar
## itself. breakdownBp is parsed but deliberately not applied: its reference
## price and comparison rule are undefined (docs/LIMITS.md, strategy
## contract) and must not be invented here. Firing a threshold-less
## breakdown would trade safety for test convenience, so the bearish verdict
## itself fails closed as SIGNAL_HELD reason="breakdown_unverified" (silent
## when holdOnDegraded=false) until a formula is approved; a tainted window
## still reports the taint's own reason first. The bullish machine is
## unaffected.
import std/[tables, algorithm]
import hcj, bars

type
  Params* = object
    lookback*: int
    pullbackMinBp*: int
    recoveryBp*: int
    reboundMinBp*: int
    breakdownBp*: int
    warmupBars*: int
    holdOnDegraded*: bool

  Signal* = object
    symbol*: string
    sessionDate*: string
    barIndex*: int
    signal*: string
    reason*: string        ## "" for a real signal; why a bar was held
    price*: int64

  Engine* = object
    params*: Params
    sessionDate*: string
    hist*: Table[string, seq[Bar]]
    signals*: seq[Signal]

proc initEngine*(p: Params; sessionDate: string): Engine =
  result.params = p
  result.sessionDate = sessionDate
  result.hist = initTable[string, seq[Bar]]()
  result.signals = @[]

proc bp(delta, base: int64): int =
  if base == 0: return 0
  int((delta * 10000'i64) div base)

proc holdReason(bar: Bar): string =
  if bar.empty: return "empty_gap"
  if bar.gapEdge.len > 0: return "gap"
  if bar.outOfOrder: return "out_of_order"
  if bar.pos == "first_after_sub": return "first_after_sub"
  if bar.degraded: return "flag_conflict"
  "degraded_bar"

proc tainted(b: Bar): bool =
  ## True when a bar's values cannot be trusted as strategy evidence: any of
  ## the §5/§6 suspicion markers. outOfOrder and the gap bar_positions always
  ## co-occur with degraded on builder output; they are checked anyway so a
  ## malformed synthetic bar still fails closed.
  b.degraded or b.volPartial or b.empty or b.outOfOrder or b.gapEdge.len > 0 or
    b.pos == "first_after_sub" or b.pos == "after_gap" or b.pos == "empty_gap"

proc windowTaint(hs: seq[Bar]; first, last: int): string =
  ## "" when every bar in [first, last] is clean; otherwise the hold reason of
  ## the most recent tainted bar — the one that keeps the window untrustworthy
  ## the longest, because it is the last to slide out.
  for k in countdown(last, first):
    if hs[k].tainted: return holdReason(hs[k])
  ""

proc emit(e: var Engine; bar: Bar; name: string; reason = "") =
  e.signals.add(Signal(symbol: bar.symbol, sessionDate: e.sessionDate,
                       barIndex: bar.index, signal: name, reason: reason,
                       price: bar.close))

proc onBar*(e: var Engine; bar: Bar) =
  var hs = e.hist.mgetOrPut(bar.symbol, @[])
  hs.add(bar)
  e.hist[bar.symbol] = hs
  if bar.degraded:
    if e.params.holdOnDegraded:
      e.emit(bar, "SIGNAL_HELD", holdReason(bar))
    return
  if bar.index < e.params.warmupBars:
    return
  let n = hs.len
  let L = e.params.lookback
  if L < 1 or n < L + 2:
    return
  let cur = hs[n - 1]
  let prev = hs[n - 2]
  let refBar = hs[n - 1 - L]

  # Each machine is fail-closed over the exact bars it reads. The bullish
  # machine reads cur, prev, refBar and the priorHigh scan (2L bars back);
  # the bearish machine reads cur, refBar and the priorLow/maxHigh scan
  # (L bars back). A tainted bar anywhere in a machine's window holds that
  # machine's verdict until the window has slid past the taint; the other
  # machine is unaffected.
  let bullFirst = max(0, n - 1 - 2 * L)
  if not refBar.empty and cur.close > refBar.close:
    var priorHigh: int64 = 0
    for k in bullFirst ..< n - 1:
      if hs[k].close > priorHigh: priorHigh = hs[k].close
    if priorHigh > 0:
      let depth = bp(priorHigh - cur.low, priorHigh)
      let rec = bp(cur.close - prev.close, prev.close)
      if not prev.empty and depth >= e.params.pullbackMinBp and
          rec >= e.params.recoveryBp:
        let taint = windowTaint(hs, bullFirst, n - 1)
        if taint.len == 0:
          e.emit(cur, "bullish_pullback_reversal")
        elif e.params.holdOnDegraded:
          e.emit(cur, "SIGNAL_HELD", taint)

  let bearFirst = max(0, n - 1 - L)
  if not refBar.empty and cur.close < refBar.close:
    var priorLow = high(int64)
    var maxHigh: int64 = 0
    for k in bearFirst ..< n - 1:
      if hs[k].low < priorLow: priorLow = hs[k].low
      if hs[k].high > maxHigh: maxHigh = hs[k].high
    if priorLow != high(int64) and priorLow > 0:
      let reboundBp = bp(maxHigh - priorLow, priorLow)
      if reboundBp >= e.params.reboundMinBp and cur.close < priorLow:
        # Evidence-window handling first and unchanged: a tainted window
        # reports the taint's own reason. A clean window then hits the
        # breakdown gate: breakdownBp has no approved reference price or
        # comparison rule, so the verdict fails closed instead of firing a
        # threshold-less breakdown. Restoring bearish_rebound_failure here
        # requires an approved formula, not a guessed one.
        let taint = windowTaint(hs, bearFirst, n - 1)
        let reason = if taint.len > 0: taint else: "breakdown_unverified"
        if e.params.holdOnDegraded:
          e.emit(cur, "SIGNAL_HELD", reason)

proc sortedSignals*(e: Engine): seq[Signal] =
  result = e.signals
  result.sort(proc (x, y: Signal): int =
    let c = cmp(x.symbol, y.symbol)
    if c != 0: return c
    let b = cmp(x.barIndex, y.barIndex)
    if b != 0: return b
    cmp(x.signal, y.signal))