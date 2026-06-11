"""Crude GDScript 3 lint for the claude_yomih mod sources.

Checks (heuristic, not a parser):
  * balanced () [] {} after stripping strings/comments
  * block-opening lines (func/if/elif/else/for/while/match) end with ':'
    accounting for backslash continuations
  * no mixed tab/space indentation
  * no Godot 4-isms
"""
import re
import sys
import os

FILES = [
    "ModMain.gd",
    "ClaudeLoader.gd",
    "ClaudeController.gd",
    "ModOptions.gd",
    "ProtocolEncoder.gd",
    "ProtocolDecoder.gd",
    "HeuristicShim.gd",
    "LegalMoveEnumerator.gd",
]

STRING_RE = re.compile(r'"(?:[^"\\]|\\.)*"')
BLOCK_RE = re.compile(r'^(static\s+func|func|if|elif|else|for|while|match)\b')
GD4 = ["await ", "Callable(", "@export", "@onready", "PackedByteArray", ".emit("]

ok = True
src_dir = sys.argv[1] if len(sys.argv) > 1 else "."
for fn in FILES:
    path = os.path.join(src_dir, fn)
    raw = open(path, encoding="utf-8").read()
    stripped_lines = []
    for line in raw.split("\n"):
        line = STRING_RE.sub('""', line)
        hash_idx = line.find("#")
        if hash_idx != -1:
            line = line[:hash_idx]
        stripped_lines.append(line)
    body = "\n".join(stripped_lines)
    for op, cl in [("(", ")"), ("[", "]"), ("{", "}")]:
        if body.count(op) != body.count(cl):
            print("%s: UNBALANCED %s%s: %d vs %d" % (fn, op, cl, body.count(op), body.count(cl)))
            ok = False
    # join continuation lines for the block check
    logical = []
    buf = ""
    for line in stripped_lines:
        s = line.rstrip()
        if s.endswith("\\"):
            buf += s[:-1] + " "
            continue
        logical.append((buf + s))
        buf = ""
    for i, line in enumerate(logical, 1):
        s = line.strip()
        if not s:
            continue
        m = BLOCK_RE.match(s)
        if m and m.group(1) in ("static func", "func", "for", "while", "elif", "match"):
            if not s.endswith(":"):
                print("%s:%d: block line missing colon: %s" % (fn, i, s[:90]))
                ok = False
    for i, line in enumerate(raw.split("\n"), 1):
        indent = line[: len(line) - len(line.lstrip())]
        if " " in indent and "\t" in indent:
            print("%s:%d: mixed tab/space indent" % (fn, i))
            ok = False
        if indent.startswith(" ") and line.strip():
            print("%s:%d: space indent" % (fn, i))
            ok = False
    for g in GD4:
        if g in raw:
            print("%s: Godot4-ism found: %s" % (fn, g))
            ok = False

print("ALL OK" if ok else "ISSUES FOUND")
sys.exit(0 if ok else 1)
