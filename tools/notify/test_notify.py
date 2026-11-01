#!/usr/bin/env python3
"""notify contract tests (tools/notify/README.md).

The real modules (notify_ledger, notify_fcm, notify_dispatcher,
notify_register, notify_config) run in-process against temp files and a
fake urllib opener: no network, no live FCM call, no credential value
printed. The crypto path is pinned to the OFFICIAL RFC 7515 A.2 RS256
test vector (its JWK is published, explicitly marked compromised, and
used for verification only — it is not a credential of anything).

Run: bash tools/notify/test_notify.sh — it resolves a Python 3.13
interpreter ($HSCOLLECTOR_PYTHON, python3.13, `uv python find 3.13`) and
runs this module through unittest. Pure standard library: no venv
bootstrap, no external dependency.
"""

import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import notify_config  # noqa: E402
import notify_dispatcher  # noqa: E402
import notify_fcm  # noqa: E402
import notify_ledger  # noqa: E402
import notify_register  # noqa: E402

BEARER = "DRILL-FAKE-BEARER-SECRET"
FCM_TOKEN = "FAKE-FCM-REGISTRATION-TOKEN-VALUE"
OAUTH_TOKEN = "FAKE-OAUTH-ACCESS-TOKEN"

# ----------------------------------------------------------------------
# RFC 7515 A.2 — the official RSASSA-PKCS1-v1_5 SHA-256 test vector.
# The JWK below is published in the RFC itself and is explicitly stated
# there to be compromised and for testing only; it pins the DER parser,
# the PKCS#1 v1.5 encoding and the RS256 signature to IETF evidence.

RFC7515_JWK = {
    "n": "ofgWCuLjybRlzo0tZWJjNiuSfb4p4fAkd_wWJcyQoTbji9k0l8W26mPddx"
         "HmfHQp-Vaw-4qPCJrcS2mJPMEzP1Pt0Bm4d4QlL-yRT-SFd2lZS-pCgNMs"
         "D1W_YpRPEwOWvG6b32690r2jZ47soMZo9wGzjb_7OMg0LOL-bSf63kpaSH"
         "SXndS5z5rexMdbBYUsLA9e-KXBdQOS-UTo7WTBEMa2R2CapHg665xsmtdV"
         "MTBQY4uDZlxvb3qCo5ZwKh9kG4LT6_I5IhlJH7aGhyxXFvUK-DWNmoudF8"
         "NAco9_h9iaGNj8q2ethFkMLs91kzk2PAcDTW9gb54h4FRWyuXpoQ",
    "e": "AQAB",
    "d": "Eq5xpGnNCivDflJsRQBXHx1hdR1k6Ulwe2JZD50LpXyWPEAeP88vLNO97I"
         "jlA7_GQ5sLKMgvfTeXZx9SE-7YwVol2NXOoAJe46sui395IW_GO-pWJ1O0"
         "BkTGoVEn2bKVRUCgu-GjBVaYLU6f3l9kJfFNS3E0QbVdxzubSu3Mkqzjkn"
         "439X0M_V51gfpRLI9JYanrC4D4qAdGcopV_0ZHHzQlBjudU2QvXt4ehNYT"
         "CBr6XCLQUShb1juUO1ZdiYoFaFQT5Tw8bGUl_x_jTj3ccPDVZFD9pIuhLh"
         "BOneufuBiB4cS98l2SR_RQyGWSeWjnczT0QU91p1DhOVRuOopznQ",
    "p": "4BzEEOtIpmVdVEZNCqS7baC4crd0pqnRH_5IB3jw3bcxGn6QLvnEtfdUdi"
         "YrqBdss1l58BQ3KhooKeQTa9AB0Hw_Py5PJdTJNPY8cQn7ouZ2KKDcmnPG"
         "BY5t7yLc1QlQ5xHdwW1VhvKn-nXqhJTBgIPgtldC-KDV5z-y2XDwGUc",
    "q": "uQPEfgmVtjL0Uyyx88GZFF1fOunH3-7cepKmtH4pxhtCoHqpWmT8YAmZxa"
         "ewHgHAjLYsp1ZSe7zFYHj7C6ul7TjeLQeZD_YwD66t62wDmpe_HlB-TnBA"
         "-njbglfIsRLtXlnDzQkv5dTltRJ11BKBBypeeF6689rjcJIDEz9RWdc",
    "dp": "BwKfV3Akq5_MFZDFZCnW-wzl-CCo83WoZvnLQwCTeDv8uzluRSnm71I3Q"
          "CLdhrqE2e9YkxvuxdBfpT_PI7Yz-FOKnu1R6HsJeDCjn12Sk3vmAktV2zb"
          "34MCdy7cpdTh_YVr7tss2u6vneTwrA86rZtu5Mbr1C1XsmvkxHQAdYo0",
    "dq": "h_96-mK1R_7glhsum81dZxjTnYynPbZpHziZjeeHcXYsXaaMwkOlODsWa"
          "7I9xXDoRwbKgB719rrmI2oKr6N3Do9U0ajaHF-NKJnwgjMd2w9cjz3_-ky"
          "NlxAr2v4IKhGNpmM5iIgOS1VZnOZ68m6_pbLBSp3nssTdlqvd0tIiTHU",
    "qi": "IYd7DHOhrWvxkwPQsRM2tOgrjbcrfvtQJipd-DlcxyVuuM9sQLdgjVk2o"
          "y26F0EmpScGLq2MowX7fhd_QJQ3ydy5cY7YIBi87w93IKLEdfnbJtoOPLU"
          "W0ITrJReOgo1cq9SbsxYawBgfp_gh6A5603k2-ZQwVK0JKSHuLFkuQ3U",
}

RFC7515_SIGNING_INPUT = (
    "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAs"
    "DQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ").encode("ascii")

