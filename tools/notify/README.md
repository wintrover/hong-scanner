# VS-3 Event Ledger + Notification Dispatcher — 운영 기록 계약 (PR-5)

이 문서는 `tools/notify/`의 **커밋되는 계약**이다. Python 모듈
(`notify_ledger.py`·`notify_fcm.py`·`notify_dispatcher.py`·
`notify_register.py`·`notify_config.py`)은 이 문서의 상태·파일·오류
의미를 그대로 구현하며, 구현이 이 문서와 어긋나면 구현이 틀린 것이다.

- 상위 계약: docs/REPLAY_CONTRACT.md §13 (이벤트 계약),
  contracts/events/event.schema.json (불변 이벤트 팩트),
  contracts/events/delivery.schema.json (운영 전달 기록),
  docs/GATES.md, docs/ASSUMPTIONS.md "Vendor facts".
- 벤더 근거(2026-11-01 열람, 페이지 갱신 2026-10-28, AGENTS.md §0.3
  절차대로 공식 소스 대조): FCM 오류 코드 표
  (firebase.google.com/docs/cloud-messaging/admin/errors),
  전송·인증 가이드 (/docs/cloud-messaging/send-message,
  /docs/cloud-messaging/auth-server), FCM 서버 환경 요건
  (/docs/cloud-messaging/http-server-ref). 실 FCM 전송은 실측
  사전검증 단계 전까지 금지(개발 중 라이브 호출 금지 — collector와
  동일 규칙). §12의 UNVERIFIED 목록이 그 한계를 정직하게 적는다.

## 0. 아키텍처 (변경 불가)

```
Nim Core (src/hs/*, PR-4의 단일 판정 함수 step)
  이벤트 팩트의 유일한 판정 권위 — 이 디렉터리는 Core를 건드리지
  않는다. 전달 코드는 팩트를 필터·정렬·번역할 수 있으나 판정·승급·
  재작성은 금지 (REPLAY_CONTRACT §13.1)
        ↓ runs/<dir>/events.hcj.jsonl 등 생산자의 이벤트 파일
Python event-ledger 프로세스 (notify_ledger.py ingest)
  ledger.hcj.jsonl의 단일 작성자: 팩트를 바이트 그대로 검증·추가,
  중복 event_id는 동일 바이트만 멱등 스킵, 불일치 중복은 거부
        ↓ ledger.hcj.jsonl (읽기 전용 소비)
Python dispatcher 프로세스 (notify_dispatcher.py)
  delivery.hcj.jsonl의 단일 작성자: 정책 필터 → 중복 억제 →
  FCM HTTP v1 전송 → 전달 기록 append (append-only + fsync)
        ↓ 기기 등록 (별도 프로세스)
Python register 프로세스 (notify_register.py)
  devices.jsonl(레지스트리)의 단일 작성자: bearer 인증 등록
```

- 3상태 3보금(전달 상태는 이벤트 팩트에 절대 병합되지 않는다,
  스키마 x-separation-rule): 중요도/신뢰는 팩트의 필드, 검증은 세션
  verify 산출물, 전달(PENDING/ACCEPTED/FAILED)은 delivery 기록 —
  세 파일·세 프로세스가 그 물리적 분리다(recorder·ledger·dispatcher
  서로 다른 파일·서로 다른 프로세스).
- dispatcher는 이벤트 ledger를 **읽기 전용**으로 소비한다: 동시
  append 중인 미완료 꼬리 라인(비-LF 종단)은 "아직 커밋되지 않은
  기록"으로 건너뛴다 — 절대 반쪽만 소비하지 않는다.
- 모든 쓰기 파일에는 배타적 비블로킹 flock(`.lock`)이 있고 프로세스
  수명 동안 유지된다. 두 번째 작성자는 시작을 거부한다(단일 작성자
  강제, 조용한 병기 없음).
- append는 O_APPEND + fsync다: 프로세스 사망(전원 상실 제외) 후에도
  기록된 바이트는 남고, 재시작 복구는 그 위에서 성립한다.

