# VS-2 라이브 수집기 — 파이프 프로토콜 계약 (PR-2)

이 문서는 수집기의 **커밋되는 계약**이다. Python sidecar(`sidecar.py`)와 Nim
collector-core(`src/hs/collector.nim`)는 이 문서의 필드·순서·오류 의미를 그대로
구현하며, 어느 한쪽 구현이 이 문서와 어긋나면 구현이 틀린 것이다.

- 상위 계약: docs/REPLAY_CONTRACT.md §12 (기록·재생·검증), docs/GATES.md,
  docs/ASSUMPTIONS.md "Vendor facts".
- 이 계약의 근거가 되는 공식 문서 검증: 키움 공식 스펙 JSON
  (`Kiwoom-Securities/Kiwoom-REST-API`, main, `kiwoom/_data/kiwoom_api_spec.json`,
  2026-10-30 raw fetch — 저장소 반입 금지, 읽기 전용)과 검증 보고서
  (V1 REG/REMOVE, V2 PING, V3 모의투자 엔드포인트, V4 fsync/마커, 유량 #49,
  FID 215, OAuth 토큰, WS 한도, 키움 스펙/FID, websockets 17.3, D-Bus/Secret
  Service).

## 0. 아키텍처 (변경 불가 — 보완항 ⑤)

```
Python sidecar (tools/collector/sidecar.py, Python 3.13 격리 venv)
  통신 전용 — 해석·기록·판정 권한 없음:
    REST ka10027 (원문 body bytes), WS 단일 영속 연결(demo),
    recv(decode=False) 원문 bytes, PING 최소 판별 후 원문 echo,
    클라이언트발 프로토콜 ping 차단(ping_interval=None),
    타이머 소유(재조회 300s·watchdog 15:40·drain 10s·quiet 10s),
    bounded 큐 백프레셔(조용한 버림 없음)
        ↓ stdin/stdout 라인 JSON 파이프 (이 문서 §2·§3)
Nim collector-core (src/hs/collector.nim + tools/collector/collector.nim)
  단일 작성자·판정 권위:
    Recorder 소유(seq 발급, input.hcj.jsonl + 60초 syncNow),
    vendor_input으로 원문 REST bytes에서 후보 도출 → 세대 스왑 지시,
    sub_input composeRegData/composeMarketStateReg/composeRemoveData 사용,
    0B/0s 파서(src/hs/tickwire.nim, 단일 파서),
    소비 검사 3종(src/hs/subcheck.nim), GAP 분류, 종료 프로토콜
```

- sidecar는 시장 데이터를 **해석하지 않는다**: 채널 판별(REG/REAL/0B/0s/…), 
  REG/REMOVE ack 짝짓기, 후보 도출, 종료 판정은 전부 Nim core가 한다.
- sidecar가 예외적으로 판별하는 것은 통신 계층의 세 가지뿐이다(§4): 
  Kiwoom PING(echo), LOGIN(접속 인증 수명), 그리고 토큰 만료(갱신).
- core는 시계가 없다: 기록되는 모든 `t`는 sidecar가 이벤트에 찍은 시각이거나,
  recorder의 COMMITTED 마커 `t`(recorder.nim이 문서화한 어댑터 경계 시계)다.

## 1. 라인 규약

- 파이프는 양방향 stdin/stdout, UTF-8, **라인당 JSON 객체 1개, LF 종단**.
- 각 라인은 HCJ 도메인을 따른다(정수만, float 금지, 키 `[A-Za-z0-9_-]`).
  sidecar→core 이벤트는 core가 HCJ 파서로 검증하며, HCJ 위반 라인은
  core를 비정상 종료시킨다(fail-closed).
- core→sidecar 명령은 sidecar가 표준 JSON으로 파싱한다. 알 수 없는 `type`은
  sidecar를 `{"ev":"error","what":"internal",...}` 후 비정상 종료( exit 4)로
  이끈다 — 무시하지 않는다.
- core는 sidecar의 stdout을 라인 단위로 차단 읽는다(이벤트 구동). sidecar의
  stdin 쓰기가 막히면 역압은 recv 루프까지 전파된다(TCP 읽기 정지, 유실 없음).

## 2. core → sidecar 명령

모든 명령은 `"type"` 필드를 가진다. 필드 순서는 무의미하나, 나열된 필드는
필수이며 타입이 정확해야 한다.

