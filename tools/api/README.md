# VS-3 Read-only API — 기록 사실 투영 계약 (PR-6)

이 문서는 `tools/api/`의 **커밋되는 계약**이다. Python 서버
(`serve.py`)는 이 문서의 엔드포인트·응답·경계 의미를 그대로 구현하며,
구현이 이 문서와 어긋나면 구현이 틀린 것이다.

- 상위 계약: docs/REPLAY_CONTRACT.md §13 (이벤트 계약·결정론 경계),
  contracts/events/event.schema.json (불변 이벤트 팩트),
  contracts/events/delivery.schema.json (운영 전달 기록),
  tools/notify/README.md (ledger·delivery 파일 규약), docs/GATES.md.
- 설계 원칙 §13.7의 "사실은 서버 소유 · 모바일은 읽기 전용 · 불확실성을
  숨기지 않음"이 이 디렉터리의 존재 이유다.

## 0. 아키텍처와 경계 (변경 불가)

```
run 디렉터리들 (runs/<dir>/, recorder·verify가 쓴 기록)
  run.json · input/bars/signals/events.hcj.jsonl · CHECKSUMS.sha256
  input.hcj.jsonl.committed · (운영자가 남긴) verify.stdout
event ledger (--ledger, notify_ledger가 단일 작성자)
  ledger.hcj.jsonl — 이벤트 팩트, append-only
delivery ledger (--delivery, dispatcher가 단일 작성자)
  delivery.hcj.jsonl — (event_id, device_id) 전달 상태, append-only
        ↓ 읽기 전용 투영 (이 디렉터리, 유일한 역할)
HTTP 서버 (serve.py, 기본 127.0.0.1 바인드, GET 전용)
```

- 이 API는 **기록된 사실의 읽기 전용 투영**이다. 판정하지 않고,
  재생하지 않고, 어떤 값을 새로 계산해 사실로 만들지 않는다. 응답은
  (1) 기록된 레코드의 투영과 (2) 계약이 명시한 저렴한 재도출 —
  CHECKSUMS.sha256 대조용 sha256 재계산, 마커·기록 존재 확인 — 만
  담는다.
- **Nim verify 바이너리 실행은 이 API 프로세스의 범위 밖이다.** API는
  replay·verify를 실행하지 않으며, `VERDICT` 판정은 운영자가 런
  디렉터리에 남긴 기록 파일(`verify.stdout`)을 **원문 그대로 인용**할
  뿐이다. 기록이 없으면 "기록 안 됨"으로 응답한다 — 위조·추정은
  없다(REPLAY_CONTRACT §0.2: 실패·미확정을 성공·확정으로 표현하지
  않는다).
- 이 프로세스는 어떤 파일의 단일 작성자도 아니다: 아무 것도 쓰지
  않는다. ledger·delivery는 읽기 전용으로 소비하며, notify와 동일한
  읽기 규약을 따른다 — 미완료(비-LF 종단) 꼬리 라인은 "아직 커밋되지
  않은 기록"으로 건너뛴다. 반대로 **커밋된 라인이 불량이면
  fail-closed**로 해당 엔드포인트가 HTTP 500을 낸다(조용한 스킵으로
  오염을 숨기지 않는다).
- 구동은 명시적 시작뿐이다: 데몬화·systemd·자동 기동·상주 감시는 범위
  밖이다.

## 1. 구동

```sh
python3.13 tools/api/serve.py \
  --runs  /abs/runs \
  --ledger /abs/ledger.hcj.jsonl \
  --delivery /abs/delivery.hcj.jsonl   # 선택
  --port 8080                          # 0 = 임시 포트
  --bind 127.0.0.1                     # 선택, 기본 127.0.0.1
```

