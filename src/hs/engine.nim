## Two independent state machines over shared closed bars.
## Output vocabulary (no "short"): bullish_pullback_reversal /
## bearish_rebound_failure, plus SIGNAL_HELD for degraded bars.
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

proc emit(e: var Engine; bar: Bar; name: string; reason = "") =
  e.signals.add(Signal(symbol: bar.symbol, sessionDate: e.sessionDate,
                       barIndex: bar.index, signal: name, reason: reason,
                       price: bar.close))

proc onBar*(e: var Engine; bar: Bar) =
  var hs = e.hist.mgetOrPut(bar.symbol, @[])
  hs.add(bar)
  e.hist[bar.symbol] = hs
  if bar.degraded and e.params.holdOnDegraded:
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

  if cur.close > refBar.close:
    var priorHigh: int64 = 0
    for k in max(0, n - 1 - 2 * L) ..< n - 1:
      if hs[k].close > priorHigh: priorHigh = hs[k].close
    if priorHigh > 0:
      let depth = bp(priorHigh - cur.low, priorHigh)
      let rec = bp(cur.close - prev.close, prev.close)
      if depth >= e.params.pullbackMinBp and rec >= e.params.recoveryBp:
        e.emit(cur, "bullish_pullback_reversal")

  if cur.close < refBar.close:
    var priorLow = high(int64)
    var maxHigh: int64 = 0
    for k in max(0, n - 1 - L) ..< n - 1:
      if hs[k].low < priorLow: priorLow = hs[k].low
      if hs[k].high > maxHigh: maxHigh = hs[k].high
    if priorLow != high(int64) and priorLow > 0:
      let reboundBp = bp(maxHigh - priorLow, priorLow)
      if reboundBp >= e.params.reboundMinBp and cur.close < priorLow:
        e.emit(cur, "bearish_rebound_failure")

proc sortedSignals*(e: Engine): seq[Signal] =
  result = e.signals
  result.sort(proc (x, y: Signal): int =
    let c = cmp(x.symbol, y.symbol)
    if c != 0: return c
    let b = cmp(x.barIndex, y.barIndex)
    if b != 0: return b
    cmp(x.signal, y.signal))