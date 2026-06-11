#!/usr/bin/env python3
"""Claude <-> YOMI Hustle TCP bridge.

Single-file localhost bridge between the Godot mod (GDScript, see src/) and
the Anthropic API, per DESIGN.md:

  - SS3   wire protocol: 4-byte UNSIGNED BIG-ENDIAN length prefix + UTF-8 JSON
          body, 1 MB frame cap, hello/hello_ack/hello_auth/0x01 handshake,
          canonical outcome envelope.
  - SS9   failure modes: 6s Claude budget (claude_timeout), SDK retries
          disabled (max_retries=0), degradation-reason taxonomy.
  - SS10  v0 category-picker mode.
  - SS12.5 port discovery 8765..8770, port file in the data dir.
  - SS14.1 --fixture mode for socket-free request/response exercise.
  - SS15  bridge-side decision log (logs/decisions.jsonl, size-rotated).
          Supplementary only: the authoritative per-turn snapshots of SS15.1
          are written MOD-side (user://claude_yomih/turns/...).
  - SS16  token auth, PID file, frame-size cap, 5 req/s rate limit.

Runs on stdlib only. The `anthropic` package is imported lazily and ONLY when
the real client is selected (i.e. never under --stub, never in tests).
"""

import argparse
import errno
import hmac
import json
import logging
import os
import secrets
import socket
import struct
import subprocess
import sys
import threading
import time
from collections import deque

# ---------------------------------------------------------------------------
# Constants (DESIGN SS3, SS9, SS12.5, SS16)
# ---------------------------------------------------------------------------

BRIDGE_VERSION = "0.1.0"
SCHEMA_VERSION = 1
SCHEMA_VERSIONS_SUPPORTED = [1]

DEFAULT_PORT = 8765           # SS12.5
PORT_SCAN_MAX = 8770          # SS12.5: retry port+1 up to 8770 on EADDRINUSE
MAX_FRAME_SIZE = 1_048_576    # SS16.3: 1 MB on both sides

CLAUDE_TIMEOUT_S = 6.0        # SS9.1: Python Claude call budget 6000ms
RATE_LIMIT_MAX = 5            # SS16.4: max 5 requests/second per connection
RATE_LIMIT_WINDOW_S = 1.0
DEFAULT_IDLE_EXIT_S = 900.0   # watchdog: exit after 15 min with no traffic
                              # AND no open connection (a live, idle match
                              # never kills the bridge; see _idle_expired)
READY_BYTE = b"\x01"          # SS3 handshake terminal marker
MAX_CONNECTIONS = 2           # per-conn handler threads; oldest is evicted
SNAPSHOT_ROTATE_BYTES = 50 * 1024 * 1024  # rotate decisions.jsonl past 50 MB

# SS11 canonical DI enum (GDScript drops unknown values silently; we also
# normalise bridge-side so the wire stays clean).
DI_ENUM = [
    "neutral", "away", "toward", "up", "opponent-corner",
    "up-left", "up-right", "down-left", "down-right",
]

# SS10: CharState.ActionType.keys() minus the passive "Hurt".
CATEGORY_ENUM = ["Movement", "Attack", "Special", "Super", "Defense"]

RANKED_MODES = ("v1", "v2_round1", "v2_round2")

DEFAULT_MODEL = "claude-opus-4-8"      # v1 / v2 rounds
DEFAULT_MODEL_V0 = "claude-sonnet-4-6"  # SS10: v0 is the cheapest Claude path

log = logging.getLogger("claude_yomih.bridge")


def _is_store_python():
    """Microsoft Store Python runs in an app container that VIRTUALIZES
    AppData writes: files written under %LOCALAPPDATA% silently land in
    %LOCALAPPDATA%/Packages/PythonSoftwareFoundation.../LocalCache/Local/
    where no other process (i.e. the game) can find them. Non-AppData
    paths write through normally."""
    return os.name == "nt" and "windowsapps" in sys.executable.lower()


def default_data_dir():
    """%LOCALAPPDATA%/claude_yomih on Windows (~/.claude_yomih under Store
    Python, which virtualizes AppData), ~/.local/share/claude_yomih else
    (SS16.1). The mod probes both Windows locations."""
    if os.name == "nt":
        if _is_store_python():
            return os.path.join(os.path.expanduser("~"), ".claude_yomih")
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
        return os.path.join(base, "claude_yomih")
    return os.path.join(os.path.expanduser("~"), ".local", "share", "claude_yomih")


def detect_git_sha():
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=os.path.dirname(os.path.abspath(__file__)),
            capture_output=True, text=True, timeout=5,
        )
        if out.returncode == 0:
            return out.stdout.strip()
    except Exception:
        pass
    return "unknown"


# ---------------------------------------------------------------------------
# Framing (DESIGN SS3): 4-byte unsigned big-endian length prefix + JSON body
# ---------------------------------------------------------------------------

class FrameError(Exception):
    """Transport-level frame failure. `code` mirrors the SS9.2 transport tier."""

    def __init__(self, code, detail=""):
        super().__init__("%s: %s" % (code, detail))
        self.code = code
        self.detail = detail


def encode_frame(obj):
    """JSON-encode `obj` and prepend struct.pack('>I', len(body)) (SS3)."""
    body = json.dumps(obj, separators=(",", ":"), sort_keys=True).encode("utf-8")
    if len(body) > MAX_FRAME_SIZE:
        raise FrameError("bad_length", "outgoing frame %d > %d" % (len(body), MAX_FRAME_SIZE))
    return struct.pack(">I", len(body)) + body


def decode_length(header):
    """Parse a 4-byte big-endian unsigned length prefix and bounds-check it."""
    if len(header) != 4:
        raise FrameError("len_read", "short header (%d bytes)" % len(header))
    (length,) = struct.unpack(">I", header)
    if length == 0 or length > MAX_FRAME_SIZE:
        raise FrameError("bad_length", "declared length %d" % length)
    return length


