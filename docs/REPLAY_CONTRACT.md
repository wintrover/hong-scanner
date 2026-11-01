# Hong Scanner — Replay Contract (VS-1 baseline, VS-2/VS-3 targets, v6.3)

This document states the intended VS-1 contract. Tests cover selected cases;
passing them does not prove every statement or replace review of the actual
implementation.

## 1. Purpose

Given the same input stream, the same binary and the same calendar, Core must
produce byte-identical `bars.hcj.jsonl` and `signals.hcj.jsonl`. Provenance
checks consistency with the binary's self-declared build metadata; it does not
independently prove that the binary came from canonical main.

## 2. Input stream

One file, `input.hcj.jsonl`, one HCJ document per line.

- Encoding: UTF-8, LF line endings, every line ends with LF. BOM, CRLF and
  blank lines are rejected (`hcj.readHcjTextLines`).
- Envelope: `{"kind":<string>,"raw":<value>,"seq":<int>}`, canonical key order.
- `seq` is a **gauge**: it proves physical order and detects loss, reordering
  and duplication. Its absolute value is never emitted in any artifact.
- Rule 1: `seq` must be `1..N` in physical file order (`REJECT`, exit 2).
- Rule 2: records 1 and 2 are always `calendar` and `config`. No other
  `calendar`/`config` record is allowed (`REJECT`, exit 2).
- Rule 3: diagnostic records may be inserted or deleted **after record 2**
  and the remaining records renumbered. This operation must not change one
  output byte (`NO_EFFECT`).

## 3. Record kinds

Exactly eleven kinds exist. Unknown kinds are rejected (exit 2).

Consumed by Core (eight):

| kind | role |
|---|---|
| `calendar` | session days; `days[date].open/close` are the only source of session bounds |
| `config` | `session_date` (required) + `params`; the only source of the run date |
| `ws_frame` | one trade tick: `symbol`, `t` (`HH:MM:SS+09:00`), `price` (int), `vol` (cumulative int), `m` (field 290, optional) |
| `rest_resp` | terminal record of one REST attempt (success, HTTP/vendor error, or transport failure) |
| `sub` | one subscription request or acknowledgement (validated acceptance) |
| `ws_raw` | one preserved WebSocket application payload, hex-encoded (validated acceptance) |
| `gap` | `symbol` (string or null) — a period whose data cannot be trusted |
| `session_end` | explicit normal close; `raw` is `null` |

Ignored by Core (three, diagnostic only):

`out_frame`, `ws_conn`, `pong`.

`ws_conn` describes how a connection changed; `gap` describes which data is
untrustworthy. They are recorded separately and only `gap` has authority.

Until a live producer is measured, `rest_resp`, `sub` and `ws_raw` follow a
**validated acceptance path**: each record parses against its declared
schema (§12.1 for `rest_resp`; the `sub_input` rules for `sub`/`ws_raw`,
documented in §12.6/§12.7) and the complete stream's declared page chains
are audited. A record that fails its schema rejects the run at its own seq
(exit 2); a chain-level failure rejects the whole stream. Verified records
are counted (`restVerified`, `subCount`, `wsRawCount`) and change no output
byte. The live wire format itself is still unmeasured (G2/G4).

## 4. Session-class (field 290)

`m` carries the vendor session flag (`1` pre-market, `2` regular, `3` post).
The calendar window is a fail-closed detector, not a fallback.

| condition | class | effect |
|---|---|---|
| `m=="2"` and `open <= t <= close` | `in_session` | tick enters a bar |
| `m in {"1","3"}` and (`t < open` or `t > close`) | `out_of_session` | excluded, counted |
| any other combination | `conflict` | excluded, counted, affected interval degraded |
| `m` missing or unknown | `unknown` | excluded, counted, affected interval degraded |

A conflict never picks a side. If `conflicts / frames > 0.5%`, the round is
aborted: `VERDICT INVALID provenance=UNRELIABLE` (exit 5). The affected
interval is marked degraded only when a bar exists for it; no bar is invented.

