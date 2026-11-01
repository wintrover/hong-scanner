#!/usr/bin/env python3
"""notify_dispatcher: the VS-3 notification dispatcher (PR-5).

Contract: tools/notify/README.md; delivery.schema.json; docs/
REPLAY_CONTRACT.md §13. The dispatcher is transport only: it filters,
orders and translates events for delivery (§13.1) — it never judges,
upgrades or rewrites a fact, and it never writes to the event ledger.

One sweep:
  1. read the event ledger (read-only; a concurrently-appending tail is
     skipped, never half-consumed);
  2. apply the notification policy (min_severity, default INFO = all);
  3. suppress duplicates: an ACCEPTED (event_id, device_id) pair is
     never sent again; a FAILED pair is terminal (UNREGISTERED token,
     SENDER_ID_MISMATCH config error, unknown permanent codes);
  4. send one FCM HTTP v1 notification+data message per remaining pair;
  5. append one delivery record per outcome (PENDING on retryable
     failures, ACCEPTED / FAILED otherwise) — append-only, fsynced, so
     a crash between send and record replays the send on restart:
     the device may receive a duplicate push. That is FCM reality, not
     a bug, and the app identifies duplicates by event_id (README §6).
     accepted != delivered: HTTP 200 proves provider acceptance only.

Retry classes (vendor table, tools/notify/README.md §5):
  429 QUOTA_EXCEEDED / 500 INTERNAL / 503 UNAVAILABLE / transport
  failure -> stay PENDING, backoff >= max(retry_min_seconds, Retry-After),
  retried in-sweep while the wait is within backoff_cap_seconds, parked
  PENDING otherwise (external scheduler resumes);
  404 UNREGISTERED -> FAILED, token retired in the registry, no retry;
  403 SENDER_ID_MISMATCH -> FAILED (config error, fail-closed, no
  retry), the sweep keeps serving the other devices and the process
  exits 3 — a config error is never a clean success;
  everything else -> FAILED with the provider's status kept verbatim.

Exit codes (README §9): 0 sweep completed, 2 usage/config violation,
3 credential failure or fail-closed sender mismatch, 4 single-writer
conflict / internal fault.
"""

import json
import os
import sys
import time

import notify_config
import notify_fcm
import notify_ledger


