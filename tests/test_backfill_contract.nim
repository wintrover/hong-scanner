## ka10080 backfill contract tests (REPLAY_CONTRACT §12.8/P21, VS-2B F-2):
## the 3-minute REST chart path — record acceptance, page-chain audit,
## BACKFILL bar derivation, origin marking, LIVE/BACKFILL merge, replay
## determinism and the frozen-run invariance of live-only streams.
##
## Synthetic payloads only: no network, no vendor data, no wall clock.
## Covers: the declared ka10080 scope schema (tic_scope pinned to the
## 3-minute scope, optional base_dt, enum fields), interleaved
## ka10027/ka10080 chain auditing, signed prices (부호가 포함된 숫자),
## the cntr_tm YYYYMMDDHHmmss placement rule and its documented
## UNVERIFIED boundary limitation, OHLC sanity, duplicate intervals,
## LIVE/BACKFILL overlap (fail-closed: P22 merge semantics are not
## declared), verify round-trips, and the §7 optional-field principle —
## a LIVE bar emits no origin field, so pre-contract streams stay
## byte-identical.
## Run: nim c -r --hints:off --warnings:off --path:src tests/test_backfill_contract.nim
import std/[os, strutils, sequtils, tempfiles]
import hs/[hcj, digest, records, replay, rest_resp, vendor_input, backfill,
           bars, verify, binfo]

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

proc bfUnit(name: string; failure: VendorFailure; needle: string;
            body: proc ()) =
  var raised = false
  var msg = ""
  try:
    body()
  except RestRespError as e:
    raised = e.failure == failure
    msg = if raised: e.msg else: "wrong class " & $e.failure & ": " & e.msg
  except VendorInputError as e:
    raised = e.failure == failure
    msg = if raised: e.msg else: "wrong class " & $e.failure & ": " & e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name, raised and needle in msg)

proc writeStream(name: string; lines: seq[string]): string =
  result = createTempDir("hs-backfill-" & name & "-", "")
  var content = ""
  for l in lines: content.add(l & "\n")
  writeFile(result / inputFile, content)

proc rejectRun(name, needle: string; lines: seq[string]) =
  ## The stream must be REJECTed (RecordError) carrying the failure detail.
  var raised = false
  var msg = ""
  try:
    discard runCore(loadRecords(writeStream("bf-rej", lines) / inputFile))
  except RecordError as e:
    raised = true
    msg = e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name, raised and needle in msg)

proc day(o, c: string): HcjValue =
  hObj(("close", hStr(c)), ("open", hStr(o)))

proc calRaw(): HcjValue =
  hObj(("days", hObj(
    ("2026-10-29", day("09:00:00+09:00", "15:30:00+09:00")))))

proc cfgRaw(): HcjValue = hObj(("session_date", hStr("2026-10-29")))

proc tickRaw(sym, t: string; price, vol: int64): HcjValue =
  hObj(("m", hStr("2")), ("price", hInt(price)), ("symbol", hStr(sym)),
       ("t", hStr(t)), ("vol", hInt(vol)))

proc baseLines(): seq[string] =
  ## Minimal valid session: two symbols, two bars each, normal close.
  result = @[
    makeRecordLine(1, kCalendar, calRaw()),
    makeRecordLine(2, kConfig, cfgRaw()),
    makeRecordLine(3, kWsFrame, tickRaw("005930", "09:00:00+09:00", 10000, 100)),
    makeRecordLine(4, kWsFrame, tickRaw("000660", "09:00:00+09:00", 20000, 500)),
    makeRecordLine(5, kWsFrame, tickRaw("005930", "09:03:00+09:00", 10100, 200)),
    makeRecordLine(6, kWsFrame, tickRaw("000660", "09:03:00+09:00", 20100, 700)),
    makeRecordLine(7, kSessionEnd, hNull())]

proc withInserts(lines: seq[string]; idx: int;
                 inserts: seq[(Kind, HcjValue)]): seq[string] =
  var recs: seq[tuple[k: Kind, raw: HcjValue]]
  for i, l in lines:
    let r = parseRecord(l, i + 1)
    recs.add((r.kind, r.raw))
  for j, ins in inserts:
    recs.insert(ins, idx + j)
  for i, p in recs:
    result.add(makeRecordLine(i + 1, p.k, p.raw))

