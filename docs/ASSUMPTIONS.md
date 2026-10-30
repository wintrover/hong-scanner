# Hong Scanner — Assumptions: MUST vs everything else

Only **MUST** rows are requirements. Every other row is a verifiable or
changeable assumption; treating one as a requirement is what stalled v1–v5.

## MUST

| id | requirement | enforced by |
|---|---|---|
| M1 | same Core input + code + calendar ⇒ byte-identical `bars` and `signals` | `NO_EFFECT`, `CLOCK_INVARIANT`, `verify` |
| M2 | the run date comes only from `config.session_date` | `replay.runCore` signature (no date parameter) |
| M3 | normal end is declared by `session_end`, never by EOF | `VERDICT INCOMPLETE` (exit 4) |
| M4 | a tick into a closed bar invalidates the run | `LATE_TICK_INTO_CLOSED_BAR` (exit 5) |
| M5 | unknown record kinds and seq discontinuity are rejected | `REJECT` tests (exit 2) |
| M6 | session bounds and alignment come from the calendar | `SESSION_NOT_BAR_ALIGNED`, `CALENDAR_COVERAGE_UNKNOWN` (exit 3) |
| M7 | every signal references a closed bar | `no_signal_for_open_bar` test |
| M8 | canonical main build must be clean, on main, equal to origin/main | `tools/build.sh` |
| M9 | `MATCH` requires all five provenance comparisons | `verifyRun` |
| M10 | CI must not fetch market data | fixtures are committed, tests closed-book |

## POLICY (a chosen contract, changeable by decision)

| id | policy | alternative |
|---|---|---|
| P1 | single `seq` gauge; diagnostic records may be inserted/deleted after record 2 and renumbered | dual counter (rejected: more coupling, no stronger guarantee) |
| P2 | 290 conflict ⇒ exclude + degrade, abort round above 0.5% | trust the window (rejected: v3 contradiction) |
| P3 | first observed cumulative volume contributes 0 and marks `vol_partial` | treat first value as volume (unproven) |
| P4 | `gap` is the authority for untrusted data; `ws_conn` is diagnostic | infer gaps from 180 s silence only (rejected: misses short drops) |
| P5 | exit codes 0/2/3/4/5/6/7 | separate codes per command |
| P6 | no `--allow-dirty`; debugging builds stay non-canonical | escape hatch (rejected) |
| P7 | public repo + synthetic CI; calendars gitignored | private repo (not needed for CI minutes) |
| P8 | candidates are queried via `ka10027` with `stex_tp="1"` and one query per direction (`sort_tp="1"`/`"3"`); query scope and page upper limit are declared and recorded (VS-2 target, no producer yet) | any other universe or uncapped pagination (unapproved) |
| P9 | approval is a separate decision with its own conditions (GATES); `session_end` and `VERDICT MATCH` never imply approval | treat MATCH as approval (rejected) |
| P10 | `NO_TRIGGER_OBSERVED` is only for complete, valid runs, and only describes the observed stream | read zero signals as market-level absence (rejected: tick completeness is not guaranteed) |

## IMPLEMENTATION CHOICE (free to change without breaking the contract)

| id | choice |
|---|---|
| I1 | pure-Nim SHA-256 (`src/hs/digest.nim`); no Nimble dependency |
| I2 | Nim 2.2.10 pinned exactly |
| I3 | VS-1 implements a Core, Replay and CLI; a standalone recorder exists, but live collection and supervision remain unimplemented VS-2 work |
| I4 | `-d` injection for build provenance instead of a generated source file |
| I5 | checksum manifest is three sorted lines |
| I6 | `bar_position` and `session_class` stored on the bar record |

## UNKNOWN (must be measured, not assumed)

| id | unknown | resolution gate |
|---|---|---|
| U1 | live WebSocket behaviour vs the documented client semantics (vendor facts below) | G2 (credentials) |
| U2 | meaning and reset window of cumulative volume `13` | G4 |
| U3 | start/end timestamp convention of REST bars | G4 |
| U4 | `290` behaviour at the closing auction | G4 |
| U5 | fixed egress IP availability and cost on the target account | deployment (not started) |
| U6 | real signal frequency and false-positive rate | PH-1/PH-2 |
| U7 | durability under power loss | VS-2 drill |
| U8 | whether the live feed drops ticks silently (0B delivery completeness) — no provider sequence or completeness contract exists (full-text search of all 337 API specs: zero hits), so client logs alone cannot prove absence | G2: WS-derived volume vs REST `acc_trde_qty` |
| U9 | an adequate ka10027 page upper limit (candidates missed by the cap) | PH-1 / G2 |

## Vendor facts (official sources, 2026-10-30)

Verified from the official Kiwoom OpenAPI repository (spec JSON, client
sources), PyPI metadata, and websockets/keyring documentation. These are
trust facts: cite them, do not re-derive them. Live confirmation of each
still requires G2 credentials.

- REG/REMOVE ACK exists (`return_code` 0 normal / 1 error, sent only on
  register/remove); the official client does not wait for it — only LOGIN
  has a dedicated ack wait. Subscription confirmation is therefore possible
  in principle, but waiting for it is a scanner-side policy decision.
- The `0s` channel (registered with no symbols) delivers market-state
  FID 215 (2 pre-close notice 15:20, 4 close 15:30, 8 regular-close,
  9 full close after 18:00). It is the only documented normal-close signal;
  no ordering guarantee vs `0B` frames.
- PING echoes the received payload; the keep-alive period is not documented.
  `trnm=SYSTEM` terminates the stream in the official client; its meaning is
  undocumented. A server close has no documented semantics.
- The mock API still requires portal-issued demo appkey/secretkey (mode
  mismatch 8030/8031; mock-unsupported 8104).
- The official `kwcli` (PyPI) requires Python >= 3.13 (this system has 3.12;
  `uv python install 3.13` is the official path) and stores credentials in
  the Secret Service, which needs a D-Bus session bus — a systemd `--user`
  unit must set `DBUS_SESSION_BUS_ADDRESS` explicitly. Token cache:
  `~/.cache/kiwoom/<mode>-token.json`; env fallbacks exist.
- Kiwoom SDK license: use is permitted for OpenAPI service purposes, but
  copying, distributing, modifying or bundling the SDK in this repository is
  not. Vendor code stays an external local installation, never repo content.
- `websockets` `recv(decode=False)` returns the application payload bytes
  (text included) after fragment reassembly — the evidence boundary of
  REPLAY_CONTRACT.md §12.2.

## Trust boundary

Facts about the platform (GitHub rules, GitHub Actions workflow semantics,
systemd timer syntax, RFC 6455 text) are **trust facts**: cite them, do not
re-derive them. What a CI run certifies is bounded to its runner and the
workflow file at that sha; it cannot see what is installed on the host, so
attestation (not CI green) has to bridge that gap. Actions the platform
already performs (branch protection, timer scheduling, TLS, SHA-256 in the
vendor docs) are **execution adapters**: delegate, do not reimplement. The
only thing Hong Scanner implements itself is the part no platform provides:
the deterministic verdict over a recorded input stream.