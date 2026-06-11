"""End-to-end tests over a REAL localhost socket: full SS3 handshake
(hello -> hello_ack -> hello_auth -> 0x01), then request -> StubClient ->
canonical envelope. Also: auth failure, disconnect recovery, malformed and
oversized frames, idle watchdog, and the SS12.5/SS16 runtime files.

Stdlib only — must pass without the `anthropic` package and without internet
(127.0.0.1 sockets only).
"""

import contextlib
import json
import os
import socket
import struct
import time

import pytest

import bridge as B
from bridge import read_frame, write_frame


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

@contextlib.contextmanager
def running_server(tmp_path, client=None, idle_exit_s=0):
    br = B.Bridge(client or B.StubClient(), data_dir=str(tmp_path),
                  git_sha="testsha", snapshots=False)
    server = B.BridgeServer(br, port=0, scan_ports=False,
                            idle_exit_s=idle_exit_s, harden=False)
    server.start_background()
    try:
        yield server
    finally:
        server.stop()


def file_token(server):
    with open(os.path.join(server.bridge.data_dir, "token"), "r", encoding="ascii") as fh:
        return fh.read().strip()


def connect(server):
    sock = socket.create_connection(("127.0.0.1", server.port), timeout=5)
    sock.settimeout(5)
    return sock


def handshake(sock, server, token=None):
    """Run the SS3 client side. Returns the hello_ack frame."""
    write_frame(sock, {"type": "hello", "mod_version": "0.1.0",
                       "schema_versions_supported": [1]})
    ack = read_frame(sock)
    write_frame(sock, {"type": "hello_auth",
                       "auth_token": token if token is not None else file_token(server)})
    ready = sock.recv(1)
    assert ready == b"\x01", "expected single ready byte 0x01, got %r" % ready
    return ack


def open_session(server):
    sock = connect(server)
    handshake(sock, server)
    return sock


def v1_request(tick=1473):
    return {
        "schema_version": 1,
        "match_id": "e2e-match",
        "tick": tick,
        "mode": "v1",
        "state": {
            "self": {"id": 2, "character_name": "Cowboy", "hp": 1180, "max_hp": 1500,
                     "super_meter": 42, "max_super_meter": 125, "feints": 1, "penalty": 5},
            "opponent": {"id": 1, "character_name": "Ninja", "hp": 1340, "max_hp": 1500,
                         "super_meter": 18, "max_super_meter": 125, "feints": 1, "penalty": 0},
            "game": {"current_tick": tick, "time_left": 2940, "stage_width": 600,
                     "super_active": False, "distance": 114},
        },
        "predicted_opponent": {"action_name": "Continue", "data": None,
                               "eval_score": 42.7, "source": "heuristic_get_best_move"},
        "legal_moves": [
            {"action_name": "HorizontalSlash", "action_type": "Attack",
             "earliest_hitbox": 6, "is_guard_break": False, "data_options": [{}]},
            {"action_name": "Grab", "action_type": "Special", "earliest_hitbox": 4,
             "is_guard_break": True,
             "data_options": [{"Dash": True}, {"Dash": False}]},
            {"action_name": "ParryHigh", "action_type": "Defense", "earliest_hitbox": None,
             "is_guard_break": False, "data_options": [{"Block Height": {"y": 0}}]},
        ],
        "recent_history": [],
        "character_info": {},
    }


# ---------------------------------------------------------------------------
# Handshake + runtime files (SS3, SS12.5, SS16.1, SS16.2)
# ---------------------------------------------------------------------------

def test_handshake_ack_ready_byte_and_runtime_files(tmp_path):
    with running_server(tmp_path) as server:
        sock = connect(server)
        try:
            ack = handshake(sock, server)
        finally:
            sock.close()
        assert ack["type"] == "hello_ack"
        assert ack["bridge_version"] == B.BRIDGE_VERSION
        assert ack["schema_version_selected"] == 1
        assert ack["git_sha"] == "testsha"
        # SS16.1: 32 random bytes -> 64 hex chars in the protected file.
        token = file_token(server)
        assert len(token) == 64 and int(token, 16) is not None
        # The bridge must NEVER echo the token to the (unauthenticated) peer:
        # the file is the only distribution channel.
        assert "auth_token" not in ack
        # SS12.5 port file: single ASCII integer matching the bound port.
        with open(os.path.join(str(tmp_path), "port"), encoding="ascii") as fh:
            assert int(fh.read()) == server.port
        # SS16.2 PID file.
        with open(os.path.join(str(tmp_path), "bridge.pid"), encoding="ascii") as fh:
            assert int(fh.read()) == os.getpid()


