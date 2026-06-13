# yomihustle-ai

Claude plays [*Your Only Move Is HUSTLE*](https://store.steampowered.com/app/2212330/) — a simultaneous-turn fighting game where both players pick a move on every actionable frame and a deterministic simulation plays it out.

A Godot 3.5 mod hooks the game's `player_actionable` signal, ships the full game state plus the legal-move set (with pre-enumerated data permutations) to a local Python bridge, and Claude returns a ranked shortlist. The game's own ghost-simulation engine then verifies the candidates 35 frames deep before the move is submitted. If the bridge is down or Claude misbehaves, the reference heuristic AI takes over seamlessly.

## Layout

| Path | What |
|---|---|
| [SETUP.md](SETUP.md) | End-to-end Windows runbook — start here |
| [DESIGN.md](DESIGN.md) | The authoritative spec: protocol, threading, fallbacks, testing |
| [VALIDATION.md](VALIDATION.md) | Source-audited facts about the game's internals |
| [RESEARCH.md](RESEARCH.md) | Original research pass (superseded where VALIDATION corrects it) |
| `src/` | The mod (GDScript, zipped into `<game>/mods/` by `tools/build.ps1`) |
| `python/` | The TCP bridge + prompts + frame-data corpus for all 5 characters |
| `tools/` | Build/install scripts and a keyless stub bridge |

## Quickstart

```powershell
# 1. Bridge (stub mode needs no API key)
python python\bridge.py --stub

# 2. Build + install the mod (default Steam path)
tools\build.ps1

# 3. Launch YOMIH, enable "Claude AI Controller" in the mod menu, restart, start a singleplayer match
```

Real model: set `OPENROUTER_API_KEY` (model-agnostic via OpenRouter — `YOMI_MODEL` is any slug) and drop `--stub`. Full walkthrough in [SETUP.md](SETUP.md).

## Status

Code-complete and audited (95 offline tests green; ten audit-critical correctness fixes verified present). Not yet validated in a live game — that requires a Steam install + GodotSteam 3.5.1 editor session, tracked in DESIGN.md §13.
