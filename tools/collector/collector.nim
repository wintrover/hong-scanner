## collector: the VS-2 live collector binary (tools/collector/README.md).
##
## Owns the sidecar process and the Recorder; the judgment authority is
## src/hs/collector.nim (one sidecar line in, records + directives out).
## This file adds the adapter-boundary pieces the core must not have: the
## subprocess, the record file, the 60 s syncNow heartbeat and the exit
## codes (README §8):
##   0  normal — drain_done -> recorder.finish() (seal + COMMITTED marker)
##      -> stop -> sidecar exit 0;
##   2  usage or pipe-protocol violation — nothing is sealed, the file is
##      preserved via abandon();
##   4  INCOMPLETE — the honest failure: finish() is never called, the
##      unsealed file is preserved (exit codes; GATES: INCOMPLETE never
##      becomes success).
##
## Usage: collector --profile <alias> --session-date YYYY-MM-DD --out <dir>
##                [--calendar=<path>] [--mrkt-tp=000] ... (declared query
##                scope, approved PH-1 values by default).
import std/[os, osproc, strutils, posix, times, streams]
import hs/[hcj, records, calendars, engine, collector, recorder]

const usageText = """collector — the VS-2 live collector (demo, PH-1)

  collector --profile <alias> --session-date YYYY-MM-DD --out <dir>
            [--calendar=calendars/krx-2026q4.json]
            [--mrkt-tp=000 --trde-qty-cnd=0000 --stk-cnd=0 --crd-cnd=0
             --updown-incls=1 --pric-cnd=0 --trde-prica-cnd=0 --stex-tp=1]
            [--lookback=3 --pullback-min-bp=50 --recovery-bp=30
             --rebound-min-bp=50 --breakdown-bp=30 --warmup-bars=0
             --hold-on-degraded=1]

Exit codes: 0 normal, 2 usage/contract, 4 INCOMPLETE (unsealed, preserved).
"""

proc fail(code: int; msg: string) {.noreturn.} =
  stderr.writeLine(msg)
  quit(code)

proc argValue(args: seq[string]; name: string): string =
  for a in args:
    if a.startsWith("--" & name & "="):
      return a[("--" & name & "=").len .. ^1]
  ""

proc defaultStr(v, d: string): string =
  if v.len == 0: d else: v

proc defaultInt(v: string; d: int; name: string): int =
  if v.len == 0: return d
  try:
    parseInt(v)
  except ValueError:
    fail(2, "collector: --" & name & " must be an integer")

proc argFlag(args: seq[string]; name: string): bool =
  "--" & name in args

# ---------------------------------------------------------------- sidecar

proc pythonCmd(): string =
  ## The sidecar interpreter: $HSCOLLECTOR_PYTHON, then the slice's venv,
  ## then the system python3 (the venv is what test_sidecar.sh guarantees;
  ## a live run needs websockets installed wherever this resolves).
  let env = getEnv("HSCOLLECTOR_PYTHON")
  if env.len > 0:
    return env
  let venvPython = getAppDir() / ".venv" / "bin" / "python"
  if fileExists(venvPython):
    return venvPython
  "python3"

proc sidecarScript(): string =
  for candidate in [getAppDir() / "sidecar.py",
                    "tools" / "collector" / "sidecar.py"]:
    if fileExists(candidate):
      return candidate
  fail(2, "sidecar.py not found next to the binary or in the repository")

# ------------------------------------------------------------- pipe input

type
  ReadResult* = enum rrLine, rrTimeout, rrEof
  PipeReader = object
    fd: cint
    acc: string
    eof: bool

proc pollFd(fd: cint; timeoutMs: int): bool =
  var pfd: TPollfd
  pfd.fd = fd
  pfd.events = POLLIN
  let n = posix.poll(addr pfd, 1, cint(timeoutMs))
  # POLLHUP (the last writer closed the pipe) and POLLERR are ready too:
  # a pipe at end-of-file may report POLLHUP without POLLIN (measured on
  # kernel 6.17: events=16), and read() then answers the EOF. Treating it
  # as a timeout made readLine return rrTimeout forever — the collector
  # spun instead of going honestly INCOMPLETE when the sidecar died
  # mid-session (found by the process-pair drill).
  result = n > 0 and
    (pfd.revents and (POLLIN or POLLHUP or POLLERR)) != 0

