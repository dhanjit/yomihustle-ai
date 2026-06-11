"""Framing tests for DESIGN.md SS3: 4-byte UNSIGNED BIG-ENDIAN length prefix +
UTF-8 JSON body, 1 MB cap. Includes the SS3-mandated hand-sent known 4-byte
length assertion, partial reads, malformed JSON, and oversized frames.

Stdlib only — no `anthropic`, no network (loopback socketpairs only).
"""

import json
import socket
import struct
import threading
import time

import pytest

import bridge
from bridge import (
    MAX_FRAME_SIZE,
    FrameError,
    decode_length,
    encode_frame,
    read_frame,
    write_frame,
)


def pair():
    a, b = socket.socketpair()
    a.settimeout(5)
    b.settimeout(5)
    return a, b


# ---------------------------------------------------------------------------
# Length prefix: big-endian unsigned, hand-checked bytes (SS3 endianness note)
# ---------------------------------------------------------------------------

def test_known_4_byte_lengths_parse_big_endian():
    # SS3: "Integration tests MUST include a hand-sent known 4-byte length
    # and assert the parsed value."
    assert decode_length(b"\x00\x00\x00\x05") == 5
    assert decode_length(b"\x00\x00\x01\x00") == 256
    assert decode_length(b"\x00\x01\x00\x00") == 65536


def test_little_endian_bytes_do_not_parse_as_5():
    # b"\x05\x00\x00\x00" is 5 in LITTLE-endian. Read big-endian it is
    # 0x05000000 (83886080), which exceeds the 1 MB cap and is rejected —
    # proving the reader is big-endian, per the SS3 endianness note.
    with pytest.raises(FrameError) as exc:
        decode_length(b"\x05\x00\x00\x00")
    assert exc.value.code == "bad_length"


def test_encode_frame_prefix_is_struct_pack_big_endian():
    obj = {"a": 1}
    frame = encode_frame(obj)
    body = json.dumps(obj, separators=(",", ":"), sort_keys=True).encode("utf-8")
    assert frame[:4] == struct.pack(">I", len(body))
    assert frame[4:] == body


def test_decode_length_rejects_zero():
    with pytest.raises(FrameError) as exc:
        decode_length(struct.pack(">I", 0))
    assert exc.value.code == "bad_length"


def test_decode_length_rejects_over_1mb():
    with pytest.raises(FrameError) as exc:
        decode_length(struct.pack(">I", MAX_FRAME_SIZE + 1))
    assert exc.value.code == "bad_length"


def test_decode_length_accepts_exactly_1mb():
    assert decode_length(struct.pack(">I", MAX_FRAME_SIZE)) == MAX_FRAME_SIZE


def test_encode_frame_rejects_oversize_body():
    with pytest.raises(FrameError) as exc:
        encode_frame({"pad": "x" * (MAX_FRAME_SIZE + 10)})
    assert exc.value.code == "bad_length"


# ---------------------------------------------------------------------------
# Roundtrips over real sockets
# ---------------------------------------------------------------------------

def test_roundtrip_single_frame():
    a, b = pair()
    try:
        payload = {"tick": 1473, "mode": "v1", "di_scaling": "1.0"}
        write_frame(a, payload)
        assert read_frame(b) == payload
    finally:
        a.close()
        b.close()


def test_fixed_point_strings_survive_roundtrip():
    # hp/meter ints stay ints; di_scaling-style values stay STRINGS.
    a, b = pair()
    try:
        payload = {"hp": 1180, "super_meter": 42, "di_scaling": "6.0", "vel": "1.0"}
        write_frame(a, payload)
        out = read_frame(b)
        assert out["di_scaling"] == "6.0" and isinstance(out["di_scaling"], str)
        assert out["hp"] == 1180 and isinstance(out["hp"], int)
    finally:
        a.close()
        b.close()


