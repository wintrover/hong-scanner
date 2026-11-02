#!/usr/bin/env python3
"""cloud_supervisor contract suite (tools/container/README.md §7).

Deterministic contract tests for the container's runtime supervisor:
fake children (Python scripts that sleep, honor a chosen SIGTERM policy
and exit with a chosen code — the real collector/worker binaries are
never run here), an injected clock driving the 08:50 session start, the
15:30 last-start bound, the 15:40 watchdog and the restart backoffs,
and real HTTP probes on an ephemeral loopback port. The only real
vendor-adjacent process exercised is serve.py itself (stdlib-only
loopback child, the tools/api/test_api.py pattern): the supervisor
supervises the real serve.py child and /ready flips are observed.

Fail-closed paths asserted: calendar volume vs baked INDEX mismatch
refuses the session; an attempt cap refuses further sessions; an
unsealed prior run is preserved (new run_id, never resumed); an exit 0
without the seal marker is NOT a sealed day; a missing prerequisite
starts nothing. Probe contract A is asserted on every probe body: no
collector/worker/session state ever appears there.

Everything is synthetic; no credential value exists anywhere in this
suite. Run: bash tools/container/test_supervisor.sh
"""

import hashlib
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
from datetime import datetime, time as dtime, timedelta, timezone
from unittest import mock
from urllib import request as urlrequest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cloud_supervisor as cs  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))))
SERVE_PY = os.path.join(REPO_ROOT, "tools", "api", "serve.py")
CS_SCRIPT = os.path.join(REPO_ROOT, "tools", "container",
                         "cloud_supervisor.py")

KST = timezone(timedelta(hours=9))
BASE_KST = datetime(2026, 11, 2, 8, 49, 30, tzinfo=KST)
DATE = "2026-11-02"
COMMITTED = cs.COMMITTED_MARKER

FAKE_COLLECTOR = """import json, os, signal, sys, time

def _term(_s, _f):
    if os.environ.get("FAKE_IGNORE_TERM") == "1":
        return
    os._exit(int(os.environ.get("FAKE_COLLECTOR_TERM_EXIT", "4")))

signal.signal(signal.SIGTERM, _term)

def arg_of(*names):
    args = sys.argv[1:]
    for i, a in enumerate(args):
        for n in names:
            if a == n and i + 1 < len(args):
                return args[i + 1]
            if a.startswith(n + "="):
                return a[len(n) + 1:]
    return ""

out = arg_of("--out")
if out:
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "fake.argv.json"), "w", encoding="utf-8") as f:
        json.dump(sys.argv[1:], f)
    with open(os.path.join(out, "fake.collector.pid"), "w",
              encoding="utf-8") as f:
        f.write(str(os.getpid()))

mode = os.environ.get("FAKE_COLLECTOR_MODE", "run")
if mode.startswith("exit:"):
    time.sleep(float(os.environ.get("FAKE_COLLECTOR_EXIT_DELAY", "0.2")))
    if os.environ.get("FAKE_COMMIT") == "1" and out:
        with open(os.path.join(out, "{committed}"), "wb"):
            pass
    sys.exit(int(mode.split(":", 1)[1]))
time.sleep(3600)
""".format(committed=COMMITTED)

FAKE_WORKER = """import os, signal, sys, time

def _term(_s, _f):
    os._exit(int(os.environ.get("FAKE_WORKER_TERM_EXIT", "0")))

signal.signal(signal.SIGTERM, _term)

def arg_of(*names):
    args = sys.argv[1:]
    for i, a in enumerate(args):
        for n in names:
            if a == n and i + 1 < len(args):
                return args[i + 1]
            if a.startswith(n + "="):
                return a[len(n) + 1:]
    return ""

watch = arg_of("--watch")
if watch:
    os.makedirs(os.path.dirname(watch), exist_ok=True)
    with open(os.path.join(os.path.dirname(watch), "fake.worker.pid"), "w",
              encoding="utf-8") as f:
        f.write(str(os.getpid()))

mode = os.environ.get("FAKE_WORKER_MODE", "run")
if mode.startswith("exit:"):
    time.sleep(float(os.environ.get("FAKE_WORKER_EXIT_DELAY", "0.3")))
    sys.exit(int(mode.split(":", 1)[1]))
time.sleep(3600)
"""

