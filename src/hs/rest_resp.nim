## rest_resp: the validated acceptance path for rest_resp records
## (docs/REPLAY_CONTRACT.md §12.1/§12.2, the VS-2 implementation choice that
## replaces the VS-1 fail-closed rejection of every rest_resp).
##
## Pure: parses and validates the raw payload of one recorded REST attempt --
## the declared request scope, the page index, and the preserved original
## HTTP response metadata and body bytes -- and audits the declared page
## chains of a complete stream. No wall clock, no filesystem, no network.
##
## Record schema (module-internal contract; the record raw is one HCJ object
## with exactly these fields):
##   api_id    string  response api-id; only ka10027 is declared (§12.1)
##   page      int     1-based page index inside this scope's page chain
##   query     object  exactly the nine ka10027 request fields, all strings;
##                     sort_tp restricted to "1"/"3" (one query per
##                     direction) and stex_tp to "1" (KRX; §12.1)
##   status    int     HTTP transport status as recorded by the producer
##   cont_yn   string  "Y", "N" or "" (header absent)
##   next_key  string  continuation key, <= 50 chars, "" when none
##   body_hex  string  the exact response body bytes, hex-encoded (below)
## Unknown fields, missing fields and wrong types are schema failures.
##
## body_hex -- the HCJ-safe byte encoding (module-internal contract): an HCJ
## string must be valid UTF-8, free of DEL, and cannot carry arbitrary
## response bytes (a legacy single-byte encoding, embedded NULs, a truncated
## sequence), so the preserved §12.2 body bytes travel as lowercase hex --
## two ASCII digits per byte, byte-exact in both directions and stable under
## canonical HCJ serialization. Uppercase hex, odd length and non-hex digits
## are schema failures; hex is the only accepted encoding.
##
## Success is affirmed exactly like vendor_input, which stays the single
## source of truth (normalizeChain): HTTP 200; return_code present, integer
## and 0; list key present (an explicit empty array is a confirmed empty
## answer); every row inside the documented schema. Every failure class
## raises and is never mapped to success. Chain-level checks (cont-yn/next-
## key repeat, page cap, missing/truncated continuation) come from the same
## code path; the stream-level order audit (pages 1..N per declared scope,
## one chain per scope per stream) lives here. A scope that restarts its
## chain is rejected fail-closed unless the stream's config record declares
## the re-poll cadence (config.repoll_seconds -- the "approved extension
## path", README §6.1): declared, each page-1 record opens a new audited
## round; undeclared, the restart stays a REJECT.
##
## Failure classes reuse VendorFailure. vfSecret has no carrier in this
## record shape: no field can hold a credential, so nothing can leak one.
##
## Unverified by a live capture (G2/G4), hence fail-closed: whether
## production responses match this shape, whether defaultPageCap equals the
## approved configuration's declared page limit (until a config record
## declares it), and whether production ever omits return_code on a success
## (omission stays a failure). Nothing here proves the recorded prices are
## true (G4) -- only that what was recorded affirms success and preserves
## its bytes. Tests are synthetic only (M10).
import std/[algorithm, strutils]
import hcj
import vendor_input

type
  RestRespError* = object of CatchableError
    failure*: VendorFailure
    seqNo*: int   ## stream seq of the offending record (chain-level: first seq)

  RestRespAttempt* = object
    ## One parsed rest_resp record: what was asked (declared scope + page
    ## index) and what came back (preserved response, byte-exact body).
    seqNo*: int
    scope*: Ka10027Query
    page*: int
    resp*: RawHttpResp
    bodySha256*: string  ## sha256 over the decoded body bytes (audit print)

const
  restRespFields* = [
    "api_id", "body_hex", "cont_yn", "next_key", "page", "query", "status"]
  queryFields* = [
    "crd_cnd", "mrkt_tp", "pric_cnd", "sort_tp", "stk_cnd", "stex_tp",
    "trde_prica_cnd", "trde_qty_cnd", "updown_incls"]

