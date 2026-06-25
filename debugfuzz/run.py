#!/usr/bin/env python3
"""Differential grinder for the debug library + source line-info model.

golua is an AST-based one-pass compiler with its own VM frame/register model;
reference Lua is a bytecode one-pass compiler with a C stack. The two seams that
diverge most are (1) the debug.* surface that exposes that frame model and
(2) the per-instruction source line table, which drives BOTH `debug.sethook`
line hooks AND runtime error-line / traceback reporting.

This tool diffs two observable channels against a reference interpreter:

  LINEHOOK  : for a matrix of statement pairs, install a "l" hook and capture
              the exact sequence of line numbers visited. Line-info attribution
              bugs (e.g. an instruction relabeled to the wrong source line) show
              up as a different visited-line sequence.
  ERRLINE   : run snippets that fault on a "discharge" instruction (index nil,
              __index error, arithmetic on nil) and capture the reported error
              line + traceback. A mis-attributed line table corrupts the user-
              visible error location, not just the debugger.
  DEBUGAPI  : a matrix of debug.getinfo / getlocal / setlocal / getupvalue /
              setupvalue / upvalueid / upvaluejoin / traceback / getmetatable /
              getregistry calls over C / Lua / main / vararg / tail-call /
              coroutine frames, address-normalized.

A clean run leaves corpus/ empty.

Usage:
  python3 run.py                 # golua master vs lua5.5.0
  python3 run.py --lua54         # golua lua_5_4_8 branch vs lua5.4.8
Env:
  GOLUA_REPO  golua checkout (default ../golua)
  GOLUA       golua CLI (default ./golua, auto-built)
  REFLUA      reference interpreter (default lua5.5.0)
"""

import argparse
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")
WORK = os.path.dirname(os.path.dirname(HERE))
GOLUA_REPO = os.path.abspath(os.environ.get("GOLUA_REPO", os.path.join(WORK, "golua")))
GOLUA = os.environ.get("GOLUA", os.path.join(HERE, "golua"))
REFLUA = os.environ.get("REFLUA", "lua5.5.0")

ULIMIT_KB = 2 * 1024 * 1024
TIMEOUT_S = 30

# ---------------------------------------------------------------------------
# LINEHOOK matrix: a "head" statement (whose last emitted instruction is some
# discharge op) followed by a "tail" statement. We trace the visited source
# lines via a line hook. The compiler must give every instruction the same
# source line the reference does, or the visited-line sequence diverges.
#
# Each head/tail is one source line; we wrap them in a function so line numbers
# are stable and we can run many cases in one process.
# ---------------------------------------------------------------------------

HEADS = {
    "loadi":   "local p = 0",
    "loadk":   "local p = 1000000",
    "loadf":   "local p = 1.5",
    "loadnil": "local p",
    "loadbool":"local p = true",
    "newtable":"local p = {}",
    "getupval":"local p = _G",
    "getfield":"local p = _G.type",
    "geti":    "local p = ({10})[1]",
    "concat":  "local p = 'a'..'b'",
    "move":    "local q = 0; local p = q",
}

TAILS = {
    "addi":   "n = n + 1",          # ADDI optimization path  (bug habitat)
    "subi":   "n = n - 1",          # SUBI optimization path  (bug habitat)
    "addbig": "n = n + 1000",       # generic arith (emits MOVE)
    "addvar": "n = n + p",          # generic arith, two locals
    "mul":    "n = n * n",          # generic arith
    "call":   "print(n)",           # GETTABUP first
    "local":  "local z = n + 1",    # ADDI into a fresh local
    "index":  "local z = ({})[n]",  # GETI
}


def linehook_cases():
    cases = []
    for hn, hsrc in HEADS.items():
        for tn, tsrc in TAILS.items():
            body = "local n = 5\n  %s\n  %s\n" % (hsrc, tsrc)
            cases.append(("lh_%s_%s" % (hn, tn), body))
    return cases


# ---------------------------------------------------------------------------
# ERRLINE matrix: the head faults at runtime; its instruction's source line
# must be reported correctly even when the following tail statement is an
# ADDI/SUBI (which historically relabeled the head's instruction line).
# ---------------------------------------------------------------------------

ERR_HEADS = {
    "index_nil_field": "local v = t.x",        # GETFIELD on nil
    "index_nil_geti":  "local v = t[1]",       # GETI on nil
    "index_nil_var":   "local v = t[k]",       # GETTABLE on nil
    "mm_index_err":    "local v = mt.boom",    # __index that errors
    "arith_nil":       "local v = t + 1",      # arithmetic on nil
}
ERR_TAILS = {
    "addi": "a = a + 1",
    "subi": "a = a - 1",
    "big":  "a = a + 1000",
    "none": "a = a",
}


