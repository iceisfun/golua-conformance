#!/usr/bin/env python3
"""Oracle-free sandbox-robustness fuzzer for golua.

golua's headline guarantee is that *sandboxed* Lua cannot crash or hang the host
Go process: every adversarial input must surface as a CATCHABLE Lua error (or a
clean bounded result), never an uncatchable Go panic / runtime fatal / SIGSEGV,
and never an unbounded hang. Because golua is Go, a whole class of failure modes
that don't exist in C Lua — nil deref, slice out-of-range, integer MinInt/-1,
runtime.throw OOM (which recover() does NOT catch), goroutine stack exhaustion —
must be defended at every boundary.

No differential finder tests this: it is an *invariant*, not a parity check, so
it works even now that the differential tail is nearly dry. Each case is run
under `ulimit -v` + `timeout`, wrapped so a normal Lua error exits cleanly; the
fuzzer flags only ESCAPES:
  - stderr shows `panic:` / `fatal error:` / `goroutine NN` / `runtime:` / SIG*
  - process dies by signal (exit > 128) or Go-panic exit (2)
  - the case hangs (timeout) despite doing only bounded work

This caught the `s = s .. s` concat fast-path OOM escape (uncatchable Go fatal
OOM aborting the host).

Usage:
  python3 run.py                 # all curated + randomized cases
  python3 run.py --rand 5000 --seed 1
Env:
  GOLUA   golua CLI (default ./golua, auto-built)
"""

import argparse
import os
import random
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")
WORK = os.path.dirname(os.path.dirname(HERE))
GOLUA_REPO = os.path.abspath(os.environ.get("GOLUA_REPO", os.path.join(WORK, "golua")))
GOLUA = os.environ.get("GOLUA", os.path.join(HERE, "golua"))

ULIMIT_KB = 6 * 1024 * 1024   # 6 GiB: enough to build a ~1GB string before a
                              # size guard fires, low enough to bound runaways.
TIMEOUT_S = 12

