## Single-writer append-only recorder for the operational record stream:
## the smallest slice of the VS-2 recorder target (docs/REPLAY_CONTRACT.md
## §12.2) that needs no Kiwoom permissions — no socket, no API, no secret,
## only records it is handed.
##
## Contract implemented here:
##   - exclusive creation (O_CREAT|O_EXCL|O_WRONLY, mode 0o600 — the stream
##     carries market bytes, private by default): an existing path — file,
##     empty file, directory or symlink — is refused before a single byte
##     is written, and the kernel check is atomic, so two recorders can
##     never both win the same path;
##   - single-writer state: Recorder is a reference with private fields.
##     Copying the handle aliases the same state instead of forking it (a
##     value copy would double-close the fd and let a stale copy write with
##     its own seq counter), and no field can be mutated from outside this
##     module — state moves only through append/syncNow/finish/abandon;
##   - ordered complete records: the recorder is the only writer and owns
##     the seq counter (1, 2, 3, ... in write order); each record is one
##     canonical line + LF from records.makeRecordLine — there is no second
##     serialization to drift from;
##   - durable-completion protocol: finish() runs, in order,
##       (1) fsync(fd) — everything appended so far is durable *before*
##           the seal exists, so a seal in the file always sits on durable
##           data;
##       (2) the session_end seal record is written;
##       (3) fsync(fd) — the seal bytes are durable;
##       (4) fsync of the parent directory (opened by path, never the
##           log fd) — the log file's directory entry is durable;
##       (5) the sibling COMMITTED marker is created exclusively at
##           <log path>.committed (O_CREAT|O_EXCL), one canonical HCJ
##           line + LF:
##             {"run_id": <basename of the log's parent directory>,
##              "schema": "hong-scanner-commit/1",
##              "seq": <total record count, seal included>,
##              "sha256": <sha256 over the sealed log file bytes,
##                         lowercase 64 hex>,
##              "t": <ISO 8601 with numeric offset, written at finish>}
##           run_id is the run directory's basename (runs/<date>/ ->
##           <date>). The marker is created, never rewritten: a marker
##           already at that path is refused (a stale marker from a
##           previous, deleted log is operator evidence, not this
##           recorder's to clear);
##       (6) the marker bytes are written and fsynced;
##       (7) fsync of the parent directory again — the marker's directory
##           entry is durable;
##       (8) the log fd is closed.
##     The invariant this encodes: the seal is only ever written after the
##     data fsync succeeded, and a *sealed file without a marker* is the
##     durable-completion verdict "termination recorded, durability
##     unconfirmed" — the log bytes alone cannot distinguish that state
##     from a durable finish, so the sibling marker is the distinguishing
##     evidence and readCommitMarker is its verifier. Any fsync or marker
##     failure raises SealUnverifiedError (or, for a pre-existing marker,
##     RecorderError) and leaves the recorder closed and unfinished; the
##     file and any partial marker are preserved, never cleaned up.
##   - durability heartbeat: syncNow() fsyncs what is already written and
##     writes nothing — no seal, no marker. The collector calls it on its
##     own cadence (60 s is the intended one); the recorder keeps no clock
##     and makes no timing decision of its own. The only clock input in
##     this module is the marker's "t" timestamp, written by the adapter
##     boundary at finish, not by Core;
##   - abnormal termination: abandon() (the in-process stand-in for process
##     death) writes nothing — the complete LF records already on disk stay
##     byte-identical and the stream stays unsealed, which records.nim
##     defines as INCOMPLETE (exit 4), never REJECT;
##   - fail-closed after a torn write: if a record write fails partway, the
##     recorder is poisoned — every later append and finish is refused, so
##     nothing (least of all a session_end seal) can be written behind a
##     partial line. The file keeps its complete records plus the torn tail,
##     unsealed and therefore INCOMPLETE, and readRecorderFile() refuses the
##     tail instead of accepting it;
##   - torn-tail discovery: readRecorderFile() refuses a file whose last
##     record is not LF-terminated (PartialTailError) and never truncates,
##     repairs or rewrites it.
##
## Documented limits (docs/LIMITS.md, the "VS-2 recorder" rows) — pinned as
## facts, NOT solved:
##   - this is not the live collector: nothing feeds it REST or WebSocket
##     bytes, and the §12.2 byte-evidence / §12.3 cross-check contracts are
##     not implemented;
##   - fsync coverage is: everything at finish, plus whatever the caller
##     syncs via syncNow. There is still no per-record fsync, so a crash
##     between records can lose un-synced complete records — the durable
##     completion claim covers the sealed whole, not per-record recency;
##     a crash can also tear a write — this module detects and preserves
##     the torn tail, it neither prevents nor repairs it;
##   - a seal alone is not durable-completion evidence: the COMMITTED
##     marker is, and only readCommitMarker's VALID (marker present, schema
##     exact, seq and sha256 equal to the log's own) counts as durable
##     completion. ABSENT means "termination recorded, durability
##     unconfirmed" (or the log predates the marker protocol); INVALID
##     means the marker and the log disagree — tampered, stale or torn.
##     These are file-level facts, not a proof of what the bytes mean;
##   - not wired into the replay verdict: replay/verify keep reading record
##     files with records.loadRecords exactly as before; verify consults
##     the marker only when the stream's config declares an environment.
import std/[os, posix, strutils, times]
import hcj, records, digest

