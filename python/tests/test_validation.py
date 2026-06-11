"""Validation tests for DESIGN.md SS3.2 / SS9.2 / SS9.4: the bridge validates
Claude's output against the closed legal set BEFORE returning to the game.
Covers: invalid action, bad data_index, empty candidates -> degradation
envelopes, DI/category validation, v2_round2 candidate checks, rate limiter,
and snapshot logging. Stdlib only — no `anthropic`, no network, no sockets.
"""

import json
import os

import bridge as B


# ---------------------------------------------------------------------------
# Fixtures mirroring the SS3.1 example payload
# ---------------------------------------------------------------------------

def legal_moves():
    return [
        {
            "action_name": "HorizontalSlash",
            "title": "Horizontal Slash",
            "action_type": "Attack",
            "earliest_hitbox": 6,
            "is_guard_break": False,
            "data_options": [{}],
        },
        {
            "action_name": "Grab",
            "title": "Grab",
            "action_type": "Special",
            "earliest_hitbox": 4,
            "is_guard_break": True,
            "data_options": [
                {"Dash": True, "Direction": {"x": 1, "y": 0}, "Jump": False},
                {"Dash": True, "Direction": {"x": -1, "y": 0}, "Jump": False},
                {"Dash": False, "Direction": {"x": 1, "y": 0}, "Jump": False},
                {"Dash": False, "Direction": {"x": -1, "y": 0}, "Jump": False},
            ],
        },
        {
            "action_name": "ParryHigh",
            "title": "Parry",
            "action_type": "Defense",
            "earliest_hitbox": None,
            "is_guard_break": False,
            "data_options": [{"Block Height": {"y": 0}, "Melee Parry Timing": {"count": 4}}],
        },
        {
            "action_name": "BrokenMove",
            "action_type": "Special",
            "data_options": [],  # zero valid invocations per SS3.2
        },
        {
            "action_name": "Continue",
            "action_type": "Movement",
            # data_options key intentionally absent -> treated as [{}]
        },
    ]


def v1_request(**overrides):
    req = {
        "schema_version": 1,
        "match_id": "match-0001",
        "round_number": 1,
        "round_score_self": 0,
        "round_score_opponent": 0,
        "tick": 1473,
        "mode": "v1",
        "state": {
            "self": {"id": 2, "character_name": "Cowboy", "hp": 1180, "max_hp": 1500,
                     "super_meter": 42, "max_super_meter": 125, "feints": 1,
                     "penalty": 5, "in_hitstun": False, "combo_proration": 1.0},
            "opponent": {"id": 1, "character_name": "Ninja", "hp": 1340, "max_hp": 1500,
                         "super_meter": 18, "max_super_meter": 125, "feints": 1,
                         "penalty": 0, "in_hitstun": False},
            "game": {"current_tick": 1473, "time_left": 2940, "stage_width": 600,
                     "super_active": False, "distance": 114},
        },
        "predicted_opponent": {"action_name": "Continue", "data": None,
                               "eval_score": 42.7, "source": "heuristic_get_best_move"},
        "legal_moves": legal_moves(),
        "recent_history": [],
        "character_info": {},
    }
    req.update(overrides)
    return req


def v0_request(**overrides):
    req = v1_request(mode="v0", visible_categories=["Movement", "Attack", "Defense"])
    del req["legal_moves"]
    req.update(overrides)
    return req


def make_bridge(client=None, tmp_path=None, snapshots=False):
    return B.Bridge(client or B.StubClient(), data_dir=str(tmp_path) if tmp_path else None,
                    git_sha="testsha", snapshots=snapshots)


# ---------------------------------------------------------------------------
# validate_ranked — pure function paths
# ---------------------------------------------------------------------------

def test_valid_entries_pass_and_preserve_order():
    ranked = [
        {"action_name": "Grab", "data_index": 2, "reason": "guard break"},
        {"action_name": "ParryHigh", "data_index": 0, "reason": "plan B"},
        {"action_name": "HorizontalSlash", "data_index": 0, "reason": "poke"},
    ]
    valid, dropped = B.validate_ranked(ranked, legal_moves())
    assert [v["action_name"] for v in valid] == ["Grab", "ParryHigh", "HorizontalSlash"]
    assert dropped == []


def test_invalid_action_dropped():
    valid, dropped = B.validate_ranked(
        [{"action_name": "DragonInstall", "data_index": 0, "reason": "x"},
         {"action_name": "Grab", "data_index": 0, "reason": "y"}],
        legal_moves())
    assert [v["action_name"] for v in valid] == ["Grab"]
    assert dropped[0]["reason"] == "unknown_action"