- 바인딩 기본값은 **127.0.0.1**이며 옵션 없이 붙는다. `--bind <IPv4>`는
  기본값을 바꾸는 유일한 창구다. 허용 값은 구체적 IPv4 유니캐스트
  주소(루프백·사설·링크로컬 포함)와 **0.0.0.0**뿐이다. 멀티캐스트
  (224.0.0.0/4), 브로드캐스트 255.255.255.255, 예약 블록
  (240.0.0.0/4, 0.0.0.0/8의 나머지), IPv4 형식 밖의 모든 문자열은
  **소켓이 생기기 전 사용법 오류(exit 2)**로 거부된다. 형식이 맞는
  주소를 OS가 열지 못하면 기존 바인드 실패 경로(exit 4)다.
- **기본 호출의 동작은 완전히 불변이다**: `--bind`를 주지 않으면
  바인드 주소·SERVE 줄·종료 코드가 옵션 도입 이전과 다르지 않다.
- **`--bind 0.0.0.0`은 Northflank ingress 뒤 컨테이너 전용이다.**
  0.0.0.0은 접근 통제가 아니다: 이 API에는 인증이 없고, 0.0.0.0
  바인드의 접근 통제는 플랫폼(Northflank ingress Basic Auth)에
  위임된다. 플랫폼 ingress 뒤가 아닌 0.0.0.0(또는 그 외 비루프백
  인터페이스 주소)의 인터넷 직접 노출은 이 계약 위반이다. 로컬
  운영은 기본값을 쓴다(옵션 없음 = 루프백만).
- 기동에 성공하면 stdout에 한 줄 `SERVE <바인드주소>:<port>`를 찍고
  flush한다 — 주소는 OS가 확인한 실제 바인딩이다. 스크립트는 이 줄로
  실제 주소와 포트를 읽는다.
- 종료는 SIGTERM/SIGINT로 한다: 서버가 조용히 드레인하고 exit 0으로
  끝난다. 기동 실패는 exit 코드로 끝난다: 2 = 사용법·설정 위반
  (존재하지 않는 --runs, 포트 범위 위반, --bind 거부), 4 = 바인드
  실패. 실패를 exit 0으로 꾸미는 경로는 없다.
- 데이터는 요청마다 파일에서 다시 읽는다: 상태 캐시가 없고, 서버
  재시작 없이 ledger·런 디렉터리의 갱신이 응답에 반영된다.

## 2. JSON 규약

- 모든 응답 본문(성공·오류 모두)은 **canonical JSON**이다: UTF-8,
  compact 구분자, **키 코드포인트 오름차순 정렬**(HCJ canonical과 같은
  규율), 끝에 LF 1개. float은 어디에도 없다(문자열·정수·불리언·null·
  배열·객체만).
- `Content-Type: application/json; charset=utf-8`, GET 전용, HTTP/1.1,
  응답마다 연결을 닫는다.
- **null의 의미**: 값이 아니라 "기록 부재"다. 0과 다르다. 예: ledger
  파일이 아직 없을 때 `/status`의 `events.count`는 0이 아니라 null이다.
- 이벤트 배열의 순서는 **ledger 파일 순서**(단일 작성자 append 순서)다.
  API가 재정렬하지 않는다. 세션 목록은 런 디렉터리 이름 코드포인트
  오름차순이다.
- 오류 본문: `{"error": {"code", "message"}}`. message는 요청 값을
  재출력하지 않고, 파일 이름만 담는다(절대 경로 비노출).

## 3. 엔드포인트 (전부 GET, 쓰기 경로 전무)

식별자 두 가지를 구분한다:

| 이름 | 뜻 | 예 |
|---|---|---|
| `session` | **런 디렉터리 이름**(파일시스템의 기록 단위) | `smoke-2026-11-02-885b009` |
| `session_id` | 레코드 안 세션 스킴 id (VS-1에서 session_date) | `2026-10-29` |

이벤트 계열 엔드포인트(`/candidates`, `/events`)의 권위는 **event
ledger**다. 런 디렉터리의 `events.hcj.jsonl`은 검증 엔드포인트에서
해시 대상 아티팩트로만 다룬다.

### 3.1 `GET /status` — 최신 세션·이벤트·전달 요약

