#!/usr/bin/env python3
"""sidecar contract tests (tools/collector/README.md §0-§8).

The real sidecar state machine (sidecar.py) runs in-process against a
fake core pipe (queue-backed stdin, captured stdout) and a fake
websockets module: no live API call, no real network, no credential
value ever printed. The token path is exercised through the real
TokenStore with a seeded local token cache and a fake `kiwoomcli`
executable on PATH, so the subprocess boundary is the real one and only
the credential values are fixtures.

Run: bash tools/collector/test_sidecar.sh — it resolves a Python 3.13
interpreter, bootstraps tools/collector/.venv with requirements.txt,
and runs this module through unittest.
"""

import asyncio
import hashlib
import json
import os
import queue
import sys
import tempfile
import threading
import time
import types
import unittest
import urllib.error
from datetime import datetime, timedelta, timezone
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sidecar  # noqa: E402

TOKEN = "SECRET-TOKEN-VALUE"
FRESH_TOKEN = "REFRESHED-TOKEN"
TOKEN_TYPE = "Bearer"


def kst_now():
    return datetime.now(sidecar.KST)


def approved_cfg():
    """The exact PH-1 approved configuration (README §2.1); tests may
    only shrink the timers through the Sidecar constructor, never these
    pinned values."""
    return {
        "protocol": 1,
        "environment": "demo",
        "rest_domain": sidecar.DEMO_REST_DOMAIN,
        "ws_endpoint": sidecar.DEMO_WS_ENDPOINT,
        "api_id": "ka10027",
        "page_cap": 10,
        "repoll_seconds": 300,
        "drain_seconds": 10,
        "ack_timeout_seconds": 10,
        "watchdog": "15:40:00+09:00",
        "profile": "test-profile",
        "rest_params": {key: "1" for key in sidecar.REST_PARAMS_FIELDS},
    }


def token_cache_path(cache_dir, profile="test-profile"):
    digest = hashlib.sha256(profile.encode("utf-8")).hexdigest()[:16]
    return os.path.join(cache_dir, "kiwoom", "profiles",
                        "profile-%s-token.json" % digest)


def seed_token_cache(cache_dir, token=TOKEN, expires_in=3600.0):
    path = token_cache_path(cache_dir)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"access_token": token, "token_type": TOKEN_TYPE,
                   "expires_at": time.time() + expires_in}, f)
    return path


def install_fake_kiwoomcli(bin_dir, cache_dir, exit_code=0):
    """A fake `kiwoomcli auth refresh` that rewrites the cache like the
    official client would (and only that — it receives no secrets)."""
    path = token_cache_path(cache_dir)
    os.makedirs(bin_dir, exist_ok=True)
    script = os.path.join(bin_dir, "kiwoomcli")
    with open(script, "w", encoding="utf-8") as f:
        f.write("#!/bin/sh\n")
        f.write("cat > '%s' <<'EOF'\n" % path)
        f.write(json.dumps({"access_token": FRESH_TOKEN,
                            "token_type": TOKEN_TYPE,
                            "expires_at": time.time() + 3600.0}) + "\n")
        f.write("EOF\n")
        f.write("exit %d\n" % exit_code)
    os.chmod(script, 0o755)
    return script


class FakeStdin:
    """The core's side of the pipe: queue-backed, iteration for the
    command loop, readline() for the init line."""

    def __init__(self):
        self.q = queue.Queue()

    def readline(self):
        line = self.q.get()
        return "" if line is None else line

    def __iter__(self):
        return self

    def __next__(self):
        line = self.q.get()
        if line is None:
            raise StopIteration
        return line

    def send(self, line):
        self.q.put(line)

    def close(self):
        self.q.put(None)


class Capture:
    """Captured stdout, one JSON line per emit."""

    def __init__(self):
        self.lines = []
        self._buf = ""

    def write(self, s):
        self._buf += s
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            self.lines.append(line)
        return len(s)

    def flush(self):
        pass

    def events(self):
        return [json.loads(line) for line in self.lines]


class FakeFrame:
    def __init__(self, code, reason):
        self.code = code
        self.reason = reason


class FakeConnectionClosed(Exception):
    def __init__(self, rcvd=None):
        super().__init__("connection closed")
        self.rcvd = rcvd


_CLOSE = object()