def recv_exact(sock, n, deadline=None):
    """Read exactly n bytes, tolerating partial recv()s and socket timeouts."""
    buf = b""
    while len(buf) < n:
        if deadline is not None and time.monotonic() > deadline:
            raise FrameError("read_timeout", "stalled mid-frame")
        try:
            chunk = sock.recv(n - len(buf))
        except socket.timeout:
            if deadline is None:
                # No deadline + socket timeout would otherwise wait forever
                # mid-frame; surface it as a transport-tier timeout instead.
                raise FrameError("read_timeout", "socket timeout mid-frame (no deadline)")
            continue
        except OSError as exc:
            raise FrameError("body_read", str(exc))
        if not chunk:
            raise FrameError("disconnected", "peer closed mid-frame")
        buf += chunk
    return buf


def read_frame(sock, deadline=None):
    """Read one length-prefixed JSON frame. Returns the parsed JSON value.

    Raises FrameError. A clean disconnect *between* frames raises
    FrameError("closed") so callers can distinguish it from mid-frame death.
    """
    try:
        first = sock.recv(1)
    except socket.timeout:
        raise FrameError("idle", "no frame within timeout")
    except OSError as exc:
        raise FrameError("len_read", str(exc))
    if not first:
        raise FrameError("closed", "peer closed between frames")
    header = first + recv_exact(sock, 3, deadline)
    length = decode_length(header)
    body = recv_exact(sock, length, deadline)
    try:
        return json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise FrameError("json_parse", str(exc))


def write_frame(sock, obj):
    try:
        sock.sendall(encode_frame(obj))
    except OSError as exc:
        raise FrameError("write_failed", str(exc))


# ---------------------------------------------------------------------------
# Validation (DESIGN SS3.2, SS9.4): bridge validates BEFORE returning to game
# ---------------------------------------------------------------------------

def _data_options_of(move):
    """Resolve a legal-move entry's data_options.

    Missing/None is treated as [{}] (one empty-dict invocation) so a sparse
    enumerator entry for e.g. Continue is never spuriously dropped; an
    explicit [] means zero valid invocations per SS3.2.
    """
    opts = move.get("data_options")
    if opts is None:
        return [{}]
    return opts if isinstance(opts, list) else []


def validate_ranked(ranked, legal_moves):
    """Walk Claude's ranked list against the closed legal set.

    Returns (valid, dropped) where valid is the surviving entries (validation
    is capped to the first 5 entries, mirroring the GDScript slice) and
    dropped is [{"entry":..., "reason":...}] for telemetry.
    """
    valid, dropped = [], []
    if not isinstance(ranked, list):
        return [], [{"entry": ranked, "reason": "ranked_not_a_list"}]
    by_name = {}
    for move in legal_moves or []:
        if isinstance(move, dict) and isinstance(move.get("action_name"), str):
            by_name.setdefault(move["action_name"], move)
    for entry in ranked[:5]:
        if not isinstance(entry, dict):
            dropped.append({"entry": entry, "reason": "entry_not_object"})
            continue
        name = entry.get("action_name")
        idx = entry.get("data_index")
        if not isinstance(name, str) or name not in by_name:
            dropped.append({"entry": entry, "reason": "unknown_action"})
            continue
        if isinstance(idx, bool) or not isinstance(idx, int):
            dropped.append({"entry": entry, "reason": "data_index_not_int"})
            continue
        options = _data_options_of(by_name[name])
        if len(options) == 0:
            dropped.append({"entry": entry, "reason": "zero_data_options"})
            continue
        if idx < 0 or idx >= len(options):
            dropped.append({"entry": entry, "reason": "data_index_out_of_range"})
            continue
        valid.append({
            "action_name": name,
            "data_index": idx,
            "reason": str(entry.get("reason", ""))[:300],
        })
    return valid, dropped


def candidates_of(request):
    """v2_round2 candidate block. DESIGN SS3.4's prose says `ghost_eval_results`
    while its example JSON (and SS6.1's encoder) uses `candidates_evaluated`;
    accept both so neither reading of the spec yields silent 100% empty_ranked.
    """
    cands = request.get("candidates_evaluated")
    if cands is None:
        cands = request.get("ghost_eval_results")
    return cands


def validate_ranked_against_candidates(ranked, candidates):
    """v2_round2: the pick must be one of the ghost-evaluated candidates."""
    valid, dropped = [], []
    if not isinstance(ranked, list):
        return [], [{"entry": ranked, "reason": "ranked_not_a_list"}]
    pairs = set()
    for cand in candidates or []:
        if isinstance(cand, dict):
            pairs.add((cand.get("action_name"), cand.get("data_index")))
    for entry in ranked[:5]:
        if not isinstance(entry, dict):
            dropped.append({"entry": entry, "reason": "entry_not_object"})
            continue
        name = entry.get("action_name")
        idx = entry.get("data_index")
        # Same type guard as validate_ranked: Python's True == 1 would let a
        # bool data_index match an int candidate and ship as JSON `true`.
        if isinstance(idx, bool) or not isinstance(idx, int):
            dropped.append({"entry": entry, "reason": "data_index_not_int"})
            continue
        if (name, idx) in pairs:
            valid.append({
                "action_name": name,
                "data_index": idx,
                "reason": str(entry.get("reason", ""))[:300],
            })
        else:
            dropped.append({"entry": entry, "reason": "not_in_candidates_evaluated"})
    return valid, dropped


def validate_di(value):
    """Return the DI string if it's a canonical SS11 enum value, else None."""
    return value if isinstance(value, str) and value in DI_ENUM else None


def validate_category(category, visible_categories):
    return (
        isinstance(category, str)
        and isinstance(visible_categories, list)
        and category in visible_categories
    )


