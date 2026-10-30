# Hong Scanner 에이전트 지침

> **이 파일이 정의하는 것**: AGENTS.md는 무엇이 참인가 · 무엇이 허용되는가 · 누가 권한을 가지는가 · 무엇이 완료인가를 규정한다. 실행 방법을 가르치는 문서가 아니다.
> **잔류 기준**: 이 파일에 남는 문장은 Fact · Invariant · Authority · Acceptance/Failure 뿐이다. 절차·근거·측정값은 docs/ SSOT가 담는다.
> 이 파일의 수정은 사용자의 명시적 지시가 있을 때만 가능하다.

---

## §-1. 절대 규칙 (ABSOLUTE RULE)

- `AGENTS.md`는 사용자의 명시적 지시 없이 수정하지 않는다.
- Northflank 및 기타 외부 배포 계정은 사용자가 준비를 알리기 전까지 진행하지 않는다.
- 주문 실행·공매도·포지션 크기 조절을 구현하지 않는다.
- 루트 `./hongscanner`는 과거 사고로 남은 개발 빌드다: 운영에 사용·삭제·덮어쓰기 금지. 운영 바이너리는 증명 검증 후 설치된 것만.

---

## §0. 헌법 (CONSTITUTION)

### 0.1 목적

목표·완료·승인 조건의 정본은 [docs/GATES.md](docs/GATES.md)다. 이 파일은 그 위에서 작업 규칙을 정의한다.

### 0.2 증명과 승인의 경계 (HARD RULE)

- `provenance=OK`는 자체 보고 메타데이터의 일치일 뿐, 빌드 출처의 독립적 증명이 아니다.
- 합성 테스트 통과·CI green·`VERDICT MATCH`는 실측 운영 승인(GATES P12)이 아니다.
- `NO_TRIGGER_OBSERVED`는 관측된 스트림에만 성립한다.
- 실패는 fail-closed: 실패·미확정을 성공·확정으로 바꾸는 표현·코드를 만들지 않는다.

### 0.3 데이터·시크릿·벤더 (HARD RULE)

- 실시장 데이터·시크릿·키움 SDK 복제본은 저장소에 들어오지 않는다(gitignore 규칙과 일치).
- 자격 증명은 플랫폼/공식 클라이언트의 네이티브 저장소로만 다룬다. 발견 시 보고 후 정지한다.
- 키움 SDK의 복제·수정·재배포·번들은 라이선스상 금지다.
- 벤더 동작 주장은 공식 소스(명세 JSON·공식 클라이언트 소스) 대조 후에만 문서화한다([docs/ASSUMPTIONS.md](docs/ASSUMPTIONS.md) "Vendor facts").

### 0.4 요구사항의 등급

ASSUMPTIONS.md의 MUST만 요구사항다. POLICY·IMPLEMENTATION·UNKNOWN은 검증·변경 가능한 가정이다.

---

## §1. 아키텍처 (ARCHITECTURE)

- Core는 결정적 순수 계산이다: 벽시계·파일시스템·네트워크 입력이 없다. 판정을 바꾸는 모든 입력은 `input.hcj.jsonl` 하나에 있다([docs/REPLAY_CONTRACT.md](docs/REPLAY_CONTRACT.md)).
- 벤더 I/O·자격 증명은 Core 밖의 어댑터 경계에 둔다.
- 커밋된 계약 없이 새 아키텍처 계층·데이터베이스·인프라를 추가하지 않는다.

---

## §2. 규칙 & 워크플로

### 2.1 게이트와 증거 (HARD RULE)

- 테스트 게이트는 `bash tools/run_tests.sh`의 exit 0과 `ALL CONTRACT SUITES PASSED` 출력이다. `nimble test` 단독은 게이트가 아니다(2026-10-29 거짓 green 사고).
- CI 판정은 체크 표시가 아니라 런 로그의 `ALL CONTRACT SUITES PASSED` 실측으로 확인한다.
- CI가 실패해도 exit 0을 내는 경로·실패를 삼키는 코드를 새로 만들지 않는다.
- 실패한 런과 그 증거는 삭제·덮어쓰기하지 않는다. 재현은 항상 새 디렉터리에 한다.
- main merge의 권위는 GitHub이다(ruleset·required check `ci`·PR 필수·직접 push 차단). required checks가 0건이면 UNKNOWN이지 SUCCESS가 아니다.

### 2.2 브랜치·변경 (HARD RULE)

- 비자잡 변경은 전용 브랜치로만 수행한다. main의 미커밋 변경은 reset·discard·stash·overwrite 금지(보존 후 전환).
- 배포 바이너리는 attest 워크플로 산출물을 `tools/install-attested.sh`로 설치한 것만 사용하며, 정확한 main sha로 증명을 검증한다.
- 완료 주장은 명령→관측→pass/fail을 동반한다. 선언·PR 생성·로컬 테스트·부분 CI 성공은 완료가 아니다.
- main에 동작 변경이 반영되면 attest·설치·검증을 재측정한다(문서 전용 커밋은 제외).

---

## §3. 환경

- Nim 2.2.10 고정(`tools/build.sh`가 다른 도구체인을 거부한다).
- 키움 REST/WS는 공식 문서·공식 SDK 명세를 신뢰 사실로 삼는다.
- kwcli를 쓰는 경로는 Python 3.13 이상이 필요하다(시스템 Python은 3.12).

---

## §4. GUARDIAN

- 변경을 ASSUMPTIONS(MUST)·REPLAY_CONTRACT·GATES에 검증한다. 검증 불가·오래된 증거는 fail-closed다.
- 계약을 깨는 우회 대신 최소 구조 변경을 한다. 범위 밖 발견은 별도 보고다.

---

## §5. SSOT 위치

| 계층 | 내용 |
|---|---|
| AGENTS.md | 에이전트 규칙·완료 조건(이 파일) |
| docs/REPLAY_CONTRACT.md | 입력·기록·리플레이·검증 계약 |
| docs/GATES.md | 목표·게이트·증거 로그·승인 조건 |
| docs/ASSUMPTIONS.md | MUST/POLICY/UNKNOWN 분류, 벤더 사실 |
| docs/LIMITS.md | 현재 증거가 증명하지 않는 것 |
| tools/run_tests.sh | 유일한 테스트 게이트(실행) |

측정값·런 ID·커밋 해시·증거 로그는 AGENTS.md에 두지 않는다(docs/GATES.md가 정본이다).
