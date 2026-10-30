# Hong Scanner — Limits of the current evidence

What the VS-1 result does **not** prove. Each line names who owns the proof.

| limit | why it matters | owner |
|---|---|---|
| `sha256` equality is byte identity, not correctness | a wrong price recorded consistently still matches | G4 |
| CI uses synthetic fixtures only | CI proves algorithm stability, not market behaviour | PH-1 |
| `13` (cumulative volume) semantics are unconfirmed | `bar_position` marks suspicion; it does not prove session-cumulative | G4 experiment (REST `acc_trde_qty` vs first `13`) |
| REST bar timestamp interpretation needs source and live cross-check | the local official extract describes `cntr_tm` as the bar start; alignment with the WS feed is not yet measured | G4 |
| `290` boundary behaviour at 15:30 is undocumented | conflicts are counted, not resolved | G4 |
| SIGKILL drills do not prove power-loss durability | page cache survives process death; data written between the 60 s fsyncs can be lost and no absolute power-loss guarantee exists | VS-2 recorder drill |
| the standalone recorder is not a live collector | it is not wired to transport or the CLI; it does implement seal + commit marker + periodic fsync, but a live producer is VS-2 work | VS-2 |
| a recorded `session_end` is not proof of durable completion | verify requires a valid commit marker only for a declared `environment`; synthetic streams report the marker state without enforcing it | VS-2 approval |
| no WebSocket client exists in VS-1 | handshake, framing, masking, close codes are VS-2 work | VS-2 |
| strategy validity is not established | synthetic fixtures are not evidence of market behavior or profitability | PH-2 |
| `breakdown_bp` is parsed but not applied | its reference and comparison are undefined, so bearish candidates are held instead of emitted | strategy contract |
| strategy evidence windows are not a market-validity proof | tainted evidence is held within each algorithm's dependency window, but thresholds and actual vendor field semantics still require validation | PH-1/PH-2 |
| a late session-flag conflict can degrade a closed bar in batch replay | live emissions need a finality or retraction contract before they are published | VS-2 live output contract |
| thresholds come from a synthetic fixture | PH-1 calibrates them on a real capture; that same session cannot also prove detection | PH-1/PH-2 |
| signals == 0 on a real day is not a bug | `NO_TRIGGER_OBSERVED` is a valid outcome | PH-2 |
| one market (KRX) only | the global goal needs a second adapter and the same acceptance evidence | V2 |
| `rest_resp` is schema-audited, not live-verified | a record that fails the declared §12.1 schema still rejects the run (exit 2); a verified page changes no output byte, and whether production responses match this shape is unmeasured | G2/G4 |
| the vendor provides no message-sequence or completeness contract | verified by full-text search of all 337 API specs (zero hits); a silent drop and a quiet market are indistinguishable from the client stream | G2 spot-check |
| the Kiwoom SDK is license-restricted | local install and use for the service are permitted; copying, modifying or bundling it in this repo is not — the adapter boundary must keep vendor code external | VS-2 adapter |
| the credential runtime has hard requirements | kwcli needs Python >= 3.13 (system has 3.12) and a D-Bus session bus for the Secret Service; bus resolution is `DBUS_SESSION_BUS_ADDRESS` (set → wins, avoids autolaunch) then the `$XDG_RUNTIME_DIR/bus` user-bus fallback — a systemd `--user` unit always gets `XDG_RUNTIME_DIR` but never the address variable automatically, so actual availability is proven only by runtime measurement (V-1~V-17); setting the variable explicitly stays a safe practice | VS-2 runtime |
| `run.json` is excluded from checksums | determinism covers the three data artifacts only | inherent |
| `provenance=OK` is self-declared consistency, not independent authenticity | compiler `-d` values and run metadata can be forged together; a match cannot prove the source tree was clean | trusted build and independent attestation design |
| previous runs require their original executable and calendar | the build gate builds the current main, while the run directory does not preserve the executable | run archive and retention design |
| the 0.5% conflict threshold is a policy choice | small samples can trip it; it is fail-closed by design | plan §3.2 |
| manager can still edit branch protection | GitHub cannot prevent a repo admin from changing the rules | P6 audit |
| Northflank fixed egress IP is unverified | no account in scope; U5 stays open | deployment |
| provider tick completeness is unverified | a silent feed drop and a quiet market can produce the same stream; `NO_TRIGGER_OBSERVED` speaks only about the observed stream | G2 spot-check (WS bars vs REST `acc_trde_qty`) |
| the ka10027 page cap is scanner-side | if more pages remain when the cap is reached, they are "not fetched", not "no more candidates" | VS-2 recorder contract |
| refresh=0's termination scope is undocumented | the official wording ("0일경우 기존등록한 item/type은 해지") does not say 전역/같은 grp_no/같은 type, so the scanner never sends refresh "0" | G2 mock subscription experiments |
| grp_no has no documented semantics | its description is empty; all 46 official examples pin "1" | G2 |
| REMOVE partial removal is undocumented | the scanner always REMOVEs a full generation, never a subset | G2 |
| multi-type REG acceptance is undocumented | all official examples are single-type; the composition cannot produce a mixed REG | G2 |
| the `0s` removal form is undocumented | the market-state channel ends with the connection; no REMOVE record exists for 0s | G2 |
| the Kiwoom PING period and no-response policy are undocumented | received PINGs are recorded as ws_raw so the period becomes observable | G2 |
| FID 215's full value table is unconfirmed | only the close subset {2, 4, 8, 9} is evidenced; 9 (전체장마감) occurs only after 18:00 | G2 observation |
| the 200-code subscription total is unreachable through the composition | the direction caps (≤100) bind first — 100+100 is the reachable boundary; `composeRemoveData` has no direction split, so its total cap is independently enforced and tested | inherent |
| demo observation success is not production evidence | Kiwoom documents the mock as a "가상 매매 시스템" test stage with "제공 기능 및 데이터에 일부 차이" possible, and claims no feed identity (UNVERIFIED) | PH-1 (separate production confirmation) |
| byte evidence excludes TLS, TCP framing and WS control frames | application payloads and non-secret pagination metadata do not expose every transport-level anomaly; the payload boundary is implementable as `websockets` `recv(decode=False)` (official docs, returns payload bytes after fragment reassembly) | VS-2 recorder contract |
| attestation evidence is per-merge, not standing | the attest→verify→install path is implemented and measured (GATES P13, twice); it must be re-measured after every behavior-changing main merge, and the verify line `provenance=OK` itself stays self-declared metadata — the digest chain, not that line, is what ties the installed binary to the exact main sha | P13 re-measurement |
| CI green is bounded trust | the workflow file and repo-admin actions sit inside the trust boundary; GitHub Actions cannot attest what is installed on the host | attestation design |
| strategy intervals and thresholds are held before approval | `warmup`/`lookback` windows and bp thresholds come from a synthetic fixture; signals before the PH-1 freeze are not acceptance evidence | PH-1 |

## Explicit non-goals

- No order execution, no shorting, no position sizing.
- No data in the repository: `calendars/*.json`, `runs/`, vendor extracts are
  gitignored; only `calendars/CALENDAR_INDEX.sha256` is committed.
- No claim that "22 selected RFC 6455 requirements" equals the whole RFC.
- No claim that a passing timer means the next KRX trading day; systemd only
  knows weekdays. The program decides trading days and SKIPs holidays.