class Dispatcher:
    """One dispatch sweep over the event ledger. The transport
    (`opener`) and the clock/sleep pair are injectable so the contract
    tests and the fake-FCM drill drive the real state machine."""

    def __init__(self, cfg, opener=None, clock=time.time,
                 sleeper=time.sleep):
        self.cfg = cfg
        self._clock = clock
        self._sleep = sleeper
        self.delivery = notify_ledger.DeliveryLedger(cfg["delivery_path"],
                                                     lock=True)
        self.registry = notify_ledger.Registry(cfg["registry_path"],
                                               lock=True)
        self.ledger = notify_ledger.EventLedger(cfg["ledger_path"],
                                                lock=False)
        self.tokens = notify_fcm.TokenSource(cfg, opener=opener)
        self.project_id = cfg["project_id"]
        self.min_rank = notify_ledger.severity_rank(
            cfg.get("min_severity", "INFO"))
        self.retry_min = cfg["retry_min_seconds"]
        self.backoff_cap = cfg["backoff_cap_seconds"]
        self.opener = opener or notify_fcm.urllib.request.urlopen
        self.mismatch_seen = False
        self.counts = {}

    def close(self):
        for resource in (self.ledger, self.registry, self.delivery):
            try:
                resource.close()
            except notify_ledger.LedgerBusy:
                pass

    # ------------------------------------------------------ selection

    def _candidates(self, events, state, devices):
        """The worklist in deterministic order (ledger order, then
        sorted device id), after the policy filter and dedup. Counters
        record what the policy and the suppression removed."""
        notifyable = 0
        pairs = []
        for event in events:
            if notify_ledger.severity_rank(event["severity"]) < self.min_rank:
                continue
            notifyable += 1
            for device_id in sorted(devices):
                record = state.get((event["event_id"], device_id))
                if record is not None and record["state"] == "ACCEPTED":
                    self.counts["dedup_suppressed"] = \
                        self.counts.get("dedup_suppressed", 0) + 1
                    continue
                if record is not None and record["state"] == "FAILED":
                    # Terminal: permanent error, retired token or the
                    # fail-closed sender mismatch — none is retried.
                    self.counts["terminal_skipped"] = \
                        self.counts.get("terminal_skipped", 0) + 1
                    continue
                pairs.append((event, device_id,
                              record["attempts"] if record else 0))
        self.counts["events_total"] = len(events)
        self.counts["severity_skipped"] = len(events) - notifyable
        self.counts["devices_active"] = len(devices)
        return pairs

    # ------------------------------------------------------- delivery

    def _record(self, event, device_id, state, attempts, error_code=None,
                provider_message_id=None):
        record = {
            "attempts": attempts,
            "device_id": device_id,
            "event_id": event["event_id"],
            "state": state,
            "updated_at": notify_ledger.now_iso(),
        }
        if error_code is not None:
            record["error_code"] = error_code
        if provider_message_id is not None:
            record["provider_message_id"] = provider_message_id
        self.delivery.append(record)  # validates before it writes
        return record

    def _attempt(self, event, device_id, token, attempts, state):
        """One send + one honest record. The appended record becomes the
        pair's current state in `state` (append-only: the last record
        per pair IS the state). Returns (kind, next_wait)."""
        pair = (event["event_id"], device_id)
        try:
            message = notify_fcm.build_message(event, token)
        except notify_fcm.FcmError:
            # Refused before send (payload limit): a permanent scanner
            # refusal, recorded honestly (HS_ codes are synthetic).
            state[pair] = self._record(event, device_id, "FAILED",
                                       attempts + 1,
                                       error_code="HS_PAYLOAD_OVER_LIMIT")
            self.counts["failed_permanent"] = \
                self.counts.get("failed_permanent", 0) + 1
            self._log("dispatch result=permanent event=%s device=%s "
                      "attempts=%d status=- error=HS_PAYLOAD_OVER_LIMIT"
                      % (event["event_id"], device_id, attempts + 1))
            return "permanent", None

        outcome = notify_fcm.send_message(self.project_id,
                                          self.tokens.get(self._clock()),
                                          message, opener=self.opener)
        attempts += 1

        if outcome.kind == "accepted":
            state[pair] = self._record(
                event, device_id, "ACCEPTED", attempts,
                provider_message_id=outcome.provider_message_id)
            self.counts["accepted"] = self.counts.get("accepted", 0) + 1
            self._log("dispatch result=accepted event=%s device=%s "
                      "attempts=%d status=200 message=%s" %
                      (event["event_id"], device_id, attempts,
                       outcome.provider_message_id))
            return "accepted", None

        if outcome.kind == "unregistered":
            # The vendor's answer: remove this token from the server and
            # stop sending to it — the delivery is terminal FAILED and
            # the token is retired (hash only) in the registry.
            state[pair] = self._record(event, device_id, "FAILED",
                                       attempts,
                                       error_code=outcome.error_code)
            self.registry.mark_invalid(device_id, token)
            self.counts["token_retired"] = \
                self.counts.get("token_retired", 0) + 1
            self._log("dispatch result=unregistered event=%s device=%s "
                      "attempts=%d status=%d error=%s token=%s" %
                      (event["event_id"], device_id, attempts,
                       outcome.http_status, outcome.error_code,
                       notify_ledger.mask_secret(token)))
            return "unregistered", None

        if outcome.kind == "sender_mismatch":
            # Fail-closed: a configuration error (the authenticated
            # sender is not a sender of this token). No retry, an honest
            # FAILED record, and exit 3 — never a clean success.
            state[pair] = self._record(event, device_id, "FAILED",
                                       attempts,
                                       error_code=outcome.error_code)
            self.mismatch_seen = True
            self.counts["sender_mismatch"] = \
                self.counts.get("sender_mismatch", 0) + 1
            print("dispatcher: SENDER_ID_MISMATCH for device=%s "
                  "(token=%s): the configured sender cannot send to this "
                  "token; fix the project/sender configuration, no "
                  "retry (fail-closed)" %
                  (device_id, notify_ledger.mask_secret(token)),
                  file=sys.stderr)
            self._log("dispatch result=sender_mismatch event=%s "
                      "device=%s attempts=%d status=%d error=%s" %
                      (event["event_id"], device_id, attempts,
                       outcome.http_status, outcome.error_code))
            return "sender_mismatch", None

        if outcome.kind == "retry":
            state[pair] = self._record(event, device_id, "PENDING",
                                       attempts)
            self.counts["retried_pending"] = \
                self.counts.get("retried_pending", 0) + 1
            wait = max(self.retry_min, outcome.retry_after_seconds or 0)
            self._log("dispatch result=retry event=%s device=%s "
                      "attempts=%d status=%s error=%s wait=%ds" %
                      (event["event_id"], device_id, attempts,
                       outcome.http_status, outcome.error_code, wait))
            return "retry", wait

        # permanent: any other provider answer, kept verbatim.
        state[pair] = self._record(event, device_id, "FAILED", attempts,
                                   error_code=outcome.error_code)
        self.counts["failed_permanent"] = \
            self.counts.get("failed_permanent", 0) + 1
        self._log("dispatch result=permanent event=%s device=%s "
                  "attempts=%d status=%s error=%s" %
                  (event["event_id"], device_id, attempts,
                   outcome.http_status, outcome.error_code))
        return "permanent", None

    def _log(self, line):
        print(line, flush=True)

    # ---------------------------------------------------------- sweep

    def sweep(self):
        """The full sweep. Returns the process exit code: 0, or 3 when a
        sender mismatch occurred (other work still completes)."""
        state = self.delivery.read_state()
        events = self.ledger.events(strict=False)
        devices = self.registry.devices()
        pairs = self._candidates(events, state, devices)
        self.counts["pairs_to_send"] = len(pairs)

        next_due = {}
        for event, device_id, _attempts in pairs:
            next_due[(event["event_id"], device_id)] = 0.0

        token_by_device = dict(devices)
        while True:
            now = self._clock()
            due = [(event, device_id)
                   for (event, device_id, _attempts) in pairs
                   if next_due[(event["event_id"], device_id)] is not None
                   and next_due[(event["event_id"], device_id)] <= now]
            if not due:
                pending = [next_due[(e["event_id"], d)]
                           for e, d, _ in pairs
                           if next_due[(e["event_id"], d)] is not None]
                if not pending:
                    break
                wait = min(pending) - now
                if wait > self.backoff_cap:
                    # Parked: the records stay PENDING for the external
                    # scheduler; nothing is marked delivered here.
                    self.counts["pending_parked"] = len(pending)
                    break
                self._sleep(max(wait, 0.0))
                continue
            for event, device_id in due:
                pair = (event["event_id"], device_id)
                record = state.get(pair)
                base = record["attempts"] if record else 0
                kind, wait = self._attempt(event, device_id,
                                           token_by_device[device_id],
                                           base, state)
                if kind == "retry" and wait is not None and \
                   wait <= self.backoff_cap:
                    next_due[pair] = self._clock() + wait
                elif kind == "retry":
                    next_due[pair] = None  # parked for external resume
                    self.counts["pending_parked"] = \
                        self.counts.get("pending_parked", 0) + 1
                else:
                    next_due[pair] = None
        return 3 if self.mismatch_seen else 0