## 5. Bars

```
i(t) = floor((t - open) / 180s)          interval [open+180i, open+180(i+1))
t == close  -> i = n_bars-1, close_boundary = true
t < open or t > close -> out_of_session (excluded)
(close - open) mod 180 != 0 -> SESSION_NOT_BAR_ALIGNED (exit 3)
```

`n_bars = (close - open) / 180` comes from the calendar; no 09:00/15:30
constant exists in code. `09:03:00` is bar 1; `15:30:00` is the last bar with
`close_boundary`; `15:30:01` is out of session (or a conflict if `m=="2"`).

Volume is a **boundary difference** of the cumulative field, not a sum:
`vol(bar n) = cum(last frame of bar n) - cum(last frame of bar n-1)`.
A negative delta is clamped to 0 and marks the bar degraded. The first
observation of a symbol contributes 0 and marks the bar `vol_partial`.

`bar_position` values: `first_after_sub`, `steady`, `after_gap`, `empty_gap`.
`first_after_sub` and `after_gap` are always `vol_partial` and `degraded`.

Bars are closed by the next bar's first frame, by a `gap`, or by
`session_end`. An in-session tick that belongs to an already closed bar
invalidates the whole run: `LATE_TICK_INTO_CLOSED_BAR` (exit 5). A backwards
tick inside the open bar only marks that bar `out_of_order` + `degraded`.
A conflicting or unknown session flag can currently mark an already-closed
bar degraded; this batch replay behavior does not establish a live signal
finality or retraction policy.

A `gap` closes the open bar as `gap_edge:"before"` and makes the next bar of
**each affected symbol** `after_gap`. A connection-wide gap (`symbol:null`)
marks each previously observed symbol; release is per symbol at that symbol's
own first later valid frame. An unresolved gap at session end is INCOMPLETE.
The current input contract does not include a subscription list, so symbols
that never produced a frame cannot be checked; live approval remains blocked.
(The target §12.6 `activeSets` derivation over `sub` records is the
basis the live subscription-set check will use.)

## 6. Signals

Two independent state machines share the same closed bars. There is no
`short`; the output vocabulary is `bullish_pullback_reversal`,
`bearish_rebound_failure`, and `SIGNAL_HELD`.

- A tainted bar cannot support a verdict. The bullish evidence window spans
  up to `2*lookback` prior bars; the bearish window spans `lookback` prior
  bars. A verdict that depends on degraded, partial-volume, empty, out-of-order
  or gap-marked evidence is held until the affected bar leaves its window.
  With `hold_on_degraded`, `SIGNAL_HELD` reports the most recent tainted
  bar's reason; otherwise the verdict is suppressed. Real signals carry
  `reason:""`.
- `breakdown_bp` has no approved reference price or comparison rule. A bearish
  candidate is therefore held with `breakdown_unverified`, never emitted as
  `bearish_rebound_failure`; evidence-window taint takes precedence. With
  `hold_on_degraded=false`, this hold is not emitted.
- Every signal references `(session_date, symbol, bar_index)` present in
  `bars.hcj.jsonl` with `closed:true`. A signal for an open bar is a contract
  violation (exit 2).
- Sort order is `(symbol, bar_index, signal)`; iteration order never leaks.

## 7. Artifacts

`runs/<date>/` contains:

| file | deterministic | checksummed |
|---|---|---|
| `input.hcj.jsonl` | yes | yes |
| `bars.hcj.jsonl` | yes | yes |
| `events.hcj.jsonl` | yes | yes |
| `signals.hcj.jsonl` | yes | yes |
| `run.json` | no | no |
| `CHECKSUMS.sha256` | yes | — |

`CHECKSUMS.sha256` has exactly four lines, sorted by file name:
`<sha256hex>  <name>`, where the hash is over the file bytes.

`bars.hcj.jsonl` fields: `bar_index, bar_position, close, close_boundary,
closed, degraded, empty, gap_edge, high, low, open, out_of_order,
session_class, symbol, ticks, vol, vol_partial`.