# Each snippet does BOUNDED work and is wrapped in pcall, so a correct golua
# exits 0 and prints "true"/"false ...". An escape is a Go panic/fatal/hang.
CURATED = {
    # --- memory / size limits (must be catchable, not runtime OOM) ----------
    "concat_double":      'local s="x" for i=1,60 do s=s..s end',
    "concat_chain_grow":  'local s="x" for i=1,40 do s=s..s..s end',
    "rep_huge":           'return string.rep("x", math.maxinteger)',
    "rep_sep_huge":       'return string.rep("ab", 2^30, "sep")',
    "tblconcat_huge":     'local t={} for i=1,1000 do t[i]=("x"):rep(2^20) end return table.concat(t)',
    "format_width_huge":  'return ("%2000000000d"):format(1)',
    "format_prec_huge":   'return ("%.2000000000f"):format(1.5)',
    "pack_huge_count":    'return string.pack(("i8"):rep(100000000))',
    "pack_fixed_huge":    'return string.pack("c" .. (1<<40), "x")',  # >1<<30 fixed size: catchable, not host OOM
    "concat_over_cap":    'local a=("x"):rep(600000000) return #table.concat({a,a})',  # >1<<30 join: catchable
    "packsize_huge":      'return string.packsize(("i8"):rep(100000000))',
    "table_grow_cap":     'local t={} for i=1,2e7 do t[i]=i end return #t',
    "table_create_huge":  'return table.create and table.create(math.maxinteger) or "n/a"',
    # --- stack depth (must be a catchable C-stack-overflow, not a crash) ----
    "deep_recursion":     'local function f(n) return 1+f(n+1) end return f(0)',
    "deep_pcall":         'local function f(n) return pcall(f, n+1) end return f(0)',
    "deep_index_mm":      'local t; t=setmetatable({},{__index=function(_,k) return t[k] end}) return t.x',
    "deep_add_mm":        'local t; t=setmetatable({},{__add=function(a,b) return a+1 end}) return t+1',
    "deep_concat_mm":     'local t; t=setmetatable({},{__concat=function(a,b) return a..b end}) return t.."x"',
    "deep_call_mm":       'local t; t=setmetatable({},{__call=function(s,...) return s(...) end}) return t()',
    "deep_tostring_mm":   'local t; t=setmetatable({},{__tostring=function(s) return tostring(s) end}) return tostring(t)',
    "deep_table_nest":    'local t={} local c=t for i=1,1e6 do c[1]={} c=c[1] end return "built"',
    "deep_paren_load":    'return load("return "..("("):rep(100000).."1"..(")"):rep(100000))',
    "deep_expr_load":     'return load(("1+"):rep(100000).."1")',
    # --- integer / arithmetic edge (Go panics on MinInt64 / -1) ------------
    "minint_idiv_m1":     'return math.mininteger // -1',
    "minint_mod_m1":      'return math.mininteger % -1',
    "minint_div_m1f":     'return math.mininteger / -1',
    "minint_abs":         'return math.abs(math.mininteger)',
    "int_div_zero":       'return 1 // 0',
    "int_mod_zero":       'return 5 % 0',
    "shift_huge":         'return 1 << 1000, 1 >> 1000, -1 << -1000',
    # --- index / range (slice OOB in Go) -----------------------------------
    "sub_extremes":       'return ("abc"):sub(math.mininteger, math.maxinteger)',
    "byte_extremes":      'return ("abc"):byte(math.mininteger, math.maxinteger)',
    "char_huge":          'return string.char(math.maxinteger)',
    "move_huge":          'local t={1,2,3} return table.move(t,1,math.maxinteger,1,{})',
    "unpack_huge":        'return table.unpack({1,2,3}, 1, math.maxinteger)',
    "pack_offset_oob":    'return string.unpack("i8", "abc", math.maxinteger)',
    "rep_neg":            'return string.rep("x", -5)',
    # --- pattern (recursion / complexity) ----------------------------------
    "pat_deep_quant":     'return ("aaaa"):match(("a*"):rep(5000))',
    "pat_deep_nest":      'return ("x"):match(("("):rep(50)..")"..(")"):rep(49))',
    "pat_backtrack":      'return ("a"):rep(100):match("(a+)+b")',
    "gsub_huge":          'return (("a"):rep(2000)):gsub("a", ("x"):rep(1000000))',  # >1<<30 result: must be catchable, not a host OOM crash
    # --- coroutine / goroutine resource ------------------------------------
    "many_coroutines":    'for i=1,200000 do coroutine.create(function() end) end return "ok"',
    "coro_deep_resume":   'local function mk() return coroutine.wrap(function() mk()() end) end return mk()()',
    "coro_yield_storm":   'local c=coroutine.wrap(function() while true do coroutine.yield(1) end end) for i=1,1e7 do c() end',
    # --- misc native boundaries --------------------------------------------
    "tostring_cycle":     'local t={} t.self=t return tostring(t)',
    "error_deep_obj":     'local t={} t.self=t error(t)',
    "select_huge":        'return select(math.maxinteger, 1, 2, 3)',
    "setmeta_loop":       'local a,b=setmetatable({},{}),{} debug.setmetatable(a,a) return tostring(a)',
}

ESCAPE_MARKERS = ("panic:", "fatal error:", "goroutine ", "runtime:",
                  "SIGSEGV", "signal SIG", "stack overflow\n\ngoroutine")


def _shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def run_case(snippet):
    """Run one snippet wrapped in pcall under ulimit+timeout.
    Returns (verdict, detail). verdict in {ok, ESCAPE, HANG}."""
    prog = "print(pcall(function() %s end))\n" % snippet
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
        f.write(prog)
        path = f.name
    try:
        cmd = "ulimit -v %d 2>/dev/null; exec %s %s" % (ULIMIT_KB, _shq(GOLUA), _shq(path))
        try:
            p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True,
                               timeout=TIMEOUT_S)
        except subprocess.TimeoutExpired:
            return ("HANG", "timeout after %ds" % TIMEOUT_S)
        out = (p.stdout or "") + (p.stderr or "")
        low = out.lower()
        for m in ESCAPE_MARKERS:
            if m.lower() in low:
                return ("ESCAPE", "marker %r | rc=%d | %s" % (m, p.returncode, out.strip()[:200]))
        if p.returncode == 2 or p.returncode > 128:
            return ("ESCAPE", "rc=%d (signal/panic) | %s" % (p.returncode, out.strip()[:200]))
        return ("ok", "rc=%d" % p.returncode)
    finally:
        os.unlink(path)


