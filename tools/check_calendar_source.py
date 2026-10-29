#!/usr/bin/env python3
"""KRX 운영 캘린더 출처 권위 확인(읽기 전용, 공개 조회 도구).

calendars/*.json 의 sources[] 중 url·method·body·response_sha256 메타가 있는
소스를, 허용 목록(allowlist)에 든 KRX 공개 HTTPS 호스트로만 다시 조회해
응답 바이트의 SHA-256 이 기록값과 같은지 비교·보고한다.

명시적 범위·한계:
- MATCH 는 '그 시점의 공개 응답 바이트 SHA-256 이 기록값과 동일'만 뜻한다.
  공식 KRX 휴장일 확인이 특별 개장/폐장시간 변경(임시 개·폐장, 반일장 등)을
  증명하지 않는다.
- 이 도구는 캘린더 자동 갱신·운영 승인(GATES P12)을 대체하지 않는다.
- 비밀·시장 데이터 미취급: 인증 헤더·쿠키를 넣지 않고, 캘린더에 기록된
  공개 휴장일 소스만 조회한다. 응답 바이트는 메모리에서 해시만 계산하고
  저장하지 않는다.
- calendars/ 와 CALENDAR_INDEX.sha256 은 절대 쓰지 않는다(읽기 전용).
- Python 표준 라이브러리만 사용한다(외부 패키지 금지).

fail-closed exit code(우선순위 INVALID > ERROR > MISMATCH > MATCH):
  0  검증 대상 전원 MATCH
  1  MISMATCH — 응답 바이트가 기록 해시와 다르다(소스 변경 의심)
  2  ERROR — 조회 실패(네트워크·TLS·timeout·HTTP 상태·크기 상한·리다이렉트)
  3  INVALID — URL 차단, 메타 오류, 캘린더 파싱 실패, 검증 대상 없음
  4  사용법 오류

사용:
  python3 tools/check_calendar_source.py [--calendars DIR] [--timeout SEC]
"""
from __future__ import annotations

import argparse
import contextlib
import functools
import hashlib
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional, Sequence, Tuple

ALLOWED_HOSTS = frozenset({"open.krx.co.kr", "global.krx.co.kr"})
DEFAULT_CALENDARS_DIR = Path(__file__).resolve().parent.parent / "calendars"
DEFAULT_TIMEOUT_SECONDS = 20.0
MIN_TIMEOUT_SECONDS = 1.0
MAX_TIMEOUT_SECONDS = 120.0
MAX_URL_CHARS = 2048
MAX_REQUEST_BODY_BYTES = 2048
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
MAX_CALENDAR_BYTES = 32 * 1024 * 1024
REQUEST_GAP_SECONDS = 1.0
USER_AGENT = "hongscanner-check-calendar-source/1"
REQUEST_HEADERS = {"User-Agent": USER_AGENT, "Accept": "*/*"}

EXIT_ALL_MATCH = 0
EXIT_MISMATCH = 1
EXIT_ERROR = 2
EXIT_INVALID = 3
EXIT_USAGE = 4

FetchFn = Callable[[str, str, Optional[str]], Tuple[bytes, Optional[int]]]

_SHA256_RE = re.compile(r"[0-9a-fA-F]{64}")


class InvalidSourceError(Exception):
    """INVALID: URL 차단 또는 소스 메타 오류(조회 시도 전에 판정)."""


class FetchError(Exception):
    """ERROR: 조회 실패(전송·상태·크기·timeout)."""


@dataclass
class SourceMeta:
    calendar: Path
    index: int
    sid: str
    url: str
    method: str
    body: Optional[str]
    expected_sha256: str


@dataclass
class SourceReport:
    calendar: Path
    index: int
    sid: str
    verdict: str  # "SKIP" | "INVALID"
    detail: str