proc runOf(name: string; lines: seq[string]): CoreResult =
  runCore(loadRecords(writeStream(name, lines) / inputFile))

proc coreBytes(lines: seq[string]): string =
  let res = runOf("core", lines)
  for b in res.bars: result.add(barLine(b) & "\n")
  result.add("--\n")
  for s in res.signals: result.add(signalLine(s) & "\n")

# ---------------------------------------------------------------- builders

proc hexOf(s: string): string = hexOfBytes(toBytes(s))

proc chartRow(cntrTm, open, high, low, cur, qty: string): HcjValue =
  ## One documented ka10080 row: all nine documented String fields. Values
  ## stay strings (the 부호가 포함된 숫자 convention is preserved raw).
  hObj(
    ("acc_trde_qty", hStr("999999")),
    ("cntr_tm", hStr(cntrTm)),
    ("cur_prc", hStr(cur)),
    ("high_pric", hStr(high)),
    ("low_pric", hStr(low)),
    ("open_pric", hStr(open)),
    ("pred_pre", hStr("+100")),
    ("pred_pre_sig", hStr("2")),
    ("trde_qty", hStr(qty)))

proc okBody80(rows: seq[HcjValue]): string =
  canonical(hObj((ka10080ListKey, hArrSeq(rows)), ("return_code", hInt(0))))

proc chartQuery(stkCd = "105930"; ticScope = "3"; updStkpcTp = "0";
                baseDt = ""): HcjValue =
  var pairs: seq[HcjPair] = @[
    ("stk_cd", hStr(stkCd)),
    ("tic_scope", hStr(ticScope)),
    ("upd_stkpc_tp", hStr(updStkpcTp))]
  if baseDt.len > 0:
    pairs.add(("base_dt", hStr(baseDt)))
  HcjValue(kind: hkObj, pairs: pairs)

proc attempt80Raw(body: string; page = 1; status = 200; contYn = "N";
                 nextKey = ""; query: HcjValue = chartQuery()): HcjValue =
  hObj(("api_id", hStr(ka10080ApiId)), ("body_hex", hStr(hexOf(body))),
       ("cont_yn", hStr(contYn)), ("next_key", hStr(nextKey)),
       ("page", hInt(page)), ("query", query), ("status", hInt(status)))

proc query27(): HcjValue =
  ## The nine declared ka10027 request fields at documented enum values
  ## (up direction, KRX) — for the interleaving case.
  hObj(("crd_cnd", hStr("0")), ("mrkt_tp", hStr("101")),
       ("pric_cnd", hStr("0")), ("sort_tp", hStr("1")),
       ("stk_cnd", hStr("0")), ("stex_tp", hStr("1")),
       ("trde_prica_cnd", hStr("0")), ("trde_qty_cnd", hStr("0000")),
       ("updown_incls", hStr("1")))

proc attempt27Raw(body: string; page = 1; contYn = "N";
                  nextKey = ""): HcjValue =
  hObj(("api_id", hStr(ka10027ApiId)), ("body_hex", hStr(hexOf(body))),
       ("cont_yn", hStr(contYn)), ("next_key", hStr(nextKey)),
       ("page", hInt(page)), ("query", query27()), ("status", hInt(200)))

proc body27(cd: string): string =
  canonical(hObj((ka10027ListKey, hArr(hObj(
    ("cur_prc", hStr("71500")), ("flu_rt", hStr("5.10")),
    ("stk_cd", hStr(cd)), ("stk_nm", hStr("종목"))))),
    ("return_code", hInt(0))))

proc attempt80CapRaw(page: int): RestRespAttempt =
  ## A cap-closed chart page: cont-yn=Y on every page, a distinct in-session
  ## cntr_tm per page (3-minute grid: page p -> minute 3p).
  let minute = align($(3 * page), 2, '0')
  parseAttempt(page + 2, attempt80Raw(
    okBody80(@[chartRow("2026102909" & minute & "00", "10000", "10100",
                        "9950", "+10100", "1200")]),
    page = page, contYn = "Y", nextKey = $page))