## 1. 라인 규약

- 모든 ledger·registry 파일은 UTF-8, **라인당 JSON 객체 1개, LF
  종단**이며 값은 HCJ-safe(문자열·정수만)다. float은 어디에도 없다.
- 레코드는 스키마 검증 통과 직후에만 디스크에 도달한다: 잘못된 레코드는
  중단을 낳는다(fail-closed — 조용한 스킵, 부분 append 없음).
- ingest는 소스 파일 **전체를 먼저 검증**한 뒤 append한다: 무결한
  소스만 ledger에 들어오고, 불량 라인이 있는 소스는 아무 바이트도
  남기지 않는다.

## 2. 이벤트 ledger (notify_ledger.py)

- 팩트는 생산자 파일에서 **바이트 그대로** 복사된다: ledger는 팩트를
  재작성·재정렬·보강하지 않는다. 팩트 바이트의 변형은 replay
  byte-일치를 깬다(REPLAY_CONTRACT §13.4).
- 동일 `event_id` 재-ingest: **바이트가 동일하면** 멱등 스킵(재실행
  안전), **바이트가 다르면** LedgerError로 거부 — 사실은 불변이고,
  갈라진 중복은 변형 시도다.
- `check` 서브커맨드: 전 라인 스키마 검증(엄격, 비-LF 꼬리도 위반).
- 검증은 event.schema.json의 구조적 거울이다: 닫힌 필드 집합
  (additionalProperties false), 12종 event_type 열거, severity/
  data_quality/direction 열거, event_id 64-lowercase-hex,
  observed_at 캐논 타임스탬프, symbol 6자리, rule_version/rank ≥ 1.
  verification_status·전달 계열 필드는 이름으로 거부된다.

## 3. 전달 ledger (delivery.hcj.jsonl)

- delivery.schema.json의 구조적 거울 + 문서화된 상태 짝: ACCEPTED는
  `provider_message_id` 필수·`error_code` 금지, FAILED는 `error_code`
  필수·`provider_message_id` 금지, PENDING은 둘 다 금지.
- (event_id, device_id) 쌍의 상태 = 파일 순서에서 그 쌍의 **마지막
  기록**. 이전 기록은 역사로 남는다(append-only; 덮어쓰기 없음).
- `attempts`는 그 쌍의 기록된 전송 시도 수(0 = 아직 아무 것도 보냈던
  적 없음). 전송 후 기록 전 사망한 시도는 기록이 없어 attempts에
  들지 않는다 — ledger는 기록된 상태만 정직하게 센다.
- `updated_at`은 dispatcher 소유 시계(ISO 8601 숫자 오프셋 KST)다.

## 4. 기기 레지스트리 (devices.jsonl, 저장소 밖)

- FCM 등록 토큰은 자격 증명이다: 레지스트리는 **저장소 밖**에만
  존재하며, notify_config가 저장소 루트 아래로 resolve되는
  registry_path·service_account_path·register_bearer_file을 하드
  거부한다(시나리오 D가 이 가드를 실프로세스로 관측한다). 새 파일은
  0600으로 생성된다.
- 레코드 2종: `{"kind":"device","device_id","fcm_token","at"}`와
  `{"kind":"token_invalid","device_id","fcm_token_hash","at"}`.
  최신 기록이 이긴다. token_invalid는 토큰의 sha256 접두어만 담는다 —
  원시 토큰은 절대 재기록되지 않는다.
- 활성 기기 = 마지막 기록이 device인 기기(token_invalid가 뒤를 잇으면
  은퇴). dispatcher는 활성 기기에만 보내고, UNREGISTERED를 받으면 그
  토큰을 은퇴시킨다(§5).
