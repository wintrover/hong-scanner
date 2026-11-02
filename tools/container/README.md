# 단일 컨테이너 계약 (Northflank Phase-0, PR-2)

이 문서는 루트 `Dockerfile`·`.dockerignore`·`tests/test_container_contract.sh`가
함께 구성하는 **커밋되는 컨테이너 계약**이다. 이미지 구성·빌드 절차·신뢰
경계가 이 문서와 어긋나면 구현이 틀린 것이다.

- 상위 계약: tools/api/README.md §1·§5 (serve.py 구동·보안 경계,
  `--bind 0.0.0.0` 컨테이너 전용), docs/REPLAY_CONTRACT.md §13,
  docs/GATES.md.
- Phase-0 범위: **API 서버 상시 실행형 단일 컨테이너**. supervisor(PR-4)와
  공급망·증명(PR-5)은 이 위에서 확장된다 — §7.

## 1. 이미지 구성 (변경 불가)

| 항목 | 값 |
|---|---|
| base | `python:3.13-slim` — serve.py는 표준 라이브러리만 사용(http.server), **pip 설치 금지** |
| 사용자 | 비루트 `hongscanner` (system user, nologin) |
| 코드 | `/opt/hongscanner/` — `serve.py` · `bin/hongscanner` · `CALENDAR_INDEX.sha256` |
| 데이터 | `/var/lib/hongscanner/` — `runs/` · `notify/` (볼륨 마운트 지점, 빈 상태로 이미지에 존재) |
| 노출 | `EXPOSE 8080`, `STOPSIGNAL SIGTERM` |
| CMD | `python3 /opt/hongscanner/serve.py --bind 0.0.0.0 --port 8080 --runs /var/lib/hongscanner/runs --ledger /var/lib/hongscanner/notify/ledger.hcj.jsonl` |

- **`--bind 0.0.0.0`은 Northflank ingress 뒤 컨테이너 전용이다.** 이 API에는
  인증이 없고, 0.0.0.0 바인드의 접근 통제는 플랫폼(Northflank ingress Basic
  Auth)에 위임된다. 플랫폼 ingress 뒤가 아닌 0.0.0.0(그 외 비루프백 포함)의
  인터넷 직접 노출은 tools/api/README.md §1·§5의 계약 위반이다. 로컬 운영은
  기본값(127.0.0.1)을 쓴다.
- serve.py 실행 계약(README §1과 동일): 기동 성공 시 stdout에 `SERVE
  <bind>:<port>` 한 줄 flush — 스크립트·supervisor가 기동 증거로 쓴다.
  SIGTERM/SIGINT로 조용히 드레인 후 exit 0. exit 2 = 사용법·설정 위반,
  exit 4 = 바인드 실패. 실패를 exit 0으로 꾸미는 경로는 없다.
- **CMD는 Phase-0 값이다**: PR-4의 cloud_supervisor ENTRYPOINT로 대체될
  예정이다. 이미지 레이아웃(경로·사용자·볼륨)이 안정 표면이다.
- 데이터는 요청마다 볼륨에서 다시 읽는다(상태 캐시 없음 — README §1).
- ledger(`notify/ledger.hcj.jsonl`)는 **볼륨 공급이지 이미지에 구운 것이
  아니다**: 이미지는 비어 있는 `notify/`만 만든다. `runs/`도 마찬가지다.

## 2. 빌드 컨텍스트 스테이징 (외부 경로 COPY 금지)

Docker의 일반 COPY는 **빌드 컨텍스트 밖 파일에 도달할 수 없다** — 컨텍스트
밖 경로의 `..` 성분은 정규화 과정에서 제거된다(docs.docker.com 공식
동작). 특히 attest 잡의 `$CI_BUILD_OUT/hongscanner`는 저장소 밖 절대
경로라서 컨텍스트에 직접 넣을 수 없다. 그래서:

1. 이미지를 빌드하는 주체가 **스테이징 디렉터리(mktemp)를 만들고 필요한
   파일을 그 안으로 복사**한다.
2. 그 디렉터리를 컨텍스트로 `docker build`한다.
3. Dockerfile은 **컨텍스트 내 상대 경로만** COPY한다: `bin/hongscanner`,
   `tools/api/serve.py`, `calendars/CALENDAR_INDEX.sha256`.