proc sameScope80(a, b: Ka10080Query): bool =
  canonical(ka10080RequestBody(a)) == canonical(ka10080RequestBody(b))

let okInfo = BuildInfo(codeCommit: "abc123", sourceRef: "main",
  originMainSha: "abc123", dirty: false, nimVersion: NimVersion,
  buildTime: "t")

# ---------------------------------------------------------- record parsing

block parseUnit:
  let body = okBody80(@[chartRow("20261029090000", "10000", "10100",
                                 "9950", "+10100", "1200")])
  let a = parseAttempt(3, attempt80Raw(body))
  check("ka10080: a chart attempt parses and is accepted",
        a.api == raKa10080)
  check("ka10080: the declared scope surfaces intact",
        a.scope80.stkCd == "105930" and a.scope80.ticScope == "3" and
        a.scope80.updStkpcTp == "0" and a.scope80.baseDt == "" and
        sameScope80(a.scope80, initKa10080Query("105930", "3", "0", "")))
  check("ka10080: the preserved response surfaces intact",
        a.resp.apiId == ka10080ApiId and a.resp.status == 200 and
        a.resp.contYn == "N" and a.resp.body == toBytes(body))
  check("ka10080: audit fingerprint matches the decoded bytes",
        a.bodySha256 == sha256Hex(toBytes(body)))
  check("ka10080: a single-page chain verifies",
        verifyAttempts(@[a]).len == 1)

  let withBase = parseAttempt(3, attempt80Raw(body,
    query = chartQuery(baseDt = "20261028")))
  check("ka10080: base_dt is accepted when declared (YYYYMMDD)",
        withBase.scope80.baseDt == "20261028" and
        sameScope80(withBase.scope80, initKa10080Query("105930", "3", "0",
                                                       "20261028")))
  check("ka10080: base_dt absent round-trips as an absent field",
        "base_dt" notin canonical(ka10080RequestBody(a.scope80)) and
        "base_dt" in canonical(ka10080RequestBody(withBase.scope80)))

# ------------------------------------------------------------- scope schema

block scopeSchema:
  let body = okBody80(@[])

  bfUnit("scope: api_id outside the acceptance path", vfContract,
         "outside the declared acceptance path",
         proc () =
           let r = attempt80Raw(body)
           var ps: seq[HcjPair]
           for p in r.pairs:
             if p.k == "api_id": ps.add((p.k, hStr("ka11080")))
             else: ps.add(p)
           discard parseAttempt(3, HcjValue(kind: hkObj, pairs: ps)))
  bfUnit("scope: tic_scope 1 is outside the declared 3-minute scope",
         vfContract, "outside this implementation's declared scope",
         proc () =
           discard parseAttempt(3, attempt80Raw(body,
             query = chartQuery(ticScope = "1"))))
  bfUnit("scope: missing stk_cd", vfContract,
         "missing declared ka10080 query field: stk_cd",
         proc () =
           discard parseAttempt(3, attempt80Raw(body,
             query = hObj(("tic_scope", hStr("3")),
                          ("upd_stkpc_tp", hStr("0"))))))
  bfUnit("scope: unknown query field", vfContract,
         "unknown declared ka10080 query field",
         proc () =
           discard parseAttempt(3, attempt80Raw(body,
             query = hObj(("stk_cd", hStr("105930")),
                          ("tic_scope", hStr("3")),
                          ("upd_stkpc_tp", hStr("0")),
                          ("sort_tp", hStr("1"))))))
  bfUnit("scope: non-string query field", vfContract,
         "is not a string",
         proc () =
           discard parseAttempt(3, attempt80Raw(body,
             query = hObj(("stk_cd", hInt(105930)),
                          ("tic_scope", hStr("3")),
                          ("upd_stkpc_tp", hStr("0"))))))
  bfUnit("scope: base_dt is not YYYYMMDD digits", vfContract,
         "not the documented YYYYMMDD form",
         proc () =
           discard parseAttempt(3, attempt80Raw(body,
             query = chartQuery(baseDt = "2026-10-28"))))
  bfUnit("scope: upd_stkpc_tp outside the documented enum", vfContract,
         "not in the documented enum",
         proc () =
           discard parseAttempt(3, attempt80Raw(body,
             query = chartQuery(updStkpcTp = "2"))))
  bfUnit("scope: empty stk_cd", vfContract, "must not be empty",
         proc () =
           discard initKa10080Query("", "3", "0", ""))