def test_auth_failure_gets_auth_fail_envelope_and_close(tmp_path):
    with running_server(tmp_path) as server:
        sock = connect(server)
        try:
            write_frame(sock, {"type": "hello", "mod_version": "0.1.0",
                               "schema_versions_supported": [1]})
            read_frame(sock)  # hello_ack
            write_frame(sock, {"type": "hello_auth", "auth_token": "f" * 64})
            envelope = read_frame(sock)
            assert envelope == {"ok": False, "outcome": "error",
                                "error_code": "auth_fail", "schema_version": 1}
            # connection is closed afterwards
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    chunk = sock.recv(64)
                except socket.timeout:
                    pytest.fail("server did not close after auth_fail")
                if chunk == b"":
                    break
            else:
                pytest.fail("server did not close after auth_fail")
        finally:
            sock.close()


def test_first_frame_not_hello_closes_connection(tmp_path):
    with running_server(tmp_path) as server:
        sock = connect(server)
        try:
            write_frame(sock, {"type": "definitely_not_hello"})
            assert sock.recv(64) == b""
        finally:
            sock.close()


# ---------------------------------------------------------------------------
# Decision roundtrips (request -> stub -> canonical envelope)
# ---------------------------------------------------------------------------

def test_v1_roundtrip(tmp_path):
    with running_server(tmp_path) as server:
        sock = open_session(server)
        try:
            write_frame(sock, v1_request())
            env = read_frame(sock)
        finally:
            sock.close()
        assert env["ok"] is True
        assert env["outcome"] == "ranked"
        assert env["schema_version"] == 1
        assert env["git_sha"] == "testsha"
        resp = env["response"]
        assert resp["tick"] == 1473 and resp["mode"] == "v1"
        names = {"HorizontalSlash", "Grab", "ParryHigh"}
        assert 1 <= len(resp["ranked"]) <= 3
        for entry in resp["ranked"]:
            assert entry["action_name"] in names
            assert isinstance(entry["data_index"], int)
        assert resp["di_override"] is None
        assert resp["feint"] is False
        assert isinstance(resp["latency_ms"], int)
        assert resp["model_version"] == "stub-auto"


def test_v0_roundtrip(tmp_path):
    with running_server(tmp_path) as server:
        sock = open_session(server)
        try:
            req = v1_request()
            req["mode"] = "v0"
            del req["legal_moves"]
            req["visible_categories"] = ["Movement", "Attack", "Defense"]
            write_frame(sock, req)
            env = read_frame(sock)
        finally:
            sock.close()
        assert env["ok"] is True and env["outcome"] == "category"
        assert env["response"]["category"] == "Attack"  # stub prefers Attack
        assert env["response"]["mode"] == "v0"


def test_v2_round2_roundtrip(tmp_path):
    with running_server(tmp_path) as server:
        sock = open_session(server)
        try:
            req = v1_request()
            req["mode"] = "v2_round2"
            req["candidates_evaluated"] = [
                {"action_name": "Grab", "data_index": 0, "predicted_self_hp_delta": 0,
                 "predicted_opponent_hp_delta": -80, "predicted_frame_advantage": 14},
                {"action_name": "HorizontalSlash", "data_index": 0,
                 "predicted_self_hp_delta": -100, "predicted_opponent_hp_delta": 0,
                 "predicted_frame_advantage": -12},
            ]
            req["predicted_opponent_assumed"] = {"action_name": "Continue", "data": None}
            write_frame(sock, req)
            env = read_frame(sock)
        finally:
            sock.close()
        assert env["ok"] is True and env["outcome"] == "ranked"
        assert env["response"]["mode"] == "v2_round2"
        assert len(env["response"]["ranked"]) == 1
        assert env["response"]["ranked"][0]["action_name"] == "Grab"


def test_multiple_requests_same_connection(tmp_path):
    with running_server(tmp_path) as server:
        sock = open_session(server)
        try:
            for tick in (100, 200, 300):
                write_frame(sock, v1_request(tick=tick))
                env = read_frame(sock)
                assert env["ok"] is True and env["response"]["tick"] == tick
        finally:
            sock.close()


# ---------------------------------------------------------------------------
# Degradation paths over the wire (SS9.2)
# ---------------------------------------------------------------------------