```json
{
  "delivery": {"by_state": {"ACCEPTED": 1, "FAILED": 1, "PENDING": 1},
               "configured": true, "devices": 2, "pairs": 3, "present": true},
  "events": {"by_severity": {"HIGH": 1, "INFO": 3},
             "by_type": {"CANDIDATE_ENTERED": 2, "CANDIDATE_EXITED": 1,
                         "SESSION_ENDED": 1},
             "count": 4,
             "latest_event": {"event_id": "e4…", "event_type":
                              "CANDIDATE_EXITED", "observed_at": "…"},
             "latest_session_id": "2026-10-30",
             "ledger_present": true},
  "sessions": {"count": 4,
               "latest": {"code_commit": "885b…", "run_id": "…",
                          "run_json_present": true, "session": "run-…",
                          "session_date": "2026-10-31", "started_at": "…"}}
}
```

- `delivery.by_state`는 (event_id, device_id) 쌍의 **마지막 기록**
  상태의 합계다(delivery ledger 문서와 같은 last-record-wins 규칙).
  `configured`는 `--delivery` 지정 여부, `present`는 파일 존재다.
- `events.latest_*`는 ledger 파일 순서의 마지막 이벤트에서 온다.

### 3.2 `GET /candidates` — 최신 세션의 CANDIDATE_* 이벤트

"최신 세션"은 **ledger 마지막 이벤트의 session_id**다. 응답은 그
session_id의 `CANDIDATE_ENTERED|UPDATED|EXITED` 팩트만 담는다:

```json
{"count": 2, "events": [ {…팩트 원문 필드…}, … ],
 "ledger_present": true, "session_id": "2026-10-30"}
```

### 3.3 `GET /events[?session_id=<id>]` — 이벤트 기록 + 전달 상태

```json
{"count": 4,
 "delivery": {"<event_id>": [{"attempts": 1, "device_id": "dev-1",
                              "provider_message_id": "projects/…/m-1",
                              "state": "ACCEPTED", "updated_at": "…"}]},
 "events": [ {…팩트 원문(레코드 그대로, 키만 정렬)…}, … ],
 "ledger_present": true}
```

- 팩트와 전달 기록은 **두 개의 키로 분리**되어 들어간다 — 3상태 3보금
  (REPLAY_CONTRACT §13.6)을 응답 모양에서도 유지한다. API는 팩트에
  전달 상태를 절대 병합하지 않는다.
- `delivery` 맵은 **응답의 events에 대응하는 event_id**만 담고, 각
  값은 device_id 오름차순의 마지막 기록들이다. 전달 기록이 없는
  이벤트는 맵에 키가 없다("전달 없음"은 빈 배열이 아니라 키 부재로
  표현된다).
- `?session_id=`는 정확-일치 필터다(선택). 값이 URL 디코딩된 뒤
  문자열 비교에만 쓰인다 — 파일시스템 접촉이 없어 경로 위험이 없다.

### 3.4 `GET /events/{event_id}` — 이벤트 1건 + 전달 기록

`{event_id}`는 64자 소문자 hex여야 한다. ledger에 없으면 404다.

```json
{"delivery": [ {…마지막 기록(필드 원문, event_id 제외)…} ],
 "event": {…팩트 원문…}}
```

전달 기록이 전무하면 `delivery`는 빈 배열이다(기록 부재의 정직한
표현).

### 3.5 `GET /sessions` — 런 디렉터리 목록

runs 루트의 **디렉터리만**, 이름 오름차순으로:

```json
{"count": 4,
 "sessions": [{"code_commit": null, "run_id": null,
               "run_json_present": false, "session": "dir-…",
               "session_date": null, "started_at": null}, …]}
```

- `run.json`이 있는 런은 화이트리스트 필드만 투영한다:
  `session_date`·`run_id`·`started_at`·`code_commit`. 나머지 기록
  필드(`host`, `pid`, `egress_ip`, `build`, 해시들…)는 **의도적으로
  비투영**이다 — 소비자가 필요로 하는 최소만 서빙한다. 값이
  문자열이 아니면 null로 서빙한다(채우지 않는다).