type
  RecorderError* = object of CatchableError
  PartialTailError* = object of RecorderError
  SealUnverifiedError* = object of RecorderError
    ## finish() could not carry its durable-completion protocol through to
    ## the COMMITTED marker: an fsync failed (before the seal, after the
    ## seal, on the directory or on the marker), or the marker could not be
    ## written. The file may carry anything from plain unsealed records to
    ## a seal whose durability is unconfirmed, and readCommitMarker answers
    ## ABSENT or INVALID — that verdict is the visible evidence of the
    ## failure, not the exception alone.

  CommitStatus* = enum
    ## File-level durable-completion verdict for one sealed log:
    csValid     ## marker present, schema exact, seq and sha256 match the log
    csAbsent    ## no marker: termination recorded, durability unconfirmed
    csInvalid   ## marker present but unreadable, foreign, or not matching

  CommitMarker* = object
    ## readCommitMarker's result: the verdict plus what the marker itself
    ## declared (filled as far as it parsed; reason is "" only for VALID).
    status*: CommitStatus
    reason*: string
    runId*: string
    seq*: int
    sha256*: string
    t*: string

  Recorder* = ref object
    ## Single-writer handle owning one exclusively created log file. A
    ## reference on purpose: copying the handle aliases the same state — a
    ## value copy would fork the fd (double close) and let a stale copy
    ## keep writing with a private seq counter. Fields are private; state
    ## changes only through append/syncNow/finish/abandon. End every
    ## session with finish() or abandon(); dropping the handle without
    ## either leaks the fd until process exit (which is itself the crash
    ## model).
    path: string   ## log destination, owned exclusively by this recorder
    seq: int       ## seq of the last record fully written; 0 before any
    finished: bool ## true only after finish() ran its whole protocol
                   ## through the COMMITTED marker
    failed: bool   ## poisoned: a record write failed partway
    fd: cint       ## kernel file descriptor; -1 once closed

proc rerr(msg: string): ref RecorderError =
  newException(RecorderError, msg)

proc path*(r: Recorder): string =
  ## The exclusively owned log destination.
  r.path

proc seqNo*(r: Recorder): int =
  ## Seq of the last record fully written; 0 before any write. Never counts
  ## a torn record.
  r.seq

proc finished*(r: Recorder): bool =
  ## True only after finish() completed its whole protocol: data fsync,
  ## seal, seal fsync, directory fsync, COMMITTED marker created, written,
  ## fsynced, directory fsync, close. An in-process statement about the
  ## protocol; the durable-completion evidence that travels with the file
  ## is the marker (readCommitMarker), not this flag.
  r.finished

proc failed*(r: Recorder): bool =
  ## True once a record write failed partway: the recorder refuses every
  ## further append and finish, and the file must be preserved and
  ## inspected (its tail is torn).
  r.failed