`events.hcj.jsonl` fields: `data_quality, event_id, event_type, evidence_ref,
observed_at, rule_id, rule_version, session_id, severity` — plus `direction`
and `rank` on candidate-transition facts (EXITED carries no rank) and
`symbol` on symbol-scoped facts. Closed facts: no record position, no
verification or delivery state. See §13.

`signals.hcj.jsonl` fields: `bar_index, price, reason, session_date, signal,
symbol`.

`run.json` fields: `bar_count, build{build_time,dirty,nim_version,
origin_main_sha,source_ref}, calendar_sha256, code_commit, config_sha256,
egress_ip, host, pid, run_id, session_date, signal_count, started_at`.

`config_sha256`/`calendar_sha256` are SHA-256 over the canonical bytes of
record 2 / record 1 **without** a trailing LF.

## 8. Provenance (five checks before any MATCH)

`verify` runs these against the verifying binary's embedded build info:

| # | check | failure |
|---|---|---|
| 1 | `run.json.code_commit` == binary `code_commit` | INVALID_PROVENANCE |
| 2 | `run.json.build.dirty == false` and binary `dirty == false` | INVALID_PROVENANCE |
| 3 | `run.json.build.nim_version` == binary `nim_version` | INVALID_PROVENANCE |
| 4 | `config_sha256` / `calendar_sha256` match records 2 / 1 | INVALID_PROVENANCE |
| 5 | `build.source_ref == "main"`, binary `source_ref == "main"`, and `origin_main_sha == code_commit` on both sides | INVALID_PROVENANCE |

The build gate (`tools/build.sh`) refuses to build unless the checkout is
`main`, clean, and `HEAD == origin/main`, then injects `code_commit`,
`source_ref`, `origin_main_sha` and `build_time` with `-d` switches. Any
plain `nim c` / `nimble build` keeps the dev marker (`dirty:true`,
`source_ref:"dev"`) and can never produce `provenance=OK`.

## 9. Exit codes

| code | meaning |
|---|---|
| 0 | `VERDICT MATCH provenance=OK` / command OK |
| 2 | contract violation (HCJ, record envelope, unknown kind, open-bar signal) |
| 3 | calendar (`CALENDAR_COVERAGE_UNKNOWN`, `SESSION_NOT_BAR_ALIGNED`) |
| 4 | `VERDICT INCOMPLETE` (no `session_end` or unresolved known-symbol gap) |
| 5 | invalid run (`LATE_TICK_INTO_CLOSED_BAR`, `SESSION_FLAG_UNRELIABLE`) |
| 6 | artifact mismatch (bytes or checksum manifest differ from replay) |
| 7 | invalid provenance |

## 10. Refutation classes (all covered by tests)

- `REJECT`: seq swap/duplicate, unknown kind, preamble violation,
  `session_end` not last.
- `EXPECTED_DELTA`: price change changes bars; volume regression holds the
  bar; 290 conflict holds the affected bar; `gap` degrades both edges.
- `NO_EFFECT`: inserting or rewriting `out_frame`/`ws_conn`/`pong` after
  record 2, with full renumbering, changes no output byte.
- `CLOCK_INVARIANT`: `TZ` does not affect output; Core has no clock input.

## 11. Two layers of reproducibility

**CI reproducibility** uses synthetic fixtures only and proves algorithm and
serialization stability. It never contacts a vendor or the network.

**Measured reproducibility** uses a real run directory: the input stream,
`run.json`, the calendar file that was in force (hash-pinned in
`calendars/CALENDAR_INDEX.sha256`) and the canonical binary. A third party
reproducing a measured run needs those files; the repository intentionally
does not contain market data.

`sha256` is a byte-identity tool. It is not evidence that prices are correct
(G4) or that the strategy is sound (PH-2).

## 12. Target additions beyond VS-1 (not implemented)

Everything in this section is **target contract**. VS-1 has no live REST or
WebSocket producer; `rest_resp` records are schema-audited (§3), not
live-verified. Passing VS-1 proves none
of the statements below, and none describes current live behavior.

