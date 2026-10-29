#!/usr/bin/env python3
"""tools/check_calendar_source.py 계약 테스트 — 네트워크 없이 수행된다.

실제 공개 KRX(open.krx.co.kr) 호출은 이 테스트가 하지 않는다. 그 검증은
부모/운영자가 별도로 수행한다. 여기서는 두 가지 주입 방식만 쓴다:
- 함수 주입: verify_source/main 에 가짜 fetch 함수를 넣어 MATCH/MISMATCH/
  ERROR/INVALID 판정과 exit 코드를 검증한다.
- 로컬 가짜 HTTP: 127.0.0.1 의 http.server 가 실제 전송 계층(method·body·
  header·상태·리다이렉트·크기 상한·timeout)을 검증한다.

캘린더·인덱스는 절대 쓰지 않는다: 모든 캘린더는 임시 디렉터리 사본이며,
읽기 전용 동작을 파일 해시 대조로 확인한다.

실행: python3 tests/test_calendar_source.py
"""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TOOL_PATH = REPO_ROOT / "tools" / "check_calendar_source.py"

_spec = importlib.util.spec_from_file_location("check_calendar_source", TOOL_PATH)
ccs = importlib.util.module_from_spec(_spec)
sys.modules["check_calendar_source"] = ccs  # dataclass 어노테이션 처리에 필요
sys.dont_write_bytecode = True  # 도구 디렉터리에 __pycache__ 를 남기지 않는다
_spec.loader.exec_module(ccs)


# --------------------------------------------------------------- 공통 픽스처

KRX_URL = "https://open.krx.co.kr/contents/OPN/99/OPN99000001.jspx"
KRX_BODY = "bld=MKD/01/0110/01100305/mkd01100305_01&search_bas_yy=2026&gridTp=KRX"
PAYLOAD_2026 = b'{"blockList":[{"marketName":"KRX","rows":[]}]}'
SHA_2026 = hashlib.sha256(PAYLOAD_2026).hexdigest()
OTHER_PAYLOAD = b'{"blockList":[]}'


def krx_source(**overrides):
    src = {
        "id": "krx-mkd01100305-json",
        "url": KRX_URL,
        "method": "POST",
        "body": KRX_BODY,
        "retrieved_at": "2026-10-28T16:45:00+09:00",
        "response_sha256": SHA_2026,
    }
    src.update(overrides)
    return src


def note_source():
    return {
        "id": "krx-holiday-rules-en",
        "url": "https://global.krx.co.kr/contents/GLB/06/0602/0602010201/GLB0602010201T1.jsp",
        "note": "Regular Session 09:00~15:30",
    }


def write_calendar(root: Path, name: str, sources: list) -> Path:
    cal = root / "calendars"
    cal.mkdir(parents=True, exist_ok=True)
    path = cal / name
    path.write_text(json.dumps(
        {"schema": "hong-scanner-calendar/1", "market": "KRX", "sources": sources},
        ensure_ascii=False), encoding="utf-8")
    return cal


def fake_fetch(payloads=None, errors=None):
    payloads = payloads or {}
    errors = errors or {}

    def fetch(url, method, body):
        if url in errors:
            raise ccs.FetchError(errors[url])
        if url not in payloads:
            raise AssertionError(f"예상치 않은 조회: {url}")
        return payloads[url], 200

    return fetch


def run_main(cal_dir, fetch=None, *extra):
    argv = ["--calendars", str(cal_dir), *extra]
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
        code = ccs.main(argv, fetch=fetch, gap_seconds=0.0)
    return code, buf.getvalue()


# --------------------------------------------------- 로컬 가짜 HTTP 서버

