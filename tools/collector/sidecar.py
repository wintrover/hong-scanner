#!/usr/bin/env python3
"""sidecar: the VS-2 live collector's communication process.

Contract: tools/collector/README.md (the committed pipe-protocol contract).
This process is COMMUNICATION ONLY: it owns the WebSocket connection, the
REST transport, its own clock (the events' "t"), the token lifetime and
nothing else. Channel discrimination (REG/REAL/0B/0s/...), REG/REMOVE ack
pairing, candidate derivation and the termination verdict are all the Nim
core's authority (README §0): every application payload is forwarded as
opaque bytes, every judgment is left to the core.

The three discriminations this process does make (README §4, all of them):
  1. Kiwoom PING — received bytes that trim to exactly "PING" or parse to
     {"trnm":"PING"} are echoed verbatim; every received message is still
     forwarded as a ws event.
  2. LOGIN — one handshake per connection; an auth-class ack
     ({8005, 8031, 8103}) triggers one token refresh and one retry, the
     same strategy as the official SDK.
  3. Token expiry — the cache's expires_at is the only expiry evidence;
     600 s buffer, re-read after `kiwoomcli auth refresh --profile <alias>`.
     Token values exist only in process memory: nothing prints them.

Wire discipline (README §1): line-delimited UTF-8 JSON over stdin/stdout,
one object per line. Every emitted line is HCJ-safe (string/int values
only). No float ever crosses the pipe. A broken stdout pipe is exit 4.

Exit codes (README §8): 0 normal (after `stop`), 3 token failure,
4 internal fault / broken pipe / unknown command.
"""

import asyncio
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

PROTOCOL = 1
KST = timezone(timedelta(hours=9))
DEMO_REST_DOMAIN = "https://mockapi.kiwoom.com"
DEMO_WS_ENDPOINT = "wss://mockapi.kiwoom.com:10000"
REST_PATH = "/api/dostk/rkinfo"
TOKEN_BUFFER_SECONDS = 600
# The auth-class LOGIN ack codes (README §2.2): one refresh + one retry.
LOGIN_RETRY_CODES = {8005, 8031, 8103}
# The official SDK's embedded-code rule (kiwoom/core/errors.py): Kiwoom
# often reports a generic top-level return_code and puts the specific code
# inside return_msg as "[8005:...]" (REST) or "CODE=8005" (WebSocket). The
# auth-class codes are matched in both places.
EMBEDDED_CODE_RE = re.compile(r"\[(\d{3,5}):|CODE=(\d{3,5})")
SORT_TP = {"up": "1", "down": "3"}
REST_PARAMS_FIELDS = [
    "mrkt_tp", "trde_qty_cnd", "stk_cnd", "crd_cnd", "updown_incls",
    "pric_cnd", "trde_prica_cnd", "stex_tp"]


def normalize_return_code(value):
    """The official SDK's rule (kiwoom/core/errors.py): the server emits
    return_code as an int or a numeric string ("0", "0000", "8005")
    depending on the endpoint. None/bool/blank/non-numeric mean no code."""
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    text = str(value).strip()
    if not text or not text.lstrip("-").isdigit():
        return None
    return int(text)


def embedded_return_code(return_msg):
    """The specific code embedded in a Kiwoom return_msg, if any."""
    match = EMBEDDED_CODE_RE.search(str(return_msg or ""))
    if match is None:
        return None
    return int(match.group(1) or match.group(2))


class SidecarExit(Exception):
    """Clean shutdown with an exit code (0 normal, 3 token, 4 internal)."""

    def __init__(self, code, detail=""):
        super().__init__(detail or str(code))
        self.code = code
        self.detail = detail


class TokenError(Exception):
    """The token path failed. The detail never carries a token value."""


def now_iso():
    """The sidecar-owned clock: ISO 8601 with the numeric KST offset."""
    return datetime.now(KST).strftime("%Y-%m-%dT%H:%M:%S+09:00")