### 2.1 `init` — 세션 초기화 (연결 전 1회)

```json
{"type":"init","protocol":1,"environment":"demo",
 "rest_domain":"https://mockapi.kiwoom.com",
 "ws_endpoint":"wss://mockapi.kiwoom.com:10000",
 "api_id":"ka10027",
 "rest_params":{"mrkt_tp":"000","trde_qty_cnd":"0000","stk_cnd":"0",
   "crd_cnd":"0","updown_incls":"1","pric_cnd":"0","trde_prica_cnd":"0",
   "stex_tp":"1"},
 "page_cap":10,"repoll_seconds":300,"drain_seconds":10,
 "ack_timeout_seconds":10,"watchdog":"15:40:00+09:00","profile":"<alias>"}
```

- `environment`는 이 슬라이스에서 `"demo"`만 허용된다(PH-1). sidecar도
  이중 검사한다. demo 엔드포인트는 공식 스펙의 모의투자 도메인 원문
  (`wss://mockapi.kiwoom.com:10000`, `https://mockapi.kiwoom.com`)과 일치해야
  한다 — 일치하지 않으면 sidecar는 시작을 거부한다.
- `rest_params`는 ka10027 9필드 중 `sort_tp`를 제외한 8필드(방향별로
  core가 `sort_tp` 1/3을 붙여 요청한다). 값 도메인은 vendor_input.nim의
  공식 enum 검증을 통과해야 한다.
- `page_cap`=10(공식 예제 MAX_PAGES), `repoll_seconds`=300(§5 승인값),
  `drain_seconds`=10(§5), `ack_timeout_seconds`=10(승인된 drain 값과 같은
  "프로토콜 1단계 정적 한계"로 선언, §5 표에 명시된 값에서 유도 —
  config 레코드에 그 사실과 함께 기록), `watchdog`=15:40 KST(스캐너 시계,
  마감 권위 아님).
- sidecar는 토큰을 여기서 확보한다(§5). 성공 시 `ready`, 실패 시
  `error(what=token)` 후 exit 3.

### 2.2 `connect` — WS 접속 + LOGIN

- sidecar는 `wss` 접속 → `{"trnm":"LOGIN","token":<access_token>}` 송신 →
  LOGIN ack 대기. ack `return_code`는 공식 스키마가 String으로, 예제는
  숫자로 서로 달라, 공식 SDK의 정규화 규칙(`kiwoom/core/errors.py`
  `normalize_return_code`: 정수 또는 "0"·"0000"·"8005"형 숫자 문자열)을
  그대로 따른다(정수도 문자열도 아닌 값은 fail-closed). auth
  계열({8005,8031,8103} 또는 HTTP/WS 401 계열, 또는 return_msg 안
  `[NNNN:...]`/`CODE=NNNN` 임베드 — SDK `_EMBEDDED_CODE_RE`)이면 토큰
  재발급 후 **1회** 재시도. 그래도 실패하면 `conn closed_error` 보고.
- 성공 시 `conn state=open` 이벤트(§3.1). 재접속은 sidecar가 자동 수행한다:
  접속이 끊기면 `closed_*` 보고 후 `ack_timeout_seconds` 간격으로 재접속을
  반복하고, 성공할 때마다 세대를 1 늘려 `conn open`을 보고한다. 재접속 시도는
  stop 전까지 멈추지 않는다(세션 상한은 core의 watchdog이 정한다).
- `ping_interval=None`(클라이언트발 RFC 6455 ping 차단 — 공식 SDK와 동일).
  서버발 프로토콜 ping/pong은 라이브러리가 처리한다(§12.2 증거 범위 밖).

### 2.3 `reg` / `remove` — 구독 지시 (core만 발행)

```json
{"type":"reg","gen":7,"refresh":"1",
 "data":[{"item":["005930"],"type":["0B"]}]}
{"type":"remove","gen":8,"data":[{"item":["005930"],"type":["0B"]}]}
```

- `data`는 sub_input의 `composeRegData`/`composeMarketStateReg`/
  `composeRemoveData` 산물 그대로다. sidecar는 이를 **문서 상수 봉투**로
  조립해 송신한다:
  - REG: `{"trnm":"REG","grp_no":"1","refresh":"1","data":[...]}`
    (`grp_no` "1"·`refresh` "1"은 공식 46개 예제 전체가 고정하는 형태)
  - REMOVE: `{"trnm":"REMOVE","grp_no":"1","data":[...]}`
    (해지시 refresh 값 불필요 — 공식 refresh 원문)
