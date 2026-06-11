"""Prompt-assembly + CLI coverage for DESIGN.md SS13.5 / SS14.1: PromptStore
caching and byte-stability (Anthropic prompt-cache hygiene), per-character
block fallback, the recorded-fixture corpus, --fixture mode, and the friendly
exit when the real client cannot be constructed.

Stdlib only -- no `anthropic`, no network, no sockets.
"""

import glob
import importlib.util
import json
import os

import pytest

import bridge as B

FIXTURES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


# ---------------------------------------------------------------------------
# PromptStore (SS13.5: byte-stable system blocks -> prompt cache hits)
# ---------------------------------------------------------------------------

def make_store(tmp_path, chars=None):
    d = tmp_path / "prompts"
    (d / "characters").mkdir(parents=True)
    (d / "system_v0.txt").write_text("SYSTEM V0 TEXT", encoding="utf-8")
    (d / "system_v1.txt").write_text("SYSTEM V1 TEXT", encoding="utf-8")
    for name, content in (chars or {}).items():
        (d / "characters" / (name + ".json")).write_text(content, encoding="utf-8")
    return B.PromptStore(str(d)), d


def request_with_chars(self_char, opp_char):
    return {"state": {"self": {"character_name": self_char},
                      "opponent": {"character_name": opp_char}}}


def test_system_text_selects_mode_file(tmp_path):
    store, _ = make_store(tmp_path)
    assert store.system_text("v0") == "SYSTEM V0 TEXT"
    assert store.system_text("v1") == "SYSTEM V1 TEXT"
    assert store.system_text("v2_round1") == "SYSTEM V1 TEXT"  # non-v0 -> v1


def test_system_text_cache_is_stable_across_file_edits(tmp_path):
    # Byte-stability is what keeps the Anthropic prompt cache warm: once read,
    # the text must not change mid-session even if the file does.
    store, d = make_store(tmp_path)
    assert store.system_text("v1") == "SYSTEM V1 TEXT"
    (d / "system_v1.txt").write_text("EDITED", encoding="utf-8")
    assert store.system_text("v1") == "SYSTEM V1 TEXT"


def test_clear_caches_rereads_prompt_files(tmp_path):
    # SS3.1 per-match reset: a new match_id may pick up edited prompts.
    store, d = make_store(tmp_path)
    assert store.system_text("v1") == "SYSTEM V1 TEXT"
    (d / "system_v1.txt").write_text("EDITED", encoding="utf-8")
    store.clear_caches()
    assert store.system_text("v1") == "EDITED"


def test_missing_system_prompt_falls_back_to_builtin(tmp_path):
    store = B.PromptStore(str(tmp_path / "nonexistent"))
    text = store.system_text("v1")
    assert "HUSTLE" in text  # built-in minimal prompt, never an exception


def test_character_block_found_and_lowercased(tmp_path):
    store, _ = make_store(tmp_path, chars={"cowboy": '{"moves": []}'})
    block = store.character_block("Cowboy")  # game name is capitalised
    assert block is not None
    assert '{"moves": []}' in block and "Cowboy" in block


def test_character_block_missing_returns_none(tmp_path):
    store, _ = make_store(tmp_path)
    assert store.character_block("Gorilla") is None
    assert store.character_block("") is None
    assert store.character_block(None) is None


def test_system_blocks_order_and_cache_control(tmp_path):
    store, _ = make_store(tmp_path, chars={"cowboy": "COWBOY DATA",
                                           "ninja": "NINJA DATA"})
    blocks = store.system_blocks("v1", request_with_chars("Cowboy", "Ninja"))
    assert len(blocks) == 3  # [system, self char, opponent char]
    assert blocks[0]["text"] == "SYSTEM V1 TEXT"
    assert "YOUR character" in blocks[1]["text"] and "COWBOY DATA" in blocks[1]["text"]
    assert "OPPONENT's character" in blocks[2]["text"] and "NINJA DATA" in blocks[2]["text"]
    for block in blocks:  # 3 breakpoints used <= Anthropic's max of 4
        assert block["cache_control"] == {"type": "ephemeral"}


def test_system_blocks_byte_stable_across_calls(tmp_path):
    store, _ = make_store(tmp_path, chars={"cowboy": "COWBOY DATA"})
    req = request_with_chars("Cowboy", "Gorilla")  # one present, one missing
    first = json.dumps(store.system_blocks("v1", req), sort_keys=True)
    second = json.dumps(store.system_blocks("v1", req), sort_keys=True)
    assert first == second
    assert len(store.system_blocks("v1", req)) == 2  # missing char -> no block


# ---------------------------------------------------------------------------
# Fixture corpus (SS14.1): recorded payloads through the full request path
# ---------------------------------------------------------------------------

def fixture_paths():
    return sorted(glob.glob(os.path.join(FIXTURES_DIR, "*.json")))


def test_fixture_corpus_exists():
    assert fixture_paths(), "python/tests/fixtures/ corpus is missing"


@pytest.mark.parametrize("path", fixture_paths(), ids=os.path.basename)
def test_fixture_produces_ok_envelope(path):
    with open(path, "r", encoding="utf-8") as fh:
        request = json.load(fh)
    env = B.Bridge(B.StubClient(), git_sha="testsha",
                   snapshots=False).handle_request(request)
    assert env["ok"] is True, "%s -> %r" % (path, env)
    assert env["schema_version"] == 1
    # fixed-point strings stay strings through json round-trip
    di = request["state"]["self"].get("di_scaling")
    assert di is None or isinstance(di, str)


# ---------------------------------------------------------------------------
# CLI: --fixture mode (SS14.1) and client-construction failure (exit 2)
# ---------------------------------------------------------------------------

def test_fixture_cli_mode_prints_envelope_and_returns_0(tmp_path, capsys):
    fixture = os.path.join(FIXTURES_DIR, "v1_cowboy_vs_ninja_neutral.json")
    rc = B.main(["--stub", "--fixture", fixture,
                 "--data-dir", str(tmp_path), "--no-snapshots"])
    assert rc == 0
    env = json.loads(capsys.readouterr().out)
    assert env["ok"] is True and env["outcome"] == "ranked"
    assert env["response"]["tick"] == 1473


@pytest.mark.skipif(importlib.util.find_spec("anthropic") is not None,
                    reason="anthropic installed; the real client might construct "
                           "via ambient credentials and reach the network")
def test_real_client_unavailable_exits_2(tmp_path, monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("ANTHROPIC_AUTH_TOKEN", raising=False)
    fixture = os.path.join(FIXTURES_DIR, "v1_cowboy_vs_ninja_neutral.json")
    with pytest.raises(SystemExit) as exc:
        B.main(["--fixture", fixture, "--data-dir", str(tmp_path), "--no-snapshots"])
    assert exc.value.code == 2
