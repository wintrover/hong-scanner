## One symmetric judgment function over shared closed bars (frozen VS-A,
## REPLAY_CONTRACT §6; ASSUMPTIONS P23). Direction is the only asymmetry:
## `d=+1` is up, `d=−1` is down, and both verdicts come from the same code
## path with the same absolute thresholds — per-direction thresholds are a
## contract violation.
##
## Declared reference price (P_ref of S_d = d × (P − P_ref)/P_ref × 10⁴):
## the close of the symbol's first untainted, non-empty bar with a positive
## close. Every bp comparison in both directions divides by that one anchor,
## so mirroring a stream around it (P → 2·P_ref − P) negates every S_d
## exactly — including the truncated integer division — and the acceptance
## mirror test (§6) is exact arithmetic, not data tuning.
##
## Structure, identical in both directions (d is the only parameter):
## the observation window is the last lookback_bars+1 bars of the symbol's
## history (the same window for both directions); (1) trend confirmation —
## the direction's pivot is the extreme close of the window before the
## current bar (ties -> earliest bar) and must stand at least trend_min_bp
## from the anchor; (2) counter-move confirmation — the opposite extreme
## from the pivot to just before the current bar (ties -> latest bar) must
## retrace at least countermove_min_bp; (3) resumption — the current close
## must recover at least directional_trigger_bp from the counter-move
## extreme. Empty bars never trade, so they are never selected as extremes;
## their placeholder prices cannot fabricate a pivot.
##
## Fail-closed (contract §6): a degraded bar never yields a verdict — it is
## reported as SIGNAL_HELD with its own reason when hold_on_degraded, and
## judgment skips it. A verdict whose evidence window still contains a
## degraded/vol_partial/gap/empty/out-of-order bar is held until the last
## tainted bar slides out of the shared window; one SIGNAL_HELD per bar
## carries the most recent tainted bar's reason (the one that binds the
## window longest). hold_on_degraded=false suppresses holds silently. Real
## signals carry reason:"". There is no "breakdown_unverified" path: the
## bearish verdict is the mirror of the bullish one and fires for real.
import std/[tables, algorithm]
import hcj, bars

type
  Params* = object
    warmupBars*: int
    lookbackBars*: int
    trendMinBp*: int
    countermoveMinBp*: int
    directionalTriggerBp*: int
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
    anchors*: Table[string, int64]  ## per-symbol declared reference close
    signals*: seq[Signal]

proc initEngine*(p: Params; sessionDate: string): Engine =
  result.params = p
  result.sessionDate = sessionDate
  result.hist = initTable[string, seq[Bar]]()
  result.anchors = initTable[string, int64]()
  result.signals = @[]

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

proc judge(e: Engine; hs: seq[Bar]; d: int): bool =
  ## Would direction d's verdict fire on the current (last) bar? Pure check:
  ## it emits nothing and reads only the shared window plus the anchor. The
  ## caller owns the taint decision, so this stays the single judgment path
  ## for both directions.
  let n = hs.len
  let i = n - 1
  let s = n - 1 - e.params.lookbackBars
  let a = e.anchors[hs[i].symbol]
  # (1) trend pivot: the direction's extreme close before the current bar,
  #     ties -> earliest bar; empty bars are never eligible extremes.
  var p = -1
  for k in s ..< i:
    if hs[k].empty: continue
    if p < 0 or d * hs[k].close > d * hs[p].close: p = k
  if p < 0: return false
  let trendBp = d * int((hs[p].close - a) * 10000'i64 div a)
  if trendBp < e.params.trendMinBp: return false
  # (2) counter-move extreme from the pivot, ties -> latest bar (the most
  #     recent opposite extreme before the current bar).
  var c = -1
  for k in p ..< i:
    if hs[k].empty: continue
    if c < 0 or d * hs[k].close <= d * hs[c].close: c = k
  if c < 0: return false
  let depthBp = d * int((hs[p].close - hs[c].close) * 10000'i64 div a)
  if depthBp < e.params.countermoveMinBp: return false
  # (3) resumption trigger at the current close from the counter-move extreme.
  let triggerBp = d * int((hs[i].close - hs[c].close) * 10000'i64 div a)
  triggerBp >= e.params.directionalTriggerBp

proc onBar*(e: var Engine; bar: Bar) =
  var hs = e.hist.mgetOrPut(bar.symbol, @[])
  hs.add(bar)
  e.hist[bar.symbol] = hs
  if bar.degraded:
    if e.params.holdOnDegraded:
      e.emit(bar, "SIGNAL_HELD", holdReason(bar))
    return
  # The declared reference price: the first untainted, non-empty, positive
  # close of the symbol's history. Until one exists no verdict is derivable,
  # so the bar fails closed (no verdict, no hold record).
  if bar.symbol notin e.anchors and not tainted(bar) and not bar.empty and
      bar.close > 0:
    e.anchors[bar.symbol] = bar.close
  if bar.symbol notin e.anchors: return
  if bar.index < e.params.warmupBars: return
  let L = e.params.lookbackBars
  let n = hs.len
  if L < 1 or n < L + 1: return
  let s = n - 1 - L
  let cur = hs[n - 1]
  let fireUp = e.judge(hs, 1)
  let fireDown = e.judge(hs, -1)
  if not fireUp and not fireDown: return
  # The evidence window is shared by both directions, so a taint holds both
  # identically and one hold record per bar carries the binding reason.
  let taint = windowTaint(hs, s, n - 1)
  if taint.len == 0:
    if fireUp: e.emit(cur, "bullish_pullback_reversal")
    if fireDown: e.emit(cur, "bearish_rebound_failure")
  elif e.params.holdOnDegraded:
    e.emit(cur, "SIGNAL_HELD", taint)

proc sortedSignals*(e: Engine): seq[Signal] =
  result = e.signals
  result.sort(proc (x, y: Signal): int =
    let c = cmp(x.symbol, y.symbol)
    if c != 0: return c
    let b = cmp(x.barIndex, y.barIndex)
    if b != 0: return b
    cmp(x.signal, y.signal))