class _RecordingHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def _handle(self):
        server = self.server
        body = b""
        length = self.headers.get("Content-Length")
        if length:
            body = self.rfile.read(int(length))
        server.seen.append({
            "method": self.command,
            "path": self.path,
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "body": body,
        })
        route = server.routes.get((self.command, self.path))
        if route is None:
            route = {"status": 404, "body": b"not found"}
        if route.get("sleep"):
            time.sleep(route["sleep"])
        self.send_response(route["status"])
        for k, v in (route.get("headers") or {}).items():
            self.send_header(k, v)
        if not route.get("omit_content_length"):
            self.send_header("Content-Length", str(len(route.get("body", b""))))
        self.end_headers()
        self.wfile.write(route.get("body", b""))

    do_GET = _handle
    do_POST = _handle

    def log_message(self, fmt, *args):
        pass


class _SilentHTTPServer(HTTPServer):
    def handle_error(self, request, client_address):
        pass


class LocalFakeHTTP:
    def __init__(self, routes):
        self.server = _SilentHTTPServer(("127.0.0.1", 0), _RecordingHandler)
        self.server.routes = routes
        self.server.seen = []
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        host, port = self.server.server_address
        return f"http://{host}:{port}"

    @property
    def routes(self):
        return self.server.routes

    @property
    def seen(self):
        return self.server.seen

    def close(self):
        self.server.shutdown()
        self.server.server_close()


# ------------------------------------------------------------ 순수 함수 테스트

class ShaTests(unittest.TestCase):
    def test_sha256_hex_matches_hashlib(self):
        self.assertEqual(ccs.sha256_hex(b"abc"),
                         hashlib.sha256(b"abc").hexdigest())
        self.assertEqual(ccs.sha256_hex(b""), hashlib.sha256(b"").hexdigest())


class UrlValidationTests(unittest.TestCase):
    def test_accepts_official_hosts(self):
        for url in (
            KRX_URL,
            "https://global.krx.co.kr/contents/GLB/06/0602010201/GLB0602010201T1.jsp",
            "https://open.krx.co.kr:443/contents/OPN/99/OPN99000001.jspx",
            "HTTPS://OPEN.KRX.CO.KR/contents/OPN/99/OPN99000001.jspx",
        ):
            with self.subTest(url=url):
                self.assertEqual(ccs.validate_source_url(url), url)

    def test_blocks_abusive_urls(self):
        bad = [
            "http://open.krx.co.kr/contents/OPN/99/OPN99000001.jspx",
            "https://evil.example/x",
            "https://open.krx.co.kr.evil.example/x",
            "https://sub.open.krx.co.kr/x",
            "https://open.krx.co.kr:8443/x",
            "https://user:pass@open.krx.co.kr/x",
            "https://user@open.krx.co.kr/x",
            "https://127.0.0.1/",
            "https://localhost/x",
            "https://[::1]/x",
            "ftp://open.krx.co.kr/x",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/plain,hello",
            "https:open.krx.co.kr/x",
            "https:///x",
            "https://open.krx.co.kr./x",
            "https://open.krx.co.kr/a b",
            "https://open.krx.co.kr/a\x7fb",
            "https://open.krx.co.kr/a경로",
            "https://open.krx.co.kr/" + "a" * 2100,
        ]
        for url in bad:
            with self.subTest(url=url[:60]):
                with self.assertRaises(ccs.InvalidSourceError):
                    ccs.validate_source_url(url)

    def test_blocks_open_url_that_is_not_a_string(self):
        for value in (None, 123, b"https://open.krx.co.kr/x", ""):
            with self.subTest(value=value):
                with self.assertRaises(ccs.InvalidSourceError):
                    ccs.validate_source_url(value)


