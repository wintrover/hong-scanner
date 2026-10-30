## tickwire contract tests: the single 0B/0s wire parser
## (tools/collector/README.md §9, src/hs/tickwire.nim). Payloads are
## synthetic, shaped from the official spec JSON response examples only —
## no network, no vendor data, no wall clock.
## Run: nim c -r --hints:off --warnings:off --path:src tests/test_tickwire_contract.nim
import std/[strutils]
import hs/[hcj, sub_input, tickwire]

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

proc tickRaises(name: string; needle: string; body: proc ()) =
  var raised = false
  var msg = ""
  try:
    body()
  except TickwireError as e:
    raised = true
    msg = e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name & " (raises: " & needle & ")", raised and needle in msg)

# ---------------------------------------------------------------- builders

proc hexOf(s: string): string =
  ## Lowercase hex, the ws_raw payload encoding.
  const digits = "0123456789abcdef"
  for c in s:
    result.add(digits[int(ord(c)) shr 4])
    result.add(digits[int(ord(c)) and 0x0f])

proc bytesOf(s: string): seq[byte] =
  payloadFromHex(0, hexOf(s))

proc tick0BJson(item = "005930"; t20 = "165208"; price = "-20800";
                cum = "30379732"; flag = "2"; sign15 = "+82";
                dir25 = "5"): string =
  ## The official 0B response_example shape (README §9): all FID values are
  ## strings, one data entry per item.
  var values = "{\"10\":\"" & price & "\",\"13\":\"" & cum & "\""
  if sign15.len > 0:
    values.add(",\"15\":\"" & sign15 & "\"")
  if dir25.len > 0:
    values.add(",\"25\":\"" & dir25 & "\"")
  values.add(",\"20\":\"" & t20 & "\"")
  if flag.len > 0:
    values.add(",\"290\":\"" & flag & "\"")
  values.add("}")
  "{\"trnm\":\"REAL\",\"data\":[{\"item\":\"" & item & "\",\"name\":\"" &
    "주식체결\",\"type\":\"0B\",\"values\":" & values & "}]}"

proc state0SJson(value215 = "b"; t20 = "170000"; item = ""): string =
  ## The official 0s response_example shape (README §9).
  "{\"trnm\":\"REAL\",\"data\":[{\"item\":\"" & item & "\",\"name\":\"" &
    "장시작시간\",\"type\":\"0s\",\"values\":{\"20\":\"" & t20 &
    "\",\"215\":\"" & value215 & "\",\"214\":\"000000\"}}]}"

proc ackJson(trnm = "REG"; code = 0; withMsg = true): string =
  if withMsg:
    "{\"return_code\":" & $code & ",\"return_msg\":\"\",\"trnm\":\"" &
      trnm & "\"}"
  else:
    "{\"return_code\":" & $code & ",\"trnm\":\"" & trnm & "\"}"

# ---------------------------------------------------------------- classify

block classifyBasics:
  check("classify: the 0B example is wcReal0B",
        classify(bytesOf(tick0BJson())) == wcReal0B)
  check("classify: the 0s example is wcReal0S",
        classify(bytesOf(state0SJson())) == wcReal0S)
  check("classify: a REG ack is wcReg", classify(bytesOf(ackJson())) == wcReg)
  check("classify: a REMOVE ack is wcRemove",
        classify(bytesOf(ackJson(trnm = "REMOVE"))) == wcRemove)
  check("classify: a LOGIN ack is wcLogin",
        classify(bytesOf("{\"trnm\":\"LOGIN\",\"return_code\":0}")) ==
        wcLogin)
  check("classify: bare PING text is wcPing",
        classify(bytesOf("PING")) == wcPing)
  check("classify: {\"trnm\":\"PING\"} is wcPing",
        classify(bytesOf("{\"trnm\":\"PING\"}")) == wcPing)
  check("classify: non-JSON bytes are wcUnknown",
        classify(bytesOf("deadbeef")) == wcUnknown)
  check("classify: a JSON array is wcUnknown",
        classify(bytesOf("[1,2]")) == wcUnknown)
  check("classify: a trnm-less object is wcUnknown",
        classify(bytesOf("{\"data\":[]}")) == wcUnknown)
  check("classify: an unknown trnm is wcUnknown",
        classify(bytesOf("{\"trnm\":\"SCALER\"}")) == wcUnknown)
  check("classify: an empty data array is wcUnknown",
        classify(bytesOf("{\"trnm\":\"REAL\",\"data\":[]}")) == wcUnknown)
  check("classify: a mixed 0B/0s REAL is wcUnknown",
        classify(bytesOf("{\"trnm\":\"REAL\",\"data\":[" &
          "{\"type\":\"0B\",\"item\":\"005930\",\"values\":{}}," &
          "{\"type\":\"0s\",\"item\":\"\",\"values\":{}}]}")) == wcUnknown)
  check("classify: a foreign data type is wcUnknown",
        classify(bytesOf("{\"trnm\":\"REAL\",\"data\":[" &
          "{\"type\":\"0H\",\"item\":\"005930\",\"values\":{}}]}")) ==
        wcUnknown)

