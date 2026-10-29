# Hong Scanner — Limits of the current evidence

What the VS-1 result does **not** prove. Each line names who owns the proof.

| limit | why it matters | owner |
|---|---|---|
| `sha256` equality is byte identity, not correctness | a wrong price recorded consistently still matches | G4 |
| CI uses synthetic fixtures only | CI proves algorithm stability, not market behaviour | PH-1 |
| `13` (cumulative volume) semantics are unconfirmed | `bar_position` marks suspicion; it does not prove session-cumulative | G4 experiment (REST `acc_trde_qty` vs first `13`) |
| REST bar timestamps (`ka10080`) are start- or end-stamped — unknown | only our own WS bars use the proven `i(t)` formula | G4 |
| `290` boundary behaviour at 15:30 is undocumented | conflicts are counted, not resolved | G4 |
| SIGKILL drills do not prove power-loss durability | page cache survives process death | VS-2 recorder drill |
| fsync batching (128 records / 1 s) is not implemented in VS-1 | VS-1 has no live recorder | VS-2 |
| no WebSocket client exists in VS-1 | handshake, framing, masking, close codes are VS-2 work | VS-2 |
| strategy validity is not established | the fixture is tuned to exercise both directions, not to be profitable | PH-2 |
| thresholds come from a synthetic fixture | PH-1 calibrates them on a real capture; that same session cannot also prove detection | PH-1/PH-2 |
| signals == 0 on a real day is not a bug | `NO_TRIGGER_OBSERVED` is a valid outcome | PH-2 |
| one market (KRX) only | the global goal needs a second adapter and the same acceptance evidence | V2 |
| `rest_resp` is consumed but ignored in VS-1 | REST failure cannot influence a verdict until VS-2 consumes it | VS-2 |
| `run.json` is excluded from checksums | determinism covers the three data artifacts only | inherent |
| the 0.5% conflict threshold is a policy choice | small samples can trip it; it is fail-closed by design | plan §3.2 |
| manager can still edit branch protection | GitHub cannot prevent a repo admin from changing the rules | P6 audit |
| Northflank fixed egress IP is unverified | no account in scope; U5 stays open | deployment |

## Explicit non-goals

- No order execution, no shorting, no position sizing.
- No data in the repository: `calendars/*.json`, `runs/`, vendor extracts are
  gitignored; only `calendars/CALENDAR_INDEX.sha256` is committed.
- No claim that "22 selected RFC 6455 requirements" equals the whole RFC.
- No claim that a passing timer means the next KRX trading day; systemd only
  knows weekdays. The program decides trading days and SKIPs holidays.