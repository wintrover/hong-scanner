## Provenance/verify contract regression tests (VS-1, plan §3.4,
## docs/REPLAY_CONTRACT.md §7-§9). Synthetic inputs only: no network, no
## real market data, no wall clock. Run:
##   nim c -r --path:src tests/test_provenance_contract.nim
##
## Covers: the five documented provenance checks, missing fields, malformed
## (wrong-type) fields, dev-marker escapes, missing artifacts, the
## fail-closed writeRun output guard, and the documented limit that a
## self-consistent forged BuildInfo still matches.
##
## The writeRun blocks below also regress the non-destructive atomicity of
## the exclusive-creation write: a symlink at (or swapped into) the output
## path, a symlink planted at an artifact name after the guard, and
## parallel writeRun calls racing on one empty directory must all end in a
## refusal that destroys no byte of existing data. Those races need real
## parallel processes, so the test binary re-executes itself as children
## (see HS_PROV_ATTACK).
import std/[os, strutils, algorithm, tempfiles]
import hs/[hcj, digest, records, calendars, bars, engine, replay, verify, binfo]

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

proc joinLines(lines: seq[string]): string =
  for l in lines: result.add(l & "\n")

proc workDir(name: string): string =
  ## Unique, exclusively created scratch dir: a fixed predictable path plus
  ## removeDir would follow a pre-planted symlink and destroy foreign data.
  createTempDir("hs-prov-" & name & "-", "")

proc materialize(dir, name: string; lines: seq[string]): string =
  result = dir / name
  writeFile(result, joinLines(lines))

proc recLines(pairs: seq[tuple[k: Kind, raw: HcjValue]]): seq[string] =
  for i, p in pairs: result.add(makeRecordLine(i + 1, p.k, p.raw))

proc pairsOf(lines: seq[string]): seq[tuple[k: Kind, raw: HcjValue]] =
  let path = materialize(workDir("pairs-src"), "in.hcj.jsonl", lines)
  for r in loadRecords(path): result.add((r.kind, r.raw))

let fixtureDir = "fixtures/smoke"
let baseLines = readHcjTextLines(fixtureDir / "input.hcj.jsonl")
let inputPath = materialize(workDir("src"), "input.hcj.jsonl",
                            recLines(pairsOf(baseLines)))

proc infoVariant(commit = "abc123"; srcRef = "main"; origin = "abc123";
                 dirty = false; nim = NimVersion;
                 buildTime = "2026-10-29T09:00:00Z"): BuildInfo =
  BuildInfo(codeCommit: commit, sourceRef: srcRef, originMainSha: origin,
            dirty: dirty, nimVersion: nim, buildTime: buildTime)