@dataclass
class SourceResult:
    calendar: Path
    index: int
    sid: str
    verdict: str  # MATCH | MISMATCH | ERROR | INVALID | SKIP
    detail: str
    expected_sha256: Optional[str] = None
    actual_sha256: Optional[str] = None
    response_bytes: int = 0
    http_status: Optional[int] = None


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def validate_source_url(url: object, allowed_hosts: frozenset = ALLOWED_HOSTS) -> str:
    """URL 남용 차단. 통과한 정규화된 https URL 을 반환한다.

    허용 조건: https 만, userinfo 금지, port 는 443(또는 생략), host 는
    allowlist 와 대소문자 무관 정확히 일치. IP·localhost·유사 도메인·경로
    이탈은 모두 정확 일치 검사로 차단된다.
    """
    if not isinstance(url, str) or not url:
        raise InvalidSourceError("url 이 없다")
    if len(url) > MAX_URL_CHARS:
        raise InvalidSourceError(f"url 길이 상한 초과({len(url)} > {MAX_URL_CHARS})")
    for ch in url:
        o = ord(ch)
        if o <= 0x20 or 0x7F <= o:
            raise InvalidSourceError("url 에 제어·공백·비ASCII 문자가 있다")
    try:
        parts = urllib.parse.urlsplit(url)
        if parts.username is not None or parts.password is not None:
            raise InvalidSourceError("url 에 userinfo 를 쓸 수 없다")
        port = parts.port
    except ValueError as e:
        raise InvalidSourceError(f"url 파싱 실패: {e}") from e
    if parts.scheme.lower() != "https":
        raise InvalidSourceError(f"scheme 은 https 여야 한다: {parts.scheme!r}")
    if port is not None and port != 443:
        raise InvalidSourceError(f"허용되지 않는 port: {port}")
    host = parts.hostname
    if not host:
        raise InvalidSourceError("host 가 없다")
    if host not in {h.lower() for h in allowed_hosts}:
        raise InvalidSourceError(f"허용 목록 밖의 host: {host}")
    return url


def _validate_method_body(method: object, body: object) -> None:
    if not isinstance(method, str) or method.upper() not in ("GET", "POST"):
        raise InvalidSourceError(f"method 는 GET/POST 여야 한다: {method!r}")
    normalized = method.upper()
    if normalized == "POST":
        if not isinstance(body, str) or not body:
            raise InvalidSourceError("POST 소스에는 body(문자열)가 필요하다")
    elif body not in (None, ""):
        raise InvalidSourceError("GET 소스에는 body 가 없어야 한다")
    if isinstance(body, str):
        raw = body.encode("utf-8")
        if len(raw) > MAX_REQUEST_BODY_BYTES:
            raise InvalidSourceError(
                f"body 크기 상한 초과({len(raw)} > {MAX_REQUEST_BODY_BYTES} bytes)")
        if any(not (0x20 <= b <= 0x7E) for b in raw):
            raise InvalidSourceError("body 는 인쇄 가능 ASCII 여야 한다")


def _validate_sha256(value: object) -> None:
    if not isinstance(value, str) or not _SHA256_RE.fullmatch(value):
        raise InvalidSourceError(f"response_sha256 이 16진수 64자가 아니다: {value!r}")