class RateLimiter:
    """SS16.4: max 5 requests/second per connection."""

    def __init__(self, max_events=RATE_LIMIT_MAX, window_s=RATE_LIMIT_WINDOW_S):
        self.max_events = max_events
        self.window_s = window_s
        self._events = deque()

    def allow(self, now=None):
        now = time.monotonic() if now is None else now
        while self._events and now - self._events[0] > self.window_s:
            self._events.popleft()
        if len(self._events) >= self.max_events:
            return False
        self._events.append(now)
        return True


# ---------------------------------------------------------------------------
# Outcome envelope (DESIGN SS3): single canonical shape, success or failure
# ---------------------------------------------------------------------------

def ok_envelope(outcome, response, git_sha):
    return {
        "ok": True,
        "outcome": outcome,
        "response": response,
        "schema_version": SCHEMA_VERSION,
        "git_sha": git_sha,
    }


def error_envelope(error_code):
    # Exact SS3 shape: {"ok": false, "outcome": "error", "error_code": ..., "schema_version": 1}
    # error_code enum: claude_timeout|api_error|parse_failure|empty_ranked|
    # all_invalid|schema_mismatch|auth_fail (all_invalid added per SS9.2/SS9.4:
    # ranked was non-empty but every entry failed bridge-side validation).
    return {
        "ok": False,
        "outcome": "error",
        "error_code": error_code,
        "schema_version": SCHEMA_VERSION,
    }


# ---------------------------------------------------------------------------
# Claude clients
# ---------------------------------------------------------------------------

class ClaudeError(Exception):
    """Maps to the SS9.2 Python-side degradation reasons."""

    def __init__(self, error_code, detail=""):
        super().__init__("%s: %s" % (error_code, detail))
        self.error_code = error_code
        self.detail = detail


class DecisionResult(object):
    def __init__(self, raw, model_version, usage=None):
        self.raw = raw                  # dict straight out of the model/stub
        self.model_version = model_version
        self.usage = usage or {}


# Static tool schemas: byte-stable across requests so the Anthropic prompt
# cache (tools render at position 0) is never invalidated. Dynamic legality
# (action names, visible categories) is enforced bridge-side in validate_*.
RANKED_TOOL = {
    "name": "submit_move_ranking",
    "description": (
        "Submit your final decision for this turn: an ordered ranking of up to "
        "3 candidate moves (best first). Every entry MUST use an action_name "
        "that appears in this request's legal_moves and a data_index that is a "
        "valid 0-based index into that move's data_options array."
    ),
    "strict": True,
    "input_schema": {
        "type": "object",
        "properties": {
            "ranked": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "action_name": {
                            "type": "string",
                            "description": "Exact action_name copied from legal_moves.",
                        },
                        "data_index": {
                            "type": "integer",
                            "description": "0-based index into that move's data_options.",
                        },
                        "reason": {
                            "type": "string",
                            "description": "One short sentence: why this candidate.",
                        },
                    },
                    "required": ["action_name", "data_index", "reason"],
                    "additionalProperties": False,
                },
                "description": "1 to 3 candidates, best first.",
            },
            "di_override": {
                "anyOf": [
                    {"type": "string", "enum": DI_ENUM},
                    {"type": "null"},
                ],
                "description": (
                    "Directional influence. Only meaningful while in hitstun; "
                    "use null otherwise."
                ),
            },
            "feint": {
                "type": "boolean",
                "description": "Cancel the chosen move into a feint (needs a feint charge).",
            },
            "reasoning_brief": {
                "type": "string",
                "description": "<= 200 chars summary of the plan for this turn.",
            },
        },
        "required": ["ranked", "di_override", "feint", "reasoning_brief"],
        "additionalProperties": False,
    },
}

CATEGORY_TOOL = {
    "name": "submit_category",
    "description": (
        "Submit the single action CATEGORY to commit to this turn. It MUST be "
        "one of this request's visible_categories; a tuned in-game heuristic "
        "will pick the concrete move within your category."
    ),
    "strict": True,
    "input_schema": {
        "type": "object",
        "properties": {
            "category": {"type": "string", "enum": CATEGORY_ENUM},
            "reasoning_brief": {
                "type": "string",
                "description": "<= 200 chars: why this category right now.",
            },
        },
        "required": ["category", "reasoning_brief"],
        "additionalProperties": False,
    },
}


class PromptStore(object):
    """Loads system prompts + optional per-character frame-data JSON.

    Character blocks are cached as raw file text so the rendered system
    blocks are byte-stable -> Anthropic prompt cache hits (per-character
    caching, DESIGN SS13.5). Missing character file -> generic prompt + one
    warning (frame data is produced by another workstream; never fail).
    """

    def __init__(self, prompts_dir):
        self.prompts_dir = prompts_dir
        self._system_cache = {}
        self._char_cache = {}
        self._warned = set()

    def clear_caches(self):
        """Per-match reset hook (SS3.1: match_id change resets prompt caches).

        Re-reads prompt files on the next request so a prompt edited between
        matches takes effect without restarting the bridge. _warned is kept:
        a missing character file should warn once per process, not per match.
        """
        self._system_cache.clear()
        self._char_cache.clear()

    def system_text(self, mode):
        name = "system_v0.txt" if mode == "v0" else "system_v1.txt"
        if name not in self._system_cache:
            path = os.path.join(self.prompts_dir, name)
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    self._system_cache[name] = fh.read()
            except OSError:
                log.warning("system prompt missing: %s (using built-in minimal prompt)", path)
                self._system_cache[name] = (
                    "You are playing the fighting game Your Only Move Is HUSTLE. "
                    "Respond only via the provided tool."
                )
        return self._system_cache[name]

    def character_block(self, character_name):
        if not isinstance(character_name, str) or not character_name:
            return None
        key = character_name.lower()
        if key in self._char_cache:
            return self._char_cache[key]
        path = os.path.join(self.prompts_dir, "characters", key + ".json")
        block = None
        try:
            with open(path, "r", encoding="utf-8") as fh:
                block = (
                    "Frame data and move list for the character %s "
                    "(JSON, fields: Move/Startup/IASA/Active/Damage/Resource/Proration/Notes):\n"
                    % character_name
                ) + fh.read()
        except OSError:
            if key not in self._warned:
                self._warned.add(key)
                log.warning(
                    "no character prompt at %s; proceeding with generic prompt", path
                )
        self._char_cache[key] = block
        return block

    def system_blocks(self, mode, request):
        """[system text, self char, opponent char], each with cache_control."""
        blocks = [{
            "type": "text",
            "text": self.system_text(mode),
            "cache_control": {"type": "ephemeral"},
        }]
        state = request.get("state") or {}
        for side in ("self", "opponent"):
            char = (state.get(side) or {}).get("character_name")
            text = self.character_block(char)
            if text:
                label = "YOUR character" if side == "self" else "the OPPONENT's character"
                blocks.append({
                    "type": "text",
                    "text": "The following describes %s.\n%s" % (label, text),
                    "cache_control": {"type": "ephemeral"},
                })
        return blocks