proc rerr(seqNo: int; f: VendorFailure; msg: string): ref RestRespError =
  let e = newException(RestRespError, msg)
  e.failure = f
  e.seqNo = seqNo
  e

proc inArr(v: string; xs: openArray[string]): bool =
  for x in xs:
    if v == x: return true
  false

# ------------------------------------------------------ HCJ-safe byte encoding

proc hexOfBytes*(b: seq[byte]): string =
  ## Lowercase hex, two digits per byte: the HCJ-safe encoding of arbitrary
  ## response bytes (see module header).
  const digits = "0123456789abcdef"
  result = newString(2 * b.len)
  for i in 0 ..< b.len:
    result[2 * i] = digits[int(b[i] shr 4)]
    result[2 * i + 1] = digits[int(b[i] and 0x0f)]

proc hexNibble(c: char): int =
  case c
  of '0' .. '9': ord(c) - ord('0')
  of 'a' .. 'f': ord(c) - ord('a') + 10
  else: -1

proc bytesFromHex*(s: string): seq[byte] =
  ## Inverse of hexOfBytes. Strict: even length, lowercase hex only.
  if s.len mod 2 != 0:
    raise rerr(0, vfContract,
               "body_hex is not a hex encoding: odd length " & $s.len)
  result = newSeq[byte](s.len div 2)
  for i in 0 ..< result.len:
    let hi = hexNibble(s[2 * i])
    let lo = hexNibble(s[2 * i + 1])
    if hi < 0 or lo < 0:
      raise rerr(0, vfContract,
                 "body_hex is not lowercase hex at offset " & $(2 * i) &
                 ": only [0-9a-f] is the declared encoding")
    result[i] = byte(hi shl 4 or lo)

# ---------------------------------------------------------------- field access

proc strField(seqNo: int; obj: HcjValue; key, what: string): string =
  if not obj.has(key):
    raise rerr(seqNo, vfContract, "missing " & what & ": " & key)
  let v = obj.get(key)
  if v.kind != hkStr:
    raise rerr(seqNo, vfContract,
               what & " is not a string: " & key & " is " & kindName(v))
  v.strVal

proc intField(seqNo: int; obj: HcjValue; key, what: string): int =
  if not obj.has(key):
    raise rerr(seqNo, vfContract, "missing " & what & ": " & key)
  let v = obj.get(key)
  if v.kind != hkInt:
    raise rerr(seqNo, vfContract,
               what & " is not an integer: " & key & " is " & kindName(v))
  int(v.ival)

proc objField(seqNo: int; obj: HcjValue; key, what: string): HcjValue =
  if not obj.has(key):
    raise rerr(seqNo, vfContract, "missing " & what & ": " & key)
  let v = obj.get(key)
  if v.kind != hkObj:
    raise rerr(seqNo, vfContract,
               what & " is not an object: " & key & " is " & kindName(v))
  v

proc dirOf(sortTp: string): Direction =
  case sortTp
  of "1": dirUp
  of "3": dirDown
  else:
    raise rerr(0, vfContract,
               "declared sort_tp " & sortTp & " is not a candidate " &
               "direction: one query per direction, sort_tp 1 (rise) or " &
               "3 (fall) (REPLAY_CONTRACT §12.1)")

# ---------------------------------------------------------------- parse record

