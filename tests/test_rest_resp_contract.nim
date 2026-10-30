## rest_resp validated acceptance path contract tests (REPLAY_CONTRACT §12.1,
## the VS-2 implementation choice that replaces the VS-1 reject-everything
## placeholder).
##
## Synthetic payloads only: no network, no vendor data, no wall clock.
## Covers: the HCJ-safe hex byte encoding, the success path (map rows,
## documented positional rows, explicit empty list, multi-page chains,
## interleaved scopes), every failure class (schema / transport / vendor
## error / missing return_code / missing list key), order and page-chain
## consistency, re-derivation from the preserved bytes, and the stream-level
## rule that a verified success changes no output byte while any failure
## stays REJECT (exit 2).
## Run: nim c -r --hints:off --warnings:off --path:src tests/test_rest_resp_contract.nim
import std/[os, strutils, tempfiles]
import hs/[hcj, digest, records, replay, rest_resp, vendor_input, verify,
           binfo]

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

proc restUnit(name: string; failure: VendorFailure; needle: string;
              body: proc ()) =
  ## parseAttempt/verifyAttempts must raise RestRespError of the exact
  ## failure class with a self-explaining message.
  var raised = false
  var msg = ""
  try:
    body()
  except RestRespError as e:
    raised = e.failure == failure
    msg = if raised: e.msg else: "wrong class " & $e.failure & ": " & e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name, raised and needle in msg)

proc writeStream(name: string; lines: seq[string]): string =
  ## dir/input.hcj.jsonl with LF discipline; returns the run dir.
  result = createTempDir("hs-restresp-" & name & "-", "")
  var content = ""
  for l in lines: content.add(l & "\n")
  writeFile(result / inputFile, content)

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
  ## Insert records at idx (0-based) and renumber seq 1..N.
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
  let res = runCore(loadRecords(writeStream("core", lines) / inputFile))
  for b in res.bars: result.add(barLine(b) & "\n")
  result.add("--\n")
  for s in res.signals: result.add(signalLine(s) & "\n")

proc rejectRun(name, needle: string; lines: seq[string]) =
  ## The stream must be REJECTed (RecordError) with the wrapper prefix and
  ## the failure detail.
  var raised = false
  var msg = ""
  try:
    discard runOf("rej", lines)
  except RecordError as e:
    raised = true
    msg = e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name, raised and msg.startsWith("rest_resp at seq") and
        needle in msg)

# ---------------------------------------------------------------- builders

proc hexOf(s: string): string = hexOfBytes(toBytes(s))

proc row(cd, nm, prc, rt: string): HcjValue =
  hObj(("cur_prc", hStr(prc)), ("flu_rt", hStr(rt)),
       ("stk_cd", hStr(cd)), ("stk_nm", hStr(nm)))

proc posRow(): HcjValue =
  ## One row in the documented positional (array) form: the 12 documented
  ## fields in documented order. Values stay strings.
  hArr(hStr("2"), hStr("005930"), hStr("삼성전자"), hStr("+71500"), hStr("2"),
       hStr("5000"), hStr("5.10"), hStr("1000"), hStr("900"),
       hStr("50000"), hStr("+5.5%"), hStr("0"))

proc okBody(rows: seq[HcjValue]): string =
  canonical(hObj((ka10027ListKey, hArrSeq(rows)), ("return_code", hInt(0))))

proc vendorErrBody(code: int; msg: string): string =
  canonical(hObj(("return_code", hInt(code)), ("return_msg", hStr(msg))))

proc rawBody(pairs: varargs[HcjPair]): string = canonical(hObj(pairs))

proc queryObj(sortTp = "1"; stexTp = "1"; mrktTp = "101"): HcjValue =
  ## The nine declared request fields, all pinned at documented enum values.
  hObj(("crd_cnd", hStr("0")), ("mrkt_tp", hStr(mrktTp)),
       ("pric_cnd", hStr("0")), ("sort_tp", hStr(sortTp)),
       ("stk_cnd", hStr("0")), ("stex_tp", hStr(stexTp)),
       ("trde_prica_cnd", hStr("0")), ("trde_qty_cnd", hStr("0000")),
       ("updown_incls", hStr("1")))

