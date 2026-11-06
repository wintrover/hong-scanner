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
- Phase-0 컨테이너 계약: 단일 컨테이너 이미지·cloud supervisor·attest
  공급망(2바이너리·이미지 digest 증명) — tools/container/README.md.

## Explicitly Out of Scope

- Northflank 배포·운영(계정 준비 전 — NF-0 미통과; Phase-0 코드·계약·
  공급망은 병합돼 아래 증거 로그에 기록), 고정 egress IP, 실주문/공매도.
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
| P3 | VS-1 계약 | `bash tools/run_tests.sh` | 모든 합성 테스트 통과, exit 0 | 2026-10-30 로컬·CI 실측 19 스위트 통과(증거 로그; PR #6·#9·#11 push·pull_request 실행 로그에서 `ALL CONTRACT SUITES PASSED` 확인) |
| P4 | 브랜치/PR | `gh pr view` | PR #1 merged (`cf5a5f6`) | DONE |
| P5 | CI green | `gh pr checks` | `ci` pass on PR #1 and on main push | DONE |
| P6 | merge gate | classic protection + ruleset + CI-green direct-push probe | `GH013`, exit 1, main unchanged | DONE |
| P7 | canonical main | `tools/build.sh` → 출력 경로의 `hongscanner doctor` | build commit equals current main, `DOCTOR RESULT=OK` | 역사적 증거만 있음; 현재 변경분 미검증 |
| P8 | 합성 replay | 빌드 출력의 `hongscanner replay` + `verify` | `VERDICT MATCH provenance=OK`, exit 0 | 역사적 합성 증거만 있음; 현재 변경분 미검증 |
| P9 | 실측 데이터 경로 | real session | `VERDICT MATCH provenance=OK` | BLOCKED(G2) — 2026-11-02 라이브 관측 시작(라이브 WS 경로 확정·실데이터·FCM 실전송, 증거 로그); 아직 봉인(`session_end`+MATCH) 세션 없음 |
| P10 | systemd 타이머 | `systemd-analyze calendar ...` | exit 0, next weekday 08:50 | BLOCKED — 상주 알림 워커·세션 런처는 PR #29(`d787b37`) 구현; systemd 서비스·운영 전환만 미구축 |
| P11 | PH-1/PH-2 | frozen config, separate session | signals observed / `NO_TRIGGER_OBSERVED` | BLOCKED(G2) — PH-1 (2) 관측 시도는 2026-11-02 INCOMPLETE로 종료(증거 로그) |
| P12 | 승인(approval) | 별도 조건 6건(하단 'Approval' 절) | 모든 조건 충족이 문서화됨 | 미구현(목표 계약, BLOCKED(G2)) |
| P13 | attestation·설치 digest | main 정확 sha + 설치 파일 sha256 대조 | main sha·digest 모두 일치 | 누적 19회 설치 성공(`~/.local/share/hongscanner/versions/` 19디렉터리 실측)·4회 attest 게이트 실패(`f4ad05c` 10-30·`97043fd` 11-02·`7eefd0d` 11-02·`06f4208` 11-03 이미지 페이즈 — 인과는 증거 로그; 배포 동작을 바꾸는 main 변경마다 재실시) |

### Northflank gates (NF)

Phase-0(코드·계약·공급망)은 병합됐지만 **Northflank 계정·배포·Kiwoom 클라우드
접속은 아직 없다**. NF 사다리는 그 경계를 게이트로 고정한다: 각 단계는 통과
조건을 문언으로 가지며, 증거 없이 DONE이 되지 않는다(fail-closed).
P12(승인)의 조건은 이 사다리와 무관하게 그대로 유지된다.

| # | gate | 통과 조건 | status |
|---|---|---|---|
| NF-0 | 계정·비용·리전 | 사용자가 Northflank 계정·비용 상한·리전을 결정하고 기록한다(사용자 게이트 — 저장소가 대행하지 않는다) | PENDING(사용자 게이트) |
| NF-1 | 전용 egress + Kiwoom 허용 IP | 전용 egress IP가 발급되고 키움 측 수용이 실측된다(U5·U13) | PENDING |
| NF-2 | 클라우드 OAuth 발급·비누출 | 클라우드 런타임에서 토큰이 `token_source=env`로 발급되고 토큰 값이 이미지·HCJ·로그 어디에도 기록되지 않음이 검증된다(M13) | PENDING |
| NF-3 | Kiwoom REST·WS 실측 | 클라우드 egress에서 REST·WS 세션이 실측된다(로컬 관측과 동등한 계약 준수) | PENDING |
| NF-4 | 볼륨 영속성 | 컨테이너 재시작·재배치 후 `runs/`·`notify/`·`calendars/*.json`이 보존되고 INDEX 교차검증이 통과한다(REPLAY_CONTRACT §14.4) | PENDING |
| NF-5 | 단일 작성자·프로브 운영 | 프로브 3종이 플랫폼에 매핑돼(tools/container/README.md §7.2) 관측되고 run 디렉터리의 작성자가 recorder뿐임이 실측된다 | PENDING |
| NF-6 | API 보안 | HTTPS·Basic Auth 뒤에서만 접근 가능하고 GET-only 계약이 유지됨이 실측된다 | PENDING |
| NF-7 | supervisor 런타임 운영 | 실세션(시도·COMMITTED·INCOMPLETE·보존)이 REPLAY_CONTRACT §14.3대로 관측된다 — SIGKILL escalation·시도 상한 소진 포함 | PENDING |
| NF-8 | FCM 실기기 | 클라우드 배포에서 실기기까지 FCM 종단이 실측된다(U17) | PENDING |
| NF-9 | 이미지 공급망 | `main-<sha7>` 이미지가 push·digest 증명되고 운영자 PAT 경로 검증(tools/container/README.md §8.3)까지 통과한다 | **부분 증거** — `782f5da` 이미지 공급망 end-to-end 성공(증거 로그); `7eefd0d`는 이미지 페이즈 실패, PAT 경로 미실측 |
| NF-10 | Replay 동등성 | 클라우드에서 생산된 런 디렉터리가 canonical 바이너리 replay·verify와 바이트 동등함이 실측된다 | PENDING |
| NF-11 | 복구·백업 | 볼륨 백업·복원 절차가 드릴되고 복원 후 검증이 통과한다 | PENDING |
| NF-12 | 실운영 승인 | NF-0~NF-11 위에서 P12의 6조건이 클라우드 운영에 대해 충족·문서화된다 | PENDING(NF 사다리 완료 전 성립 없음) |

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

### Evidence log (2026-10-30) — VS-2 PR-1 계약 기반 merge (main `342557d`)

| gate | observed |
|---|---|
| P3(sub,ws_raw) | PR #9(vs2-contracts, merge `342557d`) 반영 후 main push `ci` 런 `41047341624` 로그에서 `ALL CONTRACT SUITES PASSED` 실측 — 14 스위트 1127 단언(55/23/82/107/57/23/78/**175**/130/109/64/18/161/45, 신규 `test_sub_input_contract` 굵게; 마지막 45는 calendar 파이썬 스위트 `Ran 45 tests ... OK`). `test_recorder_contract` 72→109(8단계 finish·COMMITTED 마커), `test_cli_contract` 46→64(verify `COMMIT=` 출력·environment 게이트). merge 전 동일 트리 로컬 게이트도 exit 0·마커 실측 |
| P13(342557d) | main `342557d`(PR #9 merge) push: ci `41047341624` 성공(로그 마커 실측), attest `41047341861` 성공. `tools/install-attested.sh` → `INSTALL VERIFY OK`(source_digest `342557d…`, github-hosted-only) → `versions/0.1.0-main-342557d`, sha256 `30201116b59be24a054543c3776ea77b57a314a503882326c03b2e177254881f`, current 원자 전환(이전 버전들 보존); 설치 바이너리로 신규 디렉터리 `runs/smoke-2026-10-30-342557d` smoke: `replay` → `REPLAY OK bars=22 signals=8 frames=24` exit 0, `verify` → `VERDICT MATCH provenance=OK` + `COMMIT=ABSENT` exit 0 — 신규 COMMIT 라인이 environment 없는 VS-1 스트림에서 ABSENT로 정상 출력. `run.json` `code_commit=342557d…` == `build.origin_main_sha=342557d…`, `source_ref=main`, `nim=2.2.10`, `dirty=false` |

### Evidence log (2026-10-30) — VS-2 PR-2 라이브 수집기 merge + attest 게이트 Python 수정

| gate | observed |
|---|---|
| P3(collector) | PR #11(vs2-collector, 4커밋 `87ec1a9` 계약 → `24e5fb7` 구현 → `6359dfc` 테스트 → `fd9ea2c` 검토 수정: `recv(decode=False)` 계약 교정) merge. CI 3런: pull_request `41066643516`·push `41066634583`·synchronize `41067531981` — 첫 merge 시도는 ruleset strict(up-to-date) 요건으로 정당 차단, merge 커밋 `2cb9cd0`로 main 반영 후 재측정. 전 런 로그에서 `ALL CONTRACT SUITES PASSED` 실측. main `4f732da` push ci 런 `41069541804` 로그: **19 스위트 1337 단언**(55/23/82/107/57/23/78/**178**/130/109/**65**/**27**/**68**/**23**/**24**/64/18/161/45 — sub_input 175→178, 신규 `tickwire`·`subcheck`·`collector`·`collector_stream`·`sidecar`(python) 굵게; 마지막 45는 calendar 스위트). 로컬 게이트도 3회(구현 후·decode=False 수정 후·merge 커밋 후) exit 0·마커 실측 |
| P13(f4ad05c→4f732da) | main `f4ad05c`(PR #11 merge) push: ci `41067888845` 성공(마커 실측), attest `41067888986` **실패** — attest 워크플로 게이트에 Python 3.13 설치가 누락돼 sidecar 스위트가 fail-closed 탈락(`no Python 3.13 interpreter found`); `f4ad05c`는 설치하지 않음(실패 런 증거 보존). 수정 PR #12(`ae2ca94`: attest.yml에 SHA 고정 setup-python v5 + `HSCOLLECTOR_PYTHON=python3`) merge → main `4f732da` push: ci `41069541804`·attest `41069541491` 성공(각각 게이트 로그 마커 실측). `tools/install-attested.sh` → `INSTALL VERIFY OK`(source_digest `4f732da…`, github-hosted-only) → `versions/0.1.0-main-4f732da`, sha256 `ca72dd94a8e3b9376e918ea1ef350784a9a35c2d627d8201f7df9ed875043b32`, current 원자 전환(이전 버전 보존); 설치 바이너리로 신규 디렉터리 `runs/smoke-2026-10-30-4f732da` smoke: `replay` → `REPLAY OK bars=22 signals=8 frames=24` exit 0, `verify` → `VERDICT MATCH provenance=OK` + `COMMIT=ABSENT` exit 0. `run.json` `code_commit` == `build.origin_main_sha` == `4f732da…`, `source_ref=main`, `nim=2.2.10`, `dirty=false`. 라이브 관측(REST·WS 실측)은 포함되지 않음 — P9·P11·P12는 여전히 BLOCKED(G2) |

한계: P13의 이 증거는 "이 바이너리가 그 main 빌드에서 나왔다"는 독립 근거일 뿐, 전원 차단 내구성이나 실거래 운영 승인(P12)이 아니다. 설치 후 `versions` 비쓰기는 운영 요건이다.

### Evidence log (2026-10-31) — 토요일 사전검증·return_code 경화(PR #14)·프로세스쌍 드릴(PR #15)

| gate | observed |
|---|---|
| P9(사전) | **WS 프로브**: 금 23:44·토 09:34 KST 두 차례 `wss://mockapi.kiwoom.com:10000` opening handshake timeout(TCP+TLS는 금요일 프로브로 확인됨). **해소(11-02)**: 무응답의 근본 원인은 프로브 URL에 경로가 없었다는 것 — 서버는 루트 업그레이드에 응답하지 않고, 공식 경로는 `/api/dostk/websocket`이다(PR #30 `a660689`, kwcli SDK의 base+api_url 합성·ka10171~73 근거). 즉 10-31 무응답은 가용성 게이트가 아니라 프로브 결함이었다. **해외장 교차검증**: 금 23:44 KST 시점은 NYSE/Nasdaq(10:44 EDT 정규장)·LSE(14:44 GMT)·Xetra(15:44 CET) 전부 정규장 진행 중이었는데도 handshake 무응답 — "any-market-open 게이트" 가설 기각. 잔여 가설: KRX 거래시간 게이트(우세)·서버 결함. 판정은 월 08:30/09:0x 프로브 대비뿐. 증거: `runs/precheck-2026-10-31/{probe,overseas-crosscheck}.json`. **서브에이전트 문서조사(병렬)**: WS·REST 운영시간·주말·점검 창은 공식 문서 전무(NOT DOCUMENTED — 스펙 JSON 337 API·공식 GitHub·포털 3페이지·공지 SPA 0건). 키움 모의 시세 범위(NXT·미국 무료 실시간)는 DOCUMENTED, 모의↔실전 틱 충실도 동일성은 무문서 |
| P9(token) | sidecar refresh_token 실경로: init→ready, 강제 회전→`{"ev":"token"}`, stop→exit 0. 실 `kiwoomcli auth refresh --profile wuyoni`(토큰 값은 어디에도 기록 안 함). 24h grant 확인 — 새 만료 일 09:44 KST, 월 08:30 init 자동재발급이 같은 검증된 subprocess 경로(600s buffer, fail-closed)를 통과. 증거: `runs/precheck-2026-10-31/refresh-token.json` |
| P9(rest) | 실측 ka10027(모의 REST, page 1, 상승 방향, 토요일 장외): HTTP 200, `cont_yn="Y"`, next_key 존재, body 46,285 bytes, top-level `[pred_pre_flu_rt_upper, return_code, return_msg]`, **`return_code` 정수 0**(JSON integer), `return_msg` 문자열, 목록 200건. 원문 bytes는 /tmp에만 보존(저장소 반입 안 함). 공식 자료 내부 불일치(스키마 String vs 예제 정수 0)를 실측으로 해소 — vendor_input.nim 정수 파싱과 정합. 증거: `runs/precheck-2026-10-31/rest-body-shape.json` |
| P3(ack) | PR #14(fix-ws-ack-return-code, merge `e88f6ea`): WS ack `return_code` 경화 — `tickwire.nim` `canonicalAckCode`(정수 또는 정규 숫자 문자열 "0"/"0001" 수용, 그 외 fail-closed) + `sidecar.py`에 SDK 규칙 이식(normalize_return_code, LOGIN ack `return_msg` 임베드 `CODE=NNNN`/`[NNNN:` auth 재시도). CI 2런(pull_request `41154138884`·push `41154134165`) 성공 + 각 로그에서 `ALL CONTRACT SUITES PASSED` 1회 실측. tickwire 69 checks·sidecar 27 tests |
| P13(e88f6ea) | main `e88f6ea`(PR #14 merge) push: attest `41154388415` 성공(게이트 로그 마커 실측). `tools/install-attested.sh` → `INSTALL VERIFY OK` → `versions/0.1.0-main-e88f6ea`, sha256 `0d2f5c03b4b41cba2c0b9ec3e04c61598cb2488cd3aa07d308fb1f02a6324509`, current 원자 전환(이전 5버전 보존). smoke `runs/smoke-2026-10-31-e88f6ea`: `replay` → `REPLAY OK bars=22 signals=8 frames=24` exit 0, `verify` → `VERDICT MATCH provenance=OK` + `COMMIT=ABSENT` exit 0, `run.json` `code_commit` == `origin_main_sha` == `e88f6ea…` |
| P3(drill) | **프로세스쌍 드릴(서브에이전트, 백그라운드 병렬)**: 진짜 collector 바이너리 × 진짜 sidecar.py × 진짜 OS 파이프, 가짜 키움 와이어(fake websockets·sitecustomize urllib 패치·시드 토큰 캐시·fake kiwoomcli), 네트워크 0. 시나리오 A 정상 풀세션(records=22, session_end+COMMITED, exit 0)·B SIGKILL(exit 137, verify INCOMPLETE, COMMITTED 없음)·C replay+verify(REPLAY OK bars=4 signals=2, `VERDICT MISMATCH` provenance=INVALID + `COMMIT=VALID` — dev 빌드 계약상 최대치·REPLAY_CONTRACT §8) 전부 통과, 드릴 38/38. **운영 결함 2건 발견**(수정 전 바이너리에서 음성 재현 검증): ①`collector.nim` readLine이 소비한 줄을 accumulator에서 제거하지 않아 첫 줄 무한 재전달 → 첫 ready에서 exit 2(월요일 세션 개시 직전 치명) ②pollFd가 POLLHUP(커널 6.17, writer 종료 시 POLLIN 없음)을 timeout으로 취급 → sidecar 사망 시 무한 스핀(계약상 exit 4 INCOMPLETE여야). 수정 PR #15(drill-pair, `98f9b62`+main merge `117feec`): 병합본 로컬 게이트 exit 0·마커, 병합본에서 드릴 재실행 38/38(증거 `runs/drill-pair-20261031-104143`, 서브에이전트 원본 7디렉터리 포함 총 8디렉터리 runs/에 보존). CI 2런(pull_request `41156625073`·push `41156604464`) 성공 + 각 로그 마커 1회 실측. 신규 합성 스위트 `tests/test_collector_pipe_contract.sh`(10 checks) 게이트 등록 — **20 스위트**. 드릴 자체는 KST 15:40 기동 거부 때문에 CI 비포함 |
| P13(fa6f9fe) | main `fa6f9fe`(PR #15 merge) push: ci `41156793710`·attest `41156793827` 성공(각 게이트 로그 마커 1회 실측). 아티팩트 sha256 `7ac62fd4e7b1b4e013e6db179556521f02613cdbde1178491af89e82ad9ba28b` == `hongscanner.sha256`; `gh attestation verify … --source-digest fa6f9fe… --deny-self-hosted-runners` exit 0. `tools/install-attested.sh` → `INSTALL VERIFY OK` → `versions/0.1.0-main-fa6f9fe`, current 원자 전환(이전 버전들 보존). smoke `runs/smoke-2026-10-31-fa6f9fe`: `replay` → `REPLAY OK bars=22 signals=8 frames=24` exit 0, `verify` → `VERDICT MATCH provenance=OK` + `COMMIT=ABSENT` exit 0, `run.json` `code_commit` == `origin_main_sha` == `fa6f9fe…`. **이 바이너리가 월요일(11-02) PH-1 replay/verify 확정본** |

한계(2026-10-31): 위 증거는 모두 모의(=mock) 환경·합성 드릴·배포 절차에 대한 것이다. 라이브 WS 가용성·실장 관측(P9), 실거래일 PH-1(P11)·운영 승인(P12)은 여전히 미실시. 드릴의 가짜 와이어는 프로토콜 계약을 검증하며 실 키움 서버의 우발 동작(운영시간 게이트·PING 주기·ack 집합)을 대체하지 않는다.

### Evidence log (2026-11-01) — VS-3 기준안 공식문서 검증 4기·이벤트 계약(PR #17)·mobile 스캐폴드(PR #18)

| gate | observed |
|---|---|
| VS-3(검증) | **기준안 검증 4기(백그라운드 병렬 서브에이전트, Context7 공식 외부 문서 대조)** — ①FCM: Cloud Messaging은 Spark 무료 요금제 포함 무료 제품·HTTP v1·메시지 4KB(토픽 2048B)·provider accepted≠기기 실표시·서비스 계정 OAuth2·UNREGISTERED=404·SENDER_ID_MISMATCH=403·메시지 TTL 최대 4주·Android 13+ POST_NOTIFICATIONS·Android 7.0+/Play 서비스 기기 요건·전송률(RPM)은 미문서화·수신 포트 5228-5230. ②Flutter: firebase_messaging 17.0.1·minSdk 24·권한은 `requestPermission()` 공식 경로·**종료 상태에서의 알림 표시는 notification 메시지가 공식 경로(데이터 전용+로컬 알림 표시는 비공식 패턴) → dispatcher는 notification+data 메시지로 계획 교정**·탭 라우팅 `getInitialMessage`/`onMessageOpenedApp`+data 페이로드·강제종료 시 미수신·APK 직접 배포 무료·자체 keystore. ③오프라인: FCM 전달 순서 무보장·중복 가능·대기 큐 100개 초과 폐기+`onDeletedMessages`·1개월 미접속 기기 토큰 폐기·기기당 240/분·프로젝트 5000/시. ④이벤트 소싱 아키텍처: Axon "handlers also run during replay"·Kafka 로그 재소비 공식 유스케이스·PostgreSQL WAL "must be written only after those changes have been logged"·**실시간 판정과 replay 판정의 이원화 권고는 공식 문서에 없음(NOT DOCUMENTED) → 단일 판정 함수 `step(state, record)` 확정**. 반박 0건, 교정 5건을 기준안·계약·PR 분해에 반영 |
| VS-3(계약) | PR #17(vs3-event-contract, 커밋 `f8d51b6`, 백그라운드 서브에이전트 구현): `contracts/events/event.schema.json`(12 event_type 열거·불변 사실·additionalProperties:false·x-event-id-rule = HCJ canonical {entity,event_type,rule_id,session_id,transition_seq}의 sha256 — Q(입력 seq)는 다이제스트에만 들어가고 어떤 산출물에도 방출 안 함)·`contracts/events/delivery.schema.json`(PENDING/ACCEPTED/FAILED·device_id는 레지스트리 신원이며 FCM 토큰이 아님·error_code는 fail-closed)·`tests/test_event_contract.nim`(585행·수작성 105 checks)·`fixtures/events/valid_event.hcj.jsonl`·run_tests.sh 등록 → **21 스위트**·`docs/REPLAY_CONTRACT.md` §13(13.1 단일 판정 함수·13.2 기록 선행·13.3 단일 작성자 순서·13.4 byte 일치·13.5 결정론 경계·13.6 상태 3분리·13.7 원칙). 병합본 로컬 게이트 exit 0 + `EVENT CONTRACT PASSED (105 checks)` + `ALL CONTRACT SUITES PASSED`. CI 2런(push `41311544321`·pull_request `41311550413`) 성공 + 각 로그 마커 1회 실측 → merge main `4833a7c` |
| P13(4833a7c) | main `4833a7c`(PR #17 merge) push: ci `41312111855`·attest `41312111869` 성공(각 게이트 로그 마커 1회 실측). `gh attestation verify`(source-digest `4833a7c67b5e4bcd63683c236647ff57cfe990c1`) exit 0 → `tools/install-attested.sh` → `INSTALL VERIFY OK` → `versions/0.1.0-main-4833a7c`, sha256 `597ec418ab35bba2ebb122868e112268603a141e424914a125d8bdfe4107240e`, current 원자 전환(이전 버전들 보존). smoke `runs/smoke-2026-11-01-4833a7c`: `replay` → `REPLAY OK bars=22 signals=8 frames=24` exit 0, `verify` → `VERDICT MATCH provenance=OK` + `COMMIT=ABSENT` exit 0, `run.json` code_commit == origin_main_sha == `4833a7c…` |
| VS-3(mobile) | PR #18(vs3-mobile-scaffold, 커밋 `6d96500`, 백그라운드 서브에이전트 구현): 로컬 툴체인 Flutter 3.47.9 stable(Dart 3.13.7)·Android SDK(build-tools 34.0.0·platforms 34/35/36·platform-tools 37.0.1)·openjdk-21-jdk-headless(기존 java는 JRE 전용이라 javac 없음) 설치. `mobile/` 스캐폴드 74파일 +2353행: 화면 4종 스텁·PushService 추상화(Noop 기본·FcmPushService는 초기화 없이 인스턴스화 시 fail-closed)·firebase_core ^5.1.0·firebase_messaging ^17.0.1·minSdk 24·google-services 미적용(Firebase handoff 체크리스트 `mobile/README.md`). `flutter test` 5 green·`flutter build apk --debug` exit 0(146MB·119.2초). **`flutter analyze`는 이 저장소의 non-ASCII 경로(바탕화면)에서 LSP 도구 버그로 exit 255 — stock `flutter create` 프로브로도 동일 재현, ASCII 경로 사본에서는 `No issues found!` exit 0(우회 확보됨, CI에서는 아직 관측되지 않음)**. 병합본 mobile 게이트(Nim 계약 스위트) exit 0 + 마커 1회. main 병합 `be53612`(strict up-to-date 충족) 후 CI 2런(pull_request `41312443113`·push `41312438513`) 성공 + 각 로그 마커 1회 실측 → merge main `abd0c9a`. mobile은 아직 CI 워크플로 대상 아님(Nim 게이트만 실행) — 경로 필터 워크플로는 PR-7에서 설계 |
| P13(abd0c9a) | main `abd0c9a`(PR #18 merge) push: ci `41313177996`·attest `41313177940` 성공(각 게이트 로그 마커 1회 실측). 아티팩트 sha256 `5fa941a8ef6c4098555e614288dd33ac6ce093012a2c784579acfd488a361c08` == `hongscanner.sha256`(`sha256sum -c` 성공). `tools/install-attested.sh`(source_digest `abd0c9aaea510aa58eaf43841e5bd7c26ccb3278`) → `INSTALL VERIFY OK`(github-hosted-only) → `versions/0.1.0-main-abd0c9a`, current 원자 전환(이전 버전들 보존). smoke `runs/smoke-2026-11-01-abd0c9a`: `replay` → `REPLAY OK bars=22 signals=8 frames=24` exit 0, `verify` → `VERDICT MATCH provenance=OK` + `COMMIT=ABSENT` exit 0, `run.json` code_commit == build.origin_main_sha == `abd0c9a…`, `source_ref=main`, `nim=2.2.10`, `dirty=false`. mobile/은 Nim 빌드 입력이 아니므로 두 바이너리의 계약 게이트는 동일 — current를 최신 main에 정렬한 운영 정리 |
| 정리 | 병합 완료 워크트리 `HongScanner-events`·`HongScanner-mobile` 제거(미커밋 잔류 0 확인 후), 브랜치 vs3-event-contract·vs3-mobile-scaffold 로컬+원격 삭제 |

한계(2026-11-01): 위 증거는 계약·스캐폴드·배포 절차에 관한 것이다. 이벤트 생성기·ledger·dispatcher·FCM 실전송·실기기 수신은 미구현, 라이브 WS 가용성·실장 관측(P9)·PH-1(P11)·운영 승인(P12)은 여전히 미실시. 이벤트 계약의 12 event_type 중 구현·검증된 것은 아직 없다(계약만 존재).

### Evidence log (2026-11-02, 자정 전후) — 이벤트 생성기 merge(PR #20)·ledger+dispatcher merge(PR #21)

| gate | observed |
|---|---|
| VS-3(생성기) | PR #20(vs3-event-gen, `cb4cca3`+`4c1aa6b`, 백그라운드 서브에이전트 구현): `src/hs/event_gen.nim`(517행) — `step(state, record)` 단일 판정 함수, 이벤트 9종 구현(CANDIDATE_{ENTERED,UPDATED,EXITED}·FEED_DISCONNECTED·DATA_GAP_SUSPECTED·REST_TRUNCATED·MARKET_STATE_UNKNOWN·SESSION_{ENDED,INCOMPLETE}; REPLAY_*/SESSION_APPROVED는 session-level verify 산출물로 제외 — §13.8 문언화). verify 제4 아티팩트: 런 events.hcj.jsonl vs 재계산 byte 비교(fail-closed) + `EVENTS=<sha256>` 출력, `REPLAY OK … events=N` 라인. 게이트(main 병합 `ee02680` 후): exit 0 + `EVENT GENERATOR CONTRACT PASSED (62 checks)` + 마커, **스위트 22**. 결정론 실측: 동일 입력 2회 replay → events sha256 `c11b73c7…` 양쪽 동일(`cmp` BYTE-IDENTICAL), 이벤트 기록 `"seq"` 필드 0건(§2 미방출 준수), run.json은 pid/run_id만 상이(§7 문서화된 유일 비결정). 사망·재기동: step-only prefix 판정이 전체 판정의 byte-prefix, `stateAt(prefix)`+재개 fold가 누락분 정확 재현, 미봉합 스트림 SESSION_INCOMPLETE. drill_pair.sh(00:11 KST 창 실측): **45/45 `DRILL PAIR PASSED`** — A live events 존재·카운트·seq 부재, C replay↔live events byte-identical·`EVENTS=` 명명·byte 불일치 0건. 증거 `runs/drill-pair-20261102-001129` |
| CI(결함) | **첫 00:13 KST 창 CI 실패**(`41320116606`·`41320112301`, 증거 보존): `test_watchdog_in_the_past_fires_immediately`가 "과거" watchdog 시각을 `kst_now()-1h`로 만드는데 00:00–01:00 KST엔 어제로 랩되고 `parse_watchdog_seconds`가 이를 오늘의 미래로 해석 → 발화 없이 타임아웃. 선재(先在) 테스트 결함 — 이전 모든 CI는 15:40 이후 KST에만 실행돼 발현되지 않았음. 로컬 00:22 KST 동일 재현. 수정 `4c1aa6b`(자정 가드: 날짜 교차 시 오늘 00:00:00 사용). **PR-5 서브에이전트도 게이트 재측정 중 동일 결함을 독자 발견·동일 수정(`1ecc24c`)** — 두 브랜치가 같은 고치를 가져 PR #21 병합 시 test_sidecar.py 충돌을 main 측으로 해소(`d5f1e11`). 수정 후 CI 2런(`41321312994`·`41321307980`) 성공 + 마커 각 1 |
| P13(0b065bf) | main `0b065bf`(PR #20 merge) push: ci `41321521123`·attest `41321521158` 성공(마커 각 1). `tools/install-attested.sh` → `INSTALL VERIFY OK` → `versions/0.1.0-main-0b065bf`, sha256 `86c57b8b6f34c03c609eefb184c11775d464e38d4430b4e18cf96655c35ed740`, current 원자 전환. smoke `runs/smoke-2026-11-02-0b065bf`: `REPLAY OK bars=22 signals=8 events=1 frames=24` exit 0, `VERDICT MATCH provenance=OK` + `COMMIT=ABSENT` + `EVENTS=6a51940fad537f7f39318f24e9b52d91c3a825bfd24f33b6aa07081f8a04a28d` exit 0 — **배포 바이너리에서 이벤트 산출 최초 실측**(이벤트 1건 = SESSION_ENDED, evidence_ref는 레코드 콘텐츠 주소, observed_at은 레코드 시각 유도) |
| VS-3(ledger) | PR #21(vs3-event-ledger, `d1b6f6d`+`1ecc24c`+main 병합 `d5f1e11`, 백그라운드 서브에이전트 구현): `tools/notify/` 12파일(+3,859행) — ledger(append-only·단일 작성자·미전달 조회·재시작 복구·부분-꼬리 쓰기 거부)·FCM HTTP v1 전송(서비스 계정 OAuth2 RS256 — RFC 7515 A.2 공식 벡터로 서명 검증)·dispatcher(notification+data 메시지·severity 필터·event_id 중복 억제·전달 기록 append)·register(기기 등록·설정 파일 bearer). 429 → 1분+ 백오프·404 UNREGISTERED → 토큰 정리·403 SENDER_ID_MISMATCH → fail-closed. 자격증명은 저장소 밖 경로만 — 저장소 루트 하위 경로 하드 거부(드릴 시나리오 D, exit 2). 게이트(main 병합 후 재실측): exit 0 + 마커, **스위트 24**, notify 53 tests·sidecar 27 tests OK. **fake-FCM 프로세스쌍 드릴(게이트 등록): 33/33 `FAKE-FCM DRILL PASSED`** — 정상 전달·SIGKILL 복구(미전달 재전송·중복은 솔직 기록)·dedup·429 백오프·404 정리·403 fail-closed, 외부 네트워크 0. 증거 `runs/drill-fcm-20261102-004127`(서브에이전트 개발 원본 포함 9디렉터리 runs/ 보존). CI 2런(pull_request `41322728780`·push `41322724271`) 성공 + 마커 각 1 → merge main `885b009` |
| P13(885b009) | main `885b009`(PR #21 merge) push: ci `41322959075`·attest `41322959061` 성공(마커 각 1). 아티팩트 sha256 `f62fd8229cb21d0257d9080d38ef9a94e58d35189d5c2305a97ad4c554ae391e`(`sha256sum -c` 성공). `tools/install-attested.sh` → `INSTALL VERIFY OK` → `versions/0.1.0-main-885b009`, current 원자 전환. smoke `runs/smoke-2026-11-02-885b009`: `REPLAY OK bars=22 signals=8 events=1 frames=24`·`VERDICT MATCH provenance=OK` + `EVENTS=6a51940f…` exit 0 — **이벤트 해시가 0b065bf smoke와 동일**(동일 입력의 이벤트 산출이 서로 다른 main 빌드 간에도 결정론적이라는 교차 증거), `run.json` code_commit == `885b009…` |
| 정리 | gen·ledger 워크트리 제거(미커밋 잔류 0 확인 후), 브랜치 vs3-event-gen·vs3-event-ledger 로컬+원격 삭제. 드릴 증거 10디렉터리(drill-pair 1 + drill-fcm 9) main `runs/`에 보존 |

한계(2026-11-02 자정 전후): 이벤트 생성기·ledger·dispatcher는 계약·합성·드릴 수준에서 검증됐다. FCM 실전송·실기기 수신은 미실시(사용자 자격증명 handoff 대기), 모바일 앱은 스캐폴드 상태, 라이브 WS 가용성·실장 관측(P9)·PH-1(P11)·운영 승인(P12)은 여전히 미실시. fake-FCM 드릴은 프로토콜·상태·재시작 계약을 검증하며 실 FCM 서버의 우발 동작(한도·지연·5xx)을 대체하지 않는다. 이벤트 12종 중 9종이 구현·검증됐고 3종(REPLAY_MATCH/MISMATCH·SESSION_APPROVED)은 verify 산출물로 의도적으로 생성기 밖에 있다(§13.8).

### Evidence log (2026-11-02, 새벽) — Read-only API merge(PR #23)·Flutter 앱 merge(PR #24)

| gate | observed |
|---|---|
| VS-3(API) | PR #23(vs3-api, `98e6c09`+main 병합 `7f90678`, 백그라운드 서브에이전트 구현): `tools/api/serve.py`(593행, 표준 라이브러리만) — GET 6종(/status·/candidates·/events·/events/{id}·/sessions·/sessions/{id}/verification), 쓰기 경로 전무(비-GET 405), 127.0.0.1 전용 바인딩(--bind 옵션 부재로 외부 바인딩 원천 봉쇄), /verification은 기록+CHECKSUMS.sha256 대조만(verify stdout 원문 인용, 없으면 recorded:false — 서버 재계산 없음). 게이트(main 병합 후 재실측): exit 0 + 마커, **스위트 25**, API 22 tests·143 단언·보안 샘플(파일 open은 읽기 모드만·경로 순회 404·핸들러 open 0건). CI 2런(pull_request `41326788483`·push `41326784635`, `ALL CONTRACT SUITES PASSED` 각 1) → merge main `ee53e93` |
| P13(ee53e93) | main `ee53e93`(PR #23 merge) push: ci `41327004039`·attest `41327003958` 성공. 아티팩트 sha256 `b3f3324cfe92dda31e0295c1235a8753bd4558891dc5a25ceef810098a945b87`(`sha256sum -c` 성공). `tools/install-attested.sh` → `INSTALL VERIFY OK` → `versions/0.1.0-main-ee53e93`, current 원자 전환. smoke `runs/smoke-2026-11-02-ee53e93`: `REPLAY OK bars=22 signals=8 events=1 frames=24`·`VERDICT MATCH provenance=OK`·`EVENTS=6a51940f…` exit 0 — 3빌드(0b065bf·885b009·ee53e93) 간 이벤트 해시 동일(교차 결정론), run.json code_commit == `ee53e93…` |
| VS-3(mobile) | PR #24(vs3-mobile-app, `bc26f60`, 백그라운드 서브에이전트 구현 — 1시간 타임아웃 후 Agent resume으로 재개·완료): 28파일 +4024/−157 — 화면 4종(Overview·Timeline·Event Detail·Evidence — 부재·오프라인 솔직 표현)·typed GET-only API 클라이언트(서버 식별자 검증 일치, 오류 분류 timeout/network vs http/format)·단일 ChangeNotifier store(섹션별 로드 상태, 기동/포그라운드 재개/pull-to-refresh 경계 백오프 재동기화)·Android 13+ POST_NOTIFICATIONS 권한 요청 이력 영속(shared_preferences)·getInitialMessage/onMessageOpenedApp 탭 라우팅·release 서명 fail-closed(keystore 저장소 밖, debug-key fallback 없음). 문서화 편차: firebase_messaging 17.x가 onDeletedMessages를 upstream 제거 → 큐 폐기 복구는 resume resync가 담당(mobile/README.md). 검증(메인 에이전트 재실측): 게이트 `ALL CONTRACT SUITES PASSED` exit 0(mobile 변경은 Nim 게이트 무영향), `flutter test` **52/52**, `dart analyze` No issues(제자리 non-ASCII — dart는 정상; `flutter analyze`는 LSP exit 255 크래시로 ASCII 사본에서 대체 실행·클린), `flutter build apk --release` 50.8MB exit 0, `apksigner verify --print-certs` CN=Hong Scanner exit 0, `git ls-files`에 keystore/key.properties/.apk/local.properties 0건. **mobile.yml 신규 CI**(mobile/** paths 필터, required check 아님 — ruleset `ci` 불변): PR #24에서 4런 — ci(pull_request `41334249005`·push `41334230435`, 마커 각 1)·mobile(pull_request `41334248955`·push `41334230634`, `MOBILE SUITE PASSED` 각 3) 전부 success → merge main `c4afd4f` |
| P13(c4afd4f) | main `c4afd4f`(PR #24 merge) push: ci `41334796914`(마커 1)·attest `41334796870`(success)·mobile `41334796848`(`MOBILE SUITE PASSED` 3 — mobile.yml이 main에 들어가 main push에도 트리거) 전부 성공. 아티팩트 sha256 `74fda20c91623d672b2a79e3c69735df36aaac992e55a6a8095831f22772fb0c`. `tools/install-attested.sh` → `INSTALL VERIFY OK`(repo·signer·refs/heads/main·source_digest `c4afd4f…`·github-hosted-only) → `versions/0.1.0-main-c4afd4f`, current 원자 전환. smoke `runs/smoke-2026-11-02-c4afd4f`: `REPLAY OK bars=22 signals=8 events=1 frames=24`·`VERDICT MATCH provenance=OK`·`EVENTS=6a51940f…` exit 0 — **이벤트 해시가 3개 선행 빌드와 동일(4빌드 교차 결정론)**, run.json code_commit == `c4afd4f…`. 모바일은 Nim 빌드 입력이 아니므로 재설치는 절차적 정리(바이너리 소스는 이전과 동일) |
| 정리 | flutter 워크트리 제거·브랜치 vs3-mobile-app 로컬+원격 삭제(본 문서 PR merge 후). release APK 50.8MB·keystore는 저장소 밖·gitignore(미커밋). 루트 hongscanner.md·./hongscanner 미변경(불변 규칙 준수) |

한계(2026-11-02 새벽): 모바일 앱은 계약·합성 테스트·CI·release 서명 수준에서 검증됐다. 실기기 설치·FCM 실수신·Firebase 프로젝트 연동은 미실시(사용자 handoff 대기 — mobile/README.md 7단계 체크리스트). 앱의 FCM 토큰은 화면 표시 → 운영자가 `tools/notify` register CLI로 등록(앱에 쓰기 경로 없음). 라이브 WS 가용성·실장 관측(P9)·PH-1(P11)·운영 승인(P12)은 여전히 미실시. 모의투자 관측이 실전 승인이 아니라는 기존 문언 유지.

### Evidence log (2026-11-02, 오전~저녁) — FCM 실기기 연동(#26~#28)·상주 알림 워커(#29)·라이브 WS 경로(#30)·REST 페이싱(#31/#32)·truncation 계약(#33)

| gate | observed |
|---|---|
| 모바일(FCM) | PR #26(`b36438d`, firebase_messaging 17.x register/onRegistered 전환+handoff 감사 수정)·PR #27(`97043fd`, FcmPushService 연동, handoff 3–4단계). merge push: ci·mobile 전부 success(#26 ci `41365171169`·mobile `41365171168`; #27 ci `41375249160`·mobile `41375249153`). **#27의 attest `41375249185`는 실패 — `BUILD REFUSED: origin is not wintrover/hong-scanner`(fail-closed, 미설치)** → PR #28(`8e1f38b`, MainActivity 추가·canonical repo 고정)로 해소: 8e1f38b ci `41377299181`·mobile `41377299260`·attest `41377299196` 전부 success. 루트 hongscanner.md·./hongscanner 미변경 |
| FCM(실기기·실전송) | 사용자 휴대폰(wuyoni-sm-g977n) 연결·APK 설치·알림 허용·실알림 표시 관측. 오전 실전송 2건 HTTP 200 ACCEPTED(provider_message_id `0:1793586953353610%2e19e6a12e19e6a1`·`0:1793587274008383%2e…`, dedup_suppressed=1). 기기 표시 실측: `dumpsys notification` numPostedByApp=1, tag `FCM-Notification:5882277959`. 기기 등록: 레지스트리 토큰 `eHrUEWnOSQC7f0S-5Qbn4N`(11:34:22). 전달 ledger(`~/.local/share/hongscanner/notify/delivery.hcj.jsonl`) 총 12건 ACCEPTED, 전부 attempts=1·provider_message_id 확보 — **PROVIDER_ACCEPTED≠실기기 표시 경계 유지, 표시는 별도 관측(dumpsys·사용자 확인)** |
| VS-3(상주 워커) | PR #29(`d787b37`, notify-watch): `tools/notify/dispatcher.py --watch`(1초 폴·완성된 LF 라인만·재시작 전수 재탐색 event_id 멱등·백오프 중 신규 이벤트 논블로킹 처리·배치 ingest)·`tools/run_session.sh`(세션 런처 — Collector+Worker 동시 기동·transient 관리·달력 절대경로·notify-config 사본)·collector fsync-before-publish(이벤트 공개 전 원본 입력 fsync). 근거: 오전 관측 "수집이 다 끝나야 알림" — 일회성 CLI 실행 주체 부재(ingest 실행 주체 UNKNOWN 해소). 게이트 `/tmp/gate-notify-watch.log` exit 0+마커. watch 드릴 `runs/drill-watch-20261102-133335`(4시나리오). CI 2런(pull_request `41390111109`·push `41390042671`) 마커 각 1. **attach 실측 `runs/attach-worker-20261102-1353`: 병합 워커가 라이브 PH-1 (2) events 파일 tail — 첫 틱 1,746-이벤트 백로그 ingest, 이후 ~20초 이벤트 쌍이 1초 폴 내 ingest(observed_at→ingest 0–1초, 중앙값 0초, n=20), 171틱, SIGTERM 정지 exit 0** |
| P13(d787b37) | main `d787b37`(PR #29 merge) push: ci `41390719711`·attest `41390719697` success. INSTALL VERIFY OK → `versions/0.1.0-main-d787b37`(sha256 `2a67b63e…`), current 원자 전환. smoke `runs/smoke-2026-11-02-d787b37`: `REPLAY OK bars=22 signals=8 events=1 frames=24`·`VERDICT MATCH provenance=OK`·`EVENTS=6a51940f…` exit 0 — 5빌드 교차 결정론 유지 |
| WS 경로(#30) | **라이브 WS 최초 연결 확정**: 세션 -c(14:58, `9707d2c` pre-merge) — `wss://mockapi.kiwoom.com:10000/api/dostk/websocket` 접속, LOGIN ACK return_code=0·conn open·서버 PING 수신·0s/0B REG ACK, REST ka10027 실데이터(상승: 영광 +32.35% 등, 하락: CJ씨푸드1우 −48.00% 등). 근본원인: 수거체가 경로 없이 루트에 접속(루트 업그레이드 무응답; TCP·TLS1.3·Kiwoom EV 인증서는 정상) — 공식 kwcli SDK는 `base+api_url` 합성, ka10171~73이 `/api/dostk/websocket` 사용. 14:40 라이브 LOGIN 프로브도 pre-merge로 성공(clean close 1000). PR #30(`a660689`, sidecar `DEMO_WS_ENDPOINT`+Nim `demoWsEndpoint`+fakesite expected 동기). CI 2런(`41396140493`·`41396197632`) 마커 각 1. -c의 FCM 3건 200(event 48e0f249·011fd251·a479daa2, 14:58) — **수집 세션 도중 실시간 전송 관측** |
| REST 429(#31/#32) | -c/-d에서 up p2를 1초 내 재요청 → HTTP 429 `return_code=5` "허용된 요청 개수를 초과…유량=1, API ID=ka10027"(모의투자 "TR 1초 1회", 공지 #49). PR #31(`84217ca`): sidecar `_pace_rest()` 잠금 직렬화·최소 간격 강제(rest_min_interval). 1.0초에서도 -d up p2 429 재발(도착 지터로 서버 창보다 짧아질 수 있음) → PR #32(`0b1a474`): 1.5초 마진. 세션 -d(15:19, main 84217ca): down 체인 7페이지 연속 200(아이디스·코아시아씨엠·국일신동·NPC우·TIGER 글로벌자원생산기업·폴라리스AI핸디), FCM 3건 200(299d93bc·07cc9bfa·f9384724). 세션 -e(15:26, `a6cabe9` pre-merge): **up 10페이지 전부 200·429 0건**. CI 마커: #31 `41398641077`·`41398730580`, #32 `41400151639`·`41400244587` 각 1 |
| truncation(#33) | -e가 page cap 10 도달+cont-yn=Y → 구현이 초기 체인 truncation으로 18초 만에 exit 4 INCOMPLETE. 라이브 실측 확정: **벤더가 양방향 상한 초과 반환** — 현행대로면 PH-1 세션이 구조적으로 초기에 사망. 이는 문서 계약 위반(§12.1/GATES: 초과분은 "미조회", 상한은 스캐너 선언) → PR #33(`bded2d4`): cap-closed 체인을 **선언된 truncated 부분집합**으로 소비 — vendor_input `truncatedOk`(호출자 소유 선언, 기본값 기존 거부 유지·below-cap Y·실패 페이지는 불가), collector 초기 체인 진행(gap 기록→다리 전환→도출→REG), rest_resp 감사 수용(페이지 검증), event_gen 무판정 소비(부분 유니버스는 후보 이벤트 없음 — REST_TRUNCATED HIGH/INCOMPLETE가 사실 담당). 게이트 exit 0+마커(1,553 checks), 스트림 종단 테스트 8건 추가(seal→replay OK→20페이지 검증→REST_TRUNCATED 2→후보 이벤트 0→verify MATCH). CI 2런(`41407502571`·`41407496879`) 마커 각 1. -e의 FCM 4건 200(deb11a87·20877264 외 2, 15:26) |
| P13(bded2d4) | main `bded2d4`(PR #33 merge) push: ci `41407827865`(마커 1)·attest `41407827876` success. `tools/install-attested.sh` → `INSTALL VERIFY OK`(source_digest `bded2d4bd36b22bc9c8ddfac3ae29b7724f11b75`·github-hosted-only) → `versions/0.1.0-main-bded2d4`(sha256 `327b2a2d12468e72dfdcfcd98512cfe5113056a498de1e170d02918977336dba`), current 원자 전환. smoke `runs/smoke-2026-11-02-bded2d4`: `REPLAY OK bars=22 signals=8 events=1 frames=24`·`VERDICT MATCH provenance=OK`·`EVENTS=6a51940f…` exit 0 — **6빌드(0b065bf·885b009·ee53e93·c4afd4f·d787b37·bded2d4) 교차 결정론**(이벤트 해시 동일), run.json code_commit == `bded2d4…` |
| PH-1 (2) | 09:01:46 시작·15:40 watchdog 종료. 구동 빌드는 WS 경로 결함 포함(수거체 연결이 매 20초 실패 쌍: ws_conn 1,193·gap 1,194, REST 0건, 입력 2,389줄·events 2,388 — CHECKSUMS·run.json 없는 미봉인 상태로 보존). 종료 계약 정직 동작: "COLLECTOR INCOMPLETE: watchdog 15:40:00+09:00 reached without close evidence (FID 215 in {4,8})". 설치 바이너리(bded2d4) replay: `REPLAY INCOMPLETE: session_end missing` **exit 4**. **수동 래퍼의 `COLLECTOR_EXIT=0`은 파이프 뒤 tail의 종료 코드 — 수거체 실측 exit 아님(알려진 버그 패턴, run_session.sh에서는 수정됨 — 최종 보고에 명시)** |
| 세션 replay | 설치 바이너리로 -c/-d/-e 입력 replay: -c·-d **exit 2 REJECT**(`rest_resp at seq 8 … HTTP status 429` — 429 실패 페이지가 증거로 기록된 체인, fail-closed·그날 증거로 보존), -e **exit 4 INCOMPLETE**(session_end 없음; **cap-closed 10페이지 체인이 새 감사를 통과 — REJECT 아님**, truncation 계약 변경의 라이브 데이터 검증). 증거 `runs/ph1-2026-11-02-{a,b,c,d,e}`(+launcher log·notify-config 사본) main 트리 runs/ 보존. -b는 exit 2(워크트리 달력 상대경로 오류 — gitignored calendars, 증거 보존) |
| 정리 | notify-watch 워크트리 드릴 증거 5건(drill-fcm 2·drill-watch 3) main runs/로 복사 보존. **agent-37 사고**: 서브에이전트가 첫 게이트를 워크트리가 아닌 메인 트리에서 실행(build/hongscanner 재빌드 — gitignored, 보존) — PH-1 (2) 수거체 무영향 확인(collector mtime 08:30 무손상·입력 파일 무결), 잔류물 `runs/drill-fcm-20261102-130012` 보존. wsfix·notify-watch·gates 워크트리는 본 문서 PR merge 후 정리(브랜치 로컬+원격 삭제) |

한계(2026-11-02 오전~저녁): 라이브 관측이 시작됐지만 봉인(`session_end`) 세션은 아직 없다 — P9는 BLOCKED 유지. 세션 -c/-d/-e는 pre-merge 프로브와 merge 직후 혼재이며 canonical 전일 세션은 11-03(화) 실측 대기. FCM 실기기 표시는 dumpsys·사용자 확인으로 관측했으나 도착 시각·순서·중복의 SLA는 여전히 무보장(UNKNOWN 그대로). REST_TRUNCATED는 poll마다 발화할 수 있어(벤더가 양방향 상한 초과) 전일 세션에서 HIGH 푸시 빈도가 오를 수 있음 — min_severity 정책(현재 세션용 HIGH)은 사용자 결정 항목. 푸시 지연 분포(이벤트 기록→FCM POST)·strace fsync 순서·라이브 세션의 replay 일치는 11-03 실측 예정. 수동 래퍼 pipe-exit 버그·StartLimit 후 failed 잔류 등 운영 잔여는 최종 보고에 명시.

### Evidence log (2026-11-02, 낮~저녁) — Northflank Phase-0 코드·계약·공급망 merge(PR #35~#41)·문서 통합

| gate | observed |
|---|---|
| Phase-0(merge) | 7건 merge — #35 serve.py `--bind`(기본 127.0.0.1 불변·0.0.0.0은 컨테이너 전용)·#36 sidecar env TokenProvider(kiwoomcli 기본 경로 불변)·#37 모바일 Basic Auth+보안 저장소·#38 컨테이너 계약+Docker 레이어(스테이징 빌드 컨텍스트·캘린더 INDEX 분리)·#39 serve.py 빈 ledger 0레코드 투영(notify 워커 O_CREAT 크래시 수정)·#40 공급망(2바이너리 증명·GHCR 이미지·digest 증명)·#41 cloud supervisor(프로브 3종 분리·세션 멱등성·ENTRYPOINT 전환). main 경로 `57c299e`→`e355342`(#35)→`653cee4`(#36)→`3abc1a3`(#37)→`a9ee293`(#38)→`7fa156d`(#39)→`782f5da`(#40)→`7eefd0d`(#41) |
| NF-9(782f5da) | main `782f5da`(PR #40 merge) push attest 런 [41456644748](https://github.com/wintrover/hongscanner/actions/runs/41456644748)(2026-11-02T13:51Z) conclusion success — 이미지 `ghcr.io/wintrover/hongscanner:main-782f5da` = digest `sha256:5f1a0ea87db1c8379851c6987875a8e8b46fb7a4d719c355842da47e6b9effec`; 이미지 증명 subject `ghcr.io/wintrover/hongscanner`(subject-digest 일치). 저장소 attestations API로 워크플로 밖 재확인: payload의 source digest `782f5da1dc17749c6886131681a86c954e7b20d6`·ref `refs/heads/main`·workflow `.github/workflows/attest.yml`·run `41456644748`. 로컬 `gh attestation verify oci://`는 토큰에 `read:packages` 스코프가 없어 거부 — 운영자 PAT 경로만 가능(tools/container/README.md §8.3; LIMITS.md) |
| P3(PR #41) | PR #41 head `b6b8046` ci 런 [41470981402](https://github.com/wintrover/hongscanner/actions/runs/41470981402) conclusion success — 로그 **2129행** `ALL CONTRACT SUITES PASSED`(2026-11-02T15:24:24Z), ok 1,618건·`161 passed, 0 failed` 실측(supervisor 스위트 포함 게이트) |
| P13(7eefd0d 실패) | main `7eefd0d`(PR #41 merge) push attest 런 [41471911408](https://github.com/wintrover/hongscanner/actions/runs/41471911408)(2026-11-02T15:28:22Z) **failure** — 이미지 페이즈만 실패: 스테이징 컨텍스트에 `tools/container/cloud_supervisor.py` 부재(`COPY ... not found` — PR #41이 Dockerfile에 추가한 파일이 attest.yml의 이미지 스테이징 목록에 없음). 테스트 게이트·2바이너리 증명·아티팩트 업로드는 전부 success(README §8.1 페이즈 순서 불변식대로 로컬 재설치 경로는 보존), digest 검증·이미지 증명 업로드는 skip. **`ghcr.io/wintrover/hongscanner:main-7eefd0d`는 존재하지 않는다 — 최후 성공 이미지는 `main-782f5da`.** 수정은 attest.yml 스테이징 목록 갱신 코드 PR이며 본 문서 PR(docs-only)은 수정하지 않는다. 누적 attest 게이트 실패 3회(`f4ad05c`·`97043fd`·`7eefd0d`) |
| NF-9 근거(볼륨) | runs/ 저장량 2026-11-02 실측: 총 6.3MB·688파일, 라이브 세션 하루 최대 1.3MB(`runs/ph1-2026-11-02-a`), 드릴 런 168~180KB → 1GiB Single Read/Write Volume 근거(PH-1 속도 기준 약 700거래일 여유). 실제 볼륨 사용량·필요 크기는 배포 전까지 UNKNOWN(U15) |
| NF 경계 | 실제 Northflank 배포·프로브 매핑·Kiwoom 클라우드 접속은 없다 — NF-0~NF-8·NF-10~NF-12는 전부 PENDING(사용자 계정 게이트·실배포 전). 본 문서 PR은 위 증거를 네 docs 파일에 통합하는 docs-only 변경이다 |

한계(2026-11-02, Phase-0): 위 증거는 코드·계약·공급망·CI·이미지 digest에 관한
것이다. Northflank 계정·배포·프로브 매핑·Kiwoom 클라우드 실접속·볼륨
영속성·클라우드 FCM 종단은 전부 미실시(NF 사다리 PENDING). 이미지 digest
증명도 GitHub가 서명한 것으로 GitHub 인프라와 독립이 아니다. `7eefd0d`의
이미지 페이즈 실패로 현재 main HEAD의 운영 이미지는 존재하지 않으며,
PR #35~#41 merge분에 대한 attest·설치·검증 재측정(AGENTS.md §2.2)은 그
수정 PR이 merge된 뒤의 다음 main에서 다시 실시한다.

### Evidence log (2026-11-03) — attest 이미지 수리(#43)·§2.2 재측정(bdc697e·bd28355)·PR-A 상위 100개 선정(#45)

| gate | observed |
|---|---|
| P13(06f4208 실패) | main `06f4208`(PR #42 docs-only merge) push attest 런 [41560395236](https://github.com/wintrover/hongscanner/actions/runs/41560395236)(2026-11-03T01:32Z) **failure** — #41과 동일 인과(이미지 페이즈: 스테이징 컨텍스트에 `tools/container/cloud_supervisor.py` 부재 `COPY ... not found`; 수정 PR #43 merge 전에 docs-only merge가 먼저 들어와 실패가 재현). 정확 비트의 테스트 게이트·2바이너리 증명·아티팩트 업로드는 success(로컬 재설치 경로 보존), digest 검증·이미지 증명은 skip. **`main-06f4208` 이미지는 존재하지 않는다.** 누적 attest 게이트 실패 4회(`f4ad05c`·`97043fd`·`7eefd0d`·`06f4208`) |
| P13(bdc697e) | main `bdc697e`(PR #43 merge — `de3e9fa`가 attest.yml 이미지 페이즈 스테이징에 `tools/container/cloud_supervisor.py` 추가) push attest 런 [41561345356](https://github.com/wintrover/hongscanner/actions/runs/41561345356)(2026-11-03T01:41Z) success — `IMAGE OK ref=ghcr.io/wintrover/hongscanner:main-bdc697e digest=sha256:7223d35d1fcf7b62f28a4d7df66a0aa60489f99b3f8593f7645cf410bf9d2052`. **2026-11-02 한계의 §2.2 재측정 약속 이행 — 이미지 공급망 복구.** `tools/install-attested.sh` → `INSTALL VERIFY OK`(source_digest `bdc697e91f…`) → `versions/0.1.0-main-bdc697e`(sha256 `d7c93362cc5698fca59230894f4f2862f75a4a0d30500935c64616f98b6ef071`, installed_utc 2026-11-03T01:49:49Z). smoke `runs/smoke-2026-11-03-bdc697e`: `REPLAY OK bars=22 signals=8 events=1 frames=24`·`VERDICT MATCH provenance=OK`·`COMMIT=ABSENT`·`EVENTS=6a51940f…` exit 0 |
| P13(8a3e74a) | main `8a3e74a`(PR #44 docs-only, 모바일 실기기 LAN 경로 문서화) push attest 런 [41570141910](https://github.com/wintrover/hongscanner/actions/runs/41570141910)(2026-11-03T03:06Z) success — `IMAGE OK ref=ghcr.io/wintrover/hongscanner:main-8a3e74a digest=sha256:6ccd9c901986e5e3dea8f8bbd92fca04f1a59edbfe6c9956eebbe37f980d3257`. docs-only는 Nim 빌드 입력이 없으므로 재설치 생략(abd0c9a 전례와 동일 기준) |
| P3(PR #45) | PR #45(`feat/subscription-top-100`, head `6a41baa`, 3커밋: `33ccf3a` core·`308b3ff` test·`6a41baa` docs) — 게이트 3중 실측: 로컬 독립 재실행 exit 0(신규 `SUBSCRIPTION SELECTION CONTRACT PASSED (56 checks)` 포함, 게이트 로그 1,320행)·브랜치 push ci `41582264560`·PR ci `41582353044` 전부 success(마커 각 1). merge push main ci `41583598959` success(`ALL CONTRACT SUITES PASSED` 2026-11-03T05:25:34Z 실측) |
| P13(bd28355) | main `bd28355`(PR #45 merge) push attest 런 [41583598880](https://github.com/wintrover/hongscanner/actions/runs/41583598880)(2026-11-03T05:23Z) success — `IMAGE OK ref=ghcr.io/wintrover/hongscanner:main-bd28355 digest=sha256:11608eae52a4a269fbf25c218a3841c6afb0a82bd1a1fade2e1d36ca21a9f34e`. 아티팩트 sha256 `5ce00efe534cf9b4881ab4a6f78ecbaa2772de4f9808eb3ae910fe29684e58d2` == `hongscanner.sha256`. `tools/install-attested.sh` → `INSTALL VERIFY OK`(source_digest `bd283551d…`) → `versions/0.1.0-main-bd28355`, current 원자 전환(이전 버전 보존). selftest `SELFTEST bytes=OK bars=22 signals=8` exit 0(로컬 실행의 `provenance=NOT_CANONICAL`는 정상). smoke `runs/smoke-2026-11-03-bd28355`: `REPLAY OK bars=22 signals=8 events=1 frames=24`·`VERDICT MATCH provenance=OK`·`COMMIT=ABSENT`·`EVENTS=6a51940f…` exit 0 — **8빌드(0b065bf·885b009·ee53e93·c4afd4f·d787b37·bded2d4·bdc697e·bd28355) 교차 결정론**(이벤트 해시 동일; bdc697e·bd28355 smoke가 이번에 기여) |
| 세션 관측(11-03) | 라이브 세션 2회(`ph1-2026-11-03-a` 10:25·`-b` 13:59)가 구 바이너리로 방향별 구독 cap 초과로 종료: `COLLECTOR CONTRACT: up direction exceeds the subscription cap 100: 949 codes`·`794 codes`(notice #49) — exit 2, 런·launcher log 보존. PR-A의 동기이자 "벤더가 양방향 상한 초과 반환"의 재확인. 로컬 컬렉터 `tools/collector/collector`를 bd28355 소스로 재빌드(Nim 2.2.10, 바이너리에 `kiwoom_response_order_first_100_v1`·`SUBSCRIPTION_TRUNCATED` 문자열 포함 확인) — 11-04 세션부터 상위 100개 선정 적용 |
| P3(PR #46) | PR #46(docs/gates-bd28355-evidence, head 907be09) — ci 2런: push 41586850652·PR 41586856576 전부 success(각 로그에서 ALL CONTRACT SUITES PASSED 1회 실측), merge 5bee7bc(15:00:35 KST). docs-only(증거 기록) 변경 |
| P13(5bee7bc) | main 5bee7bc(PR #46 merge) push attest 런 41587205400(2026-11-03T06:05Z) success — IMAGE OK ref=ghcr.io/wintrover/hongscanner:main-5bee7bc digest=sha256:42d6df5745e7bd921a07c61f0d3f8fedce2175301ab1522657aaf9cab816cf40. 스테이징 수리 이후 4연속 main push 이미지 생성(main-bdc697e·main-8a3e74a·main-bd28355·main-5bee7bc). docs-only 커밋이므로 §2.2 재설치는 면제(AGENTS.md §2.2) |
| 종료 관측(15:40) | 15:40 KST 종료 관측: 세션 -a·-b 모두 COLLECTOR_EXIT=2(up 방향 949/794 codes > cap 100, notice #49), 종료 10:25:48·14:00:10. events.hcj.jsonl 각 1건 SESSION_INCOMPLETE(HIGH, observed_at 10:25:43·13:59:57) — SESSION_ENDED·SESSION_APPROVED 없음, COMMITTED 없음(미봉인 보존), 실행 중 수집 프로세스 없음 |
| 세션 replay | 설치 바이너리(0.1.0-main-bd28355)로 -a·-b 입력 replay: 모두 exit 2 REJECT — rest_resp 페이지 체인(sort_tp 3, 9페이지)이 cont-yn=Y인 채 종료(선언된 연속 페이지 미기록, fail-closed; 컬렉터가 up cap 위반으로 사망하며 down 체인 page 10 미fetch). REJECT로 출력 디렉터리 미생성 → verify N/A. 최초 측정에서 파이프 뒤 tail의 exit 0을 잘못 잡은 것을 재측정으로 교정(알려진 pipe-exit 패턴) |
| 전달 관측 | delivery.hcj.jsonl 오늘 2건: -a SESSION_INCOMPLETE(f459c48a…) ACCEPTED attempts=1 provider_message_id projects/hongscanner/messages/0:1793669145233251%2e19e6a12e19e6a1(10:25:45, observed_at→결과 약 2초). -b SESSION_INCOMPLETE(0f7ca295…) FAILED error_code=NOT_FOUND HTTP 404(14:00:07) — 기기 wuyoni-sm-g977n 토큰(11-02 등록)이 오전 ACCEPTED→오후 404로 하루 중간 무효화, 이후 알림 지속 실패 상태(재등록은 사용자 조치, 앱에 쓰기 경로 없음). REST_TRUNCATED 푸시 오늘 0건(양 세션 초기 체인 사망, poll 미도달) — min_severity 정책 변경 없음(사용자 결정). worker 재시작 0회(각 1회 기동, watch stop exit 0, ExecMainStatus=0) |

한계(2026-11-03): 위 증거는 게이트·공급망·설치·합성 재현에 관한 것이다. 상위 100개 선정의 라이브 발화(SUBSCRIPTION_TRUNCATED 이벤트·subscription_truncated 갭·전달 빈도)와 세션 완결(`session_end`+`VERDICT MATCH`)은 11-04 세션 실측 대기이며, 오늘 세션 2회는 구 바이너리 실패로 보존돼 있다. 11-03 봉인된 실측 세션 0건 — P9·P11·P12 BLOCKED 유지, 두 실패 세션·증거는 원본 보존. 15:40 종료 관측은 cron(관측·보고 전용)으로 수행했다. FCM 기기 토큰 무효(NOT_FOUND)는 사용자 재등록 대기. 11-04 세션 관측 지점: 상위 100개 선정의 라이브 발화(SUBSCRIPTION_TRUNCATED·selection 증거)와 down 체인 page 10 미fetch REJECT 양상의 소멸 여부.

### Evidence log (2026-11-05) — Projection Slice v4: 읽기 전용 투영 관측(합성 재생·검증·API·오프라인 프로브, 신규 코드 0줄)

| gate | observed |
|---|---|
| 관측(환경) | 2026-11-05, main `712e76c`(HEAD==origin/main `712e76cd7510962f9c28ac1e3948b512c8c58f99`, tree clean)에서 읽기 전용 투영 슬라이스 — 신규 코드 0줄·추적 파일 수정 0건(생성물은 전부 gitignored `runs/observe-2026-11-05-slice/`). 검증 바이너리는 설치본 `~/.local/share/hongscanner/current/hongscanner`(sha256 `5ce00efe534cf9b4881ab4a6f78ecbaa2772de4f9808eb3ae910fe29684e58d2` — PROVENANCE.txt `sha256`·`source_digest=bd283551d7bdcecefb942d68c53aafd2119cd895`·repo·signer_workflow·runner_policy 일치). 루트 `./hongscanner`는 런북 전제(과거 사고 잔류 빌드)와 달리 실측 **부재** — 사용하지 않았으므로 무영향(기대치 차이 원문: EXECUTION-LOG.md) |
| 재생·검증 | `replay --in fixtures/smoke/input.hcj.jsonl --out runs/observe-2026-11-05-slice/runs/smoke-2026-11-05-bd28355`(신규 디렉터리) → exit 0, `REPLAY OK bars=22 signals=8 events=1 frames=24`; `verify --run` → exit 0, `VERDICT MATCH provenance=OK`·`COMMIT=ABSENT`·`EVENTS=6a51940fad537f7f39318f24e9b52d91c3a825bfd24f33b6aa07081f8a04a28d` — grep -Fxq 단언 4건 전 PASS(기대값 조정 0건). Phase 0 git 단언 2건은 스크립트 sed 줄번호 결함(clean porcelain은 0바이트)으로 거짓 FAIL이 찍혔다 — 원문(`git-commit.txt`·`phase0-results.txt`) 보존 후 측정 방법만 수정해 재판정 PASS(기대값 조정 아님) |
| 서빙(격리) | `serve.py --runs runs/observe-2026-11-05-slice/runs --ledger ~/.local/share/hongscanner/notify/ledger.hcj.jsonl --delivery ~/.local/share/hongscanner/notify/delivery.hcj.jsonl --port 8080` — 전용 루트 격리 기동(관측 대상 단일 런만 노출 → `/sessions.count==1`), 기동 라인 `SERVE 127.0.0.1:8080`, readiness 1초 만에 HTTP 200(첫 PID 2336216, 포트 소유 `ss` 실측) |
| API 관측 | 35 단언 전 PASS(jq -e rc=0, 원문 `phase3-results.txt`): /status `events.count=14`·`by_type={CANDIDATE_ENTERED:2,DATA_GAP_SUSPECTED:6,REST_TRUNCATED:1,SESSION_INCOMPLETE:5}`·`by_severity={HIGH:14}`·`latest_session_id="2026-11-03"`·`delivery.by_state={ACCEPTED:13,FAILED:1}`·`pairs=14`·`devices=1`; /events `count=14`·event_id 14건 전 64-hex(응답은 top-level 객체 `{ledger_present,count,events,delivery}` — 런북의 '배열 길이 14' 기대치 차이는 `.count`·`.events\|length`로 실측); ledger 마지막 줄 `0f7ca29521a36725056e51ad7d60a2fa34a1f0976eaf599d172fa098744d1035`(SESSION_INCOMPLETE)↔`GET /events/{id}` `.event` 팩트 전체 `COMPARE OK`(event_type·session_id·severity·observed_at·data_quality·rule_id·rule_version·evidence_ref·delivery 전부 일치); /sessions `session_date="2026-10-29"`·`code_commit="bd283551d…"`; `GET /sessions/smoke-2026-11-05-bd28355/verification` `committed_marker.present=false`·아티팩트 4개(input/bars/events/signals) 전 `match=true`·`replay_verdict.line="VERDICT MATCH provenance=OK"`; /candidates `session_id="2026-11-03"`·`count=0`·`events=[]`; 오류 경로 `POST /status`→405·`GET /events/deadbeef`→404 |
| 오프라인 프로브 | SIGTERM kill(첫 PID 2336216) → 2초 내 종료 → `curl` 종료코드 7, 원문 `Failed to connect to 127.0.0.1 port 8080 after 0 ms: Couldn't connect to server`(연결 거부 관측) → 동일 인자 재기동(신규 PID `2369050`, 로그는 `serve-restart.log`로 분리 — 첫 `serve.log` 원문 보존, 덮어쓰기 금지) → readiness 1초 `/status` 200. 최종 서버 구동 유지(관측 시점 `http_code=200`, 원문 `server-final-state.txt`) |
| Phase 4(앱) | **GATE** — `mobile/android/app/google-services.json` 부재(외부 의존·사용자 제공 대기; `build.gradle.kts`가 google-services 플러그인을 참조) → 앱 빌드·설치·화면 관측 전부 미실행(`flutter build apk`는 실패가 아니라 게이트 미실행 — GATE.md). 보조 실측: `am start` `Error type 3`(미설치 확인), 기기 SM-G977N·Android 12(release 12·sdk 31) |
| 증거 보존 | `runs/observe-2026-11-05-slice/` 75항목(EXECUTION-LOG.md·phase0~5 스크립트·결과 원문·replay.log·verify.stdout·serve.log·serve-restart.log·JSON 응답 원문·GATE.md 등 — gitignored·로컬 한정) + `CHECKSUMS.sha256`(sha256 `df2f26c473f3a7f491f00eff3323ce6cac9f8b5158c960dc54e45c67e83f23a1`, 75항목) — 제3자 원문 재검토 가능 |

한계(2026-11-05): 위 관측은 합성 재생 smoke·API 투영·오프라인 프로브에 관한 것이다. smoke는 합성 재생이므로 `VERDICT MATCH`는 재생 일치이지 실측 운영 승인이 아니다 — P12는 BLOCKED 유지(P9·P11 포함). ledger 14건은 실측 12건(2026-11-02 10건·2026-11-03 2건)과 합성 Drill 2건(`drill-2026-11-02-fcm`)의 혼합이며 session_id·원본 기록 기준 구분을 유지한다. 관측된 세션은 INCOMPLETE·미봉인이고 delivery ACCEPTED는 기기 도착이 아니다(FCM 토큰은 2026-11-03 무효화 — 재등록은 사용자 조치, 앱에 쓰기 경로 없음). 모바일 Timeline 행에는 session_id·data_quality가 미표출이며 Event Detail에서만 가시하다(알려진 미표출). no-data·HTTP 오류 화면은 NOT-MEASURED(오프라인 프로브는 서버 curl 실패만 실측). 앱 화면 표시는 본 게이트 미관측 — 실기기 표시는 google-services.json 제공 시 후속 관측 과제다. 본 증거 기록 PR은 docs-only(신규 코드 0줄)이며, merge는 CI 런 로그에서 `ALL CONTRACT SUITES PASSED`를 실측한 뒤에만 수행하는 운영자 수동 통제다 — 기술적 강제가 아니므로 branch protection 실효성은 UNKNOWN 그대로다(관리자가 보호 규칙을 변경할 수 있다는 기존 한계와 동일 근거).

### Evidence log (2026-11-05, 밤) — main `244be87` post-merge attest 403 실패(GITHUB_TOKEN `actions: read` 강제 추정)

| gate | observed |
|---|---|
| P13(244be87 실패) | main `244be87`(PR #48 docs-only merge, 2026-11-05T12:07:59Z) push attest 런 [42024560285](https://github.com/wintrover/hongscanner/actions/runs/42024560285)(생성 2026-11-05T12:08:02Z) **failure — attempt 1·2 모두 동일 양상**: CI-gate 단계의 `gh api repos/wintrover/hongscanner/actions/runs?head_sha=244be87…` 호출이 10회 연속 `HTTP 403 "Resource not accessible by integration"`(attempt 1: 12:08:12Z~12:10:30Z, 잡 12:08:05→12:10:32Z·attempt 2 리런: 12:17:20Z~12:19:38Z) → 원문 `CI GATE FAIL: gh api failed 10 consecutive times; refusing to attest` exit 1 — 실패를 성공으로 바꾸지 않는 fail-closed 정상 동작. 진단: `.github/`은 PR #43(`de3e9fa`) 이후 무변경인데 동일 단계가 11-03 07:06Z 런 [41594048461](https://github.com/wintrover/hongscanner/actions/runs/41594048461)(success)에서는 API 폴링 성공으로 통과(`ci push run for 712e76c… not completed yet` 출력 = 호출 성공) → **GitHub 측이 GITHUB_TOKEN의 Actions 런 목록 조회에 `actions: read` 권한을 강제하기 시작한 것으로 추정** — attest 잡 `permissions:` 블록 실측 `contents: read`·`id-token: write`·`attestations: write`·`packages: write`에 `actions: read` 부재(`.github/workflows/attest.yml`). 일시 장애 아님(리런 재현) |
| 영향·수리 경계 | 누적 attest 게이트 실패 5번째(`f4ad05c`·`97043fd`·`7eefd0d`·`06f4208`·`244be87`). `main-244be87` 이미지·증명 없음. docs-only merge이므로 재설치 면제(전례)·운영 바이너리 무영향(설치 current는 여전히 bd28355). **게이트는 BLOCKED 유지** — 수리(attest.yml에 `actions: read` 추가)는 코드 변경이므로 별도 승인·변경으로 처리하며 본 PR(docs-only)은 기록만 한다 |

한계(2026-11-05, attest 403): 원인 진단은 추정이다 — 관측된 사실은 "무변경 워크플로가 11-03 통과 → 11-05 403×2회"이며 GitHub의 권한 강제 시작 시점·공식 발표는 확인되지 않았다(UNKNOWN). 본 PR merge는 main push로 attest를 다시 트리거하며 동일 403 실패의 재현이 예상된다(고장 상태 동일) — 그 재현은 본 항목에 기록된 알려진 상태의 재현이며, 재현 확인을 위한 추가 PR은 만들지 않는다. attest 수리 전에는 모든 main push의 증명·이미지 산출이 차단되므로 동작 변경 merge의 재측정(AGENTS.md §2.2)을 수행하려면 수리 PR이 선행돼야 한다.

### Evidence log (2026-11-05, 오후) — attest 게이트 수리 사이클: 403·익명 fetch 128·base64 wrap 3종 수리 완결, 증명 저장에서 세 번째 별개 결함(플랫폼 제한) 발견으로 BLOCKED 마감

| gate | observed |
|---|---|
| P13(310d596, 403 수리 실측) | main `310d596`(PR #50 merge — `.github/workflows/attest.yml` permissions에 `actions: read` 1줄) push attest 런 [42033872259](https://github.com/wintrover/hongscanner/actions/runs/42033872259)의 CI-gate 단계가 **403 없이 통과**: `ci run for 310d5960fd4ef54fbeac60946e15788eca796625: https://github.com/wintrover/hongscanner/actions/runs/42033872251 -> status=completed conclusion=success`(2026-11-05T13:17:05Z) — 이전 항목(#49)의 403 진단·처방(actions:read 부여) 효과 실측. 선행 재현: #49 merge `ff82213`의 attest 런 [42028888702](https://github.com/wintrover/hongscanner/actions/runs/42028888702)가 `Resource not accessible by integration` 10회(예측된 알려진 상태의 재현). 저장소 PRIVATE 실측(`gh repo view wintrover/hongscanner --json visibility` → `PRIVATE`), attest.yml 설계 주석(117-122행)이 "2026-11-03 게이트 통과는 전환 전·workflow-runs 호출에 actions:read 필요"를 기술 |
| P13(310d596 실패, 결함 #2) | 같은 런 42033872259의 `Separate CI build` 단계 실패 — `fatal: could not read Username for 'https://github.com': No such device or address`(2026-11-05T13:19:32Z) exit 128: `tools/ci_build.sh`의 origin/main 재fetch(익명)가 private 저장소에서 거부됐다. 워크플로·스크립트 무변경 — 결함이 아니라 전환으로 드러난 미인증 경로. 누적 attest 게이트 실패 7번째(244be87 5번째·ff82213 재현 6번째에 이어), `main-310d596` 이미지·증명 없음. 바이너리 입력 불변(src·hongscanner.nimble 무변경)으로 재설치 면제, 설치 current는 bd28355 유지 |
| P13(수리 #2 설계) | PR #51(`ci/attest-private-fetch`, merge `a7a7c0a`): ci_build.sh의 fetch가 `CI_GIT_TOKEN` env를 볼 때 per-command `http.extraheader="AUTHORIZATION: basic base64(\"x-access-token:<token>\")"`로 인증 — actions/checkout의 git-auth-helper(ADR 0153)가 쓰는 형식과 동일, 토큰을 URL·git config·echo에 두지 않는다(커맨드 후 지속 0, checkout은 persist-credentials:false 유지). attest.yml:247이 job `secrets.GITHUB_TOKEN`을 공급. REQUIRED 가드·HEAD==push SHA==origin/main 동등성·fail-closed exit 1 불변. CI 2런 success·마커 각 1(브랜치 push 42033872251 2026-11-05T13:16:44Z·merge push 42040018619 2026-11-05T13:57:27Z) |
| P13(a7a7c0a 실패, 수리 #2 1차 시도) | main `a7a7c0a`(#51 merge) push attest 런 [42040018677](https://github.com/wintrover/hongscanner/actions/runs/42040018677) 실패 — 같은 `Separate CI build` 단계: `CI_GIT_TOKEN: ***`(env 공급·마스킹 실측) 직후 `fatal: unable to access 'https://github.com/wintrover/hongscanner/': A libcurl function was given a bad argument`(2026-11-05T14:00:39.7Z) exit 128. 진단(로컬 재현으로 확정): 러너 GITHUB_TOKEN(v2 형식, 42자 초과)은 GNU base64가 76열에서 wrap하고 extraheader에 내장된 개행을 libcurl이 거부(CURLE_BAD_FUNCTION_ARGUMENT). 로컬 사전검증 PAT는 40자(단일 줄)라 같은 결함이 재현되지 않았다. 합성 94자 토큰으로 미교정형 exit 128 재현, `tr -d '\n'` 교정형은 실패가 인증 계층("could not read Username" — 요청이 서버에 도달하고 헤더가 정상)으로 이동, 실제 PAT로 fetch exit 0. 누적 8번째 — 같은 단계·같은 fetch 경로·결함 #2의 미완료로 판정(신규 별개 결함 아님) |
| P13(a00344c, 교정·수리 완결) | PR #52(`ci/attest-extraheader-nowrap`, babb53a — 1줄 교정 `base64 | tr -d '\n'` + 근거 주석): 구조 실측(94자 토큰: base64 출력 개행 1 → 교정 후 0, 단일 줄 148자), `bash -n` OK, 실 PAT로 인증 fetch exit 0(토큰 값 미출력·길이 40만 기록). attest.yml 무수정(env 이미 공급). CI 2런 success·마커 각 1(브랜치 push 42042877167 2026-11-05T14:15:35Z·PR 42042984884 2026-11-05T14:16:58Z), merge `a00344c`(14:17:50Z), merge push ci 42043636628 success(마커 2026-11-05T14:20:47Z). 재설치 면제 근거 재확인: `git diff bd283551d7bdcecefb942d68c53aafd2119cd895..a00344c --stat -- src/ hongscanner.nimble` 빈 출력(바이너리 입력 불변) |
| P13(a00344c 실패, 신규 별개 결함 — BLOCKED) | main `a00344c` push attest 런 [42043636600](https://github.com/wintrover/hongscanner/actions/runs/42043636600) **failure — 그러나 수리 3종 전부 완결 실측**: 15단계 success(CI-gate·Test gate·`Separate CI build` 인증 fetch 통과·provenance 검증·smoke 2건·플랫폼 태그 포함) 후 `Attest the binary (SLSA build provenance, OIDC-signed)` 단계 실패 — 원문: `##[error]Error: Failed to persist attestation: Feature not available for user-owned private repositories. To enable this feature, please make this repository public. - https://docs.github.com/rest/repos/attestations#create-an-attestation`(2026-11-05T14:24:23Z). 이후 단계 전부 skip — `main-a00344c` 증명·이미지 없음(누적 9번째). **결함 #1(403)·결함 #2(fetch 128·base64 wrap 포함)의 수리는 이 런으로 완결 실측** — 실패는 증명 저장 단계의 새 별개 결함(다른 단계·다른 컴포넌트: GitHub attestations 저장 API). 공식 문서 대조([GitHub Docs](https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds)): "If you are on a GitHub Free, GitHub Pro, or GitHub Team plan, artifact attestations are only available for public repositories. To use artifact attestations in private or internal repositories, you must be on a GitHub Enterprise Cloud plan." — 사용자 소유 private 저장소의 플랫폼 제한이며 워크플로 코드 결함이 아니다. **수리는 시도하지 않는다** — 해법(공개 전환·GHEC 조직 이전·`create-storage-record:false` 등 워크플로 변경)은 전부 사용자 결정 사항이다. 게이트는 BLOCKED 유지 |

한계(2026-11-05, attest 수리 사이클): 403의 근본 원인(GitHub가 GITHUB_TOKEN의 Actions 런 조회에 actions:read를 강제하기 시작한 시점·발표)은 여전히 추정이며 UNKNOWN을 유지한다 — 관측된 사실은 "처방 전 403×2런·처방 후 통과"뿐이다. base64 wrap 진단은 로컬 합성 재현(94자 토큰 exit 128)과 러너 실패 문언(libcurl 인수 오류)의 일치에 근거하며, 러너에서 헤더 자체를 덤프한 것은 아니다(토큰은 비공개·로그 마스킹 실측). 신규 결함의 관측은 에러 문언·공식 문서 일치이며, OIDC 서명 자체의 성공·실패는 분리 관측되지 않았다(에러는 "Failed to persist" — 저장 단계). 실패 런 5건(42024560285·42028888702·42033872259·42040018677·42043636600)은 원문 그대로 보존됐다. 이 사이클의 추적 파일은 tools/ci_build.sh·.github/workflows/attest.yml·docs/GATES.md(본 기록) 3종뿐이며 mobile/·runs/은 무접촉(관측 서버도 무중단). 설치 current는 bd28355 유지 — a00344c는 증명·이미지가 없으므로 설치 대상이 아니며, 바이너리 입력이 불변(위 git diff 실측)이므로 AGENTS.md §2.2 재설치는 이번에 면제, attest 게이트가 복구된 뒤 다음 동작 변경 merge에서 통상 재측정한다. attest 게이트는 신규 결함으로 BLOCKED — 해법 선택(공개 전환/GHEC/workflow 변경) 전까지 모든 main push의 증명·이미지 산출이 차단되며, 그 상태의 재현(본 docs PR merge 포함)은 여기에 기록된 알려진 상태의 재현이다. attest.yml의 stale 주석("90 days, public-repo cap" 등 아티팩트 보존 주석·단계명)은 최소변경 원칙으로 의도적으로 남겼다(fetch 경로와 무관).

### Evidence log (2026-11-05, 심야) — Projection Slice 앱 관측 완수: google-services.json firebase_options.dart 재구성(Option B 검증 성공), 실기기 4화면·오프라인 프로브

| gate | observed |
|---|---|
| 관측(구성 출처·구조 검증) | `mobile/android/app/google-services.json` 부재로 막혔던 Phase 4 게이트를 재구성으로 해소 — 값은 전부 repo 추적 파일 유래: `firebase_options.dart` android 블록 5필드(apiKey·appId·messagingSenderId·projectId·storageBucket) + `build.gradle.kts` applicationId(`com.hongscanner.hongscanner`), 생성 스크립트로 작성·round-trip 구조 검증 PASS. 구조는 GoogleServicesTask.kt 공식 소스 대조로 확정(project_info.project_number/project_id 필수·package_name==applicationId 불일치 시 GradleException·mobilesdk_app_id·api_key[0].current_key 필수·services·oauth_client 선택·파일 누락 시 ERROR 전략 — 원문 `phase45-gs-plugin-docs.md`). 배치는 gitignored(`git check-ignore -v` → `mobile/android/.gitignore:18:google-services.json`), git status clean 3회(관측 전·후·manifest 후 — 전부 빈 출력 원문 보존)·mobile 커밋 0건(마지막 커밋 `11ed1a5` 불변) — **새 신뢰 표면 0** |
| 관측(빌드·설치·기동) | `flutter build apk --debug --dart-define=HS_API_BASE=http://127.0.0.1:8080` exit 0(61초, `✓ Built build/app/outputs/flutter-apk/app-debug.apk`), APK sha256 `f952ac8e6acc8510be8869df7c9e77a1dfadde467c731a3f59254631f6a5878b`(재실측 일치). `adb install -r` → `Success`; `adb reverse tcp:8080 tcp:8080`(UsbFfs 실측); `am start` → MainActivity 포그라운드; logcat `FirebaseInitProvider: FirebaseApp initialization successful`·FCM 토큰 획득(Overview 푸시 카드 표시 실측)·FATAL 0건. versionName 1.0.0·기기 SM-G977N·Android 12. 서버 요청 로그(`phase45-serve-before-kill.log`): 앱이 GET /status·/events·/candidates·/sessions·/sessions/smoke-2026-11-05-bd28355/verification·/events/0f7ca295… 전부 200 수신(포그라운드 복귀마다 resync 라운드 반복 관측) |
| 관측(4화면) | **Overview** — 세션 1·`smoke-2026-11-05-bd28355`·`2026-10-29`·run.json 기록 있음, 이벤트 14(`CANDIDATE_ENTERED×2, DATA_GAP_SUSPECTED×6, REST_TRUNCATED×1, SESSION_INCOMPLETE×5`), 최신 SESSION_INCOMPLETE 2026-11-03T13:59:57+09:00, 전달 `ACCEPTED×13, FAILED×1`, 검증 `4/4 일치`·`VERDICT MATCH provenance=OK`, 후보 "상승/하락 방향 기록 없음"(/candidates count=0와 일치). **Timeline** — "ledger 기록 순서 (append 순서 — API가 재정렬하지 않음)" 헤더·14행·마지막 행 SESSION_INCOMPLETE 2026-11-03T13:59:57·전달 FAILED. **Event Detail** — `0f7ca29521a36725056e51ad7d60a2fa34a1f0976eaf599d172fa098744d1035` ledger 원문 전 필드 일치(SESSION_INCOMPLETE·data_quality INCOMPLETE·session_id 2026-11-03·severity HIGH·rule_id session-incomplete-v1·rule_version 1·observed_at 2026-11-03T13:59:57+09:00·evidence_ref `acbe3ecc…`) + 전달 별도 섹션(`wuyoni-sm-g977n — FAILED, attempts 1 · 2026-11-03T14:00:07+09:00`). **Evidence** — 헤더 `검증 관련 기록 사실 — 승인 판정이 아니다 (권위: GATES P12)`·code_commit `bd283551d…`·커밋 마커 없음·CHECKSUMS 4/4 recorded==computed(input `463c93a2…`·bars `592dc337…`·events `6a51940f…`·signals `e79231df…`)·VERDICT source=verify.stdout·line=`VERDICT MATCH provenance=OK`. 전 화면 dump 원문 보존(ui-*.xml·png) |
| 관측(오프라인 프로브) | 서버 kill(재기동 인스턴스 PID 2369050, SIGTERM) → 2초 내 종료 → curl **rc=7**(원문 `Failed to connect to 127.0.0.1 port 8080 after 0 ms: Couldn't connect to server`) → 앱 화면 "오프라인 / 서버에 연결할 수 없음 (http error: Connection closed before full header was received)"·"다시 시도" 버튼 관측 → 동일 인자 재기동(PID 2884203, readiness 1초 /status 200) → 복귀. 복귀 초기 `FAIL app-recovered-screen`은 관측 설계 오류(단언이 Overview 전용 텍스트를 검색한데 반해 앱은 탭 상태를 유지해 Evidence 탭에서 복귀, `ui-app-recovered.xml` 원문에 데이터 복구 이미 관측) — FAIL 원문 보존 후 보충 관측(Overview 탭·세션 카드 복귀 실측) PASS — 기대값 조정 아님, 정직 기록 |
| 증거(보존·최종 상태) | 신규 58항목 + `CHECKSUMS-phase45.sha256`(sha256 `fad4594641976532e5c7b91e3476694eb79250603e71b1f12854b60d4275d8f2`, 58항목) — 원본 `CHECKSUMS.sha256`(sha256 `df2f26c473f3a7f491f00eff3323ce6cac9f8b5158c960dc54e45c67e83f23a1`, 75항목) 불변. 서버 최종 PID 2884203·`/status` 200·앱 프로세스 구동 유지(2026-11-05 22:37:00 관측 원문 `phase45-final-state.txt`), 관람 종료용 중지 명령 기록(`kill "$(cat runs/observe-2026-11-05-slice/serve.pid)"`·`adb reverse --remove tcp:8080`) |

한계(2026-11-05, 심야 앱 관측): google-services.json은 **재구성본 — 운영자 원본이 아니며 원본 대기 중**이다. 동등성 주장은 이번 실측 범위(빌드 게이트 통과·Firebase 초기화·FCM 토큰 획득·4화면 관측)로 한정되며, 원본이 제공되면 원본으로 교체한 뒤 재검증이 필요하다. Firebase 초기화·FCM 토큰 획득이 재구성 구성으로 실측 성공했으나 원본과의 전면 동등성(네이티브 SDK가 소비하는 전 범위)은 미검증이다. no-data·HTTP 오류 화면은 NOT-MEASURED(오프라인 프로브만 실측). Timeline 행의 session_id·data_quality는 미표출(기존 한계 유지 — Event Detail에서만 가시). P9·P11·P12는 BLOCKED 유지 — 앱 표시 관측은 승인이 아니며 smoke는 합성 재생, `VERDICT MATCH`는 재생 일치, 전달 ACCEPTED는 기기 도착이 아니다(FCM 토큰은 2026-11-03 무효화 — Overview 카드의 토큰 표시는 획득 사실의 표시이며 기기 도착을 의미하지 않는다). 본 항목의 모바일·runs 변경은 관측 산물·gitignored 배치뿐(커밋 0건·추적 파일 수정 0건)이다.

### Evidence log (2026-11-06, 오전) — google-services.json 실본 발견·교체·생성 리소스 동등성 실측(재구성 출처 한계 해소)

| gate | observed |
|---|---|
| 관측(실본 발견·출처) | 운영자 지적으로 실본 확인: `~/hongscanner-mobile-build/android/app/google-services.json`(679B, mtime 2026-11-03 11:46) — 2026-11-03 세션에서 운영자의 Firebase 인증으로 `flutterfire configure`가 실제 프로젝트 `hongscanner`(project_number `414607619695`)를 대상으로 생성했고, ASCII 경로 빌드 사본 디렉터리에 보존된 것이다. 2026-11-05 심야 관측의 서브에이전트는 저장소 내부만 탐색해 "원본 부재"로 판정·firebase_options.dart 재구성으로 게이트를 해소했으므로 그 판정 오류의 원인은 **탐색 범위**였다. 값은 실본과 전부 동일(diff 실측: 재구성 540B 대비 실본은 빈 `oauth_client: []`·`services.appinvite_service`(other_platform_oauth_client 빈) 섹션만 추가 — project_number·project_id·storage_bucket·mobilesdk_app_id·package_name·api_key[0].current_key·configuration_version 전부 일치) |
| 관측(교체·재빌드·동등성) | 실본을 `mobile/android/app/google-services.json`로 교체(gitignored — `git check-ignore -v` 동일 규칙·git status clean·커밋 0건·추적 파일 수정 0건). 재빌드 `flutter build apk --debug --dart-define=HS_API_BASE=http://127.0.0.1:8080` exit 0(2026-11-06, `✓ Built build/app/outputs/flutter-apk/app-debug.apk`), 설치 후보 APK sha256 `2877154b6ca12974ada401c3539fb68110ec0e7bff47e0dd7d466bdcf9ee563a`. **동등성 실측**: 재구성 JSON 빌드(심야 설치본, APK `f952ac8e…`)가 생성한 `mobile/build/app/generated/res/processDebugGoogleServices/values/values.xml`와 실본 JSON 재빌드 생성물의 diff → **빈 출력(바이트 동일)** — google-services Gradle 플러그인이 두 구성에서 동일한 리소스를 생성함이 실측됐다. 따라서 재구성 구성으로 수행한 심야 관측(빌드·Firebase 초기화·FCM 토큰 획득·4화면·오프라인)은 실본 구성과 동등하다. 기기는 현재 adb 미부착(3회 측정 0대) — 실본 APK의 재설치·재관측은 재연결 시 선택(동등성 실측으로 필수는 아님) |

한계(2026-11-06): 실본의 출처 근거는 2026-11-03 세션 기록(운영자 Firebase 인증 후 `flutterfire configure` 실행·성공)·파일 구조(재구성 경로에서는 생성되지 않는 `oauth_client`·`services` 섹션 포함)·값 일치이며, 파일 자체의 콘솔 대조·서명 검증은 없다(프로젝트 실측값과의 일치는 Firebase 초기화 성공·FCM 토큰 획득 실측이 간접 증거). 생성 리소스 동등성은 `processDebugGoogleServices/values/values.xml` 산출물 기준이며, 빈 섹션이 추가 리소스를 생성하지 않는다는 GoogleServicesTask.kt 구조 해석과 일치한다. 기기 미부착 상태이므로 실본 APK(`2877154b…`)의 재설치·기동 관측은 NOT-MEASURED. no-data·HTTP 오류 화면·Timeline 행 출처 표시·P9·P11·P12 한계는 기존 그대로 유지된다. 본 항목 변경은 docs/GATES.md 기록·gitignored 파일 교체·빌드 산출물뿐(추적 코드 수정 0줄).

### Evidence log (2026-11-06, 오전 재관측) — 실본 APK(`2877154b…`) 재설치·기동·4화면 관측(NOT-MEASURED 해소)

| gate | observed |
|---|---|
| 관측(재설치·기동) | 운영자가 기기 재부착(R3CM60B9AQJ, adb 실측). `adb install -r`(실본 빌드 APK, sha256 `2877154b…`) → `Success`; `adb reverse tcp:8080 tcp:8080` → `UsbFfs tcp:8080 tcp:8080`; `am start` → MainActivity 포그라운드, 앱 PID 16613. logcat: `FirebaseApp: Device unlocked: initializing all Firebase APIs for app [DEFAULT]`·`FirebaseInitProvider: FirebaseApp initialization successful`·FATAL EXCEPTION 0건(최종 상태 재측정 포함) |
| 관측(4화면) | **Overview** — 세션 1·`smoke-2026-11-05-bd28355`·session_date `2026-10-29`·started_at `2026-11-05T20:33:22+09:00`·"기록 있음"·이벤트 14·최신 SESSION_INCOMPLETE `2026-11-03T13:59:57+09:00`·FCM 토큰 카드 표시. **Timeline** — "ledger 기록 순서 (append 순서 — API가 재정렬하지 않음)" 헤더 + 이벤트 행·스크롤로 14행 확인(마지막 행 `SESSION_INCOMPLETE 2026-11-03T13:59:57 · HIGH · 전달: FAILED`). **Event Detail** — 재설치 직후 "이벤트 미선택" 정직 안내 관측(선택 상태는 앱 재설치 후 초기화) → Timeline 마지막 행 선택 시 `0f7ca29521a36725056e51ad7d60a2fa34a1f0976eaf599d172fa098744d1035` 표시·9필드 전부 ledger 원문 일치(data_quality `INCOMPLETE`·event_type `SESSION_INCOMPLETE`·evidence_ref `acbe3ecc…`·observed_at `2026-11-03T13:59:57+09:00`·rule_id `session-incomplete-v1`·rule_version `1`·session_id `2026-11-03`·severity `HIGH`) + "기록된 사실 / ledger 팩트 원문 (키 코드포인트 순)"·"전달 기록 / delivery ledger — 운영 상태 (팩트에 병합되지 않음)" 섹션 헤더. **Evidence** — "검증 관련 기록 사실 — 승인 판정이 아니다 (권위: GATES P12)" 헤더·세션 `smoke-2026-11-05-bd28355`·session_date `2026-10-29`·code_commit `bd283551d…`·run.json "기록 있음"·커밋 마커 "input.hcj.jsonl.committed · 없음"(COMMIT=ABSENT)·session_end "기록됨"·events 파일 "존재"·events sha256 `6a51940f…`·CHECKSUMS 4/4 recorded==computed(input `463c93a2…`·bars `592dc337…`·events `6a51940f…`·signals `e79231df…`)·VERDICT "VERDICT MATCH provenance=OK"(recorded 원문 인용) |
| 증거(보존·최종 상태) | `runs/observe-2026-11-06-swap/` 14항목(logcat-start.txt·ui-*.xml 7종·app-*.png 5종·final-state.txt) + `CHECKSUMS-swap.sha256`(sha256 `bb521f75ff626df7fe9201abf686985da3c0450ad143e4e0532252b96846ca44`, 14항목) — 원본 `CHECKSUMS.sha256`(75항목)·`CHECKSUMS-phase45.sha256`(58항목) 불변. 최종 상태(2026-11-06 09:54:34+0900): 앱 PID 16613·FATAL 0건·서버 PID 2884203(`/status` 200)·`UsbFfs tcp:8080 tcp:8080` 유지. 관찰 보고: post-merge attest 런(`cff0af5` push, [42138944203](https://github.com/wintrover/hongscanner/actions/runs/42138944203)) 실패는 동일 단계(`Attest the binary`)·동일 원문("Failed to persist attestation: Feature not available for user-owned private repositories…")의 알려진 플랫폼 제한 재현 — 신규 결함 아님 |

한계(2026-11-06, 재관측): 본 관측으로 직전 항목의 "실본 APK 재설치·기동 관측 NOT-MEASURED"는 해소됐다 — 실본 구성으로 빌드·설치·기동·4화면 전부 실측되었으며 심야 관측과 동일 결과다. 재관측 중 2회의 dump가 일시적으로 `com.android.systemui`(상태바/전환 과도기)를 담은 것은 관측 도구 타이밍이며 재시도로 해소됐다(원문 보존). no-data·HTTP 오류 화면·Timeline 행 출처 표시(session_id·data_quality)·P9·P11·P12·FCM 토큰 재등록(사용자 조치) 한계는 기존 그대로 유지된다. 본 항목 변경은 docs/GATES.md 기록·관측 산물뿐(추적 코드 수정 0줄 — 본 PR은 docs-only).

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

## Candidate scope (VS-2 목표 계약 — 수집기 구현, 라이브 관측 전)

"후보"의 정의를 이 계약이 선언한다. 조회·구독을 수행하는 수집기(PR #11:
sidecar + collector core)가 계약 스위트와 함께 구현·merge됐다. 단 실시장·
모의 라이브 관측은 아직 없다(PH-1 대기). Core는 계약 검증을 통과한
`rest_resp`·`sub`·`ws_raw`만 수용하고, 검증되지 않은 페이로드는 거부한다.

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
  구독 대상은 확정 후보 각 방향의 응답 순서 상위 100개다(정책
  `kiwoom_response_order_first_100_v1`, 2026-11-03 사용자 승인).
  제외 후보는 "후보 없음"이 아니라 기록된 관측 제외이며, 그 사실은
  subscription_truncated 갭과 SUBSCRIPTION_TRUNCATED 이벤트가
  담당한다. 양방향 선출 집합의 교차 중복은 여전히 거부다(fail-closed).

## PH-1 / PH-2

- **PH-1(교정)**: 실측 캡처 한 세션으로 전략 의존 구간(`warmup`,
  `lookback`)과 임계값(`pullback_min_bp`, `recovery_bp`, `rebound_min_bp`,
  `breakdown_bp`의 적용 규칙 포함)을 동결한다. 동결 전 값은 합성 픽스처
  유래이며, 교정에 쓴 세션의 신호는 검출 증거로 함께 쓸 수 없다.
- **PH-2(평가)**: 동결된 config로 PH-1과 별개 세션을 실행한다. 결과는
  `signals observed` 또는 `NO_TRIGGER_OBSERVED` 둘 중 하나다.
- 둘 다 BLOCKED(G2) — 실측 연결 경로는 2026-11-02부터 존재한다(라이브 WS
  접속·실데이터 관측·세션 -c~-e·PH-1 (2), 증거 로그)만 봉인된 실측
  세션(`session_end`+`VERDICT MATCH`)은 아직 없다.

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