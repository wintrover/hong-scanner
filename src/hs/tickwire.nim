## tickwire: the single 0B/0s wire parser (docs/REPLAY_CONTRACT.md §12.3 —
## normalized ticks are derived from the preserved bytes by Nim, in one
## place, used by both the live collector core and replay).
##
## Wire shapes below are confirmed 2026-10-30 against the official spec JSON
## (Kiwoom-Securities/Kiwoom-REST-API, kiwoom/_data/kiwoom_api_spec.json,
## entries 주식체결(0B) and 장시작시간(0s); raw fetch, never committed):
##
##   0B real-time (response_example 원문):
##     {"trnm":"REAL","data":[{"type":"0B","name":"주식체결","item":"005930",
##       "values":{"20":"165208","10":"-20800","15":"+82","13":"30379732",
##                 "25":"5","290":"2", ...51 FIDs, all String}}]}
##   0s real-time (response_example 원문):
##     {"trnm":"REAL","data":[{"type":"0s","name":"장시작시간","item":"",
##       "values":{"215":"b","20":"170000","214":"000000"}}]}
##   REG/REMOVE/LOGIN ack: {"trnm":"REG","return_code":0,"return_msg":""}
##     — return_code: "등록,해지요청시에만 값 전송 0:정상,1:오류, 데이터
##     실시간 수신시 미전송" (spec 원문). An ack carries no request
##     identifier: pairing is by stream order per (gen, action), the
##     sub_input.activeSets rule.
##
## FID interpretation boundary (fail-closed):
##   - 20 체결시간 HHmmss (spec 원문) — combined with the session date.
##   - 10 현재가 "단위: 원, 부호가 포함된 숫자" (원문) — the sign's meaning
##     is UNVERIFIED, so the recorded signed integer is preserved and used
##     exactly as recorded; nothing adds or strips a sign.
##   - 13 누적거래량 "단위: 1주" (원문) — a '-' sign has no documented
##     meaning, so a signed 13 is a parse failure, never a guess.
##   - 15 거래량 "+는 매수체결,-는 매도체결" (원문) — documented, preserved
##     raw; the 15→13 accumulation rule is NOT assumed (UNVERIFIED).
##   - 25 전일대비기호 "1: 상한가, 2:상승, 3:보합, 4:하한가, 5:하락" (원문) —
##     preserved raw.
##   - 290 장구분 "1: 장전 시간외 , 2: 장중 , 3: 장후 시간외" (원문) —
##     the tick's session flag; "" when absent (bars counts the unknown
##     class as a conflict — fail-closed, never an invented flag).
##   - 215 장운영구분 (0s) — the full value table is preserved raw; the
##     close-evidence subset is {4, 8} (REPLAY_CONTRACT §12.4).
##
## Channel labels are derived here and MUST match the ws_raw record's
## channel field at replay: JSON object with trnm REG/REMOVE/LOGIN/PING →
## that trnm; trnm REAL → the uniform data[] type ("0B"/"0s"); a mixed
## REAL, a foreign trnm or non-JSON bytes → "unknown". A JSON parse failure
## is fail-closed at the consumer: the ws_raw bytes stay preserved and
## replay rejects at that seq; the live collector preserves and counts.
import std/[strutils, options]
import hcj, vendor_input, sub_input

type
  TickwireError* = object of CatchableError
    seqNo*: int   ## stream seq of the offending ws_raw record (0 = live)

  WireClass* = enum
    wcReal0B
    wcReal0S
    wcReg
    wcRemove
    wcLogin
    wcPing
    wcUnknown

  Tick0B* = object
    ## One 0B data entry normalized as far as the documented FIDs allow.
    item*: string        ## 6-digit code (the data[] item)
    t*: string           ## "HH:MM:SS+09:00" built from FID 20
    price*: int64        ## FID 10, the recorded signed integer
    cumVol*: int64       ## FID 13, unsigned
    flag*: string        ## FID 290 "1"|"2"|"3", "" when absent
    sign15*: string      ## FID 15 raw preserved ("" when absent)
    dir25*: string       ## FID 25 raw preserved ("" when absent)

  Tick0S* = object
    ## One 0s data entry: the market-state observation.
    item*: string
    t*: string           ## from FID 20, "" when absent
    value215*: string    ## FID 215 raw preserved ("" when absent)