# ---------------------------------------------------------------------------
# Child mode for the concurrency/TOCTOU regression tests below: the test
# binary re-executes itself as real parallel processes. One test process
# cannot open the guard-to-write window; separate processes can, and can do
# so deterministically: writeRun reads its input at least twice after the
# guard, and when that input is a FIFO the child blocks mid-window until the
# parent feeds it. Two feeds on one FIFO would merge into one read if the
# writer paired with the previous (still open) reader, so the harness feeds
# again only after an ENXIO probe proves the child closed its read, and uses
# an input large enough that the child's read->parse->read transitions are
# observably slow (see bigInputBytes).
when defined(posix):
  import std/[osproc, posix]

  proc cMkfifo(path: cstring; mode: Mode): cint {.
      importc: "mkfifo", header: "<sys/stat.h>".}

  var bigInputCache = ""

  proc bigInputBytes(): string =
    ## The smoke fixture padded with 20000 diagnostic ws_conn records
    ## (contract section 2, rule 3: no effect on Core output). Parsing it
    ## takes tens of milliseconds, which makes the child's fifo-read
    ## transitions wide enough for the parent to observe deterministically.
    if bigInputCache.len > 0:
      return bigInputCache
    let base = pairsOf(baseLines)
    var pairs: seq[tuple[k: Kind, raw: HcjValue]]
    pairs.add(base[0])
    pairs.add(base[1])
    for i in 0 ..< 20000:
      pairs.add((kWsConn, hObj(("state", hStr("reconnecting")))))
    for i in 2 ..< base.len:
      pairs.add(base[i])
    bigInputCache = joinLines(recLines(pairs))
    result = bigInputCache

  proc provChildMain(): int =
    let mode = getEnv("HS_PROV_ATTACK")
    let outDir = getEnv("HS_PROV_OUT")
    let inPath = getEnv("HS_PROV_IN")
    let winPath = getEnv("HS_PROV_WIN")
    if mode == "race":
      # Barrier: hold every racer back until the parent has spawned them
      # all, so the burst really lands on the same empty directory at once.
      var armed = false
      for i in 0 ..< 15000:
        if fileExists(getEnv("HS_PROV_GO")):
          armed = true
          break
        sleep(2)
      if not armed:
        return 8
    try:
      let res = runCore(loadRecords(inPath))
      discard writeRun(outDir, winPath, res, infoVariant())
      return 0
    except OutputGuardError as e:
      stderr.writeLine("prov-child guard refusal: " & e.msg)
      return 3
    except CatchableError as e:
      stderr.writeLine("prov-child unexpected error: " & $e.name & ": " & e.msg)
      return 4

  proc spawnProvChild(mode, outDir, inPath, winPath, goPath: string): Process =
    putEnv("HS_PROV_ATTACK", mode)
    putEnv("HS_PROV_OUT", outDir)
    putEnv("HS_PROV_IN", inPath)
    putEnv("HS_PROV_WIN", winPath)
    putEnv("HS_PROV_GO", goPath)
    startProcess(getAppFilename(), "", [], nil, {poParentStreams})

  proc waitProvChild(p: Process): int =
    ## Watchdogged wait: a hung child (the bug these tests hunt) must fail
    ## the test, not hang the suite.
    var waited = 0
    while running(p):
      sleep(100)
      inc waited
      if waited > 300:
        kill(p)
        break
    result = waitForExit(p)

  proc openFifoWriter(path: string): cint =
    ## Pair with the FIFO's next reader without hanging forever if the child
    ## dies first: poll a nonblocking O_WRONLY open (ENXIO while no reader
    ## holds the FIFO). The fd stays nonblocking; writeFdAll copes.
    for i in 0 ..< 15000:
      result = open(path, O_WRONLY or O_NONBLOCK or O_CLOEXEC)
      if result >= 0:
        return
      if errno != ENXIO:
        raise newException(IOError, "open fifo writer: " & $strerror(errno))
      sleep(2)
    raise newException(IOError, "timed out waiting for the fifo reader")

  proc writeFdAll(fd: cint; data: string) =
    var off = 0
    while off < data.len:
      let n = write(fd, addr data[off], data.len - off)
      if n > 0:
        inc off, n
      elif n < 0 and (errno == EINTR or errno == EAGAIN):
        sleep(1)
      else:
        raise newException(IOError, "fifo write failed: " & $strerror(errno))

  proc closeFd(fd: cint) =
    discard close(fd)

  proc readerClosed(path: string): bool =
    ## True while no reader holds the FIFO open (nonblocking O_WRONLY open
    ## fails with ENXIO). Guards the second feed against merging with the
    ## child's previous, still-open read.
    let fd = open(path, O_WRONLY or O_NONBLOCK or O_CLOEXEC)
    if fd >= 0:
      discard close(fd)
      return false
    if errno == ENXIO:
      return true
    raise newException(IOError, "probe fifo reader: " & $strerror(errno))

  proc feedSecondFifo(fifo, data: string) =
    ## Feed the child's next writeRun read: first wait for the previous read
    ## to close, then pair with the next one.
    var closed = false
    for i in 0 ..< 30000:
      if readerClosed(fifo):
        closed = true
        break
      sleep(1)
    if not closed:
      raise newException(IOError, "child never closed its previous fifo read")
    let w = openFifoWriter(fifo)
    writeFdAll(w, data)
    closeFd(w)

  proc countEntries(dir: string): int =
    for kind, path in walkDir(dir):
      inc result

  if getEnv("HS_PROV_ATTACK").len > 0:
    quit(provChildMain())

proc makeRun(name: string; bi: BuildInfo): string =
  let res = runCore(loadRecords(inputPath))
  doAssert res.status == rsOk, "smoke fixture must replay OK"
  result = workDir(name) / "run"
  discard writeRun(result, inputPath, res, bi)