proc openRecorder*(path: string): Recorder =
  ## Exclusive creation with mode 0o600 (the stream carries market bytes,
  ## private by default). An existing path (file, empty file, directory or
  ## symlink — O_EXCL never follows it) is refused atomically before any
  ## byte is written, so a recorder can never clobber prior evidence and a
  ## second recorder can never attach to a live one's file. The caller ends
  ## every session with finish() (normal) or abandon() (abnormal).
  var fd: cint
  while true:
    fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC,
                    0o600.cint)
    if fd >= 0:
      break
    if errno != EINTR:
      if errno == EEXIST:
        raise rerr("path exists, refusing to overwrite: " & path)
      raise rerr("open failed: " & path & ": " & $strerror(errno))
  Recorder(path: path, fd: fd)

proc writeAll(fd: cint; buf: string; path: string) =
  ## Complete write of one buffer: short writes and EINTR are retried. buf
  ## ends with the record's LF, so a record is either fully written or the
  ## file ends in a torn line — which readRecorderFile refuses, never
  ## silently accepts.
  var off = 0
  while off < buf.len:
    let n = posix.write(fd, cast[pointer](unsafeAddr buf[off]), buf.len - off)
    if n > 0:
      off += n
    elif n < 0 and errno == EINTR:
      discard
    else:
      raise rerr("write failed: " & path & ": " & $strerror(errno))

proc writeRecord(r: Recorder; kind: Kind; raw: HcjValue) =
  let line = makeRecordLine(r.seq + 1, kind, raw) & "\n"
  try:
    writeAll(r.fd, line, r.path)
  except CatchableError:
    ## A torn record is on disk (or the write never landed): the file's
    ## tail is untrustworthy from here, so the recorder poisons itself and
    ## refuses every later write — a session_end appended behind a partial
    ## line could even make the merged bytes parse as a valid record.
    r.failed = true
    raise
  inc r.seq

proc append*(r: Recorder; kind: Kind; raw: HcjValue): int =
  ## Append one record as a complete canonical line + LF and return the seq
  ## assigned to it. The recorder is the single writer, so it owns the seq
  ## counter: records are numbered 1, 2, 3, ... in write order and seq
  ## contiguity cannot drift. session_end is reserved for finish().
  if r.fd < 0:
    raise rerr("recorder is closed, cannot append: " & r.path)
  if r.finished:
    raise rerr("recorder is finished, cannot append: " & r.path)
  if r.failed:
    raise rerr("recorder failed mid-write, refusing to append behind a torn " &
      "record; preserve and inspect the file: " & r.path)
  if kind == kSessionEnd:
    raise rerr("session_end is reserved for finish(), not append: " & r.path)
  writeRecord(r, kind, raw)
  result = r.seq

const commitMarkerSchema* = "hong-scanner-commit/1"

proc fsyncDir(dir: string) =
  ## fsync a directory *by path* (never through the log fd): opens the
  ## directory itself read-only and flushes its entries, making a file's
  ## directory entry durable. Mirrors verify.nim's O_DIRECTORY handling
  ## (Nim 2.2.10's std/posix does not export it).
  const oDirectory = cint(0o200000) # Linux `O_DIRECTORY`
  var fd = posix.open(dir.cstring, O_RDONLY or oDirectory or O_CLOEXEC)
  if fd < 0:
    raise newException(SealUnverifiedError,
      "cannot open the log's parent directory to fsync it: " & dir & ": " &
      $strerror(errno))
  if posix.fsync(fd) != 0:
    let msg = $strerror(errno)
    discard posix.close(fd)
    raise newException(SealUnverifiedError,
      "directory fsync failed: " & dir & ": " & msg)
  if posix.close(fd) != 0:
    raise newException(SealUnverifiedError,
      "directory close failed: " & dir & ": " & $strerror(errno))

proc failUnverified(r: Recorder; what: string): ref SealUnverifiedError =
  ## Close the recorder's fd and hand back the exception for a finish that
  ## failed inside its durability protocol. The on-disk state stays as it
  ## is — seal present or not, marker partial or absent — and is preserved,
  ## never cleaned up.
  discard posix.close(r.fd)
  r.fd = -1
  newException(SealUnverifiedError,
    what & " — the finish protocol did not reach the COMMITTED marker; " &
    "the log's durable completion is unconfirmed: " & r.path)

