"""Fake ``websockets`` package for the process-pair drill.

The real sidecar (tools/collector/sidecar.py) imports ``websockets`` and
uses exactly this surface: ``connect(uri, ping_interval=None)`` ->
connection with ``send(text)`` / ``recv(decode=False)`` / ``close(code)``
and a ``ConnectionClosed`` exception carrying ``rcvd.code``/``rcvd.reason``
(REPLAY_CONTRACT §12.2: ``recv(decode=False)`` application payload bytes).

This file stands in for the Kiwoom demo WS server. Every scripted
response cites its source in tools/collector/drill/fakesite/
drill_fixtures.py (README §2.2/§2.3/§9/§12.7). No network, no credential
value is ever logged or echoed here.
"""

import asyncio
import json

import drill_fixtures as fx

_CLOSE = object()

# The 0B REG is the second REG the core sends (README §6.2: 0s REG ->
# initial REST -> candidate 0B REG). After acking it the fake pushes the
# scripted stream: PING, 0B ticks (in-session, ascending FID 20 per
# code), then the 0s close-evidence frame (FID 215 "4" = 장마감).
_TICK_SCRIPT = [
    fx.tick_0b(fx.UP_CODE, "090500", "10000", 100),
    fx.tick_0b(fx.UP_CODE, "090630", "10200", 150),
    fx.tick_0b(fx.DOWN_CODE, "090530", "20000", 200),
    fx.tick_0b(fx.DOWN_CODE, "090700", "19900", 260),
]
_CLOSE_FRAME_215 = "4"  # README §9 FID 215 값표: 4 장마감(15:30)


class ConnectionClosed(Exception):
    """Same name/surface as websockets.ConnectionClosed; ``rcvd`` carries
    the server close frame (code/reason) or None (sidecar.py serve)."""

    def __init__(self, rcvd=None, rcvd_is_none=False):
        super().__init__("connection closed")
        self.rcvd = None if rcvd_is_none else rcvd


class _CloseFrame:
    def __init__(self, code, reason):
        self.code = code
        self.reason = reason


class FakeConnection:
    """One simulated wire: reactive acks plus the scripted stream."""

    def __init__(self, uri, ping_interval, log):
        self.uri = uri
        self.ping_interval = ping_interval
        self._log = log
        self.inbox = asyncio.Queue()
        self.close_code = None
        self.reg_acks = 0
        if log:
            log(ev="ws_connect", uri=uri, ping_interval=ping_interval)

    async def send(self, text):
        """Server side of the wire: react exactly as the scripted server
        would. The LOGIN send carries the token — its value is never
        logged (README §5: 토큰 값은 어디에도 출력되지 않는다)."""
        stripped = text.strip() if isinstance(text, str) else ""
        try:
            doc = json.loads(text)
            trnm = doc.get("trnm") if isinstance(doc, dict) else None
        except ValueError:
            # The keep-alive echo is the one send that is not JSON: the
            # sidecar answers the server's b"PING" with the literal text
            # (sidecar.py send_text, README §4/§12.7) — treat it as the
            # scripted echo, everything else non-JSON stays unexpected.
            trnm = "PING" if stripped == "PING" else None
        if self._log:
            self._log(ev="ws_send", trnm=trnm)
        if trnm == "LOGIN":
            self.inbox.put_nowait(fx.ack("LOGIN"))
        elif trnm == "REG":
            self.reg_acks += 1
            self.inbox.put_nowait(fx.ack("REG"))
            if self._log:
                self._log(ev="ws_deliver", trnm="REG", n=self.reg_acks)
            if self.reg_acks == 2:
                # The candidate 0B REG is confirmed: stream the scripted
                # traffic, then the close evidence (README §6.2/§8).
                self.inbox.put_nowait(b"PING")
                if self._log:
                    self._log(ev="ws_deliver", trnm="PING")
                for frame in _TICK_SCRIPT:
                    self.inbox.put_nowait(frame)
                if self._log:
                    self._log(ev="ws_deliver", trnm="REAL", type="0B",
                              frames=len(_TICK_SCRIPT))
                self.inbox.put_nowait(fx.state_0s(_CLOSE_FRAME_215))
                if self._log:
                    self._log(ev="ws_deliver", trnm="REAL", type="0s",
                              value215=_CLOSE_FRAME_215)
        elif trnm == "REMOVE":
            self.inbox.put_nowait(fx.ack("REMOVE"))
            if self._log:
                self._log(ev="ws_deliver", trnm="REMOVE")
        elif trnm == "PING":
            # The client's echo of our b"PING" probe (README §12.7): the
            # observed keep-alive echo, recorded in the wire log only —
            # the echo send itself has no record duty (README §3.3).
            if self._log:
                self._log(ev="ws_deliver", trnm="PING", echo=True)
        else:
            raise AssertionError("unexpected client wire send: %r" % trnm)

    async def recv(self, decode=False):
        item = await self.inbox.get()
        if item is _CLOSE:
            raise ConnectionClosed(
                _CloseFrame(self.close_code or 1000, "drill close"))
        if decode is False and isinstance(item, str):
            return item.encode("utf-8")
        return item

    async def close(self, code=1000):
        # README §2.6: stop closes the wire with code 1000.
        self.close_code = code
        if self._log:
            self._log(ev="ws_close", code=code)
        self.inbox.put_nowait(_CLOSE)


async def connect(uri, ping_interval=None, **kwargs):
    """The single entry the sidecar uses (sidecar.py connect_loop).
    Anything other than the official demo endpoint is a drill setup bug
    (README §2.1: demo 엔드포인트 고정)."""
    expected = "wss://mockapi.kiwoom.com:10000"
    if uri != expected:
        raise AssertionError("drill fake: unexpected WS endpoint %r" % uri)
    return FakeConnection(uri, ping_interval, fx.wirelog())