block channelLabels:
  for cls in [wcReal0B, wcReal0S, wcReg, wcRemove, wcLogin, wcPing,
              wcUnknown]:
    check("channel label round-trips for " & $cls,
          classOfChannel(channelOfClass(cls)) == cls)
  check("classMatchesChannel: true for a labeled 0B",
        classMatchesChannel("0B", bytesOf(tick0BJson())))
  check("classMatchesChannel: false for a mislabeled 0B",
        not classMatchesChannel("0s", bytesOf(tick0BJson())))
  check("classMatchesChannel: false for unknown bytes labeled 0B",
        not classMatchesChannel("0B", bytesOf("garbage")))

# --------------------------------------------------------------- 0B parsing

block parse0B:
  let ticks = ticksOf0B(7, bytesOf(tick0BJson()))
  check("ticksOf0B: one tick from the example", ticks.len == 1)
  check("ticksOf0B: item is the 6-digit code", ticks[0].item == "005930")
  check("ticksOf0B: FID 20 becomes HH:MM:SS+09:00",
        ticks[0].t == "16:52:08+09:00")
  check("ticksOf0B: FID 10 keeps the recorded sign",
        ticks[0].price == -20800)
  check("ticksOf0B: FID 13 is the cumulative volume",
        ticks[0].cumVol == 30379732)
  check("ticksOf0B: FID 290 is the session flag", ticks[0].flag == "2")
  check("ticksOf0B: FID 15 is preserved raw", ticks[0].sign15 == "+82")
  check("ticksOf0B: FID 25 is preserved raw", ticks[0].dir25 == "5")

  let two = ticksOf0B(7, bytesOf(
    "{\"trnm\":\"REAL\",\"data\":[" &
    "{\"item\":\"005930\",\"name\":\"주식체결\",\"type\":\"0B\"," &
    "\"values\":{\"10\":\"-20800\",\"13\":\"100\",\"20\":\"090000\"," &
    "\"290\":\"2\"}}," &
    "{\"item\":\"000660\",\"name\":\"주식체결\",\"type\":\"0B\"," &
    "\"values\":{\"10\":\"20000\",\"13\":\"200\",\"20\":\"090000\"," &
    "\"290\":\"2\"}}]}"))
  check("ticksOf0B: two entries become two ticks in data[] order",
        two.len == 2 and two[0].item == "005930" and
        two[1].item == "000660")

  check("ticksOf0B: an absent optional FID 290 is an empty flag",
        ticksOf0B(7, bytesOf(tick0BJson(flag = "")))[0].flag == "")
  block:
    let t = ticksOf0B(7, bytesOf(tick0BJson(sign15 = "", dir25 = "")))[0]
    check("ticksOf0B: absent FID 15/25 are preserved as empty",
          t.sign15 == "" and t.dir25 == "")

  tickRaises("ticksOf0B: a present-but-empty FID 20 fails",
             "is not HHmmss", proc () =
               discard ticksOf0B(7, bytesOf(tick0BJson(t20 = ""))))
  tickRaises("ticksOf0B: a missing required FID 20 fails",
             "required FID 20", proc () =
               discard ticksOf0B(7, bytesOf(
                 "{\"trnm\":\"REAL\",\"data\":[{\"type\":\"0B\"," &
                 "\"item\":\"005930\",\"values\":{\"10\":\"-20800\"," &
                 "\"13\":\"30379732\"}}]}")))
  tickRaises("ticksOf0B: a negative FID 13 fails (undocumented sign)",
             "undocumented '-' sign", proc () =
               discard ticksOf0B(7, bytesOf(tick0BJson(cum = "-5"))))
  tickRaises("ticksOf0B: a non-integer FID 10 fails",
             "is not an integer", proc () =
               discard ticksOf0B(7, bytesOf(tick0BJson(price = "abc"))))
  tickRaises("ticksOf0B: a FID 290 outside 1|2|3 fails",
             "outside the documented 1|2|3", proc () =
               discard ticksOf0B(7, bytesOf(tick0BJson(flag = "4"))))
  tickRaises("ticksOf0B: a non-6-digit FID 20 fails",
             "is not HHmmss", proc () =
               discard ticksOf0B(7, bytesOf(tick0BJson(t20 = "90500"))))
  tickRaises("ticksOf0B: a non-6-digit item fails",
             "is not a 6-digit code", proc () =
               discard ticksOf0B(7, bytesOf(tick0BJson(item = "5930"))))
  tickRaises("ticksOf0B: non-string FID values fail",
             "is not a string", proc () =
               discard ticksOf0B(7, bytesOf(
                 "{\"trnm\":\"REAL\",\"data\":[{\"type\":\"0B\"," &
                 "\"item\":\"005930\",\"values\":{\"20\":165208," &
                 "\"10\":\"-20800\",\"13\":\"30379732\"}}]}")))
  tickRaises("ticksOf0B: a non-REAL trnm fails the parser",
             "trnm is not REAL", proc () =
               discard ticksOf0B(7, bytesOf(ackJson())))
  tickRaises("ticksOf0B: garbage bytes fail the parser",
             "is not valid HCJ JSON", proc () =
               discard ticksOf0B(7, bytesOf("garbage")))

