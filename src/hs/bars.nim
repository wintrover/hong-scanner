## Bar builder: 3-minute bars keyed by t_exch only.
##
## Contract (plan §3.2/§3.3):
##   i(t) = floor((t - open) / 180s), interval [open+180i, open+180(i+1))
##   t == close  -> last bar, close_boundary
##     t < open or t > close -> out_of_session, excluded
##   session flag (field 290) is the authority for in/out of session; a
##   disagreement between 290 and the calendar window is a *conflict*: the
##   tick is excluded and the affected interval is marked degraded. No guess.
##   A tick into an already closed bar invalidates the whole run.
import std/[strutils, tables, algorithm]
import hcj, calendars

type
  Bar* = object
    symbol*: string
    index*: int
    open*, high*, low*, close*: int64
    vol*: int64
    ticks*: int
    pos*: string            ## first_after_sub | steady | after_gap | empty_gap
    sessionClass*: string   ## in_session (only such ticks form bars)
    volPartial*: bool
    degraded*: bool
    gapEdge*: string        ## "" | before | after | both
    outOfOrder*: bool
    closeBoundary*: bool
    empty*: bool
    closed*: bool

  LateTickError* = object of CatchableError

  SymbolState = object
    started: bool
    everStarted: bool
    cur: Bar
    closed: seq[Bar]
    badIdx: seq[int]        ## intervals polluted by a 290 conflict
    lastClosedIdx: int
    lastCum: int64
    volInit: bool
    lastTickSec: int
    pendingGap: bool

  BarsBuilder* = object
    spec*: SessionSpec
    syms*: Table[string, SymbolState]
    order*: seq[string]
    globalGap*: bool
    frames*: int
    conflicts*: int
    outOfSession*: int

proc initBars*(spec: SessionSpec): BarsBuilder =
  result = BarsBuilder(spec: spec)
  result.order = @[]

proc spanSec(spec: SessionSpec): int = spec.bars * barSeconds

proc markBad(st: var SymbolState; idx: int) =
  if st.started and st.cur.index == idx:
    st.cur.degraded = true
  elif idx notin st.badIdx:
    st.badIdx.add(idx)

proc openBar(b: var BarsBuilder; st: var SymbolState; symbol: string; idx: int;
             price: int64; tSec: int) =
  let wasEver = st.everStarted
  st.cur = Bar(symbol: symbol, index: idx, open: price, high: price, low: price,
               close: price, pos: "steady", sessionClass: "in_session")
  st.started = true
  st.everStarted = true
  st.lastTickSec = tSec
  if idx in st.badIdx:
    st.cur.degraded = true
  if st.pendingGap or (b.globalGap and not wasEver):
    st.cur.pos = "after_gap"
    st.cur.degraded = true
    st.cur.volPartial = true
    st.cur.gapEdge = "after"
    st.pendingGap = false
  elif not wasEver:
    st.cur.pos = "first_after_sub"
    st.cur.volPartial = true
    st.cur.degraded = true

proc closeCur(st: var SymbolState; unresolved: bool) =
  if not st.started: return
  var bar = st.cur
  if unresolved:
    bar.degraded = true
    bar.volPartial = true
    if bar.gapEdge.len == 0: bar.gapEdge = "before"
  bar.closed = true
  st.closed.add(bar)
  st.lastClosedIdx = bar.index
  st.started = false
  st.cur = Bar()

proc startEmptyBar(st: var SymbolState; symbol: string; idx: int) =
  st.closed.add(Bar(symbol: symbol, index: idx, pos: "empty_gap", empty: true,
                    closed: true, degraded: true, volPartial: true,
                    gapEdge: "both", sessionClass: "out_of_session"))

proc applyGap*(b: var BarsBuilder; symbol: string) =
  ## symbol == "" means a connection-wide gap: every known symbol, and any
  ## symbol seen later, starts in the unresolved state. Release is per symbol
  ## (first later frame of that symbol) — never another symbol's frame.
  if symbol.len == 0:
    b.globalGap = true
    for name in b.order:
      var st = b.syms[name]
      if st.started:
        st.cur.degraded = true
        st.cur.volPartial = true
        st.cur.gapEdge = "before"
        st.closeCur(true)
      st.pendingGap = true
      b.syms[name] = st
    return
  if symbol notin b.syms:
    b.order.add(symbol)
  var st = b.syms.mgetOrPut(symbol, SymbolState())
  if st.started:
    st.cur.degraded = true
    st.cur.volPartial = true
    st.cur.gapEdge = "before"
    st.closeCur(true)
  st.pendingGap = true
  b.syms[symbol] = st

