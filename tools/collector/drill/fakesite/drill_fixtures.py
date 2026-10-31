"""Drill fixtures: the simulated Kiwoom demo wire payloads.

Every simulated shape cites its source (no invented shapes):

- REG/REMOVE/LOGIN ack ``{"trnm":...,"return_code":0,"return_msg":""}`` —
  tools/collector/README.md §9 ("REG/REMOVE/LOGIN ack" response_example
  원문 형상; return_code 스펙 원문 "등록,해지요청시에만 값 전송 0:정상,
  1:오류"). Ack는 요청 식별자를 되돌려주지 않는다(같은 절).
- LOGIN ack return_code 0 = 접속 성립 — README §2.2, sidecar.py handshake.
- 0s frame — README §9 response_example:
  ``{"trnm":"REAL","data":[{"type":"0s","name":"장시작시간","item":"",
  "values":{...}}]}``; values FID 215(장운영구분)·20(장시작시간
  HHmmss)·214 — FID 215 값 "4"는 장마감(15:30), 종료 최소 증거 부분집합
  {4,8} (README §9 값표 원문; src/hs/tickwire.nim closeEvidence215).
- 0B frame — README §9 response_example:
  ``{"trnm":"REAL","data":[{"type":"0B","name":"주식체결","item":...,
  "values":{...}}]}``; values는 스펙 원문과 같이 전부 String이고 이
  드릴이 쓰는 FID는 20(체결시간)·10(현재가)·15(거래량)·13(누적거래량)·
  25(전일대비기호)·290(장구분) — src/hs/tickwire.nim 헤더의 스펙 원문
  인용과 동일한 필드 집합(§9 파싱 규칙의 필수/보존 FID).
- ka10027 REST page — src/hs/vendor_input.nim 헤더의 공식 스펙 대조
  사실: list key ``pred_pre_flu_rt_upper``, 12개 String 행 필드
  (stk_cls stk_cd stk_nm cur_prc pred_pre_sig pred_pre flu_rt sel_req
  buy_req now_trde_qty cntr_str cnt), ``return_code``(int, 0=ok) +
  ``return_msg``(string); 연속조회는 헤더 cont-yn/next-key. 행 값은
  합성 fixture 값이다(실측 시장 데이터 아님 — tests/
  test_collector_stream_contract.nim의 합성 형상과 같은 취지).
- PING — 서버가 애플리케이션 b"PING"을 보내면 클라이언트가 수신 bytes를
  그대로 echo한다 (README §12.7, sidecar.py serve).
- REG/REMOVE 봉투(클라이언트가 보내는 것) — README §2.3: REG는
  grp_no "1"·refresh "1", REMOVE는 refresh 없음.

토큰 캐시 레이아웃 — sidecar.py TokenStore(README §5): kwcli 1.0.3
FileTokenStore와 같은 ``<XDG_CACHE_HOME>/kiwoom/profiles/
profile-<sha256(alias)[:16]>-token.json`` (access_token/token_type/
expires_at), 값은 전부 가짜 fixture 값이다.
"""

import hashlib
import json
import os
import time

# 합성 종목 코드: 이 저장소의 기존 계약 테스트·fixture가 쓰는 것과 같은
# 6자리 합성 코드(tests/test_collector_stream_contract.nim의 005930/000660).
UP_CODE = "005930"
DOWN_CODE = "000660"

WIRE_TRNM_REAL_0B = "주식체결"    # README §9 response_example 원문
WIRE_TRNM_REAL_0S = "장시작시간"  # README §9 response_example 원문


def wirelog(path_env="HSDRILL_WIRELOG"):
    """Append one JSON line to the drill wire log (evidence artifact).
    Never logs credential values: callers must not pass them."""
    path = os.environ.get(path_env)
    if not path:
        return

    def log(**fields):
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(fields, ensure_ascii=False) + "\n")

    return log


def ack(trnm):
    """The REG/REMOVE/LOGIN ack shape (README §9)."""
    return json.dumps({"trnm": trnm, "return_code": 0, "return_msg": ""},
                      ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def tick_0b(code, t20, price, cum):
    """One 0B REAL frame (README §9; FID values are String, spec 원문)."""
    return json.dumps(
        {"trnm": "REAL", "data": [{"type": "0B", "name": WIRE_TRNM_REAL_0B,
                                   "item": code,
                                   "values": {"20": t20, "10": price,
                                              "15": "+1", "13": str(cum),
                                              "25": "2", "290": "2"}}]},
        ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def state_0s(value215):
    """One 0s REAL frame (README §9; FID 215 raw value preserved)."""
    return json.dumps(
        {"trnm": "REAL", "data": [{"type": "0s", "name": WIRE_TRNM_REAL_0S,
                                   "item": "",
                                   "values": {"215": value215,
                                              "20": "153000",
                                              "214": "000000"}}]},
        ensure_ascii=False, separators=(",", ":")).encode("utf-8")


KA10027_ROW_FIELDS = [
    "stk_cls", "stk_cd", "stk_nm", "cur_prc", "pred_pre_sig", "pred_pre",
    "flu_rt", "sel_req", "buy_req", "now_trde_qty", "cntr_str", "cnt"]


def ka10027_page(codes):
    """One terminal ka10027 page: return_code 0 + the documented list key
    with object rows of exactly the 12 documented String fields
    (vendor_input.nim header facts; rows are synthetic fixture values)."""
    rows = []
    for i, code in enumerate(codes):
        rows.append({
            "stk_cls": "1",
            "stk_cd": code,
            "stk_nm": "DRILL-FIXTURE-%d" % (i + 1),
            "cur_prc": "+10000",
            "pred_pre_sig": "2",
            "pred_pre": "+500",
            "flu_rt": "+5.00",
            "sel_req": "1000",
            "buy_req": "2000",
            "now_trde_qty": "300",
            "cntr_str": "+",
            "cnt": str(i + 1),
        })
    return json.dumps(
        {"return_code": 0, "return_msg": "",
         "pred_pre_flu_rt_upper": rows},
        ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def token_cache_dir(base):
    return os.path.join(base, "kiwoom", "profiles")


def token_cache_path(base, profile):
    digest = hashlib.sha256(profile.encode("utf-8")).hexdigest()[:16]
    return os.path.join(token_cache_dir(base),
                        "profile-%s-token.json" % digest)


def seed_token_cache(base, profile, token):
    """Write the kiwoomcli FileTokenStore layout the sidecar reads
    (sidecar.py TokenStore; README §5). Far-future expires_at: the drill
    never needs a refresh. Values are fixture strings, not credentials."""
    path = token_cache_path(base, profile)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"access_token": token, "token_type": "Bearer",
                   "expires_at": time.time() + 86400.0,
                   "mode": "mock", "profile": profile}, f)
    os.chmod(path, 0o600)
    return path