- `gen`은 core의 구독 세대(기록용)이며 와이어로 나가지 않는다. sidecar는
  `gen`을 검증만 한다(정수 ≥ 1)고 해석하지 않는다.
- `refresh`는 `"1"`만 허용된다. `"0"`은 해지 범위 UNVERIFIED로 스캐너 정책이
  사용하지 않는다(REPLAY_CONTRACT §12.6). 다른 값은 sidecar가 거부한다.
- REG/REMOVE 송신 직후 sidecar는 quiet 타이머를 `ack_timeout_seconds`로
  무장한다(§3.4). 수신 메시지(무엇이든)가 도착하면 타이머는 초기화되고,
  정적이 `ack_timeout_seconds`持续되면 `timer kind=quiet`을 발행한다.
- core는 해당 ack(`ws` 이벤트로 수신한 REG/REMOVE ack)를 파싱한 뒤
  `{"type":"disarm"}`을 보내 quiet 타이머를 해제한다.

### 2.4 `rest_req` — REST ka10027 1페이지

```json
{"type":"rest_req","direction":"up","page":1,"cont_yn":"N","next_key":""}
```

- sidecar는 `POST {rest_domain}/api/dostk/rkinfo`, 헤더 `api-id: ka10027`,
  `authorization: Bearer <token>`, (연속조회 시) `cont-yn`, `next-key`,
  본문 = `rest_params` 8필드 + `sort_tp`("1"=up, "3"=down)를 송신한다.
  페이지 반복의 판단(cont-yn/next-key)은 **core**가 한다: sidecar는 각 응답을
  `rest` 이벤트로 보고하고 상태를 갖지 않는다.
- HTTP 전송 실패(연결·타임아웃 등)는 `rest` 이벤트 대신
  `error what=rest` 이벤트로 보고한다. HTTP 상태 코드가 뭐든 **응답이
  도착하면** `rest` 이벤트로 원문과 함께 보고한다(401 포함 — 판정은 core).
- 응답 본문은 **원문 bytes 그대로** `body_hex`(소문자 hex)로 전달된다.
  sidecar는 본문을 파싱하지 않는다(인증 계열 판별도 core의 몫 — §4).

### 2.5 `refresh_token` — 토큰 재발급 지시

- core가 `rest` 이벤트의 상태(401 또는 본문 auth 계열 코드)를 판정해
  재시도 전에 발행한다. sidecar는 §5의 토큰 경로를 다시 수행하고
  `{"ev":"token","t":...}`(성공) 또는 `error what=token`(실패)로 응답한다.

### 2.6 `wait_drain` / `stop` — 종료

- `wait_drain`: sidecar는 `drain_seconds` 동안 수신 루프를 계속 돌리며
  (이벤트 전달 유지) 경과 후 `drain_done`을 발행한다.
- `stop`: WS를 코드 1000으로 닫고, 큐를 비우고, exit 0으로 종료한다.
  stop 이전에 파이프가 깨지면(BrokenPipe) sidecar는 exit 4로 죽는다
  (core가 먼저 죽은 비정상 상황).

## 3. sidecar → core 이벤트

모든 이벤트는 `"ev"`와 `"t"`(ISO 8601, 숫자 오프셋, KST +09:00 —
sidecar 소유 시계)를 가진다.

### 3.1 `ready` / `token`

```json
{"ev":"ready","t":"2026-11-02T08:59:30+09:00"}
{"ev":"token","t":"..."}
```

### 3.2 `conn` — 연결 생애

```json
{"ev":"conn","state":"open","conn":1,"t":"..."}
{"ev":"conn","state":"closed_ok","conn":1,"code":1000,"reason":"","t":"..."}
{"ev":"conn","state":"closed_error","conn":2,"code":1006,"reason":"...","t":"..."}
```

- `conn`은 WS 연결 세대(1부터, 연결마다 증가). `code`/`reason`은
  websockets `ConnectionClosed(OK/Error)`의 `rcvd.code`/`rcvd.reason`(ok는
  서버가 보낸 값, error는 라이브러리 예외의 값 — 1006 등). open에는 없다.
