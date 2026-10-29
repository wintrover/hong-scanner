## Calendar-driven session window. No 09:00/15:30 constant lives in code.
## Contract: plan §3.2 (time rules) and §3.5 (trading-day judgement).
import std/[strutils, algorithm, options]
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

proc hmsToSec*(s: string): int =
  ## "HH:MM:SS+09:00" -> seconds since midnight. Offset must be +09:00.
  if s.len < 14 or s[8 .. ^1] != "+09:00":
    raise newException(CoverageError, "unsupported timestamp: " & s)
  let parts = s[0 .. 7].split(':')
  if parts.len != 3:
    raise newException(CoverageError, "bad timestamp: " & s)
  try:
    result = parseInt(parts[0]) * 3600 + parseInt(parts[1]) * 60 + parseInt(parts[2])
  except ValueError:
    raise newException(CoverageError, "bad timestamp: " & s)

proc dayKeys*(cal: HcjValue): seq[string] =
  let days = cal.get("days")
  if days.kind != hkObj:
    raise newException(CoverageError, "calendar has no days object")
  for p in days.pairs:
    result.add(p.k)

proc firstLast*(cal: HcjValue): tuple[first, last: string] =
  var ks = dayKeys(cal)
  if ks.len == 0: return ("", "")
  ks.sort()
  (ks[0], ks[^1])

proc sessionFor*(cal: HcjValue; date: string): SessionSpec =
  let days = cal.get("days")
  let dayOpt = days.getOpt(date)
  if dayOpt.isNone:
    raise newException(CoverageError, "CALENDAR_COVERAGE_UNKNOWN: " & date)
  let day = dayOpt.get
  if day.kind != hkObj:
    raise newException(CoverageError, "bad day record: " & date)
  if not day.has("open") or day.get("open").isNull:
    raise newException(CoverageError, "not a trading day: " & date)
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
  let days = cal.get("days")
  let d = days.getOpt(date)
  if d.isNone: return false
  let day = d.get
  day.kind == hkObj and day.has("open") and not day.get("open").isNull

proc inCoverage*(cal: HcjValue; date: string): bool =
  let (first, last) = firstLast(cal)
  first.len > 0 and date >= first and date <= last