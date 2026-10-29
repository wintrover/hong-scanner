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
##     module — state moves only through append/finish/abandon;
##   - ordered complete records: the recorder is the only writer and owns
##     the seq counter (1, 2, 3, ... in write order); each record is one
##     canonical line + LF from records.makeRecordLine — there is no second
##     serialization to drift from;
##   - explicit termination: finish() seals the stream with the session_end
##     record, fsyncs the file and closes;
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
##   - no power-loss guarantee: fsync is requested only at finish; there is
##     no per-record fsync, no parent-directory fsync and no atomic rename.
##     A crash can tear a write — this module detects and preserves the torn
##     tail, it neither prevents nor repairs it;
##   - a seal in the file is not durable-completion evidence: finish()
##     writes the session_end bytes before it fsyncs, so a failed fsync
##     (SealUnverifiedError) leaves a file that looks normally sealed to any
##     inspector — byte-identical to a durable finish. This module produces
##     no separate durable-completion evidence and claims no atomic
##     completion protocol; finished() is an in-process statement about the
##     finish() protocol and does not travel with the file. Approving a
##     sealed file as a complete run requires evidence from outside this
##     module;
##   - not wired into core or CLI: replay/verify keep reading record files
##     with records.loadRecords exactly as before.
import std/[posix, strutils]
import hcj, records

type
  RecorderError* = object of CatchableError
  PartialTailError* = object of RecorderError
  SealUnverifiedError* = object of RecorderError
    ## finish() wrote the session_end seal but could not confirm durability
    ## (fsync failed). The file may carry a normal-looking seal that no
    ## file-level inspection can distinguish from a durable one.

  Recorder* = ref object
    ## Single-writer handle owning one exclusively created log file. A
    ## reference on purpose: copying the handle aliases the same state — a
    ## value copy would fork the fd (double close) and let a stale copy
    ## keep writing with a private seq counter. Fields are private; state
    ## changes only through append/finish/abandon. End every session with
    ## finish() or abandon(); dropping the handle without either leaks the
    ## fd until process exit (which is itself the crash model).
    path: string   ## log destination, owned exclusively by this recorder
    seq: int       ## seq of the last record fully written; 0 before any
    finished: bool ## true only after finish() sealed, fsynced and closed
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
  ## True only after finish() completed its whole protocol (seal + fsync +
  ## close). An in-process statement: it does not travel with the file and
  ## is not durable-completion evidence for an independent inspector.
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

proc finish*(r: Recorder): int =
  ## Explicit normal termination: seal with a session_end record, fsync,
  ## close. Only this path sets finished. A finish that raises leaves the
  ## recorder closed but unverified — inspect the file before trusting it,
  ## and see the module header: a seal in the file is not durable-completion
  ## evidence. Returns the total record count, seal included.
  if r.fd < 0:
    raise rerr("recorder is closed, cannot finish: " & r.path)
  if r.finished:
    raise rerr("recorder already finished: " & r.path)
  if r.failed:
    raise rerr("recorder failed mid-write, refusing to seal behind a torn " &
      "record; preserve and inspect the file: " & r.path)
  writeRecord(r, kSessionEnd, hNull())
  if posix.fsync(r.fd) != 0:
    ## The seal bytes are already in the file. Marking them undurable would
    ## mean writing more bytes whose durability is equally unknown, so the
    ## honest model is to raise SealUnverifiedError and stay unfinished:
    ## this module claims no atomic completion protocol and produces no
    ## separate durable-completion evidence — approval of the file must
    ## rest on evidence from outside this module.
    let msg = "fsync failed after writing the seal; the file carries a " &
      "normal-looking session_end that no file-level inspection can " &
      "distinguish from a durable one — do not approve it on its bytes: " &
      r.path & ": " & $strerror(errno)
    discard posix.close(r.fd)
    r.fd = -1
    raise newException(SealUnverifiedError, msg)
  let cn = posix.close(r.fd)
  r.fd = -1
  if cn != 0:
    raise rerr("close failed: " & r.path & ": " & $strerror(errno))
  r.finished = true
  result = r.seq

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
  ## A well-formed sealed file still proves nothing about durability (see
  ## the module header).
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
  ## the writer *wrote* the seal — not that finish() completed its fsync.
  ## A sealed file alone is not durable-completion evidence and must not be
  ## fully approved on its own (see the module header).
  recs.len > 0 and recs[recs.len - 1].kind == kSessionEnd