def test_scripted_all_invalid_yields_all_invalid_envelope(tmp_path):
    # Non-empty ranked, every entry invalid -> all_invalid (SS9.2); a literal
    # ranked: [] is the only case that maps to empty_ranked.
    script = [{"ranked": [{"action_name": "NotARealMove", "data_index": 0, "reason": "x"}],
               "di_override": None, "feint": False, "reasoning_brief": "bad"}]
    with running_server(tmp_path, client=B.StubClient(script=script)) as server:
        sock = open_session(server)
        try:
            write_frame(sock, v1_request())
            env = read_frame(sock)
        finally:
            sock.close()
        assert env == {"ok": False, "outcome": "error",
                       "error_code": "all_invalid", "schema_version": 1}


def test_schema_mismatch_over_the_wire(tmp_path):
    with running_server(tmp_path) as server:
        sock = open_session(server)
        try:
            req = v1_request()
            req["schema_version"] = 2
            write_frame(sock, req)
            env = read_frame(sock)
        finally:
            sock.close()
        assert env["ok"] is False and env["error_code"] == "schema_mismatch"


def test_malformed_json_frame_gets_parse_failure_and_connection_survives(tmp_path):
    with running_server(tmp_path) as server:
        sock = open_session(server)
        try:
            body = b"{this is not json"
            sock.sendall(struct.pack(">I", len(body)) + body)
            env = read_frame(sock)
            assert env["ok"] is False and env["error_code"] == "parse_failure"
            # the same connection still serves valid requests
            write_frame(sock, v1_request())
            env2 = read_frame(sock)
            assert env2["ok"] is True
        finally:
            sock.close()


def test_oversized_frame_closes_connection_then_reconnect_works(tmp_path):
    with running_server(tmp_path) as server:
        sock = open_session(server)
        try:
            sock.sendall(struct.pack(">I", 2_000_000))  # > 1 MB cap (SS16.3)
            assert sock.recv(64) == b""                 # server dropped us
        finally:
            sock.close()
        # bridge survives and accepts a fresh connection
        sock2 = open_session(server)
        try:
            write_frame(sock2, v1_request())
            assert read_frame(sock2)["ok"] is True
        finally:
            sock2.close()


