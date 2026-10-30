# Hong Scanner — Gates

## Ultimate Purpose

매 영업일, KRX에서 상승·하락 양방향으로 매매 후보가 될 사건을 결정론적으로
탐지하고, 기록된 입력만으로 그 판정을 바이트 단위로 재현한다.

## Terminal Outcome

canonical `main`에서 빌드한 바이너리로 실제 시장 런이 매 거래일 실행되고,
보존된 입력·설정·캘린더·빌드로 제3자가 동일한 봉과 신호를 재생성할 수 있다.
`provenance=OK`는 자체 보고한 메타데이터의 일치만 뜻하며 빌드 출처를
독립적으로 증명하지 않는다. 합성 VS-1 통과는 실측 운영의 완료가 아니다.

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
| P1 | public repo, 합성 전용 CI | `gh repo view` | public, workflow `ci` | DONE |
| P2 | 툴체인 핀 | `nim --version` | 2.2.10 | DONE |
| P3 | VS-1 계약 | `bash tools/run_tests.sh` | 모든 합성 테스트 통과, exit 0 | 2026-10-30 로컬·CI 실측 13 스위트 통과(증거 로그; PR #6 push·pull_request 양 실행 로그에서 `ALL CONTRACT SUITES PASSED` 확인) |
| P4 | 브랜치/PR | `gh pr view` | PR #1 merged (`cf5a5f6`) | DONE |
| P5 | CI green | `gh pr checks` | `ci` pass on PR #1 and on main push | DONE |
| P6 | merge gate | classic protection + ruleset + CI-green direct-push probe | `GH013`, exit 1, main unchanged | DONE |
| P7 | canonical main | `tools/build.sh` → 출력 경로의 `hongscanner doctor` | build commit equals current main, `DOCTOR RESULT=OK` | 역사적 증거만 있음; 현재 변경분 미검증 |
| P8 | 합성 replay | 빌드 출력의 `hongscanner replay` + `verify` | `VERDICT MATCH provenance=OK`, exit 0 | 역사적 합성 증거만 있음; 현재 변경분 미검증 |
| P9 | 실측 데이터 경로 | real session | `VERDICT MATCH provenance=OK` | BLOCKED(G2) |
| P10 | systemd 타이머 | `systemd-analyze calendar ...` | exit 0, next weekday 08:50 | BLOCKED(VS-2 live recorder) |
| P11 | PH-1/PH-2 | frozen config, separate session | signals observed / `NO_TRIGGER_OBSERVED` | BLOCKED(G2) |
| P12 | 승인(approval) | 별도 조건 6건(하단 'Approval' 절) | 모든 조건 충족이 문서화됨 | 미구현(목표 계약, BLOCKED(G2)) |
| P13 | attestation·설치 digest | main 정확 sha + 설치 파일 sha256 대조 | main sha·digest 모두 일치 | 2회 실측 완료(2026-10-30, main `1908427`·`edc1b4a`; 배포 동작을 바꾸는 main 변경마다 재실시) |

### Evidence log (2026-10-29)

| gate | observed |
|---|---|
| P5 | `ci pass` on PR #1 (push + pull_request), `ci pass` on main pushes `cf5a5f6`, `0e8fa88` |
| P6 | 6a: `enforce_admins=true`, `strict=true`, `checks=[ci]`, `approvals=0`, `force_push=false`, `deletions=false`; ruleset `26109780` `enforcement=active`, `bypass_actors=[]`. 6b: probe `eb7ac5b` (tree `e404ea3` == `origin/main`) with `ci success` → `git push origin HEAD:main` exit 1, `remote: error: GH013 ... Changes must be made through a pull request`, `refs/heads/main` unchanged at `cf5a5f6` |
| P7 | `BUILD OK commit=0e8fa88f12e3f2efc250fee043c69dc4867f171c source_ref=main origin_main=0e8fa88... nim=2.2.10`; `GIT clean=true`; `CALENDAR_INDEX=OK files=2`; `DOCTOR RESULT=OK` exit 0 |
| P8 | `REPLAY OK bars=22 signals=8 frames=24`; `VERDICT MATCH provenance=OK` exit 0; `run.json` `code_commit=0e8fa88`, `source_ref=main`, `dirty=false`, `nim=2.2.10` |

### Evidence log (2026-10-30) — CI gate integrity fix + first attested install

| gate | observed |
|---|---|
| P3(정정) | 2026-10-29 main run `40883550758`: `nimble test`의 nimscript exec 실패가 exit 0으로 보고되어 빌드 계약 3건 실패에도 `ci` green — 거짓 green. 수정: `tools/run_tests.sh`(PR #5, merge `1908427`). PR #5 `ci` 로그에 `ALL CONTRACT SUITES PASSED` 실측 확인(12 스위트: 55/23/82/107/57/23/130/72/46/18/161/45) |
| P13 | main `1908427` push에서 `attest` 워크플로 16단계 전부 성공(run `40976811441`); 아티팩트 sha256 `59b7c18f85acd1a64d7a03a0eff3afa99a84f3218a3187221f2884f561870874` == build-report == `hongscanner.sha256`; `gh attestation verify ... --signer-workflow wintrover/hong-scanner/.github/workflows/attest.yml --source-ref refs/heads/main --source-digest 1908427... --deny-self-hosted-runners` exit 0; `tools/install-attested.sh` → `~/.local/share/hongscanner/versions/0.1.0-main-1908427`(current symlink 원자 전환, `sha256sum -c` OK); 설치 바이너리로 `replay`/`verify` → `REPLAY OK bars=22 signals=8` / `VERDICT MATCH provenance=OK` exit 0. 증명의 신뢰 경계는 LIMITS.md "bounded trust" 그대로 |
| P3(rest_resp) | 2026-10-30 rest_resp 수용 경로(§12.1 스키마·페이지 체인 검증) 반영 후 로컬 실측: `bash tools/run_tests.sh` exit 0, `ALL CONTRACT SUITES PASSED` — 13 스위트, 897 단언(55/23/82/107/57/23/**78**/130/72/46/18/161/45, 신규 `test_rest_resp_contract` 굵게). 기존 거부 스위트(`test_rest_failure_contract` 23)는 무수정 통과 — 레거시 페이로드는 여전히 REJECT |
| P13(edc1b4a) | main `edc1b4a`(PR #6 merge) push: ci `40979766637` 성공(로그 `ALL CONTRACT SUITES PASSED` 실측), attest `40979766630` 성공(1m57s). 아티팩트 sha256 `a31559ec3aae21c2a5bf27c0764b3d393c66cdf8e53205d8bf9e16bddd97df1a` == `hongscanner.sha256`; `gh attestation verify ... --source-digest edc1b4a...` exit 0, 반증: `--source-digest 1908427...` → exit 1 `expected ... got edc1b4a`(판별력 확인); `tools/install-attested.sh` → `versions/0.1.0-main-edc1b4a`, current 원자 전환(이전 `1908427` 버전 보존), `sha256sum -c` OK; 설치 바이너리로 smoke `replay`/`verify` → `VERDICT MATCH provenance=OK` exit 0, 그리고 **유효 rest_resp 포함 스트림**도 `REPLAY OK bars=4 signals=2` / `VERDICT MATCH provenance=OK` exit 0 — 신규 수용 경로의 배포 바이너리 종단 확인 |

한계: P13의 이 증거는 "이 바이너리가 그 main 빌드에서 나왔다"는 독립 근거일 뿐, 전원 차단 내구성이나 실거래 운영 승인(P12)이 아니다. 설치 후 `versions` 비쓰기는 운영 요건이다.

## Completion Evidence

```bash
# P3 — synthetic contract
# `nimble test` alone is NOT the gate: a failed exec in its nimscript task
# can still exit 0 (this let a red suite pass as a green `ci` check on
# 2026-10-29, main run 40883550758). The gate is the fail-fast script.
bash tools/run_tests.sh
#   all contract suites pass (exit 0)

# P3 — synthetic fixture with a development binary; this is not acceptance
nimble build
build/hongscanner selftest
#   SELFTEST bytes=OK ...
#   SELFTEST provenance=NOT_CANONICAL

# P7 — local canonical build (not an independent attestation)
tools/build.sh
#   BUILD OK ... local_build=<path>
#   Use the exact emitted path; a build failure may leave an incomplete directory.
<local-build>/hongscanner doctor
#   BUILD commit=<sha> source_ref=main origin_main=<sha> dirty=false nim=2.2.10
#   GIT head=<sha> origin_main=<sha> clean=true
#   CALENDAR_INDEX=OK files=2; DOCTOR RESULT=OK

# P8 — synthetic replay from that binary; never overwrite an old run
out="$(mktemp -d "${TMPDIR:-/tmp}/hongscanner-accept.XXXXXX")"
<local-build>/hongscanner replay --in fixtures/smoke/input.hcj.jsonl --out "$out"
<local-build>/hongscanner verify --run "$out"
#   VERDICT MATCH provenance=OK        (exit 0; not production approval)

# P6 — the probe must carry a green CI status, so a rejection cannot be
# caused by the required-check rule. Any non-zero exit is a pass; the server
# message is recorded verbatim.
git push origin <ci-green-sha>:main
#   ! [remote rejected] ... (protected branch hook declined)      exit != 0
```

`declare` is not evidence: P5 needs the run's conclusion, P6 needs the server
error text, P7/P8 need the printed lines above.

## Candidate scope (VS-2 목표 계약 — 미구현)

"후보"의 정의를 이 계약이 선언한다. 지금은 선언일 뿐, 이를 조회하는 코드는
없다. VS-1 Core는 검증되지 않은 `rest_resp`를 거부한다.

- 조회: 키움 REST `ka10027` 전일대비등락률상위요청 — `POST /api/dostk/rkinfo`.
- 거래소: `stex_tp="1"`(KRX). `2`(NXT)와 `3`(통합)은 이 계약의 후보
  유니버스가 아니다.
- 방향: 방향별로 각각 조회한다 — `sort_tp="1"`(상승률), `sort_tp="3"`
  (하락률). 방향은 부호 규칙이 아니라 쿼리가 결정한다.
- 나머지 조회 조건(`mrkt_tp`, `trde_qty_cnd`, `stk_cnd`, `crd_cnd`,
  `updown_incls`, `pric_cnd`, `trde_prica_cnd`)의 값은 승인 시점에 확정되고
  확정값이 config 레코드에 그대로 기록된다. 승인 전에는 어떤 값도
  기정사실이 아니다.
- 재조회 주기와 각 후보의 유효기간은 승인된 설정에 명시하고 기록한다.
  값이 미확정이면 실운영 후보 판정은 보류한다.
- 페이지 상한: 응답 Header `cont-yn`/`next-key` 연속조회를 따르되 조회
  페이지 수는 선언된 상한 이내로 제한한다. 상한에 도달했을 때 추가
  페이지가 남아 있으면 `truncated`로 기록하고, 초과분은 "후보 없음"이
  아니라 "미조회"다. 상한은 스캐너 측 선언이며, 그 값도 승인 항목이다.

## PH-1 / PH-2

- **PH-1(교정)**: 실측 캡처 한 세션으로 전략 의존 구간(`warmup`,
  `lookback`)과 임계값(`pullback_min_bp`, `recovery_bp`, `rebound_min_bp`,
  `breakdown_bp`의 적용 규칙 포함)을 동결한다. 동결 전 값은 합성 픽스처
  유래이며, 교정에 쓴 세션의 신호는 검출 증거로 함께 쓸 수 없다.
- **PH-2(평가)**: 동결된 config로 PH-1과 별개 세션을 실행한다. 결과는
  `signals observed` 또는 `NO_TRIGGER_OBSERVED` 둘 중 하나다.
- 둘 다 BLOCKED(G2) — 실측 경로가 없다.

## Approval — `session_end`와 별개 조건 (목표 계약)

`session_end`는 수집기의 정상 종료만 나타낸다. `VERDICT MATCH
provenance=OK`도 운영 승인이 아니다. 각 런의 승인에는 아래 조건이 모두
필요하다:

1. 승인된 달력 스냅샷과 세션 범위가 유효하다.
2. 양방향 후보 조회가 선언된 범위와 페이지 정책에 따라 완료됐으며,
   벤더 오류나 미완료 조회가 성공으로 오인되지 않았다.
3. 미해결 gap, 닫힌 봉에 늦게 도착한 틱, 필수 구독의 미확인 상태가 없다.
4. `session_end`가 기록되고 내구성 있게 저장됐다.
5. 비밀을 제외한 원본과 정규화 결과가 일치하며, 보존된 입력의 재생 결과가
   저장된 봉과 신호에 바이트 단위로 일치한다.
6. 실제 배포·실행 바이너리의 digest와 해당 main 빌드의 출처 증명을
   독립적으로 검증했다.

`NO_TRIGGER_OBSERVED`는 위 조건을 모두 통과하고 트리거가 없는 런에만
적용되며 "관측된 스트림에서 트리거 없음"을 뜻한다. 모든 공급자 틱을
빠짐없이 수신했다는 증거는 아니다. 전체 운영 목표의 완료에는 별도로 PH-1
보정과 동결된 설정을 쓰는 별도 거래일의 PH-2가 필요하다.

## Attestation과 workflow trust 한계 (목표 계약 — 미구현)

현재 `provenance=OK`는 자체 보고 메타데이터의 일치다. 강화의 목표 계약:

- attestation은 canonical `main`의 **정확한 sha**(HEAD == origin/main)를
  대상으로 한다.
- **설치 파일 digest**: 배포·설치된 실행 파일의 sha256을 런에 남겨 제3자가
  설치 파일과 canonical 빌드를 대조할 수 있게 한다.
- GitHub Actions CI green(P5)의 신뢰는 GitHub 인프라와 해당 sha의
  workflow 파일로 한정된다. workflow는 repo 관리자가 편집할 수 있고, CI는
  호스트에 설치된 바이너리가 그 sha에서 왔다는 것을 증명하지 않는다. CI
  green은 attestation의 대체가 아니다.