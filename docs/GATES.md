# Hong Scanner — Gates

## Ultimate Purpose

매 영업일, KRX에서 상승·하락 양방향으로 매매 후보가 될 사건을 결정론적으로
탐지하고, 기록된 입력만으로 그 판정을 바이트 단위로 재현한다.

## Terminal Outcome

canonical `main`에서 빌드한 바이너리로 실제 실행한 런이
`VERDICT MATCH provenance=OK`를 내고, 그 런의 `input.hcj.jsonl`만으로
제3자가 동일한 `bars.hcj.jsonl`·`signals.hcj.jsonl`을 재생성할 수 있다.

## In Scope

- VS-1: HCJ, seq gauge, `session_date`, `gap`, 290 4분류, 3분봉 경계,
  경계 차분, `bar_position`, 리플레이(`bars`+`signals`), 반증 4분류,
  provenance 5종 대조, CI(합성 전용), GitHub merge gate, canonical main 빌드.

## Explicitly Out of Scope

- Northflank(계정 준비 전), 고정 egress IP, 실주문/공매도.
- 실시장 데이터의 저장소 반입.
- REST 봉 타임스탬프 규약 확정(ka10080) — G4.
- 전략 타당성 평가 — PH-2.
- 다중 시장(미국) 어댑터 — V1 통과 후.

## Gates

| # | gate | command | expected | status |
|---|---|---|---|---|
| P0 | 계획 동결(v6.1) | — | 4건 반영 | DONE |
| P1 | public repo, 합성 전용 CI | `gh repo view` | public, workflow `ci` | PARTIAL |
| P2 | 툴체인 핀 | `nim --version` | 2.2.10 | DONE |
| P3 | VS-1 계약 | `nimble test` | `55 passed, 0 failed`, exit 0 | DONE |
| P4 | 브랜치/PR | `gh pr view` | PR open, head `feat/vs1` | PENDING |
| P5 | CI green | `gh pr checks` | `ci` pass | PENDING |
| P6 | merge gate | classic protection + ruleset + CI-green direct-push probe | direct push rejected, reason recorded | PENDING |
| P7 | canonical main | `tools/build.sh` → `./hongscanner doctor` | `BUILD OK`, `DOCTOR RESULT=OK` | PENDING |
| P8 | acceptance replay | `./hongscanner replay` + `verify` | `VERDICT MATCH provenance=OK` | PENDING |
| P9 | 실측 데이터 경로 | real session | `VERDICT MATCH provenance=OK` | BLOCKED(G2) |
| P10 | systemd 타이머 | `systemd-analyze calendar ...` | exit 0, next weekday 08:50 | PENDING |
| P11 | PH-1/PH-2 | frozen config, separate session | signals observed / no-trigger recorded | BLOCKED(G2) |

## Completion Evidence

```bash
# P3 — synthetic contract
nimble test
#   55 passed, 0 failed   (exit 0)

# P3 — end-to-end on the committed fixture (dev binary: bytes only)
./hongscanner selftest
#   SELFTEST bytes=OK bars=22 signals=8
#   SELFTEST provenance=NOT_CANONICAL

# P7 — canonical build (refuses on dirty tree / non-main / stale HEAD)
tools/build.sh
#   BUILD OK commit=<sha> source_ref=main origin_main=<sha> nim=...
./hongscanner doctor
#   BUILD commit=<sha> source_ref=main origin_main=<sha> dirty=false nim=2.2.10
#   GIT head=<sha> origin_main=<sha> clean=true
#   CALENDAR_INDEX=OK files=2
#   DOCTOR RESULT=OK

# P8 — acceptance replay from the canonical binary
rm -rf runs/accept-2026-10-29
./hongscanner replay --in fixtures/smoke/input.hcj.jsonl --out runs/accept-2026-10-29
./hongscanner verify --run runs/accept-2026-10-29
#   REPLAY OK bars=22 signals=8
#   VERDICT MATCH provenance=OK        (exit 0)

# P6 — the probe must carry a green CI status, so a rejection cannot be
# caused by the required-check rule. Any non-zero exit is a pass; the server
# message is recorded verbatim.
git push origin <ci-green-sha>:main
#   ! [remote rejected] ... (protected branch hook declined)      exit != 0
```

`declare` is not evidence: P5 needs the run's conclusion, P6 needs the server
error text, P7/P8 need the printed lines above.