def _main(argv):
    import argparse

    parser = argparse.ArgumentParser(
        description="notification dispatcher: ledger -> policy -> "
                    "dedup -> FCM HTTP v1 -> delivery records "
                    "(tools/notify/README.md)")
    parser.add_argument("--config",
                        default=os.environ.get("HSNOTIFY_CONFIG", ""))
    args = parser.parse_args(argv)

    try:
        cfg = notify_config.load_config(args.config, "dispatch")
    except notify_config.ConfigError as exc:
        print("dispatcher: config refused: %s" % exc, file=sys.stderr)
        return 2

    dispatcher = None
    try:
        dispatcher = Dispatcher(cfg)
        code = dispatcher.sweep()
        dispatcher.counts["exit"] = code
        print("sweep " + json.dumps(dispatcher.counts,
                                    ensure_ascii=False,
                                    separators=(",", ":")), flush=True)
        return code
    except notify_config.ConfigError as exc:
        print("dispatcher: config refused: %s" % exc, file=sys.stderr)
        return 2
    except notify_fcm.FcmError as exc:
        print("dispatcher: credential failure: %s" % exc, file=sys.stderr)
        return 3
    except (notify_ledger.LedgerBusy, notify_ledger.LedgerFault,
            notify_ledger.LedgerError) as exc:
        print("dispatcher: %s" % exc, file=sys.stderr)
        return 4
    finally:
        if dispatcher is not None:
            dispatcher.close()


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
