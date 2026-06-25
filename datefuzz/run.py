#!/usr/bin/env python3
"""Differential + invariant grinder for os.date / os.time / os.difftime.

Runs each generated case under BOTH golua and reference lua5.5.0, with a FIXED,
IDENTICAL environment injected into both subprocesses, diffs their canonical
position-stripped output line-by-line, and inspects golua's oracle-free
invariant lines. Only divergences are kept (written to corpus/). A clean run
leaves corpus empty.

DETERMINISM (critical): os.date local-time output depends on $TZ and the locale.
We pin LC_ALL=C and replay every case under each TZ in TZS (UTC + a DST zone),
injecting the SAME env into golua and the reference. See README.md.

Usage:
  python3 run.py --tier 0
  python3 run.py --tier 1 --tier 2 --tier illegal
  python3 run.py --tier3 50000 --seed 1
  python3 run.py --all
Env:
  GOLUA   path to golua CLI (default: ./golua, auto-built if missing)
  REFLUA  path to reference 5.5 interpreter (default: lua5.5.0)
  DATEFUZZ_TZS  comma-separated TZ list override (default: UTC,America/New_York)
"""

import argparse
import os
import subprocess
import sys
import tempfile

import grammar
import values as valmod
from emit import build_driver

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")

# This repo (golua-conformance) lives alongside the golua checkout it tests.
WORK = os.path.dirname(os.path.dirname(HERE))
GOLUA_REPO = os.path.abspath(os.environ.get("GOLUA_REPO", os.path.join(WORK, "golua")))

GOLUA = os.environ.get("GOLUA", os.path.join(HERE, "golua"))
REFLUA = os.environ.get("REFLUA", "lua5.5.0")

ULIMIT_KB = 2 * 1024 * 1024   # 2 GiB virtual-memory cap per interpreter
TIMEOUT_S = 30
BATCH = 400                   # cases per driver invocation (localizes crashes)

# TZs replayed against every case. UTC is the no-DST baseline; America/New_York
# exercises spring-forward/fall-back. LC_ALL=C pins %a %b %c %p %x etc.
TZS = os.environ.get("DATEFUZZ_TZS", "UTC,America/New_York").split(",")


def ensure_golua():
    if os.path.exists(GOLUA):
        return
    if not os.path.isdir(GOLUA_REPO):
        sys.exit("golua checkout not found at %s — set GOLUA_REPO or GOLUA env"
                 % GOLUA_REPO)
    print("building golua from %s -> %s" % (GOLUA_REPO, GOLUA), file=sys.stderr)
    subprocess.run(["go", "build", "-o", GOLUA, "./cmd/lua"], cwd=GOLUA_REPO, check=True)


def run_lua(interp, script_path, tz):
    """Run a lua script under ulimit+timeout with a FIXED env. (stdout, stderr, rc)."""
    cmd = "ulimit -v %d 2>/dev/null; exec %s %s" % (
        ULIMIT_KB, _shq(interp), _shq(script_path))
    # Identical, deterministic environment for BOTH interpreters.
    env = dict(os.environ)
    env["TZ"] = tz
    env["LC_ALL"] = "C"
    env["LANG"] = "C"
    try:
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True,
                           timeout=TIMEOUT_S, env=env)
        return p.stdout, p.stderr, p.returncode
    except subprocess.TimeoutExpired:
        return "", "<timeout>", -9


def _shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def diff_outputs(golua_out, ref_out):
    """Return list of (key, golua_line, ref_line) where they differ."""
    def index(text):
        idx = {}
        for line in text.splitlines():
            cols = line.split("\t", 2)
            if len(cols) >= 2:
                idx[(cols[0], cols[1])] = line   # (op, id) -> line
        return idx

    gi, ri = index(golua_out), index(ref_out)
    diffs = []
    for key in sorted(set(gi) | set(ri)):
        g = gi.get(key, "<missing>")
        r = ri.get(key, "<missing>")
        if g != r and not _platform_wontfix(g, r):
            diffs.append((key, g, r))
    return diffs


