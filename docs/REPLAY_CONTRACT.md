# Hong Scanner — Replay Contract (VS-1 baseline, v6.1)

This file is the executable contract. Every statement here is enforced by
`tests/test_all.nim`; if code and this document disagree, the test suite is
the tiebreaker and one of them must be fixed before a run is accepted.

## 1. Purpose

Given the same input stream, the same binary and the same calendar, Core must
produce byte-identical `bars.hcj.jsonl` and `signals.hcj.jsonl`. Provenance
then answers a different question: was that binary built from canonical main?

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

Exactly nine kinds exist. Unknown kinds are rejected (exit 2).

Consumed by Core (six):

| kind | role |
|---|---|
| `calendar` | session days; `days[date].open/close` are the only source of session bounds |
| `config` | `session_date` (required) + `params`; the only source of the run date |
| `ws_frame` | one trade tick: `symbol`, `t` (`HH:MM:SS+09:00`), `price` (int), `vol` (cumulative int), `m` (field 290, optional) |
| `rest_resp` | terminal record of one REST attempt (success, HTTP/vendor error, or transport failure) |
| `gap` | `symbol` (string or null) — a period whose data cannot be trusted |
| `session_end` | explicit normal close; `raw` is `null` |

Ignored by Core (three, diagnostic only):

`out_frame`, `ws_conn`, `pong`.

`ws_conn` describes how a connection changed; `gap` describes which data is
untrustworthy. They are recorded separately and only `gap` has authority.

`rest_resp` is consumed but not yet used for any verdict in VS-1 (there is no
REST producer in VS-1). VS-2 candidate selection will consume it.

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
`session_end`. A tick that belongs to an already closed bar invalidates the
whole run: `LATE_TICK_INTO_CLOSED_BAR` (exit 5). A backwards tick inside the
open bar only marks that bar `out_of_order` + `degraded`.

A `gap` closes the open bar as `gap_edge:"before"` and makes the next bar of
**each affected symbol** `after_gap`. A connection-wide gap (`symbol:null`)
applies to every subscribed symbol; release is per symbol, at that symbol's
own first later frame. A symbol that never returns stays unresolved.

## 6. Signals

Two independent state machines share the same closed bars. There is no
`short`; the output vocabulary is `bullish_pullback_reversal`,
`bearish_rebound_failure`, and `SIGNAL_HELD`.

- `SIGNAL_HELD` replaces a verdict on a degraded bar and carries `reason`:
  `gap`, `empty_gap`, `out_of_order`, `first_after_sub`, `flag_conflict`,
  `degraded_bar`. Real signals carry `reason:""`.
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
| `signals.hcj.jsonl` | yes | yes |
| `run.json` | no | no |
| `CHECKSUMS.sha256` | yes | — |

`CHECKSUMS.sha256` has exactly three lines, sorted by file name:
`<sha256hex>  <name>`, where the hash is over the file bytes.

`bars.hcj.jsonl` fields: `bar_index, bar_position, close, close_boundary,
closed, degraded, empty, gap_edge, high, low, open, out_of_order,
session_class, symbol, ticks, vol, vol_partial`.

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
| 4 | `VERDICT INCOMPLETE` (no `session_end`) |
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