#!/usr/bin/env python3
"""Differential grinder for type-coercion & operator semantics.

Runs each generated case (an operator/context applied to operand(s)) under BOTH
golua and reference lua5.5.0, diffs canonical output line-by-line, and watches
for Go panics escaping golua (sandbox-class oracle-free invariant). Only
divergences are kept (written to corpus/). A clean run leaves corpus empty.

Usage:
  python3 run.py --tier 0
  python3 run.py --tier 1 --tier 2 --ordering
  python3 run.py --tier3 100000 --seed 1
  python3 run.py --all
Env:
  GOLUA   path to golua CLI (default: ./golua, auto-built if missing)
  REFLUA  path to reference 5.5 interpreter (default: lua5.5.0)
"""

import argparse
import os
import subprocess
import sys
import tempfile

import grammar
from emit import build_driver

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")

WORK = os.path.dirname(os.path.dirname(HERE))
GOLUA_REPO = os.path.abspath(os.environ.get("GOLUA_REPO", os.path.join(WORK, "golua")))

GOLUA = os.environ.get("GOLUA", os.path.join(HERE, "golua"))
REFLUA = os.environ.get("REFLUA", "lua5.5.0")

ULIMIT_KB = 2 * 1024 * 1024   # 2 GiB virtual-memory cap per interpreter
TIMEOUT_S = 30
BATCH = 1500                  # cases per driver invocation (localizes crashes)


def ensure_golua():
    if os.path.exists(GOLUA):
        return
    if not os.path.isdir(GOLUA_REPO):
        sys.exit("golua checkout not found at %s — set GOLUA_REPO or GOLUA env"
                 % GOLUA_REPO)
    print("building golua from %s -> %s" % (GOLUA_REPO, GOLUA), file=sys.stderr)
    subprocess.run(["go", "build", "-o", GOLUA, "./cmd/lua"], cwd=GOLUA_REPO, check=True)


def run_lua(interp, script_path):
    """Run a lua script under ulimit+timeout. Returns (stdout, stderr, rc)."""
    cmd = "ulimit -v %d 2>/dev/null; exec %s %s" % (
        ULIMIT_KB, _shq(interp), _shq(script_path))
    try:
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True,
                           timeout=TIMEOUT_S)
        return p.stdout, p.stderr, p.returncode
    except subprocess.TimeoutExpired:
        return "", "<timeout>", -9


def _shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def diff_outputs(golua_out, ref_out):
    """Return list of (key, golua_line, ref_line) where they differ.

    key = (kind, id) from the first two tab-separated columns.
    """
    def index(text):
        idx = {}
        for line in text.splitlines():
            cols = line.split("\t", 2)
            if len(cols) >= 2:
                idx[(cols[0], cols[1])] = line
        return idx

    gi, ri = index(golua_out), index(ref_out)
    diffs = []
    for key in sorted(set(gi) | set(ri)):
        g = gi.get(key, "<missing>")
        r = ri.get(key, "<missing>")
        if g != r:
            diffs.append((key, g, r))
    return diffs


def panic_in(stderr):
    s = stderr or ""
    return ("panic:" in s and "goroutine" in s)


def case_repr(case):
    kind = case["kind"]
    if kind == "binop":
        return "%s: (%s) %s (%s)" % (case["id"], case["a"].expr, case["op"], case["b"].expr)
    if kind == "unop":
        return "%s: %s (%s)" % (case["id"], case["op"], case["a"].expr)
    if kind in ("index_get", "index_set"):
        return "%s: %s t[%s]" % (case["id"], kind, case["a"].expr)
    if kind == "key_norm":
        return "%s: t[%s]=7; t[%s]" % (case["id"], case["ka"], case["kb"])
    if kind == "fornum":
        return "%s: for i=%s,%s,%s" % (case["id"], case["a"].expr, case["b"].expr, case["c"].expr)
    if kind == "lib":
        return "%s: %s {X=%s}" % (case["id"], case["call_name"],
                                  case["a"].expr if "a" in case else "?")
    return "%s: %r" % (case["id"], case)