proc loadRunJson(runDir: string): HcjValue =
  parseDoc(readFile(runDir / "run.json"))

proc saveRunJson(runDir: string; rj: HcjValue) =
  writeFile(runDir / "run.json", canonical(rj) & "\n")

proc dropKey(v: HcjValue; key: string) =
  for i in 0 ..< v.pairs.len:
    if v.pairs[i].k == key:
      v.pairs.delete(i)
      return

proc setKey(v: HcjValue; key: string; nv: HcjValue) =
  for p in v.pairs.mitems:
    if p.k == key: p.v = nv

proc mutRun(name: string; mutate: proc (rj: HcjValue);
            bi: BuildInfo = infoVariant()): string =
  ## Fresh run dir per case: verify reads everything back from disk.
  let runDir = makeRun(name, bi)
  var rj = loadRunJson(runDir)
  mutate(rj)
  saveRunJson(runDir, rj)
  result = runDir

proc tryVerify(runDir: string; bi: BuildInfo): tuple[r: VerifyResult; crashed: bool] =
  ## verifyRun must answer with a contract verdict, never with an exception.
  try:
    result.r = verifyRun(runDir, bi)
    result.crashed = false
  except CatchableError as e:
    result.r = VerifyResult(verdict: vInvalid,
                            issues: @["verifyRun raised: " & e.msg])
    result.crashed = true

proc checkProv(name, runDir: string; bi: BuildInfo = infoVariant()) =
  let tv = tryVerify(runDir, bi)
  check(name, (not tv.crashed) and tv.r.verdict == vInvalidProvenance and
        exitCode(tv.r.verdict) == 7)

proc checkMismatch(name, runDir: string; bi: BuildInfo = infoVariant()) =
  let tv = tryVerify(runDir, bi)
  check(name, (not tv.crashed) and tv.r.verdict == vMismatch and
        exitCode(tv.r.verdict) == 6)

# ---------------------------------------------------------- baseline
block baseline:
  let runDir = makeRun("baseline", infoVariant())
  let tv = tryVerify(runDir, infoVariant())
  check("canonical run verifies MATCH provenance=OK",
        (not tv.crashed) and tv.r.verdict == vMatch and tv.r.matched and
        verdictLine(tv.r) == "VERDICT MATCH provenance=OK" and
        exitCode(tv.r.verdict) == 0)

# ------------------------------------ the five documented checks (§8)
block fiveChecks:
  var d = mutRun("run-dirty", proc (rj: HcjValue) =
    setKey(rj.get("build"), "dirty", hBool(true)))
  checkProv("run.json build.dirty=true is INVALID_PROVENANCE", d)

  d = mutRun("run-ref", proc (rj: HcjValue) =
    setKey(rj.get("build"), "source_ref", hStr("feat/x")))
  checkProv("run.json source_ref=feat/x is INVALID_PROVENANCE", d)

  d = mutRun("run-nim", proc (rj: HcjValue) =
    setKey(rj.get("build"), "nim_version", hStr("2.2.9")))
  checkProv("run.json nim_version=2.2.9 is INVALID_PROVENANCE", d)

  d = mutRun("run-commit", proc (rj: HcjValue) =
    setKey(rj, "code_commit", hStr("zzz")))
  checkProv("run.json code_commit != binary is INVALID_PROVENANCE", d)

  d = mutRun("run-oms", proc (rj: HcjValue) =
    setKey(rj.get("build"), "origin_main_sha", hStr("yyy")))
  checkProv("run.json origin_main_sha != code_commit is INVALID_PROVENANCE", d)

  d = mutRun("run-sd", proc (rj: HcjValue) =
    setKey(rj, "session_date", hStr("2026-10-30")))
  checkProv("run.json session_date != config is INVALID_PROVENANCE", d)

  d = mutRun("run-cal", proc (rj: HcjValue) =
    setKey(rj, "calendar_sha256", hStr("00".repeat(32))))
  checkProv("wrong calendar_sha256 is INVALID_PROVENANCE", d)

  d = mutRun("run-cfg", proc (rj: HcjValue) =
    setKey(rj, "config_sha256", hStr("00".repeat(32))))
  checkProv("wrong config_sha256 is INVALID_PROVENANCE", d)

  let b = makeRun("bin-variants", infoVariant())
  checkProv("binary dirty=true is INVALID_PROVENANCE", b, infoVariant(dirty = true))
  checkProv("binary source_ref=feat/x is INVALID_PROVENANCE", b, infoVariant(srcRef = "feat/x"))
  checkProv("binary nim_version=2.2.9 is INVALID_PROVENANCE", b, infoVariant(nim = "2.2.9"))
  checkProv("binary origin_main_sha != code_commit is INVALID_PROVENANCE", b, infoVariant(origin = "zzz"))

