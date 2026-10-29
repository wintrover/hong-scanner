## Calendar-driven session window. No 09:00/15:30 constant lives in code.
## Contract: plan §3.2 (time rules) and §3.5 (trading-day judgement).
import std/[algorithm, options]
import hcj

type
  SessionSpec* = object
    date*: string
    openSec*: int
    closeSec*: int
    bars*: int

  CoverageError* = object of CatchableError
  AlignError* = object of CatchableError

const barSeconds* = 180

proc twoDigits(s: string; i: int): int =
  ## Value of the two ASCII digits at s[i], s[i+1]; -1 when either is not.
  if s[i] >= '0' and s[i] <= '9' and s[i + 1] >= '0' and s[i + 1] <= '9':
    result = (ord(s[i]) - ord('0')) * 10 + (ord(s[i + 1]) - ord('0'))
  else:
    result = -1

proc hmsToSec*(s: string): int =
  ## "HH:MM:SS+09:00" -> seconds since midnight. Offset must be +09:00 and
  ## each field is exactly two digits: HH 00..23, MM 00..59, SS 00..59.
  if s.len != 14:
    raise newException(CoverageError, "unsupported timestamp: " & s)
  if s[2] != ':' or s[5] != ':' or s[8 .. ^1] != "+09:00":
    raise newException(CoverageError, "unsupported timestamp: " & s)
  let hh = twoDigits(s, 0)
  let mm = twoDigits(s, 3)
  let ss = twoDigits(s, 6)
  if hh < 0 or hh > 23 or mm < 0 or mm > 59 or ss < 0 or ss > 59:
    raise newException(CoverageError, "bad timestamp: " & s)
  result = hh * 3600 + mm * 60 + ss

proc daysOf*(cal: HcjValue): HcjValue =
  ## The `days` object of a calendar. A non-object calendar raw is an HCJ
  ## error (exit 2); a missing or non-object `days` is a calendar error
  ## (exit 3), like the other malformed-calendar checks below.
  if cal.kind != hkObj:
    raise newHcjError("expected object, got " & cal.kindName)
  if not cal.has("days") or cal.get("days").kind != hkObj:
    raise newException(CoverageError, "calendar has no days object")
  result = cal.get("days")

proc dayKeys*(cal: HcjValue): seq[string] =
  for p in daysOf(cal).pairs:
    result.add(p.k)

proc firstLast*(cal: HcjValue): tuple[first, last: string] =
  var ks = dayKeys(cal)
  if ks.len == 0: return ("", "")
  ks.sort()
  (ks[0], ks[^1])

proc sessionFor*(cal: HcjValue; date: string): SessionSpec =
  let days = daysOf(cal)
  let dayOpt = days.getOpt(date)
  if dayOpt.isNone:
    raise newException(CoverageError, "CALENDAR_COVERAGE_UNKNOWN: " & date)
  let day = dayOpt.get
  if day.kind != hkObj:
    raise newException(CoverageError, "bad day record: " & date)
  if not day.has("open") or day.get("open").isNull:
    raise newException(CoverageError, "not a trading day: " & date)
  if not day.has("close") or day.get("close").isNull:
    raise newException(CoverageError, "bad day record: " & date)
  if day.get("open").kind != hkStr or day.get("close").kind != hkStr:
    raise newException(CoverageError, "bad day record: " & date)
  let o = hmsToSec(day.get("open").asStr)
  let c = hmsToSec(day.get("close").asStr)
  if c <= o:
    raise newException(CoverageError, "empty session: " & date)
  let span = c - o
  if span mod barSeconds != 0:
    raise newException(AlignError,
      "SESSION_NOT_BAR_ALIGNED: " & date & " span=" & $span)
  result = SessionSpec(date: date, openSec: o, closeSec: c,
                       bars: span div barSeconds)

proc isTradingDay*(cal: HcjValue; date: string): bool =
  let d = daysOf(cal).getOpt(date)
  if d.isNone: return false
  let day = d.get
  day.kind == hkObj and day.has("open") and not day.get("open").isNull

proc inCoverage*(cal: HcjValue; date: string): bool =
  let (first, last) = firstLast(cal)
  first.len > 0 and date >= first and date <= last