def run_batch(cases, label, batch_no, leads):
    driver = build_driver(cases)
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False, dir="/tmp") as f:
        f.write(driver)
        path = f.name
    keep_driver = False
    try:
        g_out, g_err, g_rc = run_lua(GOLUA, path)
        r_out, r_err, r_rc = run_lua(REFLUA, path)

        if panic_in(g_err):
            leads.append(("PANIC", label, batch_no, g_err.strip()[:2000], path))
            _dump_panic(label, batch_no, g_err, cases, path)
            keep_driver = True

        by_id = {c["id"]: c for c in cases}
        for key, g, r in diff_outputs(g_out, r_out):
            cid = key[1]
            crepr = case_repr(by_id[cid]) if cid in by_id else cid
            leads.append(("DIFF", label, crepr, "golua: " + g, "ref:   " + r))
    finally:
        if not keep_driver:
            os.unlink(path)


def _dump_panic(label, batch_no, err, cases, path):
    p = os.path.join(CORPUS, "panic_%s_b%d.txt" % (label, batch_no))
    with open(p, "w") as f:
        f.write("driver: %s\n\n" % path)
        f.write(err)
        f.write("\n\n--- cases ---\n")
        for c in cases:
            f.write(case_repr(c) + "\n")


def write_corpus(leads, seed):
    os.makedirs(CORPUS, exist_ok=True)
    if not leads:
        return
    by_kind = {}
    for lead in leads:
        by_kind.setdefault(lead[0], []).append(lead)
    for kind, items in by_kind.items():
        p = os.path.join(CORPUS, "%s_seed%d.txt" % (kind.lower(), seed))
        with open(p, "w") as f:
            for it in items:
                f.write(" | ".join(str(x) for x in it[1:]) + "\n")
        print("  wrote %d %s leads -> %s" % (len(items), kind, p))


def write_report(seed, ncases, leads):
    os.makedirs(CORPUS, exist_ok=True)
    status = "CLEAN" if not leads else "LEADS(%d)" % len(leads)
    line = "seed=%-4d cases=%-10d %s\n" % (seed, ncases, status)
    with open(os.path.join(CORPUS, "report.txt"), "a") as f:
        f.write(line)
    print("  report -> corpus/report.txt: " + line.strip())


def process(cases, label):
    print("%s: %d cases" % (label, len(cases)))
    leads = []
    for i in range(0, len(cases), BATCH):
        run_batch(cases[i:i + BATCH], label, i // BATCH, leads)
        done = min(i + BATCH, len(cases))
        if done % (BATCH * 10) == 0 or done == len(cases):
            print("  ...%d/%d cases, %d leads so far" % (done, len(cases), len(leads)))
    return leads, len(cases)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", action="append", type=int, default=[])
    ap.add_argument("--ordering", action="store_true", help="run the ordering tier")
    ap.add_argument("--tier3", type=int, default=0, help="number of random cases")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--lua54", action="store_true",
                    help="diff the lua_5_4_8 branch against lua5.4.8 (5.4.8 oracle)")
    args = ap.parse_args()

    if args.lua54:
        sys.path.insert(0, os.path.dirname(HERE))
        import lua54
        global GOLUA, REFLUA
        GOLUA = lua54.ensure_golua54(GOLUA_REPO)
        REFLUA = os.environ.get("REFLUA", "lua5.4.8")
    else:
        ensure_golua()
    os.makedirs(CORPUS, exist_ok=True)

    tiers = set(args.tier)
    run_ordering = args.ordering
    if args.all:
        tiers |= {0, 1, 2}
        run_ordering = True

    all_leads = []
    total_cases = 0

    def run(cases, label):
        nonlocal total_cases
        leads, ncases = process(cases, "%s.s%d" % (label, args.seed))
        total_cases += ncases
        return leads

    if 0 in tiers:
        all_leads += run(grammar.tier0(), "tier0")
    if 1 in tiers:
        all_leads += run(grammar.tier1(), "tier1")
    if 2 in tiers:
        all_leads += run(grammar.tier2(), "tier2")
    if run_ordering:
        all_leads += run(grammar.ordering(), "ordering")
    if args.tier3:
        all_leads += run(grammar.tier3(args.seed, args.tier3), "tier3")

    print("\n=== %d total leads ===" % len(all_leads))
    write_corpus(all_leads, args.seed)
    write_report(args.seed, total_cases, all_leads)
    sys.exit(1 if all_leads else 0)


if __name__ == "__main__":
    main()
