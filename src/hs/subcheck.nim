## subcheck: the three Core consumption checks over the recorded
## subscription evidence (tools/collector/README.md §10, REPLAY_CONTRACT
## §12.5/§12.6). One pure state machine, shared by the live collector core
## and replay: both must quarantine exactly the same ticks.
##
## The guard consumes, in stream order:
##   - every ws_raw record's `conn` field (observeWsRaw) — strictly
##     monotonic connection generations; a decrease is a record
##     inconsistency and raises (fail-closed);
##   - every sub record (observeSub) — the exact activeSets bookkeeping of
##     sub_input.nim (acks with return_code 0 only, oldest-unmatched
##     (gen, action) pairing, refresh "0" underivable), plus:
##       * a matched (reg, ack 0) re-confirms the active set on the
##         connection generation current at that ack (stateConn),
##       * a matched (remove, ack 0) adds its codes to the removed set
##         until a later (reg, ack 0) re-registers them.
##
## The checks, evaluated per 0B tick (checkTick):
##   1. a tick for a symbol outside the active subscription set →
##      qkUnsubscribed (violates the confirmed-subscription boundary);
##   2. a tick for a symbol that a REMOVE ack took out and no REG ack has
##      brought back → qkPostRemove (a late event after removal);
##   3. a tick on a connection generation newer than the last
##      reg-ack-confirmed generation (a reconnect happened; the
##      registrations ACKed on the older connection are not valid on the
##      new one until a re-registration ack arrives) → qkStaleConn.
##      A REMOVE ack never re-validates: only a reg ack moves stateConn
##      (fail-closed — the new connection has confirmed nothing).
##
## Quarantine is NOT a REJECT (README §10): quarantined ticks never feed
## bars or signals, their count and reasons are recomputed deterministically
## at replay, and the verdict rules are documented there. The no-sub
## boundary: ws_frame synthetic ticks (VS-1) never pass through this guard;
## 0B ws_raw ticks in a stream with no subscription evidence at all
## quarantine (an honest result for data nobody subscribed to).
import std/[strutils, algorithm]
import sub_input

export SubAction, SubPhase, SubRecord, SubRegItem

type
  QuarantineKind* = enum
    qkNone
    qkUnsubscribed
    qkPostRemove
    qkStaleConn

  Quarantine* = object
    kind*: QuarantineKind
    detail*: string

  SubGuardError* = object of CatchableError

  SubGuard* = object
    ## Stream-order subscription evidence state. Owns no clock: everything
    ## here is derived from the records fed in, so replay recomputes the
    ## live collector's decisions byte-for-byte.
    conn: int                 ## last ws_raw conn generation seen (0 = none yet)
    stateConn: int            ## conn gen of the last confirming (reg, ack 0)
    pending: seq[tuple[gen: int, action: SubAction, rec: SubRecord]]
    active: seq[SubRegItem]   ## same content activeSets(subs) produces
    removed: seq[string]      ## removed by ack, not yet re-registered
    removeAcks0B: int         ## matched (remove, ack 0) naming "0B"
    regAcks0B: int            ## matched (reg, ack 0) naming "0B"

proc initSubGuard*(): SubGuard =
  SubGuard()

proc gerr(msg: string): ref SubGuardError =
  newException(SubGuardError, msg)

proc observeWsRaw*(g: var SubGuard; conn: int) =
  ## Advance the connection generation from a ws_raw record's conn field.
  if conn < 1:
    raise gerr("ws_raw conn generation must be >= 1: " & $conn)
  if conn < g.conn:
    raise gerr(
      "ws_raw conn generation went backwards: " & $conn & " after " & $g.conn &
      " (connection generations are strictly monotonic in a recorded stream)")
  g.conn = conn

proc active0BCodes*(g: SubGuard): seq[string] =
  ## The currently confirmed "0B" codes, sorted ascending (the active-set
  ## view; a type stays listed once acked even if all codes are removed).
  for it in g.active:
    if it.typ == candidateType:
      result = it.codes