def errline_cases():
    cases = []
    for hn, hsrc in ERR_HEADS.items():
        for tn, tsrc in ERR_TAILS.items():
            cases.append(("el_%s_%s" % (hn, tn), hsrc, tsrc))
    return cases


# ---------------------------------------------------------------------------
# DEBUGAPI matrix: hand-written probes over frame types. Each yields a string.
# ---------------------------------------------------------------------------

DEBUGAPI = {
    "getinfo_lua":   "local function f(a,b) local x=1 return a+b+x end local i=debug.getinfo(f,'nSlu') return i.what..'/'..tostring(i.name)..'/'..i.linedefined..'/'..i.nparams..'/'..tostring(i.isvararg)..'/'..i.nups",
    "getinfo_c":     "local i=debug.getinfo(print,'nSlu') return i.what..'/'..i.short_src..'/'..i.linedefined..'/'..i.nparams..'/'..tostring(i.isvararg)..'/'..i.nups",
    "getinfo_main":  "local i=debug.getinfo(1,'Su') return i.what..'/'..i.nparams..'/'..tostring(i.isvararg)..'/'..i.linedefined",
    "getinfo_oor":   "return tostring(debug.getinfo(100))",
    "getinfo_badopt":"local ok,e=pcall(debug.getinfo,print,'Z') return tostring(ok)..'/'..tostring(e)",
    "activelines":   "local function f() local a=1\n return a end local al=debug.getinfo(f,'L').activelines local t={} for k in pairs(al) do t[#t+1]=k end table.sort(t) return table.concat(t,',')",
    "getlocal_for":  "local out={} local function g() for i=1,1 do local a=i debug.sethook() local n,v out[1]=debug.getlocal(1,1) out[2]=select(2,debug.getlocal(1,1)) end end g() return table.concat(out,',')",
    "getlocal_func": "local function h(x,y,z) end return tostring(debug.getlocal(h,1))..','..tostring(debug.getlocal(h,3))..','..tostring(debug.getlocal(h,4))",
    "getlocal_va":   "local function f(...) return debug.getlocal(1,-1) end return tostring(select(2,(function() return f(7) end)()))",
    "setlocal":      "local function f() local a=1 debug.setlocal(1,1,99) return a end return f()",
    "upvalue":       "local x=10 local function f() return x end local n,v=debug.getupvalue(f,1) debug.setupvalue(f,1,42) return n..'/'..v..'/'..f()",
    "upvalueid":     "local x=1 local function a() return x end local function b() return x end return tostring(debug.upvalueid(a,1)==debug.upvalueid(b,1))",
    "upvaluejoin":   "local x,y=1,2 local function a() return x end local function b() return y end debug.upvaluejoin(a,1,b,1) return a()",
    "tb_basic":      "local function c() return debug.traceback('M',1) end return (c():gsub('0x%x+','P'))",
    "tb_tail":       "local function l3() return debug.traceback('T',1) end local function l2() return l3() end return (l2():gsub('0x%x+','P'))",
    "tb_nonstr":     "return type(debug.traceback({}))..'/'..debug.traceback(42)",
    "meta_str":      "return type(debug.getmetatable('x'))..'/'..tostring(debug.getmetatable(1))..'/'..tostring(debug.getmetatable(nil))",
    "registry":      "local r=debug.getregistry() return type(r)..'/'..tostring(r[2]==_G)..'/'..type(r._LOADED)",
    "getinfo_co":    "local co=coroutine.create(function(a) local x=a coroutine.yield(x) end) coroutine.resume(co,5) local i=debug.getinfo(co,1,'Sl') return i.what..'/'..tostring(i.currentline>0)",
    "getlocal_co":   "local co=coroutine.create(function(a,b) local x=a+b coroutine.yield(x) end) coroutine.resume(co,3,4) return tostring(debug.getlocal(co,1,1))..'/'..tostring(select(2,debug.getlocal(co,1,3)))",
}


# ---------------------------------------------------------------------------

def build_linehook(cases):
    L = [r"""
local out={}
local function trace(f)
  local L={}
  debug.sethook(function(_,ln) L[#L+1]=ln end, "l")
  local ok,e=pcall(f)
  debug.sethook()
  return table.concat(L, ",")
end
"""]
    for cid, body in cases:
        L.append("out[#out+1]=%r..'\\t'..trace(function()\n  %s\nend)" % (cid, body))
    L.append("io.write(table.concat(out,'\\n'),'\\n')")
    return "\n".join(L)