### 3.6 `GET /sessions/{session}/verification` — 검증 상태의 솔직 경계

기록된 사실과 저렴한 재도출만 서빙한다:

```json
{
  "code_commit": "885b…",
  "committed_marker": {"file": "input.hcj.jsonl.committed", "present": true},
  "checksums": {"artifacts": [
      {"computed_sha256": "aa…", "file": "input.hcj.jsonl",
       "match": true, "recorded_sha256": "aa…"},
      … ],
    "present": true},
  "events_file": {"present": true, "sha256": "6a…"},
  "replay_verdict": {"recorded": false},
  "run_json_present": true,
  "session": "smoke-2026-11-02-885b009",
  "session_date": "2026-10-29",
  "session_end_recorded": true
}
```

| 필드 | 원천 | 성격 |
|---|---|---|
| `session_date`·`code_commit` | run.json (화이트리스트) | 기록 |
| `committed_marker.present` | `input.hcj.jsonl.committed` 파일 존재 | 기록 |
| `session_end_recorded` | input.hcj.jsonl 안 `kind=session_end` 레코드 존재 | 기록(꼬리 미완료 라인 제외) |
| `checksums` | CHECKSUMS.sha256의 기록 해시 **vs** 각 아티팩트의 sha256 재계산 | 기록 + 계약이 허용한 유일한 재도출 |
| `events_file.sha256` | events.hcj.jsonl 바이트의 sha256 | 저렴한 재도출 |
| `replay_verdict` | 운영자가 남긴 `verify.stdout`의 첫 `VERDICT` 줄 **원문 인용** | 기록 인용 — API가 만든 판정이 아니다 |

- **replay verdict가 기록에 없으면** `{"recorded": false}`로
  응답한다. 파일이 있어도 `VERDICT` 줄이 없으면
  `{"recorded": false, "note": "verify.stdout present but no VERDICT
  line recorded"}`다. 추정·재실행·성공 가정은 없다 — §0.2 fail-closed.
- `checksums.artifacts[].match`는 재계산 해시와 기록 해시의 byte
  일치다. 파일이 없으면 `computed_sha256` null·`match` false다.
  CHECKSUMS.sha256 자체가 없으면 `{"present": false, "artifacts": []}`다.
  **기록된 아티팩트 이름은 신뢰 입력이 아니다**: 안전한 단일 경로
  구성요소가 아닌 이름은 열지 않고 `match: false` + note로 거부한다
  (CHECKSUMS가 `../../secrets`를 가리켜도 열리지 않는다).
- 이 엔드포인트는 세션의 "승인"이나 데이터 완전성을 판정하지 않는다.
  승인 권위는 GATES P12다. 응답은 세션이 지금 기록에 갖고 있는 검증
  관련 사실의 목록일 뿐이다.

## 4. 오류 응답 (fail-closed)

| 상황 | 응답 |
|---|---|
| 미지 경로·미지 이벤트 id·미지 세션·경로 순회 시도 | 404 `not_found` (요청 값 재출력 없음) |
| GET 이외의 메서드 (POST/PUT/DELETE/PATCH/HEAD/OPTIONS) | 405 `method_not_allowed`, `Allow: GET` |
| 기록 파일 불량(커밋된 라인이 불량 JSON·불량 체크섬 줄 등) | 500 `data_fault` — 조용한 스킵 없음 |
| http.server 내부 오류(불량 요청 줄 등) | JSON 본문 (HTML 없음) |

## 5. 보안 경계

1. **바인딩**: 기본 127.0.0.1(옵션 없음 = 루프백만). `--bind`는 IPv4
   유니캐스트와 0.0.0.0만 수용하고 멀티캐스트·브로드캐스트·예약
   블록·비IPv4 문자열은 사용법 오류(exit 2)로 거부한다. `0.0.0.0`은
   Northflank ingress 뒤 컨테이너 전용이며 접근 통제는 플랫폼 Basic
   Auth에 위임한다 — 직접 공개 금지. 이 API 자체는 인증을 갖지
   않는다.