proc isRemoved*(g: SubGuard; symbol: string): bool =
  symbol in g.removed

proc regAckCount0B*(g: SubGuard): int = g.regAcks0B

proc removeAckCount0B*(g: SubGuard): int = g.removeAcks0B

proc observeSub*(g: var SubGuard; rec: SubRecord) =
  ## Mirror activeSets over one sub record, plus the connection-generation
  ## bookkeeping the checks need. Raises exactly where activeSets raises
  ## (a refresh "0" registration makes the active set underivable).
  if rec.phase == spReq:
    if rec.action == saReg and rec.refresh == "0":
      raise gerr("active set is underivable at a refresh=0 registration " &
        "(the scanner policy sends refresh \"1\" REGs only)")
    g.pending.add((rec.gen, rec.action, rec))
    return
  # ack: pair with the oldest still-unmatched request of the same
  # (gen, action); an unmatched ack is a no-op (activeSets rule).
  var match = -1
  for i in 0 ..< g.pending.len:
    if g.pending[i].gen == rec.gen and g.pending[i].action == rec.action:
      match = i
      break
  if match < 0:
    return
  let req = g.pending[match].rec
  g.pending.delete(match)
  if rec.returnCode != 0:
    return
  case req.action
  of saReg:
    for ty in req.types.items:
      var idx = -1
      for i in 0 ..< g.active.len:
        if g.active[i].typ == ty:
          idx = i
          break
      if idx < 0:
        var codes = req.codes
        sort(codes, cmp)
        g.active.add(SubRegItem(typ: ty, codes: codes))
      else:
        for c in req.codes.items:
          if not g.active[idx].codes.contains(c):
            g.active[idx].codes.add(c)
        sort(g.active[idx].codes, cmp)
    # A reg ack is the only event that re-validates the active set on the
    # current connection (check 3). Without any ws_raw yet (synthetic
    # sub-only streams) stateConn stays 0 and every 0B tick quarantines —
    # an honest result for a stream with acks but no wire evidence.
    g.stateConn = g.conn
    for ty in req.types.items:
      if ty == candidateType:
        inc g.regAcks0B
    for c in req.codes.items:
      let pos = g.removed.find(c)
      if pos >= 0:
        g.removed.delete(pos)
  of saRemove:
    for ty in req.types.items:
      for i in 0 ..< g.active.len:
        if g.active[i].typ == ty:
          var kept: seq[string]
          for c in g.active[i].codes.items:
            if c notin req.codes:
              kept.add(c)
          g.active[i].codes = kept
          break
      if ty == candidateType and req.codes.len > 0:
        inc g.removeAcks0B
        for c in req.codes.items:
          if c notin g.removed:
            g.removed.add(c)

proc checkTick*(g: SubGuard; symbol: string): Quarantine =
  ## The three consumption checks for one 0B tick. qkNone means the symbol
  ## is inside the confirmed active set on the current connection.
  if g.stateConn != g.conn:
    return Quarantine(kind: qkStaleConn, detail:
      "subscriptions were last confirmed on connection generation " &
      $g.stateConn & " but the wire is on connection generation " & $g.conn &
      "; no re-registration ack has confirmed them on this connection")
  for it in g.active:
    if it.typ == candidateType and symbol in it.codes:
      return Quarantine(kind: qkNone)
  if symbol in g.removed:
    return Quarantine(kind: qkPostRemove, detail:
      "symbol " & symbol & " was removed by a REMOVE ack and no REG ack " &
      "has re-registered it; the tick is a late event after removal")
  Quarantine(kind: qkUnsubscribed, detail:
    "symbol " & symbol & " is not in the active subscription set " &
    "(0B codes: " & (if g.active0BCodes().len == 0: "none"
                     else: g.active0BCodes().join(",")) & ")")