스테이징 절차(운영·테스트 공통):

```sh
CTX="$(mktemp -d)"
mkdir -p "$CTX/bin" "$CTX/tools/api" "$CTX/calendars"
cp Dockerfile                      "$CTX/Dockerfile"
cp .dockerignore                   "$CTX/.dockerignore"
cp tools/api/serve.py              "$CTX/tools/api/serve.py"
cp calendars/CALENDAR_INDEX.sha256 "$CTX/calendars/CALENDAR_INDEX.sha256"
cp <hongscanner 바이너리>            "$CTX/bin/hongscanner"
docker build -t <tag> [--label org.hongscanner.image-purpose=ci-test] "$CTX"
```

- `<hongscanner 바이너리>`가 무엇인지는 §3이 규정한다(테스트와 운영이
  다르다).
- `.dockerignore`는 **스테이징할 때 컨텍스트에 함께 복사해야 효력이
  있다**(docker는 컨텍스트 루트의 `.dockerignore`를 읽는다). 스위트는
  같은 `.dockerignore`를 쓰는 프로브 컨텍스트에 합성 decoy
  (`calendars/krx-fake.json`, 내용은 테스트가 만든 CAL-DECOY 바이트 —
  실제 데이터가 아니다)를 넣고 COPY가 실패함을 관측해 이 효력을
  **가정이 아니라 실측**한다.
- `.dockerignore`는 컨텍스트 화이트리스트다: 위 다섯 파일만 통과시키고
  나머지 전부를 제외한다. **실제 `calendars/*.json`(gitignore된 사용자
  데이터)은 컨텍스트에 들어올 수 없다** — INDEX(`CALENDAR_INDEX.sha256`,
  git 추적·canonical main 출처)만 통과한다(§4).
- **운영 빌드는 PR-5의 attest 잡이 같은 절차로 수행한다**: attest 산출
  바이너리(`$CI_BUILD_OUT/hongscanner`)를 스테이징 컨텍스트로 복사한 뒤
  build한다. 이 Dockerfile은 그 빌드와 테스트 빌드의 공유 계약이다.

## 3. 테스트 바이너리와 운영 바이너리의 산출물 분리

- **테스트 경로** (`tests/test_container_contract.sh` — CI·게이트 포함):
  tests/test_cli_contract.sh와 같은 패턴으로 mktemp 샌드박스에
  `nim c ... -o:"$SANDBOX/hongscanner" src/hongscanner.nim`로 **직접
  컴파일한 테스트 전용 바이너리**만 쓴다. `tools/build.sh` 산출도,
  저장소 루트의 `./hongscanner`도 절대 쓰지 않는다.
- **배치 불가 표식**: 테스트 이미지는 반드시
  `docker build --label org.hongscanner.image-purpose=ci-test` 라벨을
  갖는다. 이 라벨은 **배치 금지 표식**이다 — 라벨이 붙은 이미지는
  Northflank에 배치해서는 안 되며, 향후 배치 경로(PR-4·PR-5)는 이 라벨을
  단 이미지를 거부해야 한다. 테스트 스위트가 라벨을 단언한다.
- **운영 경로**: attest 잡의 CI_BUILD_OUT 바이너리, **표식 없음**.
  운영 이미지는 PR-5에서만 만든다(§7). 두 산출물의 혼용 경로는 존재하지
  않는다 — 테스트 스크립트는 테스트 바이너리만 다루고, 운영 이미지
  검증은 별도 경로(PR-5)로 간다.
- 저장소 루트의 `./hongscanner`은 과거 사고로 남은 개발 빌드다 —
  **사용·삭제·덮어쓰기 금지**(AGENTS.md §-1; gitignore 대상).

## 4. 캘린더 신뢰 분리

- `calendars/CALENDAR_INDEX.sha256`는 git 추적 파일(canonical main
  출처)이다 — **이미지에 COPY해 구운다**(/opt/hongscanner/). 테스트는
  이미지 속 INDEX가 git 추적 파일과 바이트 일치함을 단언한다.
- 실제 `calendars/*.json`은 gitignore된 사용자 데이터다 — **이미지에도,
  빌드 컨텍스트에도, 테스트 픽스처에도 실제 파일을 넣지 않는다**
  (.dockerignore로 제외, INDEX만 통과; 스위트가 컨텍스트에 json이
  없음을 단언).