### 12.1 Candidate selection (ka10027)

VS-2 candidate selection declares its query scope so that "candidate" stays
auditable:

- API: Kiwoom REST `ka10027` (전일대비등락률상위), `POST /api/dostk/rkinfo`.
- Exchange: `stex_tp="1"` (KRX). `2` (NXT) and `3` (통합) are outside the
  candidate universe.
- Direction: one query per direction — `sort_tp="1"` (rise-rate) and
  `sort_tp="3"` (fall-rate). Direction comes from the query itself, not
  from a sign convention on thresholds.
- The remaining body fields (`mrkt_tp`, `trde_qty_cnd`, `stk_cnd`,
  `crd_cnd`, `updown_incls`, `pric_cnd`, `trde_prica_cnd`) are pinned at
  approval time and recorded verbatim in the run's config record; before
  approval no value is fixed.
- The refresh cadence and candidate time-to-live are explicitly fixed in
  the approved configuration; until then live candidate decisions are held.
- Pagination follows the response headers `cont-yn`/`next-key` and is
  capped by a declared page upper limit. If more pages remain when the cap
  is reached, the result is `truncated`: those pages are "not fetched",
  never "no more candidates". The cap is a scanner-side declaration.
- Each attempt is recorded as a `rest_resp` record that carries the
  declared request scope and the page index, so replay can audit what was
  asked for and what came back.

### 12.2 Byte evidence (recorder scope)

The bytes preserved as evidence are exactly:

- REST: the HTTP response **body** bytes.
- WebSocket: the **application payload** bytes — RFC 6455 application data
  after de-framing and unmasking — not raw TCP bytes, not the frames, not
  control frames. In the `websockets` library this boundary is
  `recv(decode=False)` (official docs confirm text messages also arrive as
  bytes, after fragment reassembly).

Preserve request metadata, response status, and the non-secret pagination
headers required to replay candidate selection. Never preserve credentials,
tokens, Authorization headers, or login payloads; control messages are
separate from market data. TLS, TCP framing and WS control frames are outside
the raw evidence scope, so transport-level anomalies require explicit gap
or failure records rather than inference from the payload alone. Each
preserved WebSocket payload is recorded as one `ws_raw` record whose
`payload_hex` is exactly these bytes.

### 12.3 Normalization cross-check

HCJ records are normalized views (`price` int, cumulative `vol` int, `t`
timestamp). The target contract: every normalized record must be
re-derivable from the preserved bytes of §12.2, and the recorder checks
this before the record is accepted; a mismatch aborts the round. No
cross-check exists today because no producer exists.

### 12.4 `session_end`, approval and `NO_TRIGGER`

- `session_end` (M3) closes the stream and only that. It is not an
  approval; approval conditions are separate and live in GATES.md.
- Minimum close evidence (scanner termination policy): at least one
  observed `0s` FID 215 value in `{4, 8}` and a successful 0B REMOVE
  acknowledgement (§12.6). FID 215 = 9 (전체장마감) occurs only after
  18:00 and is recorded when observed but is never the minimum
  evidence; a run reaching the scanner's post-close watchdog (15:40
  KST) without a `{4,8}` observation ends INCOMPLETE, not normal.
- `NO_TRIGGER_OBSERVED` applies only when every run approval condition in
  GATES.md is met and means "no trigger in the observed stream".
- Without a verified provider sequence or completeness contract, absence in
  the stream is not evidence of absence in the market. Tick completeness
  is not claimed and cannot be verified from the client stream alone.

### 12.5 Vendor facts that constrain the VS-2 design

Verified facts (see ASSUMPTIONS.md "Vendor facts"); none is implemented yet:

- The only documented normal-close signal is the `0s` channel FID 215
  (market-state notifications). The evidenced values are the close
  subset 2 (pre-close notice 15:20), 4 (close 15:30), 8 (regular
  close), 9 (full close, only after 18:00); FID 215 carries further
  operation-state values that are not yet evidenced (full value table
  UNVERIFIED). Choosing it — or a scanner-side clock — as the
  `session_end` authority is an open policy decision; whatever is
  chosen must be a deterministic input record.