proc parseScope(seqNo: int; qRaw: HcjValue): Ka10027Query =
  ## The declared request scope: exactly the nine documented fields, all
  ## strings, documented enums (initKa10027Query), KRX-only, one query per
  ## direction.
  for p in qRaw.pairs:
    if not inArr(p.k, queryFields):
      raise rerr(seqNo, vfContract,
                 "unknown declared query field: " & p.k)
    if p.v.kind != hkStr:
      raise rerr(seqNo, vfContract,
                 "declared query field is not a string: " & p.k & " is " &
                 kindName(p.v))
  for k in queryFields:
    if not qRaw.has(k):
      raise rerr(seqNo, vfContract, "missing declared query field: " & k)
  let direction = dirOf(strField(seqNo, qRaw, "sort_tp", "declared query field"))
  let stexTp = strField(seqNo, qRaw, "stex_tp", "declared query field")
  if stexTp != krxStexTp:
    raise rerr(seqNo, vfContract,
               "stex_tp " & stexTp & " is outside the candidate universe: " &
               "candidate selection is KRX-only, stex_tp " & krxStexTp &
               " (REPLAY_CONTRACT §12.1)")
  initKa10027Query(direction,
    strField(seqNo, qRaw, "mrkt_tp", "declared query field"),
    strField(seqNo, qRaw, "trde_qty_cnd", "declared query field"),
    strField(seqNo, qRaw, "stk_cnd", "declared query field"),
    strField(seqNo, qRaw, "crd_cnd", "declared query field"),
    strField(seqNo, qRaw, "updown_incls", "declared query field"),
    strField(seqNo, qRaw, "pric_cnd", "declared query field"),
    strField(seqNo, qRaw, "trde_prica_cnd", "declared query field"),
    stexTp)

proc parseAttempt*(seqNo: int; raw: HcjValue): RestRespAttempt =
  ## Parse and validate one rest_resp record payload: schema, declared
  ## request scope, page index, preserved response metadata and body bytes.
  ## Record-level failures raise here, at the record's own seq. The body's
  ## success affirmation and the chain-level rules (cont-yn repeat, page
  ## cap, 1..N order) are stream properties: verifyAttempts applies them to
  ## the complete record set and still rejects the whole stream.
  try:
    if raw.kind != hkObj:
      raise rerr(seqNo, vfContract,
                 "rest_resp raw is not an object: " & kindName(raw))
    for p in raw.pairs:
      if not inArr(p.k, restRespFields):
        raise rerr(seqNo, vfContract,
                   "unknown rest_resp field: " & p.k & " (the record schema " &
                   "is exactly " & restRespFields.join(", ") & ")")
    let apiId = strField(seqNo, raw, "api_id", "rest_resp field")
    if apiId != ka10027ApiId:
      raise rerr(seqNo, vfContract,
                 "rest_resp api_id is outside the declared acceptance path " &
                 "(only " & ka10027ApiId & " is declared, REPLAY_CONTRACT " &
                 "§12.1): " & apiId)
    let page = intField(seqNo, raw, "page", "rest_resp field")
    if page < 1:
      raise rerr(seqNo, vfContract,
                 "rest_resp page index must be >= 1: " & $page)
    let scope = parseScope(seqNo, objField(seqNo, raw, "query", "rest_resp field"))
    let status = intField(seqNo, raw, "status", "rest_resp field")
    let contYn = strField(seqNo, raw, "cont_yn", "rest_resp field")
    let nextKey = strField(seqNo, raw, "next_key", "rest_resp field")
    let body = bytesFromHex(strField(seqNo, raw, "body_hex", "rest_resp field"))
    let resp = httpResp(apiId, status, contYn, nextKey, body)
    RestRespAttempt(seqNo: seqNo, scope: scope, page: page, resp: resp,
                    bodySha256: sha256Hex(resp))
  except RestRespError as e:
    if e.seqNo == 0:
      raise rerr(seqNo, e.failure, e.msg)
    raise e
  except VendorInputError as e:
    raise rerr(seqNo, e.failure, e.msg)
  except HcjError as e:
    raise rerr(seqNo, vfContract, e.msg)

# ---------------------------------------------------------------- chain audit

proc scopeKey*(scope: Ka10027Query): string =
  ## Canonical text of the declared request scope: the page-chain grouping
  ## key (identical declared queries share one chain).
  canonical(ka10027RequestBody(scope))