class StubClient(object):
    """Deterministic offline client for tests and bridge-only smoke runs.

    Auto mode derives a canned decision from the request. Pass `script`
    (list of raw decision dicts, consumed in order) to force specific model
    outputs, e.g. invalid ones, for degradation-path tests.
    """

    def __init__(self, script=None):
        self._script = list(script) if script else []
        self._script_lock = threading.Lock()  # connections are served on threads

    def reset_match_state(self):
        pass  # stub keeps no per-match state

    def decide(self, request):
        with self._script_lock:
            if self._script:
                return DecisionResult(self._script.pop(0), "stub-scripted")
        mode = request.get("mode")
        if mode == "v0":
            visible = request.get("visible_categories") or []
            category = "Attack" if "Attack" in visible else (visible[0] if visible else "Attack")
            return DecisionResult(
                {"category": category, "reasoning_brief": "stub: deterministic category"},
                "stub-auto",
            )
        if mode == "v2_round2":
            best, best_score = None, None
            for cand in candidates_of(request) or []:
                if not isinstance(cand, dict):
                    continue
                score = (
                    -(cand.get("predicted_opponent_hp_delta") or 0)
                    + (cand.get("predicted_self_hp_delta") or 0)
                    + 20 * (cand.get("predicted_frame_advantage") or 0)
                )
                if best_score is None or score > best_score:
                    best, best_score = cand, score
            ranked = []
            if best is not None:
                ranked = [{
                    "action_name": best.get("action_name"),
                    "data_index": best.get("data_index"),
                    "reason": "stub: best ghost-eval score",
                }]
            return DecisionResult(
                {"ranked": ranked, "di_override": None, "feint": False,
                 "reasoning_brief": "stub: round-2 adjudication"},
                "stub-auto",
            )
        # v1 / v2_round1: first up to 3 legal moves with a usable invocation.
        ranked = []
        for move in request.get("legal_moves") or []:
            if not isinstance(move, dict):
                continue
            if len(_data_options_of(move)) == 0:
                continue
            ranked.append({
                "action_name": move.get("action_name"),
                "data_index": 0,
                "reason": "stub pick #%d" % (len(ranked) + 1),
            })
            if len(ranked) == 3:
                break
        return DecisionResult(
            {"ranked": ranked, "di_override": None, "feint": False,
             "reasoning_brief": "stub: first legal moves in order"},
            "stub-auto",
        )


class AnthropicClient(object):
    """Real client. Imports `anthropic` lazily, only when constructed.

    - max_retries=0: SDK retries DISABLED per SS9.1 (all retry logic mod-side)
    - timeout=6.0s: SS9.1 Claude-call budget; overrun -> claude_timeout
    - forced tool_choice for structured output; tool schemas are static
    - prompt caching: cache_control on system blocks (prompt + char data)
    - no `thinking`, no sampling params (removed on current Opus models; the
      latency budget wants direct answers anyway)
    """

    def __init__(self, prompts, model=DEFAULT_MODEL, model_v0=DEFAULT_MODEL_V0,
                 timeout_s=CLAUDE_TIMEOUT_S):
        import anthropic  # lazy: only the real client pays this import
        self._anthropic = anthropic
        self._client = anthropic.Anthropic(timeout=timeout_s, max_retries=0)
        self._prompts = prompts
        self._model = model
        self._model_v0 = model_v0

    def reset_match_state(self):
        self._prompts.clear_caches()

    def decide(self, request):
        mode = request.get("mode")
        if mode == "v0":
            tool, model, max_tokens = CATEGORY_TOOL, self._model_v0, 500
        else:
            tool, model, max_tokens = RANKED_TOOL, self._model, 1500
        user_text = (
            "Decision request (JSON). Pick using ONLY this request's legal "
            "moves/categories, then call the tool.\n"
            + json.dumps(request, sort_keys=True)
        )
        try:
            resp = self._client.messages.create(
                model=model,
                max_tokens=max_tokens,
                system=self._prompts.system_blocks(mode, request),
                tools=[tool],
                tool_choice={"type": "tool", "name": tool["name"]},
                messages=[{"role": "user", "content": user_text}],
            )
        except self._anthropic.APITimeoutError as exc:
            raise ClaudeError("claude_timeout", str(exc))
        except self._anthropic.APIStatusError as exc:
            raise ClaudeError("api_error", "status %s" % getattr(exc, "status_code", "?"))
        except self._anthropic.APIConnectionError as exc:
            raise ClaudeError("api_error", str(exc))
        block = next((b for b in resp.content if b.type == "tool_use"), None)
        if block is None or not isinstance(block.input, dict):
            raise ClaudeError("parse_failure", "no tool_use block in response")
        usage = {}
        try:
            usage = {
                "input_tokens": resp.usage.input_tokens,
                "output_tokens": resp.usage.output_tokens,
                "cache_read_input_tokens": resp.usage.cache_read_input_tokens,
                "cache_creation_input_tokens": resp.usage.cache_creation_input_tokens,
            }
        except Exception:
            pass
        return DecisionResult(block.input, resp.model, usage)


