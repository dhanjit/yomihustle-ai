#!/usr/bin/env python3
"""Deterministic stub bridge for driving the Godot mod without an API key.

DESIGN.md SS14.2: a canned-response server the mod can hit end-to-end. It
reuses python/bridge.py's machinery (framing, SS3 handshake, SS16 token auth,
port/token/pid runtime files, validation) so the mod cannot tell it apart from
the real bridge — only the decisions are canned and/or sabotaged.

Scenarios (--scenario):

  happy            StubClient auto mode: a valid `ranked` of up to 3 picked
                   from the request's own legal_moves. Verify the mod submits
                   the top valid candidate. (default)
  all_invalid      `ranked` full of action_names that are NOT in legal_moves.
                   Bridge-side validation turns this into an `all_invalid`
                   error envelope -> verify the mod degrades to Tier 2.
  empty_ranked     `ranked: []` -> `empty_ranked` error envelope -> Tier 2.
  timeout          Sleep --sleep seconds (default 10) before replying, for the
                   first --times requests (default 1). The mod's 8s read
                   budget must fire (transport_read_timeout) and fall to
                   Tier 2 — and recover on a later request.
  disconnect       Send a length prefix + half the reply body, then drop the
                   connection, for the first --times replies (default 1).
                   Verify the mod survives the mid-frame EOF and recovers on
                   the next request.
  schema_mismatch  Every reply carries schema_version=2. Verify the mod's
                   decoder reports degradation_reason=schema_mismatch.
  auth_fail        The server's in-memory token is scrambled after the token
                   file is written, so the mod's (correct) file token never
                   matches -> hello_auth is rejected with an `auth_fail`
                   envelope and the connection closes.

Scripted decisions (--script): a JSON (or YAML, if PyYAML is installed) file
holding a LIST of raw decision dicts, consumed one per request before falling
back to the scenario client — exactly bridge.StubClient's `script` hook. Use
it to force specific model outputs per request, e.g.:

    [
      {"ranked": [{"action_name": "Grab", "data_index": 2, "reason": "scripted"}],
       "di_override": null, "feint": false, "reasoning_brief": "scripted turn 1"},
      {"category": "Movement", "reasoning_brief": "scripted v0 turn 2"}
    ]

Examples:

    python tools/stub_bridge.py                          # happy path on 8765
    python tools/stub_bridge.py --scenario timeout       # one 10s stall
    python tools/stub_bridge.py --scenario disconnect --times 3
    python tools/stub_bridge.py --script my_turns.json

Stop the real bridge first: both write the same port file, and the mod
follows whichever wrote it last (%LOCALAPPDATA%/claude_yomih/port).

Stdlib only, like bridge.py's stub path. Never imports `anthropic`.
"""

import argparse
import json
import logging
import os
import sys
import threading
import time

# tools/stub_bridge.py -> ../python/bridge.py
_TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
_PYTHON_DIR = os.path.join(os.path.dirname(_TOOLS_DIR), "python")
if _PYTHON_DIR not in sys.path:
    sys.path.insert(0, _PYTHON_DIR)

import bridge as B  # noqa: E402  (path bootstrap above)

log = logging.getLogger("claude_yomih.stub_bridge")

SCENARIOS = (
    "happy", "all_invalid", "empty_ranked", "timeout",
    "disconnect", "schema_mismatch", "auth_fail",
)

# Scenarios where --times defaults to "first request only" (the SS14.2 test
# intent is fail once, then verify recovery). schema_mismatch/auth_fail are
# whole-run by nature; happy & the canned-decision scenarios ignore --times.
_TIMES_DEFAULT_ONE = ("timeout", "disconnect")


class _Budget(object):
    """Thread-safe 'do this N more times' counter; n < 0 means unlimited."""

    def __init__(self, n):
        self._n = n
        self._lock = threading.Lock()

    def consume(self):
        with self._lock:
            if self._n == 0:
                return False
            if self._n > 0:
                self._n -= 1
            return True


class CannedClient(object):
    """Always returns `raw` (after an optional per-request script), so a
    degradation path stays active for the whole run regardless of mode."""

    def __init__(self, raw, label, script=None):
        self._raw = raw
        self._label = label
        self._inner = B.StubClient(script=script)
        self._script_len = len(script or [])
        self._served = 0
        self._lock = threading.Lock()

    def reset_match_state(self):
        self._inner.reset_match_state()

    def decide(self, request):
        with self._lock:
            self._served += 1
            use_script = self._served <= self._script_len
        if use_script:
            return self._inner.decide(request)  # pops the scripted entry
        return B.DecisionResult(dict(self._raw), self._label)


class SlowClient(object):
    """Wraps another client; sleeps before deciding for the first N requests.
    The sleep blocks only this connection's handler thread, mirroring a slow
    Claude call (the mod must hit its 8s transport read budget)."""

    def __init__(self, inner, delay_s, budget):
        self._inner = inner
        self._delay_s = delay_s
        self._budget = budget

    def reset_match_state(self):
        reset = getattr(self._inner, "reset_match_state", None)
        if reset:
            reset()

    def decide(self, request):
        if self._budget.consume():
            log.info("timeout scenario: sleeping %.1fs before replying (tick=%s)",
                     self._delay_s, request.get("tick"))
            time.sleep(self._delay_s)
        return self._inner.decide(request)


