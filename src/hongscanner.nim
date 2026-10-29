## hongscanner CLI. Commands: selftest | replay | verify | doctor.
## Exit codes are the contract (docs/REPLAY_CONTRACT.md):
##   0 MATCH/OK, 2 contract violation, 3 calendar, 4 INCOMPLETE,
##   5 INVALID run, 6 artifact mismatch, 7 invalid provenance.
import std/[strutils, os, osproc]
import hs/[hcj, records, calendars, bars, engine, replay, verify, digest, binfo]

const usageText = """hongscanner <command>

  selftest                      run the committed smoke fixture end to end
  replay   --in <file> --out <dir>
                                replay an input stream into a run directory
  verify   --run <dir>          replay + byte compare + provenance check
  doctor                        environment, calendar and build checks
"""

proc fail(code: int; msg: string) =
  stderr.writeLine(msg)
  quit(code)

proc flagValue(args: seq[string]; name: string): string =
  for i in 0 ..< args.len - 1:
    if args[i] == name: return args[i + 1]
  ""

proc cmdReplay(input, outDir: string): int =
  if input.len == 0 or outDir.len == 0:
    fail(2, "replay requires --in and --out")
  var recs: seq[Record]
  try:
    recs = loadRecords(input)
    let res = runCore(recs)
    case res.status
    of rsIncomplete:
      fail(4, "REPLAY INCOMPLETE: session_end missing")
    of rsUnreliableFlag:
      fail(5, "REPLAY INVALID: SESSION_FLAG_UNRELIABLE " &
              $res.conflicts & "/" & $res.frames)
    of rsOk:
      discard
    discard writeRun(outDir, input, res)
    echo "REPLAY OK bars=", res.bars.len, " signals=", res.signals.len,
         " frames=", res.frames
    return 0
  except RecordError as e:
    fail(2, "REPLAY REJECT: " & e.msg)
  except HcjError as e:
    fail(2, "REPLAY REJECT: " & e.msg)
  except LateTickError as e:
    fail(5, "REPLAY INVALID: " & e.msg)
  except CoverageError as e:
    fail(3, "REPLAY REJECT: " & e.msg)
  except AlignError as e:
    fail(3, "REPLAY REJECT: " & e.msg)

proc cmdVerify(runDir: string): int =
  if runDir.len == 0 or not dirExists(runDir):
    fail(2, "verify requires an existing --run directory")
  let r = verifyRun(runDir)
  echo verdictLine(r)
  for issue in r.issues:
    stderr.writeLine("  issue: " & issue)
  exitCode(r.verdict)

proc cmdSelftest(): int =
  let fixture = "fixtures/smoke/input.hcj.jsonl"
  if not fileExists(fixture):
    fail(2, "selftest fixture missing: " & fixture)
  let tmp = getTempDir() / "hongscanner-selftest"
  if dirExists(tmp): removeDir(tmp)
  let recs = loadRecords(fixture)
  let res = runCore(recs)
  if res.status != rsOk:
    fail(4, "selftest replay did not complete")
  let fixtureInfo = BuildInfo(codeCommit: "fixture", sourceRef: "main",
    originMainSha: "fixture", dirty: false, nimVersion: NimVersion,
    buildTime: "fixture")
  discard writeRun(tmp, fixture, res, fixtureInfo)
  let v = verifyRun(tmp, fixtureInfo)
  if not v.matched:
    for issue in v.issues: stderr.writeLine("  issue: " & issue)
    fail(exitCode(v.verdict), "SELFTEST FAILED: " & verdictLine(v))
  echo "SELFTEST bytes=OK bars=", res.bars.len, " signals=", res.signals.len
  let real = verifyRun(tmp, buildInfo)
  echo "SELFTEST provenance=", (if real.matched: "OK" else: "NOT_CANONICAL")
  0

proc gitLine(args: string): string =
  let (outp, code) = execCmdEx("git " & args)
  if code != 0: return ""
  outp.strip()

proc cmdDoctor(): int =
  var problems = 0
  echo "BUILD commit=", buildInfo.codeCommit, " source_ref=", buildInfo.sourceRef,
       " origin_main=", buildInfo.originMainSha, " dirty=", buildInfo.dirty,
       " nim=", buildInfo.nimVersion
  echo "TOOLCHAIN nim=", NimVersion

  let head = gitLine("rev-parse HEAD")
  let originMain = gitLine("rev-parse origin/main")
  let porcelain = gitLine("status --porcelain")
  echo "GIT head=", head, " origin_main=", originMain,
       " clean=", (porcelain.len == 0)
  if head.len == 0 or originMain.len == 0:
    echo "GIT=UNKNOWN"; inc problems
  elif head != originMain:
    echo "GIT=NOT_CANONICAL_MAIN"; inc problems
  if porcelain.len != 0:
    echo "GIT=DIRTY_TREE"; inc problems
  if buildInfo.dirty or buildInfo.codeCommit == "dev":
    echo "BUILD=NOT_CANONICAL"; inc problems
  elif buildInfo.codeCommit != head:
    echo "BUILD=STALE"; inc problems

  var indexOk = true
  var calFiles: seq[string]
  let indexPath = "calendars" / "CALENDAR_INDEX.sha256"
  if fileExists(indexPath):
    for line in readHcjTextLines(indexPath):
      let parts = line.splitWhitespace()
      if parts.len != 2: indexOk = false; continue
      if not fileExists(parts[1]) or sha256Hex(readFile(parts[1])) != parts[0]:
        indexOk = false
      calFiles.add(parts[1])
    echo "CALENDAR_INDEX=", (if indexOk: "OK" else: "MISMATCH"),
         " files=", calFiles.len
    if not indexOk: inc problems
  else:
    echo "CALENDAR_INDEX=MISSING"; inc problems

  for path in walkFiles("calendars/*.json"):
    try:
      let cal = readDocFile(path)
      let (first, last) = firstLast(cal)
      var trading = 0
      for d in dayKeys(cal):
        if isTradingDay(cal, d): inc trading
      echo "CALENDAR ", path, " coverage=", first, "..", last,
           " trading_days=", trading
    except HcjError as e:
      echo "CALENDAR ", path, " UNREADABLE: ", e.msg; inc problems

  if problems == 0:
    echo "DOCTOR RESULT=OK"
    return 0
  if not indexOk:
    echo "DOCTOR RESULT=DEGRADED calendar"
    return 3
  echo "DOCTOR RESULT=DEGRADED build"
  7

proc main(): int =
  let args = commandLineParams()
  if args.len == 0:
    stdout.write(usageText)
    return 2
  case args[0]
  of "selftest": cmdSelftest()
  of "replay": cmdReplay(flagValue(args, "--in"), flagValue(args, "--out"))
  of "verify": cmdVerify(flagValue(args, "--run"))
  of "doctor": cmdDoctor()
  of "help", "--help", "-h":
    stdout.write(usageText)
    0
  else:
    stderr.writeLine("unknown command: " & args[0])
    stdout.write(usageText)
    2

when isMainModule:
  quit(main())