def test_data_index_out_of_range_dropped():
    valid, dropped = B.validate_ranked(
        [{"action_name": "Grab", "data_index": 4, "reason": "x"}], legal_moves())
    assert valid == []
    assert dropped[0]["reason"] == "data_index_out_of_range"


def test_negative_data_index_dropped():
    valid, dropped = B.validate_ranked(
        [{"action_name": "Grab", "data_index": -1, "reason": "x"}], legal_moves())
    assert valid == []
    assert dropped[0]["reason"] == "data_index_out_of_range"


def test_non_int_data_index_dropped():
    for bad in ("0", 1.5, None, True):
        valid, dropped = B.validate_ranked(
            [{"action_name": "Grab", "data_index": bad, "reason": "x"}], legal_moves())
        assert valid == [], "data_index=%r should be invalid" % (bad,)
        assert dropped[0]["reason"] == "data_index_not_int"


def test_empty_data_options_move_dropped():
    valid, dropped = B.validate_ranked(
        [{"action_name": "BrokenMove", "data_index": 0, "reason": "x"}], legal_moves())
    assert valid == []
    assert dropped[0]["reason"] == "zero_data_options"


def test_missing_data_options_treated_as_single_empty_invocation():
    valid, _ = B.validate_ranked(
        [{"action_name": "Continue", "data_index": 0, "reason": "wait"}], legal_moves())
    assert valid and valid[0]["action_name"] == "Continue"
    valid2, dropped2 = B.validate_ranked(
        [{"action_name": "Continue", "data_index": 1, "reason": "x"}], legal_moves())
    assert valid2 == [] and dropped2[0]["reason"] == "data_index_out_of_range"


def test_validation_capped_to_first_five_entries():
    # Mirrors the GDScript hard cap: slice to 5 before walking (SS3.2).
    ranked = [{"action_name": "Nope%d" % i, "data_index": 0, "reason": ""} for i in range(6)]
    ranked.append({"action_name": "Grab", "data_index": 0, "reason": "valid but 7th"})
    valid, dropped = B.validate_ranked(ranked, legal_moves())
    assert valid == []          # the only valid entry sits beyond the cap
    assert len(dropped) == 5    # exactly the first five were even considered


def test_ranked_not_a_list_is_all_dropped():
    valid, dropped = B.validate_ranked({"action_name": "Grab"}, legal_moves())
    assert valid == []
    assert dropped[0]["reason"] == "ranked_not_a_list"


def test_all_invalid_yields_empty():
    valid, dropped = B.validate_ranked(
        [{"action_name": "A", "data_index": 0, "reason": ""},
         "not even a dict",
         {"action_name": "Grab", "data_index": 99, "reason": ""}],
        legal_moves())
    assert valid == []
    assert len(dropped) == 3


def test_v2_candidates_validation():
    candidates = [
        {"action_name": "Grab", "data_index": 0, "predicted_opponent_hp_delta": -80},
        {"action_name": "ParryHigh", "data_index": 0, "predicted_opponent_hp_delta": 0},
    ]
    valid, dropped = B.validate_ranked_against_candidates(
        [{"action_name": "Grab", "data_index": 0, "reason": "best"}], candidates)
    assert valid[0]["action_name"] == "Grab"
    valid2, dropped2 = B.validate_ranked_against_candidates(
        [{"action_name": "Grab", "data_index": 3, "reason": "wrong idx"}], candidates)
    assert valid2 == [] and dropped2[0]["reason"] == "not_in_candidates_evaluated"


# ---------------------------------------------------------------------------
# DI / category validators (SS11, SS10)
# ---------------------------------------------------------------------------

def test_di_enum_accepted():
    for v in B.DI_ENUM:
        assert B.validate_di(v) == v


def test_di_invalid_values_become_none():
    for bad in ("backwards", "AWAY", "", 1, None, ["away"], {"di": "away"}):
        assert B.validate_di(bad) is None


def test_category_validation():
    assert B.validate_category("Attack", ["Movement", "Attack"])
    assert not B.validate_category("Super", ["Movement", "Attack"])
    assert not B.validate_category("attack", ["Movement", "Attack"])  # case-sensitive
    assert not B.validate_category(None, ["Movement"])
    assert not B.validate_category("Attack", None)


# ---------------------------------------------------------------------------
# handle_request — envelope paths (SS3 canonical envelope, SS9.2 taxonomy)
# ---------------------------------------------------------------------------

