## Core: records -> bars -> signals. Pure; reads only the record sequence.
## No wall clock, no filesystem, no arguments: every input that changes a
## verdict is inside input.hcj.jsonl (plan §3.0/§3.1).
import std/[strutils, algorithm]
import hcj, records, calendars, bars, engine, rest_resp, sub_input, vendor_input,
       tickwire, subcheck

type
  Config* = object
    sessionDate*: string
    params*: Params
    ## Optional declared operating environment ("demo"|"prod"; "" when the
    ## stream declares none). The marker-aware verify rules key on this
    ## field; a present-but-invalid value is a parse failure (fail-closed).
    environment*: string
    ## The declared re-poll cadence in seconds (config.repoll_seconds;
    ## 0 = undeclared). Declared, it opens rest_resp's approved multi-round
    ## page-chain audit (rest_resp.verifyAttempts); undeclared, the
    ## chain-restart REJECT stays in force.
    repollSeconds*: int
    ## The declared page cap (config.page_cap; defaultPageCap when absent).
    pageCap*: int

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
    ## Subscription-evidence records consumed (schema-validated, §12.5).
    ## Like restVerified: counted, never moved by them, and they change no
    ## output byte.
    subCount*: int
    wsRawCount*: int
    ## §12.5/§10 consumption checks (subcheck), recomputed deterministically
    ## over the stream-order sub/ws_raw evidence. Quarantined 0B ticks never
    ## fed bars or signals; the count and the first reasons are reported.
    ## Quarantine is NOT a REJECT and never moves a verdict.
    quarantined*: int
    quarantineNotes*: seq[string]
    regAcks0B*: int
    removeAcks0B*: int
    ## The distinct observed FID 215 values, in first-observation order,
    ## re-derived from the 0s ws_raw payloads (the close-evidence subset is
    ## tickwire.closeEvidence215).
    closeValues*: seq[string]

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
  # environment is optional (absent = the stream declares no operating
  # environment; every existing synthetic stream stays valid). Present,
  # it is fail-closed: only the string "demo" or "prod" is accepted --
  # another value or a non-string type is a contract violation, never a
  # default. The verify commit-marker rules key on this field.
  if raw.has("environment"):
    let e = raw.get("environment")
    if e.kind != hkStr:
      raise newException(RecordError,
        "config.environment is not a string: " & kindName(e))
    if e.strVal != "demo" and e.strVal != "prod":
      raise newException(RecordError,
        "config.environment is not demo|prod: " & e.strVal)
    result.environment = e.strVal
  # The declared re-poll cadence and page cap (tools/collector/README.md
  # §6.1): both optional, both fail-closed on a wrong type or a
  # non-positive value. repoll_seconds 0 means undeclared — the page-chain
  # audit stays single-round; page_cap defaults to the approved PH-1 value.
  result.repollSeconds = intOr(raw, "repoll_seconds", 0)
  if result.repollSeconds < 0:
    raise newException(RecordError,
      "config.repoll_seconds must be >= 0: " & $result.repollSeconds)
  if raw.has("page_cap"):
    let pc = raw.get("page_cap")
    if pc.kind != hkInt:
      raise newException(RecordError,
        "config.page_cap is not an integer: " & kindName(pc))
    if int(pc.ival) < 1:
      raise newException(RecordError,
        "config.page_cap must be >= 1: " & $pc.ival)
    result.pageCap = int(pc.ival)
  else:
    result.pageCap = defaultPageCap
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

proc schemaRejection(kindNameText: string; seqNo: int; detail: string): string =
  ## Explicit REJECT text for a sub/ws_raw record that failed its schema:
  ## names the record, its seq and the boundary, like restRejection.
  kindNameText & " at seq " & $seqNo & " is rejected: " & detail &
  " (acceptance needs exactly the declared schema fields for the " &
  "record's (action, phase) combination; the live subscription wire " &
  "format is unverified by a measured producer (G2/G4), so any schema " &
  "doubt is a failure)"