const
  ## FID 215 values that are the documented minimum close evidence
  ## (REPLAY_CONTRACT §12.4): 4 장마감(15:30), 8 정규장마감. 9 (전체장마감,
  ## only after 18:00) and every other value is recorded, never terminal.
  closeEvidence215* = ["4", "8"]

proc terr(seqNo: int; msg: string): ref TickwireError =
  let e = newException(TickwireError, msg)
  e.seqNo = seqNo
  e

# ---------------------------------------------------------------- classify

proc classify*(payload: seq[byte]): WireClass =
  ## The channel class of one received application payload. Never raises:
  ## anything it cannot read is wcUnknown (the bytes stay preserved).
  let text = bytesText(payload)
  if text.strip() == "PING":
    # The official SDK treats a bare "PING" string as a ping message
    # (ws_client._is_ping_message); the wire JSON for it is `"PING"`.
    return wcPing
  var doc: HcjValue
  try:
    doc = parseDoc(text)
  except HcjError:
    return wcUnknown
  if doc.kind != hkObj:
    return wcUnknown
  let trnmOpt = doc.getOpt("trnm")
  if trnmOpt.isNone or trnmOpt.get.kind != hkStr:
    return wcUnknown
  case trnmOpt.get.strVal
  of "PING": wcPing
  of "REG": wcReg
  of "REMOVE": wcRemove
  of "LOGIN": wcLogin
  of "REAL":
    let data = doc.getOpt("data")
    if data.isNone or data.get.kind != hkArr or data.get.items.len == 0:
      return wcUnknown
    var sawB = false
    var sawS = false
    for entry in data.get.items:
      if entry.kind != hkObj:
        return wcUnknown
      let ty = entry.getOpt("type")
      if ty.isNone or ty.get.kind != hkStr:
        return wcUnknown
      case ty.get.strVal
      of "0B": sawB = true
      of "0s": sawS = true
      else: return wcUnknown
    if sawB and sawS: wcUnknown    # a mixed REAL has no official precedent
    elif sawB: wcReal0B
    else: wcReal0S
  else: wcUnknown

proc channelOfClass*(w: WireClass): string =
  ## The ws_raw channel label this class must be recorded under.
  case w
  of wcReal0B: "0B"
  of wcReal0S: "0s"
  of wcReg: "REG"
  of wcRemove: "REMOVE"
  of wcLogin: "LOGIN"
  of wcPing: "PING"
  of wcUnknown: "unknown"

proc classOfChannel*(channel: string): WireClass =
  ## Inverse of channelOfClass for the replay-side consistency check.
  case channel
  of "0B": wcReal0B
  of "0s": wcReal0S
  of "REG": wcReg
  of "REMOVE": wcRemove
  of "LOGIN": wcLogin
  of "PING": wcPing
  of "unknown": wcUnknown
  else: wcUnknown   # a channel outside the vocabulary can only mean unknown

proc classMatchesChannel*(channel: string; payload: seq[byte]): bool =
  ## Replay-side check: the recorded channel must equal the class the bytes
  ## re-derive to. A disagreement means the record mislabels its payload.
  channelOfClass(classify(payload)) == channel

# ---------------------------------------------------------------- internals

proc realDoc(seqNo: int; payload: seq[byte]): HcjValue =
  ## Parse and shape-check the envelope of a REAL payload; every deviation
  ## raises (fail-closed at the record's own seq).
  let text = bytesText(payload)
  var doc: HcjValue
  try:
    doc = parseDoc(text)
  except HcjError as e:
    raise terr(seqNo, "payload is not valid HCJ JSON: " & e.msg)
  if doc.kind != hkObj:
    raise terr(seqNo, "payload is not a JSON object: " & kindName(doc))
  let trnm = doc.getOpt("trnm")
  if trnm.isNone or trnm.get.kind != hkStr:
    raise terr(seqNo, "payload has no string trnm")
  if trnm.get.strVal != "REAL":
    raise terr(seqNo, "payload trnm is not REAL: " & trnm.get.strVal)
  let data = doc.getOpt("data")
  if data.isNone or data.get.kind != hkArr:
    raise terr(seqNo, "REAL payload has no data array")
  if data.get.items.len == 0:
    raise terr(seqNo, "REAL payload has an empty data array")
  doc

