#!/usr/bin/env python3
"""cloud_supervisor: the container's runtime supervisor (Northflank PR-4).

Contract: tools/container/README.md §8. This process is an EXECUTION
ADAPTER and nothing more: it owns child-process lifecycle and session
scheduling — it never judges the market (the Nim core is the judgment
authority), never records a market fact (Collector/Recorder do), and
never writes into a run directory. Every decision it makes is derived
from the approved calendar volume, the wall clock and observed child
exit codes. Every failure is fail-closed: a failed verification or a
missing prerequisite refuses to start a session — it never relaxes into
a run.

Inside a container there is no systemd (tools/run_session.sh is the
host launcher and delegates worker supervision to it) — this supervisor
performs that role directly:

  - the API child (serve.py) runs always, restarted with a short delay
    when it dies; its `SERVE <bind>:<port>` line (tools/api/README.md
    §1) is the startup evidence, forwarded verbatim to the container
    logs; SIGTERM drains it cleanly;
  - the session controller (this loop, on a KST clock — injectable for
    the contract tests) starts ONE collector per trading day at the
    configured morning time (default 08:50 KST) with
    --token-source=env (README §5.1: the container's only credential
    window) plus the resident notify worker watching the run's
    events.hcj.jsonl; a 15:40 KST watchdog SIGTERMs a still-alive
    collector (the run stays unsealed/preserved; the collector's own
    core watchdog fires at the same time — this is the backstop);
  - collector exit observation: exit 0 = sealed (COMMITTED), exit 4 =
    honest INCOMPLETE, anything else (exit 2, exit 3, a signal) =
    preserved; the worker is stopped at session end (SIGTERM -> exit 0
    is never restarted; an abnormal mid-session exit IS restarted — the
    worker's full-rescan event_id dedup makes the restart idempotent);
  - session idempotency (boot/restart): a COMMITTED run for today
    (the input.hcj.jsonl.committed marker) means the day is done; an
    unsealed run is prior evidence — never resumed, never overwritten;
    a fresh run_id (ph1-<date>-a, -b, ... from the existing runs/) is
    used while time remains (before the last-start time) and the
    attempt cap (attempts = today's existing run directories) allows;
    at most one collector is ever active (single-threaded session
    control + the collector's own O_EXCL as the second line of defense).

Probes (README §8.3) — the supervisor's OWN stdlib HTTP server, never
serve.py (the GET-only API contract stays untouched):
  /startup  503 until initialization completes (config + calendar
            volume verified against the baked image index + API child
            serving), then 200 (latched);
  /ready    200 while the API child is serving, else 503 — traffic
            gating only, never a container restart signal;
  /live     200 while the supervisor loop's heartbeat is fresh (an
            injected-clock check), 503 when the loop stalled — the
            container-restart signal.
  Child work-process state (collector/worker) is deliberately NOT
  exposed on any probe: its recovery is the supervisor's internal
  responsibility, and a post-close absence of collector/worker is
  normal, not a restart reason (probe contract A).

Configuration is environment-only (README §8.2 table): every variable
has a documented default matching the image layout. The supervisor's
judgments are not recorded anywhere: its stdout (one SUPERVISOR-prefixed
line per decision, KST timestamps) IS the container log; the market
facts belong to Collector/Recorder.

Exit codes: 0 clean shutdown (SIGTERM/SIGINT), 2 configuration error,
4 probe bind failure, 1 internal fault (a fatal fault exits non-zero —
restarting the container is the platform's job, never this process's).

Python 3.13, standard library only. No credentials pass through this
code's logic: the collector child inherits the process environment
(APP_KEY_MOCK/APP_SECRET_MOCK are the platform's encrypted env vars)
and no token or secret value is ever read, printed or logged here.
"""

import hashlib
import ipaddress
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KST = timezone(timedelta(hours=9))
# The seal marker the recorder writes at durable completion — the same
# name serve.py projects (tools/api/serve.py COMMITTED_MARKER).
COMMITTED_MARKER = "input.hcj.jsonl.committed"
RUN_ID_PREFIX = "ph1"
# sha256sum text mode: "<64 lowercase hex>  <name>" (two spaces).
INDEX_LINE_RE = re.compile(r"^([0-9a-f]{64})  (.+)$")

_PRINT_LOCK = threading.Lock()