- 등록(notify_register.py): 설정의 register_bearer_file과 `--bearer`
  (또는 $HSNOTIFY_BEARER)를 상수시간 비교(hmac.compare_digest)로
  검증한다. 불일치 시 아무 것도 기록하지 않고 토큰을 폐기한다. FCM
  토큰은 파일 또는 stdin으로만 받는다(argv 금지 — ps 노출 차단).
  device_id는 레지스트리 신원이지 FCM 토큰이 절대 아니다
  (delivery.schema.json device_id x-ref). 같은 device_id의 재등록은
  새 device 기록 append(토큰 갱신 경로, 최신이 이긴다).

## 5. 재시도 분류 (벤더 표의 코드화 — §12 UNVERIFIED 참고)

| 응답 | 분류 | 후속 |
|---|---|---|
| 200 + `{"name": "projects/..."}` | accepted | ACCEPTED 기록 (message_id = name 원문) |
| 200 + name 없음 | permanent | FAILED `HS_NO_PROVIDER_MESSAGE_ID` — 증명 불가한 성공은 성공이 아니다 |
| 429 QUOTA_EXCEEDED | retry | PENDING 기록, 대기 ≥ max(retry_min_seconds, Retry-After) — 벤더 최초 지연 최소 1분이 라이브 기본값 |
| 503 UNAVAILABLE / 500 INTERNAL | retry | PENDING 기록, Retry-After 존중 (Retry-After 헤더가 있으면 그 값) |
| 전송 실패(응답 자체가 없음) | retry | PENDING 기록 `HS_TRANSPORT` |
| 404 UNREGISTERED | terminal | FAILED 기록 + 레지스트리 token_invalid(해시만) — 벤더 지시: 토큰을 제거하고 전송을 멈춘다 |
| 403 SENDER_ID_MISMATCH | terminal | FAILED 기록 + stderr 명시 오류 + **exit 3** — 설정 오류는 fail-closed, 재시도 없음, 나머지 기기는 계속 서빙 |
| 그 외 전부 (400, 401, 418, …) | permanent | FAILED, 오류 코드 **원문 보존** (집합은 열려 있고, 알 수 없는 코드는 성공·재시도로 지도되지 않는다) |
| 페이로드 > 4096바이트 | permanent | 전송 전 거부, FAILED `HS_PAYLOAD_OVER_LIMIT` |

- `HS_` 접두사는 스캐너 합성 코드다(전송 전 거부·전송 불능). 그 외
  error_code는 벤더 응답의 `error.status` 원문이며, 없으면
  `HTTP_<status>`다.
- 백오프 대기가 backoff_cap_seconds를 넘으면 그 쌍은 **보류(PENDING)
  로 남고** 스위프는 끝난다(외부 스케줄러가 재개). 영구 실패로
  포장되지 않는다.
- in-sweep 재시도: 스위프는 due가 없어도 보류 쌍이 남아 있으면
  (cap 이내의) 다음 due까지 대기 후 재시도한다.

## 6. FCM 메시지와 정직성

- 공식 경로인 **notification+data 메시지**만 보낸다(데이터 전용+로컬
  표시는 비공식 패턴으로 금지):
  `POST https://fcm.googleapis.com/v1/projects/<project>/messages:send`,
  본문 `{"message": {"token", "notification": {"title","body"},
  "data": {"event_id","event_type","severity"}}}`. title =
  `"Hong Scanner <severity>"`, body = `<event_type>[ <symbol>]` —
  최소 문구, id는 data로. data 값은 전부 문자열(공식 요건).
- 페이로드 한도 4096바이트(키·값 포함, 벤더 명시)를 전송 전 검사한다.
- **accepted ≠ delivered**: HTTP 200은 FCM의 접수 증명일 뿐이다.
  도착 시각·순서·기기 표시·열람은 어떤 보장도 없고(REPLAY_CONTRACT
  §13.5) 어떤 기록에도 도착으로 쓰지 않는다.
- **전송 도중 사망의 정직한 중복**: dispatcher가 전송(또는 전송 중)에
  죽으면 전달 기록이 없으므로 재시작 후 그 쌍은 재전송된다 — 기기가
  같은 알림을 두 번 받을 수 있다. 이것은 FCM 현실이며 숨기지 않고
  기록한다; 앱 측 event_id 중복 식별이 전제다(드릴 시나리오 B).
