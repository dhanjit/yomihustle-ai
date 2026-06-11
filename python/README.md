# Claude ⇄ YOMI Hustle bridge (`python/`)

Localhost TCP bridge between the Godot mod (`src/`) and the Anthropic API.
Wire protocol, failure modes and security model are specified in
`../DESIGN.md` (§3 protocol, §9 failure modes, §10 v0, §15 observability,
§16 security) — DESIGN.md is authoritative.

The bridge **only ever binds 127.0.0.1** (ports 8765–8770). It never exposes
a network port. If you need it on another machine, fork it.

## Run — real Claude

```powershell
cd python
pip install -r requirements.txt
$env:ANTHROPIC_API_KEY = "sk-ant-..."
python bridge.py
```

Then start YOMI Hustle with the mod installed. The mod reads the port and
auth token from the data directory (below) and handshakes automatically.

## Run — offline stub (no API key, no network, no `anthropic` package)

```powershell
python bridge.py --stub
```

The stub returns deterministic decisions derived from each request (first
legal moves / first visible category). Useful for mod development and the
integration smoke (`DESIGN.md` §14.4).

## Flags

| Flag | Default | Meaning |
| --- | --- | --- |
| `--port N` | `8765` | Listen port. Default scans 8765→8770 on `EADDRINUSE` (§12.5). An explicit `--port` disables scanning. |
| `--stub` | off | Deterministic offline client. `anthropic` is never imported. |
| `--model` | `claude-opus-4-8` | Model for `v1` / `v2_round1` / `v2_round2`. |
| `--model-v0` | `claude-sonnet-4-6` | Model for the cheap `v0` category mode (§10). |
| `--prompts-dir` | `./prompts` | `system_v0.txt`, `system_v1.txt`, `characters/<name>.json`. |
| `--data-dir` | `%LOCALAPPDATA%\claude_yomih` (Windows) / `~/.local/share/claude_yomih` | Where `token`, `port`, `bridge.pid`, `logs/` are written. |
| `--idle-exit S` | `900` | Watchdog: clean exit after S seconds with **no open connection and no traffic**. An open connection (even an AFK match) always suppresses it — once the bridge exits, nothing restarts it and the mod's §9.3 re-probe fails forever, so it only fires in the zero-connections state. `0` disables. |
| `--claude-timeout S` | `6.0` | Per-call Claude budget (§9.1). Overrun → `claude_timeout` envelope. SDK retries are disabled (`max_retries=0`). Values ≥ 8 log a warning: the mod abandons reads after 8s. |
| `--no-snapshots` | off | Disable JSONL decision snapshots. |
| `--fixture FILE` | — | Run one recorded request through the full codepath without sockets, print the envelope, exit (§14.1). |

## Files written to the data dir

- `token` — 64-hex auth token (`secrets.token_hex(32)`), regenerated per run. The mod reads this file and echoes it in `hello_auth` (§16.1); the bridge **never sends the token over the wire** (`hello_ack` does not echo it — any local process can connect, so an echoed token would defeat the auth). `chmod 600` on POSIX, `icacls` restriction on Windows (best-effort).
- `port` — the actually-bound port as a single ASCII integer (§12.5). Removed on clean exit.
- `bridge.pid` — bridge process id (§16.2). Removed on clean exit.
- `logs/decisions.jsonl` — one JSON line per decision: full request, full envelope, dropped candidates with reasons, latency (`total_ms` + `claude_ms`), model/bridge versions, git sha, token usage. This is the **bridge-side decision log, supplementary to the mod-side §15.1 snapshots** (which remain the authoritative per-turn record). Rotated to `decisions.jsonl.1` past 50 MB (one prior generation kept); delete freely.

## Character prompts

`prompts/characters/<character_name lowercased>.json` (e.g. `cowboy.json`,
`ninja.json`) is embedded into a cached system block when present. A missing
file logs one warning and the bridge proceeds with the generic prompt — frame
data is produced by a separate workstream and is never required.

## Tests

```powershell
cd ..   # repo root
python -m pytest python/tests/ -q
```

The suite is stdlib-only: it must pass without the `anthropic` package and
without internet access (it uses real 127.0.0.1 sockets).

## Replay determinism note

Game-side replays are byte-stable (they record chosen actions only). Claude's
*reasoning* is best-effort reproducible at most: current Opus models do not
accept sampling parameters, and Anthropic does not guarantee bit-stable
sampling, so re-running a recorded request may explain itself differently
(DESIGN.md §13.7).