FAKE_SERVE = """import os, signal, sys, time

def _term(_s, _f):
    os._exit(int(os.environ.get("FAKE_SERVE_TERM_EXIT", "0")))

signal.signal(signal.SIGTERM, _term)

print("SERVE %s" % os.environ.get("FAKE_SERVE_LINE", "127.0.0.1:1"),
      flush=True)
mode = os.environ.get("FAKE_SERVE_MODE", "run")
if mode.startswith("exit:"):
    time.sleep(float(os.environ.get("FAKE_SERVE_EXIT_DELAY", "0.3")))
    sys.exit(int(mode.split(":", 1)[1]))
time.sleep(3600)
"""


def calendar_bytes(date, open_="09:00:00+09:00", close="15:30:00+09:00"):
    """Synthetic calendar bytes in the readDocFile days shape."""
    doc = {"days": {date: {"open": open_, "close": close}},
           "version": "CAL-SUPERVISOR-TEST"}
    return json.dumps(doc, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")


def read_pid(path):
    with open(path, encoding="utf-8") as f:
        return int(f.read().strip())


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def advance_to(clock, h, m=0, s=0):
    """Advance the injected clock to an explicit KST wall time today."""
    now = clock.now_kst()
    target = now.replace(hour=h, minute=m, second=s, microsecond=0)
    clock.advance((target - now).total_seconds())


class SupervisorTestBase(unittest.TestCase):
    """One mktemp sandbox per test; every supervisor is shut down on
    cleanup (all children reaped); supervisor log lines are captured,
    not printed, and dumped on any failure."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="hs-supervisor-test.")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.logs = []
        patch = mock.patch.object(cs, "_emit",
                                  lambda line: self.logs.append(line))
        patch.start()
        self.addCleanup(patch.stop)
        self._write_fakes()

    def _write_fakes(self):
        for name, body in (("fake_collector.py", FAKE_COLLECTOR),
                           ("fake_worker.py", FAKE_WORKER),
                           ("fake_serve.py", FAKE_SERVE)):
            path = os.path.join(self.tmp, name)
            with open(path, "w", encoding="utf-8") as f:
                f.write("#!%s\n%s" % (sys.executable, body))
            os.chmod(path, 0o755)

    def make_cfg(self, **over):
        cfg = cs.Config(
            data_root=self.tmp,
            serve_script=os.path.join(self.tmp, "fake_serve.py"),
            api_python=sys.executable,
            api_bind="127.0.0.1",
            api_port=0,
            api_restart_seconds=0.0,
            probe_host="127.0.0.1",
            probe_port=0,
            calendar_dir=os.path.join(self.tmp, "calendars"),
            calendar_index=os.path.join(self.tmp, "index.sha256"),
            collector_bin=os.path.join(self.tmp, "fake_collector.py"),
            notify_script=os.path.join(self.tmp, "fake_worker.py"),
            notify_config=os.path.join(self.tmp, "notify_config.json"),
            worker_python=sys.executable,
            profile="demo",
            session_start=dtime(8, 50),
            session_last_start=dtime(15, 30),
            session_watchdog=dtime(15, 40),
            tick_seconds=30.0,
            max_attempts=3,
            worker_restart_seconds=0.0,
            worker_max_restarts=5,
            tail_grace_seconds=0.0,
            kill_grace_seconds=2.0,
        )
        for key, value in over.items():
            setattr(cfg, key, value)
        return cfg

    def write_calendar_fixture(self, entries):
        """entries: [(file name, bytes)] — the volume files plus the
        matching baked INDEX."""
        caldir = os.path.join(self.tmp, "calendars")
        os.makedirs(caldir, exist_ok=True)
        lines = []
        for name, data in entries:
            with open(os.path.join(caldir, name), "wb") as f:
                f.write(data)
            lines.append("%s  calendars/%s"
                         % (hashlib.sha256(data).hexdigest(), name))
        with open(os.path.join(self.tmp, "index.sha256"), "w") as f:
            f.write("\n".join(lines) + "\n")

    def make_sup(self, clock=None, start_api=True, **over):
        self.write_calendar_fixture(
            [("synth-cal.json", calendar_bytes(over.pop("date", DATE)))])
        with open(os.path.join(self.tmp, "notify_config.json"), "w") as f:
            f.write("{}\n")
        os.makedirs(os.path.join(self.tmp, "runs"), exist_ok=True)
        sup = cs.Supervisor(self.make_cfg(**over), clock)
        if start_api:
            sup.api.start()
        sup.loop_started_mono = sup.clock.monotonic()
        self.addCleanup(sup.shutdown)
        return sup

    def wait_for(self, cond, timeout=15.0, what="condition"):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if cond():
                return
            time.sleep(0.05)
        self.fail("timed out waiting for %s\n--- supervisor log ---\n%s"
                  % (what, "\n".join(self.logs[-40:])))

    def assert_in_log(self, needle):
        self.assertTrue(any(needle in line for line in self.logs),
                        "expected in the supervisor log: %r\n--- log ---\n%s"
                        % (needle, "\n".join(self.logs[-40:])))

    def probe(self, sup, path, method="GET"):
        req = urlrequest.Request(
            "http://127.0.0.1:%d%s" % (sup.probe.port, path),
            data=b"" if method != "GET" else None, method=method)
        try:
            with urlrequest.urlopen(req, timeout=5) as r:
                return r.status, r.read().decode("utf-8"), dict(r.headers)
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8"), dict(e.headers)

    def start_probe(self, sup):
        sup.start_probe_server()
        self.wait_for(lambda: sup.probe.httpd is not None,
                      what="probe server start")


class ConfigTests(SupervisorTestBase):
    def test_defaults_match_the_documented_image_layout(self):
        cfg = cs.Config.from_env({})
        self.assertEqual(cfg.api_bind, "0.0.0.0")
        self.assertEqual(cfg.api_port, 8080)
        self.assertEqual(cfg.probe_port, 8081)
        self.assertEqual(cfg.session_start, dtime(8, 50))
        self.assertEqual(cfg.session_last_start, dtime(15, 30))
        self.assertEqual(cfg.session_watchdog, dtime(15, 40))
        self.assertEqual(cfg.max_attempts, 3)
        self.assertEqual(cfg.collector_bin, "/opt/hongscanner/bin/collector")
        self.assertEqual(cfg.notify_script,
                         "/opt/hongscanner/tools/notify/notify_dispatcher.py")
        self.assertEqual(cfg.calendar_index,
                         "/opt/hongscanner/CALENDAR_INDEX.sha256")
        self.assertEqual(cfg.runs_root, "/var/lib/hongscanner/runs")

    def test_env_overrides(self):
        cfg = cs.Config.from_env({"HS_DATA_ROOT": "/data",
                                  "HS_SESSION_START": "08:55",
                                  "HS_SESSION_MAX_ATTEMPTS": "2"})
        self.assertEqual(cfg.runs_root, "/data/runs")
        self.assertEqual(cfg.session_start, dtime(8, 55))
        self.assertEqual(cfg.max_attempts, 2)

    def test_config_refusals(self):
        for env in ({"HS_API_PORT": "70000"},
                    {"HS_DATA_ROOT": "relative"},
                    {"HS_SESSION_START": "8:50"},
                    {"HS_SESSION_START": "15:30",
                     "HS_SESSION_LAST_START": "08:50"},
                    {"HS_KIWOOM_PROFILE": "has space"}):
            with self.subTest(env=env):
                with self.assertRaises(cs.ConfigError):
                    cs.Config.from_env(env)


class CalendarTrustTests(SupervisorTestBase):
    def verify(self):
        return cs.verify_calendar_volume(
            os.path.join(self.tmp, "index.sha256"),
            os.path.join(self.tmp, "calendars"))

    def test_matching_volume_verifies(self):
        data = calendar_bytes(DATE)
        self.write_calendar_fixture([("synth-cal.json", data)])
        cals, faults = self.verify()
        self.assertEqual(faults, [])
        self.assertEqual(len(cals), 1)

    def test_hash_mismatch_refuses(self):
        self.write_calendar_fixture([("synth-cal.json", calendar_bytes(DATE))])
        with open(os.path.join(self.tmp, "calendars", "synth-cal.json"),
                  "wb") as f:
            f.write(calendar_bytes(DATE, open_="09:30:00+09:00"))
        cals, faults = self.verify()
        self.assertEqual(cals, [])
        self.assertTrue(any("sha256 mismatch" in f for f in faults))

    def test_absent_volume_file_refuses(self):
        self.write_calendar_fixture([("synth-cal.json", calendar_bytes(DATE))])
        os.remove(os.path.join(self.tmp, "calendars", "synth-cal.json"))
        cals, faults = self.verify()
        self.assertEqual(cals, [])
        self.assertTrue(any("absent" in f for f in faults))

    def test_unsafe_and_malformed_index_refuses(self):
        self.write_calendar_fixture([("synth-cal.json", calendar_bytes(DATE))])
        for line in ("../evil.json", "/etc/passwd", "garbage-line"):
            with open(os.path.join(self.tmp, "index.sha256"), "w") as f:
                f.write(line + "\n")
            cals, faults = self.verify()
            self.assertEqual(cals, [], line)
            self.assertTrue(faults, line)
        with open(os.path.join(self.tmp, "index.sha256"), "w") as f:
            f.write("\n")
        cals, faults = self.verify()
        self.assertEqual(cals, [])
        self.assertTrue(faults)   # the honest fault: an empty record line


class ProbeContractTests(SupervisorTestBase):
    def test_verdicts_latch_and_no_child_detail(self):
        sup = self.make_sup(clock=cs.FakeClock(BASE_KST), start_api=False)
        self.start_probe(sup)
        # Boot: initialization incomplete, API down, supervisor loop alive.
        code, body, _ = self.probe(sup, "/startup")
        self.assertEqual((code, body), (503, "initializing\n"))
        code, body, _ = self.probe(sup, "/ready")
        self.assertEqual((code, body), (503, "api unavailable\n"))
        code, body, _ = self.probe(sup, "/live")
        self.assertEqual((code, body), (200, "ok\n"))
        # Ticks without an API child: the calendar verifies but
        # initialization includes the API child — /startup stays 503.
        sup.tick()
        sup.tick()
        code, _, _ = self.probe(sup, "/startup")
        self.assertEqual(code, 503)
        # The API child serves: initialization completes once and latches.
        sup.api.start()
        self.wait_for(lambda: sup.api.state == "serving",
                      what="api serving")
        sup.tick()
        code, body, _ = self.probe(sup, "/startup")
        self.assertEqual((code, body), (200, "ok\n"))
        code, _, _ = self.probe(sup, "/ready")
        self.assertEqual(code, 200)
        # The latch holds after the API child dies; /ready follows the
        # API, not the latch.
        sup.api.proc.kill()
        sup.api.proc.wait(timeout=5)
        sup.tick()
        code, body, _ = self.probe(sup, "/ready")
        self.assertEqual((code, body), (503, "api unavailable\n"))
        code, _, _ = self.probe(sup, "/startup")
        self.assertEqual(code, 200)
        # GET-only; unknown paths 404.
        code, body, _ = self.probe(sup, "/no-such-probe")
        self.assertEqual((code, body), (404, "not found\n"))
        code, _, headers = self.probe(sup, "/ready", method="POST")
        self.assertEqual(code, 405)
        self.assertEqual(headers.get("Allow"), "GET")
        # Contract A: no child work-process state on any probe body.
        for path in ("/startup", "/ready", "/live", "/no-such-probe"):
            _, body, _ = self.probe(sup, path)
            for word in ("collector", "worker", "session", "pid"):
                self.assertNotIn(word, body.lower(), path)

    def test_live_staleness_on_injected_clock(self):
        clock = cs.FakeClock(BASE_KST)
        sup = self.make_sup(clock=clock)
        self.start_probe(sup)
        self.assertEqual(self.probe(sup, "/live")[0], 200)
        clock.advance(sup.loop_dead_after() + 1)
        code, body, _ = self.probe(sup, "/live")
        self.assertEqual((code, body), (503, "loop stalled\n"))


class SessionStartTests(SupervisorTestBase):
    def test_no_session_before_start_time(self):
        clock = cs.FakeClock(BASE_KST)          # 08:49:30
        sup = self.make_sup(clock=clock)
        sup.tick()
        clock.advance(2)                        # still before 08:50
        sup.tick()
        self.assertIsNone(sup.session)
        self.assertEqual(os.listdir(os.path.join(self.tmp, "runs")), [])

    def test_session_starts_at_0850_with_env_token_source(self):
        clock = cs.FakeClock(BASE_KST)
        sup = self.make_sup(clock=clock)
        advance_to(clock, 8, 50, 1)
        sup.tick()
        self.assertIsNotNone(sup.session)
        run_dir = sup.session.run_dir
        self.assertEqual(os.path.basename(run_dir), "ph1-%s-a" % DATE)
        argv_path = os.path.join(run_dir, "fake.argv.json")
        self.wait_for(lambda: os.path.isfile(argv_path),
                      what="collector argv dump")
        with open(argv_path, encoding="utf-8") as f:
            argv = json.load(f)
        self.assertIn("--profile=demo", argv)
        self.assertIn("--session-date=%s" % DATE, argv)
        self.assertIn("--out=%s" % run_dir, argv)
        self.assertIn("--calendar=%s" % os.path.join(
            self.tmp, "calendars", "synth-cal.json"), argv)
        # The container's only credential window (README §5.1): the
        # supervisor always declares the env token source.
        self.assertIn("--token-source=env", argv)
        worker_cmd = sup.session.worker.command()
        self.assertIn(os.path.join(run_dir, "events.hcj.jsonl"), worker_cmd)
        self.assertIn("--watch", worker_cmd)
        self.assert_in_log("session started run_id=ph1-%s-a" % DATE)
        self.assert_in_log("attempts=1/3")

    def test_committed_run_means_day_done(self):
        done = os.path.join(self.tmp, "runs", "ph1-%s-a" % DATE)
        os.makedirs(done)
        with open(os.path.join(done, COMMITTED), "wb"):
            pass
        clock = cs.FakeClock(datetime(2026, 11, 2, 9, 0, tzinfo=KST))
        sup = self.make_sup(clock=clock)
        sup.tick()
        sup.tick()
        self.assertIsNone(sup.session)
        self.assert_in_log("already COMMITTED")
        self.assertEqual(os.listdir(os.path.join(self.tmp, "runs")),
                         ["ph1-%s-a" % DATE])

    def test_unsealed_run_preserved_new_run_id(self):
        prior = os.path.join(self.tmp, "runs", "ph1-%s-a" % DATE)
        os.makedirs(prior)
        prior_file = os.path.join(prior, "input.hcj.jsonl")
        with open(prior_file, "wb") as f:
            f.write(b'{"kind":"calendar","seq":1}\n')
        clock = cs.FakeClock(datetime(2026, 11, 2, 10, 0, tzinfo=KST))
        sup = self.make_sup(clock=clock)
        sup.tick()
        self.assertIsNotNone(sup.session)
        self.assertEqual(os.path.basename(sup.session.run_dir),
                         "ph1-%s-b" % DATE)
        # The prior run was never resumed, never overwritten.
        with open(prior_file, "rb") as f:
            self.assertEqual(f.read(), b'{"kind":"calendar","seq":1}\n')
        self.assertFalse(cs.run_is_committed(prior))

    def test_attempt_cap_refuses_further_sessions(self):
        for suffix in "abc":
            os.makedirs(os.path.join(self.tmp, "runs",
                                     "ph1-%s-%s" % (DATE, suffix)))
        clock = cs.FakeClock(datetime(2026, 11, 2, 10, 0, tzinfo=KST))
        sup = self.make_sup(clock=clock, max_attempts=3)
        sup.tick()
        sup.tick()
        self.assertIsNone(sup.session)
        self.assert_in_log("attempt cap reached")

    def test_missing_prerequisite_starts_nothing(self):
        clock = cs.FakeClock(datetime(2026, 11, 2, 9, 0, tzinfo=KST))
        sup = self.make_sup(clock=clock,
                            collector_bin=os.path.join(self.tmp, "nope"))
        sup.tick()
        sup.tick()
        self.assertIsNone(sup.session)
        self.assert_in_log("prerequisites missing")
        self.assertEqual(os.listdir(os.path.join(self.tmp, "runs")), [])


class CollectorExitTests(SupervisorTestBase):
    def _run_attempt(self, clock, env):
        old = {k: os.environ.pop(k, None) for k in env}
        os.environ.update(env)
        try:
            sup = self.make_sup(clock=clock)
            advance_to(clock, 9, 0, 0)
            sup.tick()
            self.assertIsNotNone(sup.session)
            collector = sup.session.collector
            self.wait_for(lambda: collector.poll() is not None,
                          what="collector exit")
            clock.advance(5)
            sup.tick()
            self.assertIsNone(sup.session)
            return sup
        finally:
            for key in env:
                if old[key] is not None:
                    os.environ[key] = old[key]
                else:
                    os.environ.pop(key, None)

    def test_exit_zero_without_marker_is_not_a_sealed_day(self):
        # Fail-closed: a clean exit without the seal marker is no
        # completion evidence — the next tick starts a fresh run_id.
        clock = cs.FakeClock(BASE_KST)
        sup = self._run_attempt(clock, {"FAKE_COLLECTOR_MODE": "exit:0"})
        self.assert_in_log("outcome=COMMITTED")
        sup.tick()
        sup.tick()
        self.assertIsNotNone(sup.session)
        self.assertEqual(os.path.basename(sup.session.run_dir),
                         "ph1-%s-b" % DATE)
        self.assert_in_log("attempts=2/3")

    def test_exit_zero_with_marker_completes_the_day(self):
        clock = cs.FakeClock(BASE_KST)
        sup = self._run_attempt(clock, {"FAKE_COLLECTOR_MODE": "exit:0",
                                        "FAKE_COMMIT": "1"})
        self.assert_in_log("outcome=COMMITTED")
        sup.tick()
        sup.tick()
        self.assertIsNone(sup.session)
        self.assert_in_log("already COMMITTED")

    def test_exit_four_is_incomplete_and_a_new_attempt_follows(self):
        clock = cs.FakeClock(BASE_KST)
        sup = self._run_attempt(clock, {"FAKE_COLLECTOR_MODE": "exit:4"})
        self.assert_in_log("outcome=INCOMPLETE")
        sup.tick()
        sup.tick()
        self.assertIsNotNone(sup.session)
        self.assertEqual(os.path.basename(sup.session.run_dir),
                         "ph1-%s-b" % DATE)


class WatchdogTests(SupervisorTestBase):
    def test_watchdog_sigterm_ends_session_incomplete(self):
        clock = cs.FakeClock(BASE_KST)
        sup = self.make_sup(clock=clock)
        advance_to(clock, 9, 0, 0)
        sup.tick()
        self.assertIsNotNone(sup.session)
        run_dir = sup.session.run_dir
        collector = sup.session.collector
        # The fake collector registers its SIGTERM handler before it
        # writes its pid file — this wait is the barrier that makes the
        # watchdog SIGTERM below land on a booted, responsive child.
        self.wait_for(lambda: os.path.isfile(
                          os.path.join(run_dir, "fake.collector.pid")),
                      what="collector booted (pid file)")
        advance_to(clock, 15, 40, 1)
        sup.tick()
        self.assertIsNotNone(sup.session.watchdog_sent_at)
        self.wait_for(lambda: collector.poll() is not None,
                      what="collector exit after watchdog SIGTERM")
        clock.advance(5)
        sup.tick()
        self.assertIsNone(sup.session)
        self.assert_in_log("watchdog reached — collector still alive")
        self.assert_in_log("outcome=INCOMPLETE")
        worker_pid_path = os.path.join(run_dir, "fake.worker.pid")
        self.wait_for(lambda: os.path.isfile(worker_pid_path)
                      and not pid_alive(read_pid(worker_pid_path)),
                      what="worker stopped after session end")
        self.assertFalse(cs.run_is_committed(run_dir))   # unsealed, kept
        # Past the last-start bound: no further session today.
        advance_to(clock, 15, 45, 0)
        sup.tick()
        self.assertIsNone(sup.session)


class WorkerSupervisionTests(SupervisorTestBase):
    def test_abnormal_worker_exit_is_restarted_mid_session(self):
        clock = cs.FakeClock(BASE_KST)
        env = {"FAKE_WORKER_MODE": "exit:3", "FAKE_WORKER_EXIT_DELAY": "0.05"}
        old = {k: os.environ.pop(k, None) for k in env}
        os.environ.update(env)
        try:
            sup = self.make_sup(clock=clock)
            advance_to(clock, 9, 0, 0)
            sup.tick()
            worker = sup.session.worker
            self.wait_for(lambda: worker.proc is not None
                          and worker.proc.poll() is not None,
                          what="worker abnormal exit")
            clock.advance(5)
            sup.tick()                    # schedule (backoff 0)
            clock.advance(5)
            sup.tick()                    # respawn
            self.assertEqual(sup.session.worker_restarts, 1)
            self.wait_for(lambda: sup.session.worker.proc is not None,
                          what="worker respawn")
            self.assert_in_log("worker exited rc=3 mid-session")
            self.assert_in_log("worker restarted (attempt 1)")
        finally:
            for k, v in old.items():
                if v is not None:
                    os.environ[k] = v
                else:
                    os.environ.pop(k, None)

    def test_clean_worker_exit_is_not_restarted(self):
        clock = cs.FakeClock(BASE_KST)
        os.environ["FAKE_WORKER_MODE"] = "exit:0"
        try:
            sup = self.make_sup(clock=clock)
            advance_to(clock, 9, 0, 0)
            sup.tick()
            worker = sup.session.worker
            self.wait_for(lambda: worker.proc is not None
                          and worker.proc.poll() is not None,
                          what="worker clean exit")
            clock.advance(5)
            sup.tick()
            self.assertTrue(sup.session.worker_stopped)
            self.assert_in_log("worker exited 0 (clean stop) — not restarted")
            clock.advance(30)
            sup.tick()
            self.assertTrue(sup.session.worker_stopped)
        finally:
            os.environ.pop("FAKE_WORKER_MODE", None)


class ApiChildTests(SupervisorTestBase):
    """The real-process smoke: the supervisor supervises the REAL
    serve.py child and the /ready flips are observed over HTTP."""

    def test_real_serve_py_child_ready_flips_and_clean_stop(self):
        cfg = self.make_cfg(serve_script=SERVE_PY)
        self.write_calendar_fixture([("synth-cal.json",
                                      calendar_bytes(DATE))])
        os.makedirs(os.path.join(self.tmp, "runs"), exist_ok=True)
        os.makedirs(os.path.join(self.tmp, "notify"), exist_ok=True)
        sup = cs.Supervisor(cfg, cs.FakeClock(BASE_KST))
        self.addCleanup(sup.shutdown)
        self.start_probe(sup)
        # Before the child exists: /ready 503.
        code, body, _ = self.probe(sup, "/ready")
        self.assertEqual((code, body), (503, "api unavailable\n"))
        sup.api.start()
        # The SERVE line is the only startup evidence (tools/api
        # README §1): /ready goes 200 once the supervisor observed it.
        self.wait_for(lambda: sup.api.serve_line is not None,
                      what="SERVE line from the real serve.py child")
        self.assertTrue(sup.api.serve_line.startswith("SERVE 127.0.0.1:"))
        port = int(sup.api.serve_line.rsplit(":", 1)[1])
        code, _, _ = self.probe(sup, "/ready")
        self.assertEqual(code, 200)
        with urlrequest.urlopen("http://127.0.0.1:%d/status" % port,
                                timeout=5) as r:
            self.assertEqual(r.status, 200)
            self.assertIn("sessions", json.loads(r.read().decode("utf-8")))
        # The child dies: /ready 503 (traffic gating, not a restart of
        # the container).
        sup.api.proc.kill()
        sup.api.proc.wait(timeout=5)
        sup.tick()
        code, _, _ = self.probe(sup, "/ready")
        self.assertEqual(code, 503)
        # SIGTERM to a serving child is a clean exit 0 (drain contract).
        sup.api.start()
        self.wait_for(lambda: sup.api.state == "serving",
                      what="api serving again")
        self.assertEqual(sup.api.stop(grace=5), 0)


class SupervisorProcessTests(SupervisorTestBase):
    """The real cloud_supervisor process, wired through its documented
    env contract with the fake children, stopped with SIGTERM."""

    def _free_port(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        return port

    def test_full_lifecycle_sigterm_clean_and_children_reaped(self):
        # The real wall clock decides the date — and a supervisor tick
        # can land after local midnight. The volume therefore carries
        # today AND tomorrow: whichever date the first tick sees has a
        # session, so the test cannot flake across midnight.
        today = datetime.now(KST).date()
        tomorrow = today + timedelta(days=1)
        self.write_calendar_fixture([
            ("synth-cal.json", calendar_bytes(today.isoformat())),
            ("synth-cal-2.json", calendar_bytes(tomorrow.isoformat())),
        ])
        os.makedirs(os.path.join(self.tmp, "runs"), exist_ok=True)
        with open(os.path.join(self.tmp, "notify_config.json"), "w") as f:
            f.write("{}\n")
        env = os.environ.copy()
        env.update({
            "HS_DATA_ROOT": self.tmp,
            "HS_SERVE_SCRIPT": os.path.join(self.tmp, "fake_serve.py"),
            "HS_API_PYTHON": sys.executable,
            "HS_API_BIND": "127.0.0.1",
            "HS_API_PORT": "0",
            "HS_SUPERVISOR_PROBE_HOST": "127.0.0.1",
            "HS_SUPERVISOR_PROBE_PORT": str(self._free_port()),
            "HS_CALENDAR_DIR": os.path.join(self.tmp, "calendars"),
            "HS_CALENDAR_INDEX": os.path.join(self.tmp, "index.sha256"),
            "HS_COLLECTOR_BIN": os.path.join(self.tmp, "fake_collector.py"),
            "HS_NOTIFY_SCRIPT": os.path.join(self.tmp, "fake_worker.py"),
            "HS_NOTIFY_CONFIG": os.path.join(self.tmp, "notify_config.json"),
            "HS_WORKER_PYTHON": sys.executable,
            "HS_TICK_SECONDS": "1",
            # The real wall clock decides the date; the window is wide
            # open and the volume carries today AND tomorrow, so the
            # session starts on the first tick even when it lands after
            # local midnight.
            "HS_SESSION_START": "00:00",
            "HS_SESSION_LAST_START": "23:59",
            "HS_SESSION_WATCHDOG": "23:59",
            "HS_SESSION_TAIL_GRACE": "0",
            "HS_KILL_GRACE_SECONDS": "2",
            "PYTHONDONTWRITEBYTECODE": "1",
        })
        proc = subprocess.Popen([sys.executable, CS_SCRIPT], env=env,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True,
                                start_new_session=True)
        probe_port = int(env["HS_SUPERVISOR_PROBE_PORT"])

        def probe(path):
            try:
                with urlrequest.urlopen(
                        "http://127.0.0.1:%d%s" % (probe_port, path),
                        timeout=5) as r:
                    return r.status
            except urllib.error.HTTPError as e:
                return e.code
            except urllib.error.URLError:
                return None

        def wait_probe(path, want, timeout=30):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if probe(path) == want:
                    return
                time.sleep(0.2)
            self.fail("probe %s never reached %s" % (path, want))

        try:
            wait_probe("/startup", 200)
            wait_probe("/ready", 200)
            self.assertEqual(probe("/live"), 200)
            runs = os.path.join(self.tmp, "runs")
            self.wait_for(lambda: bool(os.listdir(runs)),
                          what="session run directory")
            run_name = os.listdir(runs)[0]
            self.assertTrue(
                any(run_name.startswith("ph1-%s-" % d)
                    for d in (today.isoformat(), tomorrow.isoformat())),
                run_name)
            pid_path = os.path.join(runs, run_name, "fake.collector.pid")
            self.wait_for(lambda: os.path.isfile(pid_path),
                          what="collector pid file")
            worker_pid_path = os.path.join(runs, run_name,
                                           "fake.worker.pid")
            self.wait_for(lambda: os.path.isfile(worker_pid_path),
                          what="worker pid file")
            # SIGTERM: the supervisor drains everything and exits 0.
            proc.terminate()
            out, _ = proc.communicate(timeout=30)
            self.assertEqual(proc.returncode, 0, out[-2000:])
            self.wait_for(lambda: not pid_alive(read_pid(pid_path)),
                          what="collector reaped")
            self.wait_for(lambda: not pid_alive(read_pid(worker_pid_path)),
                          what="worker reaped")
            self.assertIn("SUPERVISOR session started run_id=%s" % run_name,
                          out)
            self.assertIn("shutdown: run %s left unsealed/preserved"
                          % run_name, out)
            self.assertIn("stopped (clean, exit 0)", out)
            # The child's SERVE line reached the log verbatim.
            self.assertTrue(any(line.startswith("SERVE ")
                                for line in out.splitlines()))
        finally:
            if proc.poll() is None:
                # Failure path: the supervisor's children must not be
                # orphaned. Signal the whole process group — SIGTERM
                # first so a draining supervisor still reaps them, then
                # SIGKILL as the backstop.
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                    proc.wait(timeout=10)
                except (ProcessLookupError, subprocess.TimeoutExpired):
                    pass
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