- **중복 억제**: ACCEPTED인 쌍은 정책·기기가 같아도 절대 재전송하지
  않는다(드릴 시나리오 A). FAILED는 단말이다(재시도 금지).

## 7. 설정 (저장소 밖, --config 또는 $HSNOTIFY_CONFIG)

```json
{
  "project_id": "<firebase project>",
  "ledger_path":    "/abs/ledger.hcj.jsonl",
  "delivery_path":  "/abs/delivery.hcj.jsonl",
  "registry_path":  "/abs/outside-repo/devices.jsonl",
  "register_bearer_file": "/abs/outside-repo/bearer.secret",
  "min_severity": "INFO",            // INFO(전부, 기본) | HIGH | CRITICAL
  "retry_min_seconds": 60,           // 라이브 기본 = 벤더 최소 1분
  "backoff_cap_seconds": 900,
  "service_account_path": "/abs/outside-repo/sa.json",  // 또는 아래
  "token_command": ["gcloud", "auth", "application-default",
                    "print-access-token"]
}
```

- dispatch는 두 자격 경로 중 **정확히 하나**를 요구한다:
  서비스 계정 JSON(저장소 밖 경로에서 로드, RS256 JWT 교환) 또는
  token_command(플랫폼 위임 — 공식 클라이언트가 자기 네이티브
  저장소를 다룬다, collector의 kiwoomcli 선례). 토큰 만료 60초 전에
  재발급한다.
- 정책(min_severity)에 못 미치는 이벤트는 **전달 기록을 만들지
  않는다** — 정책은 전송 계층의 결정이지 사실의 변경이 아니다. 기록
  없는 스킵은 가짜 PENDING을 만들지 않는다.
- 엔드포인트 오버라이드는 존재하지 않는다: FCM/OAuth URL은 공식
  값으로 고정(fail-closed, collector의 도메인 고정 선례).

## 8. 자격 증명과 마스킹

- 토큰 값(FCM 등록 토큰, OAuth 액세스 토큰, bearer 시크릿)은 프로세스
  메모리와 저장소 밖 파일에서만 존재한다. 로그·stdout·delivery
  기록·ledger·이벤트 팩트 어디에도 쓰이지 않는다 — 필요한 곳엔
  `sha256:` 접두어 마스크만 간다.