class FakeWS:
    """One fake wire: records sends, delivers scripted bytes."""

    def __init__(self):
        self.sent = []
        self.inbox = asyncio.Queue()
        self.close_code = None

    def deliver(self, msg):
        self.inbox.put_nowait(msg)

    async def send(self, text):
        self.sent.append(text)

    async def recv(self, decode=None):
        item = await self.inbox.get()
        if item is _CLOSE:
            raise FakeConnectionClosed(FakeFrame(self.close_code or 1000,
                                                 "test close"))
        if decode is False and isinstance(item, str):
            return item.encode("utf-8")
        if decode is True and isinstance(item, bytes):
            return item.decode("utf-8")
        return item

    async def close(self, code=1000):
        self.close_code = code
        self.inbox.put_nowait(_CLOSE)


def quiet_count(evs):
    return sum(1 for e in evs if e.get("ev") == "timer"
               and e.get("kind") == "quiet")


class Harness:
    """One live Sidecar wired to the fake pipe; the test drives commands
    and a fake wire, and asserts on the emitted event lines."""

    def __init__(self, testcase, ack_timeout=0.5, drain=0.2, repoll=3600,
                 watchdog="23:59:59+09:00", token=TOKEN):
        self.testcase = testcase
        self.stdin = FakeStdin()
        self.stdout = Capture()
        self.saved = (sys.stdin, sys.stdout)
        sys.stdin, sys.stdout = self.stdin, self.stdout
        cfg = approved_cfg()
        cfg["watchdog"] = watchdog
        self.cfg = cfg
        self.sc = sidecar.Sidecar(cfg, repoll=repoll, drain=drain,
                                  ack_timeout=ack_timeout)
        self.sc.token = token
        self.sc.token_type = TOKEN_TYPE
        self.task = None
        self.fake_ws = None
        self.connect_calls = []
        self.saved_ws_mod = None

    def close(self):
        sys.stdin, sys.stdout = self.saved

    def send(self, **cmd):
        self.stdin.send(json.dumps(cmd, ensure_ascii=False))

    def events(self):
        return self.stdout.events()

    async def wait_for(self, pred, desc, timeout=5.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            evs = self.stdout.events()
            if pred(evs):
                return evs
            await asyncio.sleep(0.005)
        raise AssertionError("timeout waiting for: %s\nseen:\n%s"
                             % (desc, "\n".join(self.stdout.lines)))

    async def start(self):
        self.task = asyncio.create_task(self.sc.run())
        await self.wait_for(lambda evs: bool(evs) and
                            evs[0].get("ev") == "ready", "the ready event")
        return self

    def attach_fake_websockets(self):
        self.fake_ws = FakeWS()
        mod = types.ModuleType("websockets")
        mod.ConnectionClosed = FakeConnectionClosed

        async def connect(url, ping_interval=None):
            self.connect_calls.append((url, ping_interval))
            return self.fake_ws

        mod.connect = connect
        self.saved_ws_mod = sys.modules.get("websockets")
        sys.modules["websockets"] = mod

    async def login(self):
        """connect + LOGIN ack -> an open connection, generation 1."""
        self.send(type="connect")
        await self.wait_for(lambda evs: bool(self.fake_ws.sent),
                            "the LOGIN frame on the wire")
        self.fake_ws.deliver(json.dumps({"trnm": "LOGIN", "return_code": 0}))
        await self.wait_for(
            lambda evs: any(e.get("ev") == "conn" and e.get("state") == "open"
                            for e in evs),
            "the conn open event")

    async def stop_and_join(self):
        """`stop` -> the documented clean exit code."""
        self.send(type="stop")
        try:
            await self.task
            raise AssertionError("the sidecar did not exit on stop")
        except sidecar.SidecarExit as exc:
            return exc.code


class SidecarContract(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.tmp = tmp
        self.addCleanup(tmp.cleanup)
        self.cache_dir = os.path.join(tmp.name, "cache")
        self.bin_dir = os.path.join(tmp.name, "bin")
        self._patchenv("XDG_CACHE_HOME", self.cache_dir)
        self._saved_path = os.environ.get("PATH")
        self._saved_ws = sys.modules.get("websockets")

    def tearDown(self):
        if self._saved_path is None:
            os.environ.pop("PATH", None)
        else:
            os.environ["PATH"] = self._saved_path
        if self._saved_ws is None:
            sys.modules.pop("websockets", None)
        else:
            sys.modules["websockets"] = self._saved_ws

    async def tearDownAsync(self):
        # Cancel whatever the sidecar still runs (connect loop, timers) so
        # a failed test leaves no destroyed-pending-task noise behind.
        tasks = [t for t in asyncio.all_tasks()
                 if t is not asyncio.current_task()]
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

    def _patchenv(self, key, value):
        old = os.environ.get(key)
        os.environ[key] = value

        def restore():
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old

        self.addCleanup(restore)

    def harness(self, **kwargs):
        h = Harness(self, **kwargs)
        self.addCleanup(h.close)
        return h

    # ------------------------------------------------------------- init

    def test_init_accepts_the_approved_configuration(self):
        cfg = sidecar.parse_init(json.dumps(approved_cfg()))
        self.assertEqual(cfg["profile"], "test-profile")
        self.assertEqual(cfg["api_id"], "ka10027")
        self.assertEqual(sorted(cfg["rest_params"]),
                         sorted(sidecar.REST_PARAMS_FIELDS))

    def test_init_rejects_every_unapproved_value(self):
        def mutate(**changes):
            cfg = approved_cfg()
            for key, value in changes.items():
                if value is None:
                    cfg.pop(key, None)
                else:
                    cfg[key] = value
            return json.dumps(cfg)

        bad_lines = [
            ("protocol", mutate(protocol=2)),
            ("environment", mutate(environment="prod")),
            ("rest_domain", mutate(rest_domain="https://evil.example")),
            ("ws_endpoint", mutate(ws_endpoint="wss://evil.example:10000")),
            ("api_id", mutate(api_id="ka10099")),
            ("page_cap", mutate(page_cap=11)),
            ("repoll_seconds", mutate(repoll_seconds=299)),
            ("drain_seconds", mutate(drain_seconds=11)),
            ("ack_timeout_seconds", mutate(ack_timeout_seconds=9)),
            ("watchdog format", mutate(watchdog="15:40:00")),
            ("watchdog offset", mutate(watchdog="15:40:00+09:30")),
            ("profile empty", mutate(profile="")),
            ("profile spaces", mutate(profile="a b")),
            ("profile too long", mutate(profile="a" * 65)),
            ("api_id absent", mutate(api_id=None)),
            ("rest_params type", mutate(rest_params="x")),
            ("rest_params key",
             mutate(rest_params={k: "1" for k in sidecar.REST_PARAMS_FIELDS
                                 if k != "stex_tp"})),
            ("rest_params value type",
             mutate(rest_params={k: "1" for k in sidecar.REST_PARAMS_FIELDS}
                    | {"mrkt_tp": 0})),
        ]
        for name, line in bad_lines:
            with self.assertRaises(sidecar.SidecarExit) as cm:
                sidecar.parse_init(line)
            self.assertEqual(cm.exception.code, 4, name)
        for bad in ["", "not json", "[1,2]"]:
            with self.assertRaises(sidecar.SidecarExit) as cm:
                sidecar.parse_init(bad)
            self.assertEqual(cm.exception.code, 4)

    def test_watchdog_parse_rejects_malformed_times(self):
        for bad in ["", "15:40", "15:40:00", "15:40:00Z", "154000+09:00",
                    "25:40:00+09:00", "15:61:00+09:00"]:
            with self.assertRaises(sidecar.SidecarExit):
                sidecar.parse_watchdog_seconds(bad)

    # ------------------------------------------------ ready/stop/exit 4

    async def test_ready_then_stop_exits_zero(self):
        h = self.harness()
        await h.start()
        self.assertEqual(h.events()[0]["ev"], "ready")
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_unknown_command_exits_four(self):
        h = self.harness()
        await h.start()
        h.send(type="wat")
        try:
            await h.task
            self.fail("an unknown command must exit, not be ignored")
        except sidecar.SidecarExit as exc:
            self.assertEqual(exc.code, 4)

    async def test_stdin_eof_exits_four(self):
        h = self.harness()
        await h.start()
        h.stdin.close()
        try:
            await h.task
            self.fail("EOF before stop is a broken pipe")
        except sidecar.SidecarExit as exc:
            self.assertEqual(exc.code, 4)

    async def test_reg_without_a_connection_exits_four(self):
        h = self.harness()
        await h.start()
        h.send(type="reg", gen=1, data=[])
        try:
            await h.task
            self.fail("reg with no open connection must exit 4")
        except sidecar.SidecarExit as exc:
            self.assertEqual(exc.code, 4)

    # --------------------------------------------------- connect/LOGIN

    async def test_connect_login_and_ping_echo(self):
        h = self.harness()
        h.attach_fake_websockets()
        await h.start()
        await h.login()
        self.assertEqual(h.connect_calls,
                         [(sidecar.DEMO_WS_ENDPOINT, None)])
        login = json.loads(h.fake_ws.sent[0])
        self.assertEqual(login["trnm"], "LOGIN")
        self.assertEqual(login["token"], TOKEN)

        h.fake_ws.deliver(b"PING")
        evs = await h.wait_for(
            lambda evs: any(e.get("ev") == "ws" and
                            e.get("payload_hex") == b"PING".hex()
                            for e in evs),
            "the PING bytes forwarded as a ws event")
        ws_ev = [e for e in evs if e.get("ev") == "ws"][-1]
        self.assertEqual(ws_ev["conn"], 1)
        self.assertIn("PING", h.fake_ws.sent[-1],
                      "PING echoes verbatim")

        payload = json.dumps(
            {"trnm": "REAL", "data": [{"item": "005930", "type": "0B",
                                       "values": {"10": "10000"}}]}
        ).encode("utf-8")
        h.fake_ws.deliver(payload)
        await h.wait_for(
            lambda evs: any(e.get("ev") == "ws" and
                            e.get("payload_hex") == payload.hex() for e in evs),
            "the 0B payload forwarded byte-exact")

        ping_doc = b'{"trnm":"PING","x":1}'
        h.fake_ws.deliver(ping_doc)
        await h.wait_for(
            lambda evs: any(e.get("ev") == "ws" and
                            e.get("payload_hex") == ping_doc.hex()
                            for e in evs),
            "the PING document forwarded")
        self.assertIn(ping_doc.decode(), h.fake_ws.sent[-1],
                      "a PING object echoes verbatim")

        garbage = b"\xff\xfe not json"
        h.fake_ws.deliver(garbage)
        await h.wait_for(
            lambda evs: any(e.get("ev") == "ws" and
                            e.get("payload_hex") == garbage.hex()
                            for e in evs),
            "non-JSON bytes still forwarded opaque")

        self.assertEqual(await h.stop_and_join(), 0)
        self.assertEqual(h.fake_ws.close_code, 1000)

    async def test_login_auth_code_refreshes_once_and_retries(self):
        h = self.harness(ack_timeout=0.3)
        seed_token_cache(self.cache_dir, token=TOKEN, expires_in=-10.0)
        install_fake_kiwoomcli(self.bin_dir, self.cache_dir)
        os.environ["PATH"] = self.bin_dir + os.pathsep + \
            (self._saved_path or "")
        h.attach_fake_websockets()
        await h.start()
        h.send(type="connect")
        await h.wait_for(lambda evs: bool(h.fake_ws.sent), "LOGIN sent")
        h.fake_ws.deliver(json.dumps({"trnm": "LOGIN", "return_code": 8005}))
        await h.wait_for(
            lambda evs: any(e.get("ev") == "token" for e in evs),
            "the token event after the refresh")
        await h.wait_for(lambda evs: len(h.fake_ws.sent) >= 2,
                         "the retried LOGIN")
        self.assertNotIn(TOKEN, h.fake_ws.sent[1])
        self.assertIn(FRESH_TOKEN, h.fake_ws.sent[1])
        h.fake_ws.deliver(json.dumps({"trnm": "LOGIN", "return_code": 0}))
        await h.wait_for(
            lambda evs: any(e.get("ev") == "conn" and
                            e.get("state") == "open" for e in evs),
            "conn open after the retry")

    async def test_login_ack_numeric_string_opens(self):
        h = self.harness(ack_timeout=0.3)
        h.attach_fake_websockets()
        await h.start()
        h.send(type="connect")
        await h.wait_for(lambda evs: bool(h.fake_ws.sent), "LOGIN sent")
        # The spec schema types return_code as a String while its examples
        # send a number; the official SDK normalizes both forms.
        h.fake_ws.deliver(json.dumps({"trnm": "LOGIN", "return_code": "0"}))
        await h.wait_for(
            lambda evs: any(e.get("ev") == "conn" and
                            e.get("state") == "open" for e in evs),
            "conn open on the numeric-string ack")
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_login_auth_code_embedded_in_return_msg_retries(self):
        h = self.harness(ack_timeout=0.3)
        seed_token_cache(self.cache_dir, token=TOKEN, expires_in=-10.0)
        install_fake_kiwoomcli(self.bin_dir, self.cache_dir)
        os.environ["PATH"] = self.bin_dir + os.pathsep + \
            (self._saved_path or "")
        h.attach_fake_websockets()
        await h.start()
        h.send(type="connect")
        await h.wait_for(lambda evs: bool(h.fake_ws.sent), "LOGIN sent")
        # A generic top-level code with the specific one embedded in
        # return_msg — the pattern the official SDK documents and matches.
        h.fake_ws.deliver(json.dumps({
            "trnm": "LOGIN", "return_code": "3",
            "return_msg": "CODE=8005:Token invalid"}))
        await h.wait_for(
            lambda evs: any(e.get("ev") == "token" for e in evs),
            "the token event after the refresh")
        await h.wait_for(lambda evs: len(h.fake_ws.sent) >= 2,
                         "the retried LOGIN")
        self.assertNotIn(TOKEN, h.fake_ws.sent[1])
        self.assertIn(FRESH_TOKEN, h.fake_ws.sent[1])
        h.fake_ws.deliver(json.dumps({"trnm": "LOGIN", "return_code": 0}))
        await h.wait_for(
            lambda evs: any(e.get("ev") == "conn" and
                            e.get("state") == "open" for e in evs),
            "conn open after the retry")

    async def test_login_ack_non_numeric_code_fails_closed(self):
        h = self.harness(ack_timeout=0.2)
        h.attach_fake_websockets()
        await h.start()
        h.send(type="connect")
        await h.wait_for(lambda evs: bool(h.fake_ws.sent), "LOGIN sent")
        h.fake_ws.deliver(json.dumps({"trnm": "LOGIN", "return_code": "OK"}))
        await h.wait_for(
            lambda evs: any(e.get("ev") == "conn" and
                            e.get("state") == "closed_error" and
                            "return_code='OK'" in e.get("reason", "")
                            for e in evs),
            "a non-numeric code is a closed_error, never a success")
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_login_failure_reports_closed_error(self):
        h = self.harness(ack_timeout=0.2)
        h.attach_fake_websockets()
        await h.start()
        h.send(type="connect")
        await h.wait_for(lambda evs: bool(h.fake_ws.sent), "LOGIN sent")
        h.fake_ws.deliver(json.dumps({"trnm": "LOGIN", "return_code": 1}))
        await h.wait_for(
            lambda evs: any(e.get("ev") == "conn" and
                            e.get("state") == "closed_error" and
                            "return_code=1" in e.get("reason", "")
                            for e in evs),
            "the login failure as conn closed_error")
        self.assertEqual(h.fake_ws.close_code, 1000)
        self.assertEqual(await h.stop_and_join(), 0)

    # --------------------------------------------------- reg/remove/quiet

    async def test_reg_envelope_and_quiet_disarm_cycle(self):
        h = self.harness(ack_timeout=0.15)
        h.attach_fake_websockets()
        await h.start()
        await h.login()

        # Received traffic alone never arms the window: the quiet timer is
        # the REG/REMOVE ack expectation (README §2.3).
        await asyncio.sleep(0.25)
        self.assertEqual(quiet_count(h.events()), 0)

        data = [{"item": ["005930", "000660"], "type": ["0B"]}]
        h.send(type="reg", gen=1, data=data)
        await h.wait_for(lambda evs: quiet_count(evs) >= 1,
                         "the quiet window the reg armed")
        envelope = json.loads(h.fake_ws.sent[-1])
        self.assertEqual(envelope, {"trnm": "REG", "grp_no": "1",
                                    "refresh": "1", "data": data})

        # A second reg re-arms; disarm cancels it before it can fire.
        h.send(type="reg", gen=2, data=data)
        h.send(type="disarm")
        await asyncio.sleep(0.35)
        self.assertEqual(quiet_count(h.events()), 1,
                         "disarm cancels the quiet window")

        self.assertEqual(await h.stop_and_join(), 0)

    async def test_remove_envelope_has_no_refresh(self):
        h = self.harness()
        h.attach_fake_websockets()
        await h.start()
        await h.login()
        data = [{"item": ["005930"], "type": ["0B"]}]
        h.send(type="remove", gen=2, data=data)
        await h.wait_for(lambda evs: len(h.fake_ws.sent) >= 2,
                         "the REMOVE frame on the wire")
        envelope = json.loads(h.fake_ws.sent[-1])
        self.assertEqual(envelope, {"trnm": "REMOVE", "grp_no": "1",
                                    "data": data})
        self.assertEqual(await h.stop_and_join(), 0)

    # ---------------------------------------------------------------- rest

    async def test_rest_req_reports_the_raw_response(self):
        h = self.harness()
        await h.start()
        captured = {}

        class FakeResp:
            status = 200

            def __init__(self):
                self.headers = {"cont-yn": "Y", "next-key": "abc123"}

            def read(self):
                return b'{"pred_pre_flu_rt_upper":[],"return_code":0}'

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def fake_urlopen(req, timeout=None):
            captured["req"] = req
            captured["timeout"] = timeout
            return FakeResp()

        with mock.patch("urllib.request.urlopen", fake_urlopen):
            h.send(type="rest_req", direction="up", page=1,
                   cont_yn="", next_key="")
            evs = await h.wait_for(
                lambda evs: any(e.get("ev") == "rest" for e in evs),
                "the rest event")

        rest = [e for e in evs if e.get("ev") == "rest"][-1]
        self.assertEqual(rest["direction"], "up")
        self.assertEqual(rest["page"], 1)
        self.assertEqual(rest["status"], 200)
        self.assertEqual(rest["cont_yn"], "Y")
        self.assertEqual(rest["next_key"], "abc123")
        self.assertEqual(rest["body_hex"],
                         b'{"pred_pre_flu_rt_upper":[],"return_code":0}'
                         .hex())

        req = captured["req"]
        self.assertEqual(req.full_url,
                         sidecar.DEMO_REST_DOMAIN + sidecar.REST_PATH)
        self.assertEqual(req.headers.get("Api-id"), "ka10027")
        self.assertEqual(req.headers.get("Authorization"),
                         "Bearer " + TOKEN)
        body = json.loads(req.data.decode("utf-8"))
        self.assertEqual(body["sort_tp"], "1")
        self.assertEqual(captured["timeout"], 30)
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_rest_req_down_uses_sort_tp_3(self):
        h = self.harness()
        await h.start()
        captured = {}

        class FakeResp:
            status = 200
            headers = {}

            def read(self):
                return b"{}"

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def fake_urlopen(req, timeout=None):
            captured["req"] = req
            return FakeResp()

        with mock.patch("urllib.request.urlopen", fake_urlopen):
            h.send(type="rest_req", direction="down", page=2,
                   cont_yn="Y", next_key="k1")
            await h.wait_for(
                lambda evs: any(e.get("ev") == "rest" for e in evs),
                "the rest event")

        body = json.loads(captured["req"].data.decode("utf-8"))
        self.assertEqual(body["sort_tp"], "3")
        self.assertEqual(captured["req"].headers.get("Cont-yn"), "Y")
        self.assertEqual(captured["req"].headers.get("Next-key"), "k1")
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_rest_http_error_is_still_a_response(self):
        h = self.harness()
        await h.start()

        def fake_urlopen(req, timeout=None):
            raise urllib.error.HTTPError("http://test", 401, "unauthorized",
                                         {"cont-yn": "", "next-key": ""},
                                         None)

        with mock.patch("urllib.request.urlopen", fake_urlopen):
            h.send(type="rest_req", direction="up", page=1)
            evs = await h.wait_for(
                lambda evs: any(e.get("ev") == "rest" for e in evs),
                "the 401 as a rest event, not an error")
        rest = [e for e in evs if e.get("ev") == "rest"][-1]
        self.assertEqual(rest["status"], 401)
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_rest_transport_failure_is_an_error_event(self):
        h = self.harness()
        await h.start()

        def fake_urlopen(req, timeout=None):
            raise ConnectionRefusedError("no route")

        with mock.patch("urllib.request.urlopen", fake_urlopen):
            h.send(type="rest_req", direction="up", page=1)
            evs = await h.wait_for(
                lambda evs: any(e.get("ev") == "error" and
                                e.get("what") == "rest" for e in evs),
                "the transport failure as error what=rest")
        err = [e for e in evs if e.get("ev") == "error"][-1]
        self.assertTrue(err["detail"].startswith("transport failed"))
        self.assertEqual(await h.stop_and_join(), 0)

    # --------------------------------------------------------- drain etc.

    async def test_wait_drain_reports_drain_done(self):
        h = self.harness(drain=0.2)
        await h.start()
        h.send(type="wait_drain")
        await h.wait_for(
            lambda evs: any(e.get("ev") == "drain_done" for e in evs),
            "the drain_done event")
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_watchdog_in_the_past_fires_immediately(self):
        past = (kst_now() - timedelta(hours=1)).strftime("%H:%M:%S+09:00")
        h = self.harness(watchdog=past)
        await h.start()
        await h.wait_for(
            lambda evs: any(e.get("ev") == "timer" and
                            e.get("kind") == "watchdog" for e in evs),
            "the watchdog event")

    # ------------------------------------------------------------- token

    def test_token_cache_hit_needs_no_subprocess(self):
        seed_token_cache(self.cache_dir, token=TOKEN)
        os.environ["PATH"] = "/nonexistent"
        store = sidecar.TokenStore("test-profile")
        self.assertEqual(store.get(), (TOKEN, TOKEN_TYPE))

    def test_token_expired_cache_refreshes_through_the_client(self):
        seed_token_cache(self.cache_dir, token=TOKEN, expires_in=-10.0)
        install_fake_kiwoomcli(self.bin_dir, self.cache_dir)
        os.environ["PATH"] = self.bin_dir + os.pathsep + \
            (self._saved_path or "")
        store = sidecar.TokenStore("test-profile")
        self.assertEqual(store.get(), (FRESH_TOKEN, TOKEN_TYPE))

    def test_token_refresh_failure_raises_without_leaking_values(self):
        seed_token_cache(self.cache_dir, token=TOKEN, expires_in=-10.0)
        install_fake_kiwoomcli(self.bin_dir, self.cache_dir, exit_code=3)
        os.environ["PATH"] = self.bin_dir + os.pathsep + \
            (self._saved_path or "")
        store = sidecar.TokenStore("test-profile")
        with self.assertRaises(sidecar.TokenError) as cm:
            store.get()
        self.assertNotIn(TOKEN, str(cm.exception))
        self.assertNotIn(FRESH_TOKEN, str(cm.exception))

    def test_token_without_cache_or_client_fails_closed(self):
        os.environ["PATH"] = "/nonexistent"
        store = sidecar.TokenStore("test-profile")
        with self.assertRaises(sidecar.TokenError):
            store.get()

    def test_main_exits_three_when_the_token_path_fails(self):
        h = self.harness()
        os.environ["PATH"] = "/nonexistent"
        h.send(**approved_cfg())  # the init line
        result = {}

        def run_main():
            result["code"] = sidecar.main()

        thread = threading.Thread(target=run_main)
        thread.start()
        thread.join(timeout=10)
        self.assertFalse(thread.is_alive(), "main did not return")
        self.assertEqual(result["code"], 3)
        evs = h.events()
        self.assertTrue(any(e.get("ev") == "error" and
                            e.get("what") == "token" for e in evs))

    # ---------------------------------------------------------- privacy

    async def test_no_token_value_ever_reaches_the_pipe(self):
        h = self.harness()
        h.attach_fake_websockets()
        await h.start()
        await h.login()
        h.fake_ws.deliver(b"PING")
        await h.wait_for(
            lambda evs: any(e.get("payload_hex") == b"PING".hex()
                            for e in evs), "a forwarded payload")
        h.send(type="reg", gen=1,
               data=[{"item": ["005930"], "type": ["0B"]}])
        await h.wait_for(lambda evs: len(h.fake_ws.sent) >= 2,
                         "the REG frame")

        def refused(req, timeout=None):
            raise ConnectionRefusedError("offline by construction")

        with mock.patch("urllib.request.urlopen", refused):
            h.send(type="rest_req", direction="up", page=1)
            await h.wait_for(
                lambda evs: any(e.get("ev") == "error" and
                                e.get("what") == "rest" for e in evs),
                "the refused rest attempt reported as an error event")
        self.assertEqual(await h.stop_and_join(), 0)
        joined = "\n".join(h.stdout.lines)
        self.assertNotIn(TOKEN, joined)
        self.assertNotIn(FRESH_TOKEN, joined)
        self.assertNotIn("Bearer", joined)


if __name__ == "__main__":
    unittest.main()