- 운영에서는 **Northflank 영구 볼륨이 캘린더 JSON을 공급**하고, 그 내용을
  이미지에 구운 INDEX와 **교차 검증**한다. 이 교차 검증의 실행은 PR-4
  범위다(Phase-0은 INDEX 구움과 컨텍스트 배제까지만 계약).

## 5. 볼륨 레이아웃

```
/opt/hongscanner/              # 이미지 레이어 (코드, 읽기 전용 운명)
  serve.py
  bin/hongscanner
  CALENDAR_INDEX.sha256
/var/lib/hongscanner/          # 영구 볼륨 마운트 지점 (Northflank)
  runs/                        #   recorder·verify가 쓴 런 디렉터리들
  notify/
    ledger.hcj.jsonl           #   이벤트 ledger (append-only)
```

- 이미지는 두 디렉터리를 **비어 있는 상태로** 만들어 둔다(serve.py가
  `--runs` 디렉터리 부재에 exit 2로 끝나지 않도록 runs/는 필수). 내용은
  전부 볼륨에서 온다.
- 컨테이너는 비루트로 실행되므로 볼륨 마운트 내용은 `hongscanner`
  사용자(uid = 이미지의 system uid)가 읽을 수 있어야 한다. 이 API는
  어떤 파일도 쓰지 않는다(읽기 전용 투영 — tools/api/README.md §0).

## 6. 테스트·게이트

- `bash tests/test_container_contract.sh`: 실측 스모크. mktemp 샌드박스 →
  테스트 바이너리 nim 직접 컴파일 → 스테이징 컨텍스트(Dockerfile·
  .dockerignore·serve.py·INDEX·바이너리) →
  `docker build --label org.hongscanner.image-purpose=ci-test` →
  .dockerignore 효력 실측(decoy calendar json의 COPY 실패) →
  이미지 내부 검증(레이아웃·실행 비트·바인드 바이트 일치·INDEX·라벨·비루트) →
  합성 fixture(runs 루트 + 2-레코드 ledger, tools/api/test_api.py의
  구성 방식)를 `-v` 마운트해 `docker run -d -p 127.0.0.1::<임시포트>:8080` →
  로그에서 `SERVE 0.0.0.0:8080` 대기 → `GET /status` 200·본문 JSON 검증 →
  `POST /status` 405(`Allow: GET`) → 미지 경로 404 → `docker stop`
  (SIGTERM) → exit 0·비-OOM 관측 → 컨테이너·이미지 제거와 잔류 0 단언.
- **docker가 없으면 fail-closed**: docker CLI 부재·데몬 불도응은
  exit 1 + 명확한 메시지다. 게이트(`tools/run_tests.sh`)가 이 스위트를
  포함하므로 **docker 없는 환경에서 게이트는 실패한다 — 의도된 계약**이다.
  재시도·우회 경로는 없다. 베이스 이미지 pull 실패도 그대로 실패다.
- Python 해석 순서는 collector·notify·api 스위트와 같다:
  `$HSCOLLECTOR_PYTHON` → `python3.13` → `uv python find 3.13`.
  스위트는 합성 fixture 바이트와 응답 JSON 검증에만 호스트 Python을
  쓴다.
- 게이트: `bash tools/run_tests.sh`에 등록된 스위트(`run bash
  tests/test_container_contract.sh`)의 exit 0. 단독 통과는 게이트가
  아니다. 전체 게이트에 이 스위트로 몇 분이 더해진다(이미지 빌드·pull).

## 7. 범위 밖 (향후 PR)

- **PR-4**: cloud_supervisor — CMD의 ENTRYPOINT 대체, serve.py 자식
  프로세스 감시, 캘린더 볼륨 vs 이미지 INDEX 교차 검증의 **실행**,
  컨테이너 내 바이너리 실행 호환성 확인.
- **PR-5**: 공급망 — attest 잡이 CI_BUILD_OUT 바이너리로 같은 스테이징
  절차의 **운영 이미지**(표식 없음)를 만들고 증명·배포.
- GHCR push·이미지 서명·배치 자동화 — 본 PR 범위 밖.
- 인증·TLS·헬스체크 인프라 — tools/api/README.md §7과 동일하게 범위 밖.