def scan_calendar_file(path: Path):
    """캘린더 하나를 읽어 (검증 대상 메타, SKIP/INVALID 보고, 파일 오류)."""
    metas: list[SourceMeta] = []
    reports: list[SourceReport] = []
    try:
        raw = path.read_bytes()
    except OSError as e:
        return metas, reports, f"읽기 실패: {e}"
    if len(raw) > MAX_CALENDAR_BYTES:
        return metas, reports, f"파일 크기 상한 초과({len(raw)} bytes)"
    try:
        doc = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        return metas, reports, f"JSON 파싱 실패: {e}"
    if not isinstance(doc, dict):
        return metas, reports, "최상위 값이 JSON 객체가 아니다"
    sources = doc.get("sources")
    if not isinstance(sources, list):
        return metas, reports, "sources 배열이 없다"
    for idx, entry in enumerate(sources, start=1):
        sid = entry.get("id") if isinstance(entry, dict) else None
        sid = sid.strip() if isinstance(sid, str) and sid.strip() else f"source[{idx}]"
        if not isinstance(entry, dict):
            reports.append(SourceReport(path, idx, sid, "INVALID", "source 항목이 객체가 아니다"))
            continue
        if "response_sha256" not in entry:
            reports.append(SourceReport(path, idx, sid, "SKIP",
                                        "response_sha256 미기록(비교 불가, 참고 소스)"))
            continue
        reasons = []
        try:
            validate_source_url(entry.get("url"))
        except InvalidSourceError as e:
            reasons.append(f"url: {e}")
        try:
            _validate_method_body(entry.get("method"), entry.get("body"))
        except InvalidSourceError as e:
            reasons.append(f"method/body: {e}")
        try:
            _validate_sha256(entry.get("response_sha256"))
        except InvalidSourceError as e:
            reasons.append(f"response_sha256: {e}")
        if reasons:
            reports.append(SourceReport(path, idx, sid, "INVALID", "; ".join(reasons)))
            continue
        metas.append(SourceMeta(
            calendar=path,
            index=idx,
            sid=sid,
            url=entry["url"],
            method=str(entry["method"]).upper(),
            body=entry.get("body"),
            expected_sha256=str(entry["response_sha256"]).lower(),
        ))
    return metas, reports, None


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # 리다이렉트 차단: allowlist 우회 경로를 원천 봉쇄


def fetch_bytes(url: str, method: str, body: Optional[str] = None, *,
                timeout: float = DEFAULT_TIMEOUT_SECONDS,
                max_response_bytes: int = MAX_RESPONSE_BYTES,
                allow_plain_http: bool = False) -> Tuple[bytes, Optional[int]]:
    """단일 조회. 리다이렉트 비활성, 응답 크기 상한, timeout 강제.

    이 함수는 전송만 담당한다. 호스트 allowlist·https 강제는 진입점
    (verify_source/main) 이 validate_source_url 로 항상 먼저 검사한다.
    allow_plain_http 는 네트워크 없는 로컬 테스트 전용 스위치다.
    """
    try:
        parts = urllib.parse.urlsplit(url)
    except ValueError as e:
        raise FetchError(f"url 파싱 실패: {e}") from e
    scheme = parts.scheme.lower()
    if scheme not in ("http", "https"):
        raise FetchError(f"허용되지 않은 scheme: {scheme!r}")
    if scheme == "http" and not allow_plain_http:
        raise FetchError("평문 http 는 허용되지 않는다(https 필수)")
    data = None
    headers = dict(REQUEST_HEADERS)
    if body:
        data = body.encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=data, headers=headers, method=method.upper())
    opener = urllib.request.build_opener(_NoRedirectHandler)
    try:
        with opener.open(req, timeout=timeout) as resp:
            status = getattr(resp, "status", None)
            if status is None and hasattr(resp, "getcode"):
                status = resp.getcode()
            declared = resp.headers.get("Content-Length") if resp.headers else None
            if declared is not None:
                try:
                    if int(declared) > max_response_bytes:
                        raise FetchError(
                            f"응답 크기 상한 초과(선언 {declared} bytes > 상한 {max_response_bytes})")
                except ValueError:
                    pass
            payload = resp.read(max_response_bytes + 1)
            if len(payload) > max_response_bytes:
                raise FetchError(
                    f"응답 크기 상한 초과({len(payload)} bytes > 상한 {max_response_bytes})")
            if status is not None and not (200 <= status < 300):
                raise FetchError(f"HTTP 상태 {status}")
            return payload, status
    except FetchError:
        raise
    except urllib.error.HTTPError as e:
        detail = f"HTTP 상태 {e.code}"
        with contextlib.suppress(Exception):
            e.close()
        raise FetchError(detail) from e
    except urllib.error.URLError as e:
        reason = e.reason
        if isinstance(reason, TimeoutError) or "timed out" in str(reason).lower():
            raise FetchError(f"timeout({timeout}s) 초과") from e
        raise FetchError(f"조회 오류: {reason}") from e
    except TimeoutError as e:
        raise FetchError(f"timeout({timeout}s) 초과") from e
    except OSError as e:
        raise FetchError(f"전송 오류: {e}") from e