def test_v1_ok_envelope_shape():
    env = make_bridge().handle_request(v1_request())
    assert env["ok"] is True
    assert env["outcome"] == "ranked"
    assert env["schema_version"] == 1
    assert env["git_sha"] == "testsha"
    resp = env["response"]
    assert resp["tick"] == 1473
    assert resp["mode"] == "v1"
    assert 1 <= len(resp["ranked"]) <= 5
    legal_names = {m["action_name"] for m in legal_moves()}
    for entry in resp["ranked"]:
        assert entry["action_name"] in legal_names
    assert resp["di_override"] is None
    assert resp["feint"] is False
    assert isinstance(resp["latency_ms"], int)
    assert resp["model_version"] == "stub-auto"


def test_schema_mismatch_envelope():
    env = make_bridge().handle_request(v1_request(schema_version=2))
    assert env == {"ok": False, "outcome": "error",
                   "error_code": "schema_mismatch", "schema_version": 1}


def test_unknown_mode_is_parse_failure():
    env = make_bridge().handle_request(v1_request(mode="v99"))
    assert env["ok"] is False and env["error_code"] == "parse_failure"


def test_non_dict_request_is_parse_failure():
    env = make_bridge().handle_request(["not", "a", "dict"])
    assert env["ok"] is False and env["error_code"] == "parse_failure"


def test_v0_ok_envelope():
    env = make_bridge().handle_request(v0_request())
    assert env["ok"] is True and env["outcome"] == "category"
    assert env["response"]["mode"] == "v0"
    assert env["response"]["category"] in ["Movement", "Attack", "Defense"]


def test_v0_non_visible_category_is_forwarded():
    # SS9.2: an enum-valid category that is not visible this turn ships
    # anyway; the MOD's button filter degrades with v0_filter_empty (the
    # taxonomy-clean label), not the bridge with parse_failure.
    stub = B.StubClient(script=[{"category": "Super", "reasoning_brief": "not visible"}])
    env = make_bridge(client=stub).handle_request(v0_request())
    assert env["ok"] is True
    assert env["response"]["category"] == "Super"


def test_v0_non_enum_category_is_parse_failure():
    stub = B.StubClient(script=[{"category": "Hadouken", "reasoning_brief": "?"}])
    env = make_bridge(client=stub).handle_request(v0_request())
    assert env["ok"] is False and env["error_code"] == "parse_failure"


def test_all_invalid_ranked_degrades_to_all_invalid():
    # SS9.2: ranked was NON-EMPTY but every entry failed validation ->
    # all_invalid (empty_ranked is reserved for a literal `ranked: []`).
    stub = B.StubClient(script=[{
        "ranked": [{"action_name": "Hadouken", "data_index": 0, "reason": "no"}],
        "di_override": None, "feint": False, "reasoning_brief": "bad"}])
    env = make_bridge(client=stub).handle_request(v1_request())
    assert env["ok"] is False and env["error_code"] == "all_invalid"


def test_ranked_not_a_list_is_parse_failure_envelope():
    stub = B.StubClient(script=[{
        "ranked": {"action_name": "Grab"}, "di_override": None,
        "feint": False, "reasoning_brief": "shape broken"}])
    env = make_bridge(client=stub).handle_request(v1_request())
    assert env["ok"] is False and env["error_code"] == "parse_failure"


def test_empty_ranked_list_degrades():
    stub = B.StubClient(script=[{
        "ranked": [], "di_override": None, "feint": False, "reasoning_brief": ""}])
    env = make_bridge(client=stub).handle_request(v1_request())
    assert env["ok"] is False and env["error_code"] == "empty_ranked"


def test_partial_invalid_keeps_valid_entries():
    stub = B.StubClient(script=[{
        "ranked": [
            {"action_name": "Hadouken", "data_index": 0, "reason": "invalid"},
            {"action_name": "Grab", "data_index": 1, "reason": "valid"},
        ],
        "di_override": None, "feint": True, "reasoning_brief": "mixed"}])
    env = make_bridge(client=stub).handle_request(v1_request())
    assert env["ok"] is True
    assert [e["action_name"] for e in env["response"]["ranked"]] == ["Grab"]
    assert env["response"]["feint"] is True


def test_invalid_di_is_dropped_silently_but_move_survives():
    stub = B.StubClient(script=[{
        "ranked": [{"action_name": "Grab", "data_index": 0, "reason": "ok"}],
        "di_override": "sideways", "feint": False, "reasoning_brief": "x"}])
    env = make_bridge(client=stub).handle_request(v1_request())
    assert env["ok"] is True
    assert env["response"]["di_override"] is None


