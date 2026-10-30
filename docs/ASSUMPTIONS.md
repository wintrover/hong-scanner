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
| P11 | the config record may declare `environment` (`demo` or `prod`); verify enforces the commit-marker gate only for a declared environment, and synthetic streams report the marker state without enforcing it | enforcing the marker gate on synthetic streams (rejected: CI has no recorder) |
| P12 | durable completion = sealed artifacts + a valid commit marker (`hong-scanner-commit/1`); "recorded" never implies "committed" | trusting the seal alone (rejected: the fsync window leaves the state ambiguous) |
| P13 | the commit marker's `t` is the only wall-clock input at the recorder adapter boundary; Core still has none | timestamps in Core (rejected: M1) |
| P14 | subscription REGs are single-type in the official example form, refresh `"1"`, grp_no `"1"`; `0s` is registered by its own REG and never enters a 0B replacement request; a swap is REMOVE(outgoing) → ack → REG(incoming, refresh `"1"`) → ack; refresh `"0"` is never sent | multi-type REG with 0s auto-added (rejected: no official precedent, V1) |
| P15 | subscription confirmation records REG/REMOVE acks; `activeSets` reflects ack `return_code` 0 only | trusting requests alone (rejected: a request is not evidence) |

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
| U10 | refresh=0's termination scope, grp_no scope semantics, REMOVE partial-removal behavior, multi-type REG acceptance (official wording absent for all four) | G2 mock subscription experiments |
| U11 | Kiwoom PING period and no-response policy | G2 (ws_raw PING records) |
| U12 | the full FID 215 value table beyond the evidenced close subset {2, 4, 8, 9} | G2 observation |

## Vendor facts (official sources, 2026-10-30)

Verified from the official Kiwoom OpenAPI repository (spec JSON, client
sources), PyPI metadata, and websockets/keyring documentation. These are
trust facts: cite them, do not re-derive them. Live confirmation of each
still requires G2 credentials.

- REG/REMOVE wire form (official spec JSON, SDK `packets.py`, portal
  guide): REG = `{trnm:"REG", grp_no, refresh, data:[{item, type}]}`;
  REMOVE is the same structure without refresh (SDK
  `build_remove_packet`; no official REMOVE example exists). refresh
  (한글명 기존등록유지여부, required) 원문: "등록(REG)시 0:기존유지안함
  1:기존유지(Default) 0일경우 기존등록한 item/type은 해지, 1일경우
  기존등록한 item/type 유지 해지(REMOVE)시 값 불필요". The termination
  scope of refresh=0 (전역 / 같은 grp_no / 같은 type) has no official
  wording (UNVERIFIED). grp_no (그룹번호) has an empty description; all
  46 official examples (국내 38 + 미국 8) pin "1". Every official
  example is a single-type REG (one `{item, type}` entry, refresh "1");
  a multi-type REG has no official precedent and no official prohibition
  (UNVERIFIED). REMOVE partial removal is undocumented (UNVERIFIED).
- REG/REMOVE ACK exists (`return_code` 0 normal / 1 error, sent only on
  register/remove); the official client does not wait for it — only LOGIN
  has a dedicated ack wait. Subscription confirmation is therefore possible
  in principle, but waiting for it is a scanner-side policy decision.
- The `0s` channel (registered with no symbols) delivers market-state
  FID 215. The evidenced values are the close subset 2 (pre-close notice
  15:20), 4 (close 15:30), 8 (regular close), 9 (full close, only after
  18:00); the full value table is larger and UNVERIFIED. It is the only
  documented normal-close signal; no ordering guarantee vs `0B` frames.
- Kiwoom application-level PING: the server sends `trnm:"PING"` and the
  official clients echo it back (portal samples in three languages,
  "수신값 그대로 송신"; the SDK `_receive_non_ping_message` re-sends the
  parsed message — a logical echo re-serialized via json.dumps). The
  evidence is the samples and SDK code only: the 337-API spec JSON has
  zero "ping" mentions. The SDK connects with `ping_interval=None`
  (client-initiated RFC 6455 pings off; the library still answers
  server-side protocol pings). The PING period and no-response policy
  are undocumented (UNVERIFIED). `trnm=SYSTEM` terminates the stream in
  the official client; its meaning is undocumented. A server close has
  no documented semantics.
- Mock vs real (portal 모의투자 이용안내 · 서비스 이용안내 · notices ·
  spec JSON · SDK): 모의투자 is a "가상 매매 시스템" and Kiwoom
  recommends "디버깅과 테스트를 위하여 실제 환경 적용 전에 모의투자로
  접속하여 충분한 테스트" — a test stage, not an equivalent feed. No
  official statement claims mock-feed identity with the production feed
  (UNVERIFIED); the opposite direction is documented — notice #48:
  "(단, 모의투자의 경우 제공 기능 및 데이터에 일부 차이가 있을 수
  있습니다.)". NXT trading is mock-unsupported (시세만 제공). Error
  codes: 8104 "모의투자에서 지원하지 않는 API 입니다.", 8030/8031
  투자구분(실전/모의) mismatch. Domains: mock REST
  `https://mockapi.kiwoom.com`; mock WS `wss://mockapi.kiwoom.com:10000`
  (SDK `DEFAULT_WS_BASE_URLS["demo"]`). "실제 투자와 모의투자 App Key를
  별도로 관리합니다." Mock rate limit: TR 1초 1회 per account/토큰
  (notice #49). The 모의투자 운영규정 text itself is UNVERIFIED (SPA, not
  statically retrievable).
- Durability evidence (man-pages, POSIX.1-2024, SQLite, LevelDB,
  PostgreSQL): fsync(2) flushes file data and metadata, but "Calling
  fsync() does not necessarily ensure that the entry in the directory
  containing the file has also reached disk. For that an explicit fsync()
  on a file descriptor for the directory is also needed"; POSIX adds
  "If the fsync() function fails, outstanding I/O operations are not
  guaranteed to have been completed". write(2): "A successful return
  from write() does not make any guarantee that data has been committed
  to disk." Completed-work markers are separate from the data in SQLite
  (rollback-journal deletion is the commit instant; WAL's "last valid
  commit record"), LevelDB (CURRENT names the committed MANIFEST) and
  PostgreSQL (WAL records protected by CRC-32C). Marker creation is
  atomic via open(2) `O_CREAT|O_EXCL`. Wording rule: no official
  document approves the recorder's whole finish order — each component
  (file fsync, directory fsync, separate marker, atomic marker
  creation, marker validation) carries its own official basis, and
  "marker mismatch = INVALID" is this design's application of the
  trust-only-a-valid-commit-marker principle, not a quoted rule. Data
  written between the 60 s fsyncs can still be lost, and no absolute
  power-loss guarantee exists.
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