# --------------------------------------------- missing run.json fields
block missingFields:
  var d = mutRun("miss-dirty", proc (rj: HcjValue) =
    dropKey(rj.get("build"), "dirty"))
  checkProv("missing build.dirty is INVALID_PROVENANCE (missing != false)", d)

  d = mutRun("miss-commit", proc (rj: HcjValue) = dropKey(rj, "code_commit"))
  checkProv("missing code_commit is INVALID_PROVENANCE", d)

  d = mutRun("miss-nim", proc (rj: HcjValue) =
    dropKey(rj.get("build"), "nim_version"))
  checkProv("missing build.nim_version is INVALID_PROVENANCE", d)

  d = mutRun("miss-ref", proc (rj: HcjValue) =
    dropKey(rj.get("build"), "source_ref"))
  checkProv("missing build.source_ref is INVALID_PROVENANCE", d)

  d = mutRun("miss-oms", proc (rj: HcjValue) =
    dropKey(rj.get("build"), "origin_main_sha"))
  checkProv("missing build.origin_main_sha is INVALID_PROVENANCE", d)

  d = mutRun("miss-cal", proc (rj: HcjValue) = dropKey(rj, "calendar_sha256"))
  checkProv("missing calendar_sha256 is INVALID_PROVENANCE", d)

  d = mutRun("miss-cfg", proc (rj: HcjValue) = dropKey(rj, "config_sha256"))
  checkProv("missing config_sha256 is INVALID_PROVENANCE", d)

  d = mutRun("miss-sd", proc (rj: HcjValue) = dropKey(rj, "session_date"))
  checkProv("missing session_date is INVALID_PROVENANCE", d)

  d = mutRun("miss-build", proc (rj: HcjValue) = dropKey(rj, "build"))
  checkProv("missing build object is INVALID_PROVENANCE", d)

  d = makeRun("miss-runjson", infoVariant())
  removeFile(d / "run.json")
  checkProv("missing run.json is INVALID_PROVENANCE", d)

# --------------------------------- malformed run.json fields (types)
block malformedFields:
  var d = mutRun("mal-commit", proc (rj: HcjValue) =
    setKey(rj, "code_commit", hInt(123)))
  checkProv("code_commit as int is INVALID_PROVENANCE, not a crash", d)

  d = mutRun("mal-commit-null", proc (rj: HcjValue) =
    setKey(rj, "code_commit", hNull()))
  checkProv("code_commit as null is INVALID_PROVENANCE", d)

  d = mutRun("mal-dirty", proc (rj: HcjValue) =
    setKey(rj.get("build"), "dirty", hStr("false")))
  checkProv("build.dirty as string is INVALID_PROVENANCE, not a crash", d)

  d = mutRun("mal-nim", proc (rj: HcjValue) =
    setKey(rj.get("build"), "nim_version", hInt(2)))
  checkProv("build.nim_version as int is INVALID_PROVENANCE, not a crash", d)

  d = mutRun("mal-ref", proc (rj: HcjValue) =
    setKey(rj.get("build"), "source_ref", hNull()))
  checkProv("build.source_ref as null is INVALID_PROVENANCE, not a crash", d)

  d = mutRun("mal-oms", proc (rj: HcjValue) =
    setKey(rj.get("build"), "origin_main_sha", hBool(true)))
  checkProv("origin_main_sha as bool is INVALID_PROVENANCE, not a crash", d)

  d = mutRun("mal-cal", proc (rj: HcjValue) =
    setKey(rj, "calendar_sha256", hInt(7)))
  checkProv("calendar_sha256 as int is INVALID_PROVENANCE, not a crash", d)

  d = mutRun("mal-cfg", proc (rj: HcjValue) =
    setKey(rj, "config_sha256", hArr()))
  checkProv("config_sha256 as array is INVALID_PROVENANCE, not a crash", d)

  d = mutRun("mal-sd", proc (rj: HcjValue) =
    setKey(rj, "session_date", hInt(20261029)))
  checkProv("session_date as int is INVALID_PROVENANCE, not a crash", d)

  d = mutRun("mal-build", proc (rj: HcjValue) =
    setKey(rj, "build", hStr("x")))
  checkProv("build as string is INVALID_PROVENANCE", d)

  d = makeRun("mal-json-top", infoVariant())
  writeFile(d / "run.json", "[1]\n")
  checkProv("run.json top-level array is INVALID_PROVENANCE", d)

  d = makeRun("mal-json-doc", infoVariant())
  writeFile(d / "run.json", "{invalid")
  checkProv("unparsable run.json is INVALID_PROVENANCE", d)