def test_valid_di_passes_through():
    stub = B.StubClient(script=[{
        "ranked": [{"action_name": "Grab", "data_index": 0, "reason": "ok"}],
        "di_override": "up-left", "feint": False, "reasoning_brief": "x"}])
    env = make_bridge(client=stub).handle_request(v1_request())
    assert env["response"]["di_override"] == "up-left"


def test_v2_round2_returns_single_pick():
    req = v1_request(mode="v2_round2", candidates_evaluated=[
        {"action_name": "Grab", "data_index": 0, "predicted_self_hp_delta": 0,
         "predicted_opponent_hp_delta": -80, "predicted_frame_advantage": 14,
         "predicted_distance_closed": 60, "predicted_self_super_delta": 0},
        {"action_name": "ParryHigh", "data_index": 0, "predicted_self_hp_delta": 0,
         "predicted_opponent_hp_delta": 0, "predicted_frame_advantage": 7,
         "predicted_distance_closed": -8, "predicted_self_super_delta": 0},
        {"action_name": "HorizontalSlash", "data_index": 0, "predicted_self_hp_delta": -100,
         "predicted_opponent_hp_delta": 0, "predicted_frame_advantage": -12,
         "predicted_distance_closed": 30, "predicted_self_super_delta": 0},
    ])
    env = make_bridge().handle_request(req)
    assert env["ok"] is True
    assert env["response"]["mode"] == "v2_round2"
    assert len(env["response"]["ranked"]) == 1  # SS3.4: single picked candidate
    assert env["response"]["ranked"][0]["action_name"] == "Grab"  # best ghost-eval


def test_v2_round2_pick_outside_candidates_degrades():
    stub = B.StubClient(script=[{
        "ranked": [{"action_name": "Grab", "data_index": 3, "reason": "not evaluated"}],
        "di_override": None, "feint": False, "reasoning_brief": "x"}])
    req = v1_request(mode="v2_round2",
                     candidates_evaluated=[{"action_name": "Grab", "data_index": 0}])
    env = make_bridge(client=stub).handle_request(req)
    assert env["ok"] is False and env["error_code"] == "all_invalid"


def test_v2_round2_accepts_ghost_eval_results_key():
    # DESIGN SS3.4 erratum: prose said `ghost_eval_results`, example said
    # `candidates_evaluated`. The bridge accepts both spellings.
    req = v1_request(mode="v2_round2", ghost_eval_results=[
        {"action_name": "Grab", "data_index": 0, "predicted_self_hp_delta": 0,
         "predicted_opponent_hp_delta": -80, "predicted_frame_advantage": 14},
        {"action_name": "ParryHigh", "data_index": 0, "predicted_self_hp_delta": 0,
         "predicted_opponent_hp_delta": 0, "predicted_frame_advantage": 7},
    ])
    env = make_bridge().handle_request(req)
    assert env["ok"] is True
    assert env["response"]["ranked"][0]["action_name"] == "Grab"


def test_v2_round2_bool_data_index_dropped():
    # Python's True == 1: without the type guard a bool data_index would
    # match an int candidate and ship to GDScript as JSON `true`.
    stub = B.StubClient(script=[{
        "ranked": [{"action_name": "Grab", "data_index": True, "reason": "bool"}],
        "di_override": None, "feint": False, "reasoning_brief": "x"}])
    req = v1_request(mode="v2_round2",
                     candidates_evaluated=[{"action_name": "Grab", "data_index": 1}])
    env = make_bridge(client=stub).handle_request(req)
    assert env["ok"] is False and env["error_code"] == "all_invalid"


def test_claude_error_maps_to_envelope_code():
    class FailingClient(object):
        def decide(self, request):
            raise B.ClaudeError("claude_timeout", "exceeded 6s")

    env = make_bridge(client=FailingClient()).handle_request(v1_request())
    assert env == {"ok": False, "outcome": "error",
                   "error_code": "claude_timeout", "schema_version": 1}


def test_unexpected_client_exception_becomes_api_error():
    class ExplodingClient(object):
        def decide(self, request):
            raise RuntimeError("boom")

    env = make_bridge(client=ExplodingClient()).handle_request(v1_request())
    assert env["ok"] is False and env["error_code"] == "api_error"


# ---------------------------------------------------------------------------
# Snapshots (SS15.1) and rate limiter (SS16.4)
# ---------------------------------------------------------------------------

