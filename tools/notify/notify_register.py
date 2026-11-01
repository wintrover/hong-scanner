#!/usr/bin/env python3
"""notify_register: authenticated device registration (PR-5).

Contract: tools/notify/README.md §7. The device registry lives OUTSIDE
the repository (it stores FCM registration tokens — credentials never
enter the repo; delivery.schema.json device_id x-ref). Registration is
gated by a shared bearer secret from the config's register_bearer_file
(the same credential path the read-only API of PR-6 will authenticate
with). The FCM token reaches this process through a file or stdin —
never argv, never a log: the token value exists only in process memory
and in the registry file (0600). Logs name the masked sha256 only.

Usage (see README §7):
  python3 notify_register.py --config <path> \
      --device-id <registry id> --token-file <path | -> \
      [--bearer <secret>]          # default: $HSNOTIFY_BEARER

Exit codes: 0 registered, 2 usage/contract violation (bad bearer,
bad device id, unreadable token), 4 single-writer conflict / fault.
A refused registration writes nothing.
"""

import argparse
import hmac
import os
import sys

import notify_config
import notify_ledger


def _read_secret_file(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return None


def _main(argv):
    parser = argparse.ArgumentParser(
        description="register a device (bearer-authenticated; README §7)")
    parser.add_argument("--config",
                        default=os.environ.get("HSNOTIFY_CONFIG", ""))
    parser.add_argument("--device-id", required=True,
                        help="registry identity (delivery.device_id); "
                             "never an FCM token itself")
    parser.add_argument("--token-file", required=True,
                        help="file holding the FCM registration token; "
                             "'-' reads stdin (never argv)")
    parser.add_argument("--bearer", default=os.environ.get("HSNOTIFY_BEARER",
                                                          ""),
                        help="shared secret; default $HSNOTIFY_BEARER")
    args = parser.parse_args(argv)

    if not notify_ledger.DEVICE_ID_RE.match(args.device_id):
        print("notify_register: device-id must match "
              "^[A-Za-z0-9_.:-]{1,128}$", file=sys.stderr)
        return 2
    try:
        cfg = notify_config.load_config(args.config, "register")
    except notify_config.ConfigError as exc:
        print("notify_register: config refused: %s" % exc, file=sys.stderr)
        return 2

    secret = _read_secret_file(cfg["register_bearer_file"])
    if not secret or not args.bearer or \
       not hmac.compare_digest(args.bearer, secret):
        # Constant-time compare; the mismatch discards the token and
        # writes nothing. The values are never echoed.
        print("notify_register: bearer refused (device not registered)",
              file=sys.stderr)
        return 2

    if args.token_file == "-":
        token = sys.stdin.readline().strip()
    else:
        token = _read_secret_file(args.token_file)
    if not token or len(token) > 4096 or any(c.isspace() for c in token):
        print("notify_register: no usable fcm token on --token-file "
              "(1..4096 chars, no whitespace)", file=sys.stderr)
        return 2

    try:
        registry = notify_ledger.Registry(cfg["registry_path"], lock=True)
        try:
            registry.add_device(args.device_id, token)
        finally:
            registry.close()
    except notify_ledger.LedgerBusy as exc:
        print("notify_register: %s" % exc, file=sys.stderr)
        return 4
    except (notify_ledger.LedgerFault, notify_ledger.LedgerError) as exc:
        print("notify_register: %s" % exc, file=sys.stderr)
        return 4

    print("registered device=%s token=%s registry=%s" %
          (args.device_id, notify_ledger.mask_secret(token),
           cfg["registry_path"]))
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