proc commitMarkerBytes(runId: string; total: int; sealedSha256,
                       t: string): string =
  ## The canonical HCJ marker line + LF, exactly the documented schema.
  canonical(hObj(
    ("run_id", hStr(runId)),
    ("schema", hStr(commitMarkerSchema)),
    ("seq", hInt(total)),
    ("sha256", hStr(sealedSha256)),
    ("t", hStr(t)))) & "\n"

proc finish*(r: Recorder): int =
  ## Explicit normal termination: the durable-completion protocol of the
  ## module header, steps (1)..(8). The seal is written only after the
  ## data fsync succeeded, and completion is only claimed once the
  ## COMMITTED marker is written and fsynced — a seal without a marker
  ## stays "termination recorded, durability unconfirmed", which
  ## readCommitMarker reports as ABSENT. Any fsync or marker failure
  ## raises SealUnverifiedError (a pre-existing marker is refused with
  ## RecorderError: it is prior evidence, never overwritten) and leaves
  ## the recorder closed and unfinished, the file exactly as it was.
  ## Returns the total record count, seal included.
  if r.fd < 0:
    raise rerr("recorder is closed, cannot finish: " & r.path)
  if r.finished:
    raise rerr("recorder already finished: " & r.path)
  if r.failed:
    raise rerr("recorder failed mid-write, refusing to seal behind a torn " &
      "record; preserve and inspect the file: " & r.path)
  let dir = parentDir(r.path)
  let runId = lastPathPart(dir)
  if runId.len == 0:
    raise rerr("cannot derive the marker's run_id: the log path has no " &
      "parent directory, record into a run directory instead: " & r.path)
  # (1) data durability before the seal: everything appended so far.
  if posix.fsync(r.fd) != 0:
    raise failUnverified(r,
      "fsync failed before the seal was written (nothing was sealed)")
  # (2) the seal.
  writeRecord(r, kSessionEnd, hNull())
  # (3) seal durability.
  if posix.fsync(r.fd) != 0:
    raise failUnverified(r,
      "fsync failed after writing the seal; the file carries a " &
      "session_end whose durability is unconfirmed")
  # (4) directory-entry durability of the sealed log.
  try:
    fsyncDir(dir)
  except SealUnverifiedError as e:
    raise failUnverified(r, e.msg)
  # (5) the COMMITTED marker, exclusively. The sha256 is taken over the
  # bytes read back from the sealed file — exactly what readCommitMarker
  # and any third-party verifier recompute.
  let markerPath = r.path & ".committed"
  let sealedSha = block:
    var s = ""
    try:
      s = sha256Hex(readFile(r.path))
    except CatchableError as e:
      raise failUnverified(r,
        "the sealed log could not be read back for the marker's sha256: " &
        e.msg)
    s
  let t = $now() # ISO 8601 with numeric offset; the adapter boundary's clock
  let mfd = posix.open(markerPath.cstring,
                       O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC, 0o600.cint)
  if mfd < 0:
    if errno == EEXIST:
      discard posix.close(r.fd)
      r.fd = -1
      raise rerr("commit marker already exists, refusing to overwrite " &
        "prior evidence; clear it by hand if and only if it is stale: " &
        markerPath)
    raise failUnverified(r,
      "cannot create the commit marker " & markerPath & ": " &
      $strerror(errno))
  # (6) marker write + fsync. A failed write can leave a torn marker —
  # preserved on purpose; readCommitMarker answers INVALID for it.
  var markerErr = ""
  try:
    writeAll(mfd, commitMarkerBytes(runId, r.seq, sealedSha, t), markerPath)
    if posix.fsync(mfd) != 0:
      markerErr = "marker fsync failed: " & markerPath & ": " &
        $strerror(errno)
  except CatchableError as e:
    markerErr = "marker write failed: " & e.msg
  if markerErr.len > 0:
    discard posix.close(mfd)
    raise failUnverified(r, markerErr)
  if posix.close(mfd) != 0:
    raise failUnverified(r,
      "marker close failed: " & markerPath & ": " & $strerror(errno))
  # (7) directory-entry durability of the marker.
  try:
    fsyncDir(dir)
  except SealUnverifiedError as e:
    raise failUnverified(r, e.msg)
  # (8) close.
  let cn = posix.close(r.fd)
  r.fd = -1
  if cn != 0:
    raise rerr("close failed: " & r.path & ": " & $strerror(errno))
  r.finished = true
  result = r.seq

