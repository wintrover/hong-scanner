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

## IMPLEMENTATION CHOICE (free to change without breaking the contract)

| id | choice |
|---|---|
| I1 | pure-Nim SHA-256 (`src/hs/digest.nim`); no Nimble dependency |
| I2 | Nim 2.2.10 pinned exactly |
| I3 | one process, four modules (recorder/core/replay/supervisor skeleton) |
| I4 | `-d` injection for build provenance instead of a generated source file |
| I5 | checksum manifest is three sorted lines |
| I6 | `bar_position` and `session_class` stored on the bar record |

## UNKNOWN (must be measured, not assumed)

| id | unknown | resolution gate |
|---|---|---|
| U1 | WebSocket handshake/framing behaviour of the vendor | G2 (credentials) |
| U2 | meaning and reset window of cumulative volume `13` | G4 |
| U3 | start/end timestamp convention of REST bars | G4 |
| U4 | `290` behaviour at the closing auction | G4 |
| U5 | fixed egress IP availability and cost on the target account | deployment (not started) |
| U6 | real signal frequency and false-positive rate | PH-1/PH-2 |
| U7 | durability under power loss | VS-2 drill |

## Trust boundary

Facts about the platform (GitHub rules, systemd timer syntax, RFC 6455 text)
are **trust facts**: cite them, do not re-derive them. Actions the platform
already performs (branch protection, timer scheduling, TLS, SHA-256 in the
vendor docs) are **execution adapters**: delegate, do not reimplement. The
only thing Hong Scanner implements itself is the part no platform provides:
the deterministic verdict over a recorded input stream.