# ------------------------------------------- dev-marker escapes
block devMarkers:
  # Partial hand injection: only source_ref and dirty were faked; the
  # commit/origin/time still carry the "dev" default. All five documented
  # comparisons agree, so this must still be rejected by the dev marker.
  let partial = infoVariant(commit = "dev", srcRef = "main", origin = "dev",
                            dirty = false, buildTime = "dev")
  let d1 = makeRun("dev-partial", partial)
  checkProv("partially injected dev-marker build never reaches provenance=OK", d1, partial)

  let timeOnly = infoVariant(buildTime = "dev")
  let d2 = makeRun("dev-time", timeOnly)
  checkProv("dev-marker build_time never reaches provenance=OK", d2, timeOnly)

  let d3 = makeRun("dev-default", infoVariant())
  checkProv("checked-in dev build info is INVALID_PROVENANCE", d3, buildInfo)

# ------------------------------------------------- missing artifacts
block missingArtifacts:
  var d = makeRun("art-bars", infoVariant())
  removeFile(d / "bars.hcj.jsonl")
  checkMismatch("missing bars.hcj.jsonl is MISMATCH exit 6", d)

  d = makeRun("art-sigs", infoVariant())
  removeFile(d / "signals.hcj.jsonl")
  removeFile(d / "CHECKSUMS.sha256")
  checkMismatch("missing signals + manifest is MISMATCH exit 6", d)

  d = makeRun("art-input", infoVariant())
  removeFile(d / "input.hcj.jsonl")
  checkMismatch("missing input.hcj.jsonl is MISMATCH exit 6, not a crash", d)

  d = makeRun("art-tamper", infoVariant())
  var lines = readHcjTextLines(d / "signals.hcj.jsonl")
  lines[0] = lines[0].replace("\"price\":", "\"price\":1")
  writeFile(d / "signals.hcj.jsonl", joinLines(lines))
  checkMismatch("tampered signal bytes are MISMATCH exit 6", d)

