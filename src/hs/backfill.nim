## Backfill bars: ka10080 3-minute REST evidence -> origin:"BACKFILL" bars
## (REPLAY_CONTRACT §12.8, the VS-2B implementation; P21).
##
## Pure: consumes the verified ka10080 attempts of a stream (rest_resp
## acceptance path), re-parses the preserved row bytes and derives closed
## bars marked origin:"BACKFILL". No wall clock, no filesystem, no network.
## A backfill bar never masquerades as a live tick: no ws_frame is ever
## fabricated from a REST bar (§12.8); the raw evidence stays the recorded
## body_hex of the rest_resp records (§12.2, checksummed by the run
## artifacts), and the derived bar carries only the §7 bar vocabulary plus
## the optional origin field.
##
## Interpretation declarations (scanner-side, fail-closed):
##   - cntr_tm is preserved as recorded (YYYYMMDDHHmmss string; the raw
##     bytes are the evidence). The official document does not state whether
##     that time is the bar interval's start or its end — UNVERIFIED. This
##     module declares the scanner-side placement rule "the bar belongs to
##     the interval that CONTAINS cntr_tm" (the same i(t) rule as ticks,
##     §5); under the end-interpretation every index here shifts by one.
##     Resolving the boundary semantics is the F-2 measured-capture item
##     (demo server raw capture); until then both the rule and its
##     undetermined status are pinned here and in the tests.
##   - The cntr_tm date part must equal the session date: a bar of another
##     day cannot be placed on this session's timeline (a base_dt other
##     than the session date is therefore unconsumable, fail-closed).
##   - Rows are placed by (symbol, interval); row order inside a page is
##     the vendor's own order (ascending/descending cntr_tm is UNVERIFIED
##     and does not matter: bars are keyed, never ordered, by row order).
##     Two rows landing on one interval, or a LIVE tick bar on the same
##     (symbol, interval), are contract failures — the P22 session-mode
##     merge semantics are not declared, so no merge is guessed.
##   - A row absent between two present rows produces NO bar (no
##     empty-interval inference: whether an absent row means a no-trade
##     interval is UNVERIFIED vendor behavior).
import std/[strutils, algorithm]
import hcj, bars, calendars, vendor_input, rest_resp

type
  BackfillError* = object of CatchableError

proc berr(msg: string): ref BackfillError =
  newException(BackfillError, msg)

const backfillOrigin* = "BACKFILL"

proc parseSignedInt(name, text: string): int64 =
  ## A 부호가 포함된 숫자 field as an integer. The raw string stays
  ## preserved in the response bytes; the parsed value must be a possible
  ## market value: an optional "+" sign and digits, never a negative
  ## (prices and volumes cannot be negative — a "-" is a schema failure,
  ## fail-closed, not a silently used value). Leading zeros are value 0
  ## padding and parse naturally.
  if text.len == 0:
    raise berr(name & " is empty: a 부호가 포함된 숫자 field must carry digits")
  if text[0] == '-':
    raise berr(name & " is negative: a price/volume value cannot be " &
               "negative — the sign convention is preserved verbatim in " &
               "the recorded bytes, and an impossible value is a schema " &
               "failure (fail-closed): " & text)
  var body = if text[0] == '+': text[1 .. ^1] else: text
  if body.len == 0:
    raise berr(name & " is only a sign: " & text)
  for c in body.items:
    if c < '0' or c > '9':
      raise berr(name & " is not a 부호가 포함된 숫자 value: " & text)
  parseBiggestInt(body)

proc rowField(row: HcjValue; name: string): string =
  if not row.has(name) or row.get(name).kind != hkStr:
    raise berr("backfill row lacks the string field " & name)
  row.get(name).strVal

proc cntrTmBarTime(row: HcjValue; spec: SessionSpec; sessionDate: string):
                  tuple[idx: int, boundary: bool] =
  ## cntr_tm YYYYMMDDHHmmss -> (bar interval index, close_boundary) under
  ## the declared containing-interval placement rule (module header). The
  ## 14-digit shape, the digits and the session date are all validated
  ## fail-closed; the string itself is never re-encoded or stored.
  let tm = rowField(row, "cntr_tm")
  if tm.len != 14:
    raise berr("cntr_tm is not the documented YYYYMMDDHHmmss 14-digit " &
               "form: " & tm)
  for c in tm.items:
    if c < '0' or c > '9':
      raise berr("cntr_tm carries a non-digit: " & tm)
  if tm[0 .. 7] != sessionDate.replace("-", ""):
    raise berr("cntr_tm date " & tm[0 .. 7] & " is not the session date " &
               sessionDate & ": a backfill bar of another day cannot be " &
               "placed on this session's timeline (fail-closed)")
  let hh = parseInt(tm[8 .. 9])
  let mm = parseInt(tm[10 .. 11])
  let ss = parseInt(tm[12 .. 13])
  if hh > 23 or mm > 59 or ss > 59:
    raise berr("cntr_tm time-of-day is outside plausible ranges: " & tm)
  let t = hh * 3600 + mm * 60 + ss - spec.openSec
  let span = spec.bars * barSeconds
  if t < 0 or t > span:
    raise berr("cntr_tm " & tm & " is outside the session window: a " &
               "backfill bar outside [open, close] cannot be placed " &
               "(fail-closed)")
  if t == span:
    return (spec.bars - 1, true)
  (t div barSeconds, false)