- core는 모든 `conn`을 `ws_conn` 레코드로 기록한다(기존 ignored kind).
  `closed_*`는 추가로 `gap` 레코드(symbol null — 확인된 GAP, §7)를 낳는다.

### 3.3 `ws` — 수신 WS 애플리케이션 메시지 (불투명 전달)

```json
{"ev":"ws","conn":1,
 "payload_hex":"7b2274726e6d223a22...","t":"..."}
```

- `recv(decode=False)`의 원문 application payload bytes(재조립 완료,
  프레임 정보 없음 — REPLAY_CONTRACT §12.2). **채널 판별 없이 전달**하며
  core가 파싱해 채널·유형을 판정한다(§4·§6).
- PING도 예외 없이 이 이벤트로 전달된다(기록 관측 항목) — echo는 sidecar가
  전송 계층에서 수행하고, echo 송신 자체는 기록 의무가 없다(§12.7).

### 3.4 `timer` — sidecar 소유 시계

```json
{"ev":"timer","kind":"poll","t":"..."}      // repoll_seconds마다, 첫 conn open 기준
{"ev":"timer","kind":"watchdog","t":"..."}  // watchdog 시각 1회, 세션 진행 중일 때만
{"ev":"timer","kind":"quiet","t":"..."}     // 무장 상태에서 ack_timeout_seconds간 완전 정적일 때
```

- `poll`은 "이 시각에 재조회를 시작하라"는 신호일 뿐이다. 페이지 반복·스왑
  판단은 전부 core가 한다.
- `watchdog`은 1회만 발행된다. core는 이것을 받으면 정상 종료 경로를
  폐쇄한다(§8).
- `quiet`은 "wire가 완전히 조용하다"는 통신 계층 사실이지 ack 부재의
  판정이 아니다. 판정(core): ack 대기 중이면 ack 타임아웃(§8 INCOMPLETE),
  대기 중이 아니면 무시하고 센다.

### 3.5 `rest` — REST 응답 (원문)

```json
{"ev":"rest","direction":"up","page":1,"status":200,
 "cont_yn":"N","next_key":"","body_hex":"7b0a...","t":"..."}
```

- `status`는 HTTP 상태. `cont_yn`/`next_key`는 응답 헤더 원문(없으면 "").
- core는 이것을 `rest_resp` 레코드로 기록하고(rest_resp.nim 스키마),
  vendor_input 규칙으로 성립을 검증한 뒤 체인을 조립한다. 실패 응답
  (non-200, 본문 미성립)의 처리는 §7과 같다.

### 3.6 `drain_done`, `error`

```json
{"ev":"drain_done","t":"..."}
{"ev":"error","what":"rest|token|send|internal","detail":"...","t":"..."}
```

- `what=send`: 와이어 송신 실패(REG/REMOVE/…). core는 이것을 확인된 전송
  오류로 분류한다(§7).
- `what=internal`: sidecar 내부 결함. core는 세션을 즉시 비정상 종료한다
  (INCOMPLETE 경로, §8). sidecar 자신도 같은 결함으로 exit 4.

## 4. sidecar의 최소 판별 (전부 — 이것 밖에 없다)

1. **PING**: 수신 bytes가 (a) trim하면 정확히 `"PING"` 문자열 JSON이거나
   (b) JSON 파싱에 성공하고 `trnm == "PING"`이면, **수신 bytes를 그대로
   echo**한다(공식 SDK는 파싱 후 재직렬화 — 우리 쪽이 더 충실, §12.7).
   echo 실패는 `error what=send`. PING 여부와 무관하게 모든 수신 메시지는
   `ws` 이벤트로 전달된다.
2. **LOGIN**: 접속 후 1회 송신, ack `return_code`로 접속 성립만 판정.
   auth 계열 실패 시 재발급+1회 재시도. 내용은 기록하지 않는다(core가
   ws_raw로 기록한다).
3. **토큰 만료**: 캐시 `expires_at`이 유일한 만료 근거(agent-89i8jq2u:
   expires_dt 유일 만료 근거·재발급=재호출·8010 IP 바인딩). 기준은
   공식 SDK와 같은 600초 버퍼. 토큰 값은 어디에도 출력되지 않는다.