class MetaValidationTests(unittest.TestCase):
    def test_post_requires_body(self):
        with self.assertRaises(ccs.InvalidSourceError):
            ccs._validate_method_body("POST", None)
        with self.assertRaises(ccs.InvalidSourceError):
            ccs._validate_method_body("POST", "")
        ccs._validate_method_body("POST", "bld=x&y=1")

    def test_get_must_not_have_body(self):
        with self.assertRaises(ccs.InvalidSourceError):
            ccs._validate_method_body("GET", "bld=x")
        ccs._validate_method_body("GET", None)
        ccs._validate_method_body("GET", "")

    def test_unsupported_method(self):
        for method in (None, "DELETE", "HEAD", 123, ""):
            with self.subTest(method=method):
                with self.assertRaises(ccs.InvalidSourceError):
                    ccs._validate_method_body(method, None)

    def test_body_size_and_charset_limits(self):
        big = "a" * (ccs.MAX_REQUEST_BODY_BYTES + 1)
        with self.assertRaises(ccs.InvalidSourceError):
            ccs._validate_method_body("POST", big)
        with self.assertRaises(ccs.InvalidSourceError):
            ccs._validate_method_body("POST", "bld=경로")
        with self.assertRaises(ccs.InvalidSourceError):
            ccs._validate_method_body("POST", "bld=a\x00b")

    def test_sha256_format(self):
        ok = "89ccce131de8d0c4baa6a30d62b7d2e8e3bdc872c71a21d7d81d4b667330d384"
        ccs._validate_sha256(ok)
        ccs._validate_sha256(ok.upper())
        for bad in (None, 123, "", "abc", ok[:-1], ok + "0", "z" * 64):
            with self.subTest(bad=bad):
                with self.assertRaises(ccs.InvalidSourceError):
                    ccs._validate_sha256(bad)


# ------------------------------------------------------------------ 스캔 테스트