proc readLine(r: var PipeReader; timeoutMs: int): (ReadResult, string) =
  ## One LF-terminated line, a timeout (for the syncNow heartbeat), or EOF.
  ## Never returns a partial line as a record: EOF carries the remainder,
  ## which the caller refuses.
  while true:
    let nl = find(r.acc, '\n')
    if nl >= 0:
      result = (rrLine, r.acc[0 ..< nl])
      # Consume the returned line: without this the next call would find
      # the same newline again and re-deliver the first line forever
      # (found by the process-pair drill; a session could never get past
      # its first event).
      r.acc = r.acc[nl + 1 ..< r.acc.len]
      return
    if r.eof:
      if r.acc.len == 0:
        return (rrEof, "")
      result = (rrEof, r.acc)
      r.acc = ""
      return
    if not pollFd(r.fd, timeoutMs):
      return (rrTimeout, "")
    var chunk: array[65536, char]
    let n = posix.read(r.fd, addr chunk[0], chunk.len)
    if n < 0:
      if errno == EINTR:
        continue
      raise newException(IOError, "sidecar stdout read failed: " &
        $strerror(errno))
    if n == 0:
      r.eof = true
      continue
    for i in 0 ..< n:
      r.acc.add(chunk[i])

# ------------------------------------------------------------------- main