proc syncNow*(r: Recorder) =
  ## Durability heartbeat: fsync what is already written; write nothing —
  ## no record, no seal, no marker. The collector calls this on its own
  ## cadence (the intended one is every 60 s); the recorder keeps no clock
  ## and makes no timing decision, so periodicity is entirely the caller's
  ## responsibility. A failed fsync raises RecorderError but neither
  ## poisons the recorder nor changes any byte: the next syncNow or finish
  ## may still succeed. Allowed on a poisoned recorder — it only flushes
  ## the bytes already on disk, which is exactly what torn-tail evidence
  ## preservation wants.
  if r.fd < 0:
    raise rerr("recorder is closed, cannot sync: " & r.path)
  if posix.fsync(r.fd) != 0:
    raise rerr("syncNow fsync failed (durability unconfirmed for the " &
      "bytes written so far; no byte was changed): " & r.path & ": " &
      $strerror(errno))

proc abandon*(r: Recorder) =
  ## Abnormal termination (the in-process stand-in for process death):
  ## close the fd without writing the session_end seal and without fsync.
  ## The complete LF records already on disk stay byte-identical and the
  ## stream stays unsealed — INCOMPLETE per records.nim, not REJECT. Also
  ## allowed on a poisoned recorder: it writes nothing either way.
  if r.fd < 0:
    raise rerr("recorder is closed, cannot abandon: " & r.path)
  discard posix.close(r.fd)
  r.fd = -1

proc readRecorderFile*(path: string): seq[Record] =
  ## Operator-side inspection of a recorder file. Reads only — never
  ## truncates, repairs or rewrites: a torn tail is preserved as evidence.
  ## Raises PartialTailError when the last record is not LF-terminated
  ## (crash mid-write); other line-discipline or envelope violations are
  ## wrapped in RecorderError. An empty file is zero records, not an error.
  ## A well-formed sealed file alone still proves nothing about durability:
  ## the sibling COMMITTED marker does (readCommitMarker).
  var content: string
  try:
    content = readFile(path)
  except IOError as e:
    raise rerr("recorder file unreadable: " & path & ": " & e.msg)
  if content.len > 0 and not content.endsWith("\n"):
    raise newException(PartialTailError,
      "partial tail: last record is not LF-terminated, original preserved: " &
      path)
  try:
    result = loadRecords(path)
  except CatchableError as e:
    raise rerr("not a valid record stream: " & path & ": " & e.msg)

proc isSealed*(recs: seq[Record]): bool =
  ## Byte-level fact: the stream ends with the session_end record. It says
  ## the writer *wrote* the seal — not that the finish() protocol carried
  ## it to durable completion. The distinguishing evidence is the sibling
  ## COMMITTED marker (readCommitMarker): a sealed file with ABSENT there
  ## is "termination recorded, durability unconfirmed".
  recs.len > 0 and recs[recs.len - 1].kind == kSessionEnd

proc commitStateName*(s: CommitStatus): string =
  ## The verdict as it travels in report lines and verify output.
  case s
  of csValid: "VALID"
  of csAbsent: "ABSENT"
  of csInvalid: "INVALID"

proc inMarkerFields(k: string): bool =
  k in ["run_id", "schema", "seq", "sha256", "t"]

proc validIso8601Offset(s: string): bool =
  ## Exactly "YYYY-MM-DDTHH:MM:SS+HH:MM" (offset sign + or -), digits in
  ## every digit position and plausible ranges. Pure format check, no
  ## calendar arithmetic — the same format contract as sub_input's record
  ## timestamps and the marker's t, module-local by the codebase's
  ## self-contained-schema convention.
  if s.len != 25:
    return false
  if s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or
     s[16] != ':' or (s[19] != '+' and s[19] != '-') or s[22] != ':':
    return false
  for i in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18, 20, 21, 23, 24]:
    if s[i] notin {'0' .. '9'}:
      return false
  proc d2(i: int): int = (ord(s[i]) - ord('0')) * 10 + (ord(s[i + 1]) - ord('0'))
  result = d2(5) in 1 .. 12 and d2(8) in 1 .. 31 and d2(11) in 0 .. 23 and
    d2(14) in 0 .. 59 and d2(17) in 0 .. 59 and d2(20) in 0 .. 23 and
    d2(23) in 0 .. 59