def verify_source(meta: SourceMeta, fetch: Optional[FetchFn] = None) -> SourceResult:
    """소스 하나를 검증: URL 차단 → 조회 → 바이트 SHA-256 비교(fail-closed)."""
    if fetch is None:
        fetch = functools.partial(fetch_bytes, timeout=DEFAULT_TIMEOUT_SECONDS)
    try:
        validate_source_url(meta.url)
        _validate_method_body(meta.method, meta.body)
        _validate_sha256(meta.expected_sha256)
    except InvalidSourceError as e:
        return SourceResult(meta.calendar, meta.index, meta.sid, "INVALID", str(e),
                            expected_sha256=meta.expected_sha256)
    try:
        payload, status = fetch(meta.url, meta.method, meta.body)
    except FetchError as e:
        return SourceResult(meta.calendar, meta.index, meta.sid, "ERROR", f"조회 실패: {e}")
    except Exception as e:  # 예측 밖 예외도 닫힌 판정으로
        return SourceResult(meta.calendar, meta.index, meta.sid, "ERROR",
                            f"조회 중 예외({type(e).__name__}): {e}")
    actual = sha256_hex(payload)
    expected = str(meta.expected_sha256).lower()
    if actual == expected:
        return SourceResult(meta.calendar, meta.index, meta.sid, "MATCH",
                            "응답 바이트 SHA-256 일치",
                            expected, actual, len(payload), status)
    return SourceResult(meta.calendar, meta.index, meta.sid, "MISMATCH",
                        "응답 바이트가 기록 해시와 다르다(소스 변경 또는 요청마다 달라지는 응답)",
                        expected, actual, len(payload), status)


NOTE_LINES = (
    "NOTE MATCH는 공개 응답 바이트의 SHA-256이 기록값과 동일함만 확인한다. 공식 KRX 휴장일 확인이",
    "NOTE 특별 개장/폐장시간 변경(임시 개·폐장, 반일장 등)을 증명하지 않는다.",
    "NOTE 이 도구는 캘린더 자동 갱신·운영 승인(GATES P12)을 대체하지 않는다.",
    "NOTE calendars/ 및 CALENDAR_INDEX.sha256은 절대 쓰지 않는다(읽기 전용).",
    "NOTE 비밀·시장 데이터 미취급: 인증 헤더·쿠키 없이 공개 휴장일 조회만 수행한다.",
)


def print_notes() -> None:
    for line in NOTE_LINES:
        print(line)


def _format_result(r: SourceResult) -> str:
    base = f"SRC {r.calendar.name}#{r.index} id={r.sid} VERDICT={r.verdict}"
    if r.verdict in ("MATCH", "MISMATCH"):
        s = (f"{base} expected={r.expected_sha256} actual={r.actual_sha256}"
             f" bytes={r.response_bytes}")
        if r.http_status is not None:
            s += f" status={r.http_status}"
        if r.verdict == "MISMATCH":
            s += f" detail={r.detail}"
        return s
    return f"{base} detail={r.detail}"


class _UsageParser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        print(f"USAGE ERROR: {message}", file=sys.stderr)
        raise SystemExit(EXIT_USAGE)


def _build_parser() -> argparse.ArgumentParser:
    hosts = ", ".join(f"https://{h}" for h in sorted(ALLOWED_HOSTS))
    return _UsageParser(
        prog="check_calendar_source.py",
        description=(
            "KRX 캘린더 출처 권위 확인(읽기 전용). calendars/*.json sources 의 "
            "url/method/body/response_sha256 로 공개 휴장일 응답 SHA-256 을 대조한다. "
            f"허용 호스트: {hosts}"
        ),
        epilog=("MATCH는 특별 개장/폐장시간 변경을 증명하지 않고, 캘린더 자동 갱신·"
                "운영 승인을 대체하지 않는다."),
    )


