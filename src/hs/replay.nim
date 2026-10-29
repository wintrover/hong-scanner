## Core: records -> bars -> signals. Pure; reads only the record sequence.
## No wall clock, no filesystem, no arguments: every input that changes a
## verdict is inside input.hcj.jsonl (plan §3.0/§3.1).
import std/[strutils, algorithm]
import hcj, records, calendars, bars, engine

type
  Config* = object
    sessionDate*: string
    params*: Params

  RunStatus* = enum
    rsOk, rsIncomplete, rsUnreliableFlag

  CoreResult* = object
    status*: RunStatus
    bars*: seq[Bar]
    signals*: seq[Signal]
    config*: Config
    spec*: SessionSpec
    frames*: int
    conflicts*: int
    ignoredKinds*: int

proc intOr(raw: HcjValue; key: string; dflt: int): int =
  if raw.kind == hkObj and raw.has(key) and raw.get(key).kind == hkInt:
    int(raw.get(key).ival)
  else:
    dflt

proc boolOr(raw: HcjValue; key: string; dflt: bool): bool =
  if raw.kind == hkObj and raw.has(key) and raw.get(key).kind == hkBool:
    raw.get(key).bval
  else:
    dflt

proc parseConfig*(raw: HcjValue): Config =
  if raw.kind != hkObj:
    raise newException(RecordError, "config raw is not an object")
  if not raw.has("session_date"):
    raise newException(RecordError, "config.session_date is required")
  result.sessionDate = raw.get("session_date").asStr
  let p = if raw.has("params"): raw.get("params") else: hNull()
  result.params = Params(
    lookback: intOr(p, "lookback", 3),
    pullbackMinBp: intOr(p, "pullback_min_bp", 50),
    recoveryBp: intOr(p, "recovery_bp", 30),
    reboundMinBp: intOr(p, "rebound_min_bp", 50),
    breakdownBp: intOr(p, "breakdown_bp", 30),
    warmupBars: intOr(p, "warmup_bars", 0),
    holdOnDegraded: boolOr(p, "hold_on_degraded", true))

proc reqField(raw: HcjValue; key: string): HcjValue =
  if raw.kind != hkObj:
    raise newException(RecordError, "record raw is not an object")
  if not raw.has(key):
    raise newException(RecordError, "missing field: " & key)
  raw.get(key)

proc flagOf(raw: HcjValue): string =
  ## Field 290 (session class) as a raw string; "" when absent.
  if raw.kind == hkObj and raw.has("m"):
    let n = raw.get("m")
    if n.kind == hkStr: return n.strVal
    if n.kind == hkInt: return $n.ival
  ""

proc barLine*(bar: Bar): string =
  canonical(hObj(
    ("bar_index", hInt(bar.index)),
    ("bar_position", hStr(bar.pos)),
    ("close", hInt(bar.close)),
    ("close_boundary", hBool(bar.closeBoundary)),
    ("closed", hBool(bar.closed)),
    ("degraded", hBool(bar.degraded)),
    ("empty", hBool(bar.empty)),
    ("gap_edge", hStr(bar.gapEdge)),
    ("high", hInt(bar.high)),
    ("low", hInt(bar.low)),
    ("open", hInt(bar.open)),
    ("out_of_order", hBool(bar.outOfOrder)),
    ("session_class", hStr(bar.sessionClass)),
    ("symbol", hStr(bar.symbol)),
    ("ticks", hInt(bar.ticks)),
    ("vol", hInt(bar.vol)),
    ("vol_partial", hBool(bar.volPartial))))

proc signalLine*(s: Signal): string =
  canonical(hObj(
    ("bar_index", hInt(s.barIndex)),
    ("price", hInt(s.price)),
    ("reason", hStr(s.reason)),
    ("session_date", hStr(s.sessionDate)),
    ("signal", hStr(s.signal)),
    ("symbol", hStr(s.symbol))))

proc runCore*(recs: seq[Record]): CoreResult =
  validateRecords(recs)
  let cal = recs[0].raw
  result.config = parseConfig(recs[1].raw)
  result.spec = sessionFor(cal, result.config.sessionDate)
  var b = initBars(result.spec)
  var sawEnd = false
  for i in 2 ..< recs.len:
    case recs[i].kind
    of kWsFrame:
      let raw = recs[i].raw
      let symbol = reqField(raw, "symbol").asStr
      let t = reqField(raw, "t").asStr
      let price = reqField(raw, "price").asInt
      let vol = reqField(raw, "vol").asInt
      let tSec = hmsToSec(t) - result.spec.openSec
      feedTick(b, symbol, tSec, price, vol, flagOf(raw))
    of kGap:
      let raw = recs[i].raw
      var symbol = ""
      if raw.kind == hkObj and raw.has("symbol") and not raw.get("symbol").isNull:
        symbol = raw.get("symbol").asStr
      applyGap(b, symbol)
    of kSessionEnd:
      sawEnd = true
      closeAtSessionEnd(b)
    of kRestResp:
      discard
    of kCalendar, kConfig:
      discard
    else:
      inc result.ignoredKinds
  result.frames = b.frames
  result.conflicts = b.conflicts
  if not sawEnd:
    result.status = rsIncomplete
    return
  if not flagReliable(b):
    result.status = rsUnreliableFlag
    return
  result.status = rsOk
  result.bars = closedBars(b)
  var eng = initEngine(result.config.params, result.config.sessionDate)
  for bar in result.bars:
    eng.onBar(bar)
  result.signals = sortedSignals(eng)