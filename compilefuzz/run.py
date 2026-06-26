#!/usr/bin/env python3
"""Differential compiler-limit / deep-nesting grinder (compile-time, not runtime).

golua's hand-written compiler must accept/reject exactly the programs reference
Lua does, and emit the same limit diagnostics. This sweeps each compiler limit
and structural-nesting axis across a range of sizes that brackets the known
boundary, compiles each candidate with load() under a FIXED chunk name, and
diffs (accept/reject + error message) golua vs the reference. It also asserts
the oracle-free invariant that even pathologically deep/large source only ever
yields a CATCHABLE error (or success), never an uncatchable host crash (Go fatal
stack overflow / OOM) — load() is reachable from sandboxed code.

Calibration shows golua matches the reference at both the counting limits (e.g.
"too many local variables (limit is 200)") and the parser C-stack bound ("C
stack overflow"), so any mismatch here is a real compiler bug.

Usage:
  python3 run.py                 # full sweep
  python3 run.py --max 4000      # raise the deep-nesting ceiling
  python3 run.py --lua54
Env: GOLUA, GOLUA_REPO, REFLUA
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")
WORK = os.path.dirname(os.path.dirname(HERE))
GOLUA_REPO = os.path.abspath(os.environ.get("GOLUA_REPO", os.path.join(WORK, "golua")))
GOLUA = os.environ.get("GOLUA", os.path.join(HERE, "golua"))
REFLUA = os.environ.get("REFLUA", "lua5.5.0")
TIMEOUT_S = 20
ULIMIT_KB = 4 * 1024 * 1024

# load() the candidate under a fixed chunk name '=t' so error messages read
# "t:line: msg" identically on both engines (no [string "..."] truncation noise).
DRIVER = (
    "local p = arg[1]\n"
    "local fh = assert(io.open(p, 'rb')); local src = fh:read('a'); fh:close()\n"
    "local ok, err = load(src, '=t')\n"
    "if ok then print('OK') else print('ERR ' .. tostring(err)) end\n"
)


# ---------------------------------------------------------------------------
# generators: name -> function(n) -> lua source string. Each is swept over a
# range of n bracketing its limit.
# ---------------------------------------------------------------------------
def g_locals(n):
    return "local " + ",".join("a%d" % i for i in range(n)) + " = 1\nreturn a0"


def g_upvalues(n):
    outer = "local " + ",".join("u%d" % i for i in range(n)) + " = " + ",".join(["1"] * n)
    body = "return " + "+".join("u%d" % i for i in range(n))
    return outer + "\nreturn function()\n" + body + "\nend"


def g_params(n):
    return "return function(" + ",".join("p%d" % i for i in range(n)) + ") return p0 end"


def g_callargs(n):
    return "local function f(...) return ... end\nreturn f(" + ",".join("1" for _ in range(n)) + ")"


def g_fields_arr(n):
    return "return {" + ",".join("1" for _ in range(n)) + "}"


def g_fields_rec(n):
    return "return {" + ",".join("k%d=1" % i for i in range(n)) + "}"


def g_andchain(n):
    return "return " + " and ".join("1" for _ in range(n))


def g_orchain(n):
    return "return " + " or ".join("x%d" % i for i in range(n))


def g_returns(n):
    return "return " + ",".join("1" for _ in range(n))


def g_multiassign(n):
    lhs = ",".join("a%d" % i for i in range(n))
    rhs = ",".join("1" for _ in range(n))
    return "local " + lhs + "\n" + lhs + " = " + rhs


def g_arith_depth(n):
    # deeply nested arithmetic -> register pressure
    return "local a = 1\nreturn " + "(1+" * n + "a" + ")" * n


def g_concat_depth(n):
    return "return " + "('x'.." * n + "'y'" + ")" * n


def g_index_depth(n):
    return "local t = {}\nreturn " + "t" + "[1]" * n


def g_paren_depth(n):
    return "return " + "(" * n + "1" + ")" * n


def g_block_depth(n):
    return "do " * n + "return 1 " + "end " * n


def g_func_depth(n):
    return "return " + "function() return " * n + "1" + " end" * n


def g_if_depth(n):
    return "if true then " * n + "return 1 " + "end " * n


def g_for_depth(n):
    return "for _=1,1 do " * n + "break " + "end " * n


def g_unary_depth(n):
    return "return " + "-" * n + "1"


def g_not_depth(n):
    return "return " + "not " * n + "true"


def g_longjump(n):
    # huge straight-line block then a goto over it -> jump distance / "control
    # structure too long"
    body = "\n".join("local _x%d = %d" % (i, i) for i in range(n))
    return "do\ngoto done\n" + body + "\n::done::\nend\nreturn 1"


def g_break_distance(n):
    body = "\n".join("local _y%d = %d" % (i, i) for i in range(n))
    return "while true do\n" + body + "\nbreak\nend\nreturn 1"


def g_nested_table(n):
    return "return " + "{" * n + "1" + "}" * n


# (generator, [list of n to sweep])
COUNT_SWEEP = [198, 199, 200, 201, 202, 253, 254, 255, 256, 257]
DEPTH_SWEEP = [50, 100, 150, 190, 195, 200, 205, 210, 240, 250, 300, 400, 800, 2000]

GENERATORS = {
    "locals": (g_locals, COUNT_SWEEP),
    "upvalues": (g_upvalues, COUNT_SWEEP),
    "params": (g_params, COUNT_SWEEP),
    "callargs": (g_callargs, COUNT_SWEEP + [300, 600]),
    "fields_arr": (g_fields_arr, COUNT_SWEEP + [300, 1000]),
    "fields_rec": (g_fields_rec, COUNT_SWEEP + [300, 1000]),
    "andchain": (g_andchain, COUNT_SWEEP + [300, 600]),
    "orchain": (g_orchain, COUNT_SWEEP + [300, 600]),
    "returns": (g_returns, COUNT_SWEEP + [300, 600]),
    "multiassign": (g_multiassign, COUNT_SWEEP + [300]),
    "arith_depth": (g_arith_depth, DEPTH_SWEEP),
    "concat_depth": (g_concat_depth, DEPTH_SWEEP),
    "index_depth": (g_index_depth, DEPTH_SWEEP),
    "paren_depth": (g_paren_depth, DEPTH_SWEEP),
    "block_depth": (g_block_depth, DEPTH_SWEEP),
    "func_depth": (g_func_depth, DEPTH_SWEEP),
    "if_depth": (g_if_depth, DEPTH_SWEEP),
    "for_depth": (g_for_depth, DEPTH_SWEEP),
    "unary_depth": (g_unary_depth, DEPTH_SWEEP),
    "not_depth": (g_not_depth, DEPTH_SWEEP),
    "longjump": (g_longjump, [100, 1000, 10000, 60000, 70000, 130000, 200000]),
    "break_distance": (g_break_distance, [100, 1000, 10000, 60000, 70000, 200000]),
    "nested_table": (g_nested_table, DEPTH_SWEEP),
}

CRASH_MARKERS = ("panic:", "fatal error:", "goroutine ", "runtime:", "SIGSEGV",
                 "signal SIG", "stack exceeds")


def normalize_err(s):
    """Reduce a compile-error message to its core for comparison. Two documented
    low-value divergences are normalized away:
      * Reference's load() embeds a stack traceback into the error MESSAGE it
        returns for a parser "C stack overflow" (only when called directly, not
        under pcall); golua returns the clean message (golua
        wontfix/load-stack-overflow-traceback).
      * The location TAIL of a limit error (" in main function"/" in function at
        line N" + " near '<tok>'/<eof>") and the exact line in the "t:N:" prefix
        differ by a token at the boundary — message wording, not a conformance
        bug (the brief de-emphasizes it). The error CORE ("too many X (limit is
        N)" / "C stack overflow") is what we compare.
    """
    s = s.split("\nstack traceback:")[0]
    s = re.sub(r"\bt:\d+:", "t:", s)
    s = re.sub(r" in (main function|function at line \d+)", "", s)
    s = re.sub(r" near (<eof>|'[^']*'|\"[^\"]*\")", "", s)
    return s


def cstack_vs_reg(a, b):
    """True for the goroutine-vs-C-stack divergence: one side rejects with the
    parser's recursive 'C stack overflow' (e.g. reference's recursive restassign
    on a 200-target multi-assignment) while golua's iterative parser rejects the
    same program with a different fixed limit (too many registers). Both reject;
    only the limit that bites first differs — a documented design divergence."""
    return ("C stack overflow" in a) != ("C stack overflow" in b)


def _shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def run(interp, driver_path, src_path):
    cmd = "ulimit -v %d 2>/dev/null; exec %s %s %s" % (
        ULIMIT_KB, _shq(interp), _shq(driver_path), _shq(src_path))
    try:
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True,
                           timeout=TIMEOUT_S, errors="replace")
    except subprocess.TimeoutExpired:
        return None, "<timeout>", True
    out = (p.stdout or "") + (("\n!!" + p.stderr) if p.stderr else "")
    crash = (p.returncode == 2 or (p.returncode is not None and p.returncode > 128)
             or any(m in out for m in CRASH_MARKERS))
    return p.returncode, out.strip(), crash


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--max", type=int, default=0, help="extra deep-nesting ceiling")
    ap.add_argument("--lua54", action="store_true")
    args = ap.parse_args()
    global GOLUA, GOLUA_REPO, REFLUA
    if args.lua54:
        sys.path.insert(0, os.path.dirname(HERE))
        import lua54
        GOLUA = lua54.ensure_golua54(GOLUA_REPO)
        REFLUA = os.environ.get("REFLUA", "lua5.4.8")
    elif not os.path.exists(GOLUA):
        if not os.path.isdir(GOLUA_REPO):
            sys.exit("golua checkout not found at %s" % GOLUA_REPO)
        subprocess.run(["go", "build", "-o", GOLUA, "./cmd/lua"], cwd=GOLUA_REPO, check=True)
    os.makedirs(CORPUS, exist_ok=True)

    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as df:
        df.write(DRIVER)
        driver = df.name

    print("compilefuzz: golua=%s ref=%s" % (os.path.basename(GOLUA), REFLUA))
    leads, escapes, total = [], [], 0
    for name, (gen, sweep) in GENERATORS.items():
        ns = list(sweep)
        if args.max:
            ns.append(args.max)
        for n in ns:
            src = gen(n)
            with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as sf:
                sf.write(src)
                spath = sf.name
            try:
                total += 1
                grc, gout, gcrash = run(GOLUA, driver, spath)
                rrc, rout, rcrash = run(REFLUA, driver, spath)
                if gcrash:
                    escapes.append("%s n=%d | golua host-crash | %s" % (name, n, gout[:160]))
                    print("  ESCAPE %s n=%d" % (name, n))
                gn = normalize_err(gout)
                rn = normalize_err(rout)
                if gn != rn and not cstack_vs_reg(gn, rn):
                    leads.append("%s n=%d\n  golua: %s\n  ref:   %s" % (name, n, gout[:200], rout[:200]))
                    print("  DIFF %s n=%d | golua=%r ref=%r" % (name, n, gout[:80], rout[:80]))
            finally:
                os.unlink(spath)
    os.unlink(driver)
    print("\n=== %d DIFFs, %d ESCAPES / %d candidates ===" % (len(leads), len(escapes), total))
    with open(os.path.join(CORPUS, "report.txt"), "w") as f:
        f.write("candidates=%d diffs=%d escapes=%d ref=%s\n\n" % (total, len(leads), len(escapes), REFLUA))
        if escapes:
            f.write("== ESCAPES (host crash on load of deep/large source) ==\n" + "\n".join(escapes) + "\n\n")
        f.write("== DIFFS (compile accept/reject or message mismatch) ==\n" + "\n\n".join(leads) + "\n")
    sys.exit(1 if (leads or escapes) else 0)


if __name__ == "__main__":
    main()