# ---------------------------------------------------------------------------
# Bridge core: request handling (socket-free; reused by --fixture and tests)
# ---------------------------------------------------------------------------

class Bridge(object):
    def __init__(self, client, data_dir=None, git_sha=None, snapshots=True):
        self.client = client
        self.data_dir = data_dir or default_data_dir()
        self.git_sha = git_sha or detect_git_sha()
        self.snapshots = snapshots
        self._match_id = None
        self._match_lock = threading.Lock()
        self._snapshot_lock = threading.Lock()

    # -- per-match state (SS3 notes: match_id resets per-match state) -------
    def _observe_match(self, request):
        match_id = request.get("match_id")
        with self._match_lock:
            if match_id == self._match_id:
                return
            self._match_id = match_id
        reset = getattr(self.client, "reset_match_state", None)
        if reset is not None:
            try:
                reset()
            except Exception:
                log.exception("per-match reset hook failed; continuing")
        log.info("new match_id=%s -- per-match state reset", match_id)

    def handle_request(self, request):
        """Request dict -> canonical outcome envelope dict. Never raises."""
        started = time.monotonic()
        # NOTE on request-tier failures (SS9.2): the taxonomy defines
        # parse_failure as "Claude's text response did not parse"; a malformed
        # *request* cannot occur with a conformant mod, so rather than extend
        # the closed SS3 enum we reuse parse_failure and record the real cause
        # in `detail` (visible in logs + decision snapshots).
        if not isinstance(request, dict):
            return self._finish(request, error_envelope("parse_failure"),
                                started, detail="request not an object")
        if request.get("schema_version") != SCHEMA_VERSION:
            return self._finish(request, error_envelope("schema_mismatch"),
                                started, detail="schema_version=%r" % request.get("schema_version"))
        self._observe_match(request)
        mode = request.get("mode")
        if mode != "v0" and mode not in RANKED_MODES:
            return self._finish(request, error_envelope("parse_failure"),
                                started, detail="unknown mode %r" % mode)

        claude_started = time.monotonic()
        try:
            result = self.client.decide(request)
        except ClaudeError as exc:
            return self._finish(request, error_envelope(exc.error_code),
                                started, detail=exc.detail)
        except Exception as exc:  # never let the bridge die on a turn
            log.exception("unexpected client failure")
            return self._finish(request, error_envelope("api_error"),
                                started, detail=repr(exc))
        claude_ms = int((time.monotonic() - claude_started) * 1000)

        if mode == "v0":
            envelope, dropped = self._build_v0(request, result, claude_ms)
        else:
            envelope, dropped = self._build_ranked(request, result, claude_ms, mode)
        return self._finish(request, envelope, started, result=result,
                            dropped=dropped, claude_ms=claude_ms)

    def _build_v0(self, request, result, claude_ms):
        raw = result.raw if isinstance(result.raw, dict) else {}
        category = raw.get("category")
        if not (isinstance(category, str) and category in CATEGORY_ENUM):
            # The tool output broke the closed category enum -> the response
            # itself is malformed, which is the SS9.2 parse_failure tier.
            return error_envelope("parse_failure"), [
                {"entry": category, "reason": "category_not_in_enum"}]
        dropped = []
        if not validate_category(category, request.get("visible_categories") or []):
            # SS9.2 taxonomy: an enum-valid category that simply is not
            # visible this turn is FORWARDED. The mod's button filter then
            # yields zero buttons and degrades with v0_filter_empty -- the
            # taxonomy-clean label -- instead of a bogus parse_failure here.
            dropped.append({"entry": category, "reason": "category_not_visible_forwarded"})
        response = {
            "tick": request.get("tick"),
            "mode": "v0",
            "category": category,
            "reasoning_brief": str(raw.get("reasoning_brief", ""))[:300],
            "latency_ms": claude_ms,
            "model_version": result.model_version,
        }
        return ok_envelope("category", response, self.git_sha), dropped

    def _build_ranked(self, request, result, claude_ms, mode):
        raw = result.raw if isinstance(result.raw, dict) else {}
        ranked = raw.get("ranked")
        if not isinstance(ranked, list):
            # Tool output missing/of the wrong shape -> the response itself is
            # malformed: SS9.2 parse_failure, not a candidate-quality failure.
            return error_envelope("parse_failure"), [
                {"entry": ranked, "reason": "ranked_not_a_list"}]
        raw_len = len(ranked)
        if mode == "v2_round2":
            valid, dropped = validate_ranked_against_candidates(
                ranked, candidates_of(request))
            # SS3.4: round-2 response is a single pick. Surplus picks that
            # validated are discarded but kept in telemetry (SS15) so the
            # snapshots can still explain Claude's full ranking.
            for extra in valid[1:]:
                dropped.append({"entry": extra, "reason": "round2_extra_pick_discarded"})
            valid = valid[:1]
        else:
            valid, dropped = validate_ranked(ranked, request.get("legal_moves"))
        if raw_len > 50:
            # SS3.2/SS9.2 ranked_cardinality: validation slices to 5, so the
            # mod can never observe >50 entries -- record the raw length in
            # telemetry here so the histogram does not silently lose the case.
            dropped.append({"entry": "raw_ranked_len=%d" % raw_len,
                            "reason": "ranked_cardinality"})
        if not valid:
            # SS9.2: `empty_ranked` is "ranked: [] in response"; a non-empty
            # ranked whose every entry failed validation is `all_invalid`.
            code = "empty_ranked" if raw_len == 0 else "all_invalid"
            return error_envelope(code), dropped
        di = validate_di(raw.get("di_override"))
        if raw.get("di_override") is not None and di is None:
            dropped.append({"entry": raw.get("di_override"), "reason": "di_override_invalid"})
        response = {
            "tick": request.get("tick"),
            "mode": mode,
            "ranked": valid,
            "di_override": di,
            "feint": bool(raw.get("feint", False)),
            "reasoning_brief": str(raw.get("reasoning_brief", ""))[:300],
            "latency_ms": claude_ms,
            "model_version": result.model_version,
        }
        return ok_envelope("ranked", response, self.git_sha), dropped

    # -- observability: bridge-side decision log (supplementary to the
    #    mod-side SS15.1 per-turn snapshots, which remain authoritative) -----
    def _finish(self, request, envelope, started, detail="", result=None,
                dropped=None, claude_ms=None):
        total_ms = int((time.monotonic() - started) * 1000)
        req = request if isinstance(request, dict) else {}
        log.info(
            "[match=%s tick=%s mode=%s] outcome=%s%s latency_ms=%d%s",
            req.get("match_id"), req.get("tick"), req.get("mode"),
            envelope.get("outcome"),
            "" if envelope.get("ok") else " error_code=" + str(envelope.get("error_code")),
            total_ms,
            (" detail=" + detail) if detail else "",
        )
        if self.snapshots:
            snapshot = {
                "ts": time.time(),
                "bridge_version": BRIDGE_VERSION,
                "git_sha": self.git_sha,
                "schema_version": SCHEMA_VERSION,
                "match_id": req.get("match_id"),
                "tick": req.get("tick"),
                "mode": req.get("mode"),
                "request": request,
                "envelope": envelope,
                "dropped_candidates": dropped or [],
                "error_detail": detail,
                "model_version": result.model_version if result else None,
                "usage": result.usage if result else {},
                # claude_ms = Claude-call wall time only; total_ms = whole
                # request. None on paths that never reached Claude (SS9.5
                # latency breakdown).
                "latency": {"total_ms": total_ms, "claude_ms": claude_ms},
            }
            self._write_snapshot(snapshot)
        return envelope

    def _write_snapshot(self, snapshot):
        try:
            logs_dir = os.path.join(self.data_dir, "logs")
            os.makedirs(logs_dir, exist_ok=True)
            path = os.path.join(logs_dir, "decisions.jsonl")
            line = json.dumps(snapshot, sort_keys=True, default=repr)
            with self._snapshot_lock:
                try:
                    # Size-based rotation: keep exactly one prior generation
                    # (.1). Bounds bridge-side disk growth; the mod-side
                    # SS15.1 snapshots own gzip + last-100-matches retention.
                    if os.path.getsize(path) > SNAPSHOT_ROTATE_BYTES:
                        os.replace(path, path + ".1")
                except OSError:
                    pass  # no log file yet
                with open(path, "a", encoding="utf-8") as fh:
                    fh.write(line + "\n")
        except OSError as exc:
            log.warning("snapshot write failed: %s", exc)