def parse_watchdog_seconds(text):
    """"HH:MM:SS+09:00" -> the epoch second of its next occurrence (KST).

    A moment already past today fires immediately: a session that starts
    after the watchdog must end INCOMPLETE, not run on to a silent close.
    """
    if len(text) != 14 or text[2] != ":" or text[5] != ":" or \
       text[8:] != "+09:00":
        raise SidecarExit(4, "watchdog is not HH:MM:SS+09:00: " + text)
    hh, mm, ss = int(text[0:2]), int(text[3:5]), int(text[6:8])
    if hh > 23 or mm > 59 or ss > 59:
        raise SidecarExit(4, "watchdog is outside plausible ranges: " + text)
    now = datetime.now(KST)
    target = now.replace(hour=hh, minute=mm, second=ss, microsecond=0)
    return target.timestamp()


def parse_init(line):
    """Validate the `init` instruction (README §2.1). Every field is
    required; the approved PH-1 values are pinned here too — this sidecar
    refuses to run a configuration the contract does not approve."""
    try:
        cfg = json.loads(line)
    except ValueError:
        raise SidecarExit(4, "init line is not valid JSON")
    if not isinstance(cfg, dict):
        raise SidecarExit(4, "init line is not a JSON object")
    if cfg.get("protocol") != PROTOCOL:
        raise SidecarExit(4, "init protocol must be 1")
    if cfg.get("environment") != "demo":
        raise SidecarExit(4, "this slice runs the demo environment only")
    if cfg.get("rest_domain") != DEMO_REST_DOMAIN:
        raise SidecarExit(4, "rest_domain is not the official demo domain")
    if cfg.get("ws_endpoint") != DEMO_WS_ENDPOINT:
        raise SidecarExit(4, "ws_endpoint is not the official demo endpoint")
    if cfg.get("api_id") != "ka10027":
        raise SidecarExit(4, "api_id must be ka10027")
    for key, want in [("page_cap", 10), ("repoll_seconds", 300),
                      ("drain_seconds", 10), ("ack_timeout_seconds", 10)]:
        if cfg.get(key) != want:
            raise SidecarExit(4, "init %s must be the approved value %d"
                              % (key, want))
    if cfg.get("watchdog") != "15:40:00+09:00":
        raise SidecarExit(4, "init watchdog must be the approved 15:40 KST")
    profile = cfg.get("profile")
    if not isinstance(profile, str) or not 1 <= len(profile) <= 64 or \
       any(c.isspace() for c in profile):
        raise SidecarExit(4, "profile alias must be 1..64 non-space chars")
    params = cfg.get("rest_params")
    if not isinstance(params, dict):
        raise SidecarExit(4, "init rest_params must be an object")
    for key in REST_PARAMS_FIELDS:
        if not isinstance(params.get(key), str):
            raise SidecarExit(4, "init rest_params.%s must be a string" % key)
    return cfg