- REG/REMOVE ACK exists (`return_code` 0/1). Waiting for it would make
  subscription confirmation an auditable input; the official client does
  not wait. This is a scanner-side policy choice, not a vendor constraint.
- No provider sequence or completeness contract exists, so approval
  condition 3 (subscription confirmation) and U8 can only be closed by
  scanner-side evidence, never by trusting the stream.
- The vendor SDK stays an external local installation (license); the
  recorder adapter boundary must not copy or modify vendor code.

### 12.6 Subscription lifecycle (`sub` records: REG/REMOVE)

The wire envelope follows the official example form — all 46 official
examples (국내 38 + 미국 8) are exactly this shape: one REG request
carries exactly one `{item, type}` entry whose `type` list has a single
element, `refresh` `"1"` (the documented default), and `grp_no` `"1"`
(every official example; the field's own description is empty, so its
scope is UNVERIFIED). REMOVE is the same structure without `refresh`
("해지(REMOVE)시 값 불필요"; official SDK `build_remove_packet`; no
official REMOVE example exists). The `sub`/`ws_raw` record schemas and
the composition functions are the single source of truth in
`src/hs/sub_input.nim`; a `sub` record that fails its `(action, phase)`
schema rejects the run at its own seq (§3).

Scanner composition policy (`composeRegData`, `composeMarketStateReg`,
`composeRemoveData`, `activeSets` in the same module):

