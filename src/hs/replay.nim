## Core: records -> bars -> signals. Pure; reads only the record sequence.
## No wall clock, no filesystem, no arguments: every input that changes a
## verdict is inside input.hcj.jsonl (plan §3.0/§3.1).
import std/[strutils, algorithm]
import hcj, records, calendars, bars, engine, rest_resp

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
    ## rest_resp pages whose declared page chain verified as confirmed
    ## success (REPLAY_CONTRACT §12.1). Minimal consumption record: there is
    ## no live collector yet, so a verified page never moves the verdict --
    ## bars and signals stay exactly the stream's tick-derived output.
    restVerified*: int

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

proc restRejection(seqNo: int; detail: string): string =
  ## Explicit REJECT text for a rest_resp that failed the validated
  ## acceptance path: always names the record, its seq and the verification
  ## boundary, so a rejection is self-explaining on the CLI.
  "rest_resp at seq " & $seqNo & " is rejected: " & detail &
  " (acceptance needs a declared request scope, a preserved response and " &
  "a page chain that affirms success; the live REST wire format is " &
  "unverified by a measured producer (G2/G4), so no unconfirmed state can " &
  "mean success)"

proc runCore*(recs: seq[Record]): CoreResult =
  validateRecords(recs)
  let cal = recs[0].raw
  result.config = parseConfig(recs[1].raw)
  result.spec = sessionFor(cal, result.config.sessionDate)
  var b = initBars(result.spec)
  var sawEnd = false
  var restAttempts: seq[RestRespAttempt] = @[]
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
      if raw.kind != hkObj:
        raise newException(RecordError, "gap raw is not an object")
      if not raw.has("symbol"):
        raise newException(RecordError, "gap raw has no symbol field")
      let sym = raw.get("symbol")
      if not sym.isNull and sym.kind != hkStr:
        raise newException(RecordError, "gap symbol is not a string or null")
      applyGap(b, if sym.isNull: "" else: sym.strVal)
    of kSessionEnd:
      if not recs[i].raw.isNull:
        raise newException(RecordError, "session_end raw is not null")
      sawEnd = true
      closeAtSessionEnd(b)
    of kRestResp:
      # VS-2 §12.1 validated acceptance path, replacing the VS-1 fail-closed
      # placeholder. A record is accepted only when its raw payload parses
      # against the rest_resp schema: a declared request scope (ka10027,
      # KRX-only, one query per direction), a 1-based page index, and the
      # preserved original HTTP response (status, cont-yn/next-key, body
      # bytes byte-exact via body_hex). Schema failures reject here, at the
      # record's own seq. Success is affirmed by the vendor_input rules
      # only -- HTTP 200, return_code present + integer + 0, list key
      # present -- and body-level or chain-level failures (cont-yn repeat,
      # page cap, missing page, page order) still reject the whole run once
      # the stream is complete (see verifyAttempts after the loop).
      # Verified pages are counted in the result but do not move the
      # verdict: no live collector exists, so candidate-scope consumption
      # stays future work (G2/G4: no measured producer capture).
      try:
        restAttempts.add(parseAttempt(recs[i].seq, recs[i].raw))
      except RestRespError as e:
        raise newException(RecordError, restRejection(recs[i].seq, e.msg))
    of kCalendar, kConfig:
      discard
    else:
      inc result.ignoredKinds
  # The declared page chains are audited once the record set is complete: a
  # body or chain failure is a contract violation (REJECT, exit 2) and takes
  # precedence over INCOMPLETE, never a silent pass.
  try:
    result.restVerified = verifyAttempts(restAttempts).len
  except RestRespError as e:
    raise newException(RecordError, restRejection(e.seqNo, e.msg))
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