그 외의 어떤 payload도 sidecar는 열지 않는다 — 0B/0s/REG/REMOVE/LOGIN ack의
채널·유형·코드 판별과 후보·종료 판정은 전부 Nim core의 권위다.

## 5. 자격 증명 경로 (선택과 근거)

**선택: subprocess 경로 — `kiwoomcli auth refresh` + 로컬 토큰 캐시 판독.**

- 열람 사실(라이브 호출 없음, `--help`만): `kiwoomcli auth refresh`는
  "저장된 자격 증명으로 새 접근 토큰을 발급하고 로컬 캐시를 갱신",
  `auth export`는 App Key/Secret을 .env로 내보내고, 그 외 하위명령 중 토큰
  값을 stdout으로 노출하는 것은 없다.
- 따라서 sidecar는: (1) 캐시 파일을 읽어 토큰·만료를 얻고, (2) 만료
  근접·부재 시 `kiwoomcli auth refresh --profile <alias>`를 subprocess로
  실행한 뒤 다시 읽는다. **appkey/secretkey는 sidecar에 존재하지 않는다** —
  kiwoomcli가 자신의 키 저장소(네이티브 자격 저장소)에서만 다룬다. 
  `auth export`(.env 평문)는 채택하지 않았다(디스크에 시크릿을 쓰는 경로
  추가를 피함).
- 캐시 파일: kwcli 1.0.3의 `FileTokenStore` 레이아웃
  (`user_cache_dir("kiwoom")/profiles/profile-<sha256(alias)[:16]>-token.json`,
  필드 `access_token`/`token_type`/`expires_at`/`mode`/`profile`/…, 0600).
  이 레이아웃 의존은 명시적 의존으로 기록되며, 판독 실패는 fail-closed다
  (재시도 1회 후 `error what=token`, exit 3 — 기본값·재시도 무한 금지).
- 토큰 값은 프로세스 메모리에서만 존재한다: 로그·stderr·레코드·종료 보고
  어디에도 쓰지 않는다. 모의테스트로만 검증한다(라이브 호출 없음).

## 6. 기록 규칙 (이미 커밋된 계약 그대로)

core가 Recorder의 단일 작성자로서 쓰는 레코드(seq = 기록 순서):

| 원인 | 레코드 |
|---|---|
| 세션 시작 | `calendar`(승인 스냅샷 전체), `config`(§6.1) |
| conn 이벤트 전부 | `ws_conn`(기존 ignored kind, 진단용: conn/state/code/reason/t) |
| `closed_*` 연결 종료 | 위 ws_conn + `gap`(symbol null, 확인된 GAP) |
| 수신 WS 메시지 전부(0B·0s·PING·REG/REMOVE/LOGIN ack 포함) | `ws_raw`(channel=core 판별, conn, t, payload_hex) |
| REG/REMOVE ack | 위 ws_raw **+** `sub`(phase=ack, return_code/return_msg) — core는 자신의 미매칭 req(gen, action)와 짝지어 activeSets 갱신 |
| core가 보낸 reg/remove | `sub`(phase=req, gen/types/codes/refresh) — 송신 **전에** 기록 |
| REST 응답 전부 | `rest_resp`(rest_resp.nim 스키마: 선언 스코프+page+status+cont_yn+next_key+body_hex) |
| REST 실패(전송 실패·non-200·본문 미성립) | `gap`(symbol null, api_id/direction/page/what/detail — §7) |
| 세션 정상 종료 | `recorder.finish()` — seal + COMMITTED 마커 |

### 6.1 config 레코드 (PH-1 승인값 전부 기록)

```json
{"environment":"demo","market":"KRX",
 "candidate_query":{"mrkt_tp":"000","trde_qty_cnd":"0000","stk_cnd":"0",
   "crd_cnd":"0","updown_incls":"1","pric_cnd":"0","trde_prica_cnd":"0",
   "stex_tp":"1","sort_tp":"1|3 양방향"},
 "repoll_seconds":300,"page_cap":10,"drain_seconds":10,
 "ack_timeout_seconds":10,"watchdog":"15:40:00+09:00",
 "subscription_caps":{"per_direction":100,"total":200},
 "collector":{"schema":"hong-scanner-collector-config/1",
   "api_id":"ka10027","rest_domain":"https://mockapi.kiwoom.com",
   "ws_endpoint":"wss://mockapi.kiwoom.com:10000","profile":"<alias>"},
 "params":{...}, "session_date":"..."}
```