proc validSha256Hex(s: string): bool =
  ## 64 lowercase hex digits (same rule as sub_input, module-local).
  if s.len != 64:
    return false
  for c in s.items:
    if c notin {'0' .. '9', 'a' .. 'f'}:
      return false
  result = true

proc readCommitMarker*(logPath: string): CommitMarker =
  ## Verify the COMMITTED marker of one log file: parse
  ## <logPath>.committed, validate the schema exactly
  ## ({"run_id","schema","seq","sha256","t"}; schema ==
  ## "hong-scanner-commit/1"; run_id == basename of the log's parent
  ## directory; seq == the log's record count, seal included; sha256 ==
  ## sha256 over the log file bytes; t == ISO 8601 with numeric offset)
  ## and answer VALID, ABSENT (no marker file) or INVALID with the reason.
  ## Read-only: nothing is ever rewritten or deleted. The log itself is
  ## inspected with readRecorderFile, so a torn log tail is INVALID
  ## (the marker's seq/sha256 cannot honestly match a torn file).
  let markerPath = logPath & ".committed"
  if not fileExists(markerPath):
    return CommitMarker(status: csAbsent,
      reason: "no commit marker file at " & markerPath)
  var bad = ""
  var m: HcjValue
  try:
    m = parseDoc(readFile(markerPath))
  except CatchableError as e:
    bad = "marker is not valid HCJ JSON: " & e.msg
  if bad.len == 0:
    if m.kind != hkObj:
      bad = "marker is not a JSON object: " & kindName(m)
    else:
      for p in m.pairs:
        if not inMarkerFields(p.k):
          bad = "unknown marker field: " & p.k & " (the marker schema is " &
                "exactly run_id/schema/seq/sha256/t)"
      if bad.len == 0:
        for k in ["run_id", "schema", "seq", "sha256", "t"]:
          if not m.has(k):
            bad = "marker is missing field: " & k
      if bad.len == 0:
        for k in ["run_id", "schema", "sha256", "t"]:
          if m.get(k).kind != hkStr:
            bad = "marker field is not a string: " & k & " is " &
                  kindName(m.get(k))
        if m.has("seq") and m.get("seq").kind != hkInt:
          bad = "marker field seq is not an integer: " &
                kindName(m.get("seq"))
      if bad.len == 0:
        result.runId = m.get("run_id").strVal
        result.seq = int(m.get("seq").ival)
        result.sha256 = m.get("sha256").strVal
        result.t = m.get("t").strVal
        if m.get("schema").strVal != commitMarkerSchema:
          bad = "marker schema is not " & commitMarkerSchema & ": " &
                m.get("schema").strVal
        elif result.runId != lastPathPart(parentDir(logPath)):
          bad = "marker run_id does not name this log's run directory: " &
                result.runId & " vs " & lastPathPart(parentDir(logPath))
        elif not validIso8601Offset(result.t):
          bad = "marker t is not an ISO 8601 timestamp with a numeric " &
                "offset (YYYY-MM-DDTHH:MM:SS+HH:MM): " & result.t
        elif not validSha256Hex(result.sha256):
          bad = "marker sha256 is not 64 lowercase hex digits: " &
                result.sha256
        elif result.seq < 1:
          bad = "marker seq must be >= 1: " & $result.seq
        else:
          # Log cross-check: seq first (cheap, structural), then sha256
          # over the exact bytes.
          var recs: seq[Record]
          try:
            recs = readRecorderFile(logPath)
          except CatchableError as e:
            bad = "log is not a readable record stream: " & e.msg
          if bad.len == 0:
            if recs.len != result.seq:
              bad = "marker seq does not match the log: marker " &
                    $result.seq & " vs log " & $recs.len &
                    " records (seal included)"
            else:
              var logged = ""
              try:
                logged = sha256Hex(readFile(logPath))
              except CatchableError as e:
                bad = "log bytes unreadable: " & e.msg
              if bad.len == 0 and logged != result.sha256:
                bad = "marker sha256 does not match the log bytes: " &
                      "tampered, stale or torn"
  result.status = if bad.len == 0: csValid else: csInvalid
  if bad.len != 0:
    result.reason = bad