def build_errline(cases):
    # each case is its own program (a fault aborts the chunk) -> run separately.
    progs = []
    for cid, head, tail in cases:
        src = (
            "local a = 1\n"
            "local t = nil\n"
            "local k = 1\n"
            "local mt = setmetatable({}, {__index=function() error('boom', 2) end})\n"
            "%s\n"
            "%s\n"
            "print('NOERR')\n"
        ) % (head, tail)
        progs.append((cid, src))
    return progs


def build_debugapi(cases):
    L = ["local out={}"]
    for cid, expr in cases.items():
        L.append("do local ok,r=pcall(function() %s end) out[#out+1]=%r..'\\t'..(ok and tostring(r) or 'ERR:'..tostring(r)) end" % (expr, cid))
    L.append("io.write(table.concat(out,'\\n'),'\\n')")
    return "\n".join(L)


def _shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def run_lua(interp, path):
    cmd = "ulimit -v %d 2>/dev/null; exec %s %s" % (ULIMIT_KB, _shq(interp), _shq(path))
    try:
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=TIMEOUT_S)
        return p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return "<timeout>"


def norm_err(s):
    import re
    return re.sub(r"0x[0-9a-f]+", "P", s)


def parse_tsv(text):
    d = {}
    for line in text.split("\n"):
        if "\t" in line:
            k, v = line.split("\t", 1)
            d[k] = v
    return d


def run_block(name, source, leads):
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
        f.write(source)
        path = f.name
    try:
        g = parse_tsv(run_lua(GOLUA, path))
        r = parse_tsv(run_lua(REFLUA, path))
    finally:
        os.unlink(path)
    keys = set(g) | set(r)
    for k in sorted(keys):
        gv, rv = g.get(k, "<MISSING>"), r.get(k, "<MISSING>")
        if gv != rv:
            leads.append("[%s] %s\n    golua: %s\n    ref:   %s" % (name, k, gv, rv))


def run_errline(cases, leads):
    for cid, src in build_errline(cases):
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
            f.write(src)
            path = f.name
        try:
            g = norm_err(run_lua(GOLUA, path)).replace(path, "FILE").strip()
            r = norm_err(run_lua(REFLUA, path)).replace(path, "FILE").strip()
        finally:
            os.unlink(path)
        # strip the leading interpreter-name token ("golua:" vs "/usr/bin/lua5.5.0:")
        def strip_prog(s):
            return "\n".join(ln.split(": ", 1)[-1] if ln and not ln.startswith("\t") else ln for ln in s.split("\n"))
        gs, rs = strip_prog(g), strip_prog(r)
        if gs != rs:
            leads.append("[ERRLINE] %s\n    golua: %s\n    ref:   %s" % (cid, gs.replace("\n", " | "), rs.replace("\n", " | ")))


def ensure_golua():
    if os.path.exists(GOLUA):
        return
    if not os.path.isdir(GOLUA_REPO):
        sys.exit("golua checkout not found at %s" % GOLUA_REPO)
    print("building golua -> %s" % GOLUA, file=sys.stderr)
    subprocess.run(["go", "build", "-o", GOLUA, "./cmd/lua"], cwd=GOLUA_REPO, check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lua54", action="store_true")
    args = ap.parse_args()
    global GOLUA, REFLUA
    if args.lua54:
        sys.path.insert(0, os.path.dirname(HERE))
        import lua54
        GOLUA = lua54.ensure_golua54(GOLUA_REPO)
        REFLUA = os.environ.get("REFLUA", "lua5.4.8")
    else:
        ensure_golua()
    os.makedirs(CORPUS, exist_ok=True)

    lh = linehook_cases()
    el = errline_cases()
    n = len(lh) + len(el) + len(DEBUGAPI)
    print("debugfuzz: %d cases (linehook=%d errline=%d api=%d) ref=%s"
          % (n, len(lh), len(el), len(DEBUGAPI), REFLUA))

    leads = []
    run_block("LINEHOOK", build_linehook(lh), leads)
    run_errline(el, leads)
    run_block("DEBUGAPI", build_debugapi(DEBUGAPI), leads)

    print("\n=== %d leads ===" % len(leads))
    with open(os.path.join(CORPUS, "report.txt"), "w") as f:
        f.write("cases=%d ref=%s leads=%d\n\n" % (n, REFLUA, len(leads)))
        f.write("\n\n".join(leads))
    if leads:
        with open(os.path.join(CORPUS, "diff.txt"), "w") as f:
            f.write("\n\n".join(leads) + "\n")
        for l in leads:
            print(l)
        print("  wrote %d leads -> corpus/diff.txt" % len(leads))
    sys.exit(1 if leads else 0)


if __name__ == "__main__":
    main()