class SabotageServer(B.BridgeServer):
    """BridgeServer with reply-side sabotage for the transport scenarios.

    Only decision envelopes (dicts carrying "outcome") are touched; the SS3
    handshake frames (hello_ack has "type", and the 0x01 ready byte) pass
    through untouched so the mod always gets a clean handshake first.
    """

    def __init__(self, *args, **kwargs):
        self._scenario = kwargs.pop("scenario", "happy")
        self._budget = kwargs.pop("budget", _Budget(0))
        super(SabotageServer, self).__init__(*args, **kwargs)

    def _safe_reply(self, conn, envelope):
        is_decision = isinstance(envelope, dict) and "outcome" in envelope
        if is_decision and self._scenario == "schema_mismatch" and self._budget.consume():
            envelope = dict(envelope)
            envelope["schema_version"] = 2
            log.info("schema_mismatch scenario: replying with schema_version=2")
        if is_decision and self._scenario == "disconnect" and self._budget.consume():
            frame = B.encode_frame(envelope)
            cut = max(5, len(frame) // 2)  # past the 4-byte prefix, mid-body
            log.info("disconnect scenario: sending %d of %d bytes then dropping the connection",
                     cut, len(frame))
            try:
                conn.sendall(frame[:cut])
            except OSError:
                pass
            self._shutdown_sock(conn)
            return False  # caller treats this as a dead connection
        return super(SabotageServer, self)._safe_reply(conn, envelope)


def load_script(path):
    """JSON natively; YAML only if PyYAML happens to be installed."""
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    if path.lower().endswith((".yaml", ".yml")):
        try:
            import yaml  # optional; not in requirements.txt on purpose
        except ImportError:
            raise SystemExit(
                "--script %s is YAML but PyYAML is not installed. "
                "`pip install pyyaml` or supply JSON instead." % path)
        data = yaml.safe_load(text)
    else:
        data = json.loads(text)
    if not isinstance(data, list):
        raise SystemExit("--script must contain a LIST of decision objects (got %s)"
                         % type(data).__name__)
    return data


def build_client(scenario, script, sleep_s, budget):
    if scenario == "all_invalid":
        raw = {
            "ranked": [
                {"action_name": "NotARealMove", "data_index": 0,
                 "reason": "stub: deliberately not in legal_moves"},
                {"action_name": "AlsoNotAMove", "data_index": 99,
                 "reason": "stub: deliberately not in legal_moves"},
            ],
            "di_override": None,
            "feint": False,
            "reasoning_brief": "stub scenario: all_invalid",
        }
        return CannedClient(raw, "stub-all-invalid", script=script)
    if scenario == "empty_ranked":
        raw = {"ranked": [], "di_override": None, "feint": False,
               "reasoning_brief": "stub scenario: empty_ranked"}
        return CannedClient(raw, "stub-empty-ranked", script=script)
    inner = B.StubClient(script=script)
    if scenario == "timeout":
        return SlowClient(inner, sleep_s, budget)
    # happy / disconnect / schema_mismatch / auth_fail: decisions themselves
    # are the normal deterministic stub; sabotage (if any) is server-side.
    return inner


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Deterministic stub bridge for mod-side testing (DESIGN SS14.2). "
                    "Speaks the full SS3 protocol; no API key needed.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument("--scenario", choices=SCENARIOS, default="happy",
                        help="failure-injection scenario")
    parser.add_argument("--script", default=None, metavar="FILE",
                        help="JSON/YAML list of raw decision dicts, consumed one per "
                             "request before the scenario client takes over")
    parser.add_argument("--times", type=int, default=None, metavar="N",
                        help="how many requests/replies the scenario sabotages "
                             "(timeout/disconnect default 1; schema_mismatch default "
                             "-1 = every reply; -1 = unlimited)")
    parser.add_argument("--sleep", type=float, default=10.0, metavar="SECONDS",
                        help="stall length for --scenario timeout (SS14.2 uses 10s "
                             "vs the mod's 8s read budget)")
    parser.add_argument("--port", type=int, default=B.DEFAULT_PORT,
                        help="listen port (scans up to %d if taken, like the real "
                             "bridge)" % B.PORT_SCAN_MAX)
    parser.add_argument("--data-dir", default=None,
                        help="token/port/pid directory the mod reads "
                             "(default: %s)" % B.default_data_dir())
    parser.add_argument("--idle-exit", type=float, default=0.0,
                        help="exit after this many idle seconds (0 = run until "
                             "Ctrl+C; the real bridge defaults to 900)")
    parser.add_argument("--snapshots", action="store_true",
                        help="also write decisions.jsonl like the real bridge "
                             "(off by default so stub runs don't pollute logs)")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )

    times = args.times
    if times is None:
        times = 1 if args.scenario in _TIMES_DEFAULT_ONE else -1
    budget = _Budget(times)

    script = load_script(args.script) if args.script else None
    if script:
        log.info("loaded %d scripted decision(s) from %s", len(script), args.script)

    client = build_client(args.scenario, script, args.sleep, budget)
    bridge = B.Bridge(client, data_dir=args.data_dir, snapshots=args.snapshots)
    server = SabotageServer(bridge, port=args.port,
                            scan_ports=(args.port == B.DEFAULT_PORT),
                            idle_exit_s=args.idle_exit,
                            scenario=args.scenario, budget=budget)
    server.bind()  # writes port/token/pid files; binds 127.0.0.1 only (SS12.5)

    if args.scenario == "auth_fail":
        # The token FILE (which the mod reads) keeps the original value, but
        # the server now expects something else -> every handshake fails with
        # an auth_fail envelope, per the SS14.2 authentication-failure test.
        server.auth_token = "f" * 64
        log.info("auth_fail scenario: server token scrambled; the mod's file "
                 "token will be rejected")

    log.info("STUB BRIDGE up: scenario=%s port=%d data_dir=%s (Ctrl+C to stop)",
             args.scenario, server.port, bridge.data_dir)
    log.info("mod-side files: port+token under %s", bridge.data_dir)
    try:
        server.serve()
    except KeyboardInterrupt:
        log.info("interrupted -- shutting down")
    finally:
        server.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