class ScanTests(unittest.TestCase):
    def test_scan_classifies_sources(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "krx-2026q4.json"
            path.write_text(json.dumps({"sources": [
                krx_source(),
                note_source(),
                krx_source(url="https://evil.example/x"),
                krx_source(method="POST", body=None),
                krx_source(response_sha256="zz"),
            ]}), encoding="utf-8")
            metas, reports, error = ccs.scan_calendar_file(path)
        self.assertIsNone(error)
        self.assertEqual(len(metas), 1)
        self.assertEqual(metas[0].sid, "krx-mkd01100305-json")
        self.assertEqual(metas[0].url, KRX_URL)
        self.assertEqual(metas[0].method, "POST")
        self.assertEqual(metas[0].body, KRX_BODY)
        self.assertEqual(metas[0].expected_sha256, SHA_2026)
        verdicts = {r.index: r.verdict for r in reports}
        self.assertEqual(verdicts, {2: "SKIP", 3: "INVALID", 4: "INVALID", 5: "INVALID"})
        self.assertIn("허용 목록 밖", reports[1].detail)
        self.assertIn("body", reports[2].detail)
        self.assertIn("response_sha256", reports[3].detail)

    def test_scan_skips_source_without_id_still_reports(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "c.json"
            path.write_text(json.dumps({"sources": [
                {"url": KRX_URL, "method": "GET", "response_sha256": "a" * 64},
            ]}), encoding="utf-8")
            metas, reports, error = ccs.scan_calendar_file(path)
        self.assertIsNone(error)
        self.assertEqual(len(metas), 1)
        self.assertEqual(metas[0].sid, "source[1]")

    def test_scan_file_errors(self):
        cases = {
            "bad.json": "{not json",
            "array.json": "[1,2]",
            "nosources.json": json.dumps({"days": {}}),
            "sourcesobj.json": json.dumps({"sources": {}}),
        }
        for name, content in cases.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / name
                path.write_text(content, encoding="utf-8")
                metas, reports, error = ccs.scan_calendar_file(path)
                self.assertEqual((metas, reports), ([], []))
                self.assertIsNotNone(error)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "missing.json"
            metas, reports, error = ccs.scan_calendar_file(path)
            self.assertIsNotNone(error)
            self.assertIn("읽기 실패", error)

    def test_scan_calendar_size_cap(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "c.json"
            path.write_text(json.dumps({"sources": []}), encoding="utf-8")
            old = ccs.MAX_CALENDAR_BYTES
            ccs.MAX_CALENDAR_BYTES = 8
            try:
                metas, reports, error = ccs.scan_calendar_file(path)
            finally:
                ccs.MAX_CALENDAR_BYTES = old
        self.assertEqual((metas, reports), ([], []))
        self.assertIn("상한", error)

# -------------------------------------------------- verify_source(함수 주입)

class VerifyTests(unittest.TestCase):
    def test_match(self):
        meta = ccs.SourceMeta(Path("c.json"), 1, "s", KRX_URL, "POST", KRX_BODY, SHA_2026)
        res = ccs.verify_source(meta, fake_fetch({KRX_URL: PAYLOAD_2026}))
        self.assertEqual(res.verdict, "MATCH")
        self.assertEqual(res.actual_sha256, SHA_2026)
        self.assertEqual(res.response_bytes, len(PAYLOAD_2026))
        self.assertEqual(res.http_status, 200)

    def test_mismatch(self):
        meta = ccs.SourceMeta(Path("c.json"), 1, "s", KRX_URL, "POST", KRX_BODY, SHA_2026)
        res = ccs.verify_source(meta, fake_fetch({KRX_URL: OTHER_PAYLOAD}))
        self.assertEqual(res.verdict, "MISMATCH")
        self.assertEqual(res.actual_sha256, hashlib.sha256(OTHER_PAYLOAD).hexdigest())
        self.assertNotEqual(res.actual_sha256, res.expected_sha256)

    def test_fetch_error(self):
        meta = ccs.SourceMeta(Path("c.json"), 1, "s", KRX_URL, "POST", KRX_BODY, SHA_2026)
        res = ccs.verify_source(meta, fake_fetch(errors={KRX_URL: "HTTP 상태 500"}))
        self.assertEqual(res.verdict, "ERROR")
        self.assertIn("500", res.detail)

    def test_unknown_exception_is_fail_closed_error(self):
        def boom(url, method, body):
            raise RuntimeError("vendor exploded")
        meta = ccs.SourceMeta(Path("c.json"), 1, "s", KRX_URL, "POST", KRX_BODY, SHA_2026)
        res = ccs.verify_source(meta, boom)
        self.assertEqual(res.verdict, "ERROR")
        self.assertIn("RuntimeError", res.detail)

    def test_blocked_url_never_reaches_fetch(self):
        seen = []

        def recorder(url, method, body):
            seen.append((url, method, body))
            return PAYLOAD_2026, 200

        meta = ccs.SourceMeta(Path("c.json"), 1, "s",
                              "https://open.krx.co.kr:8443/x", "POST", KRX_BODY, SHA_2026)
        res = ccs.verify_source(meta, recorder)
        self.assertEqual(res.verdict, "INVALID")
        self.assertEqual(seen, [])

    def test_uppercase_hex_hash_matches(self):
        meta = ccs.SourceMeta(Path("c.json"), 1, "s", KRX_URL, "POST", KRX_BODY,
                              SHA_2026.upper())
        res = ccs.verify_source(meta, fake_fetch({KRX_URL: PAYLOAD_2026}))
        self.assertEqual(res.verdict, "MATCH")


# ------------------------------------------------ fetch_bytes(로컬 가짜 HTTP)

class FetchTests(unittest.TestCase):
    def setUp(self):
        self.server = LocalFakeHTTP({})

    def tearDown(self):
        self.server.close()

    def url(self, path):
        return self.server.url + path

    def test_post_sends_exactly_the_recorded_body(self):
        self.server.routes[("POST", "/krx.jspx")] = {"status": 200, "body": PAYLOAD_2026}
        payload, status = ccs.fetch_bytes(self.url("/krx.jspx"), "POST", KRX_BODY,
                                          timeout=5, allow_plain_http=True)
        self.assertEqual(payload, PAYLOAD_2026)
        self.assertEqual(status, 200)
        self.assertEqual(len(self.server.seen), 1)
        req = self.server.seen[0]
        self.assertEqual(req["method"], "POST")
        self.assertEqual(req["path"], "/krx.jspx")
        self.assertEqual(req["body"], KRX_BODY.encode())
        self.assertEqual(req["headers"]["content-type"],
                         "application/x-www-form-urlencoded")
        self.assertEqual(req["headers"]["user-agent"], ccs.USER_AGENT)
        self.assertIn("content-length", req["headers"])

    def test_get_sends_no_body(self):
        self.server.routes[("GET", "/krx.jspx")] = {"status": 200, "body": b"[]"}
        payload, status = ccs.fetch_bytes(self.url("/krx.jspx"), "GET", None,
                                          timeout=5, allow_plain_http=True)
        self.assertEqual(payload, b"[]")
        self.assertEqual(status, 200)
        req = self.server.seen[0]
        self.assertEqual(req["method"], "GET")
        self.assertEqual(req["body"], b"")
        self.assertNotIn("content-type", req["headers"])

    def test_http_500_is_fail_closed(self):
        self.server.routes[("POST", "/krx.jspx")] = {"status": 500, "body": b"err"}
        with self.assertRaises(ccs.FetchError) as ctx:
            ccs.fetch_bytes(self.url("/krx.jspx"), "POST", KRX_BODY,
                            timeout=5, allow_plain_http=True)
        self.assertIn("500", str(ctx.exception))

    def test_http_404_is_fail_closed(self):
        with self.assertRaises(ccs.FetchError) as ctx:
            ccs.fetch_bytes(self.url("/nowhere.jspx"), "GET", None,
                            timeout=5, allow_plain_http=True)
        self.assertIn("404", str(ctx.exception))

    def test_redirect_is_blocked(self):
        self.server.routes[("GET", "/krx.jspx")] = {
            "status": 302,
            "headers": {"Location": "https://evil.example/steal"},
            "body": b"",
        }
        with self.assertRaises(ccs.FetchError) as ctx:
            ccs.fetch_bytes(self.url("/krx.jspx"), "GET", None,
                            timeout=5, allow_plain_http=True)
        self.assertIn("302", str(ctx.exception))
        self.assertEqual(len(self.server.seen), 1)  # 재요청 없음

    def test_response_size_cap_declared(self):
        self.server.routes[("GET", "/big.jspx")] = {"status": 200, "body": b"x" * 100}
        with self.assertRaises(ccs.FetchError) as ctx:
            ccs.fetch_bytes(self.url("/big.jspx"), "GET", None,
                            timeout=5, max_response_bytes=10, allow_plain_http=True)
        self.assertIn("상한", str(ctx.exception))

    def test_response_size_cap_read_path(self):
        self.server.routes[("GET", "/nocl.jspx")] = {
            "status": 200, "body": b"x" * 100, "omit_content_length": True,
            "headers": {"Connection": "close"},
        }
        with self.assertRaises(ccs.FetchError) as ctx:
            ccs.fetch_bytes(self.url("/nocl.jspx"), "GET", None,
                            timeout=5, max_response_bytes=10, allow_plain_http=True)
        self.assertIn("상한", str(ctx.exception))

    def test_timeout_is_fail_closed(self):
        self.server.routes[("POST", "/slow.jspx")] = {"status": 200, "body": b"{}",
                                                      "sleep": 0.6}
        with self.assertRaises(ccs.FetchError) as ctx:
            ccs.fetch_bytes(self.url("/slow.jspx"), "POST", KRX_BODY,
                            timeout=0.15, allow_plain_http=True)
        self.assertIn("timeout", str(ctx.exception))

    def test_non_http_scheme_rejected_without_io(self):
        for url in ("file:///etc/passwd", "ftp://open.krx.co.kr/x", "javascript:x"):
            with self.subTest(url=url):
                with self.assertRaises(ccs.FetchError) as ctx:
                    ccs.fetch_bytes(url, "GET", None, timeout=5)
                self.assertIn("scheme", str(ctx.exception))

    def test_plain_http_rejected_by_default(self):
        with self.assertRaises(ccs.FetchError) as ctx:
            ccs.fetch_bytes("http://127.0.0.1:9/x", "GET", None, timeout=5)
        self.assertIn("https", str(ctx.exception))


# ------------------------------------------------------- main(함수 주입 CLI)

class MainTests(unittest.TestCase):
    def test_all_match_exits_0(self):
        with tempfile.TemporaryDirectory() as tmp:
            cal = write_calendar(Path(tmp), "krx-2026q4.json",
                                 [krx_source(), note_source()])
            code, out = run_main(cal, fake_fetch({KRX_URL: PAYLOAD_2026}))
        self.assertEqual(code, 0)
        self.assertIn("RESULT=ALL_MATCH", out)
        self.assertEqual(out.count("VERDICT=MATCH"), 1)
        self.assertIn("VERDICT=SKIP", out)
        self.assertIn(f"expected={SHA_2026}", out)

    def test_mismatch_exits_1(self):
        with tempfile.TemporaryDirectory() as tmp:
            cal = write_calendar(Path(tmp), "krx-2026q4.json", [krx_source()])
            code, out = run_main(cal, fake_fetch({KRX_URL: OTHER_PAYLOAD}))
        self.assertEqual(code, 1)
        self.assertIn("RESULT=MISMATCH", out)
        self.assertIn("VERDICT=MISMATCH", out)
        self.assertNotEqual(
            hashlib.sha256(OTHER_PAYLOAD).hexdigest(), SHA_2026)

    def test_error_exits_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            cal = write_calendar(Path(tmp), "krx-2026q4.json", [krx_source()])
            code, out = run_main(cal, fake_fetch(errors={KRX_URL: "timeout(5s) 초과"}))
        self.assertEqual(code, 2)
        self.assertIn("RESULT=ERROR", out)
        self.assertIn("VERDICT=ERROR", out)

    def test_invalid_beats_match_exits_3(self):
        with tempfile.TemporaryDirectory() as tmp:
            cal = write_calendar(Path(tmp), "krx-2026q4.json", [krx_source()])
            write_calendar(Path(tmp), "evil.json",
                           [krx_source(url="https://evil.example/x")])
            code, out = run_main(cal, fake_fetch({KRX_URL: PAYLOAD_2026}))
        self.assertEqual(code, 3)
        self.assertIn("RESULT=INVALID", out)
        self.assertIn("VERDICT=INVALID", out)
        self.assertIn("VERDICT=MATCH", out)

    def test_error_beats_mismatch_exits_2(self):
        other_url = "https://global.krx.co.kr/contents/x.jsp"
        with tempfile.TemporaryDirectory() as tmp:
            cal = write_calendar(Path(tmp), "krx-2026q4.json",
                                 [krx_source(response_sha256="0" * 64),
                                  krx_source(url=other_url)])
            code, out = run_main(cal, fake_fetch(
                payloads={KRX_URL: PAYLOAD_2026},
                errors={other_url: "HTTP 상태 500"}))
        self.assertEqual(code, 2)
        self.assertIn("VERDICT=MISMATCH", out)
        self.assertIn("VERDICT=ERROR", out)

    def test_skip_only_is_fail_closed_invalid(self):
        with tempfile.TemporaryDirectory() as tmp:
            cal = write_calendar(Path(tmp), "krx-2026q4.json", [note_source()])
            code, out = run_main(cal, fake_fetch())
        self.assertEqual(code, 3)
        self.assertIn("RESULT=INVALID", out)
        self.assertIn("VERDICT=SKIP", out)

    def test_calendar_file_error_exits_3(self):
        with tempfile.TemporaryDirectory() as tmp:
            cal = write_calendar(Path(tmp), "bad.json", [krx_source()])
            (cal / "broken.json").write_text("{oops", encoding="utf-8")
            code, out = run_main(cal, fake_fetch({KRX_URL: PAYLOAD_2026}))
        self.assertEqual(code, 3)
        self.assertIn("CAL broken.json INVALID", out)

    def test_scope_notes_are_always_printed(self):
        with tempfile.TemporaryDirectory() as tmp:
            cal = write_calendar(Path(tmp), "krx-2026q4.json", [krx_source()])
            code, out = run_main(cal, fake_fetch({KRX_URL: PAYLOAD_2026}))
        self.assertEqual(code, 0)
        self.assertIn("특별 개장/폐장시간", out)
        self.assertIn("증명하지 않는다", out)
        self.assertIn("자동 갱신·운영 승인", out)
        self.assertIn("대체하지 않는다", out)
        self.assertIn("절대 쓰지 않는다", out)
        self.assertIn("비밀·시장 데이터", out)

    def test_calendars_and_index_are_never_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            cal = write_calendar(Path(tmp), "krx-2026q4.json", [krx_source()])
            index = cal / "CALENDAR_INDEX.sha256"
            index.write_text("canary  calendars/krx-2026q4.json\n", encoding="utf-8")
            before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in sorted(cal.iterdir())}
            code, out = run_main(cal, fake_fetch({KRX_URL: PAYLOAD_2026}))
            after = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in sorted(cal.iterdir())}
            names_after = {p.name for p in cal.iterdir()}
        self.assertEqual(code, 0)
        self.assertEqual(before, after)
        self.assertEqual(names_after, set(before))

    def test_missing_calendars_dir_exits_3(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, out = run_main(Path(tmp) / "nope")
        self.assertEqual(code, 3)
        self.assertIn("RESULT=INVALID", out)

    def test_empty_calendars_dir_exits_3(self):
        with tempfile.TemporaryDirectory() as tmp:
            cal = write_calendar(Path(tmp), "x.json", [])
            (cal / "x.json").unlink()
            code, out = run_main(cal, fake_fetch())
        self.assertEqual(code, 3)
        self.assertIn("RESULT=INVALID", out)

    def test_timeout_out_of_range_is_usage_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            cal = write_calendar(Path(tmp), "x.json", [krx_source()])
            with self.assertRaises(SystemExit) as ctx:
                run_main(cal, None, "--timeout", "0")
            self.assertEqual(ctx.exception.code, ccs.EXIT_USAGE)
            with self.assertRaises(SystemExit) as ctx:
                run_main(cal, None, "--timeout", "999")
            self.assertEqual(ctx.exception.code, ccs.EXIT_USAGE)


# ------------------------------------------------------- CLI(서브프로세스)

class CliTests(unittest.TestCase):
    def run_cli(self, *argv, timeout=60):
        return subprocess.run(
            [sys.executable, str(TOOL_PATH), *argv],
            capture_output=True, text=True, timeout=timeout, cwd=str(REPO_ROOT))

    def test_blocked_urls_exit_3_without_fetching(self):
        with tempfile.TemporaryDirectory() as tmp:
            cal = write_calendar(Path(tmp), "attack.json", [
                krx_source(url="https://evil.example/x", **{"id": "a"}),
                krx_source(url="https://open.krx.co.kr:8443/x", **{"id": "b"}),
                krx_source(url="http://open.krx.co.kr/x", **{"id": "c"}),
                krx_source(url="https://user:pw@open.krx.co.kr/x", **{"id": "d"}),
            ])
            proc = self.run_cli("--calendars", str(cal), "--timeout", "5")
        self.assertEqual(proc.returncode, 3)
        self.assertEqual(proc.stdout.count("VERDICT=INVALID"), 4)
        self.assertIn("RESULT=INVALID", out := proc.stdout)
        self.assertIn("특별 개장/폐장시간", out)
        self.assertIn("대체하지 않는다", out)

    def test_missing_dir_exit_3(self):
        proc = self.run_cli("--calendars", "/nonexistent-hs-calendar-dir")
        self.assertEqual(proc.returncode, 3)
        self.assertIn("RESULT=INVALID", proc.stdout)

    def test_usage_errors_exit_4(self):
        proc = self.run_cli("--timeout", "not-a-number")
        self.assertEqual(proc.returncode, 4)
        self.assertIn("USAGE ERROR", proc.stderr)
        proc = self.run_cli("--timeout", "0")
        self.assertEqual(proc.returncode, 4)

    def test_help_exits_0_and_documents_allowlist(self):
        proc = self.run_cli("--help")
        self.assertEqual(proc.returncode, 0)
        for host in ("open.krx.co.kr", "global.krx.co.kr"):
            self.assertIn(host, proc.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
