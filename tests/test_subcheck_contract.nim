## subcheck contract tests: the three §10 consumption checks over the
## stream-order sub/ws_raw evidence (tools/collector/README.md §10,
## src/hs/subcheck.nim). Synthetic records only — the same guard runs in
## the live collector core and at replay.
## Run: nim c -r --hints:off --warnings:off --path:src tests/test_subcheck_contract.nim
import std/[strutils]
import hs/[hcj, records, sub_input, subcheck]

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

proc guardRaises(name: string; needle: string; body: proc ()) =
  var raised = false
  var msg = ""
  try:
    body()
  except SubGuardError as e:
    raised = true
    msg = e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name & " (raises: " & needle & ")", raised and needle in msg)

# ---------------------------------------------------------------- builders

const ts = "2026-10-29T09:00:00+09:00"

proc regReq(gen = 1; types: seq[string] = @["0B"];
            codes: seq[string] = @["005930"]; refresh = "1"): HcjValue =
  var codesArr: seq[HcjValue]
  for c in codes: codesArr.add(hStr(c))
  var typesArr: seq[HcjValue]
  for t in types: typesArr.add(hStr(t))
  hObj(("action", hStr("reg")), ("codes", HcjValue(kind: hkArr,
       items: codesArr)), ("gen", hInt(gen)), ("phase", hStr("req")),
       ("refresh", hStr(refresh)), ("t", hStr(ts)),
       ("types", HcjValue(kind: hkArr, items: typesArr)))

proc ackRaw(gen = 1; action = "reg"; code = 0; msg = ""): HcjValue =
  if msg.len > 0:
    hObj(("action", hStr(action)), ("gen", hInt(gen)),
         ("phase", hStr("ack")), ("return_code", hInt(code)),
         ("return_msg", hStr(msg)), ("t", hStr(ts)))
  else:
    hObj(("action", hStr(action)), ("gen", hInt(gen)),
         ("phase", hStr("ack")), ("return_code", hInt(code)),
         ("t", hStr(ts)))

proc arrStr(xs: seq[string]): HcjValue =
  var items: seq[HcjValue]
  for x in xs: items.add(hStr(x))
  HcjValue(kind: hkArr, items: items)

proc fed(g: var SubGuard; raw: HcjValue) =
  g.observeSub(parseSub(0, raw))

# ------------------------------------------------------------- wire epochs

block wireEpochs:
  var g = initSubGuard()
  g.observeWsRaw(1)
  g.observeWsRaw(1)
  g.observeWsRaw(2)
  check("observeWsRaw: repeating and advancing generations are accepted",
        true)
  guardRaises("observeWsRaw: a backwards generation is a record failure",
              "went backwards", proc () =
                var h = initSubGuard()
                h.observeWsRaw(2)
                h.observeWsRaw(1))
  guardRaises("observeWsRaw: conn 0 is refused", "must be >= 1",
              proc () =
                var h = initSubGuard()
                h.observeWsRaw(0))

# --------------------------------------------------------- activeSets rules

block pairing:
  var g = initSubGuard()
  g.fed(regReq(gen = 1))
  check("a req alone activates nothing", g.active0BCodes().len == 0)
  g.fed(ackRaw(gen = 1, action = "reg", code = 0))
  check("a (reg, ack 0) activates the codes",
        g.active0BCodes() == @["005930"])
  check("the reg ack is counted", g.regAckCount0B() == 1)

  var g2 = initSubGuard()
  g2.fed(regReq(gen = 1))
  g2.fed(ackRaw(gen = 1, action = "reg", code = 1))
  check("a failed ack (code != 0) activates nothing",
        g2.active0BCodes().len == 0 and g2.regAckCount0B() == 0)

  var g3 = initSubGuard()
  g3.fed(ackRaw(gen = 5, action = "reg", code = 0))
  check("an unmatched ack is a no-op",
        g3.active0BCodes().len == 0 and g3.regAckCount0B() == 0)

  var g4 = initSubGuard()
  g4.fed(regReq(gen = 1, codes = @["000660"]))
  g4.fed(regReq(gen = 2, codes = @["005930"]))
  g4.fed(ackRaw(gen = 2, action = "reg", code = 0))
  check("an ack pairs its own (gen, action), not the oldest req blindly",
        g4.active0BCodes() == @["005930"])
  g4.fed(ackRaw(gen = 1, action = "reg", code = 0))
  check("the remaining oldest req is paired by the next ack",
        g4.active0BCodes() == @["000660", "005930"])

  guardRaises("a refresh=0 registration makes the active set underivable",
              "refresh=0", proc () =
                var h = initSubGuard()
                h.fed(regReq(gen = 1, refresh = "0")))

# --------------------------------------------------------------- the checks