# ----------------------------------------------------------- chain audits

block chainRules:
  let r1 = okBody80(@[chartRow("20261029090000", "10000", "10100", "9950",
                               "+10100", "1200")])
  let r2 = okBody80(@[chartRow("20261029090300", "10100", "10200", "10050",
                               "10200", "800")])
  let p1 = parseAttempt(3, attempt80Raw(r1, page = 1, contYn = "Y",
                                        nextKey = "k1"))
  let p2 = parseAttempt(4, attempt80Raw(r2, page = 2))
  check("chain: a declared two-page chart chain verifies in order",
        verifyAttempts(@[p1, p2]).len == 2)
  bfUnit("chain: below-cap cont-yn=Y is a missing continuation (fail-closed)",
         vfIncomplete, "continuation page is missing",
         proc () = discard verifyAttempts(@[p1]))
  bfUnit("chain: a page gap is rejected", vfContract, "leaves a gap",
         proc () = discard verifyAttempts(@[
           parseAttempt(3, attempt80Raw(r1, contYn = "Y", nextKey = "k1")),
           parseAttempt(4, attempt80Raw(r2, page = 3))]))
  bfUnit("chain: a duplicate page-1 restart is rejected", vfContract,
         "repeats page 1",
         proc () = discard verifyAttempts(@[
           parseAttempt(3, attempt80Raw(r1)),
           parseAttempt(4, attempt80Raw(r2))]))
  bfUnit("chain: first recorded page must be 1", vfContract,
         "does not start at page 1",
         proc () = discard verifyAttempts(@[p2]))
  block:
    var xs: seq[RestRespAttempt]
    for p in 1 .. defaultPageCap:
      xs.add(attempt80CapRaw(p))
    let vt = verifyAttempts(@xs)
    check("chain: a cap-closed chart round audits as a declared truncated " &
          "subset (pages verified; the truncation fact is separate)",
          vt.len == defaultPageCap)
  # Interleaved with a ka10027 chain: one stream, both APIs, independent
  # audits and separate grouping.
  let c1 = parseAttempt(5, attempt27Raw(body27("005930"), contYn = "Y",
                                        nextKey = "k1"))
  let c2 = parseAttempt(6, attempt27Raw(body27("000660"), page = 2))
  let v = verifyAttempts(@[p1, c1, p2, c2])
  check("chain: interleaved ka10027/ka10080 scopes audit as separate chains",
        v.len == 4)
  check("chain: verified attempts return in stream order",
        v[0].seqNo == 3 and v[1].seqNo == 4 and v[2].seqNo == 5 and
        v[3].seqNo == 6)
  let chains = ka10080Chains(@[p1, c1, p2, c2])
  check("chains: only the ka10080 attempts assemble, per scope, in page order",
        chains.len == 1 and chains[0].pages.len == 2 and
        canonical(ka10080RequestBody(chains[0].query)) ==
        canonical(ka10080RequestBody(p1.scope80)))

# ------------------------------------------------------------------- bars