# ---------------------------------------------------------------------------
# TCP server: handshake (SS3), auth (SS16.1), rate limit (SS16.4), watchdog
# ---------------------------------------------------------------------------

class BridgeServer(object):
    def __init__(self, bridge, host="127.0.0.1", port=DEFAULT_PORT,
                 scan_ports=True, idle_exit_s=DEFAULT_IDLE_EXIT_S, harden=True):
        self.bridge = bridge
        self.host = host  # SS12.5: hardcoded loopback; never 0.0.0.0
        self.requested_port = port
        self.scan_ports = scan_ports
        self.idle_exit_s = idle_exit_s
        self.harden = harden
        self.port = None
        self.auth_token = None
        self._listener = None
        self._shutdown = threading.Event()
        self._thread = None
        self._last_activity = time.monotonic()
        self._conns = []  # open connections, oldest first (cap MAX_CONNECTIONS)
        self._conn_lock = threading.Lock()

    # -- lifecycle -----------------------------------------------------------
    def start_background(self):
        self.bind()
        self._thread = threading.Thread(target=self.serve, name="bridge-accept", daemon=True)
        self._thread.start()
        return self

    def stop(self):
        self._shutdown.set()
        self._evict_all()
        if self._listener is not None:
            try:
                self._listener.close()
            except OSError:
                pass
        if self._thread is not None:
            self._thread.join(timeout=5)

    def wait(self, timeout=None):
        if self._thread is not None:
            self._thread.join(timeout)
            return not self._thread.is_alive()
        return True

    # -- setup ---------------------------------------------------------------
    def bind(self):
        candidates = [self.requested_port]
        if self.scan_ports and self.requested_port > 0:
            # SS12.5 scan: requested port, then +1 ... over the same span as
            # 8765..8770 (callers enable scan_ports only for the default port;
            # tests use an OS-assigned base to exercise this path).
            span = PORT_SCAN_MAX - DEFAULT_PORT
            candidates = [p for p in range(self.requested_port,
                                           self.requested_port + span + 1)
                          if p <= 65535]
        last_err = None
        for port in candidates:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            if os.name == "nt":
                # On Windows, SO_REUSEADDR lets bind() succeed over a port
                # another process is actively LISTENING on -- the SS12.5 scan
                # never sees EADDRINUSE and two bridges silently fight over
                # 8765. SO_EXCLUSIVEADDRUSE restores fail-fast semantics.
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            else:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind((self.host, port))
            except OSError as exc:
                sock.close()
                in_use = (errno.EADDRINUSE, getattr(errno, "WSAEADDRINUSE", errno.EADDRINUSE))
                if exc.errno not in in_use:
                    raise  # SS12.5: only EADDRINUSE walks to port+1
                last_err = exc
                continue
            sock.listen(2)
            sock.settimeout(0.5)  # accept loop wakes to check watchdog/shutdown
            self._listener = sock
            self.port = sock.getsockname()[1]
            break
        if self._listener is None:
            raise SystemExit("could not bind %s on ports %s: %s" % (self.host, candidates, last_err))
        self._write_runtime_files()
        if _is_store_python():
            log.info("Microsoft Store Python detected — runtime files in %s "
                     "(AppData is virtualized inside the Store sandbox)",
                     self.bridge.data_dir)
        log.info("bridge %s listening on %s:%d (git %s)",
                 BRIDGE_VERSION, self.host, self.port, self.bridge.git_sha)

    def _write_runtime_files(self):
        os.makedirs(self.bridge.data_dir, exist_ok=True)
        # SS16.1 token (32 random bytes -> 64 hex chars)
        self.auth_token = secrets.token_hex(32)
        token_path = os.path.join(self.bridge.data_dir, "token")
        with open(token_path, "w", encoding="ascii") as fh:
            fh.write(self.auth_token)
        self._restrict(token_path)
        # SS12.5 port file (single ASCII integer)
        with open(os.path.join(self.bridge.data_dir, "port"), "w", encoding="ascii") as fh:
            fh.write(str(self.port))
        # SS16.2 PID file
        with open(os.path.join(self.bridge.data_dir, "bridge.pid"), "w", encoding="ascii") as fh:
            fh.write(str(os.getpid()))

    def _cleanup_runtime_files(self):
        """Best-effort removal of port + bridge.pid on exit so a stale port
        file never points the mod at a dead (or hijacked) port. The token file
        is left in place; it is useless without a live bridge."""
        for name in ("port", "bridge.pid"):
            try:
                os.remove(os.path.join(self.bridge.data_dir, name))
            except OSError:
                pass

    def _restrict(self, path):
        """Best-effort SS16.1 file protection (chmod 600 / icacls)."""
        try:
            if os.name != "nt":
                os.chmod(path, 0o600)
            elif self.harden:
                user = os.environ.get("USERNAME", "")
                if user:
                    subprocess.run(
                        ["icacls", path, "/inheritance:r", "/grant:r", "%s:F" % user],
                        capture_output=True, timeout=10,
                    )
        except Exception as exc:
            log.warning("could not restrict %s: %s", path, exc)

    # -- accept loop -----------------------------------------------------------
    def serve(self):
        try:
            while not self._shutdown.is_set():
                if self._idle_expired():
                    log.info("idle watchdog: no traffic for %.0fs and no open "
                             "connection -- exiting", self.idle_exit_s)
                    break
                try:
                    conn, addr = self._listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break  # listener closed by stop()
                self._touch()
                log.info("connection from %s:%d", *addr)
                self._admit(conn)
        finally:
            self._shutdown.set()
            self._evict_all()
            if self._listener is not None:
                try:
                    self._listener.close()
                except OSError:
                    pass
            self._cleanup_runtime_files()

    def _admit(self, conn):
        """Serve `conn` on its own thread so a stale/leaked connection can
        never starve a new one (the mod opens a fresh connection per match,
        SS16.5). Past MAX_CONNECTIONS the OLDEST connection is evicted --
        newest-wins matches the per-match reconnect reality."""
        with self._conn_lock:
            while len(self._conns) >= MAX_CONNECTIONS:
                old = self._conns.pop(0)
                log.warning("connection cap %d reached -- evicting oldest", MAX_CONNECTIONS)
                self._shutdown_sock(old)
            self._conns.append(conn)
        threading.Thread(target=self._serve_connection, args=(conn,),
                         name="bridge-conn", daemon=True).start()

    def _serve_connection(self, conn):
        try:
            self._handle_connection(conn)
        except Exception:
            log.exception("connection handler crashed; surviving")
        finally:
            with self._conn_lock:
                if conn in self._conns:
                    self._conns.remove(conn)
            try:
                conn.close()
            except OSError:
                pass
            log.info("connection closed")

    @staticmethod
    def _shutdown_sock(sock):
        try:
            sock.shutdown(socket.SHUT_RDWR)  # wakes the handler's recv with EOF
        except OSError:
            pass

    def _evict_all(self):
        with self._conn_lock:
            conns = list(self._conns)
        for conn in conns:
            self._shutdown_sock(conn)

    def _touch(self):
        self._last_activity = time.monotonic()

    def _idle_expired(self):
        """True only with idle-exit enabled, NO open connection, and no
        traffic for idle_exit_s. An open connection always suppresses the
        watchdog: a player AFK mid-match must not lose the bridge (the SS9.3
        re-probe has nothing to restart it). Dead peers surface as EOF/RST on
        loopback, so zombie connections cannot pin the process."""
        if not self.idle_exit_s:
            return False
        with self._conn_lock:
            if self._conns:
                return False
        return (time.monotonic() - self._last_activity) > self.idle_exit_s

    # -- per-connection --------------------------------------------------------
    def _handle_connection(self, conn):
        conn.settimeout(1.0)  # recv wakes regularly so shutdown/watchdog work
        if not self._handshake(conn):
            return
        limiter = RateLimiter()
        while not self._shutdown.is_set():
            try:
                request = read_frame(conn, deadline=time.monotonic() + 30.0)
            except FrameError as exc:
                if exc.code == "idle":
                    continue  # no frame yet; open conn suppresses the watchdog
                if exc.code == "closed":
                    return  # clean disconnect between frames
                if exc.code == "json_parse":
                    # frame-aligned (body fully consumed) -> respond and
                    # survive. Malformed frames count against the SS16.4 rate
                    # limit too, else garbage frames bypass it entirely.
                    self._touch()
                    if not limiter.allow():
                        log.warning("RATE_LIMIT exceeded on malformed frames -- closing connection")
                        return
                    log.warning("malformed JSON frame: %s", exc.detail)
                    self._safe_reply(conn, error_envelope("parse_failure"))
                    continue
                log.warning("transport error (%s): %s -- dropping connection",
                            exc.code, exc.detail)
                return
            self._touch()
            if not limiter.allow():
                log.warning("RATE_LIMIT exceeded (%d req/%.0fs) -- closing connection",
                            RATE_LIMIT_MAX, RATE_LIMIT_WINDOW_S)
                return
            envelope = self.bridge.handle_request(request)
            self._touch()
            if not self._safe_reply(conn, envelope):
                return

    def _safe_reply(self, conn, envelope):
        try:
            write_frame(conn, envelope)
            return True
        except FrameError as exc:
            log.warning("reply failed (%s); dropping connection", exc.code)
            return False

    def _read_handshake_frame(self, conn, deadline):
        """read_frame, retrying across the 1s recv timeout until `deadline`."""
        while time.monotonic() < deadline and not self._shutdown.is_set():
            try:
                return read_frame(conn, deadline=deadline)
            except FrameError as exc:
                if exc.code == "idle":
                    continue
                raise
        raise FrameError("read_timeout", "handshake frame not received in time")

    def _handshake(self, conn):
        """SS3: hello -> hello_ack -> hello_auth -> single 0x01 ready byte."""
        try:
            hello = self._read_handshake_frame(conn, time.monotonic() + 10.0)
        except FrameError as exc:
            if exc.code != "closed":
                log.warning("handshake: no hello frame (%s)", exc.code)
            return False
        if not isinstance(hello, dict) or hello.get("type") != "hello":
            log.warning("handshake: first frame was not hello")
            return False
        offered = hello.get("schema_versions_supported")
        selected = SCHEMA_VERSION
        if isinstance(offered, list) and SCHEMA_VERSION not in offered:
            log.warning("PROTO_INCOMPAT: mod offers %s, bridge supports %s",
                        offered, SCHEMA_VERSIONS_SUPPORTED)
        # SS16.1: the token is NEVER sent over the wire by the bridge. The mod
        # reads it from the protected token file; echoing it in hello_ack
        # would hand it to any unauthenticated local process and defeat the
        # auth entirely.
        if not self._safe_reply(conn, {
            "type": "hello_ack",
            "bridge_version": BRIDGE_VERSION,
            "schema_version_selected": selected,
            "git_sha": self.bridge.git_sha,
        }):
            return False
        try:
            auth = self._read_handshake_frame(conn, time.monotonic() + 10.0)
        except FrameError as exc:
            log.warning("handshake: no hello_auth frame (%s)", exc.code)
            return False
        token = auth.get("auth_token") if isinstance(auth, dict) else None
        if not (isinstance(auth, dict) and auth.get("type") == "hello_auth"
                and isinstance(token, str)
                and hmac.compare_digest(token, self.auth_token)):
            log.warning("AUTH_FAIL: hello_auth token mismatch -- closing")
            self._safe_reply(conn, error_envelope("auth_fail"))
            return False
        try:
            conn.sendall(READY_BYTE)
        except OSError:
            return False
        log.info("handshake complete (mod_version=%s schema=%d)",
                 hello.get("mod_version"), selected)
        return True


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def build_client(args):
    prompts_dir = args.prompts_dir or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "prompts")
    prompts = PromptStore(prompts_dir)
    if args.stub:
        return StubClient()
    try:
        return AnthropicClient(prompts, model=args.model, model_v0=args.model_v0,
                               timeout_s=args.claude_timeout)
    except Exception as exc:  # ImportError or missing-credentials at construction
        print("bridge: could not initialise the Anthropic client: %s" % exc,
              file=sys.stderr)
        print("bridge: set ANTHROPIC_API_KEY (and `pip install -r requirements.txt`), "
              "or run with --stub for the offline client.", file=sys.stderr)
        raise SystemExit(2)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Claude <-> YOMI Hustle localhost TCP bridge (DESIGN.md SS3)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help="listen port (default %d; scans up to %d if taken)"
                             % (DEFAULT_PORT, PORT_SCAN_MAX))
    parser.add_argument("--stub", action="store_true",
                        help="use the deterministic offline StubClient (no anthropic, no network)")
    parser.add_argument("--model", default=DEFAULT_MODEL,
                        help="Anthropic model for v1/v2 (default %s)" % DEFAULT_MODEL)
    parser.add_argument("--model-v0", default=DEFAULT_MODEL_V0,
                        help="Anthropic model for v0 category mode (default %s)" % DEFAULT_MODEL_V0)
    parser.add_argument("--prompts-dir", default=None,
                        help="prompt directory (default: ./prompts next to bridge.py)")
    parser.add_argument("--data-dir", default=None,
                        help="token/port/pid/logs directory (default: %s)" % default_data_dir())
    parser.add_argument("--idle-exit", type=float, default=DEFAULT_IDLE_EXIT_S,
                        help="watchdog: exit after this many idle seconds (0 disables; default %.0f)"
                             % DEFAULT_IDLE_EXIT_S)
    parser.add_argument("--claude-timeout", type=float, default=CLAUDE_TIMEOUT_S,
                        help="Claude API call budget in seconds (default %.1f, per DESIGN SS9.1)"
                             % CLAUDE_TIMEOUT_S)
    parser.add_argument("--no-snapshots", action="store_true",
                        help="disable JSONL decision snapshots")
    parser.add_argument("--fixture", default=None,
                        help="read one request JSON from this file, print the envelope, exit "
                             "(DESIGN SS14.1)")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )

    if args.claude_timeout >= 8.0:
        # SS9.1: the mod abandons the read after 8s; a Claude budget at or
        # above that means successful replies can land after the mod has
        # already degraded the turn (transport_read_timeout).
        log.warning("--claude-timeout %.1fs >= the mod's 8s read budget (SS9.1); "
                    "replies may arrive after the mod gives up on the turn",
                    args.claude_timeout)

    bridge = Bridge(build_client(args), data_dir=args.data_dir,
                    snapshots=not args.no_snapshots)

    if args.fixture:
        with open(args.fixture, "r", encoding="utf-8") as fh:
            request = json.load(fh)
        envelope = bridge.handle_request(request)
        print(json.dumps(envelope, indent=2, sort_keys=True))
        return 0

    server = BridgeServer(bridge, port=args.port,
                          scan_ports=(args.port == DEFAULT_PORT),
                          idle_exit_s=args.idle_exit)
    server.bind()
    try:
        server.serve()
    except KeyboardInterrupt:
        log.info("interrupted -- shutting down")
    finally:
        server.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