`repoll_seconds`·`page_cap`의 config 선언은 rest_resp.nim이 예약한
"승인된 확장 경로"다: cadence가 선언된 스트림에서만 같은 스코프의
페이지 체인이 여러 라운드(재조회)를 가질 수 있고, 각 라운드는 1..N 연속·
단말 cont_yn으로 감사된다. 선언이 없으면 기존 규칙(체인 재시작 REJECT)이
그대로 적용된다.

### 6.2 개시 순서 (판정 권위 core)

config·calendar → `connect` → (conn open) → 0s REG req(별도,
composeMarketStateReg, refresh="1") → ack → 초기 REST 조회(up 체인 →
down 체인, cont-yn/core가 page_cap 내 반복) → 후보 도출(vendor_input,
KRX) → 0B REG req(refresh="1") → ack → 스트리밍. 이후 `timer poll`마다
재조회 → 후보 변화 시 스왑: REMOVE(구세대 전체)→ack(return_code 0)→
REG(신세대, refresh="1")→ack. 0s는 스왑 경로에 절대 등장하지 않는다
(별도 REG, 구조적 배제 — sub_input.nim).

## 7. GAP 분류 (계약 §12 확정표의 구현 매핑 — 전부 기존 kind)

| 사건 | 기록 | 후속 |
|---|---|---|
| 연결 종료(closed_ok/closed_error) | `ws_conn` + `gap`(symbol null) | core가 이벤트 처리 계속, sidecar가 재접속(세대 증가) |
| 전송 오류(error what=send/rest) | `gap`(symbol null + detail) | 재조회는 다음 poll에서 |
| 인증 실패(REST 401·auth 코드) | `gap` + (refresh_token 후) 1회 재시도 | 재시도 성공분만 rest_resp 체인으로 기록(체인 연속성 보존), 실패 체인은 그날 증거로 남는다 |
| REG ACK 실패(return_code≠0) | `sub`(ack, return_code≠0) — 구독 미확정 | activeSets 불변(fail-closed) → 해당 종목 틱은 소비 검사 1에 걸려 격리. 시작 0s/0B REG 실패·타임아웃은 INCOMPLETE 경로(§8) |
| 기록 실패(recorder poisoned) | (기록 불가 — 파일 보존) | finish() 금지, abandon(), exit 4 |
| 큐 overflow | 발생하지 않는다(구조): bounded 큐 + blocking put = 조용한 버림 없음, 역압은 TCP 읽기 정지. 파이프 단절은 sidecar exit 4 | — |
| 전체 스트림 장시간 무응답(STALE) | 연속한 `timer poll` 두 개 사이에 `ws_raw`가 하나도 없으면 `gap`(symbol null, what=stale — GAP_SUSPECTED) | 스트리밍 계속(늦은 트래픽이 gap 해소), 회복 없이 watchdog이면 INCOMPLETE |
| 종목 무체결 | 아무것도 기록하지 않는다(GAP 아님) | — |

## 8. 종료 프로토콜과 exit 코드

- **정상**: 215∈{4,8} 관측(0s ws_raw의 core 파싱) → teardown REMOVE(활성
  0B 전체) → ack(return_code 0) → `wait_drain` → `drain_done` →
  `recorder.finish()`(seal+COMMITTED 마커) → `stop` → sidecar exit 0 →
  **collector exit 0**.
- **INCOMPLETE(정직한 실패)**: watchdog까지 {4,8} 무관측 / ack 실패·타임아웃
  (시작 REG·teardown REMOVE 포함) / 기록 실패 / sidecar 내부 결함 →
  **finish() 호출 금지**(seal 없음 = verify가 INCOMPLETE로 판정) →
  파일 보존 → `recorder.abandon()`(이미 닫혀 있으면 생략) → `stop`(가능하면)
  → **collector exit 4**.
- **사용법·내부 계약 위반**: exit 2.
- exit 코드는 이 문서가 정의한다: 0 정상, 2 사용법·계약, 4 INCOMPLETE.
  실패를 성공으로 꾸미는 경로는 존재하지 않는다.

## 9. 0B/0s 와이어 형상 (공식 스펙 JSON으로 확정 — tickwire.nim 단일 파서)