block barDerivation:
  ## One chart page with three rows (signed close, plain close, and the
  ## session-close boundary row) for a symbol with NO live ticks.
  let body = okBody80(@[
    chartRow("20261029090000", "10000", "10100", "9950", "+10100", "1200"),
    chartRow("20261029090300", "10100", "10200", "10050", "10200", "800"),
    chartRow("20261029153000", "9900", "9950", "9850", "9900", "300")])
  let lines = withInserts(baseLines(), 6,
                          @[(kRestResp, attempt80Raw(body))])
  let res = runOf("bars", lines)
  check("bars: a verified ka10080 page derives BACKFILL bars, stream replays OK",
        res.status == rsOk and res.restVerified == 1)
  check("bars: live bars stay 4, backfill adds 3 (merge is the union)",
        res.bars.len == 7)
  var liveLines: seq[string]
  var bfLines: seq[string]
  for b in res.bars:
    if b.origin == "BACKFILL": bfLines.add(barLine(b)) else: liveLines.add(barLine(b))
  check("bars: exactly the chart rows carry origin BACKFILL",
        bfLines.len == 3 and liveLines.len == 4)
  check("bars: a LIVE bar line carries no origin field (§7 optional field)",
        liveLines.len > 0 and
        all(liveLines, proc (l: string): bool = "origin" notin l))
  check("bars: a BACKFILL bar line carries origin:\"BACKFILL\"",
        all(bfLines, proc (l: string): bool = "\"origin\":\"BACKFILL\"" in l))
  var bf0: Bar
  var bf1: Bar
  var bfLast: Bar
  for b in res.bars:
    if b.symbol == "105930":
      case b.index
      of 0: bf0 = b
      of 1: bf1 = b
      of 129: bfLast = b
      else: discard
  check("bars: row 1 maps to bar 0 with the documented field mapping",
        bf0.symbol == "105930" and bf0.index == 0 and bf0.open == 10000 and
        bf0.high == 10100 and bf0.low == 9950 and bf0.close == 10100 and
        bf0.vol == 1200 and bf0.ticks == 1)
  check("bars: the + sign of a 부호가 포함된 숫자 close parses as the value",
        bf1.close == 10200 and bf1.open == 10100 and bf1.vol == 800)
  check("bars: a backfill bar carries the neutral live quality flags",
        bf0.closed and not bf0.degraded and not bf0.volPartial and
        not bf0.empty and not bf0.outOfOrder and bf0.gapEdge.len == 0 and
        bf0.pos == "steady" and bf0.sessionClass == "in_session")
  check("bars: cntr_tm == close maps to the last bar with close_boundary",
        bfLast.index == 129 and bfLast.closeBoundary and not bf0.closeBoundary)
  check("bars: bars sort by (symbol, index) across LIVE and BACKFILL",
        res.bars[0].symbol == "000660" and res.bars[2].symbol == "005930" and
        res.bars[4].symbol == "105930" and res.bars[4].index == 0)
  check("bars: two replays are byte-identical (determinism)",
        coreBytes(lines) == coreBytes(lines))

  # LATE_START shape: backfill bars 0..1 then live ticks from bar 2 for the
  # SAME symbol — no overlap, merged in index order, engine consumes both.
  let lateLines = @[
    makeRecordLine(1, kCalendar, calRaw()),
    makeRecordLine(2, kConfig, cfgRaw()),
    makeRecordLine(3, kRestResp, attempt80Raw(okBody80(@[
      chartRow("20261029090000", "10000", "10100", "9950", "+10100", "1200"),
      chartRow("20261029090300", "10100", "10200", "10050", "10200", "800")]),
      query = chartQuery(stkCd = "005930"))),
    makeRecordLine(4, kWsFrame, tickRaw("005930", "09:09:00+09:00", 10300, 50)),
    makeRecordLine(5, kWsFrame, tickRaw("005930", "09:12:00+09:00", 10400, 80)),
    makeRecordLine(6, kWsFrame, tickRaw("005930", "09:15:00+09:00", 10500, 90)),
    makeRecordLine(7, kSessionEnd, hNull())]
  let late = runOf("late", lateLines)
  check("late-start: backfill bars precede the live bars of the same symbol",
        late.status == rsOk and late.bars.len == 5 and
        late.bars[0].origin == backfillOrigin and late.bars[0].index == 0 and
        late.bars[1].origin == backfillOrigin and late.bars[1].index == 1 and
        late.bars[2].origin.len == 0 and late.bars[2].index == 3 and
        late.bars[2].closed and late.bars[3].index == 4 and
        late.bars[4].index == 5)
  check("late-start: the engine consumes the merged history deterministically",
        coreBytes(lateLines) == coreBytes(lateLines))

  # The raw preservation itself: the recorded body_hex is the exact bytes
  # and the bars are re-derived from them, never from a second copy.
  let a = parseAttempt(3, attempt80Raw(body))
  check("re-derivation: the preserved body bytes re-parse to the same rows",
        parsePageRows(ka10080Spec, a.resp).len == 3)