proc barOfRow(symbol: string; row: HcjValue; spec: SessionSpec;
              sessionDate: string): Bar =
  ## One row -> one closed BACKFILL bar. Field mapping (official row
  ## schema): cur_prc -> close (현재가/종가, 부호 포함), open_pric/high_pric/
  ## low_pric -> open/high/low, trde_qty -> vol (the bar's own volume —
  ## acc_trde_qty is cumulative evidence, preserved in the raw bytes, never
  ## summed here), cntr_tm -> the interval placement. pred_pre/pred_pre_sig
  ## are preserved in the raw bytes only.
  let open = parseSignedInt("open_pric", rowField(row, "open_pric"))
  let high = parseSignedInt("high_pric", rowField(row, "high_pric"))
  let low = parseSignedInt("low_pric", rowField(row, "low_pric"))
  let close = parseSignedInt("cur_prc", rowField(row, "cur_prc"))
  let vol = parseSignedInt("trde_qty", rowField(row, "trde_qty"))
  if high < open or high < close or high < low:
    raise berr("high_pric is below an open/close/low value (symbol " &
               symbol & ", row cntr_tm " & rowField(row, "cntr_tm") &
               "): the documented 시고저가 semantics are violated — " &
               "fail-closed, never silently re-ordered")
  if low > open or low > close:
    raise berr("low_pric is above an open/close value (symbol " & symbol &
               ", row cntr_tm " & rowField(row, "cntr_tm") &
               "): the documented 시고저가 semantics are violated — " &
               "fail-closed, never silently re-ordered")
  let (idx, boundary) = cntrTmBarTime(row, spec, sessionDate)
  Bar(
    symbol: symbol,
    index: idx,
    open: open, high: high, low: low, close: close,
    vol: vol,
    ticks: 1,               ## one vendor row is one source observation
    pos: "steady",          ## the neutral live position: no subscription,
                            ## gap or ordering state exists on this path
    sessionClass: "in_session",
    volPartial: false,
    degraded: false,
    gapEdge: "",
    outOfOrder: false,
    closeBoundary: boundary,
    empty: false,
    closed: true,
    origin: backfillOrigin)

proc backfillBars*(attempts: seq[RestRespAttempt]; spec: SessionSpec;
                   sessionDate: string): seq[Bar] =
  ## The ka10080 attempts of a verified stream -> BACKFILL bars, sorted by
  ## (symbol, bar_index) exactly like closedBars. The attempts are the
  ## verifyAttempts output (chains already audited); rows are re-parsed
  ## from the preserved body bytes here, so a parse failure is still a
  ## failure (the caller wraps it fail-closed). Duplicate (symbol,
  ## interval) derivations — inside one chain, across chains, never
  ## merged silently — raise: no merge semantics are guessed (P22).
  var bars: seq[Bar]
  var seen: seq[tuple[symbol: string, idx: int]]
  for chain in ka10080Chains(attempts):
    for resp in chain.pages:
      for row in parsePageRows(ka10080Spec, resp):
        let bar = barOfRow(chain.query.stkCd, row, spec, sessionDate)
        for s in seen:
          if s.symbol == bar.symbol and s.idx == bar.index:
            raise berr("two ka10080 rows derive the same bar (symbol " &
                       bar.symbol & ", bar_index " & $bar.index &
                       "): a duplicate interval is a contract failure — " &
                       "the vendor's row duplication semantics are " &
                       "UNVERIFIED, so nothing is merged or overwritten " &
                       "(fail-closed)")
        seen.add((bar.symbol, bar.index))
        bars.add(bar)
  bars.sort(proc (x, y: Bar): int =
    let c = cmp(x.symbol, y.symbol)
    if c != 0: c else: cmp(x.index, y.index))
  bars

proc mergeBars*(live, backfill: seq[Bar]): seq[Bar] =
  ## LIVE and BACKFILL bars of one session -> the §7 bar set, sorted by
  ## (symbol, bar_index). A (symbol, interval) carried by both families is
  ## a contract failure: the session-mode merge semantics (P22:
  ## LATE_START/CLOSE_RECONCILIATION composition) are not declared, so the
  ## overlap is rejected fail-closed instead of guessed. With no overlap
  ## the merge is the plain sorted union.
  for bf in backfill:
    for lv in live:
      if lv.symbol == bf.symbol and lv.index == bf.index:
        raise berr("bar (symbol " & bf.symbol & ", bar_index " & $bf.index &
                   ") is derived BOTH live (ws ticks) and backfill " &
                   "(ka10080): the LIVE/BACKFILL merge semantics are a " &
                   "session-mode (P22) declaration that this stream does " &
                   "not carry — rejected fail-closed, never merged")
  result = live & backfill
  result.sort(proc (x, y: Bar): int =
    let c = cmp(x.symbol, y.symbol)
    if c != 0: c else: cmp(x.index, y.index))