def test_survives_mid_frame_disconnect_then_reconnect(tmp_path):
    with running_server(tmp_path) as server:
        sock = open_session(server)
        frame = B.encode_frame(v1_request())
        sock.sendall(frame[: len(frame) // 2])  # die mid-frame
        sock.close()
        time.sleep(0.2)
        sock2 = open_session(server)
        try:
            write_frame(sock2, v1_request())
            assert read_frame(sock2)["ok"] is True
        finally:
            sock2.close()


# ---------------------------------------------------------------------------
# Watchdog
# ---------------------------------------------------------------------------

def test_idle_watchdog_exits_on_its_own(tmp_path):
    br = B.Bridge(B.StubClient(), data_dir=str(tmp_path), git_sha="testsha",
                  snapshots=False)
    server = B.BridgeServer(br, port=0, scan_ports=False, idle_exit_s=0.5,
                            harden=False)
    server.start_background()
    try:
        assert server.wait(timeout=5), "watchdog did not shut the server down"
    finally:
        server.stop()


def test_zero_idle_exit_disables_watchdog(tmp_path):
    with running_server(tmp_path, idle_exit_s=0) as server:
        time.sleep(1.2)
        sock = open_session(server)  # still alive and serving
        try:
            write_frame(sock, v1_request())
            assert read_frame(sock)["ok"] is True
        finally:
            sock.close()


def test_watchdog_suppressed_while_connection_open(tmp_path):
    """An open-but-idle connection (AFK player mid-match) must NOT trip the
    idle exit; after the connection closes, the zero-connection reaper may."""
    with running_server(tmp_path, idle_exit_s=0.5) as server:
        sock = open_session(server)
        try:
            time.sleep(1.2)  # well past idle_exit_s, zero frames sent
            write_frame(sock, v1_request())
            assert read_frame(sock)["ok"] is True  # bridge still alive
        finally:
            sock.close()
        # with no connections left, the watchdog fires on its own
        assert server.wait(timeout=5), "watchdog did not fire after last close"


def test_runtime_files_removed_on_shutdown(tmp_path):
    with running_server(tmp_path, idle_exit_s=0.5) as server:
        assert os.path.exists(os.path.join(str(tmp_path), "port"))
        assert server.wait(timeout=5)
    assert not os.path.exists(os.path.join(str(tmp_path), "port"))
    assert not os.path.exists(os.path.join(str(tmp_path), "bridge.pid"))


# ---------------------------------------------------------------------------
# Handshake variants and concurrency
# ---------------------------------------------------------------------------

def test_handshake_with_unsupported_schema_offer_still_acks_v1(tmp_path):
    # PROTO_INCOMPAT path: the bridge logs and pins schema 1; SS3 leaves the
    # bail-out decision to the MOD (bridge_ready = false on its side).
    with running_server(tmp_path) as server:
        sock = connect(server)
        try:
            write_frame(sock, {"type": "hello", "mod_version": "9.9.9",
                               "schema_versions_supported": [2]})
            ack = read_frame(sock)
            assert ack["type"] == "hello_ack"
            assert ack["schema_version_selected"] == 1
            write_frame(sock, {"type": "hello_auth", "auth_token": file_token(server)})
            assert sock.recv(1) == b"\x01"
        finally:
            sock.close()


def test_second_connection_served_while_first_still_open(tmp_path):
    """A stale/held connection must not starve a new one (per-connection
    threads; the mod opens a fresh connection per match, SS16.5)."""
    with running_server(tmp_path) as server:
        s1 = open_session(server)
        try:
            write_frame(s1, v1_request(tick=1))
            assert read_frame(s1)["ok"] is True
            s2 = open_session(server)  # would hang forever on a serial server
            try:
                write_frame(s2, v1_request(tick=2))
                assert read_frame(s2)["ok"] is True
                write_frame(s1, v1_request(tick=3))  # first conn still works
                assert read_frame(s1)["ok"] is True
            finally:
                s2.close()
        finally:
            s1.close()


def test_connection_cap_evicts_oldest(tmp_path):
    with running_server(tmp_path) as server:
        s1 = open_session(server)
        s2 = open_session(server)
        s3 = open_session(server)  # cap is 2 -> s1 is evicted, newest wins
        try:
            write_frame(s3, v1_request())
            assert read_frame(s3)["ok"] is True
            write_frame(s2, v1_request())
            assert read_frame(s2)["ok"] is True
            assert s1.recv(64) == b""  # server shut the oldest down
        finally:
            for s in (s1, s2, s3):
                s.close()


# ---------------------------------------------------------------------------
# Rate limiting over the wire (SS16.4)
# ---------------------------------------------------------------------------

def drain_replies(sock):
    replies = 0
    while True:
        try:
            read_frame(sock)
        except B.FrameError as exc:
            assert exc.code == "closed", "expected clean close, got %s" % exc.code
            return replies
        replies += 1


def test_rate_limit_closes_connection_over_the_wire(tmp_path):
    with running_server(tmp_path) as server:
        sock = open_session(server)
        try:
            for tick in range(6):  # 6 requests inside the 1s window
                write_frame(sock, v1_request(tick=tick))
            assert drain_replies(sock) == 5  # 6th trips the limiter -> close
        finally:
            sock.close()


def test_malformed_frames_also_count_against_rate_limit(tmp_path):
    with running_server(tmp_path) as server:
        sock = open_session(server)
        try:
            body = b"{garbage"
            for _ in range(6):
                sock.sendall(struct.pack(">I", len(body)) + body)
            assert drain_replies(sock) == 5  # parse_failure x5, then close
        finally:
            sock.close()


# ---------------------------------------------------------------------------
# Port scan (SS12.5) — exercises the Windows SO_EXCLUSIVEADDRUSE path
# ---------------------------------------------------------------------------

def test_port_scan_skips_occupied_port(tmp_path):
    blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    blocker.bind(("127.0.0.1", 0))
    blocker.listen(1)
    taken = blocker.getsockname()[1]
    try:
        br = B.Bridge(B.StubClient(), data_dir=str(tmp_path), git_sha="testsha",
                      snapshots=False)
        server = B.BridgeServer(br, port=taken, scan_ports=True, idle_exit_s=0,
                                harden=False)
        server.start_background()
        try:
            span = B.PORT_SCAN_MAX - B.DEFAULT_PORT
            assert taken < server.port <= taken + span
            sock = open_session(server)
            try:
                write_frame(sock, v1_request())
                assert read_frame(sock)["ok"] is True
            finally:
                sock.close()
        finally:
            server.stop()
    finally:
        blocker.close()