proc feedTick*(b: var BarsBuilder; symbol: string; tSec: int; price: int64;
               cumVol: int64; flag: string) =
  ## tSec is seconds since session open. flag is field 290 ("1"|"2"|"3")
  ## or "" when the field is missing.
  if symbol notin b.syms:
    b.order.add(symbol)
  inc b.frames
  let span = spanSec(b.spec)
  let inWindow = tSec >= 0 and tSec <= span
  var cls: string
  if flag == "2":
    if inWindow: cls = "in_session" else: cls = "conflict"
  elif flag == "1" or flag == "3":
    if inWindow: cls = "conflict" else: cls = "out_of_session"
  else:
    cls = "unknown"

  var st = b.syms.mgetOrPut(symbol, SymbolState())

  if cls != "in_session":
    if cls == "out_of_session":
      inc b.outOfSession
    else:
      inc b.conflicts
      var idx = if tSec < 0: 0 else: tSec div barSeconds
      if idx >= b.spec.bars: idx = b.spec.bars - 1
      st.markBad(idx)
    b.syms[symbol] = st
    return

  var idx = tSec div barSeconds
  var boundary = false
  if tSec == span:
    idx = b.spec.bars - 1
    boundary = true

  if st.started and idx < st.cur.index:
    raise newException(LateTickError,
      "LATE_TICK_INTO_CLOSED_BAR symbol=" & symbol & " bar=" & $idx &
      " current=" & $st.cur.index)
  if not st.started and st.everStarted and idx <= st.lastClosedIdx:
    raise newException(LateTickError,
      "LATE_TICK_INTO_CLOSED_BAR symbol=" & symbol & " bar=" & $idx &
      " closed=" & $st.lastClosedIdx)

  if not st.started:
    b.openBar(st, symbol, idx, price, tSec)
  elif idx > st.cur.index:
    let prev = st.cur.index
    st.closeCur(false)
    for k in prev + 1 ..< idx:
      st.startEmptyBar(symbol, k)
    b.openBar(st, symbol, idx, price, tSec)
  else:
    if tSec < st.lastTickSec:
      st.cur.outOfOrder = true
      st.cur.degraded = true
    st.lastTickSec = tSec

  if boundary: st.cur.closeBoundary = true
  st.cur.high = max(st.cur.high, price)
  st.cur.low = min(st.cur.low, price)
  st.cur.close = price
  inc st.cur.ticks
  var delta: int64 = 0
  if not st.volInit:
    st.volInit = true
    st.cur.volPartial = true
  else:
    delta = cumVol - st.lastCum
    if delta < 0:
      delta = 0
      st.cur.degraded = true
  st.lastCum = cumVol
  st.cur.vol += delta
  b.syms[symbol] = st

proc closeAtSessionEnd*(b: var BarsBuilder) =
  ## A bar still open at session_end is closed as-is. Only a symbol whose gap
  ## was never resolved (pendingGap) is marked unresolved; a session-wide gap
  ## that this symbol already recovered from must not taint its last bar.
  for name in b.order:
    var st = b.syms[name]
    if st.started:
      st.closeCur(st.pendingGap)
    b.syms[name] = st

proc flagReliable*(b: BarsBuilder): bool =
  ## Plan §3.2: abort the round when 290/calendar conflicts exceed 0.5%.
  if b.frames == 0: return true
  b.conflicts * 1000 <= b.frames * 5

proc closedBars*(b: BarsBuilder): seq[Bar] =
  for name in b.order:
    for bar in b.syms[name].closed:
      result.add(bar)
  result.sort(proc (x, y: Bar): int =
    let c = cmp(x.symbol, y.symbol)
    if c != 0: c else: cmp(x.index, y.index))

proc openBarCount*(b: BarsBuilder): int =
  for name in b.order:
    if b.syms[name].started: inc result

proc currentBarIndex*(b: BarsBuilder; symbol: string): int =
  if symbol in b.syms and b.syms[symbol].started: b.syms[symbol].cur.index
  else: -1

proc currentBarBoundary*(b: BarsBuilder; symbol: string): bool =
  symbol in b.syms and b.syms[symbol].started and b.syms[symbol].cur.closeBoundary