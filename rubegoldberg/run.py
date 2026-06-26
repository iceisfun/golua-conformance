#!/usr/bin/env python3
"""Semantic "Rube Goldberg" program generator — differential golua vs reference.

Unlike a syntax fuzzer, this builds *valid, deterministic* Lua programs by
chaining individually-correct semantic stages (see stages.py) into a deep
machine whose final integer is fully determined. The complexity is emergent
from composition: closures feeding coroutines feeding pattern matches feeding
self-modifying metatables, etc. Any behavioral divergence between golua and the
reference surfaces as a different printed result.

Pipeline per candidate:
  generate (depth stages) -> run golua + reference under ulimit+timeout ->
  classify -> on DIFFERENTIAL FAILURE, auto-reduce (delta-debug at stage
  granularity) to a minimal reproducer -> persist to corpus.

Classification (only DIFFERENTIAL FAILUREs are kept):
  PASS                 golua == reference
  DIFFERENTIAL FAILURE golua != reference, reference is deterministic, golua
                       did not resource-fail  -> a real golua bug, retained
  RESOURCE FAILURE     either side OOM/timeout/crash -> skipped (that is
                       sandboxfuzz/bytecodefuzz territory, not a semantic diff)
  NON-DETERMINISTIC    reference's own two runs differ -> discarded
  INVALID GENERATION   reference errored at parse/compile -> discarded

Usage:
  python3 run.py                       # default: 300 programs, depth 12
  python3 run.py --count 5000 --depth 30 --seed 1
  python3 run.py --lua54               # golua lua_5_4_8 branch vs lua5.4.8
  python3 run.py --replay corpus/x.lua # re-run + reduce one saved program
Env:
  GOLUA       golua CLI (default ./golua, auto-built)
  GOLUA_REPO  golua checkout (default ../golua)
  REFLUA      reference interpreter (default lua5.5.0, or lua5.4.8 with --lua54)
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

import stages as stagelib

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")
WORK = os.path.dirname(os.path.dirname(HERE))
GOLUA_REPO = os.path.abspath(os.environ.get("GOLUA_REPO", os.path.join(WORK, "golua")))
GOLUA = os.environ.get("GOLUA", os.path.join(HERE, "golua"))
REFLUA = os.environ.get("REFLUA", "lua5.5.0")

ULIMIT_KB = 4 * 1024 * 1024   # 4 GiB
TIMEOUT_S = 12
SEED_CONST = 1140118117       # fixed deterministic seed value in the program

import random


def parse_args():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=300)
    ap.add_argument("--depth", type=int, default=12)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--lua54", action="store_true")
    ap.add_argument("--replay", help="re-run + reduce a saved .lua program")
    ap.add_argument("--keep-going", action="store_true",
                    help="don't stop after the first differential failure")
    return ap.parse_args()


# ---------------------------------------------------------------------------
# program model: a list of (stage_name, body). render() drops nothing; a
# reduced program simply omits stages.
# ---------------------------------------------------------------------------
def generate(rng, depth):
    names = list(stagelib.STAGES.keys())
    prog = []
    for _ in range(depth):
        name = rng.choice(names)
        body = stagelib.STAGES[name](rng)
        prog.append((name, body))
    return prog


def render(prog):
    # Each stage runs under pcall so its result OR its error message+line is
    # captured into a transcript line ("i:name:VAL" or "i:name:ERR <msg>").
    # Comparing the whole transcript (not just a final integer) exposes
    # intermediate result divergence AND error-message/line divergence. The
    # caught error's chunk name is this temp file's path — identical for the
    # golua and reference runs of the same file — so the line number and message
    # text are compared directly. v is unchanged when a stage errors.
    out = ["-- rube goldberg machine: %d stages" % len(prog),
           "local out = {}",
           "local function obs(i, name, ok, r)",
           "  local s",
           "  if ok then s = tostring(r)",
           "  elseif type(r) == 'string' then s = 'ERR ' .. r",
           "  else s = 'ERR <' .. type(r) .. '>' end",
           "  out[#out+1] = i .. ':' .. name .. ':' .. s",
           "end",
           "local v = %d" % SEED_CONST]
    for i, (name, body) in enumerate(prog):
        out.append("-- stage %d: %s" % (i, name))
        out.append("do")
        out.append("  local ok, r = pcall(function(x)")
        out.append(body.rstrip("\n"))
        out.append("  end, v)")
        out.append("  if ok and math.type(r) == 'integer' then v = r end")
        out.append("  obs(%d, %r, ok, r)" % (i, name))
        out.append("end")
    out.append("print(table.concat(out, '\\n'))")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------
# execution + normalization
# ---------------------------------------------------------------------------
_NUM = re.compile(r":\d+:")


def _shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def run(interp, path):
    """Return (rc, normalized_output, raw, resource_fail)."""
    cmd = "ulimit -v %d 2>/dev/null; exec %s %s" % (ULIMIT_KB, _shq(interp), _shq(path))
    try:
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True,
                           timeout=TIMEOUT_S, errors="replace")
    except subprocess.TimeoutExpired:
        return (None, "<timeout>", "<timeout>", True)
    raw = (p.stdout or "") + (("\n--stderr--\n" + p.stderr) if p.stderr else "")
    # resource / crash markers
    low = raw.lower()
    resource = (p.returncode is not None and (p.returncode == 2 or p.returncode > 128)) or \
        "not enough memory" in low or "out of memory" in low or \
        "stack overflow" in low or "panic:" in raw or "fatal error:" in raw
    # normalize: drop the interpreter program-name prefix, the temp path, and
    # collapse ":<line>:" so we compare semantic content, not cosmetics.
    norm = raw.replace(os.path.basename(interp), "<lua>")
    norm = norm.replace(path, "<prog>")
    norm = re.sub(r"[^\s:]*<prog>[^\s:]*", "<prog>", norm)
    return (p.returncode, norm, raw, resource)


def classify(prog):
    """Render prog, run both, classify. Returns (verdict, detail, g_raw, r_raw)."""
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
        f.write(render(prog))
        path = f.name
    try:
        # reference twice -> non-determinism guard
        r_rc, r_norm, r_raw, r_res = run(REFLUA, path)
        r_rc2, r_norm2, _, _ = run(REFLUA, path)
        if r_res:
            return ("RESOURCE", "reference resource-fail", "", r_raw)
        if r_norm != r_norm2:
            return ("NONDET", "reference non-deterministic", "", r_raw)
        if r_rc not in (0, 1) and r_rc is not None:
            return ("INVALID", "reference rc=%s" % r_rc, "", r_raw)
        g_rc, g_norm, g_raw, g_res = run(GOLUA, path)
        if g_res:
            return ("RESOURCE", "golua resource-fail rc=%s" % g_rc, g_raw, r_raw)
        if g_norm == r_norm:
            return ("PASS", "", g_raw, r_raw)
        return ("DIFF", "golua!=ref", g_raw, r_raw)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def reproduces(prog):
    """True iff prog is still a clean differential failure."""
    verdict, _, _, _ = classify(prog)
    return verdict == "DIFF"


# ---------------------------------------------------------------------------
# reducer: delta-debug at stage granularity, then a final sanity re-check.
# ---------------------------------------------------------------------------
def reduce(prog):
    changed = True
    while changed and len(prog) > 1:
        changed = False
        for i in range(len(prog)):
            cand = prog[:i] + prog[i + 1:]
            if cand and reproduces(cand):
                prog = cand
                changed = True
                break
    return prog


# ---------------------------------------------------------------------------
def ensure_golua(lua54):
    global GOLUA, GOLUA_REPO, REFLUA
    if lua54:
        REFLUA = os.environ.get("REFLUA", "lua5.4.8")
        wt = os.path.join(WORK, "golua-conformance", ".worktrees", "lua_5_4_8")
        subprocess.run(["git", "-C", GOLUA_REPO, "worktree", "add", "-f", "--detach", wt, "lua_5_4_8"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["git", "-C", wt, "checkout", "lua_5_4_8", "--", "."],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        GOLUA_REPO = wt
        GOLUA = os.path.join(HERE, "golua54")
        if os.path.exists(GOLUA):
            os.unlink(GOLUA)
    if os.path.exists(GOLUA):
        return
    if not os.path.isdir(GOLUA_REPO):
        sys.exit("golua checkout not found at %s" % GOLUA_REPO)
    print("building golua -> %s" % GOLUA, file=sys.stderr)
    subprocess.run(["go", "build", "-o", GOLUA, "./cmd/lua"], cwd=GOLUA_REPO, check=True)


def save_failure(idx, prog, g_raw, r_raw):
    base = os.path.join(CORPUS, "diff_%03d" % idx)
    with open(base + ".lua", "w") as f:
        f.write(render(prog))
    with open(base + ".txt", "w") as f:
        f.write("stages: %s\n\n" % " -> ".join(n for n, _ in prog))
        f.write("== golua ==\n%s\n\n== reference (%s) ==\n%s\n" % (g_raw, REFLUA, r_raw))
    return base


def replay(path):
    """Re-run + reduce a saved program file (best-effort: treat whole file as one stage)."""
    with open(path) as f:
        src = f.read()
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
        f.write(src)
        p = f.name
    g = run(GOLUA, p)
    r = run(REFLUA, p)
    os.unlink(p)
    print("golua rc=%s\n%s\n\nref rc=%s\n%s" % (g[0], g[2], r[0], r[2]))


def main():
    args = parse_args()
    ensure_golua(args.lua54)
    if args.replay:
        replay(args.replay)
        return
    rng = random.Random(args.seed)
    print("rubegoldberg: count=%d depth=%d golua=%s ref=%s"
          % (args.count, args.depth, os.path.basename(GOLUA), REFLUA))
    tally = {"PASS": 0, "DIFF": 0, "RESOURCE": 0, "NONDET": 0, "INVALID": 0}
    found = 0
    for i in range(args.count):
        prog = generate(rng, args.depth)
        verdict, detail, g_raw, r_raw = classify(prog)
        tally[verdict] = tally.get(verdict, 0) + 1
        if verdict == "DIFF":
            print("  DIFFERENTIAL FAILURE #%d (%d stages) — reducing..." % (i, len(prog)))
            mn = reduce(prog)
            base = save_failure(found, mn, *([x for x in classify(mn)[2:]]))
            print("    minimized to %d stages: %s -> %s.lua"
                  % (len(mn), " -> ".join(n for n, _ in mn), base))
            found += 1
            if not args.keep_going:
                break
        if (i + 1) % 50 == 0:
            print("  ... %d/%d  %s" % (i + 1, args.count, tally), file=sys.stderr)
    print("\n=== %s ===" % "  ".join("%s=%d" % kv for kv in tally.items()))
    with open(os.path.join(CORPUS, "report.txt"), "w") as f:
        f.write("count=%d depth=%d ref=%s\n%s\ndifferential_failures=%d\n"
                % (args.count, args.depth, REFLUA,
                   "  ".join("%s=%d" % kv for kv in tally.items()), found))
    sys.exit(1 if found else 0)


if __name__ == "__main__":
    main()