def _emit(line):
    """One complete line to stdout — the container log. Locked so the
    API child's forwarded lines and the supervisor's own lines never
    interleave mid-line."""
    with _PRINT_LOCK:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def kst_stamp(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S+09:00")


class ConfigError(Exception):
    """The configuration is refused: the supervisor exits 2 and starts
    nothing (fail-closed at boot, before any child exists)."""


# ---------------------------------------------------------------- clock

class Clock:
    """The wall clock. Every time-dependent decision goes through this
    object so the contract tests can inject a deterministic one."""

    def epoch(self):
        return time.time()

    def monotonic(self):
        return time.monotonic()

    def now_kst(self):
        return datetime.now(KST)


class FakeClock(Clock):
    """Deterministic clock for the contract tests: advance() moves both
    the wall and the monotonic reading."""

    def __init__(self, start_kst):
        self._epoch = start_kst.timestamp()
        self._mono = 1000.0

    def epoch(self):
        return self._epoch

    def monotonic(self):
        return self._mono

    def now_kst(self):
        return datetime.fromtimestamp(self._epoch, KST)

    def advance(self, seconds):
        self._epoch += seconds
        self._mono += seconds


# ----------------------------------------------------------------- config

def _env(env, key, default):
    value = env.get(key)
    return default if value is None or value == "" else value


def _env_int(env, key, default, low, high):
    raw = _env(env, key, str(default))
    try:
        value = int(raw)
    except ValueError:
        raise ConfigError("%s must be an integer: %r" % (key, raw))
    if not low <= value <= high:
        raise ConfigError("%s must be between %d and %d: %d"
                          % (key, low, high, value))
    return value


def _env_float(env, key, default, low):
    raw = _env(env, key, repr(default))
    try:
        value = float(raw)
    except ValueError:
        raise ConfigError("%s must be a number: %r" % (key, raw))
    if value < low:
        raise ConfigError("%s must be >= %g: %g" % (key, low, value))
    return value


def _env_abs(env, key, default):
    value = _env(env, key, default)
    if not os.path.isabs(value):
        raise ConfigError("%s must be an absolute path: %r" % (key, value))
    return value


def _env_hhmm(env, key, default):
    raw = _env(env, key, default)
    if len(raw) != 5 or raw[2] != ":" or \
            not raw[:2].isdigit() or not raw[3:].isdigit():
        raise ConfigError("%s must be HH:MM (KST): %r" % (key, raw))
    hh, mm = int(raw[:2]), int(raw[3:])
    if hh > 23 or mm > 59:
        raise ConfigError("%s is outside plausible ranges: %s" % (key, raw))
    return datetime(2000, 1, 1, hh, mm).time()


@dataclass
class Config:
    """Everything the supervisor may be configured with, env-overridable,
    each with the documented default (README §8.2)."""

    data_root: str = "/var/lib/hongscanner"
    serve_script: str = "/opt/hongscanner/serve.py"
    api_python: str = sys.executable
    api_bind: str = "0.0.0.0"      # container-only, behind the platform ingress
    api_port: int = 8080
    api_restart_seconds: float = 2.0
    probe_host: str = "0.0.0.0"
    probe_port: int = 8081
    probe_startup_path: str = "/startup"
    probe_ready_path: str = "/ready"
    probe_live_path: str = "/live"
    calendar_dir: str = "/var/lib/hongscanner/calendars"
    calendar_index: str = "/opt/hongscanner/CALENDAR_INDEX.sha256"
    collector_bin: str = "/opt/hongscanner/bin/collector"
    notify_script: str = "/opt/hongscanner/notify/notify_dispatcher.py"
    notify_config: str = "/var/lib/hongscanner/notify/notify_config.json"
    worker_python: str = sys.executable
    profile: str = "demo"
    session_start: object = None   # time(8, 50)
    session_last_start: object = None   # time(15, 30)
    session_watchdog: object = None     # time(15, 40)
    tick_seconds: float = 30.0
    max_attempts: int = 3
    worker_restart_seconds: float = 2.0
    worker_max_restarts: int = 5
    tail_grace_seconds: float = 3.0
    kill_grace_seconds: float = 10.0
    runs_root: str = field(init=False, default="")
    ledger_path: str = field(init=False, default="")

    def __post_init__(self):
        self.runs_root = os.path.join(self.data_root, "runs")
        self.ledger_path = os.path.join(self.data_root, "notify",
                                        "ledger.hcj.jsonl")
        if self.session_start is None:
            self.session_start = _env_hhmm({}, "HS_SESSION_START", "08:50")
        if self.session_last_start is None:
            self.session_last_start = _env_hhmm({}, "HS_SESSION_LAST_START",
                                                "15:30")
        if self.session_watchdog is None:
            self.session_watchdog = _env_hhmm({}, "HS_SESSION_WATCHDOG",
                                              "15:40")

    @classmethod
    def from_env(cls, env):
        cfg = cls(
            data_root=_env_abs(env, "HS_DATA_ROOT", "/var/lib/hongscanner"),
            serve_script=_env_abs(env, "HS_SERVE_SCRIPT",
                                  "/opt/hongscanner/serve.py"),
            api_python=_env(env, "HS_API_PYTHON", sys.executable),
            api_bind=_env(env, "HS_API_BIND", "0.0.0.0"),
            api_port=_env_int(env, "HS_API_PORT", 8080, 0, 65535),
            api_restart_seconds=_env_float(env, "HS_API_RESTART_SECONDS",
                                           2.0, 0.0),
            probe_host=_env(env, "HS_SUPERVISOR_PROBE_HOST", "0.0.0.0"),
            probe_port=_env_int(env, "HS_SUPERVISOR_PROBE_PORT", 8081,
                                0, 65535),
            probe_startup_path=_env(env, "HS_PROBE_STARTUP_PATH", "/startup"),
            probe_ready_path=_env(env, "HS_PROBE_READY_PATH", "/ready"),
            probe_live_path=_env(env, "HS_PROBE_LIVE_PATH", "/live"),
            calendar_dir=_env_abs(env, "HS_CALENDAR_DIR",
                                  "/var/lib/hongscanner/calendars"),
            calendar_index=_env_abs(env, "HS_CALENDAR_INDEX",
                                    "/opt/hongscanner/CALENDAR_INDEX.sha256"),
            collector_bin=_env_abs(env, "HS_COLLECTOR_BIN",
                                   "/opt/hongscanner/bin/collector"),
            notify_script=_env_abs(env, "HS_NOTIFY_SCRIPT",
                                   "/opt/hongscanner/notify/"
                                   "notify_dispatcher.py"),
            notify_config=_env_abs(env, "HS_NOTIFY_CONFIG",
                                   "/var/lib/hongscanner/notify/"
                                   "notify_config.json"),
            worker_python=_env(env, "HS_WORKER_PYTHON", sys.executable),
            profile=_env(env, "HS_KIWOOM_PROFILE", "demo"),
            session_start=_env_hhmm(env, "HS_SESSION_START", "08:50"),
            session_last_start=_env_hhmm(env, "HS_SESSION_LAST_START",
                                         "15:30"),
            session_watchdog=_env_hhmm(env, "HS_SESSION_WATCHDOG", "15:40"),
            tick_seconds=_env_float(env, "HS_TICK_SECONDS", 30.0, 1.0),
            max_attempts=_env_int(env, "HS_SESSION_MAX_ATTEMPTS", 3, 1,
                                  26),
            worker_restart_seconds=_env_float(env, "HS_WORKER_RESTART_SECONDS",
                                              2.0, 0.0),
            worker_max_restarts=_env_int(env, "HS_WORKER_MAX_RESTARTS", 5,
                                         0, 1000),
            tail_grace_seconds=_env_float(env, "HS_SESSION_TAIL_GRACE",
                                          3.0, 0.0),
            kill_grace_seconds=_env_float(env, "HS_KILL_GRACE_SECONDS",
                                          10.0, 1.0),
        )
        if not 1 <= len(cfg.profile) <= 64 or \
                any(c.isspace() for c in cfg.profile):
            raise ConfigError(
                "HS_KIWOOM_PROFILE must be 1..64 non-space chars: %r"
                % cfg.profile)
        try:
            ipaddress.IPv4Address(cfg.api_bind)
            ipaddress.IPv4Address(cfg.probe_host)
        except ValueError as exc:
            raise ConfigError("bind addresses must be dotted-quad IPv4: %s"
                              % exc)
        if cfg.session_start >= cfg.session_last_start:
            raise ConfigError(
                "HS_SESSION_START must be earlier than "
                "HS_SESSION_LAST_START (the start window would be empty)")
        return cfg


# ------------------------------------------------- calendar trust check

def verify_calendar_volume(index_path, calendar_dir):
    """Cross-validate the volume-supplied calendar JSONs against the
    image's baked CALENDAR_INDEX.sha256 (tools/container/README.md §4/§8).
    Returns (calendars, faults): calendars is a list of
    {"path", "doc"} entries for the files that matched; faults is a
    list of reason strings — any fault is fail-closed (the session
    never starts, initialization never completes). The index text mode
    is sha256sum's "<64 hex>\\<space><space><name>"; a name may map one
    calendar file per index line, looked up by basename inside the
    calendar directory."""
    faults = []
    calendars = []
    try:
        with open(index_path, "rb") as f:
            data = f.read()
    except OSError as exc:
        return [], ["calendar index unreadable: %s" % exc.strerror]
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return [], ["calendar index is not valid UTF-8"]
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()          # the trailing newline is not a record
    seen_names = set()
    for i, line in enumerate(lines, start=1):
        if not line:
            faults.append("index line %d is empty" % i)
            continue
        match = INDEX_LINE_RE.match(line)
        if match is None:
            faults.append("index line %d is not a sha256sum line" % i)
            continue
        recorded, name = match.group(1), match.group(2)
        parts = name.split("/")
        if name.startswith("/") or "\\" in name or "" in parts or \
                ".." in parts:
            faults.append("index line %d names an unsafe path: refused"
                          % i)
            continue
        base = parts[-1]
        if base in seen_names:
            faults.append("index line %d: duplicate calendar name %s"
                          % (i, base))
            continue
        seen_names.add(base)
        path = os.path.join(calendar_dir, base)
        try:
            with open(path, "rb") as f:
                digest = hashlib.sha256()
                for chunk in iter(lambda: f.read(65536), b""):
                    digest.update(chunk)
            actual = digest.hexdigest()
        except FileNotFoundError:
            faults.append("calendar %s is absent from the volume" % base)
            continue
        except OSError as exc:
            faults.append("calendar %s unreadable: %s"
                          % (base, exc.strerror))
            continue
        if actual != recorded:
            faults.append("calendar %s does not match the baked index "
                          "(sha256 mismatch)" % base)
            continue
        try:
            with open(path, "rb") as f:
                doc = json.loads(f.read().decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            faults.append("calendar %s is not valid UTF-8 JSON" % base)
            continue
        if not isinstance(doc, dict) or \
                not isinstance(doc.get("days"), dict):
            faults.append("calendar %s has no days object" % base)
            continue
        calendars.append({"path": path, "doc": doc})
    if not faults and not calendars:
        faults.append("the calendar index names no calendars")
    return calendars, faults


def calendar_is_trading_day(doc, date):
    """The same judgment as calendars.nim isTradingDay: the day record
    exists and carries a non-null open. Nothing more is decided here —
    the session window itself is the collector core's authority."""
    day = doc.get("days", {}).get(date)
    return isinstance(day, dict) and day.get("open") is not None


def calendar_covers(doc, date):
    """The same coverage shape as calendars.nim inCoverage: the date
    lies between the calendar's first and last day key (string order)."""
    keys = sorted(doc.get("days", {}).keys())
    if not keys:
        return False
    return keys[0] <= date <= keys[-1]


def select_calendar(calendars, date):
    """The one verified calendar that covers `date` as a trading day.
    Zero coverage and ambiguous coverage are both refusals (fail-closed)
    — the caller never guesses."""
    picked = [c for c in calendars
              if calendar_covers(c["doc"], date)
              and calendar_is_trading_day(c["doc"], date)]
    if len(picked) == 1:
        return picked[0], None
    if not picked:
        return None, ("no verified calendar covers %s as a trading day"
                      % date)
    return None, ("%d verified calendars cover %s — coverage is ambiguous"
                  % (len(picked), date))


# ---------------------------------------------------------- run registry

def todays_run_names(runs_root, date):
    """Existing run directories for `date` (the ph1-<date>-* local
    convention), sorted. An unreadable runs root raises OSError — the
    caller treats that as a refusal, never as an empty day."""
    prefix = "%s-%s-" % (RUN_ID_PREFIX, date)
    names = os.listdir(runs_root)
    return sorted(n for n in names
                  if n.startswith(prefix)
                  and os.path.isdir(os.path.join(runs_root, n)))


def run_is_committed(run_dir):
    """The durable seal marker the recorder wrote (the only completion
    evidence the supervisor trusts)."""
    return os.path.isfile(os.path.join(run_dir, COMMITTED_MARKER))


def next_run_id(date, names):
    """The next ph1-<date>-<letter> run id after the existing ones
    (a, b, c, ...). None when the letters are exhausted — refused, not
    wrapped."""
    prefix = "%s-%s-" % (RUN_ID_PREFIX, date)
    existing = {n[len(prefix):] for n in names if n.startswith(prefix)}
    for ch in "abcdefghijklmnopqrstuvwxyz":
        if ch not in existing:
            return prefix + ch
    return None


# ------------------------------------------------------------ api child

class ApiProcess:
    """The always-running serve.py child. The `SERVE <bind>:<port>`
    line on its stdout (tools/api/README.md §1) is the only startup
    evidence: until it arrives the state is `starting` and /ready is
    503. Any exit is restarted after the short backoff — an API that
    refuses its configuration (exit 2) keeps saying so in the log
    while /ready stays 503; the supervisor never turns that into a
    success. Child stdout is forwarded verbatim (unprefixed) so the
    container log keeps serving the original SERVE line."""

    def __init__(self, cfg, clock, log):
        self.cfg = cfg
        self.clock = clock
        self.log = log
        self.state = "down"          # down | starting | serving
        self.proc = None
        self.last_exit = None
        self.exit_count = 0
        self.serve_line = None
        self.stopping = False
        self._restart_at = None
        self._gen = 0

    def command(self):
        return [self.cfg.api_python, self.cfg.serve_script,
                "--bind", self.cfg.api_bind,
                "--port", str(self.cfg.api_port),
                "--runs", self.cfg.runs_root,
                "--ledger", self.cfg.ledger_path]

    def start(self):
        self._gen += 1
        gen = self._gen
        self.state = "starting"
        self.proc = subprocess.Popen(
            self.command(), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            text=True, bufsize=1, errors="replace")
        threading.Thread(target=self._pump, args=(gen,),
                         daemon=True).start()
        self.log("api child started pid=%d (serve.py)" % self.proc.pid)

    def _pump(self, gen):
        """Forward the child's stdout verbatim; the SERVE line marks the
        child as serving. A generation guard keeps a lingering old
        thread from marking a newer child."""
        proc = self.proc
        try:
            for line in proc.stdout:
                line = line.rstrip("\n")
                if gen != self._gen:
                    continue
                if line.startswith("SERVE ") and self.state != "serving":
                    self.state = "serving"
                    self.serve_line = line
                _emit(line)
        except (OSError, ValueError):
            pass

    def poll(self):
        """The child's exit code once it has exited (and the restart is
        scheduled), else None."""
        if self.proc is not None and self.proc.poll() is not None:
            self.last_exit = self.proc.returncode
            self.exit_count += 1
            self.proc = None
            self.state = "down"
            self._restart_at = self.clock.monotonic() \
                + self.cfg.api_restart_seconds
            return self.last_exit
        return None

    def tick(self):
        exited = self.poll()
        if exited is not None:
            note = {0: "(unexpected clean exit)",
                    2: "(usage/config violation — fix the volume layout)",
                    4: "(bind failure)"}.get(exited, "(crashed)")
            self.log("api child exited rc=%d %s — restart in %gs"
                     % (exited, note, self.cfg.api_restart_seconds))
        if self.stopping or self.proc is not None or \
                self._restart_at is None:
            return
        if self.clock.monotonic() >= self._restart_at:
            self._restart_at = None
            self.log("restarting api child")
            self.start()

    def stop(self, grace):
        """SIGTERM (serve.py drains and exits 0), then SIGKILL."""
        self.stopping = True
        proc = self.proc
        if proc is None or proc.poll() is not None:
            return proc.returncode if proc is not None else None
        proc.terminate()
        try:
            proc.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            self.log("api child ignored SIGTERM — SIGKILL")
            proc.kill()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        self.state = "down"
        self.last_exit = proc.returncode
        return proc.returncode


# ---------------------------------------------------------- notify worker

class WorkerProcess:
    """The resident notification worker for one session
    (notify_dispatcher.py --watch on the run's events.hcj.jsonl).
    SIGTERM -> exit 0 is the clean stop; anything else while the
    session is active is restarted by the supervisor (full-rescan
    event_id dedup makes that idempotent — the worker's own contract)."""

    def __init__(self, cfg, log, events_path):
        self.cfg = cfg
        self.log = log
        self.events_path = events_path
        self.proc = None

    def command(self):
        return [self.cfg.worker_python, self.cfg.notify_script,
                "--config", self.cfg.notify_config,
                "--watch", self.events_path]

    def start(self):
        self.proc = subprocess.Popen(self.command(),
                                     stdin=subprocess.DEVNULL)
        self.log("worker started pid=%d (watch %s)"
                 % (self.proc.pid, os.path.basename(self.events_path)))

    def poll(self):
        if self.proc is not None and self.proc.poll() is not None:
            code = self.proc.returncode
            self.proc = None
            return code
        return None

    def terminate(self, grace):
        """SIGTERM, then SIGKILL after the grace. Returns the exit
        code (or None when the worker was already gone)."""
        proc = self.proc
        if proc is None or proc.poll() is not None:
            return proc.returncode if proc is not None else None
        proc.terminate()
        try:
            proc.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            self.log("worker ignored SIGTERM — SIGKILL")
            proc.kill()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        code = proc.returncode
        self.proc = None
        return code


# --------------------------------------------------------------- session

@dataclass
class Session:
    run_id: str
    run_dir: str
    calendar_path: str
    collector: object
    worker: object
    worker_restarts: int = 0
    worker_restart_at: float = None
    worker_stopped: bool = False      # exited 0 / gave up: never restarted
    watchdog_sent_at: float = None


# ------------------------------------------------------------ probe server

class _ProbeHandler(BaseHTTPRequestHandler):
    """GET-only. Three fixed paths, three fixed plain-text verdicts —
    deliberately NO child work-process state anywhere in a response
    (probe contract A): the collector/worker lifecycle is the
    supervisor's internal responsibility and must never become a
    container-restart reason."""

    protocol_version = "HTTP/1.1"
    server_version = "HongScannerSupervisorProbe/1"

    def _reply(self, code, text):
        body = (text + "\n").encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def do_GET(self):
        sup = self.server.sup
        cfg = sup.cfg
        path = self.path.split("?", 1)[0]
        if path == cfg.probe_startup_path:
            if sup.init_complete:
                self._reply(200, "ok")
            else:
                self._reply(503, "initializing")
        elif path == cfg.probe_ready_path:
            if sup.api.state == "serving":
                self._reply(200, "ok")
            else:
                self._reply(503, "api unavailable")
        elif path == cfg.probe_live_path:
            if sup.loop_is_alive():
                self._reply(200, "ok")
            else:
                self._reply(503, "loop stalled")
        else:
            self._reply(404, "not found")

    def _method_not_allowed(self):
        self.send_response(405)
        self.send_header("Allow", "GET")
        body = b"method not allowed\n"
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    do_POST = _method_not_allowed
    do_PUT = _method_not_allowed
    do_DELETE = _method_not_allowed
    do_PATCH = _method_not_allowed
    do_HEAD = _method_not_allowed
    do_OPTIONS = _method_not_allowed

    def log_message(self, fmt, *args):
        pass  # probe noise stays out of the container log


class ProbeServer:
    """The supervisor's own stdlib HTTP server — separate port,
    separate process from serve.py, whose GET-only contract is never
    touched. The three paths and the port are env-configurable
    (README §8.2/§8.3); the Northflank mapping itself is deployment
    configuration (NF-5 guide in the README), not a repository file."""

    def __init__(self, supervisor):
        self.sup = supervisor
        self.httpd = None
        self.thread = None

    @property
    def port(self):
        return self.httpd.server_address[1]

    def start(self):
        self.httpd = ThreadingHTTPServer(
            (self.sup.cfg.probe_host, self.sup.cfg.probe_port),
            _ProbeHandler)
        self.httpd.daemon_threads = True
        self.httpd.sup = self.sup
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       kwargs={"poll_interval": 0.2},
                                       daemon=True)
        self.thread.start()

    def shutdown(self):
        if self.httpd is not None:
            self.httpd.shutdown()
            self.httpd.server_close()
            self.httpd = None


# ------------------------------------------------------------- supervisor

class Supervisor:
    """The session controller. One instance, one tick loop; all session
    decisions happen on the (injectable) clock inside tick()."""

    def __init__(self, cfg, clock=None):
        self.cfg = cfg
        self.clock = clock or Clock()
        self.api = ApiProcess(cfg, self.clock, self.log)
        self.calendar_ok = False
        self.calendars = []
        self.init_complete = False
        self.session = None
        self.stopping = False
        self.loop_started_mono = None
        self.last_tick_mono = None
        self.probe = ProbeServer(self)
        self._calendar_fault_logged = False
        self._logged_once = {}       # date -> set of refusal keys

    # ------------------------------------------------------------- logging

    def log(self, msg):
        _emit("%s SUPERVISOR %s" % (kst_stamp(self.clock.now_kst()), msg))

    def log_once(self, date, key, msg):
        keys = self._logged_once.setdefault(date, set())
        if key not in keys:
            keys.add(key)
            self.log(msg)

    # ------------------------------------------------------- probe support

    def loop_dead_after(self):
        """A loop heartbeat older than this means the controller thread
        stalled — the /live verdict turns 503 (the container-restart
        signal)."""
        return max(2.0 * self.cfg.tick_seconds, 10.0)

    def loop_is_alive(self):
        ref = self.last_tick_mono or self.loop_started_mono
        if ref is None:
            return True
        return self.clock.monotonic() - ref <= self.loop_dead_after()

    def start_probe_server(self):
        self.probe.start()

    # ------------------------------------------------------------ ticking

    def tick(self):
        """One controller tick: API supervision, initialization
        progress, session supervision/start. Everything below is
        fail-closed: a refusal starts nothing and relaxes nothing."""
        self.last_tick_mono = self.clock.monotonic()
        self.api.tick()
        self._init_step()
        if self.stopping:
            return
        if self.session is not None:
            self._maintain_session(self.session)
        else:
            self._maybe_start_session()

    def _init_step(self):
        if not self.calendar_ok:
            calendars, faults = verify_calendar_volume(
                self.cfg.calendar_index, self.cfg.calendar_dir)
            if faults:
                if not self._calendar_fault_logged:
                    self._calendar_fault_logged = True
                    self.log("calendar verification FAILED (fail-closed: "
                             "no session starts): " + "; ".join(faults[:5]))
            else:
                self.calendar_ok = True
                self.calendars = calendars
                self.log("calendar verified: %d file(s) match the baked "
                         "image index" % len(calendars))
        if not self.init_complete and self.calendar_ok and \
                self.api.state == "serving":
            self.init_complete = True
            self.log("initialization complete (/startup 200 from here)")

    # ------------------------------------------------------ session start

    def _maybe_start_session(self):
        now = self.clock.now_kst()
        date = now.date().isoformat()
        todays_time = now.time()
        if todays_time < self.cfg.session_start:
            return
        self.log_once(date, "window",
                      "session start window open (start %s, last start %s, "
                      "watchdog %s KST)"
                      % (self.cfg.session_start.strftime("%H:%M"),
                         self.cfg.session_last_start.strftime("%H:%M"),
                         self.cfg.session_watchdog.strftime("%H:%M")))
        if todays_time >= self.cfg.session_last_start:
            return
        try:
            names = todays_run_names(self.cfg.runs_root, date)
        except OSError as exc:
            self.log_once(date, "runs-root",
                          "session start refused: runs root unreadable: %s"
                          % exc.strerror)
            return
        committed = [n for n in names
                     if run_is_committed(os.path.join(self.cfg.runs_root, n))]
        if committed:
            self.log_once(date, "committed",
                          "today's session is already COMMITTED (run %s) — "
                          "no new session" % committed[-1])
            return
        if len(names) >= self.cfg.max_attempts:
            self.log_once(date, "cap",
                          "attempt cap reached (%d runs today >= %d) — no "
                          "further session today"
                          % (len(names), self.cfg.max_attempts))
            return
        calendars, faults = verify_calendar_volume(
            self.cfg.calendar_index, self.cfg.calendar_dir)
        if faults:
            self.log_once(date, "cal-fault",
                          "session start refused: calendar verification "
                          "failed: " + "; ".join(faults[:5]))
            return
        picked, reason = select_calendar(calendars, date)
        if picked is None:
            self.log_once(date, "calendar",
                          "no session today: %s" % reason)
            return
        missing = [p for p, ok in (
            (self.cfg.collector_bin, os.access(self.cfg.collector_bin,
                                               os.X_OK)),
            (self.cfg.notify_script, os.path.isfile(self.cfg.notify_script)),
            (self.cfg.notify_config, os.path.isfile(self.cfg.notify_config)),
        ) if not ok]
        if missing:
            self.log_once(date, "prereq",
                          "session start refused, prerequisites missing: "
                          + ", ".join(missing))
            return
        run_id = next_run_id(date, names)
        if run_id is None:
            self.log_once(date, "suffix",
                          "run-id suffixes exhausted — session refused")
            return
        run_dir = os.path.join(self.cfg.runs_root, run_id)
        events_path = os.path.join(run_dir, "events.hcj.jsonl")
        # The collector creates its own run directory (O_EXCL on the
        # input log is the second one-active-collector defense); the
        # supervisor creates nothing inside it.
        collector_cmd = [
            self.cfg.collector_bin,
            "--profile=%s" % self.cfg.profile,
            "--session-date=%s" % date,
            "--out=%s" % run_dir,
            "--calendar=%s" % picked["path"],
            "--token-source=env",
        ]
        try:
            collector = subprocess.Popen(collector_cmd,
                                         stdin=subprocess.DEVNULL)
        except OSError as exc:
            self.log("session start failed (collector spawn): %s" % exc)
            return
        worker = WorkerProcess(self.cfg, self.log, events_path)
        try:
            worker.start()
        except OSError as exc:
            self.log("session start aborted (worker spawn failed: %s) — "
                     "collector stopped, nothing half-started is kept "
                     "running" % exc)
            collector.terminate()
            try:
                collector.wait(timeout=self.cfg.kill_grace_seconds)
            except subprocess.TimeoutExpired:
                collector.kill()
            return
        self.session = Session(run_id=run_id, run_dir=run_dir,
                               calendar_path=picked["path"],
                               collector=collector, worker=worker)
        self.log("session started run_id=%s calendar=%s attempts=%d/%d "
                 "collector_pid=%d (token_source=env)"
                 % (run_id, os.path.basename(picked["path"]),
                    len(names) + 1, self.cfg.max_attempts, collector.pid))

    # -------------------------------------------------- session supervision

    def _maintain_session(self, s):
        now_mono = self.clock.monotonic()
        now_kst = self.clock.now_kst()
        # 1. the 15:40 backstop: the collector's own core watchdog fires
        #    at the same time — this SIGTERM catches one that hung past it.
        if s.watchdog_sent_at is None and \
                now_kst.time() >= self.cfg.session_watchdog and \
                s.collector.poll() is None:
            s.watchdog_sent_at = now_mono
            s.collector.terminate()
            self.log("watchdog reached — collector still alive: SIGTERM "
                     "(the run stays unsealed/preserved)")
        elif s.watchdog_sent_at is not None and \
                s.collector.poll() is None and \
                now_mono - s.watchdog_sent_at >= self.cfg.kill_grace_seconds:
            self.log("collector ignored the watchdog SIGTERM — SIGKILL")
            s.collector.kill()
        # 2. worker supervision (never a session-level failure: the
        #    recording authority is the collector). The worker object
        #    persists across restarts; proc is None while it is down.
        w = s.worker
        rc = w.poll()
        if rc is not None:
            if rc == 0:
                s.worker_stopped = True
                self.log("worker exited 0 (clean stop) — not "
                         "restarted (worker contract)")
            elif s.worker_stopped:
                pass
            elif s.worker_restarts < self.cfg.worker_max_restarts:
                s.worker_restart_at = now_mono + \
                    self.cfg.worker_restart_seconds
                self.log("worker exited rc=%d mid-session — restart "
                         "scheduled (full-rescan dedup keeps it "
                         "idempotent)" % rc)
            else:
                s.worker_stopped = True
                self.log("worker restart cap reached (%d) — pushes "
                         "suspended for this session; recording "
                         "continues" % self.cfg.worker_max_restarts)
        elif not s.worker_stopped and \
                s.worker_restart_at is not None and \
                now_mono >= s.worker_restart_at:
            s.worker_restart_at = None
            try:
                w.start()
            except OSError as exc:
                self.log("worker restart failed: %s — will retry" % exc)
                s.worker_restart_at = now_mono + \
                    self.cfg.worker_restart_seconds
                return
            s.worker_restarts += 1
            self.log("worker restarted (attempt %d)" % s.worker_restarts)
        # 3. collector exit observation — the session-level event
        rc = s.collector.poll()
        if rc is not None:
            self._end_session(s, rc)

    def _end_session(self, s, rc):
        """Collector exit: 0 = sealed (COMMITTED), 4 = honest
        INCOMPLETE, everything else = preserved (fail-closed — no exit
        is ever promoted to a success). The worker is stopped after a
        short tail grace so the close-protocol events appended in the
        collector's final seconds still reach the worker's next tick
        (the events file stays the authority either way)."""
        if rc == 0:
            outcome = "COMMITTED"
        elif rc == 4:
            outcome = "INCOMPLETE"
        else:
            outcome = "PRESERVED"
        if self.cfg.tail_grace_seconds > 0:
            time.sleep(self.cfg.tail_grace_seconds)
        worker_rc = s.worker.terminate(self.cfg.kill_grace_seconds) \
            if s.worker is not None else None
        self.session = None
        self.log("session ended run_id=%s collector_exit=%d worker_exit=%s "
                 "outcome=%s"
                 % (s.run_id, rc,
                    "none" if worker_rc is None else str(worker_rc),
                    outcome))

    # ----------------------------------------------------------- shutdown

    def shutdown(self):
        """Graceful stop: the collector is signaled (the run stays
        unsealed — the restart idempotency contract owns the
        continuation), the worker and the API child drain, the probe
        server closes."""
        self.stopping = True
        s = self.session
        if s is not None:
            if s.collector.poll() is None:
                s.collector.terminate()
                try:
                    s.collector.wait(timeout=self.cfg.kill_grace_seconds)
                except subprocess.TimeoutExpired:
                    s.collector.kill()
            if s.worker is not None:
                s.worker.terminate(self.cfg.kill_grace_seconds)
            self.log("shutdown: run %s left unsealed/preserved (a later "
                     "boot starts a fresh run_id)" % s.run_id)
            self.session = None
        self.api.stop(self.cfg.kill_grace_seconds)
        self.probe.shutdown()


# ------------------------------------------------------------------ main

def main():
    try:
        cfg = Config.from_env(os.environ)
    except ConfigError as exc:
        sys.stderr.write("cloud_supervisor: configuration refused: %s\n"
                         % exc)
        return 2
    sup = Supervisor(cfg)
    try:
        sup.start_probe_server()
    except OSError as exc:
        sup.log("probe server bind failed (%s:%d): %s — exiting 4"
                % (cfg.probe_host, cfg.probe_port, exc))
        return 4
    stop = threading.Event()

    def _request_stop(_signum, _frame):
        stop.set()

    signal.signal(signal.SIGTERM, _request_stop)
    signal.signal(signal.SIGINT, _request_stop)
    sup.log("cloud supervisor starting (api %s:%d, probes %s:%d, data "
            "root %s, tick %gs)"
            % (cfg.api_bind, cfg.api_port, cfg.probe_host, sup.probe.port,
               cfg.data_root, cfg.tick_seconds))
    sup.loop_started_mono = sup.clock.monotonic()
    sup.api.start()
    code = 0
    try:
        while not stop.is_set():
            sup.tick()
            if stop.is_set():
                break
            deadline = time.monotonic() + cfg.tick_seconds
            while not stop.is_set():
                remain = deadline - time.monotonic()
                if remain <= 0:
                    break
                stop.wait(min(remain, 0.5))
    except Exception as exc:
        code = 1
        sup.log("internal fault: %s: %s" % (type(exc).__name__, exc))
    sup.shutdown()
    sup.log("stopped (%s)"
            % ("internal fault, exit 1" if code else "clean, exit 0"))
    return code


if __name__ == "__main__":
    sys.exit(main())