# --- randomized tier: extreme args into a spread of builtins -----------------

_RANDOPS = [
    'string.rep("ab", {N})', 'string.rep("ab", {N}, "s")',
    '("abcdef"):sub({N}, {N2})', '("abcdef"):byte({N}, {N2})',
    'string.char({N})', '("%{N}d"):format(1)', '("%.{N}f"):format(1.0)',
    'string.pack(("i8"):rep({N}))', 'table.unpack({{1,2,3}}, {N}, {N2})',
    'table.move({{1,2,3}}, {N}, {N2}, 1, {{}})', 'select({N}, 1, 2, 3)',
    '("a"):rep({N3}):match(("a*"):rep({N3}))', '{N} // {N2}', '{N} % {N2}',
    '1 << {N}', 'math.floor({N}.0)', 'string.rep("x", {N}):gsub("x", "yy")',
]
_RANDN = ["math.maxinteger", "math.mininteger", "-1", "0", "2^53", "2^31",
          "1e18", "2^30", "100000000", "-100000000", "1<<40"]


def rand_cases(seed, count):
    rng = random.Random(seed)
    out = []
    for i in range(count):
        op = rng.choice(_RANDOPS)
        s = (op.replace("{N3}", str(rng.randint(1, 8000)))
               .replace("{N2}", rng.choice(_RANDN))
               .replace("{N}", rng.choice(_RANDN)))
        out.append(("rand_%d" % i, s))
    return out


def ensure_golua():
    if os.path.exists(GOLUA):
        return
    if not os.path.isdir(GOLUA_REPO):
        sys.exit("golua checkout not found at %s" % GOLUA_REPO)
    print("building golua -> %s" % GOLUA, file=sys.stderr)
    subprocess.run(["go", "build", "-o", GOLUA, "./cmd/lua"], cwd=GOLUA_REPO, check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rand", type=int, default=0, help="number of randomized cases")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    ensure_golua()
    os.makedirs(CORPUS, exist_ok=True)

    cases = sorted(CURATED.items())
    if args.rand:
        cases += rand_cases(args.seed, args.rand)
    print("sandbox grind: %d cases (ulimit=%dGiB, timeout=%ds)"
          % (len(cases), ULIMIT_KB // (1024 * 1024), TIMEOUT_S))

    escapes, hangs = [], []
    for cid, snippet in cases:
        verdict, detail = run_case(snippet)
        if verdict == "ESCAPE":
            escapes.append("%s | %s\n    %s" % (cid, snippet, detail))
            print("  ESCAPE %s" % cid)
        elif verdict == "HANG":
            hangs.append("%s | %s\n    %s" % (cid, snippet, detail))
            print("  HANG   %s" % cid)

    print("\n=== %d ESCAPES, %d HANGS / %d cases ===" % (len(escapes), len(hangs), len(cases)))
    with open(os.path.join(CORPUS, "report.txt"), "w") as f:
        f.write("cases=%d escapes=%d hangs=%d\n\n" % (len(cases), len(escapes), len(hangs)))
        f.write("== ESCAPES (host-crash: uncatchable Go panic/fatal/signal) ==\n")
        f.write("\n".join(escapes) + "\n\n== HANGS (unbounded; review) ==\n")
        f.write("\n".join(hangs))
    if escapes or hangs:
        with open(os.path.join(CORPUS, "diff.txt"), "w") as f:
            f.write("ESCAPES:\n" + "\n".join(escapes) + "\n\nHANGS:\n" + "\n".join(hangs) + "\n")
    print("  report -> corpus/report.txt")
    sys.exit(1 if escapes else 0)   # hangs are a soft signal; escapes fail


if __name__ == "__main__":
    main()