# ------------------------------------------ UnresolvedGapError verdict
block unresolvedGapVerdict:
  ## A gap still pending at session_end never lets a run pass as OK: Core
  ## raises UnresolvedGapError. `verify` must classify it INCOMPLETE
  ## (exit 4) -- the same exit code `replay`/`selftest` already use -- and
  ## report the unresolved symbols, never a generic contract rejection.
  let base = pairsOf(baseLines)
  var pairs: seq[tuple[k: Kind, raw: HcjValue]]
  pairs.add(base[0])
  pairs.add(base[1])
  # One frame for 005930, a symbol-specific gap, then only another
  # symbol's frames: 005930 never confirms its own gap, so the run fails
  # closed at session_end (contract section 5).
  pairs.add((kWsFrame, hObj(("m", hStr("2")), ("price", hInt(100)),
                            ("symbol", hStr("005930")),
                            ("t", hStr("09:00:30+09:00")), ("vol", hInt(100)))))
  pairs.add((kGap, hObj(("symbol", hStr("005930")))))
  pairs.add((kWsFrame, hObj(("m", hStr("2")), ("price", hInt(200)),
                            ("symbol", hStr("000660")),
                            ("t", hStr("09:03:30+09:00")), ("vol", hInt(200)))))
  pairs.add((kSessionEnd, hNull()))
  let dir = workDir("gapverdict")
  let path = materialize(dir, "input.hcj.jsonl", recLines(pairs))
  var raised = ""
  try:
    discard runCore(loadRecords(path))
  except UnresolvedGapError as e:
    raised = e.msg
  check("the synthetic stream raises UnresolvedGapError in Core",
        raised.contains("UNRESOLVED_GAP") and
        raised.contains("symbol_gap_unresolved=005930"))
  let tv = tryVerify(dir, infoVariant())
  check("verify answers INCOMPLETE, not a crash or a contract rejection",
        (not tv.crashed) and tv.r.verdict == vIncomplete and
        exitCode(tv.r.verdict) == 4 and
        verdictLine(tv.r) == "VERDICT INCOMPLETE" and not tv.r.matched)
  check("the INCOMPLETE issue carries the unresolved symbol",
        tv.r.issues.len == 1 and tv.r.issues[0].contains("UNRESOLVED_GAP") and
        tv.r.issues[0].contains("005930"))

# ------------------------------------------------- writeRun fail-closed
block writeGuard:
  ## writeRun must never overwrite data: not an existing run, not an
  ## unrelated directory, not a file at the output path, and never the
  ## run's own input (copying a file onto itself truncates it to 0 bytes).
  let bi = infoVariant()
  let res = runCore(loadRecords(inputPath))

  proc hashDir(dir: string): string =
    var rows: seq[string]
    for kind, path in walkDir(dir):
      if kind == pcFile:
        rows.add(path & " " & sha256Hex(readFile(path)))
    rows.sort()
    result = rows.join("\n")

  proc attempt(outDir, inPath: string): string =
    ## "OutputGuardError" on refusal, "" when writeRun succeeded, anything
    ## else is a wrong exception or a Defect and fails the check.
    try:
      discard writeRun(outDir, inPath, res, bi)
      result = ""
    except OutputGuardError:
      result = "OutputGuardError"
    except CatchableError as e:
      result = "wrong exception: " & $e.name
    except Defect as e:
      result = "defect: " & $e.name

  let runDir = makeRun("guard-existing", bi)
  let before = hashDir(runDir)
  check("writeRun refuses to overwrite an existing run",
        attempt(runDir, inputPath) == "OutputGuardError")
  check("refused writeRun changed no byte of the existing run",
        hashDir(runDir) == before)
  let tv1 = tryVerify(runDir, bi)
  check("the refused-overwrite run still verifies MATCH",
        (not tv1.crashed) and tv1.r.matched)

  let selfRun = makeRun("guard-self", bi)
  let selfInput = selfRun / "input.hcj.jsonl"
  let beforeSelf = hashDir(selfRun)
  check("input artifact is non-empty before the self-replay attempt",
        readFile(selfInput).len > 0)
  check("writeRun refuses to replay a run onto its own input",
        attempt(selfRun, selfInput) == "OutputGuardError")
  check("self-replay refusal leaves the input non-empty (no 0-byte cut)",
        readFile(selfInput).len > 0)
  check("self-replay refusal changed no byte of the run",
        hashDir(selfRun) == beforeSelf)

  let other = workDir("guard-other")
  writeFile(other / "precious.json", "{\"days\":{}}")
  check("writeRun refuses a non-empty unrelated directory",
        attempt(other, inputPath) == "OutputGuardError")
  check("unrelated directory received no run files",
        not fileExists(other / "run.json") and
        not fileExists(other / "input.hcj.jsonl"))
  check("unrelated directory content untouched",
        readFile(other / "precious.json") == "{\"days\":{}}")

  let asFile = workDir("guard-file") / "not-a-dir"
  writeFile(asFile, "keep me")
  check("writeRun refuses when the output path is a file",
        attempt(asFile, inputPath) == "OutputGuardError")
  check("file at the output path is untouched", readFile(asFile) == "keep me")

  let fresh = workDir("guard-fresh") / "run"
  check("writeRun accepts a fresh directory", attempt(fresh, inputPath) == "")
  let tv2 = tryVerify(fresh, bi)
  check("fresh run still verifies MATCH", (not tv2.crashed) and tv2.r.matched)

  let empty = workDir("guard-empty") / "run"
  createDir(empty)
  check("writeRun accepts an existing empty directory",
        attempt(empty, inputPath) == "")
  let tv3 = tryVerify(empty, bi)
  check("run in the pre-existing empty dir verifies MATCH",
        (not tv3.crashed) and tv3.r.matched)