def test_snapshot_jsonl_written(tmp_path):
    br = make_bridge(tmp_path=tmp_path, snapshots=True)
    br.handle_request(v1_request())
    br.handle_request(v1_request(tick=1500))
    path = os.path.join(str(tmp_path), "logs", "decisions.jsonl")
    with open(path, "r", encoding="utf-8") as fh:
        lines = [json.loads(line) for line in fh.read().splitlines()]
    assert len(lines) == 2
    snap = lines[0]
    assert snap["tick"] == 1473
    assert snap["envelope"]["ok"] is True
    assert snap["request"]["mode"] == "v1"
    assert snap["bridge_version"] == B.BRIDGE_VERSION
    assert snap["git_sha"] == "testsha"
    assert "total_ms" in snap["latency"]
    # SS9.5 latency breakdown: Claude-call time is recorded separately.
    assert isinstance(snap["latency"]["claude_ms"], int)


def read_snapshots(tmp_path):
    path = os.path.join(str(tmp_path), "logs", "decisions.jsonl")
    with open(path, "r", encoding="utf-8") as fh:
        return [json.loads(line) for line in fh.read().splitlines()]


def test_snapshot_rotation_keeps_one_generation(tmp_path, monkeypatch):
    monkeypatch.setattr(B, "SNAPSHOT_ROTATE_BYTES", 10)  # force rotation
    br = make_bridge(tmp_path=tmp_path, snapshots=True)
    br.handle_request(v1_request())
    br.handle_request(v1_request(tick=1500))  # first file > 10 bytes -> rotate
    logs = os.path.join(str(tmp_path), "logs")
    assert os.path.exists(os.path.join(logs, "decisions.jsonl"))
    assert os.path.exists(os.path.join(logs, "decisions.jsonl.1"))
    assert len(read_snapshots(tmp_path)) == 1  # current generation only


def test_ranked_cardinality_recorded_in_dropped_telemetry(tmp_path):
    # SS9.2 ranked_cardinality: validation slices to 5, so the raw >50 length
    # must be preserved via telemetry or the reason can never be observed.
    ranked = [{"action_name": "Grab", "data_index": 0, "reason": "ok"}]
    ranked += [{"action_name": "Nope%d" % i, "data_index": 0, "reason": ""} for i in range(51)]
    stub = B.StubClient(script=[{
        "ranked": ranked, "di_override": None, "feint": False, "reasoning_brief": "x"}])
    br = make_bridge(client=stub, tmp_path=tmp_path, snapshots=True)
    env = br.handle_request(v1_request())
    assert env["ok"] is True  # entry 0 is valid; we still serve the turn
    reasons = {d["reason"] for d in read_snapshots(tmp_path)[0]["dropped_candidates"]}
    assert "ranked_cardinality" in reasons


def test_round2_surplus_picks_land_in_dropped_telemetry(tmp_path):
    stub = B.StubClient(script=[{
        "ranked": [
            {"action_name": "Grab", "data_index": 0, "reason": "best"},
            {"action_name": "ParryHigh", "data_index": 0, "reason": "second"},
        ],
        "di_override": None, "feint": False, "reasoning_brief": "x"}])
    req = v1_request(mode="v2_round2", candidates_evaluated=[
        {"action_name": "Grab", "data_index": 0},
        {"action_name": "ParryHigh", "data_index": 0},
    ])
    br = make_bridge(client=stub, tmp_path=tmp_path, snapshots=True)
    env = br.handle_request(req)
    assert env["ok"] is True
    assert len(env["response"]["ranked"]) == 1  # SS3.4 single pick
    reasons = [d["reason"] for d in read_snapshots(tmp_path)[0]["dropped_candidates"]]
    assert "round2_extra_pick_discarded" in reasons


def test_match_change_triggers_client_reset_hook():
    class CountingClient(B.StubClient):
        resets = 0

        def reset_match_state(self):
            self.resets += 1

    client = CountingClient()
    br = make_bridge(client=client)
    br.handle_request(v1_request())                      # new match -> reset
    br.handle_request(v1_request(tick=1500))             # same match
    assert client.resets == 1
    br.handle_request(v1_request(match_id="match-0002"))  # new match -> reset
    assert client.resets == 2


def test_rate_limiter_allows_5_per_second_then_blocks():
    rl = B.RateLimiter(max_events=5, window_s=1.0)
    t0 = 100.0
    for i in range(5):
        assert rl.allow(now=t0 + i * 0.01)
    assert not rl.allow(now=t0 + 0.5)          # 6th inside the window
    assert rl.allow(now=t0 + 1.2)              # window expired


def test_stub_is_deterministic():
    br1, br2 = make_bridge(), make_bridge()
    e1 = br1.handle_request(v1_request())
    e2 = br2.handle_request(v1_request())
    assert e1["response"]["ranked"] == e2["response"]["ranked"]