공식 스펙 JSON `주식체결(0B)`·`장시작시간(0s)`의 response_example 원문 형상:

```json
{"trnm":"REAL","data":[{"type":"0B","name":"주식체결","item":"005930",
  "values":{"20":"165208","10":"-20800","15":"+82","13":"30379732",
            "25":"5","290":"2", "...51 FID 전부 String":"..."}}]}
{"trnm":"REAL","data":[{"type":"0s","name":"장시작시간","item":"",
  "values":{"215":"b","20":"170000","214":"000000"}}]}
```

- REG/REMOVE/LOGIN ack: `{"trnm":"REG","return_code":0,"return_msg":""}` —
  `return_code`는 "등록,해지요청시에만 값 전송 0:정상,1:오류, 데이터 실시간
  수신시 미전송"(스펙 원문). 스키마는 이 필드를 String으로 선언하고 예제는
  숫자를 보낸다 — 공식 SDK 정규화 규칙(정수 또는 "0"·"0000"형 숫자
  문자열)대로 두 형식을 하나의 정수로 정규화하고(모의 REST 실측
  2026-10-31: 정수 0), 그 외 값은 파싱 실패(fail-closed). ack는 어떤
  요청 식별자도 되돌려주지 않는다 →
  짝짓기는 스트림 순서로 같은 (gen, action)의 가장 오래된 미매칭 req
  (sub_input.activeSets 규칙 그대로)이며, core는 한 번에 하나의 요청만
  미완료로 둔다.
- 파싱 규칙(Nim, collector와 replay 양쪽이 쓰는 단일 파서):
  - JSON 파싱 실패 = fail-closed: ws_raw는 보존, replay는 그 seq에서 REJECT,
    collector는 보존+집계(세션은 계속 — 기록이 멈추면 증거가 멈춘다).
  - 채널 라벨(core가 판별해 ws_raw.channel에 기록): payload가 JSON 객체가
    아니거나 알 수 없는 trnm이면 `"unknown"`; `trnm`이 REG/REMOVE/LOGIN/
    PING이면 그 값; `trnm == "REAL"`이면 data 전체의 `type`(혼합이면
    "unknown"). replay는 기록된 channel과 재유도 결과의 일치를 강제한다
    (불일치=REJECT).
  - 0B tick으로 쓰는 FID(문서화된 것만): 20(체결시간 HHmmss — 세션 날짜와
    결합), 10(현재가, 부호 포함 정수 — **부호 의미 UNVERIFIED, 기록된 부호
    그대로 보존·사용**), 13(누적거래량, 음수면 파싱 거부), 290(장구분
    1/2/3, 없으면 ""→conflict 집계), 25(전일대비기호 1~5 — 보존만),
    15(거래량 +매수/−매도 체결 — **보존만, 15→13 합산 규칙 미가정**),
    215(0s 장운영구분 — 값 전체 원문 보존, 종료 증거 부분집합 {4,8}).
  - 필수 FID(20/10/13) 누락·형식 위반 = 파싱 실패(fail-closed). values에
    우리가 쓰지 않는 FID는 제약 없이 원문 bytes로 보존된다.
- FID 215 전체 값표(스펙 원문, 2026-10-30): 0 장시작전 알림(8:40~) / 3 장시작
  (09:00) / 2 장마감 알림(15:20~) / 4 장마감(15:30) / 8 정규장마감(거래소
  수신 15:30 이후) / 9 전체장마감(18:00 이후) / a~d 시간외 / e,f,o,s 선옵 /
  P~V NXT. 종료 최소 증거는 {4,8} ≥1 + 0B REMOVE ack(§12.4); 9 등은
  관측 기록 전용.

## 10. 소비 검사 3종 (src/hs/subcheck.nim — collector와 replay 공유)

스트림 순서의 `sub`·`ws_raw` 레코드만으로 결정적으로 재계산된다:

1. 활성 구독 세대(activeSets, ack return_code 0만)에 없는 종목의 0B 틱 →
   격리(qkUnsubscribed).
2. REMOVE ack 이후(재등록 ack 전) 해당 종목의 늦은 이벤트 → 격리
   (qkPostRemove).
