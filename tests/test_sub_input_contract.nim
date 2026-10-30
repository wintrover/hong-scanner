## sub / ws_raw validated acceptance path contract tests (REPLAY_CONTRACT
## §12.5, VS-2 target; the sub_input.nim module-internal schemas), the
## official single-type REG composition contract (one {item, type} entry
## per REG; 0s registered by its own REG and never mixed into a candidate
## request; REMOVE names the outgoing 0B generation; the ack-based
## activeSets bookkeeping), and the environment + commit-marker verify
## rules (sealed + VALID marker = completion, sealed alone = INCOMPLETE,
## marker mismatch = REJECT, torn tail = INCOMPLETE — synthetic streams
## unchanged).
##
## Synthetic only: no network, no vendor data, no wall clock.
## Run: nim c -r --hints:off --warnings:off --path:src tests/test_sub_input_contract.nim
import std/[os, strutils, tempfiles]
import hs/[hcj, digest, records, replay, verify, sub_input, vendor_input,
           recorder, binfo]

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

proc subUnit(name: string; failure: VendorFailure; needle: string;
             body: proc ()) =
  ## parseSub/parseWsRaw/compose must raise SubInputError of the exact
  ## failure class with a self-explaining message.
  var raised = false
  var msg = ""
  try:
    body()
  except SubInputError as e:
    raised = e.failure == failure
    msg = if raised: e.msg else: "wrong class " & $e.failure & ": " & e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name, raised and needle in msg)

proc recordErrorUnit(name: string; needle: string; body: proc ()) =
  var raised = false
  var msg = ""
  try:
    body()
  except RecordError as e:
    raised = true
    msg = e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name, raised and needle in msg)

# ---------------------------------------------------------------- builders

const ts = "2026-10-29T09:00:00+09:00"

proc day(o, c: string): HcjValue =
  hObj(("close", hStr(c)), ("open", hStr(o)))

proc calRaw(): HcjValue =
  hObj(("days", hObj(
    ("2026-10-29", day("09:00:00+09:00", "15:30:00+09:00")))))

proc cfgRaw(environment = ""): HcjValue =
  if environment.len == 0:
    hObj(("session_date", hStr("2026-10-29")))
  else:
    hObj(("environment", hStr(environment)),
         ("session_date", hStr("2026-10-29")))

proc tickRaw(sym, t: string; price, vol: int64): HcjValue =
  hObj(("m", hStr("2")), ("price", hInt(price)), ("symbol", hStr(sym)),
       ("t", hStr(t)), ("vol", hInt(vol)))