# ----------------------------------------------------- row-level failures

block rowFailures:
  proc linesWith(rows: seq[HcjValue]): seq[string] =
    withInserts(baseLines(), 6, @[(kRestResp,
      attempt80Raw(okBody80(rows)))])

  rejectRun("row: a negative price is rejected", "is negative",
            linesWith(@[chartRow("20261029090000", "10000", "10100", "9950",
                                 "-10100", "1200")]))
  rejectRun("row: an empty price is rejected", "is empty",
            linesWith(@[chartRow("20261029090000", "10000", "10100", "9950",
                                 "", "1200")]))
  rejectRun("row: high below low is rejected", "high_pric is below",
            linesWith(@[chartRow("20261029090000", "10000", "9900", "9950",
                                 "10100", "1200")]))
  rejectRun("row: low above open is rejected", "low_pric is above",
            linesWith(@[chartRow("20261029090000", "10000", "10100", "10050",
                                 "10100", "1200")]))
  rejectRun("row: cntr_tm with the wrong digit count is rejected",
            "14-digit",
            linesWith(@[chartRow("2026102909000", "10000", "10100", "9950",
                                 "10100", "1200")]))
  rejectRun("row: cntr_tm with a non-digit is rejected",
            "carries a non-digit",
            linesWith(@[chartRow("2026102909000x", "10000", "10100", "9950",
                                 "10100", "1200")]))
  rejectRun("row: cntr_tm of another day is rejected", "not the session date",
            linesWith(@[chartRow("20261028090000", "10000", "10100", "9950",
                                 "10100", "1200")]))
  rejectRun("row: cntr_tm before the open is rejected",
            "outside the session window",
            linesWith(@[chartRow("20261029085900", "10000", "10100", "9950",
                                 "10100", "1200")]))
  rejectRun("row: cntr_tm after the close is rejected",
            "outside the session window",
            linesWith(@[chartRow("20261029153100", "10000", "10100", "9950",
                                 "10100", "1200")]))
  rejectRun("row: two rows on one interval are rejected", "same bar",
            linesWith(@[
              chartRow("20261029090000", "10000", "10100", "9950", "10100",
                       "1200"),
              chartRow("20261029090030", "10000", "10100", "9950", "10100",
                       "1200")]))
  rejectRun("row: a row missing cur_prc is rejected",
            "lacks the string field cur_prc",
            linesWith(@[hObj(
              ("acc_trde_qty", hStr("999999")),
              ("cntr_tm", hStr("20261029090000")),
              ("high_pric", hStr("10100")),
              ("low_pric", hStr("9950")),
              ("open_pric", hStr("10000")),
              ("pred_pre", hStr("+100")),
              ("pred_pre_sig", hStr("2")),
              ("trde_qty", hStr("1200")))]))
  rejectRun("merge: a LIVE/BACKFILL overlap is rejected",
            "derived BOTH live",
            withInserts(baseLines(), 6, @[(kRestResp,
              attempt80Raw(okBody80(@[
                chartRow("20261029090000", "10000", "10100", "9950",
                         "+10100", "1200")]),
                query = chartQuery(stkCd = "005930")))]))
  rejectRun("merge: a duplicate row across two chains is rejected",
            "same bar",
            withInserts(baseLines(), 6, @[
              (kRestResp, attempt80Raw(okBody80(@[
                chartRow("20261029090000", "10000", "10100", "9950",
                         "+10100", "1200")]))),
              (kRestResp, attempt80Raw(okBody80(@[
                chartRow("20261029090000", "10000", "10100", "9950",
                         "+10100", "1200")]),
                query = chartQuery(updStkpcTp = "1")))]))

  # base_dt other than the session date: every row is of that other day,
  # so nothing can be placed — fail-closed.
  rejectRun("row: a base_dt chain of another day is unconsumable",
            "not the session date",
            withInserts(baseLines(), 6, @[(kRestResp,
              attempt80Raw(okBody80(@[
                chartRow("20261028090000", "10000", "10100", "9950",
                         "+10100", "1200")]),
                query = chartQuery(baseDt = "20261028")))]))

  # A vendor-error chart body is a chain failure (REJECT precedes INCOMPLETE
  # and any bar derivation).
  rejectRun("affirmation: a vendor-error chart page is REJECT",
            "vendor return_code 5",
            withInserts(baseLines(), 6, @[(kRestResp,
              attempt80Raw(canonical(hObj(("return_code", hInt(5)),
                                         ("return_msg", hStr("거부"))))))]))