def _build_parser_with_args() -> argparse.ArgumentParser:
    parser = _build_parser()
    parser.add_argument("--calendars", default=str(DEFAULT_CALENDARS_DIR),
                        help="calendars 디렉터리(기본: 저장소 루트의 calendars)")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS,
                        help=f"조회 timeout 초(기본 {DEFAULT_TIMEOUT_SECONDS}, "
                             f"{MIN_TIMEOUT_SECONDS}~{MAX_TIMEOUT_SECONDS})")
    return parser


def main(argv: Optional[Sequence] = None, *, fetch: Optional[FetchFn] = None,
         gap_seconds: float = REQUEST_GAP_SECONDS) -> int:
    parser = _build_parser_with_args()
    args = parser.parse_args(argv)
    timeout = float(args.timeout)
    if not (MIN_TIMEOUT_SECONDS <= timeout <= MAX_TIMEOUT_SECONDS):
        parser.error(f"--timeout 은 {MIN_TIMEOUT_SECONDS}~{MAX_TIMEOUT_SECONDS} 사이여야 한다")
    if fetch is None:
        fetch = functools.partial(fetch_bytes, timeout=timeout)

    cal_dir = Path(args.calendars)
    if not cal_dir.is_dir():
        print(f"CALENDAR_SOURCE CHECK RESULT=INVALID detail=calendars 디렉터리가 없다: {cal_dir}")
        print_notes()
        return EXIT_INVALID
    files = sorted(p for p in cal_dir.glob("*.json") if p.is_file())
    if not files:
        print(f"CALENDAR_SOURCE CHECK RESULT=INVALID detail=JSON 캘린더 파일이 없다: {cal_dir}")
        print_notes()
        return EXIT_INVALID

    results: list[SourceResult] = []
    file_errors = 0
    network_pending = False
    for path in files:
        metas, reports, error = scan_calendar_file(path)
        if error is not None:
            file_errors += 1
            print(f"CAL {path.name} INVALID: {error}")
        else:
            skipped = sum(1 for r in reports if r.verdict == "SKIP")
            invalid = sum(1 for r in reports if r.verdict == "INVALID")
            print(f"CAL {path.name} OK verifiable={len(metas)} skipped={skipped} invalid={invalid}")
        for rep in reports:
            results.append(SourceResult(rep.calendar, rep.index, rep.sid,
                                        rep.verdict, rep.detail))
        for meta in metas:
            if network_pending and gap_seconds > 0:
                time.sleep(gap_seconds)
                network_pending = False
            res = verify_source(meta, fetch)
            if res.verdict in ("MATCH", "MISMATCH", "ERROR"):
                network_pending = True
            results.append(res)

    for res in results:
        print(_format_result(res))
    counts = Counter(r.verdict for r in results)
    checked = counts["MATCH"] + counts["MISMATCH"] + counts["ERROR"] + counts["INVALID"]
    print(f"SUMMARY files={len(files)} checked={checked} match={counts['MATCH']} "
          f"mismatch={counts['MISMATCH']} error={counts['ERROR']} "
          f"invalid={counts['INVALID']} skipped={counts['SKIP']}")

    if file_errors > 0 or counts["INVALID"] > 0 or checked == 0:
        label, code = "INVALID", EXIT_INVALID
    elif counts["ERROR"] > 0:
        label, code = "ERROR", EXIT_ERROR
    elif counts["MISMATCH"] > 0:
        label, code = "MISMATCH", EXIT_MISMATCH
    else:
        label, code = "ALL_MATCH", EXIT_ALL_MATCH
    print(f"CALENDAR_SOURCE CHECK RESULT={label} exit={code}")
    print_notes()
    return code


if __name__ == "__main__":
    sys.exit(main())