2. **GET 전용**: 쓰기 경로·POST·PUT·DELETE·PATCH·HEAD·OPTIONS는 전부
   405다. 쓰기 엔드포인트는 존재하지 않는다.
3. **식별자 검증**: `{event_id}`는 `^[0-9a-f]{64}$`, `{session}`은
   `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` + `..`·구분자 명시 거부 +
   **실제 런 디렉터리 이름과의 정확-일치** + realpath 격납 검사.
   `%2e%2e` 같은 인코딩 우회는 디코딩 뒤 같은 검증에 걸린다.
4. **파일시스템 비노출**: 응답에 절대 경로가 없다. 파일시스템에서
   노출되는 것은 런 **디렉터리 이름**뿐이다. 오류 메시지도 파일
   basename만 담는다.
5. **비밀 비서빙**: 응답은 기록 화이트리스트에서만 온다. run.json의
   `host`·`pid`·`egress_ip` 등은 투영하지 않고, ledger·delivery는
   스키마가 닫혀 있어(추가 속성 거부) 자격증명 필드가 애초 기록되지
   않는다. 기기 레지스트리(FCM 토큰 보관)는 애초에 API 원천이
   아니다 — 저장소 밖 파일이며 `--delivery`와 다른 파일이다.
6. **기록 입력 무신뢰**: CHECKSUMS.sha256의 아티팩트 이름은 안전
   패턴 밖이면 열지 않는다.

## 6. 테스트·게이트

- `bash tools/api/test_api.sh`: unittest 계약 스위트. mktemp 샌드박스에
  합성 런 디렉터리·ledger·delivery를 만들고, 실제 서버를 127.0.0.1
  **임시 포트(port 0)**로 띄워 엔드포인트별 상태코드·본문 바이트를
  단언한다. 네트워크는 루프백뿐, 실데이터·실자격 0. 서버는 스위트가
  SIGTERM으로 종료·회수하며 잔류 프로세스 0을 단언한다. 커버 시나리오:
  엔드포인트 전부, canonical 바이트 일치, last-record-wins 전달 상태,
  체크섬 불일치·부재, 기록된 VERDICT 인용 vs "기록 안 됨", torn-tail
  ledger(미커밋 꼬리 스킵), 경로 순회·인코딩 우회 404, 메서드 405,
  비밀·은닉 필드 비노출, 기동 fail-closed(미지 --runs·포트 범위·미지
  옵션), SIGTERM 종료 코드 0, --bind 계약(127.0.0.2 기동 시 SERVE 줄과
  리스너 단언, 0.0.0.0 인자 검증 수용, 멀티캐스트·브로드캐스트·예약
  블록·비IPv4 문자열의 exit 2 거부).
- 인터프리터 해석 순서는 collector·notify 스위트와 같다:
  `$HSCOLLECTOR_PYTHON` → `python3.13` → `uv python find 3.13`.
- 게이트: `bash tools/run_tests.sh`에 등록된 스위트(`run bash
  tools/api/test_api.sh`)의 exit 0. 단독 통과는 게이트가 아니다.

## 7. 범위 밖

- 인증·TLS·WireGuard 앞단 — 별도 계획 없이는 없다(기준안 §8). 원격
  노출은 이 API 프로세스의 기능이 아니라 플랫폼 ingress(§1)의
  역할이며, 그 계약 없는 직접 노출은 금지다.
- 페이지네이션·정렬 옵션·커서 — 개인용 규모에서 요청 시 재검토.
- 캐시·ETag·압축 — 없다(기록 재독이 권위다).
- 데몬화·systemd·자동 기동·헬스체크 인프라 — 명시적 시작만 계약이다.
- 판정·replay·verify 실행 — 이 프로세스의 역할이 영원히 아니다.