class TokenStore:
    """The credential path (README §5): read the kiwoomcli token cache,
    refresh through `kiwoomcli auth refresh` as a subprocess, re-read.
    appkey/secretkey never enter this process; access_token never leaves
    process memory (no log, no stderr, no record, no exit report)."""

    def __init__(self, profile):
        self.profile = profile
        digest = hashlib.sha256(profile.encode("utf-8")).hexdigest()[:16]
        base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
        self.cache_path = os.path.join(
            base, "kiwoom", "profiles", "profile-%s-token.json" % digest)

    def _read(self):
        """Parse the cache file. Returns (access_token, token_type,
        expires_epoch) or None when unreadable/absent — the caller treats
        None as 'expired' (fail-closed), never as a usable token."""
        try:
            with open(self.cache_path, "r", encoding="utf-8") as f:
                doc = json.load(f)
        except (OSError, ValueError):
            return None
        if not isinstance(doc, dict):
            return None
        token = doc.get("access_token")
        if not isinstance(token, str) or not token:
            return None
        token_type = doc.get("token_type")
        if not isinstance(token_type, str):
            token_type = "Bearer"
        expires = doc.get("expires_at")
        if isinstance(expires, (int, float)) and not isinstance(expires, bool):
            expires_epoch = float(expires)
        elif isinstance(expires, str):
            try:
                expires_epoch = datetime.fromisoformat(expires).timestamp()
            except ValueError:
                return None
        else:
            return None
        return (token, token_type, expires_epoch)

    def _refresh(self):
        """Reissue through the official client. Its output is captured and
        discarded (it is not this process's evidence and might name the
        profile); only the exit code is interpreted."""
        try:
            proc = subprocess.run(
                ["kiwoomcli", "auth", "refresh", "--profile", self.profile],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            raise TokenError("token refresh subprocess failed")
        if proc.returncode != 0:
            raise TokenError("token refresh failed rc=%d" % proc.returncode)

    def get(self, force=False):
        """A token whose remaining life exceeds the 600 s buffer, refreshing
        once when not. Raises TokenError (no token value in any message)."""
        entry = self._read()
        if force or entry is None or \
           entry[2] - time.time() <= TOKEN_BUFFER_SECONDS:
            self._refresh()
            entry = self._read()
            if entry is None or \
               entry[2] - time.time() <= TOKEN_BUFFER_SECONDS:
                raise TokenError("token cache unusable after refresh")
        return entry[0], entry[1]


class Sidecar:
    """One collector session's communication state machine."""

    def __init__(self, cfg, repoll=300, drain=10, ack_timeout=10):
        self.cfg = cfg
        self.ws_endpoint = cfg["ws_endpoint"]
        self.rest_domain = cfg["rest_domain"]
        self.api_id = cfg["api_id"]
        self.rest_params = cfg["rest_params"]
        self.store = TokenStore(cfg["profile"])
        # Durations are constructor parameters so the contract tests can
        # shrink them; parse_init pins the approved live values.
        self.repoll = repoll
        self.drain = drain
        self.ack_timeout = ack_timeout
        self.watchdog_text = cfg["watchdog"]
        self.token = None
        self.token_type = "Bearer"
        self.conn_gen = 0
        self.ws = None
        self.ws_task = None
        self.quiet_task = None
        self.draining = False
        self.stopping = False
        self.out_lock = threading.Lock()
        self.first_open = asyncio.Event()

    # ---------------------------------------------------------- wire out

    def emit(self, ev):
        """One HCJ-safe event line on stdout. Token values never enter ev.
        A broken pipe is the core dying first: exit 4 (README §2.6)."""
        ev["t"] = now_iso()
        line = json.dumps(ev, ensure_ascii=False, separators=(",", ":"))
        try:
            with self.out_lock:
                sys.stdout.write(line + "\n")
                sys.stdout.flush()
        except (BrokenPipeError, OSError):
            os._exit(4)

    # ------------------------------------------------------ token path

    def acquire_token(self, force=False):
        token, token_type = self.store.get(force=force)
        self.token = token
        self.token_type = token_type or "Bearer"

    # ----------------------------------------------------- ws connection

    async def connect_loop(self):
        """The single connection-maintenance loop (README §2.2): connect,
        LOGIN handshake, report `conn open` (generation 1 upward), serve
        until the wire closes, report `closed_*`, retry after
        ack_timeout_seconds — forever, until `stop`."""
        import websockets
        while not self.stopping:
            try:
                ws = await websockets.connect(
                    self.ws_endpoint, ping_interval=None)
            except Exception as exc:
                self.emit({
                    "ev": "conn", "state": "closed_error",
                    "conn": self.conn_gen + 1, "code": 1006,
                    "reason": "connect failed: " + type(exc).__name__})
                await asyncio.sleep(self.ack_timeout)
                continue
            opened = await self.handshake(ws)
            if not opened:
                try:
                    await ws.close(code=1000)
                except Exception:
                    pass
                await asyncio.sleep(self.ack_timeout)
                continue
            self.conn_gen += 1
            self.ws = ws
            self.first_open.set()
            self.emit({"ev": "conn", "state": "open",
                             "conn": self.conn_gen})
            code, reason = await self.serve(ws, self.conn_gen)
            self.ws = None
            state = "closed_ok" if code == 1000 else "closed_error"
            self.emit({"ev": "conn", "state": state,
                             "conn": self.conn_gen,
                             "code": code, "reason": reason})
            if self.stopping:
                return
            await asyncio.sleep(self.ack_timeout)

    async def handshake(self, ws):
        """LOGIN (README §2.2): one send, await the ack. An auth-class
        code triggers one refresh + one retry. Other received messages are
        forwarded untouched — nothing is dropped while waiting."""
        for attempt in (0, 1):
            try:
                await ws.send(json.dumps(
                    {"trnm": "LOGIN", "token": self.token},
                    ensure_ascii=False, separators=(",", ":")))
                while True:
                    raw = await asyncio.wait_for(
                        ws.recv(decode=False), timeout=self.ack_timeout)
                    data = bytes(raw)
                    await self.forward(data, self.conn_gen + 1)
                    try:
                        doc = json.loads(data.decode("utf-8"))
                    except (UnicodeDecodeError, ValueError):
                        continue
                    if not isinstance(doc, dict) or \
                       doc.get("trnm") != "LOGIN" or \
                       "return_code" not in doc:
                        continue
                    code = normalize_return_code(doc.get("return_code"))
                    if code is None:
                        # Present, but in no form the official sources
                        # document (int or canonical numeric string, the
                        # SDK's normalize_return_code rule): fail-closed,
                        # never a silent success.
                        self.emit({
                            "ev": "conn", "state": "closed_error",
                            "conn": self.conn_gen + 1, "code": 1000,
                            "reason": "login failed return_code=%r" %
                                      (doc.get("return_code"),)})
                        return False
                    if code == 0:
                        return True
                    if attempt == 0 and (code in LOGIN_RETRY_CODES or
                                         embedded_return_code(
                                             doc.get("return_msg"))
                                         in LOGIN_RETRY_CODES):
                        try:
                            self.acquire_token(force=True)
                            self.emit({"ev": "token"})
                        except TokenError as exc:
                            self.emit({
                                "ev": "error", "what": "token",
                                "detail": exc.args[0]})
                        break  # retry the handshake once
                    self.emit({
                        "ev": "conn", "state": "closed_error",
                        "conn": self.conn_gen + 1, "code": 1000,
                        "reason": "login failed return_code=%s" % code})
                    return False
            except (asyncio.TimeoutError, asyncio.IncompleteReadError,
                    Exception) as exc:
                # A wire failure during the handshake: report and retry.
                self.emit({
                    "ev": "conn", "state": "closed_error",
                    "conn": self.conn_gen + 1, "code": 1006,
                    "reason": "login handshake failed: " +
                              type(exc).__name__})
                return False
        self.emit({
            "ev": "conn", "state": "closed_error", "conn": self.conn_gen + 1,
            "code": 1000, "reason": "login failed after refresh+retry"})
        return False

    async def serve(self, ws, gen):
        """The receive loop of one opened connection: forward every
        application payload as opaque bytes, echo PING, keep the quiet
        timer honest. Returns the close (code, reason)."""
        import websockets
        try:
            while True:
                raw = await ws.recv(decode=False)
                data = bytes(raw)
                await self.forward(data, gen)
                if data.strip() == b"PING":
                    self.send_text(ws, data.decode("utf-8"))
                    continue
                try:
                    doc = json.loads(data.decode("utf-8"))
                except (UnicodeDecodeError, ValueError):
                    doc = None
                if isinstance(doc, dict) and doc.get("trnm") == "PING":
                    self.send_text(ws, data.decode("utf-8"))
        except websockets.ConnectionClosed as e:
            frame = e.rcvd
            if frame is not None:
                return frame.code, frame.reason
            return 1006, "no close frame"
        except Exception as exc:
            return 1006, "recv failed: " + type(exc).__name__

    def send_text(self, ws, text):
        """Fire-and-forget text send on the running loop; a failure is
        reported as error what=send (README §3.6) and the connection
        machinery handles the dead wire."""
        async def _send():
            try:
                await ws.send(text)
            except Exception as exc:
                self.emit({"ev": "error", "what": "send",
                                 "detail": "send failed: " +
                                           type(exc).__name__})
        asyncio.get_running_loop().create_task(_send())

    async def forward(self, data, gen):
        """Every received application payload, byte-exact, opaque (README
        §3.3). Receipt also resets the quiet window (README §2.3)."""
        self.emit({"ev": "ws", "conn": gen,
                         "payload_hex": data.hex()})
        if self.quiet_task is not None:
            self.arm_quiet()

    # ------------------------------------------------------ quiet timer

    def arm_quiet(self):
        self.disarm_quiet()
        self.quiet_task = asyncio.get_running_loop().create_task(
            self._quiet_fire())

    def disarm_quiet(self):
        if self.quiet_task is not None:
            self.quiet_task.cancel()
            self.quiet_task = None

    async def _quiet_fire(self):
        await asyncio.sleep(self.ack_timeout)
        self.quiet_task = None
        self.emit({"ev": "timer", "kind": "quiet"})

    # ----------------------------------------------------- poll/watchdog

    async def poll_timer(self):
        """repoll_seconds after the first conn open, then on cadence
        (README §3.4) — the signal to start a re-poll, nothing more."""
        await self.first_open.wait()
        while not self.stopping:
            await asyncio.sleep(self.repoll)
            self.emit({"ev": "timer", "kind": "poll"})

    async def watchdog_timer(self):
        """One-shot at the watchdog wall-clock time (README §3.4)."""
        delay = parse_watchdog_seconds(self.watchdog_text) - time.time()
        if delay > 0:
            await asyncio.sleep(delay)
        if not self.stopping:
            self.emit({"ev": "timer", "kind": "watchdog"})

    # ------------------------------------------------------------ REST

    def do_rest(self, direction, cont_yn, next_key):
        """One ka10027 page request on the caller's executor thread.
        The response is reported raw — status, response cont-yn/next-key
        headers, body bytes hex — whatever the status (README §2.4). A
        transport failure (no HTTP response at all) is error what=rest."""
        body = dict(self.rest_params)
        body["sort_tp"] = SORT_TP[direction]
        data = json.dumps(body, ensure_ascii=False,
                          separators=(",", ":")).encode("utf-8")
        headers = {
            "Content-Type": "application/json;charset=utf-8",
            "api-id": self.api_id,
            "authorization": ("%s %s" % (self.token_type, self.token)).strip(),
        }
        if cont_yn == "Y":
            headers["cont-yn"] = "Y"
        if next_key:
            headers["next-key"] = next_key
        req = urllib.request.Request(
            self.rest_domain + REST_PATH, data=data, headers=headers,
            method="POST")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return (resp.status, resp.headers.get("cont-yn") or "",
                        resp.headers.get("next-key") or "", resp.read())
        except urllib.error.HTTPError as e:
            # An HTTP response with an error status is still a response:
            # the core owns the verdict (401 included).
            try:
                body = e.read()
                cont = e.headers.get("cont-yn") or ""
                key = e.headers.get("next-key") or ""
            except Exception:
                body, cont, key = b"", "", ""
            return e.code, cont, key, body
        except Exception as exc:
            raise RestError("transport failed: " + type(exc).__name__)

    async def handle_rest(self, cmd):
        loop = asyncio.get_running_loop()
        try:
            status, cont, key, body = await loop.run_in_executor(
                None, self.do_rest, cmd["direction"],
                cmd.get("cont_yn", ""), cmd.get("next_key", ""))
        except RestError as exc:
            self.emit({"ev": "error", "what": "rest",
                             "detail": exc.args[0]})
            return
        self.emit({"ev": "rest", "direction": cmd["direction"],
                         "page": cmd["page"], "status": status,
                         "cont_yn": cont, "next_key": key,
                         "body_hex": body.hex()})

    # -------------------------------------------------------- commands

    async def handle(self, cmd):
        ctype = cmd.get("type")
        if ctype == "connect":
            if self.ws_task is None:
                self.ws_task = asyncio.get_running_loop().create_task(
                    self.connect_loop())
        elif ctype == "reg":
            data = cmd.get("data")
            if not isinstance(data, list) or not isinstance(cmd.get("gen"),
                                                            int) or \
               cmd["gen"] < 1:
                raise SidecarExit(4, "reg command needs gen>=1 and data")
            envelope = {"trnm": "REG", "grp_no": "1", "refresh": "1",
                        "data": data}
            if self.ws is None:
                raise SidecarExit(4, "reg command with no open connection")
            self.send_text(self.ws, json.dumps(
                envelope, ensure_ascii=False, separators=(",", ":")))
            self.arm_quiet()
        elif ctype == "remove":
            data = cmd.get("data")
            if not isinstance(data, list) or not isinstance(cmd.get("gen"),
                                                            int) or \
               cmd["gen"] < 1:
                raise SidecarExit(4, "remove command needs gen>=1 and data")
            envelope = {"trnm": "REMOVE", "grp_no": "1", "data": data}
            if self.ws is None:
                raise SidecarExit(4, "remove command with no open connection")
            self.send_text(self.ws, json.dumps(
                envelope, ensure_ascii=False, separators=(",", ":")))
            self.arm_quiet()
        elif ctype == "rest_req":
            await self.handle_rest(cmd)
        elif ctype == "refresh_token":
            try:
                self.acquire_token(force=True)
                self.emit({"ev": "token"})
            except TokenError as exc:
                self.emit({"ev": "error", "what": "token",
                                 "detail": exc.args[0]})
        elif ctype == "disarm":
            self.disarm_quiet()
        elif ctype == "wait_drain":
            # A task, not an await: the command loop stays responsive to
            # `stop` while the drain window runs (README §2.6).
            asyncio.get_running_loop().create_task(self._drain())
        elif ctype == "stop":
            self.stopping = True
            self.disarm_quiet()
            if self.ws is not None:
                try:
                    await self.ws.close(code=1000)
                except Exception:
                    pass
            raise SidecarExit(0)
        else:
            # An unknown command is never ignored (README §1).
            raise SidecarExit(4, "unknown command type: %r" % (ctype,))

    async def _drain(self):
        await asyncio.sleep(self.drain)
        if not self.stopping:
            self.emit({"ev": "drain_done"})

    @staticmethod
    def _stdin_thread(loop, queue):
        try:
            for line in sys.stdin:
                line = line.strip()
                if line:
                    loop.call_soon_threadsafe(queue.put_nowait, line)
        except (OSError, ValueError):
            pass
        loop.call_soon_threadsafe(queue.put_nowait, None)

    async def run(self):
        """ready -> serve commands until stop / EOF / fault (README §3.1)."""
        loop = asyncio.get_running_loop()
        queue = asyncio.Queue()
        threading.Thread(target=self._stdin_thread, args=(loop, queue),
                         daemon=True).start()
        loop.create_task(self.poll_timer())
        loop.create_task(self.watchdog_timer())
        self.emit({"ev": "ready"})
        while True:
            line = await queue.get()
            if line is None:
                # stdin closed: the core is gone — a broken pipe (exit 4).
                raise SidecarExit(4, "stdin closed before stop")
            try:
                cmd = json.loads(line)
                if not isinstance(cmd, dict):
                    raise ValueError("command is not a JSON object")
            except ValueError as exc:
                raise SidecarExit(4, "command line is not valid JSON: %s"
                                  % exc)
            await self.handle(cmd)


class RestError(Exception):
    """A REST transport failure (no HTTP response at all)."""


def main():
    line = sys.stdin.readline()
    if not line:
        raise SidecarExit(4, "stdin closed before init")
    cfg = parse_init(line)
    repoll = cfg["repoll_seconds"]
    drain = cfg["drain_seconds"]
    ack_timeout = cfg["ack_timeout_seconds"]
    sidecar = Sidecar(cfg, repoll=repoll, drain=drain, ack_timeout=ack_timeout)

    async def runner():
        try:
            sidecar.acquire_token()
        except TokenError as exc:
            sidecar.emit({"ev": "error", "what": "token",
                          "detail": exc.args[0]})
            return 3
        try:
            await sidecar.run()
        except SidecarExit as exc:
            return exc.code
        return 0

    try:
        code = asyncio.run(runner())
    except SidecarExit as exc:
        code = exc.code
    except KeyboardInterrupt:
        code = 4
    except Exception:
        # A sidecar internal fault is reported, never swallowed; the detail
        # names the exception class only (a traceback could carry data).
        try:
            sidecar.emit({"ev": "error", "what": "internal",
                          "detail": "internal fault"})
        except Exception:
            pass
        code = 4
    return code


if __name__ == "__main__":
    sys.exit(main())