proc main(): int =
  let args = commandLineParams()
  if args.len == 0 or argFlag(args, "help") or argFlag(args, "h"):
    stdout.write(usageText)
    return 2
  let profile = argValue(args, "profile")
  let sessionDate = argValue(args, "session-date")
  let outDir = argValue(args, "out")
  let calendarPath = argValue(args, "calendar")
  if profile.len == 0 or sessionDate.len == 0 or outDir.len == 0:
    fail(2, "collector requires --profile, --session-date and --out")
  if calendarPath.len == 0:
    fail(2, "collector requires --calendar (the approved snapshot)")
  # createDir is pure creation: it never destroys an existing directory's
  # content, and openRecorder refuses an existing input file outright.
  try:
    createDir(outDir)
  except OSError as e:
    fail(2, "cannot create the run directory: " & outDir & ": " & e.msg)
  if not dirExists(outDir):
    fail(2, "run directory is not a directory: " & outDir)

  var cfg: CollectorConfig
  try:
    cfg = initCollectorConfig(
      sessionDate, "demo", profile,
      argValue(args, "mrkt-tp").defaultStr("000"),
      argValue(args, "trde-qty-cnd").defaultStr("0000"),
      argValue(args, "stk-cnd").defaultStr("0"),
      argValue(args, "crd-cnd").defaultStr("0"),
      argValue(args, "updown-incls").defaultStr("1"),
      argValue(args, "pric-cnd").defaultStr("0"),
      argValue(args, "trde-prica-cnd").defaultStr("0"),
      argValue(args, "stex-tp").defaultStr("1"),
      Params(
        lookback: argValue(args, "lookback").defaultInt(3, "lookback"),
        pullbackMinBp: argValue(args, "pullback-min-bp").defaultInt(50,
          "pullback-min-bp"),
        recoveryBp: argValue(args, "recovery-bp").defaultInt(30, "recovery-bp"),
        reboundMinBp: argValue(args, "rebound-min-bp").defaultInt(50,
          "rebound-min-bp"),
        breakdownBp: argValue(args, "breakdown-bp").defaultInt(30,
          "breakdown-bp"),
        warmupBars: argValue(args, "warmup-bars").defaultInt(0, "warmup-bars"),
        holdOnDegraded:
          argValue(args, "hold-on-degraded").defaultInt(1,
            "hold-on-degraded") != 0),
      readDocFile(calendarPath))
  except CollectorError as e:
    fail(2, "COLLECTOR CONFIG: " & e.msg)
  except CoverageError as e:
    fail(3, "COLLECTOR CALENDAR: " & e.msg)
  except HcjError as e:
    fail(2, "COLLECTOR CALENDAR unreadable: " & e.msg)
  except IOError as e:
    fail(2, "COLLECTOR CALENDAR unreadable: " & e.msg)

  var rec: Recorder
  let inputPath = outDir / "input.hcj.jsonl"
  try:
    rec = openRecorder(inputPath)
  except RecorderError as e:
    fail(2, "COLLECTOR RECORDER: " & e.msg)

  # Launch the sidecar (no shell): its stderr stays ours for diagnosis; its
  # stdout is the event pipe, its stdin the command pipe.
  let p = startProcess(pythonCmd(), args = @[sidecarScript()],
                       options = {poUsePath})
  defer:
    try:
      p.close()
    except CatchableError:
      discard

  proc send(cmdLine: string): bool =
    ## One command line to the sidecar; false when the pipe is broken.
    try:
      p.inputStream().write(cmdLine & "\n")
      p.inputStream().flush()
      true
    except CatchableError:
      false

  var c = startCollector(cfg)
  try:
    if not send(cfg.initLine()):
      rec.abandon()
      fail(4, "COLLECTOR INCOMPLETE: the sidecar stdin broke at init")
    for (kind, raw) in cfg.preambleRecords():
      discard rec.append(kind, raw)
  except RecorderError as e:
    try:
      rec.abandon()
    except CatchableError:
      discard
    fail(4, "COLLECTOR INCOMPLETE: the recorder failed during the preamble: " &
      e.msg)

  var reader = PipeReader(fd: p.outputHandle())
  var nextSync = epochTime() + 60.0
  var stopSent = false

  template preserveAndExit(code: int; msg: string) {.dirty.} =
    try:
      rec.abandon()
    except CatchableError:
      discard
    if not stopSent:
      discard send(Directive(kind: dkStop).directiveLine())
    try:
      p.inputStream().close()
    except CatchableError:
      discard
    let sc = p.peekExitCode()
    if sc == -1:
      discard p.waitForExit()
    fail(code, msg)

  while not stopSent:
    let now = epochTime()
    let waitMs = int(clamp(nextSync - now, 0.0, 60.0) * 1000.0)
    var (res, line) = reader.readLine(waitMs)
    case res
    of rrTimeout:
      try:
        rec.syncNow()
      except RecorderError as e:
        stderr.writeLine("COLLECTOR sync failed (no byte changed): " & e.msg)
      nextSync = epochTime() + 60.0
      continue
    of rrEof:
      if c.done:
        break
      # The sidecar died mid-session (or sent a torn final fragment): the
      # stream stays unsealed — INCOMPLETE, never a silent pass.
      var gapRecords: seq[RecOut]
      discard c.goIncomplete(gapRecords, $now(),
        "the sidecar pipe closed before the termination protocol completed " &
        "(exit code " & $p.peekExitCode() & ")")
      try:
        for (kind, raw) in gapRecords:
          discard rec.append(kind, raw)
      except RecorderError:
        discard
      preserveAndExit(4, "COLLECTOR INCOMPLETE: the sidecar pipe closed " &
        "before the termination protocol completed")
    of rrLine:
      if line.len == 0:
        continue
      nextSync = epochTime() + 60.0
      var recs: seq[RecOut]
      var directives: seq[Directive]
      try:
        directives = c.handleEvent(line, recs)
      except CatchableError as e:
        preserveAndExit(2, "COLLECTOR CONTRACT: " & e.msg)
      try:
        for (kind, raw) in recs:
          discard rec.append(kind, raw)
      except RecorderError as e:
        preserveAndExit(4, "COLLECTOR INCOMPLETE: the recorder refused a " &
          "record; preserve and inspect the file: " & e.msg)
      if c.done and not rec.finished():
        # §8 normal order: finish() (seal + COMMITTED marker) BEFORE stop.
        try:
          discard rec.finish()
        except CatchableError as e:
          preserveAndExit(4, "COLLECTOR INCOMPLETE: the finish protocol " &
            "did not reach the COMMITTED marker: " & e.msg)
      for d in directives:
        if not send(d.directiveLine()):
          if not c.done:
            preserveAndExit(4, "COLLECTOR INCOMPLETE: the sidecar stdin " &
              "broke while sending a directive")
        if d.kind == dkStop:
          stopSent = true

  if c.incomplete:
    preserveAndExit(4, "COLLECTOR INCOMPLETE: " & c.incompleteReason)

  # Normal path: the seal is on disk; wait for the sidecar's own exit.
  p.inputStream().close()
  let sidecarCode = p.waitForExit()
  if sidecarCode != 0:
    fail(4, "COLLECTOR INCOMPLETE: the sidecar exited " & $sidecarCode &
      " after stop (the stream is sealed; inspect the run directory)")
  echo "COLLECTOR DONE records=", rec.seqNo()
  0

when isMainModule:
  quit(main())