proc baseLines(environment = ""): seq[string] =
  ## Minimal valid session: two symbols, two bars each, normal close.
  result = @[
    makeRecordLine(1, kCalendar, calRaw()),
    makeRecordLine(2, kConfig, cfgRaw(environment)),
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

proc writeStream(name: string; lines: seq[string]): string =
  ## dir/input.hcj.jsonl with LF discipline; returns the run dir.
  result = createTempDir("hs-subin-" & name & "-", "")
  var content = ""
  for l in lines: content.add(l & "\n")
  writeFile(result / inputFile, content)

proc runOf(name: string; lines: seq[string]): CoreResult =
  runCore(loadRecords(writeStream(name, lines) / inputFile))

proc coreBytes(lines: seq[string]): string =
  let res = runCore(loadRecords(writeStream("core", lines) / inputFile))
  for b in res.bars: result.add(barLine(b) & "\n")
  result.add("--\n")
  for s in res.signals: result.add(signalLine(s) & "\n")

proc dropKey(v: HcjValue; key: string) =
  var keep: seq[HcjPair]
  for p in v.pairs:
    if p.k != key: keep.add(p)
  v.pairs = keep

proc setType(v: HcjValue; key: string; val: HcjValue) =
  for p in v.pairs.mitems:
    if p.k == key: p.v = val

proc strSeq(xs: seq[string]): HcjValue =
  var items: seq[HcjValue]
  for x in xs: items.add(hStr(x))
  hArrSeq(items)

proc regReq(gen = 1; types: seq[string] = @["0B"];
            codes: seq[string] = @["005930"]; refresh = "0"): HcjValue =
  hObj(("action", hStr("reg")), ("codes", strSeq(codes)), ("gen", hInt(gen)),
       ("phase", hStr("req")), ("refresh", hStr(refresh)), ("t", hStr(ts)),
       ("types", strSeq(types)))

proc removeReq(gen = 1; types: seq[string] = @["0B"];
               codes: seq[string] = @["005930"]): HcjValue =
  hObj(("action", hStr("remove")), ("codes", strSeq(codes)), ("gen", hInt(gen)),
       ("phase", hStr("req")), ("t", hStr(ts)), ("types", strSeq(types)))

proc ackRaw(gen = 1; action = "reg"; code = 0; msg = ""): HcjValue =
  if msg.len > 0:
    hObj(("action", hStr(action)), ("gen", hInt(gen)),
         ("phase", hStr("ack")), ("return_code", hInt(code)),
         ("return_msg", hStr(msg)), ("t", hStr(ts)))
  else:
    hObj(("action", hStr(action)), ("gen", hInt(gen)),
         ("phase", hStr("ack")), ("return_code", hInt(code)),
         ("t", hStr(ts)))

proc wsRawRaw(channel = "0B"; conn = 1; t: string = ts;
              payloadHex = "deadbeef"): HcjValue =
  hObj(("channel", hStr(channel)), ("conn", hInt(conn)), ("payload_hex",
       hStr(payloadHex)), ("t", hStr(t)))

proc hexOf(s: string): string =
  const digits = "0123456789abcdef"
  for c in s:
    result.add(digits[int(ord(c)) shr 4])
    result.add(digits[int(ord(c)) and 0x0f])

proc tick0BPayload(item = "005930"): string =
  ## One well-formed 0B REAL payload in the official example shape (README
  ## §9): the FID set the single parser actually consumes.
  "{\"trnm\":\"REAL\",\"data\":[{\"item\":\"" & item & "\",\"name\":\"" &
    "주식체결\",\"type\":\"0B\",\"values\":{\"10\":\"10000\",\"13\":\"100\"," &
    "\"15\":\"+1\",\"20\":\"090500\",\"25\":\"2\",\"290\":\"2\"}}]}"

proc state0SPayload(value215 = "4"): string =
  ## One well-formed 0s REAL payload (README §9 shape) carrying the market
  ## state FID 215 — "4" is the close value the termination evidence
  ## requires.
  "{\"trnm\":\"REAL\",\"data\":[{\"item\":\"\",\"name\":\"장시작시간\"," &
    "\"type\":\"0s\",\"values\":{\"20\":\"153000\",\"215\":\"" & value215 &
    "\",\"214\":\"000000\"}}]}"

# ------------------------------------------------------------- format rules

block formatRules:
  check("iso: full valid timestamp accepted",
        validIso8601Offset("2026-10-29T09:00:00+09:00"))
  check("iso: negative offset accepted",
        validIso8601Offset("2026-10-29T23:59:59-05:00"))
  for good in ["2026-01-01T00:00:00+00:00", "2024-02-29T12:00:00+09:00"]:
    check("iso: valid " & good, validIso8601Offset(good))
  for bad in ["", "2026-10-29T09:00:00+09:0", "2026-10-29T09:00:00Z",
              "2026-10-29 09:00:00+09:00", "2026-10-29T09:00:00",
              "26-10-29T09:00:00+09:00", "2026-13-29T09:00:00+09:00",
              "2026-00-29T09:00:00+09:00", "2026-10-00T09:00:00+09:00",
              "2026-10-32T09:00:00+09:00", "2026-10-29T24:00:00+09:00",
              "2026-10-29T09:60:00+09:00", "2026-10-29T09:00:60+09:00",
              "2026-10-29T09:00:00+24:00", "2026-10-29T09:00:00+09:60",
              "2026-10-29T09:00:00 09:00", "2026-10-29T09:00:00+0a:00",
              "2026-10-29T09:00:00+09:00 "]:
    check("iso: malformed rejected " & (if bad.len == 0: "(empty)" else: bad),
          not validIso8601Offset(bad))
  check("type: 1-char channel type valid", validChannelType("s"))
  check("type: 4-char channel type valid", validChannelType("0ABz"))
  for bad in ["", "0ABz9", "0B_0", "0B-1", "0 B", "한글", "0B."]:
    check("type: invalid channel type " &
          (if bad.len == 0: "(empty)" else: bad), not validChannelType(bad))
  check("code: 6 digits valid", validCode("005930"))
  for bad in ["", "00593", "0059300", "00593a", "005930 ", "593O30"]:
    check("code: invalid code " & (if bad.len == 0: "(empty)" else: bad),
          not validCode(bad))

# ------------------------------------------------------------- hex encoding

block hexContract:
  check("hex: empty encodes to empty",
        payloadHexOfBytes(@[]).len == 0 and payloadFromHex(0, "").len == 0)
  let bin: seq[byte] = @[0x00'u8, 0x0a'u8, 0x22'u8, 0x7f'u8, 0x80'u8,
                         0xfe'u8, 0xff'u8]
  check("hex: arbitrary bytes round-trip byte-exact",
        payloadFromHex(0, payloadHexOfBytes(bin)) == bin)
  check("hex: known vector",
        payloadHexOfBytes(@[0xde'u8, 0xad'u8, 0xbe'u8, 0xef'u8]) == "deadbeef")
  subUnit("hex: odd length is rejected", vfContract, "odd length",
          proc () = discard payloadFromHex(3, "abc"))
  subUnit("hex: uppercase hex is rejected", vfContract, "lowercase",
          proc () = discard payloadFromHex(3, "DEADBEEF"))
  subUnit("hex: non-hex digit is rejected", vfContract, "lowercase",
          proc () = discard payloadFromHex(3, "0g"))

# ------------------------------------------------------------ sub success

block subSchemaSuccess:
  let a = parseSub(4, regReq())
  check("parse surfaces gen/action/phase/t",
        a.gen == 1 and a.action == saReg and a.phase == spReq and a.t == ts)
  check("parse surfaces the declared types, codes and refresh",
        a.types == @["0B"] and a.codes == @["005930"] and a.refresh == "0")
  check("the channel-only 0s registration with empty codes is valid",
        parseSub(3, regReq(types = @["0s"], codes = @[],
                           refresh = "1")).codes.len == 0)
  check("a 4-char type and several types parse",
        parseSub(3, regReq(types = @["0B", "0s", "9ABz"],
                           codes = @["005930", "000660"])).types.len == 3)
  let rm = parseSub(5, removeReq(types = @["0B"],
                                 codes = @["005930", "000660"]))
  check("a (remove,req) with explicit targets parses",
        rm.action == saRemove and rm.codes == @["005930", "000660"] and
        rm.refresh == "")
  let ack = parseSub(6, ackRaw())
  check("a (reg,ack) with return_code 0 parses",
        ack.phase == spAck and ack.returnCode == 0 and ack.returnMsg == "")
  check("an ack with return_msg parses",
        parseSub(6, ackRaw(msg = "정상처리")).returnMsg == "정상처리")
  check("a (remove,ack) parses",
        parseSub(7, ackRaw(action = "remove", code = 1)).action == saRemove)
  check("a large monotonic gen parses",
        parseSub(8, regReq(gen = 9007199254740991'i64)).gen ==
        9007199254740991'i64)

# ------------------------------------------------------------ sub failures

block subSchemaFailures:
  subUnit("sub: null raw is rejected", vfContract, "not an object",
          proc () = discard parseSub(3, hNull()))
  subUnit("sub: string raw is rejected", vfContract, "not an object",
          proc () = discard parseSub(3, hStr("reg")))
  subUnit("sub: array raw is rejected", vfContract, "not an object",
          proc () = discard parseSub(3, hArr(hInt(1))))
  subUnit("sub: unknown field is rejected", vfContract,
          "unknown sub field: trnm",
          proc () =
            let r = regReq()
            r.pairs.add(("trnm", hStr("REG")))
            discard parseSub(3, r))
  for k in ["gen", "action", "phase", "t"]:
    subUnit("sub: missing " & k & " is rejected", vfContract,
            "missing sub field: " & k,
            proc () =
              let r = regReq()
              dropKey(r, k)
              discard parseSub(3, r))
  subUnit("sub: gen 0 is rejected", vfContract, "must be >= 1",
          proc () = discard parseSub(3, regReq(gen = 0)))
  subUnit("sub: negative gen is rejected", vfContract, "must be >= 1",
          proc () = discard parseSub(3, regReq(gen = -1)))
  subUnit("sub: gen must be an integer", vfContract, "not an integer",
          proc () =
            let r = regReq()
            setType(r, "gen", hStr("1"))
            discard parseSub(3, r))
  subUnit("sub: action outside the enum is rejected", vfContract,
          "action is not reg|remove",
          proc () =
            let r = regReq()
            setType(r, "action", hStr("add"))
            discard parseSub(3, r))
  subUnit("sub: phase outside the enum is rejected", vfContract,
          "phase is not req|ack",
          proc () =
            let r = regReq()
            setType(r, "phase", hStr("commit"))
            discard parseSub(3, r))
  for bad in ["2026-10-29T09:00:00", "2026-10-29T09:00:00Z",
              "2026-10-29 09:00:00+09:00", "2026-13-29T09:00:00+09:00",
              "not a timestamp"]:
    subUnit("sub: malformed t is rejected: " & bad, vfContract,
            "not an ISO 8601",
            proc () =
              let r = regReq()
              setType(r, "t", hStr(bad))
              discard parseSub(3, r))
  subUnit("sub: t must be a string", vfContract, "is not a string",
          proc () =
            let r = regReq()
            setType(r, "t", hInt(0))
            discard parseSub(3, r))
  # (reg,req) combination failures
  for k in ["types", "codes", "refresh"]:
    subUnit("sub: (reg,req) missing " & k & " is rejected", vfContract,
            "missing sub field: " & k,
            proc () =
              let r = regReq()
              dropKey(r, k)
              discard parseSub(3, r))
  subUnit("sub: (reg,req) empty types is rejected", vfContract,
          "types must not be empty",
          proc () = discard parseSub(3, regReq(types = @[])))
  subUnit("sub: types element longer than 4 chars is rejected", vfContract,
          "not 1..4 chars",
          proc () = discard parseSub(3, regReq(types = @["0BABC"])))
  subUnit("sub: types element outside [0-9A-Za-z] is rejected", vfContract,
          "not 1..4 chars",
          proc () = discard parseSub(3, regReq(types = @["0B_"])))
  subUnit("sub: types element must be a string", vfContract,
          "element is not a string",
          proc () =
            let r = regReq()
            setType(r, "types", hArr(hInt(1)))
            discard parseSub(3, r))
  subUnit("sub: types must be an array", vfContract, "is not an array",
          proc () =
            let r = regReq()
            setType(r, "types", hStr("0B"))
            discard parseSub(3, r))
  for bad in ["00593", "0059300", "00593a"]:
    subUnit("sub: codes element " & bad & " is rejected", vfContract,
            "not a 6-digit code",
            proc () = discard parseSub(3, regReq(codes = @[bad])))
  subUnit("sub: codes must be an array", vfContract, "is not an array",
          proc () =
            let r = regReq()
            setType(r, "codes", hStr("005930"))
            discard parseSub(3, r))
  subUnit("sub: refresh outside 0|1 is rejected", vfContract,
          "refresh is not 0|1",
          proc () = discard parseSub(3, regReq(refresh = "2")))
  subUnit("sub: refresh must be a string", vfContract, "is not a string",
          proc () =
            let r = regReq()
            setType(r, "refresh", hInt(0))
            discard parseSub(3, r))
  # (remove,req) combination failures
  subUnit("sub: (remove,req) empty codes is rejected", vfContract,
          "must not be empty in a (remove,req)",
          proc () = discard parseSub(3, removeReq(codes = @[])))
  subUnit("sub: (remove,req) missing codes is rejected", vfContract,
          "missing sub field: codes",
          proc () =
            let r = removeReq()
            dropKey(r, "codes")
            discard parseSub(3, r))
  subUnit("sub: (remove,req) carries no refresh", vfContract,
          "refresh is not allowed in a (remove,req)",
          proc () =
            let r = removeReq()
            r.pairs.add(("refresh", hStr("1")))
            discard parseSub(3, r))
  # ack combination failures
  subUnit("sub: ack without return_code is rejected", vfContract,
          "missing sub field: return_code",
          proc () =
            let r = ackRaw()
            dropKey(r, "return_code")
            discard parseSub(3, r))
  for k in ["types", "codes", "refresh"]:
    subUnit("sub: ack carries no " & k, vfContract,
            k & " is not allowed in an ack record",
            proc () =
              let r = ackRaw()
              r.pairs.add((k, if k == "refresh": hStr("1") else:
                (if k == "codes": hArr(hStr("005930")) else:
                  hArr(hStr("0B")))))
              discard parseSub(3, r))
  subUnit("sub: (req) carries no return_code", vfContract,
          "return_code is not allowed in a (reg,req)",
          proc () =
            let r = regReq()
            r.pairs.add(("return_code", hInt(0)))
            discard parseSub(3, r))
  subUnit("sub: (req) carries no return_msg", vfContract,
          "return_msg is not allowed in a (reg,req)",
          proc () =
            let r = regReq()
            r.pairs.add(("return_msg", hStr("ok")))
            discard parseSub(3, r))
  subUnit("sub: return_code must be an integer", vfContract,
          "not an integer",
          proc () =
            let r = ackRaw()
            setType(r, "return_code", hStr("0"))
            discard parseSub(3, r))
  subUnit("sub: return_msg must be a string", vfContract, "is not a string",
          proc () =
            let r = ackRaw(msg = "ok")
            setType(r, "return_msg", hInt(1))
            discard parseSub(3, r))

# ---------------------------------------------------------- ws_raw schema

block wsRawSchema:
  let w = parseWsRaw(5, wsRawRaw())
  check("parse surfaces channel/conn/t and the decoded payload",
        w.channel == "0B" and w.conn == 1 and w.t == ts and
        w.payload == @[0xde'u8, 0xad'u8, 0xbe'u8, 0xef'u8])
  check("an empty payload (empty hex) is a valid ws_raw record",
        parseWsRaw(5, wsRawRaw(payloadHex = "")).payload.len == 0)

block wsRawFailures:
  subUnit("ws_raw: null raw is rejected", vfContract, "not an object",
          proc () = discard parseWsRaw(3, hNull()))
  subUnit("ws_raw: unknown field is rejected", vfContract,
          "unknown ws_raw field: frame",
          proc () =
            let r = wsRawRaw()
            r.pairs.add(("frame", hStr("text")))
            discard parseWsRaw(3, r))
  for k in ["channel", "conn", "payload_hex", "t"]:
    subUnit("ws_raw: missing " & k & " is rejected", vfContract,
            "missing ws_raw field: " & k,
            proc () =
              let r = wsRawRaw()
              dropKey(r, k)
              discard parseWsRaw(3, r))
  subUnit("ws_raw: empty channel is rejected", vfContract,
          "channel must not be empty",
          proc () = discard parseWsRaw(3, wsRawRaw(channel = "")))
  subUnit("ws_raw: conn 0 is rejected", vfContract, "conn must be >= 1",
          proc () = discard parseWsRaw(3, wsRawRaw(conn = 0)))
  subUnit("ws_raw: conn must be an integer", vfContract, "not an integer",
          proc () =
            let r = wsRawRaw()
            setType(r, "conn", hStr("1"))
            discard parseWsRaw(3, r))
  subUnit("ws_raw: malformed t is rejected", vfContract, "not an ISO 8601",
          proc () = discard parseWsRaw(3, wsRawRaw(t = "09:00:00+09:00")))
  subUnit("ws_raw: payload_hex must be a string", vfContract,
          "is not a string",
          proc () =
            let r = wsRawRaw()
            setType(r, "payload_hex", hInt(0))
            discard parseWsRaw(3, r))
  subUnit("ws_raw: odd-length payload_hex is rejected", vfContract,
          "odd length",
          proc () = discard parseWsRaw(3, wsRawRaw(payloadHex = "abc")))
  subUnit("ws_raw: uppercase payload_hex is rejected", vfContract,
          "lowercase",
          proc () = discard parseWsRaw(3, wsRawRaw(payloadHex = "DEAD")))
  subUnit("ws_raw: non-hex payload_hex is rejected", vfContract,
          "lowercase",
          proc () = discard parseWsRaw(3, wsRawRaw(payloadHex = "zz")))

# ------------------------------------------------------- registration sets

proc itemsOf(up, down: seq[string]): seq[SubRegItem] = composeRegData(up, down)

proc hasType(items: seq[SubRegItem]; typ: string): bool =
  for it in items:
    if it.typ == typ: return true
  false

proc recordFromItems(gen: int; refresh: string;
                     items: seq[SubRegItem]): HcjValue =
  ## Flatten a composed set into a (reg,req) record: types in item order,
  ## codes concatenated in item order (the recorded wire view). For a
  ## single-type set the flatten is the identity.
  var types: seq[string]
  var codes: seq[string]
  for it in items:
    types.add(it.typ)
    for c in it.codes: codes.add(c)
  regReq(gen = gen, types = types, codes = codes, refresh = refresh)

proc parsed(seqNo: int; raw: HcjValue): SubRecord = parseSub(seqNo, raw)

block composeFiveStep:
  ## The subscription lifecycle regression (REPLAY_CONTRACT §12.6):
  ## ① 0s registered by its own REG (channel-only, refresh "1"),
  ## ② 0B generation 1 REG (refresh "1"), ③ the swap — REMOVE(outgoing
  ## generation) req+ack, then REG(incoming generation) req+ack with
  ## refresh "1", ④ the 0s registration state is untouched by the swap,
  ## ⑤ the end-of-session teardown REMOVEs 0B only; 0s has no REMOVE
  ## record (its removal form is undocumented) and stays registered as
  ## the close evidence.
  let up1 = @["005930", "000660"]
  let down1 = @["999999"]
  let up2 = @["005930", "000660", "111111"]
  let down2 = @["999999", "222222"]

  # ① the market-state channel is registered by its own REG
  let sReg = composeMarketStateReg()
  check("step 1: the 0s REG is exactly one channel-only entry",
        sReg.len == 1 and sReg[0].typ == "0s" and sReg[0].codes.len == 0)
  let sRec = parseSub(3, recordFromItems(1, "1", sReg))
  check("step 1: the 0s REG round-trips as a channel-only (reg,req)",
        sRec.types == @["0s"] and sRec.codes.len == 0 and
        sRec.refresh == "1")

  # ② the generation-1 candidate REG: single-type, official form
  let g1 = itemsOf(up1, down1)
  check("step 2: the 0B REG is exactly one single-type entry",
        g1.len == 1 and g1[0].typ == "0B" and g1[0].codes == up1 & down1)
  check("step 2: the composition cannot mix a market-state item into a " &
        "candidate REG (0s never appears in a replacement request)",
        not hasType(g1, "0s"))
  let g1Rec = parseSub(4, recordFromItems(2, "1", g1))
  check("step 2: the 0B REG round-trips with refresh 1",
        g1Rec.types == @["0B"] and g1Rec.codes == up1 & down1 and
        g1Rec.refresh == "1")

  # ③ the swap: REMOVE(outgoing) → ack → REG(incoming, refresh 1) → ack
  let removeOut = composeRemoveData(up1 & down1)
  check("step 3: the swap removal names the full outgoing generation",
        removeOut.len == 1 and removeOut[0].typ == "0B" and
        removeOut[0].codes == up1 & down1)
  let g2 = itemsOf(up2, down2)
  check("step 3: the incoming generation REG keeps the single-type form",
        g2.len == 1 and g2[0].typ == "0B" and g2[0].codes == up2 & down2)
  let g2Rec = parseSub(5, recordFromItems(4, "1", g2))
  check("step 3: the incoming REG is recorded with refresh 1 (refresh 0 " &
        "is never sent)", g2Rec.refresh == "1")

  # ④ the active-set view over the whole lifecycle: 0s unaffected
  let lifecycle: seq[SubRecord] = @[
    parsed(3, recordFromItems(1, "1", sReg)),            # ① 0s REG req
    parsed(4, ackRaw(gen = 1)),                          # ① 0s REG ack 0
    parsed(5, recordFromItems(2, "1", g1)),              # ② 0B gen1 REG req
    parsed(6, ackRaw(gen = 2)),                          # ② 0B REG ack 0
    parsed(7, removeReq(gen = 3, codes = up1 & down1)),  # ③ REMOVE(outgoing)
    parsed(8, ackRaw(gen = 3, action = "remove")),       # ③ REMOVE ack 0
    parsed(9, recordFromItems(4, "1", g2)),              # ③ REG(incoming)
    parsed(10, ackRaw(gen = 4)),                         # ③ REG ack 0
    parsed(11, removeReq(gen = 5, codes = up2 & down2)), # ⑤ teardown REMOVE
    parsed(12, ackRaw(gen = 5, action = "remove"))]      # ⑤ REMOVE ack 0

  let afterGen1 = activeSets(lifecycle[0 .. 3])
  check("step 4a: after generation 1, both types are active with sorted " &
        "codes",
        afterGen1.len == 2 and afterGen1[0].typ == "0B" and
        afterGen1[0].codes == @["000660", "005930", "999999"] and
        afterGen1[1].typ == "0s" and afterGen1[1].codes.len == 0)
  let midSwap = activeSets(lifecycle[0 .. 5])
  check("step 4b: after the removal ack the outgoing codes are gone but " &
        "the type stays listed",
        midSwap.len == 2 and midSwap[0].typ == "0B" and
        midSwap[0].codes.len == 0 and midSwap[1].typ == "0s")
  let afterSwap = activeSets(lifecycle[0 .. 7])
  check("step 4c: after the swap the 0B set is the incoming generation",
        afterSwap.len == 2 and afterSwap[0].typ == "0B" and
        afterSwap[0].codes ==
        @["000660", "005930", "111111", "222222", "999999"])
  check("step 4d: the 0s registration state is identical before and " &
        "after the swap (the swap never touches the market-state " &
        "channel)", afterGen1[1] == afterSwap[1])

  # ⑤ the end-of-session teardown removes 0B only; 0s is kept
  let teardown = composeRemoveData(up2 & down2)
  check("step 5: the teardown set is exactly one 0B item naming the " &
        "active generation",
        teardown.len == 1 and teardown[0].typ == "0B" and
        teardown[0].codes == up2 & down2)
  check("step 5: the teardown set never names 0s",
        not hasType(teardown, "0s"))
  check("step 5: the teardown set round-trips through (remove,req)",
        parseSub(6, removeReq(gen = 5, types = @["0B"],
                              codes = teardown[0].codes)).codes ==
        up2 & down2)
  let atEnd = activeSets(lifecycle)
  check("step 5: after the teardown the 0B codes are gone and the 0s " &
        "registration is kept (no REMOVE record for 0s)",
        atEnd.len == 2 and atEnd[0].typ == "0B" and
        atEnd[0].codes.len == 0 and atEnd[1].typ == "0s" and
        atEnd[1] == afterSwap[1])

block activeSetsRules:
  ## The ack-based bookkeeping rules: requests never change state,
  ## refused acks never change state, unmatched records are no-ops,
  ## refresh=0 is underivable, output is deterministic.
  check("a request without its ack activates nothing",
        activeSets(@[parsed(3, recordFromItems(2, "1",
          composeRegData(@["005930"], @[])))]).len == 0)
  let refused = activeSets(@[
    parsed(3, recordFromItems(2, "1", composeRegData(@["005930"], @[]))),
    parsed(4, ackRaw(gen = 2, code = 1)),
    parsed(5, ackRaw(gen = 2))])
  check("a refused ack consumes its request and changes no state; a " &
        "later ack of the same gen is unmatched",
        refused.len == 0)
  check("an unmatched ack is a no-op",
        activeSets(@[parsed(3, ackRaw(gen = 9))]).len == 0)
  var raised = false
  var seqSeen = 0
  try:
    discard activeSets(@[parsed(3, regReq(gen = 2))])  # default refresh "0"
  except SubInputError as e:
    raised = e.failure == vfContract and "underivable" in e.msg
    seqSeen = e.seqNo
  check("a refresh=0 request makes the active set underivable, named at " &
        "its own seq", raised and seqSeen == 3)
  let fifo = activeSets(@[
    parsed(3, regReq(gen = 7, codes = @["005930"], refresh = "1")),
    parsed(4, regReq(gen = 7, codes = @["000660"], refresh = "1")),
    parsed(5, ackRaw(gen = 7)),
    parsed(6, ackRaw(gen = 7))])
  check("matching acks consume requests oldest-first and dedupe codes",
        fifo.len == 1 and fifo[0].typ == "0B" and
        fifo[0].codes == @["000660", "005930"])
  let twice = activeSets(@[
    parsed(3, recordFromItems(2, "1", composeRegData(@["005930"], @[]))),
    parsed(4, ackRaw(gen = 2)),
    parsed(5, recordFromItems(3, "1", composeRegData(@["005930"], @[]))),
    parsed(6, ackRaw(gen = 3))])
  check("re-acknowledged codes do not duplicate",
        twice.len == 1 and twice[0].codes == @["005930"])
  check("the bookkeeping is deterministic: same input, same output",
        activeSets(@[parsed(3, recordFromItems(2, "1",
          composeRegData(@["000660", "005930"], @["999999"]))),
          parsed(4, ackRaw(gen = 2))]) ==
        activeSets(@[parsed(3, recordFromItems(2, "1",
          composeRegData(@["000660", "005930"], @["999999"]))),
          parsed(4, ackRaw(gen = 2))]))

block composeFailures:
  subUnit("compose: 101 up codes exceed the direction cap", vfContract,
          "up direction exceeds the subscription cap",
          proc () =
            var xs: seq[string]
            for i in 1 .. 101: xs.add($(100000 + i))
            discard composeRegData(xs, @[]))
  subUnit("compose: 101 down codes exceed the direction cap", vfContract,
          "down direction exceeds the subscription cap",
          proc () =
            var xs: seq[string]
            for i in 1 .. 101: xs.add($(300000 + i))
            discard composeRegData(@[], xs))
  # The direction caps (101 fires above) mathematically imply the 200-code
  # per-session total inside composeRegData — 100+100 is the reachable
  # boundary, checked below. composeRemoveData has no direction split, so
  # the 200 total is directly enforced (and tested) there.
  subUnit("compose: a code outside the 6-digit shape is rejected", vfContract,
          "not a 6-digit code",
          proc () = discard composeRegData(@["5930"], @[]))
  subUnit("compose: a duplicate candidate is rejected", vfContract,
          "duplicate code",
          proc () = discard composeRegData(@["005930"], @["005930"]))
  subUnit("compose: an empty removal is rejected", vfContract,
          "removal set must not be empty",
          proc () = discard composeRemoveData(@[]))
  subUnit("compose: removal over the cap is rejected", vfContract,
          "exceeds the per-session cap",
          proc () =
            var xs: seq[string]
            for i in 1 .. 201: xs.add($(400000 + i))
            discard composeRemoveData(xs))
  subUnit("compose: a duplicate removal target is rejected", vfContract,
          "duplicate code",
          proc () = discard composeRemoveData(@["005930", "005930"]))
  check("compose: 100+100 is inside the caps and stays single-type",
        block:
          var ups: seq[string]
          for i in 1 .. 100: ups.add($(100000 + i))
          var downs: seq[string]
          for i in 1 .. 100: downs.add($(300000 + i))
          let items = composeRegData(ups, downs)
          items.len == 1 and items[0].typ == "0B" and
          items[0].codes == ups & downs)

# ------------------------------------------------------- config environment

block configEnvironment:
  check("config: demo is accepted",
        parseConfig(cfgRaw("demo")).environment == "demo")
  check("config: prod is accepted",
        parseConfig(cfgRaw("prod")).environment == "prod")
  check("config: absent environment stays valid and undeclared",
        parseConfig(cfgRaw()).environment == "")
  recordErrorUnit("config: another value is a contract failure",
                  "not demo|prod: staging",
                  proc () = discard parseConfig(cfgRaw("staging")))
  recordErrorUnit("config: a non-string environment is a contract failure",
                  "not a string",
                  proc () =
                    let r = cfgRaw()
                    r.pairs.add(("environment", hInt(1)))
                    discard parseConfig(r))

# ------------------------------------------------------------- stream level

block streamLevel:
  # The ws_raw payload is a well-formed 0B REAL tick in the official
  # example shape; its REQ has no ack yet, so the consumption check
  # quarantines the tick (stale connection generation) instead of
  # consuming it into a bar.
  let subInserts: seq[(Kind, HcjValue)] = @[
    (kSub, regReq(gen = 1, types = @["0s"], codes = @[], refresh = "1")),
    (kSub, regReq(gen = 2, types = @["0B"], codes = @["005930", "000660"],
                  refresh = "1")),
    (kWsRaw, wsRawRaw(payloadHex = hexOf(tick0BPayload())))]
  let lines = withInserts(baseLines(), 6, subInserts)
  let res = runOf("ok", lines)
  check("a stream with valid sub/ws_raw records replays OK",
        res.status == rsOk)
  check("the subscription records are counted on the result",
        res.subCount == 2 and res.wsRawCount == 1)
  check("the unacked 0B tick is quarantined, not consumed",
        res.quarantined == 1 and
        res.quarantineNotes[0].startsWith("stale_conn") and
        res.bars.len == 4)
  check("sub/ws_raw acceptance changes no output byte",
        coreBytes(lines) == coreBytes(baseLines()))
  check("an ack-only stream also replays OK",
        runOf("acks", withInserts(baseLines(), 6,
          @[(kSub, ackRaw(gen = 3))])).subCount == 1)

  recordErrorUnit("stream: a schema-violating sub is REJECT with the " &
                  "record named", "unknown sub field",
                  proc () =
                    let bad = regReq()
                    bad.pairs.add(("trnm", hStr("REG")))
                    discard runOf("bad", withInserts(baseLines(), 6,
                      @[(kSub, bad)])))
  recordErrorUnit("stream: a schema-violating ws_raw is REJECT with the " &
                  "record named", "unknown ws_raw field",
                  proc () =
                    let bad = wsRawRaw()
                    bad.pairs.add(("frame", hStr("text")))
                    discard runOf("badws", withInserts(baseLines(), 6,
                      @[(kWsRaw, bad)])))
  recordErrorUnit("stream: a garbage 0B ws_raw payload is REJECT at its " &
                  "own seq", "is rejected",
                  proc () =
                    discard runOf("garbage", withInserts(baseLines(), 6,
                      @[(kWsRaw, wsRawRaw(
                          payloadHex = hexOf("totally not json")))])))
  recordErrorUnit("stream: a mislabeled 0B channel is REJECT with the " &
                  "record named", "does not match",
                  proc () =
                    discard runOf("mislabeled", withInserts(baseLines(), 6,
                      @[(kWsRaw, wsRawRaw(channel = "0s",
                          payloadHex = hexOf(tick0BPayload())))])))
  var msg = ""
  try:
    let bad = regReq()
    bad.pairs.add(("trnm", hStr("REG")))
    discard runOf("msg", withInserts(baseLines(), 6, @[(kSub, bad)]))
  except RecordError as e:
    msg = e.msg
  check("the rejection names the record and its seq",
        msg.startsWith("sub at seq 7 is rejected"))
  check("the rejection states the unverified wire boundary",
        "unverified" in msg)
  check("kind names round-trip through parseKind",
        parseKind(kindName(kSub)) == kSub and
        parseKind(kindName(kWsRaw)) == kWsRaw and
        kindName(kSub) == "sub" and kindName(kWsRaw) == "ws_raw")

# --------------------------------------------- environment + commit marker

const commitMarkerSchema = "hong-scanner-commit/1"

let okInfo = BuildInfo(codeCommit: "abc123", sourceRef: "main",
  originMainSha: "abc123", dirty: false, nimVersion: NimVersion,
  buildTime: "t")

proc runDirOf(name: string; lines: seq[string]): string =
  ## A full run directory (writeRun artifacts) over the given stream.
  let dir = writeStream(name, lines)
  let inPath = dir / inputFile
  result = dir / "run"
  discard writeRun(result, inPath, runCore(loadRecords(inPath)), okInfo)

proc writeMarker(runDir: string; shaOverride = ""; seqOverride = 0) =
  ## Hand-build the COMMITTED marker for runDir's input artifact from its
  ## actual bytes (an external verifier's view); overrides let a test
  ## plant a mismatching field.
  let input = runDir / inputFile
  let sha = if shaOverride.len == 0: sha256Hex(readFile(input))
            else: shaOverride
  let n = if seqOverride == 0: loadRecords(input).len else: seqOverride
  let marker = hObj(("run_id", hStr(lastPathPart(parentDir(input)))),
                    ("schema", hStr(commitMarkerSchema)),
                    ("seq", hInt(n)),
                    ("sha256", hStr(sha)),
                    ("t", hStr(ts)))
  writeFile(input & ".committed", canonical(marker) & "\n")

block commitGateRules:
  # The fixtures below are honest sealed live streams: a stream that
  # declares an environment must carry the minimum close evidence (README
  # §10) — the 0s FID 215 close observation and the confirmed (remove,
  # ack 0) 0B teardown — or replay rejects it before verify runs.
  let envClose: seq[(Kind, HcjValue)] = @[
    (kWsRaw, wsRawRaw(channel = "0s", payloadHex = hexOf(state0SPayload()))),
    (kSub, removeReq(gen = 3, types = @["0B"],
                     codes = @["005930", "000660"])),
    (kSub, ackRaw(gen = 3, action = "remove", code = 0))]
  let envLines = withInserts(baseLines("demo"), 6, envClose)

  let absent = verifyRun(runDirOf("absent", envLines))
  check("environment + marker ABSENT verifies INCOMPLETE exit 4",
        absent.verdict == vIncomplete and exitCode(absent.verdict) == 4)
  check("ABSENT is reported as COMMIT=ABSENT",
        absent.commitState == "ABSENT")
  check("ABSENT explains the durability boundary",
        absent.issues.len == 1 and "commit marker absent" in absent.issues[0])

  let invalidRun = runDirOf("invalid", envLines)
  writeMarker(invalidRun, shaOverride = repeat('0', 64))
  let invalid = verifyRun(invalidRun)
  check("environment + mismatching marker verifies REJECT exit 2",
        invalid.verdict == vContract and exitCode(invalid.verdict) == 2)
  check("INVALID is reported as COMMIT=INVALID",
        invalid.commitState == "INVALID")
  check("INVALID explains the mismatch",
        "commit marker INVALID" in invalid.issues[0] and
        "does not match" in invalid.issues[0])

  let validRun = runDirOf("valid", envLines)
  writeMarker(validRun)
  let valid = verifyRun(validRun, okInfo)
  check("environment + VALID marker verifies MATCH provenance=OK",
        valid.verdict == vMatch and valid.matched and
        verdictLine(valid) == "VERDICT MATCH provenance=OK")
  check("VALID is reported as COMMIT=VALID", valid.commitState == "VALID")

  let unseqRun = runDirOf("seqwrong", envLines)
  writeMarker(unseqRun, seqOverride = 3)
  let unseq = verifyRun(unseqRun)
  check("a marker seq mismatch is REJECT exit 2",
        unseq.verdict == vContract and exitCode(unseq.verdict) == 2 and
        "seq does not match" in unseq.issues[0])

block syntheticUnchanged:
  let plain = baseLines()
  let noMarker = verifyRun(runDirOf("plain", plain), okInfo)
  check("a synthetic stream without environment verifies as before",
        noMarker.verdict == vMatch and noMarker.matched)
  check("its absent marker is reported but not enforced",
        noMarker.commitState == "ABSENT" and noMarker.issues.len == 0)

  let repRun = runDirOf("plain-rep", plain)
  writeMarker(repRun, shaOverride = repeat('f', 64))
  let rep = verifyRun(repRun, okInfo)
  check("a synthetic stream with a mismatching marker keeps its verdict",
        rep.verdict == vMatch and rep.matched)
  check("the mismatch is reported only",
        rep.commitState == "INVALID" and rep.issues.len == 1 and
        "reported only" in rep.issues[0])

block tornTailRules:
  let tornEnv = writeStream("torn-env", baseLines("demo"))
  writeFile(tornEnv / inputFile,
            readFile(tornEnv / inputFile) & "{")
  let envV = verifyRun(tornEnv)
  check("an environment stream with a torn tail verifies INCOMPLETE exit 4",
        envV.verdict == vIncomplete and exitCode(envV.verdict) == 4)
  check("the torn tail is named as the crashed-run classification",
        envV.issues.len == 2 and "torn tail" in envV.issues[1] and
        "INCOMPLETE" in envV.issues[1])

  let tornPlain = writeStream("torn-plain", baseLines())
  writeFile(tornPlain / inputFile,
            readFile(tornPlain / inputFile) & "{")
  let plainV = verifyRun(tornPlain)
  check("a synthetic stream with a torn tail keeps the line-discipline " &
        "REJECT", plainV.verdict == vContract and
        exitCode(plainV.verdict) == 2)

  let tornProd = writeStream("torn-prod", baseLines("prod"))
  writeFile(tornProd / inputFile,
            readFile(tornProd / inputFile) & "{")
  check("the torn-tail rule keys on any declared environment, not a " &
        "literal",
        verifyRun(tornProd).verdict == vIncomplete)

echo ""
echo passes, " passed, ", failures, " failed"
if failures > 0: quit(1)