proc dataEntries(seqNo: int; doc: HcjValue; typ: string): seq[HcjValue] =
  let data = doc.get("data")
  for entry in data.items:
    if entry.kind != hkObj:
      raise terr(seqNo, "REAL data entry is not an object: " & kindName(entry))
    let ty = entry.getOpt("type")
    if ty.isNone or ty.get.kind != hkStr or ty.get.strVal != typ:
      raise terr(seqNo, "REAL data entry type is not " & typ)
    let values = entry.getOpt("values")
    if values.isNone or values.get.kind != hkObj:
      raise terr(seqNo, "REAL data entry has no values object")
    for p in values.get.pairs:
      if p.v.kind != hkStr:
        raise terr(seqNo,
          "REAL values value is not a string (FID " & p.k & " is " &
          kindName(p.v) & ")")
    result.add(entry)

proc strFid(seqNo: int; values: HcjValue; fid: string): string =
  let v = values.getOpt(fid)
  if v.isNone:
    raise terr(seqNo, "required FID " & fid & " is missing from values")
  if v.get.kind != hkStr:
    raise terr(seqNo, "FID " & fid & " is not a string: " & kindName(v.get))
  v.get.strVal

proc optFid(values: HcjValue; fid: string): string =
  let v = values.getOpt(fid)
  if v.isNone: return ""
  if v.get.kind != hkStr: return ""
  v.get.strVal

proc hmsFid(seqNo: int; s: string; what: string): string =
  ## FID 20 (체결시간 HHmmss, spec 원문) → "HH:MM:SS+09:00" (the KRX session
  ## offset calendars.nim accepts). Exactly six digits with plausible
  ## ranges; anything else is a parse failure.
  if s.len != 6:
    raise terr(seqNo, what & " is not HHmmss (6 digits): " & s)
  for c in s.items:
    if c notin {'0' .. '9'}:
      raise terr(seqNo, what & " is not HHmmss (6 digits): " & s)
  let hh = (ord(s[0]) - ord('0')) * 10 + (ord(s[1]) - ord('0'))
  proc d2(i: int): int = (ord(s[i]) - ord('0')) * 10 + (ord(s[i + 1]) - ord('0'))
  let mm = d2(2)
  let ss = d2(4)
  if hh > 23 or mm > 59 or ss > 59:
    raise terr(seqNo, what & " is outside plausible HHmmss ranges: " & s)
  result = s[0 .. 1] & ":" & s[2 .. 3] & ":" & s[4 .. 5] & "+09:00"

proc signedInt(seqNo: int; s: string; fid: string; allowMinus: bool): int64 =
  ## A signed-integer FID value: optional '+' or '-' (when allowed), then
  ## digits. The sign is preserved in the value — never stripped into a
  ## separate interpretation (FID 10's sign semantics are UNVERIFIED).
  if s.len == 0:
    raise terr(seqNo, "FID " & fid & " is empty")
  var i = 0
  var neg = false
  if s[0] == '+' or s[0] == '-':
    if s[0] == '-':
      if not allowMinus:
        raise terr(seqNo, "FID " & fid & " carries an undocumented '-' sign: " &
                   s & " (the sign's meaning is UNVERIFIED; fail-closed)")
      neg = true
    i = 1
  if i >= s.len:
    raise terr(seqNo, "FID " & fid & " has a sign but no digits: " & s)
  var v: int64 = 0
  while i < s.len:
    if s[i] notin {'0' .. '9'}:
      raise terr(seqNo, "FID " & fid & " is not an integer: " & s)
    if v > (high(int64) - (ord(s[i]) - ord('0'))) div 10:
      raise terr(seqNo, "FID " & fid & " overflows int64: " & s)
    v = v * 10 + (ord(s[i]) - ord('0')).int64
    inc i
  result = if neg: -v else: v

# ---------------------------------------------------------------- parsers