proc attemptRaw(body: string; page = 1; status = 200; contYn = "N";
                nextKey = ""; query: HcjValue = queryObj()): HcjValue =
  hObj(("api_id", hStr(ka10027ApiId)), ("body_hex", hStr(hexOf(body))),
       ("cont_yn", hStr(contYn)), ("next_key", hStr(nextKey)),
       ("page", hInt(page)), ("query", query), ("status", hInt(status)))

proc dropKey(v: HcjValue; key: string) =
  var keep: seq[HcjPair]
  for p in v.pairs:
    if p.k != key: keep.add(p)
  v.pairs = keep

proc setType(v: HcjValue; key: string; val: HcjValue) =
  for p in v.pairs.mitems:
    if p.k == key: p.v = val

proc sameQuery(a, b: Ka10027Query): bool =
  canonical(ka10027RequestBody(a)) == canonical(ka10027RequestBody(b))

let refScope = initKa10027Query(dirUp, "101", "0000", "0", "0", "1", "0",
                                "0", "1")

# ---------------------------------------------------------------- hex contract

block hexContract:
  check("hex: empty encodes to empty",
        hexOfBytes(@[]).len == 0 and bytesFromHex("").len == 0)
  let bin: seq[byte] = @[0x00'u8, 0x0a'u8, 0x22'u8, 0x7f'u8, 0x80'u8,
                         0xfe'u8, 0xff'u8]
  check("hex: arbitrary bytes round-trip byte-exact",
        bytesFromHex(hexOfBytes(bin)) == bin)
  let ko = "삼성전자/return_code 0"
  check("hex: UTF-8 text round-trips byte-exact",
        bytesFromHex(hexOfBytes(toBytes(ko))) == toBytes(ko))
  check("hex: known vector", hexOfBytes(@[0xde'u8, 0xad'u8, 0xbe'u8,
                                          0xef'u8]) == "deadbeef")
  restUnit("hex: odd length is rejected", vfContract, "odd length",
           proc () = discard bytesFromHex("abc"))
  restUnit("hex: uppercase hex is rejected", vfContract, "lowercase",
           proc () = discard bytesFromHex("DEADBEEF"))
  restUnit("hex: non-hex digit is rejected", vfContract, "lowercase",
           proc () = discard bytesFromHex("0g"))

# ---------------------------------------------------------------- success path

block unitSuccess:
  let body = okBody(@[row("005930", "삼성전자", "71500", "5.10"),
                      row("000660", "SK하이닉스", "182200", "3.25")])
  let a = parseAttempt(4, attemptRaw(body))
  check("parse surfaces the declared page index", a.page == 1)
  check("parse surfaces the declared scope",
        sameQuery(a.scope, refScope))
  check("parse surfaces the preserved response metadata",
        a.resp.apiId == ka10027ApiId and a.resp.status == 200 and
        a.resp.contYn == "N" and a.resp.nextKey == "")
  check("parse decodes the body byte-exact", a.resp.body == toBytes(body))
  check("audit fingerprint matches the decoded bytes",
        a.bodySha256 == sha256Hex(toBytes(body)))
  check("a terminal success page verifies",
        verifyAttempts(@[a]).len == 1)

  let p1 = parseAttempt(3, attemptRaw(
    okBody(@[row("005930", "삼성전자", "71500", "5.10")]),
    page = 1, contYn = "Y", nextKey = "000660"))
  let p2 = parseAttempt(4, attemptRaw(
    okBody(@[row("000660", "SK하이닉스", "182200", "3.25")]), page = 2))
  let v2 = verifyAttempts(@[p1, p2])
  check("a declared two-page chain verifies in order",
        v2.len == 2 and v2[0].page == 1 and v2[1].page == 2)

  let d1 = parseAttempt(5, attemptRaw(
    okBody(@[row("999999", "하락1위", "1000", "-1.0")]),
    page = 1, contYn = "Y", nextKey = "next", query = queryObj(sortTp = "3")))
  let d2 = parseAttempt(6, attemptRaw(
    okBody(@[row("888888", "하락2위", "900", "-2.0")]), page = 2,
    query = queryObj(sortTp = "3")))
  let v3 = verifyAttempts(@[p1, d1, p2, d2])
  check("interleaved scopes verify as separate chains", v3.len == 4)
  check("verified attempts return in stream order",
        v3[0].seqNo == 3 and v3[1].seqNo == 4 and v3[2].seqNo == 5 and
        v3[3].seqNo == 6)

  check("the documented positional row form verifies",
        verifyAttempts(@[parseAttempt(3, attemptRaw(okBody(@[posRow()])))]).len == 1)
  check("an explicit empty list is a confirmed empty answer",
        verifyAttempts(@[parseAttempt(3, attemptRaw(okBody(@[])))]).len == 1)
  check("an empty record set verifies trivially", verifyAttempts(@[]).len == 0)

# ---------------------------------------------------------------- re-derivation

block rederive:
  ## §12.2/§12.3: the normalized rows must be re-derivable from the
  ## preserved bytes. The record's body_hex decode and the original body
  ## string must yield identical events.
  let body = okBody(@[row("005930", "삼성전자", "71500", "5.10"),
                      row("000660", "SK하이닉스", "182200", "3.25")])
  let a = parseAttempt(3, attemptRaw(body))
  let direct = httpResp(ka10027ApiId, 200, "N", "", toBytes(body))
  let fromRecord = normalizeChain(ka10027Spec,
    PageChain(query: refScope, pages: @[a.resp]))
  let fromBytes = normalizeChain(ka10027Spec,
    PageChain(query: refScope, pages: @[direct]))
  check("re-derivation: same event count",
        fromRecord.len == 2 and fromBytes.len == 2)
  var same = fromRecord.len == fromBytes.len
  for i in 0 ..< min(fromRecord.len, fromBytes.len):
    if not sameEvent(fromRecord[i], fromBytes[i]): same = false
  check("re-derivation: events identical byte- and value-wise", same)
  check("re-derivation: source hash is the preserved body",
        fromRecord[0].sourceSha256 == sha256Hex(toBytes(body)))
  let syms = chainSymbols(ka10027Spec,
    PageChain(query: refScope, pages: @[a.resp]))
  check("re-derivation: candidates in vendor order",
        syms == @["005930", "000660"])
  let line = makeRecordLine(3, kRestResp, attemptRaw(body))
  let back = parseAttempt(3, parseRecord(line, 3).raw)
  check("HCJ round trip: canonical record bytes preserve body_hex exactly",
        back.bodySha256 == a.bodySha256 and back.page == 1 and
        sameQuery(back.scope, a.scope))

# ---------------------------------------------------------------- schema

block failureSchema:
  let body = okBody(@[row("005930", "삼성전자", "71500", "5.10")])

  restUnit("schema: null raw is rejected", vfContract, "not an object",
           proc () = discard parseAttempt(3, hNull()))
  restUnit("schema: string raw is rejected", vfContract, "not an object",
           proc () = discard parseAttempt(3, hStr("ok")))
  restUnit("schema: array raw is rejected", vfContract, "not an object",
           proc () = discard parseAttempt(3, hArr(hInt(200))))
  restUnit("schema: empty object is missing fields", vfContract,
           "missing rest_resp field: api_id",
           proc () = discard parseAttempt(3, hObj()))
  restUnit("schema: unknown record field (legacy vendor_msg)", vfContract,
           "unknown rest_resp field: vendor_msg",
           proc () =
             let r = attemptRaw(body)
             r.pairs.add(("vendor_msg", hStr("extra")))
             discard parseAttempt(3, r))
  restUnit("schema: missing body_hex", vfContract,
           "missing rest_resp field: body_hex",
           proc () =
             let r = attemptRaw(body)
             dropKey(r, "body_hex")
             discard parseAttempt(3, r))
  restUnit("schema: status is not an integer", vfContract, "not an integer",
           proc () =
             let r = attemptRaw(body)
             setType(r, "status", hStr("200"))
             discard parseAttempt(3, r))
  restUnit("schema: page 0 is rejected", vfContract,
           "page index must be >= 1",
           proc () = discard parseAttempt(3, attemptRaw(body, page = 0)))
  restUnit("schema: api_id outside the declared path", vfContract,
           "outside the declared acceptance path",
           proc () =
             let r = attemptRaw(body)
             setType(r, "api_id", hStr("ka10080"))
             discard parseAttempt(3, r))
  restUnit("schema: sort_tp 2 is not a candidate direction", vfContract,
           "not a candidate direction",
           proc () = discard parseAttempt(3,
             attemptRaw(body, query = queryObj(sortTp = "2"))))
  restUnit("schema: stex_tp 3 is outside the KRX universe", vfContract,
           "outside the candidate universe",
           proc () = discard parseAttempt(3,
             attemptRaw(body, query = queryObj(stexTp = "3"))))
  restUnit("schema: mrkt_tp outside the documented enum", vfContract,
           "not in the documented enum",
           proc () = discard parseAttempt(3,
             attemptRaw(body, query = queryObj(mrktTp = "999"))))
  restUnit("schema: query is not an object", vfContract, "not an object",
           proc () =
             let r = attemptRaw(body)
             setType(r, "query", hStr("nope"))
             discard parseAttempt(3, r))
  restUnit("schema: query misses a declared field", vfContract,
           "missing declared query field: sort_tp",
           proc () =
             let q = queryObj()
             dropKey(q, "sort_tp")
             discard parseAttempt(3, attemptRaw(body, query = q)))
  restUnit("schema: query has an unknown field", vfContract,
           "unknown declared query field: extra",
           proc () =
             let q = queryObj()
             q.pairs.add(("extra", hStr("x")))
             discard parseAttempt(3, attemptRaw(body, query = q)))
  restUnit("schema: query field is not a string", vfContract,
           "declared query field is not a string",
           proc () =
             let q = queryObj()
             setType(q, "mrkt_tp", hInt(101))
             discard parseAttempt(3, attemptRaw(body, query = q)))
  restUnit("schema: body_hex is not a string", vfContract, "not a string",
           proc () =
             let r = attemptRaw(body)
             setType(r, "body_hex", hInt(0))
             discard parseAttempt(3, r))

# ------------------------------------------------- success affirmation failures

proc unitVerify(name: string; failure: VendorFailure; needle: string;
                a: RestRespAttempt) =
  ## The attempt parses; its affirmation/chain check must reject it.
  restUnit(name, failure, needle,
           proc () = discard verifyAttempts(@[a]))

block failureAffirmation:
  unitVerify("transport: HTTP 503 page is rejected", vfTransport,
             "HTTP status 503",
             parseAttempt(3, attemptRaw(okBody(@[]), status = 503)))
  unitVerify("vendor error: return_code 5 is rejected", vfVendorError,
             "vendor return_code 5",
             parseAttempt(3, attemptRaw(vendorErrBody(5, "조회 거부"))))
  unitVerify("missing return_code never maps to success", vfVendorError,
             "return_code is missing",
             parseAttempt(3, attemptRaw(rawBody(("return_msg", hStr("ok"))))))
  unitVerify("missing list key never maps to empty", vfContract,
             ka10027ListKey & " is missing",
             parseAttempt(3, attemptRaw(rawBody(("return_code", hInt(0))))))
  unitVerify("body that is not JSON is rejected", vfContract,
             "not valid HCJ JSON",
             parseAttempt(3, attemptRaw("nope")))
  unitVerify("body that is not an object is rejected", vfContract,
             "not a JSON object",
             parseAttempt(3, attemptRaw("[]")))
  unitVerify("unknown body key is rejected", vfContract,
             "outside the documented schema",
             parseAttempt(3, attemptRaw(rawBody(("extra", hInt(1)),
                                                ("return_code", hInt(0))))))
  unitVerify("row field outside the schema is rejected", vfContract,
             "row field outside the documented schema",
             parseAttempt(3, attemptRaw(okBody(@[
               hObj(("hack", hStr("x")), ("stk_cd", hStr("005930")))]))))
  unitVerify("non-string row field is rejected", vfContract,
             "row field is not a string",
             parseAttempt(3, attemptRaw(okBody(@[
               hObj(("stk_cd", hInt(5930)))]))))
  unitVerify("positional row with the wrong length is rejected", vfContract,
             "positional row length is not the documented field count",
             parseAttempt(3, attemptRaw(okBody(@[
               hArr(hStr("2"), hStr("005930"))]))))

# ---------------------------------------------------------------- chain rules

block chainRules:
  restUnit("chain: first recorded page must be 1", vfContract,
           "does not start at page 1",
           proc () = discard verifyAttempts(@[
             parseAttempt(3, attemptRaw(okBody(@[]), page = 2))]))
  restUnit("chain: a page gap is rejected", vfContract, "leaves a gap",
           proc () = discard verifyAttempts(@[
             parseAttempt(3, attemptRaw(okBody(@[]), page = 1,
                                        contYn = "Y", nextKey = "k")),
             parseAttempt(4, attemptRaw(okBody(@[]), page = 3))]))
  restUnit("chain: a duplicate page-1 restart is rejected", vfContract,
           "repeats page 1",
           proc () = discard verifyAttempts(@[
             parseAttempt(3, attemptRaw(okBody(@[]))),
             parseAttempt(4, attemptRaw(okBody(@[])))]))
  restUnit("chain: cont-yn=Y below the cap is incomplete", vfIncomplete,
           "continuation page is missing",
           proc () = discard verifyAttempts(@[
             parseAttempt(3, attemptRaw(okBody(@[]), contYn = "Y",
                                        nextKey = "k"))]))
  restUnit("chain: the cap reached while cont-yn=Y is truncated", vfTruncated,
           "truncated",
           proc () =
             var xs: seq[RestRespAttempt]
             for p in 1 .. defaultPageCap:
               xs.add(parseAttempt(p + 2, attemptRaw(okBody(@[]), page = p,
                                                     contYn = "Y",
                                                     nextKey = $p)))
             discard verifyAttempts(@xs))
  restUnit("chain: a terminal page followed by more pages is rejected",
           vfContract, "more pages follow",
           proc () = discard verifyAttempts(@[
             parseAttempt(3, attemptRaw(okBody(@[]))),
             parseAttempt(4, attemptRaw(okBody(@[]), page = 2))]))
  restUnit("chain: cont-yn=Y without next-key is rejected", vfContract,
           "without next-key",
           proc () = discard verifyAttempts(@[
             parseAttempt(3, attemptRaw(okBody(@[]), contYn = "Y")),
             parseAttempt(4, attemptRaw(okBody(@[]), page = 2))]))

# ---------------------------------------------------------------- stream level

let upPage1 = attemptRaw(
  okBody(@[row("005930", "삼성전자", "71500", "5.10")]),
  page = 1, contYn = "Y", nextKey = "000660")
let upPage2 = attemptRaw(
  okBody(@[row("000660", "SK하이닉스", "182200", "3.25")]), page = 2)
let okInfo = BuildInfo(codeCommit: "abc123", sourceRef: "main",
  originMainSha: "abc123", dirty: false, nimVersion: NimVersion,
  buildTime: "t")

block streamAcceptance:
  let successLines = withInserts(baseLines(), 6,
                                 @[(kRestResp, upPage1), (kRestResp, upPage2)])
  let res = runOf("ok", successLines)
  check("a verified success rest_resp stream replays OK",
        res.status == rsOk)
  check("verified pages are recorded on the result", res.restVerified == 2)
  check("acceptance changes no output byte",
        coreBytes(successLines) == coreBytes(baseLines()))

  let early = withInserts(baseLines(), 2,
                          @[(kRestResp, upPage1), (kRestResp, upPage2)])
  let resEarly = runOf("pos-ok", early)
  check("rest_resp right after the preamble is accepted when verified",
        resEarly.status == rsOk and resEarly.restVerified == 2)
  check("acceptance position changes no output byte",
        coreBytes(early) == coreBytes(baseLines()))

block streamIncomplete:
  let terminal = attemptRaw(
    okBody(@[row("005930", "삼성전자", "71500", "5.10")]), page = 1)
  let lines = withInserts(baseLines()[0 .. ^2], 5, @[(kRestResp, terminal)])
  let res = runOf("inc", lines)
  check("a verified success rest_resp without session_end is INCOMPLETE " &
        "(not REJECT)", res.status == rsIncomplete and res.restVerified == 1)
  let dir = writeStream("inc-run", lines)
  let inPath = dir / inputFile
  discard writeRun(dir / "run", inPath, runCore(loadRecords(inPath)), okInfo)
  let v = verifyRun(dir / "run", okInfo)
  check("verify reports INCOMPLETE exit 4 for it",
        v.verdict == vIncomplete and exitCode(v.verdict) == 4)

block streamRejections:
  let legacy = hObj(("body", hArr()), ("http_status", hInt(200)),
                    ("status", hStr("ok")))

  rejectRun("stream: schema violation is REJECT with the record named",
            "unknown rest_resp field",
            withInserts(baseLines(), 6, @[(kRestResp, legacy)]))
  rejectRun("stream: transport failure is REJECT", "HTTP status 503",
            withInserts(baseLines(), 6, @[(kRestResp,
              attemptRaw(okBody(@[]), status = 503))]))
  rejectRun("stream: vendor error is REJECT", "vendor return_code 5",
            withInserts(baseLines(), 6, @[(kRestResp,
              attemptRaw(vendorErrBody(5, "조회 거부")))]))
  rejectRun("stream: missing return_code is REJECT", "return_code is missing",
            withInserts(baseLines(), 6, @[(kRestResp,
              attemptRaw(rawBody(("return_msg", hStr("ok")))))]))
  rejectRun("stream: missing list key is REJECT",
            ka10027ListKey & " is missing",
            withInserts(baseLines(), 6, @[(kRestResp,
              attemptRaw(rawBody(("return_code", hInt(0)))))]))
  rejectRun("stream: page order violation is REJECT",
            "does not start at page 1",
            withInserts(baseLines(), 6, @[(kRestResp, upPage2)]))
  rejectRun("stream: a chain that ends while cont-yn=Y is REJECT",
            "continuation page is missing",
            withInserts(baseLines(), 6, @[(kRestResp,
              attemptRaw(okBody(@[]), contYn = "Y", nextKey = "k"))]))

  var msg = ""
  try:
    discard runOf("msg", withInserts(baseLines(), 6, @[(kRestResp, legacy)]))
  except RecordError as e:
    msg = e.msg
  check("rejection names the record and its seq",
        msg.startsWith("rest_resp at seq 7 is rejected"))
  check("rejection states the unverified wire boundary",
        "unverified" in msg)

block streamVerdict:
  let badLines = withInserts(baseLines(), 6, @[(kRestResp,
    attemptRaw(vendorErrBody(5, "조회 거부")))])
  let bv = verifyRun(writeStream("verdict-bad", badLines))
  check("verify classifies a failing rest_resp stream as REJECT exit 2",
        bv.verdict == vContract and exitCode(bv.verdict) == 2 and
        not bv.matched)
  check("verify prints VERDICT REJECT contract",
        verdictLine(bv) == "VERDICT REJECT contract")
  check("verify surfaces the rest_resp reason as an issue",
        bv.issues.len == 1 and "rest_resp" in bv.issues[0])

  let goodLines = withInserts(baseLines(), 6,
                              @[(kRestResp, upPage1), (kRestResp, upPage2)])
  let goodDir = writeStream("verdict-good", goodLines)
  let inPath = goodDir / inputFile
  discard writeRun(goodDir / "run", inPath, runCore(loadRecords(inPath)),
                   okInfo)
  let g = verifyRun(goodDir / "run", okInfo)
  check("a verified success rest_resp stream is MATCH provenance=OK",
        g.verdict == vMatch and g.matched and
        verdictLine(g) == "VERDICT MATCH provenance=OK")

echo ""
echo passes, " passed, ", failures, " failed"
if failures > 0: quit(1)