3. 재접속(ws_raw.conn 증가) 이전 세대에서 ACK된 구독은 **재등록 ack 전까지
   유효하지 않다** → 그 사이 틱은 격리(qkStaleConn). REMOVE ack는
   재검증하지 못한다(오직 reg ack만 stateConn을 새 연결 세대로 옮긴다 —
   fail-closed).

- **격리는 REJECT가 아니다**: 격리된 틱은 봉·신호 계산에 절대 들어가지
  않고(collector·replay 양쪽 다), 개수와 사유가 결정적으로 재계산되어
  결과에 보고된다(`quarantined`). verify는 `SUBCHECK=quarantined=<n>`을
  출력하지만 이것 자체로 판정을 바꾸지는 않는다 — 재생 결정성·바이트
  일치·내구성 판정은 그대로 성립한다. 승인(GATES) 관점에서 0이 아닌
  격리 수는 검토 대상 증거다. 판정 규칙의 본문은 이 절이며,
  docs/LIMITS.md에 무sub 경계와 함께 명시된다.
- **무sub 경계**: `ws_frame` 합성 틱(VS-1)은 검사 대상이 아니다 — 구독
  증거가 없는 합성 스트림은 무손상 통과한다(기존 게이트 유지). 검사는
  0B `ws_raw` 틱에만 적용되며, 0B ws_raw가 있는데 sub 증거가 전혀 없는
  스트림은 전부 격리된다(정직한 결과).
- 환경이 선언된 스트림(config.environment)이 seal까지 갔다면, replay는
  최소 종료 증거({4,8} ≥1 관측 + (remove, ack 0) 0B)를 재검출해 확인한다.
  증거 없는 seal은 collector 계약 위반 = REJECT다.

## 11. 빌드·테스트 (게이트 통합)

- Nim collector-core: `src/hs/`의 순수 모듈(collector/tickwire/subcheck) —
  테스트는 `tests/test_collector_contract.nim`, `tests/test_tickwire_contract.nim`,
  `tests/test_subcheck_contract.nim`, `tests/test_collector_stream_contract.nim`.
- sidecar: Python 3.13 격리 venv(`tools/collector/.venv`, gitignore),
  의존성은 `requirements.txt`(websockets만 — 키움 SDK 불필요·복제 금지).
  `bash tools/collector/test_sidecar.sh`가 venv를 보장하고 unittest를
  돌린다(모킹 websockets·가짜 core — 라이브 호출 없음).
- 게이트: `bash tools/run_tests.sh` exit 0 + `ALL CONTRACT SUITES PASSED`
  (새 스위트 포함). CI는 python 3.13 설치 단계를 갖는다.
- 실행(라이브, 별도 사전검증 단계에서만): 
  `tools/collector/collector --profile <alias> --session-date YYYY-MM-DD --out runs/<dir>`
  — 개발 중 라이브 호출 금지(하드 규칙). 바이너리는
  `nim c -d:release --path:src -o:tools/collector/collector tools/collector/collector.nim`.

## 12. UNVERIFIED·사전 검증 목록 (merge 후 실측 항목)

- ws_raw 실측 형상 대조: 실제 0B/0s/REG ack/PING payload가 §9 형상과
  정확히 일치하는지(필드 집합·타입·FID 존재). 합성 테스트는 스펙 example
  형상 기반일 뿐이다.
- REG/REMOVE ack의 실측 return_code 집합(0/1 문서 vs 실측), return_msg 원문
  (형식 불일치는 2026-10-31 문서 조사로 확인: 스키마 String vs 예제 숫자 —
  SDK 규칙대로 두 형식 모두 정규화 수용. 실측 집합·원문은 여전히 실측 대상).
- PING 수신 주기·형태(문자열 "PING" vs {"trnm":"PING"})·무응답 동작.
- quiet 타이머 10초의 실측 적합성(ack 지연이 10초를 넘는지).
- 연속조회 페이지 크기·체인 길이(page_cap 10 도달 여부 — 도달 시
  TRUNCATED로 정직 기록).
- 재접속 시 구독 유지 여부(재등록 전 트래픽 존재 여부 — qkStaleConn 격리
  실측).
- 토큰 경로 실측: 캐시 판독·만료 임계·재발급 동작(agent-89i8jq2u의
  10-31 만료 이후 관측).
- websockets 잔여 UNVERIFIED(max_size 초과 종료 코드, recv 지연 무유실의
  직접 문구) — GAP 기록·fail-closed로 흡수.