proc ticksOf0B*(seqNo: int; payload: seq[byte]): seq[Tick0B] =
  ## Parse one 0B REAL payload into normalized ticks, in data[] order.
  ## Raises TickwireError on any shape or required-FID deviation — the
  ## caller fail-closes (replay: REJECT at seq; collector: preserve+count).
  let doc = realDoc(seqNo, payload)
  for entry in dataEntries(seqNo, doc, "0B"):
    let item = entry.getOpt("item")
    if item.isNone or item.get.kind != hkStr:
      raise terr(seqNo, "0B data entry has no string item")
    if not validCode(item.get.strVal):
      raise terr(seqNo, "0B item is not a 6-digit code: " & item.get.strVal)
    let values = entry.get("values")
    let t20 = hmsFid(seqNo, strFid(seqNo, values, "20"), "FID 20 체결시간")
    let p10 = signedInt(seqNo, strFid(seqNo, values, "10"), "10", true)
    let v13 = signedInt(seqNo, strFid(seqNo, values, "13"), "13", false)
    let flag = optFid(values, "290")
    if flag.len > 0 and flag notin ["1", "2", "3"]:
      raise terr(seqNo,
        "FID 290 장구분 is outside the documented 1|2|3: " & flag)
    result.add(Tick0B(
      item: item.get.strVal,
      t: t20,
      price: p10,
      cumVol: v13,
      flag: flag,
      sign15: optFid(values, "15"),
      dir25: optFid(values, "25")))

proc statesOf0S*(seqNo: int; payload: seq[byte]): seq[Tick0S] =
  ## Parse one 0s REAL payload into market-state observations. FID 215 is
  ## preserved raw (the full value table is larger than the evidenced
  ## close subset); FID 20 is optional here (the spec example carries it).
  let doc = realDoc(seqNo, payload)
  for entry in dataEntries(seqNo, doc, "0s"):
    let item = entry.getOpt("item")
    let values = entry.get("values")
    var t = ""
    if values.has("20"):
      t = hmsFid(seqNo, strFid(seqNo, values, "20"), "FID 20 체결시간")
    var v215 = ""
    if values.has("215"):
      v215 = strFid(seqNo, values, "215")
      if v215.len == 0:
        raise terr(seqNo, "FID 215 is present but empty")
    result.add(Tick0S(
      item: if item.isNone: "" else: item.get.strVal,
      t: t,
      value215: v215))

proc isCloseEvidence*(value215: string): bool =
  ## The documented minimum close-evidence subset (REPLAY_CONTRACT §12.4).
  value215 in closeEvidence215

# ---------------------------------------------------------------- ack payloads

proc ackTrnmOf*(seqNo: int; payload: seq[byte]): string =
  ## "REG" or "REMOVE" for an ack payload, fail-closed otherwise. Used by
  ## the collector core to pair an ack with its own outstanding request.
  let text = bytesText(payload)
  var doc: HcjValue
  try:
    doc = parseDoc(text)
  except HcjError as e:
    raise terr(seqNo, "ack payload is not valid HCJ JSON: " & e.msg)
  if doc.kind != hkObj:
    raise terr(seqNo, "ack payload is not a JSON object: " & kindName(doc))
  let trnm = doc.getOpt("trnm")
  if trnm.isNone or trnm.get.kind != hkStr or
     (trnm.get.strVal != "REG" and trnm.get.strVal != "REMOVE"):
    raise terr(seqNo, "ack payload trnm is not REG|REMOVE")
  trnm.get.strVal

proc ackReturnCode*(seqNo: int; payload: seq[byte]): int =
  ## The ack's return_code. A missing or non-integer code is a parse
  ## failure: the spec documents the code as always sent for REG/REMOVE
  ## responses ("등록,해지요청시에만 값 전송"), so absence is fail-closed.
  let text = bytesText(payload)
  var doc: HcjValue
  try:
    doc = parseDoc(text)
  except HcjError as e:
    raise terr(seqNo, "ack payload is not valid HCJ JSON: " & e.msg)
  let rc = doc.getOpt("return_code")
  if rc.isNone:
    raise terr(seqNo,
      "ack payload has no return_code (the spec sends it for every " &
      "REG/REMOVE response; absence is fail-closed)")
  if rc.get.kind != hkInt:
    raise terr(seqNo, "ack return_code is not an integer: " & kindName(rc.get))
  int(rc.get.ival)