- RS256 구현은 순수 표준 라이브러리다(RFC 8017 RSASSA-PKCS1-v1_5
  over SHA-256, PKCS#8/PKCS#1 PEM 파서 포함). 외부 crypto 의존성은
  추가하지 않는다(collector 의존성 규율: 새 pip 의존성 금지). 정확성은
  RFC 7515 A.2 **공식 벡터**로 게이트에서 핀된다(그 JWK는 RFC가
  공개·폐기 선언한 테스트 전용 키이며 자격 증명이 아니다).

## 9. exit 코드 (이 문서가 정의한다)

| 코드 | 의미 |
|---|---|
| 0 | 스위프 정상 완료 (보류 PENDING·외부 재개 포함 — 정상이 보류를 숨기지 않는다: 요약 라인이 세어 보인다) |
| 2 | 사용법·설정 계약 위반 (설정 거부, bearer 거부, 잘못된 device_id) |
| 3 | 자격 경로 실패 또는 fail-closed SENDER_ID_MISMATCH — 설정 오류는 절대 깨끗한 성공이 아니다 |
| 4 | 단일 작성자 충돌(다른 프로세스가 lock 보유) / 내부 결함 / ledger 계약 위반 |

- 실패를 성공으로 꾸미는 경로는 존재하지 않는다. dispatcher의 스위프
  요약(`sweep {...}` JSON 라인)은 세친 사실만 보고한다.

## 10. 드릴과 테스트 (모두 합성 — 네트워크 0, 실자격 0)

- `bash tools/notify/test_notify.sh`: unittest 계약 스위트. 실제
  모듈을 가짜 urllib 전송과 temp ledger로 in-process 구동. RFC 7515
  A.2 벡터(서명·키 파싱·JWT 형상), 스키마 검증 전표, ledger 멱등·
  거부 규칙, dispatcher 상태기계 전체(정상·중복 억제·429/404/403·
  영구·전송 실패·기록 소실 복구·정책 필터·ledger 순서 소비).
- `bash tools/notify/drill/drill_fcm.sh`: 프로세스쌍 드릴(collector의
  drill_pair 패턴 재사용). REAL CLI들을 별도 OS 프로세스로,
  `fakesite/sitecustomize.py`가 HSDRILL=1일 때만 urllib.urlopen을
  가짜 FCM 백엔드로 패치(공식 URL·bearer 강제, device별 응답
  스크립트, SEND 마커 후 지연 삽입으로 SIGKILL 창 결정화,
  wirelog는 토큰 해시만). 시나리오:
  - **A** 정상 전달(ingest→register→dispatch→ACCEPTED) + 두 번째
    dispatch 0 재전송(ACCEPTED 중복 억제) + ledger 바이트 불변;
  - **B** SEND 마커 관측 후 SIGKILL → 전달 기록 부재 확인 → 재시작
    재전송 → ACCEPTED (솔직한 중복의 와이어 증거: 동일 쌍 SEND 2회);
  - **C** 429(Retry-After 존중, 와이어 타임스탬프 간격 ≥1s, PENDING
    →ACCEPTED attempts 1→2) / 404(FAILED UNREGISTERED + 레지스트리
    token_invalid 해시만, 재실행 무전송) / 403(FAILED
    SENDER_ID_MISMATCH + exit 3, 타 기기 계속 서빙) + 재실행 0 전송;
  - **D** 저장소 안 registry_path 거부(exit 2), 잘못된 bearer 등록 0건.
  증거는 `runs/drill-fcm-<ts>/`(gitignored): wire 로그, dispatcher
  stdout/stderr, delivery·이벤트 ledger, 레지스트리 **마스크드**
  프로젝션. 드릴은 증거 트리에 자격증명 값이 하나라도 나오면 실패한다.
  wall-clock 제약 없음(watchdog 없음).

## 11. 빌드·게이트 통합

- Python 3.13 표준 라이브러리만(의존성 추가 없음, venv 불필요).
  인터프리터 해석 순서는 collector 스위트와 같다:
  `$HSCOLLECTOR_PYTHON` → `python3.13` → `uv python find 3.13`.
- 게이트: `bash tools/run_tests.sh` exit 0 + `ALL CONTRACT SUITES
  PASSED`. 등록 라인: `run bash tools/notify/test_notify.sh`와
  `run bash tools/notify/drill/drill_fcm.sh`.
- 실행(live, 별도 사전검증 단계에서만): dispatcher를 systemd
  timer 등 외부 스케줄러로 주기 기동하는 것을 전제로 설계했다
  (보류 PENDING은 스위프가 끝내지 않고 남긴다 — 미전달은 서버에
  잔존한다, 설계 원칙 ⑤).

## 12. UNVERIFIED·사전 검증 목록 (merge 후 실측 항목)

- 실 FCM 실측 전체: 실 프로젝트에서의 429 Retry-After 실측 값,
  404/403 실측 본문 형상(오류 표는 2026-10-28 갱신본과 대조됐으나
  실측은 별도다), message_id 실측 형상, 실 토큰 수명.
- OAuth 실측: 서비스 계정 JWT 교환의 실측 응답(expires_in 형상),
  token_command 경로의 실제 gcloud 출력 형상.
- 앱 측 전제(앱의 event_id 중복 식별)는 PR-7의 구현·실측 대상이다 —
  이 계약은 그 전제를 문서로 요구할 뿐 증명하지 않는다.
- accepted≠delivered의 실측 경계(접수 후 유실 가능성)는 벤더 문서가
  보장하지 않는 영역이며, 관측 수단은 이 슬라이스에 없다.