# ---------------------------------------------------------- stream levels

block streamLevels:
  let body = okBody80(@[chartRow("20261029090000", "10000", "10100", "9950",
                                 "+10100", "1200")])
  # INCOMPLETE (unsealed) with a verified chart page: restVerified counts,
  # bars are not emitted, no rejection.
  let unsealed = withInserts(baseLines()[0 .. ^2], 5,
                             @[(kRestResp, attempt80Raw(body))])
  let inc = runOf("inc", unsealed)
  check("stream: an unsealed chart stream is INCOMPLETE, not REJECT",
        inc.status == rsIncomplete and inc.restVerified == 1 and
        inc.bars.len == 0)
  let dir = writeStream("inc-run", unsealed)
  let inPath = dir / inputFile
  discard writeRun(dir / "run", inPath, runCore(loadRecords(inPath)), okInfo)
  let vInc = verifyRun(dir / "run", okInfo)
  check("stream: verify reports INCOMPLETE exit 4 for it",
        vInc.verdict == vIncomplete and exitCode(vInc.verdict) == 4)

  # Sealed + verified: MATCH provenance=OK, the backfill bar byte-compared
  # by the artifact audit.
  let sealed = withInserts(baseLines(), 6, @[(kRestResp, attempt80Raw(body))])
  let goodDir = writeStream("verdict-good", sealed)
  let inPath2 = goodDir / inputFile
  discard writeRun(goodDir / "run", inPath2, runCore(loadRecords(inPath2)),
                   okInfo)
  let g = verifyRun(goodDir / "run", okInfo)
  check("stream: a verified chart stream is MATCH provenance=OK",
        g.verdict == vMatch and g.matched and
        verdictLine(g) == "VERDICT MATCH provenance=OK")
  let barsText = readFile(goodDir / "run" / barsFile)
  check("stream: the run artifact carries the origin field verbatim",
        barsText.contains("\"origin\":\"BACKFILL\"") and
        barsText.count("\n") == 5)

  # The judgment layer: ka10080 records judge no candidate facts (§13
  # table — candidate transitions are ka10027 chains only).
  let withChart = withInserts(baseLines(), 6, @[(kRestResp,
                                                 attempt80Raw(body))])
  let res = runOf("events", withChart)
  check("events: ka10080 records judge no facts of their own",
        res.events.len == 1 and
        not any(res.events, proc (l: string): bool =
                  "candidate" in l))

  # The frozen-run invariance (the §7 optional-field principle, measured):
  # a live-only stream's bar bytes contain no origin field, and inserting a
  # VERIFIED ka10080 record changes only the backfill bars' own lines.
  let plain = coreBytes(baseLines())
  check("invariance: a live-only stream emits no origin field",
        "origin" notin plain)
  let withBf = coreBytes(withChart)
  let plainLines = plain.split("\n")
  let bfLines2 = withBf.split("\n")
  var liveKept = 0
  for l in plainLines:
    if l.startsWith("{") and l in bfLines2:
      inc liveKept
  check("invariance: every live bar and signal line survives the backfill " &
        "merge byte-exact (4 bars + 2 signals)", liveKept == 6)

echo ""
echo passes, " passed, ", failures, " failed"
if failures > 0: quit(1)
