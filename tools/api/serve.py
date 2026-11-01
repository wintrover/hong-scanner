#!/usr/bin/env python3
"""Hong Scanner read-only API (VS-3 PR-6).

Contract: tools/api/README.md. The API serves RECORDED facts only —
the run directories (--runs) and the append-only event ledger
(--ledger), plus the optional delivery ledger (--delivery). It judges
nothing, replays nothing, recomputes no verdict: every response is a
projection of recorded bytes plus the cheap rederivations the contract
names (sha256 comparison against a recorded CHECKSUMS.sha256, presence
of recorded markers and operator-recorded verify output). Running the
Nim verify binary is outside this process's scope, always.

Security boundaries (README §5):
  - binds 127.0.0.1 only; there is no option to bind anything else;
  - GET only — every other method is a JSON 405;
  - identifiers are validated before any path is built (event ids must
    be 64 lowercase hex digits, session ids must name an existing run
    directory); "..", separators and percent-encoded traversals are
    rejected before lookup and the resolved path must stay inside the
    runs root;
  - responses never contain filesystem paths, credential values, or
    the non-projected run.json fields (host, pid, egress_ip, ...);
  - artifact names read from a recorded CHECKSUMS.sha256 are untrusted
    input: names outside the safe set are refused, never opened.

Python 3.13, standard library only (http.server). No new dependencies.
"""

import argparse
import hashlib
import json
import os
import re
import signal
import sys
import threading
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

BIND_HOST = "127.0.0.1"

EVENT_ID_RE = re.compile(r"^[0-9a-f]{64}$")
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
# sha256sum line: "<64 lowercase hex>  <name>" (two-space text mode).
CHECKSUM_LINE_RE = re.compile(r"^([0-9a-f]{64})  (.+)$")
# Untrusted artifact names from a recorded CHECKSUMS.sha256: a single
# safe path component only. Anything else is refused, never opened.
SAFE_ARTIFACT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$")

RUN_JSON = "run.json"
INPUT_JSONL = "input.hcj.jsonl"
EVENTS_JSONL = "events.hcj.jsonl"
CHECKSUMS = "CHECKSUMS.sha256"
COMMITTED_MARKER = "input.hcj.jsonl.committed"
VERIFY_OUT = "verify.stdout"

# run.json fields the API projects. Everything else recorded in the
# file (host, pid, egress_ip, build details, ...) is deliberately not
# served: the projection serves what consumers need, not the file.
RUN_JSON_FIELDS = ("session_date", "run_id", "started_at", "code_commit")

CANDIDATE_PREFIX = "CANDIDATE_"


class DataFault(Exception):
    """A recorded file is unreadable or violates its recorded shape.
    Fail-closed: the endpoint answers HTTP 500, it never silently skips
    a corrupted record. Messages carry file basenames only — never
    absolute paths."""