- The candidate REG is single-type: item = up then down codes (vendor
  order), type `["0B"]`, caps ≤100 per direction and ≤200 total
  (notice #49). The market-state REG is its own request: item = [],
  type `["0s"]` (the official 0s example's channel-only form). A REG
  mixing `0s` into a candidate replacement cannot be composed — the
  composition makes the invariant "0s never appears in a 0B replacement
  request" structural.
- Candidate swap = REMOVE(outgoing 0B generation) →
  ack(`return_code` 0) → REG(incoming 0B generation, refresh `"1"`) →
  ack. `refresh: "0"` is never sent: the official wording ("0일경우
  기존등록한 item/type은 해지") does not define the termination scope
  (전역 / 같은 grp_no / 같은 type), so its effect is UNVERIFIED.
- The end-of-session teardown REMOVE names the active 0B codes
  (non-empty, the full generation — the same rule as the `(remove,req)`
  record schema). `0s` is never a REMOVE target: its removal form is
  undocumented, so the market-state channel ends with the connection
  and its records stay available as close evidence.
- `activeSets` derives the active subscription state from the recorded
  stream deterministically: only acks with `return_code` 0 change state
  (requests alone never do — fail-closed), an ack pairs with the oldest
  unmatched request of the same `(gen, action)`, unmatched records are
  no-ops, and a `refresh: "0"` request makes the set underivable
  (rejected at its own seq). This is scanner-side bookkeeping, not a
  vendor-behavior claim.

UNVERIFIED (G2 mock subscription experiments before any live use):
refresh=0's termination scope, grp_no scope semantics, REMOVE
partial-removal behavior, and multi-type REG acceptance (no official
precedent and no official prohibition).

### 12.7 Kiwoom application-level PING

- The server sends an application message with `trnm: "PING"`; the
  official clients (portal samples in Python/Java/JavaScript and the
  SDK's `_receive_non_ping_message`) respond by echoing the received
  message back. The scanner sidecar echoes the received payload
  **bytes** — stricter than the SDK, which re-serializes the parsed
  dict (a logical echo).
- Client-initiated RFC 6455 pings are disabled (`ping_interval=None`,
  the official SDK's own `websockets` setting); the library still
  answers server-side protocol pings. The Kiwoom PING is an
  application message, distinct from RFC 6455 control frames, which are
  outside the §12.2 evidence scope.
- Every received PING is recorded as a `ws_raw` record (its `channel`
  distinguishes it from `0B`/`0s` traffic), so the keep-alive period
  becomes an observable. The period and the no-response policy are
  officially undocumented — the 337-API spec JSON contains zero "ping"
  mentions; the samples and SDK code are the only evidence — so both
  are G2 observation items, never assumed.

## 13. Events (VS-3 contract)

The judgment layer described in this section is implemented
(`src/hs/event_gen.nim`; §13.8 states exactly what exists and what does
not). The push transport, mobile client and delivery path are not
implemented, and nothing in this repository proves operational approval —
GATES P12 remains the only such authority. The record schemas are the
single source of truth: `contracts/events/event.schema.json` (the immutable
event fact) and `contracts/events/delivery.schema.json` (the operational
delivery record). The event contract suite (`tests/test_event_contract.nim`)
covers the schemas' structure, vocabularies, the committed fixture, the
deterministic id rule and the state separation; the judgment suite
(`tests/test_event_gen_contract.nim`) covers the implemented judgment
layer. Passing either proves no live producer and no delivery path exists.

### 13.1 One judgment function

Events are produced by exactly one deterministic function,
`step(state, record) -> (state', events)`, shared by the live and replay
paths. Separate live/replay event code is contractually forbidden: a second
judgment path would be a second definition of the facts. Delivery and
notification code may filter, order or translate events for transport; it
may never judge, upgrade, or rewrite them.

### 13.2 Record-first (write-ahead judgment)

Event judgment consumes RECORDED records: `step` sees only records already
in `input.hcj.jsonl` (§2). The input log precedes judgment (the WAL
principle), so after a crash the complete event history is reconstructible
by replaying the log. An event that cannot be derived from the log is not
a fact.

### 13.3 Single-writer order

Live consumers feed records to `step` strictly in recorder seq order — the
physical order §2 Rule 1 pins (`seq` 1..N). There is one writer and one
order, so live and replay see identical input sequences and therefore
identical events. No consumer may judge from a side channel or reorder
records before judgment.

### 13.4 Replay and byte-identity

Replay regenerates `events.hcj.jsonl` byte-identically, and `verify`
byte-compares the live-produced events file against the replayed one
before any MATCH is reported. The event id binds each fact to its recorded
position: `event_id` is the sha256 hex of the canonical serialization of
`(session_id, event_type, rule_id, entity, transition_seq)`, where entity
is the symbol or `*` and `transition_seq` is the input record seq at which
the transition was observed (the full rule is `x-event-id-rule` in the
schema). The seq value itself is never emitted (§2); it enters only this
one-way digest, and the record carries no position field.

Because ids bind to recorded positions, a §2 Rule 3 diagnostic
insert/delete (with renumbering) yields a different `events.hcj.jsonl` by
design; the NO_EFFECT class of §10 is stated over the Core artifacts of
§1 (`bars.hcj.jsonl`, `signals.hcj.jsonl`). Event byte-identity is defined
between the live-produced file and the replay of the same input bytes:
same input bytes, same event bytes.

### 13.5 Determinism boundary

Guaranteed — computation over the same recorded input:

- event generation (which events exist, in what order);
- event ids (the deterministic rule of §13.4);
- replay results (byte-identical `events.hcj.jsonl`).

Not guaranteed — everything downstream of the provider boundary:

- FCM (or any provider) arrival time;
- delivery order across devices or events;
- the device's display time;
- whether and when the user read the notification.

None of the unguaranteed outcomes may flow back into a fact, an id, or a
judgment.

### 13.6 Operational state is never fact state

Three states, three homes, never mixed in one record:

| state | home | mutable |
|---|---|---|
| importance / trust (`severity`, `data_quality`) | the event fact | no |
| verification | the session-level verify output | per session run |
| delivery (`state`, `attempts`, `error_code`) | delivery records | yes |

A fact never carries `verification_status` or delivery fields; adding them
would mutate the fact bytes and break replay byte-identity (§13.4). The
schemas enforce this structurally (`additionalProperties` false); the
event contract suite rejects both families by name.

### 13.7 Design principles

The six VS-3 design principles govern this contract and are referenced,
not duplicated: facts live on the server; one judgment logic;
notifications are transport; mobile is read-only; uncertainty is not
hidden; existing platform features are leveraged.

### 13.8 Implementation note (what exists, what does not)

Implemented — one judgment function, two drivers, one byte comparison:

- `step(state, record) -> (state', events)` and the end-of-stream judgment
  `finish(state)` live in `src/hs/event_gen.nim`. The replay path folds
  `eventsOfRecords` once over the consumed stream (`src/hs/replay.nim`);
  the live collector (`tools/collector/collector.nim`) appends the same
  `step` judgments per consumed record. There is no other judgment code.
- The live journal is `<out>/events.hcj.jsonl`, created exclusively
  (`O_CREAT|O_EXCL|O_NOFOLLOW`): an existing judgment log is never
  reopened or appended to. Events are appended at consume time (§13.2)
  and the seal's session_end record is judged through the same `step`.
- Replay writes `events.hcj.jsonl` as the fourth checksummed artifact
  (§7). `verify` byte-compares the run directory's file against the
  recomputation — a missing or differing file is a named MISMATCH issue,
  never a pass — and prints the recomputation hash as `EVENTS=<sha256>`
  on every verdict past the run-status gate. A drill carries the live
  bytes into the run directory byte-exact (the same staging the commit
  marker gets) so verify audits the artifact the collector wrote.
- Death/restart recovery is record-first reconstruction: the state is
  `stateAt(records consumed so far)`, and resuming the recorded stream
  from there reproduces exactly the missing events (covered by the
  judgment suite's recovery block).

Rules (all `rule_version: 1`; `evidence_ref` is the declared vendor scope
for candidate transitions, otherwise the content address of the consumed
record's canonical line):

| rule_id | event_type(s) | judged from | severity / data_quality |
|---|---|---|---|
| `candidate-transition-v1` | CANDIDATE_ENTERED / UPDATED / EXITED | completed ka10027 up+down chains (`evidence_ref` = `ka10027:stex_tp=1:sort_tp=1` or `…:sort_tp=3`); a code in both directions is judged once, up first; EXITED carries no rank | INFO / OBSERVING |
| `feed-disconnected-v1` | FEED_DISCONNECTED | ws_conn `closed_ok` (INFO) / `closed_error` (HIGH); `open` judges nothing | INFO or HIGH / INCOMPLETE |
| `gap-suspected-v1` | DATA_GAP_SUSPECTED | every gap record | HIGH / INCOMPLETE |
| `rest-truncated-v1` | REST_TRUNCATED | a gap record whose `what` is `rest_truncated` (second fact of the same record, distinct by event_type) | HIGH / INCOMPLETE |
| `market-state-unknown-v1` | MARKET_STATE_UNKNOWN | a 0s ws_raw payload whose FID 215 value is outside the evidenced set {2,4,8,9}; at most one per record | HIGH / UNKNOWN |
| `session-close-v1` | SESSION_ENDED | the session_end seal record | INFO / OBSERVING |
| `session-incomplete-v1` | SESSION_INCOMPLETE | `finish` on a consumed stream that never sealed; binds to the last consumed record | HIGH / INCOMPLETE |

Not implemented — vocabulary only (the schema defines the full
vocabulary; the implementation lags it):

- `REPLAY_MATCH`, `REPLAY_MISMATCH`, `SESSION_APPROVED` are session-level
  verify outputs, not `step` facts; the judgment layer emits none of them.
- Delivery records (`contracts/events/delivery.schema.json`), the push
  transport and the mobile client: none exist.

What the current evidence does not prove: byte-identity proven on
synthetic fixtures and a dev-build drill is mechanism, not operation — no
live market data, no real vendor stream, no delivery path, no GATES P12
observation. Any `NO_TRIGGER_OBSERVED`-style claim remains impossible
until a real observed stream exists.