# --------------------------------------------------------------- 0s parsing

block parse0S:
  let states = statesOf0S(3, bytesOf(state0SJson()))
  check("statesOf0S: one state from the example", states.len == 1)
  check("statesOf0S: FID 215 preserved raw", states[0].value215 == "b")
  check("statesOf0S: FID 20 becomes HH:MM:SS+09:00",
        states[0].t == "17:00:00+09:00")
  check("statesOf0S: the example item is empty", states[0].item == "")

  let no215 = statesOf0S(3, bytesOf(
    "{\"trnm\":\"REAL\",\"data\":[{\"item\":\"\",\"type\":\"0s\"," &
    "\"values\":{\"20\":\"170000\",\"214\":\"000000\"}}]}"))
  check("statesOf0S: an absent FID 215 is an empty value",
        no215[0].value215 == "")
  tickRaises("statesOf0S: a present-but-empty FID 215 fails",
             "present but empty", proc () =
               discard statesOf0S(3, bytesOf(state0SJson(value215 = ""))))
  tickRaises("statesOf0S: garbage bytes fail the parser",
             "is not valid HCJ JSON", proc () =
               discard statesOf0S(3, bytesOf("PING")))

block closeEvidence:
  check("close evidence is 4", isCloseEvidence("4"))
  check("close evidence is 8", isCloseEvidence("8"))
  check("9 is recorded, never terminal", not isCloseEvidence("9"))
  check("b (장시작) is not close evidence", not isCloseEvidence("b"))
  check("an empty value is not close evidence",
        not isCloseEvidence(""))

# ------------------------------------------------------------ ack payloads

block acks:
  check("ackTrnmOf: REG", ackTrnmOf(0, bytesOf(ackJson())) == "REG")
  check("ackTrnmOf: REMOVE",
        ackTrnmOf(0, bytesOf(ackJson(trnm = "REMOVE"))) == "REMOVE")
  check("ackReturnCode: zero", ackReturnCode(0, bytesOf(ackJson())) == 0)
  check("ackReturnCode: one (no msg field)",
        ackReturnCode(0, bytesOf(ackJson(code = 1, withMsg = false))) == 1)
  tickRaises("ackTrnmOf: a REAL payload is not an ack",
             "trnm is not REG|REMOVE", proc () =
               discard ackTrnmOf(0, bytesOf(tick0BJson())))
  tickRaises("ackTrnmOf: garbage is not an ack", "not valid HCJ JSON",
             proc () = discard ackTrnmOf(0, bytesOf("???")))
  tickRaises("ackReturnCode: a missing return_code fails (spec sends it)",
             "has no return_code", proc () =
               discard ackReturnCode(0, bytesOf("{\"trnm\":\"REG\"}")))
  tickRaises("ackReturnCode: a string return_code fails",
             "is not an integer", proc () =
               discard ackReturnCode(0, bytesOf(
                 "{\"trnm\":\"REG\",\"return_code\":\"0\"}")))

if failures == 0:
  echo "TICKWIRE CONTRACT PASSED (", passes, " checks)"
else:
  echo "TICKWIRE CONTRACT FAILED: ", failures, " of ", passes + failures
  quit(1)