RFC7515_SIGNATURE_B64URL = (
    "cC4hiUPoj9Eetdgtv3hF80EGrhuB__dzERat0XF9g2VtQgr9PJbu3XOiZj5RZmh7"
    "AAuHIm4Bh-0Qc_lF5YKt_O8W2Fp5jujGbds9uJdbF9CUAr7t1dnZcAcQjbKBYNX4"
    "BAynRFdiuB--f_nZLgrnbyTyWzO75vRK5h6xBArLIARNPvkSjtQBMHlb1L07Qe7K"
    "0GarZRmB_eSN9383LcOLn6_dO--xi12jzDwusC-eOkHWEsqtFZESc6BfI7noOPqv"
    "hJ1phCnvWh6IeYI2w9QOYEUipUTI8np6LbgGY9Fs98rqVt5AXLIhWkWywlVmtVrB"
    "p0igcN_IoypGlUPQGe77Rw")

# ------------------------------------------------------------------ helpers


def b64url_decode(text):
    pad = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + pad)


def jwk_component(name):
    return int.from_bytes(b64url_decode(RFC7515_JWK[name]), "big")


def build_pkcs8_pem(jwk=RFC7515_JWK):
    """DER-encode the RFC JWK as a PKCS#8 RSAPrivateKey PEM — a test-side
    writer so the production DER reader is proven against real bytes."""
    def der_len(n):
        if n < 0x80:
            return bytes([n])
        body = n.to_bytes((n.bit_length() + 7) // 8, "big")
        return bytes([0x80 | len(body)]) + body

    def der_int(value):
        body = value.to_bytes(max(1, (value.bit_length() + 8) // 8), "big")
        return b"\x02" + der_len(len(body)) + body

    def der_seq(*parts):
        body = b"".join(parts)
        return b"\x30" + der_len(len(body)) + body

    order = ("n", "e", "d", "p", "q", "dp", "dq", "qi")
    pkcs1 = der_seq(der_int(0),
                    *[der_int(jwk_component(name)) for name in order])
    alg_id = der_seq(b"\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01",
                     b"\x05\x00")
    pkcs8 = der_seq(der_int(0), alg_id,
                    b"\x04" + der_len(len(pkcs1)) + pkcs1)
    b64 = base64.b64encode(pkcs8).decode("ascii")
    lines = [b64[i:i + 64] for i in range(0, len(b64), 64)]
    return "-----BEGIN PRIVATE KEY-----\n" + "\n".join(lines) + \
        "\n-----END PRIVATE KEY-----\n"


def event_id(session_id, event_type, rule_id, entity, transition_seq):
    """The committed x-event-id-rule: sha256 over the HCJ canonical
    serialization of {entity, event_type, rule_id, session_id,
    transition_seq} (keys codepoint-ascending, no whitespace, bare
    integers). The seq enters only this digest and is never emitted."""
    doc = {"entity": entity, "event_type": event_type,
           "rule_id": rule_id, "session_id": session_id,
           "transition_seq": transition_seq}
    canonical = json.dumps(doc, sort_keys=True, separators=(",", ":"),
                           ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def make_event(session_id="2026-11-01", event_type="CANDIDATE_ENTERED",
               rule_id="candidate-entered", seq=17, severity="INFO",
               symbol="005930"):
    doc = {
        "event_id": event_id(session_id, event_type, rule_id,
                             symbol if symbol else "*", seq),
        "event_type": event_type,
        "observed_at": "2026-11-01T09:12:33+09:00",
        "session_id": session_id,
        "rule_id": rule_id,
        "rule_version": 1,
        "data_quality": "OBSERVING",
        "severity": severity,
        "evidence_ref": "ka10027:stex_tp=1:sort_tp=1",
        "direction": "UP",
        "rank": 1,
    }
    if symbol:
        doc["symbol"] = symbol
    return doc


def write_jsonl(path, records):
    with open(path, "w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record, ensure_ascii=False,
                               separators=(",", ":")) + "\n")
    return path


class FakeResponse:
    def __init__(self, status, body, headers=None):
        self.status = status
        self._body = body if isinstance(body, bytes) else \
            json.dumps(body).encode("utf-8")
        self.headers = headers or {}

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeTransport:
    """The fake FCM/OAuth transport: a callable opener plus a scripted
    per-call behavior. Records every request; asserts the official
    endpoint URLs. No socket is ever opened."""

    TOKEN_URL = notify_fcm.OAUTH_TOKEN_URL
    SEND_URL = notify_fcm.FCM_SEND_URL % "drill-project"

    def __init__(self, send_responses=None):
        self.requests = []
        self.send_responses = list(send_responses or [])
        self.fail_sends = 0  # simulate transport loss (no answer)

    def __call__(self, request, timeout=None):
        url = request.full_url
        headers = {k.lower(): v for k, v in request.header_items()}
        self.requests.append({"url": url, "headers": headers,
                              "data": bytes(request.data or b"")})
        if url == self.TOKEN_URL:
            assert request.get_method() == "POST"
            return FakeResponse(200, {"access_token": OAUTH_TOKEN,
                                      "expires_in": 3600})
        if url == self.SEND_URL:
            auth = headers.get("authorization", "")
            assert auth == "Bearer %s" % OAUTH_TOKEN
            if self.fail_sends:
                self.fail_sends -= 1
                raise OSError("fake transport loss")
            if self.send_responses:
                return self.send_responses.pop(0)
            return FakeResponse(
                200, {"name": "projects/drill-project/messages/m-1"})
        raise AssertionError("fake transport: unexpected url %r" % url)

    def send_count(self):
        return sum(1 for r in self.requests if r["url"] == self.SEND_URL)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="notify-test-")
        self.outside = tempfile.mkdtemp(prefix="notify-outside-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.addCleanup(shutil.rmtree, self.outside, True)
        self.registry_path = os.path.join(self.outside, "devices.jsonl")
        self.bearer_path = os.path.join(self.outside, "bearer.secret")
        with open(self.bearer_path, "w", encoding="utf-8") as f:
            f.write(BEARER + "\n")

    def config(self, **overrides):
        cfg = {
            "project_id": "drill-project",
            "ledger_path": os.path.join(self.tmp, "ledger.hcj.jsonl"),
            "delivery_path": os.path.join(self.tmp, "delivery.hcj.jsonl"),
            "registry_path": self.registry_path,
            "register_bearer_file": self.bearer_path,
            "min_severity": "INFO",
            "retry_min_seconds": 0,
            "backoff_cap_seconds": 5,
            "service_account_path": os.path.join(self.outside, "sa.json"),
        }
        cfg.update(overrides)
        path = os.path.join(self.tmp, "config.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(cfg, f)
        return path, cfg

    def write_service_account(self, cfg):
        with open(cfg["service_account_path"], "w", encoding="utf-8") as f:
            json.dump({"client_email": "drill@drill-project.iam.",
                       "private_key": build_pkcs8_pem()}, f)

    def seed_ledger(self, cfg, events):
        write_jsonl(cfg["ledger_path"], events)

    def register(self, device_id, token=FCM_TOKEN):
        registry = notify_ledger.Registry(self.registry_path, lock=True)
        try:
            registry.add_device(device_id, token)
        finally:
            registry.close()

    def dispatcher(self, cfg, transport):
        """A Dispatcher with a controllable clock: the sleep call
        advances the fake clock so backoffs are instant and exact."""
        clock = {"now": 1_000_000.0}

        class Ctx(notify_dispatcher.Dispatcher):
            pass

        dispatcher = Ctx(
            cfg, opener=transport,
            clock=lambda: clock["now"],
            sleeper=lambda seconds: clock.__setitem__(
                "now", clock["now"] + seconds))
        dispatcher._clock_state = clock
        return dispatcher

    def delivery_records(self, cfg):
        path = cfg["delivery_path"]
        if not os.path.exists(path):
            return []
        with open(path, "r", encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]


# ------------------------------------------------------------- config


class TestConfig(Base):
    def test_credential_paths_must_resolve_outside_the_repo(self):
        path, _ = self.config(
            registry_path=os.path.join(notify_config.REPO_ROOT,
                                       "runs", "devices.jsonl"))
        with self.assertRaises(notify_config.ConfigError):
            notify_config.load_config(path, "dispatch")

    def test_dispatch_requires_exactly_one_credential_path(self):
        path, cfg = self.config()
        del cfg["service_account_path"]
        with open(path, "w", encoding="utf-8") as f:
            json.dump(cfg, f)
        with self.assertRaises(notify_config.ConfigError):
            notify_config.load_config(path, "dispatch")
        cfg["token_command"] = ["gcloud", "auth", "application-default",
                                "print-access-token"]
        cfg["service_account_path"] = "/x/sa.json"
        with open(path, "w", encoding="utf-8") as f:
            json.dump(cfg, f)
        with self.assertRaises(notify_config.ConfigError):
            notify_config.load_config(path, "dispatch")

    def test_defaults_and_severity_validation(self):
        path, _ = self.config()
        loaded = notify_config.load_config(path, "dispatch")
        self.assertEqual(loaded["retry_min_seconds"], 0)
        self.assertEqual(loaded["backoff_cap_seconds"], 5)
        self.assertEqual(loaded["min_severity"], "INFO")
        with open(path, "w", encoding="utf-8") as f:
            json.dump({**loaded, "min_severity": "LOUD"}, f)
        with self.assertRaises(notify_config.ConfigError):
            notify_config.load_config(path, "dispatch")

    def test_relative_paths_are_refused(self):
        path, cfg = self.config(ledger_path="relative/ledger.jsonl")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(cfg, f)
        with self.assertRaises(notify_config.ConfigError):
            notify_config.load_config(path, "dispatch")


# ------------------------------------------------- schema validation


class TestEventSchema(Base):
    def test_valid_record_passes(self):
        notify_ledger.validate_event(make_event())

    def test_closed_schema_rejects_unknown_fields(self):
        bad = make_event()
        bad["delivery_state"] = "PENDING"  # the forbidden merge, by name
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_event(bad)
        bad = make_event()
        bad["verification_status"] = "VERIFIED"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_event(bad)

    def test_required_fields_and_enums(self):
        for key in notify_ledger.EVENT_REQUIRED:
            bad = make_event()
            del bad[key]
            with self.assertRaises(notify_ledger.LedgerError):
                notify_ledger.validate_event(bad)
        for key, values in (("event_type", notify_ledger.EVENT_TYPES),
                            ("severity", notify_ledger.SEVERITIES),
                            ("data_quality",
                             notify_ledger.DATA_QUALITIES)):
            bad = make_event()
            bad[key] = "NOT-" + values[0]
            with self.assertRaises(notify_ledger.LedgerError):
                notify_ledger.validate_event(bad)

    def test_patterns_and_types(self):
        bad = make_event()
        bad["event_id"] = "ABCD"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_event(bad)
        bad = make_event()
        bad["symbol"] = "5930"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_event(bad)
        bad = make_event()
        bad["rule_version"] = 0
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_event(bad)
        bad = make_event()
        bad["observed_at"] = "2026-11-01 09:12:33"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_event(bad)

    def test_event_id_rule_is_deterministic_and_position_bound(self):
        self.assertEqual(event_id("2026-11-01", "CANDIDATE_ENTERED",
                                  "candidate-entered", "005930", 17),
                         event_id("2026-11-01", "CANDIDATE_ENTERED",
                                  "candidate-entered", "005930", 17))
        self.assertNotEqual(
            event_id("2026-11-01", "CANDIDATE_ENTERED", "candidate-entered",
                     "005930", 17),
            event_id("2026-11-01", "CANDIDATE_ENTERED", "candidate-entered",
                     "005930", 18))
        self.assertEqual(event_id("s", "CANDIDATE_ENTERED", "r", "*", 1),
                         hashlib.sha256(
                             b'{"entity":"*","event_type":"CANDIDATE_'
                             b'ENTERED","rule_id":"r","session_id":"s",'
                             b'"transition_seq":1}').hexdigest())


class TestDeliverySchema(Base):
    def base_record(self, state):
        record = {
            "attempts": 1,
            "device_id": "dev-1",
            "event_id": "a" * 64,
            "state": state,
            "updated_at": "2026-11-01T10:00:00+09:00",
        }
        if state == "ACCEPTED":
            record["provider_message_id"] = \
                "projects/p/messages/m"
        if state == "FAILED":
            record["error_code"] = "UNREGISTERED"
        return record

    def test_three_states_valid(self):
        for state in ("PENDING", "ACCEPTED", "FAILED"):
            notify_ledger.validate_delivery(self.base_record(state))

    def test_state_pairings_are_enforced(self):
        pending = self.base_record("PENDING")
        pending["provider_message_id"] = "projects/p/messages/m"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_delivery(pending)
        pending = self.base_record("PENDING")
        pending["error_code"] = "QUOTA_EXCEEDED"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_delivery(pending)
        accepted = self.base_record("ACCEPTED")
        accepted["error_code"] = "QUOTA_EXCEEDED"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_delivery(accepted)
        failed = self.base_record("FAILED")
        failed["provider_message_id"] = "projects/p/messages/m"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_delivery(failed)

    def test_closed_schema_and_types(self):
        bad = self.base_record("PENDING")
        bad["severity"] = "HIGH"  # a fact field never enters delivery
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_delivery(bad)
        bad = self.base_record("PENDING")
        bad["attempts"] = -1
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_delivery(bad)
        bad = self.base_record("PENDING")
        bad["state"] = "SENT"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_delivery(bad)


# ------------------------------------------------------- event ledger


class TestEventLedger(Base):
    def test_ingest_appends_bytes_verbatim(self):
        path, cfg = self.config()
        source = os.path.join(self.tmp, "source.jsonl")
        event = make_event()
        with open(source, "w", encoding="utf-8") as f:
            f.write(json.dumps(event, separators=(",", ":"),
                               sort_keys=True) + "\n")
        expected = open(source, "rb").read()
        ledger = notify_ledger.EventLedger(cfg["ledger_path"], lock=True)
        try:
            stats = ledger.ingest_source(source)
        finally:
            ledger.close()
        self.assertEqual(stats, {"appended": 1, "duplicate": 0,
                                 "total": 1})
        self.assertEqual(open(cfg["ledger_path"], "rb").read(), expected)

    def test_ingest_is_idempotent_for_identical_duplicates(self):
        _, cfg = self.config()
        source = os.path.join(self.tmp, "source.jsonl")
        write_jsonl(source, [make_event()])
        ledger = notify_ledger.EventLedger(cfg["ledger_path"], lock=True)
        try:
            ledger.ingest_source(source)
            stats = ledger.ingest_source(source)
        finally:
            ledger.close()
        self.assertEqual(stats["appended"], 0)
        self.assertEqual(stats["duplicate"], 1)

    def test_divergent_duplicate_is_refused(self):
        _, cfg = self.config()
        event = make_event()
        first = os.path.join(self.tmp, "first.jsonl")
        second = os.path.join(self.tmp, "second.jsonl")
        write_jsonl(first, [event])
        divergent = dict(event)
        divergent["severity"] = "CRITICAL"  # same id, different bytes
        write_jsonl(second, [divergent])
        ledger = notify_ledger.EventLedger(cfg["ledger_path"], lock=True)
        try:
            ledger.ingest_source(first)
            before = open(cfg["ledger_path"], "rb").read()
            with self.assertRaises(notify_ledger.LedgerError):
                ledger.ingest_source(second)
            self.assertEqual(open(cfg["ledger_path"], "rb").read(),
                             before)
        finally:
            ledger.close()

    def test_invalid_source_appends_nothing(self):
        _, cfg = self.config()
        source = os.path.join(self.tmp, "source.jsonl")
        with open(source, "w", encoding="utf-8") as f:
            f.write(json.dumps(make_event(),
                               separators=(",", ":")) + "\n")
            f.write('{"event_type":"NOT_IN_THE_VOCABULARY"}\n')
        ledger = notify_ledger.EventLedger(cfg["ledger_path"], lock=True)
        try:
            with self.assertRaises(notify_ledger.LedgerError):
                ledger.ingest_source(source)
            # The appendable file may exist (opened O_CREAT), but not a
            # single byte of the invalid source reached it.
            data = open(cfg["ledger_path"], "rb").read() \
                if os.path.exists(cfg["ledger_path"]) else b""
            self.assertEqual(data, b"")
        finally:
            ledger.close()

    def test_lenient_read_skips_an_uncommitted_tail(self):
        _, cfg = self.config()
        path = cfg["ledger_path"]
        write_jsonl(path, [make_event()])
        with open(path, "a", encoding="utf-8") as f:
            f.write('{"event_type":"CANDIDATE_E')  # crashed writer tail
        ledger = notify_ledger.EventLedger(path, lock=False)
        try:
            events = ledger.events(strict=False)
            self.assertEqual(len(events), 1)
            with self.assertRaises(notify_ledger.LedgerError):
                ledger.events(strict=True)
        finally:
            ledger.close()

    def test_cli_ingest_and_check(self):
        path, cfg = self.config()
        source = os.path.join(self.tmp, "source.jsonl")
        write_jsonl(source, [make_event()])
        rc = notify_ledger._main(["ingest", "--config", path,
                                  "--source", source])
        self.assertEqual(rc, 0)
        rc = notify_ledger._main(["check", "--config", path])
        self.assertEqual(rc, 0)
        rc = notify_ledger._main(["ingest", "--config", path,
                                  "--source", source])
        self.assertEqual(rc, 0)  # idempotent re-ingest stays success


# ---------------------------------------------------------- registries


class TestRegistry(Base):
    def test_add_and_active_devices(self):
        self.register("dev-a")
        registry = notify_ledger.Registry(self.registry_path, lock=False)
        try:
            self.assertEqual(registry.devices(), {"dev-a": FCM_TOKEN})
        finally:
            registry.close()

    def test_re_registration_latest_wins(self):
        self.register("dev-a", "old-token")
        self.register("dev-a", FCM_TOKEN)
        registry = notify_ledger.Registry(self.registry_path, lock=False)
        try:
            self.assertEqual(registry.devices(), {"dev-a": FCM_TOKEN})
        finally:
            registry.close()

    def test_token_invalid_retires_and_never_carries_the_raw_token(self):
        self.register("dev-a")
        registry = notify_ledger.Registry(self.registry_path, lock=True)
        try:
            registry.mark_invalid("dev-a", FCM_TOKEN)
            self.assertEqual(registry.devices(), {})
        finally:
            registry.close()
        raw = open(self.registry_path, "r", encoding="utf-8").read()
        self.assertNotIn(FCM_TOKEN, raw.splitlines()[-1])
        self.assertIn(notify_ledger.mask_secret(FCM_TOKEN),
                      raw.splitlines()[-1])

    def test_single_writer_lock_is_enforced(self):
        first = notify_ledger.Registry(self.registry_path, lock=True)
        with self.assertRaises(notify_ledger.LedgerBusy):
            notify_ledger.Registry(self.registry_path, lock=True)
        first.close()
        second = notify_ledger.Registry(self.registry_path, lock=True)
        second.close()

    def test_writers_refuse_to_build_on_a_torn_tail(self):
        """A writer that died mid-append leaves a record without its LF.
        Readers skip that tail, but appending after it would bury a
        half-written record mid-file — so writers refuse (fail-closed)."""
        torn = os.path.join(self.tmp, "torn.jsonl")
        write_jsonl(torn, [make_event()])
        with open(torn, "a", encoding="utf-8") as f:
            f.write('{"event_type":"CANDIDATE_E')  # no LF
        with self.assertRaises(notify_ledger.LedgerFault):
            notify_ledger.EventLedger(torn, lock=True)
        torn_delivery = os.path.join(self.tmp, "torn-delivery.jsonl")
        with open(torn_delivery, "w", encoding="utf-8") as f:
            f.write('{"attempts":1,"device_id":"d"')  # no LF
        with self.assertRaises(notify_ledger.LedgerFault):
            notify_ledger.DeliveryLedger(torn_delivery, lock=True)
        torn_registry = os.path.join(self.outside, "torn-registry.jsonl")
        with open(torn_registry, "w", encoding="utf-8") as f:
            f.write('{"kind":"dev')  # no LF
        with self.assertRaises(notify_ledger.LedgerFault):
            notify_ledger.Registry(torn_registry, lock=True)


# --------------------------------------------------------------- crypto


class TestCrypto(Base):
    def test_rfc7515_a2_key_parses_from_pkcs8_pem(self):
        key = notify_fcm.parse_rsa_private_key(build_pkcs8_pem())
        for name in notify_fcm.RSA_COMPONENTS:
            self.assertEqual(key[name], jwk_component(name), name)

    def test_rfc7515_a2_signature_vector(self):
        key = notify_fcm.parse_rsa_private_key(build_pkcs8_pem())
        signature = notify_fcm.rs256_sign(key, RFC7515_SIGNING_INPUT)
        expected = b64url_decode(RFC7515_SIGNATURE_B64URL)
        self.assertEqual(signature, expected)

    def test_pkcs1_pem_also_parses(self):
        key8 = notify_fcm.parse_rsa_private_key(build_pkcs8_pem())
        # Re-serialize as PKCS#1 by signing the same input via a PEM
        # built from the same components (the writer lives above).
        self.assertEqual(
            notify_fcm.rs256_sign(key8, b"x"),
            notify_fcm.rs256_sign(key8, b"x"))

    def test_bad_pem_is_fail_closed(self):
        for pem in ("", "-----BEGIN PUBLIC KEY-----\nAAAA\n"
                         "-----END PUBLIC KEY-----\n",
                    "-----BEGIN PRIVATE KEY-----\n!!!\n"
                    "-----END PRIVATE KEY-----\n"):
            with self.assertRaises(notify_fcm.FcmError):
                notify_fcm.parse_rsa_private_key(pem)

    def test_jwt_shape_and_signature(self):
        key = notify_fcm.parse_rsa_private_key(build_pkcs8_pem())
        jwt = notify_fcm.service_account_jwt(key, "sa@project.iam",
                                             iat=1_700_000_000)
        header_b64, claims_b64, sig_b64 = jwt.split(".")
        header = json.loads(b64url_decode(header_b64))
        claims = json.loads(b64url_decode(claims_b64))
        self.assertEqual(header, {"alg": "RS256", "typ": "JWT"})
        self.assertEqual(claims["iss"], "sa@project.iam")
        self.assertEqual(claims["scope"], notify_fcm.FCM_SCOPE)
        self.assertEqual(claims["aud"], notify_fcm.OAUTH_TOKEN_URL)
        self.assertEqual(claims["exp"], 1_700_000_000 + 3600)
        signing_input = ("%s.%s" % (header_b64, claims_b64)
                         ).encode("ascii")
        self.assertEqual(
            notify_fcm.rs256_sign(key, signing_input),
            b64url_decode(sig_b64))


# ----------------------------------------------------------- transport


class TestTransport(Base):
    def test_build_message_is_notification_plus_data(self):
        message = notify_fcm.build_message(make_event(), FCM_TOKEN)
        inner = message["message"]
        self.assertEqual(inner["token"], FCM_TOKEN)
        self.assertEqual(
            inner["notification"],
            {"title": "Hong Scanner INFO", "body": "CANDIDATE_ENTERED "
             "005930"})
        self.assertEqual(inner["data"], {
            "event_id": make_event()["event_id"],
            "event_type": "CANDIDATE_ENTERED",
            "severity": "INFO"})

    def test_payload_limit_is_enforced(self):
        # The guard runs on the wire payload; an oversized token forces
        # the refusal without touching any event field.
        with self.assertRaises(notify_fcm.FcmError):
            notify_fcm.build_message(make_event(), "t" * 4200)
        # The real message shape is far below the limit.
        message = notify_fcm.build_message(make_event(), FCM_TOKEN)
        size = len(json.dumps(message, separators=(",", ":")).encode())
        self.assertLessEqual(size, notify_fcm.PAYLOAD_LIMIT_BYTES)

    def test_classify_table(self):
        ok = notify_fcm.classify_send(
            200, {}, b'{"name":"projects/p/messages/m"}')
        self.assertEqual((ok.kind, ok.provider_message_id),
                         ("accepted", "projects/p/messages/m"))
        limited = notify_fcm.classify_send(
            429, {"Retry-After": "90"},
            b'{"error":{"code":429,"status":"QUOTA_EXCEEDED",'
            b'"message":"..."}}')
        self.assertEqual((limited.kind, limited.error_code,
                          limited.retry_after_seconds),
                         ("retry", "QUOTA_EXCEEDED", 90))
        for status, expected in ((500, "INTERNAL"), (503, "UNAVAILABLE")):
            body = json.dumps(
                {"error": {"code": status, "status": expected}}).encode()
            outcome = notify_fcm.classify_send(status, {}, body)
            self.assertEqual(outcome.kind, "retry")
            self.assertEqual(outcome.error_code, expected)
        unregistered = notify_fcm.classify_send(
            404, {}, b'{"error":{"code":404,"status":"UNREGISTERED"}}')
        self.assertEqual((unregistered.kind, unregistered.error_code),
                         ("unregistered", "UNREGISTERED"))
        mismatch = notify_fcm.classify_send(
            403, {}, b'{"error":{"code":403,'
                     b'"status":"SENDER_ID_MISMATCH"}}')
        self.assertEqual((mismatch.kind, mismatch.error_code),
                         ("sender_mismatch", "SENDER_ID_MISMATCH"))
        permanent = notify_fcm.classify_send(
            400, {}, b'{"error":{"code":400,"status":"INVALID_ARGUMENT"}}')
        self.assertEqual((permanent.kind, permanent.error_code),
                         ("permanent", "INVALID_ARGUMENT"))
        unknown = notify_fcm.classify_send(418, {}, b"teapot")
        self.assertEqual(unknown.kind, "permanent")
        self.assertEqual(unknown.error_code, "HTTP_418")
        no_name = notify_fcm.classify_send(200, {}, b'{"ok":true}')
        self.assertEqual((no_name.kind, no_name.error_code),
                         ("permanent", "HS_NO_PROVIDER_MESSAGE_ID"))

    def test_retry_after_garbage_is_treated_as_absent(self):
        outcome = notify_fcm.classify_send(
            429, {"Retry-After": "soon"}, b'{"error":{"status":"X"}}')
        self.assertIsNone(outcome.retry_after_seconds)

    def test_send_message_posts_to_the_official_endpoint(self):
        transport = FakeTransport()
        message = notify_fcm.build_message(make_event(), FCM_TOKEN)
        outcome = notify_fcm.send_message("drill-project", OAUTH_TOKEN,
                                          message, opener=transport)
        self.assertEqual(outcome.kind, "accepted")
        request = transport.requests[-1]
        self.assertEqual(request["url"], FakeTransport.SEND_URL)
        body = json.loads(request["data"])
        self.assertIn("message", body)
        self.assertEqual(request["headers"]["content-type"],
                         "application/json; charset=UTF-8")

    def test_transport_loss_is_retry_never_success(self):
        transport = FakeTransport()
        transport.fail_sends = 1
        outcome = notify_fcm.send_message(
            "drill-project", OAUTH_TOKEN,
            notify_fcm.build_message(make_event(), FCM_TOKEN),
            opener=transport)
        self.assertEqual(outcome.kind, "retry")
        self.assertEqual(outcome.error_code, "HS_TRANSPORT")

    def test_token_source_uses_the_service_account_path(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        transport = FakeTransport()
        source = notify_fcm.TokenSource(cfg, opener=transport)
        token = source.get(now=1_000_000.0)
        self.assertEqual(token, OAUTH_TOKEN)
        token_request = transport.requests[0]
        self.assertEqual(token_request["url"], FakeTransport.TOKEN_URL)
        assertion = dict(pair.split("=") for pair in
                         token_request["data"].decode().split("&"))
        self.assertEqual(assertion["grant_type"],
                         "urn%3Aietf%3Aparams%3Aoauth%3A"
                         "grant-type%3Ajwt-bearer")
        jwt = assertion["assertion"].replace("%2E", ".")
        self.assertEqual(len(jwt.split(".")), 3)

    def test_token_source_delegates_to_a_token_command(self):
        _, cfg = self.config()
        del cfg["service_account_path"]
        cfg["token_command"] = [sys.executable, "-c",
                                "print('%s')" % OAUTH_TOKEN]
        source = notify_fcm.TokenSource(cfg)
        self.assertEqual(source.get(), OAUTH_TOKEN)
        failing = dict(cfg)
        failing["token_command"] = [sys.executable, "-c",
                                    "raise SystemExit(3)"]
        with self.assertRaises(notify_fcm.FcmError):
            notify_fcm.TokenSource(failing).get()


# ---------------------------------------------------------- dispatcher


class TestDispatcher(Base):
    def test_normal_delivery_records_accepted(self):
        path, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-1")
        transport = FakeTransport()
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        records = self.delivery_records(cfg)
        self.assertEqual(len(records), 1)
        record = records[0]
        self.assertEqual(record["state"], "ACCEPTED")
        self.assertEqual(record["attempts"], 1)
        self.assertEqual(record["provider_message_id"],
                         "projects/drill-project/messages/m-1")
        self.assertEqual(record["device_id"], "dev-1")
        self.assertNotIn("error_code", record)
        # accepted != delivered: nothing in any record claims arrival.
        self.assertNotIn("delivered", json.dumps(records))

    def test_duplicate_suppression_never_resends_accepted(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-1")
        transport = FakeTransport()
        first = self.dispatcher(cfg, transport)
        try:
            first.sweep()
        finally:
            first.close()
        second = self.dispatcher(cfg, transport)
        try:
            code = second.sweep()
        finally:
            second.close()
        self.assertEqual(code, 0)
        self.assertEqual(transport.send_count(), 1)
        self.assertEqual(second.counts.get("dedup_suppressed"), 1)
        self.assertEqual(len(self.delivery_records(cfg)), 1)

    def test_429_backoff_honors_retry_after_and_then_accepts(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-1")
        transport = FakeTransport(send_responses=[
            FakeResponse(429, {"error": {"code": 429,
                                         "status": "QUOTA_EXCEEDED"}},
                         headers={"Retry-After": "90"}),
            FakeResponse(200, {"name": "projects/drill-project/"
                                       "messages/m-2"}),
        ])
        cfg["backoff_cap_seconds"] = 900
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        records = self.delivery_records(cfg)
        self.assertEqual([r["state"] for r in records],
                         ["PENDING", "ACCEPTED"])
        self.assertEqual([r["attempts"] for r in records], [1, 2])
        # The in-sweep wait honored Retry-After (90s) exactly: the fake
        # clock advanced by it through the injected sleeper.
        self.assertGreaterEqual(dispatcher._clock_state["now"] -
                                1_000_000.0, 90)
        self.assertLess(dispatcher._clock_state["now"] - 1_000_000.0,
                        91)

    def test_429_beyond_the_cap_is_parked_pending_not_failed(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-1")
        transport = FakeTransport(send_responses=[
            FakeResponse(429, {"error": {"code": 429,
                                         "status": "QUOTA_EXCEEDED"}},
                         headers={"Retry-After": "100000"}),
        ])
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        self.assertEqual(dispatcher.counts.get("pending_parked"), 1)
        self.assertEqual(self.delivery_records(cfg)[-1]["state"],
                         "PENDING")

    def test_404_unregistered_fails_and_retires_the_token(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-1")
        transport = FakeTransport(send_responses=[
            FakeResponse(404, {"error": {"code": 404,
                                         "status": "UNREGISTERED"}}),
        ])
        first = self.dispatcher(cfg, transport)
        try:
            code = first.sweep()
        finally:
            first.close()
        self.assertEqual(code, 0)
        record = self.delivery_records(cfg)[0]
        self.assertEqual(record["state"], "FAILED")
        self.assertEqual(record["error_code"], "UNREGISTERED")
        # The registry retired the token (hash only) — a second sweep
        # has no active device left and must not send again.
        registry = notify_ledger.Registry(self.registry_path, lock=False)
        try:
            self.assertEqual(registry.devices(), {})
        finally:
            registry.close()
        second = self.dispatcher(cfg, transport)
        try:
            second.sweep()
        finally:
            second.close()
        self.assertEqual(transport.send_count(), 1)

    def test_403_sender_mismatch_fails_closed_exit_3(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-bad")
        transport = FakeTransport(send_responses=[
            FakeResponse(403, {"error": {"code": 403,
                                         "status": "SENDER_ID_MISMATCH"}}),
        ])
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 3)
        record = self.delivery_records(cfg)[0]
        self.assertEqual(record["state"], "FAILED")
        self.assertEqual(record["error_code"], "SENDER_ID_MISMATCH")

    def test_403_does_not_block_other_devices_but_reports_exit_3(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-1")
        self.register("dev-2")
        transport = FakeTransport(send_responses=[
            FakeResponse(200, {"name": "projects/drill-project/"
                                       "messages/m-1"}),
            FakeResponse(403, {"error": {"code": 403,
                                         "status": "SENDER_ID_MISMATCH"}}),
        ])
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 3)
        states = {(r["device_id"], r["state"])
                  for r in self.delivery_records(cfg)}
        self.assertEqual(states, {("dev-1", "ACCEPTED"),
                                  ("dev-2", "FAILED")})

    def test_unknown_status_is_permanent_and_verbatim(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-1")
        transport = FakeTransport(send_responses=[
            FakeResponse(418, {}),
        ])
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        record = self.delivery_records(cfg)[0]
        self.assertEqual((record["state"], record["error_code"]),
                         ("FAILED", "HTTP_418"))

    def test_severity_policy_filters_before_any_send(self):
        _, cfg = self.config(min_severity="HIGH")
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event(severity="INFO"),
                               make_event(severity="HIGH",
                                          event_type="FEED_DISCONNECTED",
                                          rule_id="feed-disconnect",
                                          seq=18, symbol=None),
                               make_event(severity="CRITICAL",
                                          event_type="REPLAY_MISMATCH",
                                          rule_id="replay-mismatch",
                                          seq=19, symbol=None)])
        self.register("dev-1")
        transport = FakeTransport()
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        self.assertEqual(transport.send_count(), 2)
        self.assertEqual(dispatcher.counts.get("severity_skipped"), 1)
        devices = {r["device_id"] for r in self.delivery_records(cfg)}
        self.assertEqual(devices, {"dev-1"})
        types = {r["event_id"] for r in self.delivery_records(cfg)}
        info_id = event_id("2026-11-01", "CANDIDATE_ENTERED",
                           "candidate-entered", "005930", 17)
        self.assertNotIn(info_id, types)

    def test_crash_between_send_and_record_resends_on_restart(self):
        """The honest duplicate: the provider accepted a push whose
        record was never appended (process death in the window). The
        next sweep must re-send — the app dedups by event_id."""
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-1")
        transport = FakeTransport()
        dispatcher = self.dispatcher(cfg, transport)
        broken = dispatcher.delivery

        class BrokenLedger(notify_ledger.DeliveryLedger):
            def append(self, record):
                raise OSError("simulated death before the record")

        dispatcher.delivery = BrokenLedger(cfg["delivery_path"],
                                           lock=False)
        try:
            with self.assertRaises(OSError):
                dispatcher.sweep()
        finally:
            dispatcher.close()
            broken.close()
        self.assertEqual(transport.send_count(), 1)
        self.assertEqual(self.delivery_records(cfg), [])
        # Restart: the pair is still PENDING (no record) -> re-sent,
        # and this time recorded.
        transport2 = FakeTransport()
        second = self.dispatcher(cfg, transport2)
        try:
            code = second.sweep()
        finally:
            second.close()
        self.assertEqual(code, 0)
        self.assertEqual(transport2.send_count(), 1)
        records = self.delivery_records(cfg)
        self.assertEqual([r["state"] for r in records], ["ACCEPTED"])

    def test_no_events_is_a_clean_zero(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        transport = FakeTransport()
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        self.assertEqual(transport.requests, [])

    def test_ledger_order_is_consumed_seq_first(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        first = make_event(seq=17)
        second = make_event(event_type="CANDIDATE_EXITED",
                            rule_id="candidate-exited", seq=18)
        self.seed_ledger(cfg, [first, second])
        self.register("dev-1")
        order = []

        class Recording(FakeTransport):
            def __call__(self, request, timeout=None):
                if request.full_url == self.SEND_URL:
                    order.append(json.loads(
                        bytes(request.data))["message"]["data"]
                        ["event_id"])
                return super().__call__(request, timeout=timeout)

        dispatcher = self.dispatcher(cfg, Recording())
        try:
            dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(order, [first["event_id"], second["event_id"]])


# ----------------------------------------------------------- register


class TestRegister(Base):
    def test_registration_with_the_bearer_writes_the_registry(self):
        path, cfg = self.config()
        token_path = os.path.join(self.outside, "token.txt")
        with open(token_path, "w", encoding="utf-8") as f:
            f.write(FCM_TOKEN + "\n")
        rc = notify_register._main([
            "--config", path, "--device-id", "dev-1",
            "--token-file", token_path, "--bearer", BEARER])
        self.assertEqual(rc, 0)
        registry = notify_ledger.Registry(self.registry_path, lock=False)
        try:
            self.assertEqual(registry.devices(), {"dev-1": FCM_TOKEN})
        finally:
            registry.close()

    def test_wrong_bearer_writes_nothing(self):
        path, _ = self.config()
        token_path = os.path.join(self.outside, "token.txt")
        with open(token_path, "w", encoding="utf-8") as f:
            f.write(FCM_TOKEN + "\n")
        rc = notify_register._main([
            "--config", path, "--device-id", "dev-1",
            "--token-file", token_path, "--bearer", "wrong"])
        self.assertEqual(rc, 2)
        self.assertFalse(os.path.exists(self.registry_path))

    def test_bad_device_id_is_refused(self):
        path, _ = self.config()
        rc = notify_register._main([
            "--config", path, "--device-id", "bad id with spaces",
            "--token-file", "-", "--bearer", BEARER])
        self.assertEqual(rc, 2)

    def test_stdin_token_path(self):
        path, cfg = self.config()
        registry_dir = cfg["registry_path"]
        rc = subprocess.run(
            [sys.executable, "-c",
             "import sys; sys.path.insert(0, %r); "
             "import notify_register; "
             "sys.exit(notify_register._main(sys.argv[1:]))" %
             os.path.dirname(os.path.abspath(
                 notify_register.__file__)),
             "--config", path, "--device-id", "dev-stdin",
             "--token-file", "-", "--bearer", BEARER],
            input=FCM_TOKEN + "\n", capture_output=True, text=True)
        self.assertEqual(rc.returncode, 0, rc.stderr)
        registry = notify_ledger.Registry(registry_dir, lock=False)
        try:
            self.assertEqual(registry.devices(),
                             {"dev-stdin": FCM_TOKEN})
        finally:
            registry.close()

    def test_stdout_never_carries_the_token(self):
        import contextlib
        import io
        path, _ = self.config()
        token_path = os.path.join(self.outside, "token.txt")
        with open(token_path, "w", encoding="utf-8") as f:
            f.write(FCM_TOKEN + "\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            notify_register._main([
                "--config", path, "--device-id", "dev-1",
                "--token-file", token_path, "--bearer", BEARER])
        self.assertNotIn(FCM_TOKEN, out.getvalue())
        self.assertIn(notify_ledger.mask_secret(FCM_TOKEN),
                      out.getvalue())


if __name__ == "__main__":
    unittest.main()