# ------------------------------------ writeRun symlink hardening
when defined(posix):
  block writeSymlinkGuard:
    ## A symlink at the output path must be refused outright. The historical
    ## path accepted it whenever the target happened to be empty and then
    ## wrote through the link into a directory the caller never named.
    proc attempt(outDir: string): string =
      try:
        discard writeRun(outDir, inputPath, runCore(loadRecords(inputPath)),
                         infoVariant())
        result = ""
      except OutputGuardError:
        result = "OutputGuardError"
      except CatchableError as e:
        result = "wrong exception: " & $e.name

    let sb = createTempDir("hs-prov-sym-", "")
    let real = sb / "real"
    createDir(real)
    createSymlink(real, sb / "link")
    check("writeRun refuses a symlink at the output path",
          attempt(sb / "link") == "OutputGuardError")
    check("nothing was written through the symlink", countEntries(real) == 0)

    # A symlink to a non-empty target was already refused by the emptiness
    # guard before the hardening; it must keep refusing.
    writeFile(real / "precious.json", "{}")
    createSymlink(real, sb / "link2")
    check("writeRun refuses a symlink to a non-empty directory",
          attempt(sb / "link2") == "OutputGuardError")
    check("symlink target content is untouched",
          readFile(real / "precious.json") == "{}")

  block toctouSwapDir:
    ## Deterministic guard-to-write race. The child's runCore reads a real
    ## file, so the first time the FIFO is ever opened for reading is
    ## writeRun's own post-guard loadRecords: the parent's pairing open
    ## returns exactly then. While the child sits blocked in that read --
    ## past the guard, before a single byte is written -- the parent
    ## replaces the still-empty output directory with a symlink to user
    ## data. Following the swapped link would truncate the victim's files
    ## (the historical copyFile/writeFile path did exactly that); the
    ## exclusive-creation path must refuse instead.
    let sb = createTempDir("hs-prov-tocswap-", "")
    let victim = sb / "victim"
    createDir(victim)
    writeFile(victim / "input.hcj.jsonl", "PRECIOUS USER DATA\n")
    let bigPath = sb / "big.hcj.jsonl"
    writeFile(bigPath, bigInputBytes())
    let outDir = sb / "run"
    createDir(outDir)
    let fifo = sb / "in.fifo"
    check("test harness can create a FIFO (swap)",
          cMkfifo(fifo.cstring, 0o600.Mode) == 0)
    let bigBytes = readFile(bigPath)
    let p = spawnProvChild("swap", outDir, bigPath, fifo, "")
    # This open returns only once the child is inside writeRun, past the
    # guard, blocked reading the FIFO: the guaranteed in-window instant.
    let w = openFifoWriter(fifo)
    doAssert dirExists(outDir) and not symlinkExists(outDir) and
             countEntries(outDir) == 0
    removeDir(outDir)
    createSymlink(victim, outDir)
    writeFdAll(w, bigBytes)
    closeFd(w)
    # writeRun reads the input bytes once more before creating anything.
    feedSecondFifo(fifo, bigBytes)
    let rc = waitProvChild(p)
    check("writeRun refuses when the output dir is swapped for a symlink mid-run",
          rc == 3)
    check("victim input.hcj.jsonl was not truncated through the swapped link",
          readFile(victim / "input.hcj.jsonl") == "PRECIOUS USER DATA\n")
    check("victim received no run artifacts", countEntries(victim) == 1)
    check("output path is still exactly the planted symlink",
          symlinkExists(outDir))
    # Unlink the planted link itself; never follow it.
    removeFile(outDir)

  block toctouPlantedArtifact:
    ## Same deterministic window, different attack: the directory stays
    ## real, but run.json is planted as a symlink to a user file while the
    ## child is blocked past the guard. The exclusive create must fail on
    ## the occupied name instead of writing through the link (the
    ## historical writeFile truncated the victim into a partial run.json).
    let sb = createTempDir("hs-prov-tocplant-", "")
    let bigPath = sb / "big.hcj.jsonl"
    writeFile(bigPath, bigInputBytes())
    let outDir = sb / "run"
    createDir(outDir)
    let precious = sb / "precious.json"
    writeFile(precious, "PRECIOUS USER DATA\n")
    let fifo = sb / "in.fifo"
    check("test harness can create a FIFO (plant)",
          cMkfifo(fifo.cstring, 0o600.Mode) == 0)
    let bigBytes = readFile(bigPath)
    let p = spawnProvChild("plant", outDir, bigPath, fifo, "")
    let w = openFifoWriter(fifo)
    createSymlink(precious, outDir / runFile)
    writeFdAll(w, bigBytes)
    closeFd(w)
    feedSecondFifo(fifo, bigBytes)
    let rc = waitProvChild(p)
    check("writeRun refuses when an artifact name is a planted symlink",
          rc == 3)
    check("file behind the planted run.json symlink is intact",
          readFile(precious) == "PRECIOUS USER DATA\n")
    check("run.json was never written through the symlink",
          symlinkExists(outDir / runFile))
    check("refusal left only the artifacts created before the clash",
          countEntries(outDir) == 4)
    let tv = tryVerify(outDir, infoVariant())
    check("the partial run left by the refusal is MISMATCH exit 6",
          (not tv.crashed) and tv.r.verdict == vMismatch and
          exitCode(tv.r.verdict) == 6)
    proc retry(): string =
      try:
        discard writeRun(outDir, inputPath, runCore(loadRecords(inputPath)),
                         infoVariant())
        result = ""
      except OutputGuardError:
        result = "OutputGuardError"
      except CatchableError as e:
        result = "wrong exception: " & $e.name
    check("retrying writeRun into the partial run is refused",
          retry() == "OutputGuardError")

  block concurrentEmptyDir:
    ## The documented mktemp case hammered by parallel processes: every
    ## child sees a provably empty directory at guard time, so only
    ## exclusive creation can serialize them. Exactly one run may land, the
    ## losers must refuse without writing a byte, and the winner must
    ## verify MATCH (no interleaved or half-clobbered artifacts).
    let outDir = createTempDir("hs-prov-race-", "")
    let go = outDir & ".go"
    let inputBefore = readFile(inputPath)
    var ps: seq[Process]
    for i in 0 ..< 6:
      ps.add(spawnProvChild("race", outDir, inputPath, inputPath, go))
    writeFile(go, "go")
    var wins, refused, broken = 0
    for p in ps:
      let rc = waitProvChild(p)
      if rc == 0:
        inc wins
      elif rc == 3:
        inc refused
      else:
        inc broken
    check("exactly one concurrent writeRun wins the empty directory",
          wins == 1 and refused == 5 and broken == 0)
    var files = 0
    for kind, path in walkDir(outDir):
      if kind == pcFile:
        inc files
    check("the winner left exactly the five run artifacts", files == 5)
    let tv = tryVerify(outDir, infoVariant())
    check("the winning run verifies MATCH (no interleaving)",
          (not tv.crashed) and tv.r.matched)
    check("the source input is byte-identical after the race",
          readFile(inputPath) == inputBefore)

# ------------------------------------------------- documented limit
block forgeryLimit:
  ## verify binds run.json to the *verifying binary's self-declared* build
  ## info. Both are attacker-controlled at compile time: a forger who
  ## compiles with fake -d values produces a self-consistent pair that
  ## verifies as MATCH. This is a consistency check, not authenticity
  ## evidence; the assertion below pins that limit as executable fact.
  let forged = infoVariant(commit = "e".repeat(40), origin = "e".repeat(40),
                           buildTime = "forged-by-hand")
  let d = makeRun("forged", forged)
  let tv = tryVerify(d, forged)
  check("self-consistent forged BuildInfo still matches (documented limit)",
        (not tv.crashed) and tv.r.verdict == vMatch and tv.r.matched)

echo ""
echo passes, " passed, ", failures, " failed"
if failures > 0: quit(1)