def test_two_frames_back_to_back():
    a, b = pair()
    try:
        a.sendall(encode_frame({"n": 1}) + encode_frame({"n": 2}))
        assert read_frame(b) == {"n": 1}
        assert read_frame(b) == {"n": 2}
    finally:
        a.close()
        b.close()


def test_partial_reads_byte_by_byte():
    """The reader must reassemble a frame delivered one byte at a time."""
    a, b = pair()
    frame = encode_frame({"slow": True, "tick": 9})

    def drip():
        for i in range(len(frame)):
            a.sendall(frame[i:i + 1])
            time.sleep(0.002)

    sender = threading.Thread(target=drip)
    sender.start()
    try:
        assert read_frame(b, deadline=time.monotonic() + 10) == {"slow": True, "tick": 9}
    finally:
        sender.join()
        a.close()
        b.close()


def test_partial_reads_split_inside_header():
    a, b = pair()
    frame = encode_frame({"x": "y"})

    def send_split():
        a.sendall(frame[:2])       # half the length prefix
        time.sleep(0.05)
        a.sendall(frame[2:7])      # rest of prefix + start of body
        time.sleep(0.05)
        a.sendall(frame[7:])

    sender = threading.Thread(target=send_split)
    sender.start()
    try:
        assert read_frame(b, deadline=time.monotonic() + 10) == {"x": "y"}
    finally:
        sender.join()
        a.close()
        b.close()


# ---------------------------------------------------------------------------
# Failure paths
# ---------------------------------------------------------------------------

def test_malformed_json_raises_json_parse():
    a, b = pair()
    try:
        body = b"{not valid json!"
        a.sendall(struct.pack(">I", len(body)) + body)
        with pytest.raises(FrameError) as exc:
            read_frame(b)
        assert exc.value.code == "json_parse"
    finally:
        a.close()
        b.close()


def test_oversized_declared_length_rejected_before_body():
    a, b = pair()
    try:
        a.sendall(struct.pack(">I", 2_000_000))  # no body needed — header is enough
        with pytest.raises(FrameError) as exc:
            read_frame(b)
        assert exc.value.code == "bad_length"
    finally:
        a.close()
        b.close()


def test_clean_close_between_frames_is_closed():
    a, b = pair()
    try:
        a.close()
        with pytest.raises(FrameError) as exc:
            read_frame(b)
        assert exc.value.code == "closed"
    finally:
        b.close()


def test_close_mid_frame_is_disconnected():
    a, b = pair()
    try:
        frame = encode_frame({"x": 1})
        a.sendall(frame[:6])  # header + 2 body bytes, then die
        a.close()
        with pytest.raises(FrameError) as exc:
            read_frame(b)
        assert exc.value.code == "disconnected"
    finally:
        b.close()


def test_no_data_within_timeout_is_idle():
    a, b = pair()
    try:
        b.settimeout(0.1)
        with pytest.raises(FrameError) as exc:
            read_frame(b)
        assert exc.value.code == "idle"
    finally:
        a.close()
        b.close()


def test_stalled_mid_frame_hits_deadline():
    a, b = pair()
    try:
        b.settimeout(0.05)
        frame = encode_frame({"x": 1})
        a.sendall(frame[:6])  # start a frame, never finish it
        with pytest.raises(FrameError) as exc:
            read_frame(b, deadline=time.monotonic() + 0.3)
        assert exc.value.code == "read_timeout"
    finally:
        a.close()
        b.close()


def test_stalled_mid_frame_without_deadline_times_out():
    # deadline=None + a socket timeout must surface as read_timeout instead
    # of waiting forever mid-frame (latent footgun in the framing API).
    a, b = pair()
    try:
        b.settimeout(0.05)
        frame = encode_frame({"x": 1})
        a.sendall(frame[:6])
        with pytest.raises(FrameError) as exc:
            read_frame(b)  # no deadline on purpose
        assert exc.value.code == "read_timeout"
    finally:
        a.close()
        b.close()