def _platform_wontfix(g, r):
    """True for documented Go-time-vs-glibc platform won't-fixes (see golua
    wontfix/). Only the REPRESENTATION-PARITY class is auto-allowlisted here: it
    is unambiguous (one side errors "cannot be represented", the other does not).

    The other two datefuzz platform classes are deliberately NOT auto-allowlisted
    because they manifest as ordinary VALUE differences and a blanket value
    pattern would risk masking a real date bug during a sweep:
      - DST-boundary resolution: under a DST zone os.time of an ambiguous/
        nonexistent wall-clock differs by the DST offset (3600s) between Go's
        time and glibc's mktime.
      - INT32 tm_year overflow: at extreme years C's int32 tm_year wraps
        (negative) while golua's 64-bit Go time stays correct — golua is the
        more-correct side.
    Those remain visible as a small, KNOWN residue; recognize them by the 3600s
    delta / wrapped-year sign rather than auto-dropping them. The cleanest empty
    baseline is a UTC-only run (no DST class)."""
    # Representation parity, either direction (os.time{isdst} under a no-DST zone
    # where glibc's mktime applies a -3600 hack and returns a value; and the
    # converse where Go computes a valid time glibc's mktime rejects).
    g_rep = "cannot be represented" in g
    r_rep = "cannot be represented" in r
    if g_rep != r_rep:
        return True
    return False


def invariant_failures(golua_out):
    fails = []
    for line in golua_out.splitlines():
        cols = line.split("\t")
        if cols[0] == "INV" and len(cols) >= 4 and cols[3] != "true":
            fails.append(line)
    return fails


def panic_in(stderr):
    s = stderr or ""
    return ("panic:" in s and "goroutine" in s) or "runtime error" in s


def run_batch(cases, label, batch_no, tz, leads):
    driver = build_driver(cases)
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False, dir="/tmp") as f:
        f.write(driver)
        path = f.name
    try:
        g_out, g_err, g_rc = run_lua(GOLUA, path, tz)
        r_out, r_err, r_rc = run_lua(REFLUA, path, tz)

        if panic_in(g_err):
            leads.append(("PANIC", label, "tz=%s b%d" % (tz, batch_no), g_err.strip()[:2000], path))
            _dump_panic(label, batch_no, tz, g_err, cases, path)

        for line in invariant_failures(g_out):
            leads.append(("INVARIANT", label, "tz=%s" % tz, line, ""))

        for key, g, r in diff_outputs(g_out, r_out):
            if key[0] == "INV":
                continue  # invariant lines are golua-only meaning; handled above
            leads.append(("DIFF", label, "tz=%s %s" % (tz, "\t".join(key)),
                          "golua: " + g, "ref:   " + r))
    finally:
        if not any(l[0] == "PANIC" for l in leads[-4:]):
            os.unlink(path)


def _dump_panic(label, batch_no, tz, err, cases, path):
    p = os.path.join(CORPUS, "panic_%s_%s_b%d.txt" % (label, tz.replace("/", "_"), batch_no))
    with open(p, "w") as f:
        f.write("driver: %s  TZ=%s LC_ALL=C\n\n" % (path, tz))
        f.write(err)
        f.write("\n\n--- cases ---\n")
        for c in cases:
            f.write("%r\n" % c)


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
    line = "seed=%-4d cases=%-10d tzs=%s %s\n" % (seed, ncases, "+".join(TZS), status)
    with open(os.path.join(CORPUS, "report.txt"), "a") as f:
        f.write(line)
    print("  report -> corpus/report.txt: " + line.strip())


def process(cases, label, seed):
    print("%s: %d cases x %d TZ(s)" % (label, len(cases), len(TZS)))
    leads = []
    for tz in TZS:
        for i in range(0, len(cases), BATCH):
            run_batch(cases[i:i + BATCH], label, i // BATCH, tz, leads)
            done = min(i + BATCH, len(cases))
            if done % (BATCH * 10) == 0 or done == len(cases):
                print("  [TZ=%s] ...%d/%d, %d leads" % (tz, done, len(cases), len(leads)))
    return leads, len(cases) * len(TZS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", action="append", default=[],
                    help="0,1,2 or 'illegal'")
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

    tiers = set(str(t) for t in args.tier)
    if args.all:
        tiers |= {"0", "1", "2", "illegal"}

    all_leads = []
    total_cases = 0

    def run(cases, label):
        nonlocal total_cases
        leads, ncases = process(cases, "%s.s%d" % (label, args.seed), args.seed)
        total_cases += ncases
        return leads

    if "0" in tiers:
        all_leads += run(grammar.tier0(), "tier0")
    if "1" in tiers:
        all_leads += run(grammar.tier1(), "tier1")
    if "2" in tiers:
        all_leads += run(grammar.tier2(), "tier2")
    if "illegal" in tiers:
        all_leads += run(grammar.tier_illegal(), "illegal")
    if args.tier3:
        all_leads += run(grammar.tier3(args.seed, args.tier3), "tier3")

    print("\n=== %d total leads ===" % len(all_leads))
    write_corpus(all_leads, args.seed)
    write_report(args.seed, total_cases, all_leads)
    sys.exit(1 if all_leads else 0)


if __name__ == "__main__":
    main()