block checks:
  var g = initSubGuard()
  check("no evidence at all: every 0B tick quarantines (unsubscribed)",
        g.checkTick("005930").kind == qkUnsubscribed)

  # Confirmed set, current connection: the tick is consumed.
  g.fed(regReq(gen = 1, codes = @["005930", "000660"]))
  g.fed(ackRaw(gen = 1, action = "reg", code = 0))
  check("checkTick: an active symbol on the confirming generation passes",
        g.checkTick("005930").kind == qkNone)

  # A reg ack without any ws_raw leaves stateConn 0 with conn 0: equal,
  # so the active-set check decides (the no-wire stream stays honest).
  var gNoWire = initSubGuard()
  gNoWire.fed(regReq(gen = 1))
  gNoWire.fed(ackRaw(gen = 1, action = "reg", code = 0))
  check("an ack-only stream still quarantines foreign symbols",
        gNoWire.checkTick("005930").kind == qkNone)

  g.fed(regReq(gen = 2, codes = @["003540"]))
  g.fed(ackRaw(gen = 2, action = "reg", code = 0))
  check("a second confirmed REG extends the active set",
        g.active0BCodes() == @["000660", "003540", "005930"])

  # Remove: ack 0 takes the codes out until a reg ack brings them back.
  g.fed(hObj(("action", hStr("remove")), ("codes", arrStr(@["005930"])),
             ("gen", hInt(3)), ("phase", hStr("req")), ("t", hStr(ts)),
             ("types", arrStr(@["0B"]))))
  g.fed(ackRaw(gen = 3, action = "remove", code = 0))
  check("a (remove, ack 0) shrinks the active set",
        g.active0BCodes() == @["000660", "003540"])
  check("the remove ack is counted", g.removeAckCount0B() == 1)
  let q = g.checkTick("005930")
  check("a post-remove tick quarantines as qkPostRemove",
        q.kind == qkPostRemove)
  check("a never-subscribed symbol still quarantines as unsubscribed",
        g.checkTick("999999").kind == qkUnsubscribed)

  # Re-registration clears the removed set.
  g.fed(regReq(gen = 4, codes = @["005930"]))
  g.fed(ackRaw(gen = 4, action = "reg", code = 0))
  check("a re-registering reg ack un-quarantines the symbol",
        g.checkTick("005930").kind == qkNone)

  # A failed REMOVE changes nothing (activeSets rule).
  g.fed(hObj(("action", hStr("remove")), ("codes", arrStr(@["000660"])),
             ("gen", hInt(5)), ("phase", hStr("req")), ("t", hStr(ts)),
             ("types", arrStr(@["0B"]))))
  g.fed(ackRaw(gen = 5, action = "remove", code = 1))
  check("a failed REMOVE ack leaves the active set unchanged",
        g.checkTick("000660").kind == qkNone and
        g.removeAckCount0B() == 1)

block staleConn:
  var g = initSubGuard()
  g.observeWsRaw(1)
  g.fed(regReq(gen = 1, codes = @["005930"]))
  g.fed(ackRaw(gen = 1, action = "reg", code = 0))
  check("the confirming ack pins stateConn to the current wire",
        g.checkTick("005930").kind == qkNone)
  g.observeWsRaw(2)
  let q = g.checkTick("005930")
  check("after a reconnect (no re-registration ack yet) the tick is stale",
        q.kind == qkStaleConn)
  g.fed(regReq(gen = 2, codes = @["005930"]))
  g.fed(ackRaw(gen = 2, action = "reg", code = 0))
  check("a re-registration ack on the new connection re-validates",
        g.checkTick("005930").kind == qkNone)

  var g2 = initSubGuard()
  g2.observeWsRaw(1)
  g2.fed(regReq(gen = 1))
  g2.fed(ackRaw(gen = 1, action = "reg", code = 0))
  g2.fed(hObj(("action", hStr("remove")), ("codes", arrStr(@["005930"])),
              ("gen", hInt(2)), ("phase", hStr("req")), ("t", hStr(ts)),
              ("types", arrStr(@["0B"]))))
  g2.fed(ackRaw(gen = 2, action = "remove", code = 0))
  g2.observeWsRaw(2)
  let q2 = g2.checkTick("005930")
  check("a REMOVE ack never re-validates a stale connection (check 3 " &
        "before check 2)", q2.kind == qkStaleConn)

block details:
  var g = initSubGuard()
  let qu = g.checkTick("005930")
  check("the unsubscribed detail names the symbol",
        "005930" in qu.detail and "active subscription set" in qu.detail)
  g.fed(regReq(gen = 1, codes = @["005930"]))
  g.fed(ackRaw(gen = 1, action = "reg", code = 0))
  g.fed(hObj(("action", hStr("remove")), ("codes", arrStr(@["005930"])),
             ("gen", hInt(2)), ("phase", hStr("req")), ("t", hStr(ts)),
             ("types", arrStr(@["0B"]))))
  g.fed(ackRaw(gen = 2, action = "remove", code = 0))
  check("the post-remove detail names the removal",
        "removed by a REMOVE ack" in g.checkTick("005930").detail)

if failures == 0:
  echo "SUBCHECK CONTRACT PASSED (", passes, " checks)"
else:
  echo "SUBCHECK CONTRACT FAILED: ", failures, " of ", passes + failures
  quit(1)
