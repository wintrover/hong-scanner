## Fixture generator. Regenerates fixtures/smoke/*.hcj.jsonl through the same
## canonical encoder the recorder uses, so committed fixtures cannot drift
## from the on-disk record envelope. Run: nim c -r --path:src tools/gen_fixture.nim
import std/[os, strutils]
import hs/[hcj, records]

const sessionDate = "2026-10-29"

proc hmsToSec(s: string): int =
  let hh = parseInt(s[0 .. 1])
  let mm = parseInt(s[3 .. 4])
  let ss = parseInt(s[6 .. 7])
  hh * 3600 + mm * 60 + ss

proc tAt(barIdx: int): string =
  let sec = 9 * 3600 + barIdx * 180
  result = align($(sec div 3600), 2, '0') & ":" &
           align($((sec mod 3600) div 60), 2, '0') & ":" &
           align($(sec mod 60), 2, '0') & "+09:00"

proc calendarRaw(): HcjValue =
  hObj(
    ("days", hObj(
      ("2026-10-28", hObj(("close", hStr("15:30:00+09:00")),
                          ("half_day", hBool(false)),
                          ("open", hStr("09:00:00+09:00")),
                          ("reason", hNull()))),
      ("2026-10-29", hObj(("close", hStr("15:30:00+09:00")),
                          ("half_day", hBool(false)),
                          ("open", hStr("09:00:00+09:00")),
                          ("reason", hNull()))),
      ("2026-10-30", hObj(("close", hNull()),
                          ("half_day", hBool(false)),
                          ("open", hNull()),
                          ("reason", hStr("holiday")))))),
    ("market", hStr("KRX")),
    ("schema", hStr("hong-scanner-calendar/1")),
    ("tz", hStr("Asia/Seoul")),
    ("version", hStr("CAL-FIXTURE-2026-10-29")))

proc configRaw(): HcjValue =
  hObj(
    ("params", hObj(
      ("lookback", hInt(3)),
      ("pullback_min_bp", hInt(50)),
      ("rebound_min_bp", hInt(50)),
      ("recovery_bp", hInt(30)),
      ("breakdown_bp", hInt(30)),
      ("warmup_bars", hInt(0)),
      ("hold_on_degraded", hBool(true)))),
    ("session_date", hStr(sessionDate)))

proc tick(symbol: string; barIdx: int; price: int64; vol: int64): HcjValue =
  hObj(("m", hStr("2")), ("price", hInt(price)), ("symbol", hStr(symbol)),
       ("t", hStr(tAt(barIdx))), ("vol", hInt(vol)))

proc gapRaw(): HcjValue =
  hObj(("detail", hObj(("code", hNull()))),
       ("reason", hStr("ws_disconnect")),
       ("symbol", hNull()))

proc baseTicks(): seq[HcjValue] =
  ## Time-ordered stream: bar 0 .. bar 10, both symbols per bar.
  ## 005930: rise to bar 5, pull back to bar 8, reversal at bar 9.
  ## 000660: fall to bar 5, rebound to bar 7, breakdown at bar 9.
  result.add tick("005930", 0, 10000, 100)
  result.add tick("000660", 0, 20000, 5000)
  result.add tick("005930", 1, 10100, 200)
  result.add tick("000660", 1, 19800, 5001)
  result.add tick("005930", 2, 10200, 300)
  result.add tick("000660", 2, 19600, 5002)
  result.add tick("005930", 3, 10300, 400)
  result.add tick("000660", 3, 19400, 5003)
  result.add tick("005930", 4, 10400, 500)
  result.add tick("000660", 4, 19200, 5004)
  result.add tick("005930", 5, 10500, 600)
  result.add tick("000660", 5, 18800, 5005)
  result.add tick("005930", 6, 10400, 700)
  result.add tick("000660", 6, 19000, 5006)
  result.add tick("005930", 7, 10300, 800)
  result.add tick("000660", 7, 19100, 5007)
  result.add tick("005930", 8, 10200, 900)
  result.add tick("000660", 8, 19050, 5008)
  result.add tick("005930", 9, 10250, 950)
  result.add tick("005930", 9, 10450, 1000)
  result.add tick("000660", 9, 18850, 5009)
  result.add tick("000660", 9, 18400, 5010)
  result.add tick("005930", 10, 10440, 1100)
  result.add tick("000660", 10, 18900, 5011)

proc linesText(lines: seq[string]): string =
  for l in lines: result.add(l & "\n")

proc build(ticks: seq[HcjValue]; gapAfterBar: int; withEnd: bool): seq[string] =
  var seqNo = 0
  var rows: seq[string]
  template app(k: Kind, r: HcjValue) =
    inc seqNo
    rows.add(makeRecordLine(seqNo, k, r))
  app(kCalendar, calendarRaw())
  app(kConfig, configRaw())
  var gapDone = gapAfterBar < 0
  for t in ticks:
    let bar = (hmsToSec(t.get("t").asStr) - 9 * 3600) div 180
    if not gapDone and bar > gapAfterBar:
      app(kGap, gapRaw())
      gapDone = true
    app(kWsFrame, t)
  if not gapDone:
    app(kGap, gapRaw())
  if withEnd:
    app(kSessionEnd, hNull())
  rows

when isMainModule:
  let dir = "fixtures" / "smoke"
  createDir(dir)
  let base = baseTicks()
  writeFile(dir / "input.hcj.jsonl", linesText(build(base, -1, true)))
  writeFile(dir / "gap_input.hcj.jsonl", linesText(build(base, 2, true)))
  writeFile(dir / "incomplete_input.hcj.jsonl", linesText(build(base, -1, false)))
  var late = build(base, -1, false)
  # A tick that belongs to bar 1 arrives after bar 2 has opened.
  late.add(makeRecordLine(late.len + 1, kWsFrame, tick("005930", 1, 10150, 950)))
  late.add(makeRecordLine(late.len + 1, kSessionEnd, hNull()))
  writeFile(dir / "late_tick_input.hcj.jsonl", linesText(late))
  echo "fixtures written to ", dir