proc runCore*(recs: seq[Record]): CoreResult =
  validateRecords(recs)
  let cal = recs[0].raw
  result.config = parseConfig(recs[1].raw)
  result.spec = sessionFor(cal, result.config.sessionDate)
  var b = initBars(result.spec)
  var sawEnd = false
  var restAttempts: seq[RestRespAttempt] = @[]
  var guard = initSubGuard()
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
    of kSub, kWsRaw:
      # VS-2 §12.5 subscription evidence, validated acceptance path like
      # rest_resp: each record must parse against its declared schema
      # (sub: gen/action/phase/t plus exactly its combination's fields;
      # ws_raw: channel/conn/t/payload_hex) or the run is rejected at the
      # record's own seq. Beyond the schema, every record feeds the subcheck
      # guard in stream order (README §10): a ws_raw's channel label must
      # match the class its bytes re-derive to, its 0B payload must parse by
      # the single tickwire parser (any deviation REJECTs at this seq), and
      # each parsed tick is either inside the confirmed active set (fed to
      # the bars, byte-identical to the live collector's consumption) or
      # quarantined — counted with its reason, never fed anywhere. The 0s
      # payloads contribute the FID 215 observations. REG/REMOVE/LOGIN/
      # PING/unknown payloads stay preserved bytes only.
      try:
        case recs[i].kind
        of kSub:
          let sub = parseSub(recs[i].seq, recs[i].raw)
          guard.observeSub(sub)
          inc result.subCount
        of kWsRaw:
          let w = parseWsRaw(recs[i].seq, recs[i].raw)
          guard.observeWsRaw(w.conn)
          let cls = classify(w.payload)
          if channelOfClass(cls) != w.channel:
            raise newException(SubInputError,
              "recorded channel \"" & w.channel & "\" does not match the " &
              "class the payload re-derives to (\"" &
              channelOfClass(cls) & "\"); a mislabeled payload is a " &
              "record-consistency failure")
          case cls
          of wcReal0B:
            for tick in ticksOf0B(recs[i].seq, w.payload):
              let q = guard.checkTick(tick.item)
              if q.kind == qkNone:
                feedTick(b, tick.item, hmsToSec(tick.t) - result.spec.openSec,
                         tick.price, tick.cumVol, tick.flag)
              else:
                inc result.quarantined
                if result.quarantineNotes.len < 64:
                  result.quarantineNotes.add(
                    (case q.kind
                     of qkUnsubscribed: "unsubscribed"
                     of qkPostRemove: "post_remove"
                     of qkStaleConn: "stale_conn"
                     of qkNone: "none") & " seq=" & $recs[i].seq &
                    " item=" & tick.item)
          of wcReal0S:
            for st in statesOf0S(recs[i].seq, w.payload):
              if st.value215.len > 0 and st.value215 notin result.closeValues:
                result.closeValues.add(st.value215)
          else:
            discard
          inc result.wsRawCount
        else: discard
      except SubInputError as e:
        raise newException(RecordError,
          schemaRejection(kindName(recs[i].kind), recs[i].seq, e.msg))
      except TickwireError as e:
        raise newException(RecordError,
          schemaRejection(kindName(recs[i].kind), recs[i].seq, e.msg))
      except SubGuardError as e:
        raise newException(RecordError,
          schemaRejection(kindName(recs[i].kind), recs[i].seq, e.msg))
    else:
      inc result.ignoredKinds
  # The declared page chains are audited once the record set is complete: a
  # body or chain failure is a contract violation (REJECT, exit 2) and takes
  # precedence over INCOMPLETE, never a silent pass. The declared re-poll
  # cadence and page cap come from the config record (README §6.1); with no
  # declared cadence the audit stays single-round.
  try:
    result.restVerified = verifyAttempts(restAttempts, result.config.pageCap,
                                         result.config.repollSeconds).len
  except RestRespError as e:
    raise newException(RecordError, restRejection(e.seqNo, e.msg))
  result.regAcks0B = guard.regAckCount0B()
  result.removeAcks0B = guard.removeAckCount0B()
  # The minimum close evidence of a sealed live stream (README §10): a
  # stream that declares an environment and carries the session_end seal
  # must re-derive, from its own preserved bytes, the documented
  # termination evidence — a FID 215 close value in {4,8} observed and a
  # confirmed (remove, ack 0) 0B teardown. A seal without that evidence is
  # a collector contract violation: REJECT, fail-closed, never approval.
  if result.config.environment.len > 0 and sawEnd:
    var closeSeen = false
    for v in result.closeValues:
      if isCloseEvidence(v): closeSeen = true
    if not closeSeen or result.removeAcks0B < 1:
      raise newException(RecordError,
        "the stream declares environment " & result.config.environment &
        " and is sealed, but the minimum close evidence was not re-detected " &
        "at replay (FID 215 in {4,8} observed: " & $closeSeen &
        "; confirmed 0B REMOVE acks: " & $result.removeAcks0B &
        ") — a sealed live session must carry its termination evidence " &
        "(tools/collector/README.md §10); rejected fail-closed")
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