proc verifyAttempts*(attempts: seq[RestRespAttempt];
                     pageCap: int = defaultPageCap;
                     pollSeconds: int = 0): seq[RestRespAttempt] =
  ## Audit the declared page chains of a complete stream and return the
  ## verified attempts (confirmed success, in stream order). Any failure
  ## raises; a partial result is never returned. Per declared scope, in
  ## stream order: pages must run 1..N without gaps, duplicates or restarts,
  ## and the whole chain must pass vendor_input.normalizeChain -- the same
  ## success affirmation and cont-yn/page-cap rules as the vendor layer.
  ##
  ## pollSeconds is the config-declared re-poll cadence (README §6.1, the
  ## "approved extension path" rest_resp reserves). 0 (undeclared) keeps the
  ## historical single-chain rule: a page-1 restart inside a scope is a
  ## REJECT. Declared (> 0), each page-1 record opens a new round of that
  ## scope's chain -- the initial lookup and the re-poll rounds coexist --
  ## and every round is itself audited as a full 1..N chain with a terminal
  ## cont_yn (normalizeChain), so an unterminated re-poll chain is still
  ## never a success.
  if attempts.len == 0: return
  var keys: seq[string]
  var groups: seq[seq[RestRespAttempt]]
  for a in attempts:
    let k = scopeKey(a.scope)
    var gi = -1
    for i, x in keys:
      if x == k:
        gi = i
        break
    if gi < 0:
      keys.add(k)
      groups.add(@[])
      gi = keys.len - 1
    groups[gi].add(a)
  proc auditChain(g: seq[RestRespAttempt]): seq[RestRespAttempt] =
    if g.len == 0: return
    if g[0].page != 1:
      raise rerr(g[0].seqNo, vfContract,
                 "declared page chain does not start at page 1 (first " &
                 "recorded index " & $g[0].page & "): a chain without its " &
                 "first page is missing data; rejected fail-closed")
    for i, a in g:
      if a.page != i + 1:
        if a.page == 1:
          raise rerr(a.seqNo, vfContract,
                     "declared scope repeats page 1 before its chain ended: " &
                     "a page-chain restart is an undeclared refresh cadence " &
                     "or a duplicated capture (REPLAY_CONTRACT §12.1); " &
                     "rejected fail-closed")
        raise rerr(a.seqNo, vfContract,
                   "page index " & $a.page & " leaves a gap in the 1..N " &
                   "continuation (expected " & $(i + 1) & "); rejected " &
                   "fail-closed")
    var pages: seq[RawHttpResp]
    for a in g:
      pages.add(a.resp)
    let chain = PageChain(query: g[0].scope, pages: pages)
    try:
      discard normalizeChain(ka10027Spec, chain, pageCap)
    except VendorInputError as e:
      raise rerr(g[0].seqNo, e.failure,
                 "ka10027 page chain (sort_tp " &
                 sortTpOf(g[0].scope.direction) & ", " & $g.len &
                 " page(s)): " & e.msg)
    for a in g:
      result.add(a)
  for g in groups:
    if pollSeconds <= 0:
      for a in auditChain(g):
        result.add(a)
    else:
      # Declared cadence: split the scope's stream-order pages into rounds
      # at each page-1 record and audit every round on its own.
      var rounds: seq[seq[RestRespAttempt]]
      for a in g:
        if a.page == 1:
          rounds.add(@[a])
        else:
          if rounds.len == 0:
            raise rerr(a.seqNo, vfContract,
                       "declared page chain does not start at page 1 (first " &
                       "recorded index " & $a.page & "): a chain without " &
                       "its first page is missing data; rejected fail-closed")
          rounds[^1].add(a)
      for r in rounds:
        for a in auditChain(r):
          result.add(a)
  result.sort(proc (a, b: RestRespAttempt): int = cmp(a.seqNo, b.seqNo))