def canonical_bytes(obj):
    """Deterministic response encoding: UTF-8, compact separators, keys
    in codepoint-ascending order (the HCJ canonical discipline). The
    caller appends the single trailing LF."""
    return json.dumps(obj, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")


def _reason(exc):
    """A path-free reason string for error messages."""
    return getattr(exc, "strerror", None) or exc.__class__.__name__


def sha256_file(path):
    """sha256 hex of the file bytes, or None when the file is absent.
    Any other read fault is a DataFault (fail-closed), never a silent
    mismatch."""
    try:
        with open(path, "rb") as f:
            digest = hashlib.sha256()
            for chunk in iter(lambda: f.read(65536), b""):
                digest.update(chunk)
            return digest.hexdigest()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise DataFault("%s unreadable: %s"
                        % (os.path.basename(path), _reason(exc)))


def read_committed_lines(path):
    """JSONL records committed to `path` as parsed JSON objects, in
    file order. Same reading discipline as the notify ledgers: a
    trailing line without LF is a concurrently-appending record that
    has not been committed yet and is skipped, never half-consumed. A
    malformed COMMITTED line is a DataFault — corruption is not
    skipped. Returns (objects, file_present)."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except FileNotFoundError:
        return [], False
    except OSError as exc:
        raise DataFault("%s unreadable: %s"
                        % (os.path.basename(path), _reason(exc)))
    if data and not data.endswith(b"\n"):
        data = data[:data.rfind(b"\n") + 1]
    objects = []
    if data:
        for i, raw in enumerate(data.split(b"\n")[:-1], start=1):
            if not raw:
                raise DataFault("%s line %d is empty"
                                % (os.path.basename(path), i))
            try:
                obj = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, ValueError) as exc:
                raise DataFault("%s line %d is not valid UTF-8 JSON: %s"
                                % (os.path.basename(path), i, exc))
            if not isinstance(obj, dict):
                raise DataFault("%s line %d is not a JSON object"
                                % (os.path.basename(path), i))
            objects.append(obj)
    return objects, True


class Projector:
    """Read-only projection of the recorded sources. Every method
    returns plain JSON-safe data (strings, integers, booleans, null,
    arrays, objects — no floats)."""

    def __init__(self, runs_root, ledger_path, delivery_path=None):
        self.runs_root = runs_root
        self.ledger_path = ledger_path
        self.delivery_path = delivery_path
        self._runs_real = os.path.realpath(runs_root)

    # ---- run directories -------------------------------------------------

    def _session_names(self):
        try:
            names = os.listdir(self.runs_root)
        except OSError as exc:
            raise DataFault("runs directory unreadable: %s" % _reason(exc))
        return sorted(n for n in names
                      if os.path.isdir(os.path.join(self.runs_root, n)))

    def _run_dir(self, session):
        """The run directory for a validated session id, or None. The
        resolved path must stay inside the runs root (defense in depth
        behind the id validation)."""
        candidate = os.path.realpath(os.path.join(self.runs_root, session))
        if candidate != self._runs_real and \
                candidate.startswith(self._runs_real + os.sep) and \
                os.path.isdir(candidate):
            return candidate
        return None

    def _run_json(self, run_dir):
        path = os.path.join(run_dir, RUN_JSON)
        try:
            with open(path, "rb") as f:
                data = f.read()
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise DataFault("%s unreadable: %s" % (RUN_JSON, _reason(exc)))
        try:
            obj = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise DataFault("%s is not valid UTF-8 JSON: %s" % (RUN_JSON, exc))
        if not isinstance(obj, dict):
            raise DataFault("%s is not a JSON object" % RUN_JSON)
        return obj

    @staticmethod
    def _run_summary(name, run_json):
        """The whitelisted projection of one run.json. Absent or
        non-string fields are null — absence is served, not filled."""
        summary = {"session": name, "run_json_present": run_json is not None}
        for field in RUN_JSON_FIELDS:
            value = run_json.get(field) if isinstance(run_json, dict) else None
            summary[field] = value if isinstance(value, str) else None
        return summary

    def sessions(self):
        names = self._session_names()
        return {"count": len(names),
                "sessions": [self._run_summary(n, self._run_json(
                                 os.path.join(self.runs_root, n)))
                             for n in names]}

    # ---- event ledger ----------------------------------------------------

    def _ledger_events(self):
        """Committed ledger events in ledger order. Minimal shape
        validation for the fields this projection relies on; anything
        else in a record is served verbatim. Returns (events, present)."""
        events, present = read_committed_lines(self.ledger_path)
        if present:
            for i, ev in enumerate(events, start=1):
                for field in ("event_id", "event_type", "session_id",
                              "severity"):
                    if not isinstance(ev.get(field), str):
                        raise DataFault("ledger.hcj.jsonl line %d has no %s"
                                        % (i, field))
        return events, present

    def _delivery_latest(self):
        """Latest delivery record per (event_id, device_id), the same
        last-record-wins rule the delivery ledger documents. Returns
        (map, configured, present) where map is {} when absent."""
        if self.delivery_path is None:
            return {}, False, None
        records, present = read_committed_lines(self.delivery_path)
        latest = {}
        if present:
            for i, rec in enumerate(records, start=1):
                if not isinstance(rec.get("device_id"), str) or \
                        not isinstance(rec.get("state"), str) or \
                        not isinstance(rec.get("attempts"), int) or \
                        isinstance(rec.get("attempts"), bool) or \
                        not isinstance(rec.get("event_id"), str):
                    raise DataFault("delivery.hcj.jsonl line %d violates "
                                    "the recorded shape" % i)
                latest[(rec["event_id"], rec["device_id"])] = rec
        return latest, True, present

    def _delivery_for(self, latest, event_id):
        """Per-device latest records for one event, sorted by device_id.
        The event_id itself is the map key, not repeated per record."""
        rows = [rec for (eid, _), rec in latest.items() if eid == event_id]
        return [{k: v for k, v in rec.items() if k != "event_id"}
                for rec in sorted(rows, key=lambda r: r["device_id"])]

    # ---- endpoints -------------------------------------------------------

    def status(self):
        names = self._session_names()
        latest_summary = None
        if names:
            latest_summary = self._run_summary(
                names[-1], self._run_json(os.path.join(self.runs_root,
                                                       names[-1])))
        events, ledger_present = self._ledger_events()
        if ledger_present:
            last = events[-1]
            events_block = {
                "ledger_present": True,
                "count": len(events),
                "by_type": dict(sorted(Counter(
                    ev["event_type"] for ev in events).items())),
                "by_severity": dict(sorted(Counter(
                    ev["severity"] for ev in events).items())),
                "latest_session_id": last["session_id"],
                "latest_event": {k: last[k]
                                 for k in ("event_id", "event_type",
                                           "observed_at")
                                 if k in last},
            }
        else:
            events_block = {"ledger_present": False, "count": None,
                            "by_type": None, "by_severity": None,
                            "latest_session_id": None, "latest_event": None}
        latest_deliveries, configured, present = self._delivery_latest()
        if not configured:
            delivery_block = {"configured": False, "present": None,
                              "by_state": None, "pairs": None,
                              "devices": None}
        elif not present:
            delivery_block = {"configured": True, "present": False,
                              "by_state": None, "pairs": None,
                              "devices": None}
        else:
            delivery_block = {
                "configured": True,
                "present": True,
                "by_state": dict(sorted(Counter(
                    rec["state"] for rec in latest_deliveries.values())
                    .items())),
                "pairs": len(latest_deliveries),
                "devices": len({rec["device_id"] for
                                rec in latest_deliveries.values()}),
            }
        return {"sessions": {"count": len(names), "latest": latest_summary},
                "events": events_block,
                "delivery": delivery_block}

    def candidates(self):
        events, ledger_present = self._ledger_events()
        if not ledger_present:
            return {"ledger_present": False, "session_id": None,
                    "count": None, "events": None}
        session_id = events[-1]["session_id"]
        chosen = [ev for ev in events
                  if ev["session_id"] == session_id
                  and ev["event_type"].startswith(CANDIDATE_PREFIX)]
        return {"ledger_present": True, "session_id": session_id,
                "count": len(chosen), "events": chosen}

    def events(self, session_filter=None):
        events, ledger_present = self._ledger_events()
        latest_deliveries, configured, present = self._delivery_latest()
        if not ledger_present:
            return {"ledger_present": False, "count": None, "events": None,
                    "delivery": None}
        if session_filter is not None:
            events = [ev for ev in events
                      if ev["session_id"] == session_filter]
        delivery = {}
        if configured and present:
            delivered_ids = {eid for eid, _ in latest_deliveries}
            delivery = {ev["event_id"]:
                        self._delivery_for(latest_deliveries,
                                           ev["event_id"])
                        for ev in events
                        if ev["event_id"] in delivered_ids}
        return {"ledger_present": True, "count": len(events),
                "events": events, "delivery": delivery}

    def event(self, event_id):
        """The one event fact and its delivery records, or None when the
        id is not in the ledger (the handler answers 404)."""
        events, ledger_present = self._ledger_events()
        latest_deliveries, _, present = self._delivery_latest()
        for ev in events:
            if ev["event_id"] == event_id:
                delivery = self._delivery_for(latest_deliveries, event_id) \
                    if ledger_present and present else []
                return {"event": ev, "delivery": delivery}
        return None

    # ---- session verification --------------------------------------------

    @staticmethod
    def _recorded_output_line(run_dir, filename, prefix):
        """The first recorded line starting with `prefix` in an
        operator-recorded output file, verbatim. The API quotes what an
        operator recorded; it never runs or interprets the tool."""
        path = os.path.join(run_dir, filename)
        if not os.path.isfile(path):
            return {"recorded": False}
        try:
            with open(path, "r", encoding="utf-8") as f:
                text = f.read()
        except OSError as exc:
            return {"recorded": False,
                    "note": "%s unreadable: %s" % (filename, _reason(exc))}
        except UnicodeDecodeError:
            return {"recorded": False,
                    "note": "%s is not valid UTF-8" % filename}
        for line in text.splitlines():
            if line.startswith(prefix):
                return {"recorded": True, "source": filename, "line": line}
        return {"recorded": False,
                "note": "%s present but no %s line recorded"
                        % (filename, prefix)}

    def _checksums(self, run_dir):
        path = os.path.join(run_dir, CHECKSUMS)
        try:
            with open(path, "r", encoding="utf-8") as f:
                text = f.read()
        except FileNotFoundError:
            return {"present": False, "artifacts": []}
        except OSError as exc:
            raise DataFault("%s unreadable: %s" % (CHECKSUMS, _reason(exc)))
        except UnicodeDecodeError:
            raise DataFault("%s is not valid UTF-8" % CHECKSUMS)
        artifacts = []
        for i, line in enumerate(text.splitlines(), start=1):
            if not line:
                continue
            match = CHECKSUM_LINE_RE.match(line)
            if match is None:
                raise DataFault("%s line %d is not a sha256sum line"
                                % (CHECKSUMS, i))
            recorded, name = match.group(1), match.group(2)
            safe = SAFE_ARTIFACT_RE.match(name) is not None \
                and ".." not in name and "/" not in name and "\\" not in name
            if safe:
                computed = sha256_file(os.path.join(run_dir, name))
            else:
                computed = None  # untrusted name: refused, never opened
            entry = {"file": name,
                     "recorded_sha256": recorded,
                     "computed_sha256": computed,
                     "match": computed == recorded if computed else False}
            if not safe:
                entry["note"] = "unsafe artifact name refused"
            artifacts.append(entry)
        return {"present": True, "artifacts": artifacts}

    def verification(self, session):
        run_dir = self._run_dir(session)
        if run_dir is None:
            return None
        run_json = self._run_json(run_dir)
        input_events, _ = read_committed_lines(
            os.path.join(run_dir, INPUT_JSONL))
        events_sha = sha256_file(os.path.join(run_dir, EVENTS_JSONL))
        return {
            "session": session,
            "run_json_present": run_json is not None,
            "session_date": run_json.get("session_date")
            if isinstance(run_json, dict)
            and isinstance(run_json.get("session_date"), str) else None,
            "code_commit": run_json.get("code_commit")
            if isinstance(run_json, dict)
            and isinstance(run_json.get("code_commit"), str) else None,
            "committed_marker": {"file": COMMITTED_MARKER,
                                 "present": os.path.isfile(
                                     os.path.join(run_dir,
                                                  COMMITTED_MARKER))},
            "session_end_recorded": any(
                ev.get("kind") == "session_end" for ev in input_events),
            "events_file": {"present": events_sha is not None,
                            "sha256": events_sha},
            "checksums": self._checksums(run_dir),
            "replay_verdict": self._recorded_output_line(
                run_dir, VERIFY_OUT, "VERDICT"),
        }


class Handler(BaseHTTPRequestHandler):
    """GET-only JSON handler. Every response body — success or error —
    is canonical JSON bytes plus one trailing LF."""

    server_version = "HongScannerAPI/1"
    protocol_version = "HTTP/1.1"
    projector = None  # set by main() before the server starts

    # -- responses --

    def _send_json(self, code, obj, extra_headers=()):
        body = canonical_bytes(obj) + b"\n"
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        for key, value in extra_headers:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _not_found(self):
        # No reflection: the message never echoes the requested path.
        self._send_json(404, {"error": {"code": "not_found",
                                        "message": "no such resource"}})

    def _method_not_allowed(self):
        self._send_json(405, {"error": {"code": "method_not_allowed",
                                        "message": "GET only"}},
                        extra_headers=(("Allow", "GET"),))

    def send_error(self, code, message=None, explain=None):
        """http.server's internal errors (bad request line, unknown
        method, ...) as JSON, so no HTML body ever leaves the API."""
        self._send_json(code, {"error": {"code": "http_error",
                                         "message": message or "http error"}})

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n"
                         % (self.address_string(), fmt % args))

    # -- methods --

    def do_GET(self):
        split = urlsplit(self.path)
        path = unquote(split.path)
        projector = self.projector
        try:
            if path == "/status":
                body = projector.status()
            elif path == "/candidates":
                body = projector.candidates()
            elif path == "/events":
                values = parse_qs(split.query).get("session_id")
                body = projector.events(values[0] if values else None)
            elif path.startswith("/events/"):
                event_id = path[len("/events/"):]
                if EVENT_ID_RE.match(event_id) is None:
                    return self._not_found()
                body = projector.event(event_id)
                if body is None:
                    return self._not_found()
            elif path == "/sessions":
                body = projector.sessions()
            elif path.startswith("/sessions/") and \
                    path.endswith("/verification"):
                session = path[len("/sessions/"):-len("/verification")]
                body = self._verification(projector, session)
                if body is None:
                    return self._not_found()
            else:
                return self._not_found()
        except DataFault as exc:
            return self._send_json(500, {"error": {"code": "data_fault",
                                                   "message": str(exc)}})
        self._send_json(200, body)

    @staticmethod
    def _verification(projector, session):
        """Path-traversal guard for the session id: explicit refusal of
        separators, dot segments and any id outside the recorded run
        directory names, before and behind the projector's own
        containment check."""
        if session in ("", ".", "..") or ".." in session or \
                "/" in session or "\\" in session or \
                SESSION_ID_RE.match(session) is None:
            return None
        return projector.verification(session)

    def do_POST(self):
        self._method_not_allowed()

    def do_PUT(self):
        self._method_not_allowed()

    def do_DELETE(self):
        self._method_not_allowed()

    def do_PATCH(self):
        self._method_not_allowed()

    def do_HEAD(self):
        self._method_not_allowed()

    def do_OPTIONS(self):
        self._method_not_allowed()


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="serve.py",
        description="Hong Scanner read-only API — serves recorded facts "
                    "from a runs directory and an event ledger on "
                    "127.0.0.1 only.")
    parser.add_argument("--runs", required=True, metavar="DIR",
                        help="runs root directory (read-only)")
    parser.add_argument("--ledger", required=True, metavar="FILE",
                        help="event ledger JSONL (read-only)")
    parser.add_argument("--delivery", default=None, metavar="FILE",
                        help="delivery ledger JSONL (read-only, optional)")
    parser.add_argument("--port", required=True, type=int, metavar="N",
                        help="TCP port on 127.0.0.1 (0 = ephemeral)")
    args = parser.parse_args(argv)

    if not (0 <= args.port <= 65535):
        parser.error("--port must be between 0 and 65535")
    if not os.path.isdir(args.runs):
        sys.stderr.write("serve.py: --runs is not an existing directory\n")
        return 2

    projector = Projector(args.runs, args.ledger, args.delivery)
    Handler.projector = projector
    try:
        server = ThreadingHTTPServer((BIND_HOST, args.port), Handler)
    except OSError as exc:
        sys.stderr.write("serve.py: cannot bind %s:%d: %s\n"
                         % (BIND_HOST, args.port, _reason(exc)))
        return 4
    server.daemon_threads = True

    def _shutdown(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)
    print("SERVE %s:%d" % (BIND_HOST, server.server_address[1]), flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
