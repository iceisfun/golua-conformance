#!/usr/bin/env python3
"""Differential state-machine grinder for coroutines.

golua implements coroutines with goroutines + channels; reference Lua copies the
C stack. That is golua's single biggest implementation-mechanism divergence from
reference, so it is the most likely remaining habitat for parity bugs. This tool
drives coroutines through the interactions that exercise that seam and diffs the
full observable trace (resume/yield/return/error sequence + status transitions)
against a reference interpreter.

Axes:
  drivers     : bare resume loop / coroutine.wrap / pcall(resume) / xpcall+wrap
  yield-sites : plain body / inside each metamethod (__index __newindex __add
                __concat __call __len __tostring __eq __lt __le) / iterators
                (custom, pairs, ipairs, gmatch) / library callbacks (gsub, sort)
  errors      : none / string / nil / number / table-with-__tostring / level 0,2
                / error before first yield
  specials    : nested resume, yield-from-main, resume dead/running, pcall across
                a yield, coroutine.close on a suspended coroutine with a pending
                to-be-closed var (and a __close that errors), error-object
                identity across the resume boundary, wrap re-raise of every error
                payload, isyieldable/status/running in nested contexts.

Each case runs to a canonical, address-normalized trace string; golua and the
reference must produce identical traces. A clean run leaves corpus/ empty.

Usage:
  python3 run.py                 # all cases vs lua5.5.0 (golua master)
  python3 run.py --lua54         # vs lua5.4.8 (golua lua_5_4_8 branch)
Env:
  GOLUA   path to golua CLI (default ./golua, auto-built)
  REFLUA  reference interpreter (default lua5.5.0)
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
BATCH = 200

# --- Lua driver prologue: trace helpers --------------------------------------

PROLOGUE = r"""
local out = {}
local function norm(s)
  return (tostring(s):gsub("0x%x+", "0xPTR"))
end
local function serv(v)
  local t = type(v)
  if t == "number" then
    if math.type(v) == "integer" then return "I"..v else return "F"..string.format("%.5g", v) end
  elseif t == "string" then return "S"..v
  elseif t == "boolean" then return "B"..tostring(v)
  elseif t == "nil" then return "nil"
  elseif t == "table" then return "T"
  elseif t == "function" then return "fn"
  elseif t == "thread" then return "co"
  else return "?"..t end
end
-- Drive a coroutine to completion via resume; capture each step.
local function drive(co, ...)
  local parts, args = {}, table.pack(...)
  for _ = 1, 25 do
    local r = table.pack(coroutine.resume(co, table.unpack(args, 1, args.n)))
    args = table.pack()
    local ok = r[1]
    local seg = { ok and "R+" or "R-" }
    for i = 2, r.n do seg[#seg+1] = ok and serv(r[i]) or norm(r[i]) end
    parts[#parts+1] = table.concat(seg, ",") .. "/" .. coroutine.status(co)
    if not ok or coroutine.status(co) == "dead" then break end
  end
  return table.concat(parts, "|")
end
-- Drive via coroutine.wrap: call until it raises (dead) or the cap. wrap cannot
-- distinguish a yield from the final return, and re-raises body errors (with a
-- caller-location prefix for string errors) — both are part of the trace.
local function drive_wrap(w, ...)
  local parts, args = {}, table.pack(...)
  for _ = 1, 25 do
    local r = table.pack(pcall(w, table.unpack(args, 1, args.n)))
    args = table.pack()
    local ok = r[1]
    local seg = { ok and "W+" or "W-" }
    for i = 2, r.n do seg[#seg+1] = ok and serv(r[i]) or norm(r[i]) end
    parts[#parts+1] = table.concat(seg, ",")
    if not ok then break end
  end
  return table.concat(parts, "|")
end
local function emit(id, fn)
  local r = table.pack(pcall(fn))
  if r[1] then
    out[#out+1] = id .. "\t" .. tostring(r[2])
  else
    out[#out+1] = id .. "\tCASEERR:" .. norm(r[2])
  end
end
"""

# --- Coroutine body sources (yield sites) ------------------------------------

BODIES = {
    "plain":      "function() coroutine.yield('y'); return 'r' end",
    "plain2":     "function() coroutine.yield('a'); coroutine.yield('b'); return 'r' end",
    "noyield":    "function() return 1, 2 end",
    "mm_index":   "function() local o=setmetatable({},{__index=function(_,k) coroutine.yield('idx'); return 7 end}); return o.x end",
    "mm_newindex":"function() local o=setmetatable({},{__newindex=function(_,k,v) coroutine.yield('nidx') end}); o.x=1; return 'r' end",
    "mm_add":     "function() local o=setmetatable({},{__add=function(a,b) coroutine.yield('add'); return 9 end}); return o+1 end",
    "mm_concat":  "function() local o=setmetatable({},{__concat=function(a,b) coroutine.yield('cc'); return 'z' end}); return o..'x' end",
    "mm_call":    "function() local o=setmetatable({},{__call=function(self,x) coroutine.yield('call'); return x+1 end}); return o(5) end",
    "mm_len":     "function() local o=setmetatable({},{__len=function() coroutine.yield('len'); return 3 end}); return #o end",
    "mm_tostr":   "function() local o=setmetatable({},{__tostring=function() coroutine.yield('ts'); return 'S' end}); return tostring(o) end",
    "mm_eq":      "function() local mt={__eq=function() coroutine.yield('eq'); return true end}; local a=setmetatable({},mt); local b=setmetatable({},mt); return a==b end",
    "mm_lt":      "function() local mt={__lt=function() coroutine.yield('lt'); return true end}; local a=setmetatable({},mt); local b=setmetatable({},mt); return a<b end",
    "mm_le":      "function() local mt={__le=function() coroutine.yield('le'); return true end}; local a=setmetatable({},mt); local b=setmetatable({},mt); return a<=b end",
    "iter_gen":   "function() local r={}; for k,v in pairs(setmetatable({},{__pairs=function(t) return function(_,i) i=(i or 0)+1; if i<=2 then coroutine.yield('it'..i); return i,i*10 end end, t, nil end})) do r[#r+1]=k end; return #r end",
    "iter_custom":"function() local function it(_, i) i=(i or 0)+1; if i<=2 then coroutine.yield('c'..i); return i end end; local s=0; for i in it do s=s+i end; return s end",
    "iter_ipairs":"function() local t={10,20}; local s=0; for i,v in ipairs(t) do coroutine.yield('ip'..i); s=s+v end; return s end",
    "iter_gmatch":"function() local s=''; for w in string.gmatch('a b', '%a') do coroutine.yield('gm'..w); s=s..w end; return s end",
    "cb_gsub":    "function() local s=string.gsub('ab','%a',function(c) coroutine.yield('g'..c); return c:upper() end); return s end",
    "cb_sort":    "function() local t={3,1,2}; table.sort(t,function(a,b) coroutine.yield('so'); return a<b end); return table.concat(t,',') end",
    # error bodies (yield once, then error with payload)
    "err_str":    "function() coroutine.yield('y'); error('boom') end",
    "err_nil":    "function() coroutine.yield('y'); error(nil) end",
    "err_num":    "function() coroutine.yield('y'); error(42) end",
    "err_tbl":    "function() coroutine.yield('y'); error(setmetatable({},{__tostring=function() return 'ETBL' end})) end",
    "err_lvl0":   "function() coroutine.yield('y'); error('boom', 0) end",
    "err_lvl2":   "function() coroutine.yield('y'); local function f() error('deep', 2) end; f() end",
    "err_first":  "function() error('early') end",
    "err_runtime":"function() coroutine.yield('y'); local x = nil + 1; return x end",
}

DRIVERS = {
    "resume":      "drive(coroutine.create(%s))",
    "wrap":        "drive_wrap(coroutine.wrap(%s))",
    "pcall_res":   "select(2, pcall(drive, coroutine.create(%s)))",
    "xpcall_wrap": "select(2, xpcall(function() return drive_wrap(coroutine.wrap(%s)) end, function(e) return 'H:'..norm(e) end))",
}

# --- Hand-written special scenarios (each a Lua expr returning a trace) -------

SPECIALS = {
    "yield_from_main":      "tostring(coroutine.isyieldable())..'|'..select(2, pcall(coroutine.yield, 1))",
    "resume_dead":          "function() local co=coroutine.create(function() return 1 end); drive(co); return drive(co) end",
    "resume_self":          "function() local co; co=coroutine.create(function() return coroutine.resume(co) end); return drive(co) end",
    "status_running":       "function() local co; co=coroutine.create(function() return coroutine.status(co) end); return drive(co) end",
    "running_main":         "(function() local c,m=coroutine.running(); return type(c)..','..tostring(m) end)()",
    "isyieldable_in_co":    "drive(coroutine.create(function() coroutine.yield(coroutine.isyieldable()); return coroutine.isyieldable() end))",
    "nested_resume":        "drive(coroutine.create(function() local inner=coroutine.create(function() coroutine.yield('inner'); return 'idone' end); local a,b=coroutine.resume(inner); coroutine.yield('outer:'..tostring(b)); local c,d=coroutine.resume(inner); return 'done:'..tostring(d) end))",
    "pcall_across_yield":   "drive(coroutine.create(function() local ok,e=pcall(function() coroutine.yield('p'); error('boom') end); return tostring(ok)..','..norm(e) end))",
    "xpcall_across_yield":  "drive(coroutine.create(function() return xpcall(function() coroutine.yield('p'); error('x') end, function(e) return 'H:'..norm(e) end) end))",
    "err_identity":         "function() local t={}; local co=coroutine.create(function() error(t) end); local ok,e=coroutine.resume(co); return tostring(ok)..','..tostring(e==t) end",
    "wrap_reraise_str":     "select(2, pcall(coroutine.wrap(function() error('boom') end)))",
    "wrap_reraise_nil":     "select(2, pcall(coroutine.wrap(function() error(nil) end)))",
    "wrap_reraise_tbl":     "(function() local ok,e=pcall(coroutine.wrap(function() error(setmetatable({},{__tostring=function() return 'X' end})) end)); return tostring(ok)..','..tostring(e) end)()",
    "wrap_reraise_num":     "select(2, pcall(coroutine.wrap(function() error(42) end)))",
    "close_suspended":      "function() local co=coroutine.create(function() coroutine.yield('a'); coroutine.yield('b') end); coroutine.resume(co); local ok,e=coroutine.close(co); return tostring(ok)..','..tostring(e)..'/'..coroutine.status(co) end",
    "close_tbc":            "function() local log={}; local co=coroutine.create(function() local x <close> = setmetatable({},{__close=function() log[#log+1]='C' end}); coroutine.yield('y') end); coroutine.resume(co); local ok=coroutine.close(co); return tostring(ok)..','..table.concat(log)..'/'..coroutine.status(co) end",
    "close_tbc_err":        "function() local co=coroutine.create(function() local x <close> = setmetatable({},{__close=function() error('cerr') end}); coroutine.yield('y') end); coroutine.resume(co); local ok,e=coroutine.close(co); return tostring(ok)..','..norm(e) end",
    "close_dead":           "function() local co=coroutine.create(function() return 1 end); coroutine.resume(co); return tostring(coroutine.close(co))..'/'..coroutine.status(co) end",
    "close_errored":        "function() local co=coroutine.create(function() error('x') end); coroutine.resume(co); local ok,e=coroutine.close(co); return tostring(ok)..','..tostring(e) end",
    "resume_normal":        "function() local outer; outer=coroutine.create(function() local inner=coroutine.create(function() return coroutine.resume(outer) end); local a,b,c=coroutine.resume(inner); coroutine.yield(tostring(b)..','..norm(tostring(c))) end); return drive(outer) end",
    "yield_extra_args":     "function() local co=coroutine.create(function(a,b) local c=coroutine.yield(a+b); return c*2 end); local t={} t[1]=table.concat({select(2,coroutine.resume(co,3,4))},','); t[2]=table.concat({select(2,coroutine.resume(co,10))},','); return table.concat(t,'|') end",
    "wrap_then_resume":     "function() local co=coroutine.create(function() coroutine.yield(1) end); local w=coroutine.wrap(function() coroutine.yield(2) end); return tostring((coroutine.resume(co)))..','..tostring(w()) end",
}


def make_cases():
    cases = []
    for dname, dtmpl in DRIVERS.items():
        for bname, bsrc in BODIES.items():
            expr = dtmpl % bsrc
            cases.append(("x_%s_%s" % (dname, bname), expr))
    for sname, sexpr in SPECIALS.items():
        # specials may be a bare expr or an immediately-defined function; wrap
        # function-valued specials in a call.
        expr = sexpr
        if expr.startswith("function()"):
            expr = "(%s)()" % expr
        cases.append(("s_%s" % sname, expr))
    return cases


def build_driver(cases):
    lines = [PROLOGUE]
    for cid, expr in cases:
        lines.append("emit(%r, function() return %s end)" % (cid, expr))
    lines.append("io.write(table.concat(out, '\\n')); io.write('\\n')")
    return "\n".join(lines)


def _shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def run_lua(interp, path):
    cmd = "ulimit -v %d 2>/dev/null; exec %s %s" % (ULIMIT_KB, _shq(interp), _shq(path))
    try:
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=TIMEOUT_S)
        return p.stdout, p.stderr, p.returncode
    except subprocess.TimeoutExpired:
        return "", "<timeout>", -9


def parse(text):
    d = {}
    for line in text.split("\n"):
        if "\t" in line:
            k, v = line.split("\t", 1)
            d[k] = v
    return d


def ensure_golua():
    if os.path.exists(GOLUA):
        return
    if not os.path.isdir(GOLUA_REPO):
        sys.exit("golua checkout not found at %s" % GOLUA_REPO)
    print("building golua -> %s" % GOLUA, file=sys.stderr)
    subprocess.run(["go", "build", "-o", GOLUA, "./cmd/lua"], cwd=GOLUA_REPO, check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lua54", action="store_true", help="diff lua_5_4_8 branch vs lua5.4.8")
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

    cases = make_cases()
    print("coroutine grind: %d cases, ref=%s" % (len(cases), REFLUA))
    leads = []
    for i in range(0, len(cases), BATCH):
        batch = cases[i:i + BATCH]
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
            f.write(build_driver(batch))
            path = f.name
        try:
            go_out, go_err, _ = run_lua(GOLUA, path)
            rf_out, rf_err, _ = run_lua(REFLUA, path)
        finally:
            os.unlink(path)
        gd, rd = parse(go_out), parse(rf_out)
        for cid, expr in batch:
            g, r = gd.get(cid, "<MISSING golua: %s>" % go_err[:80]), rd.get(cid, "<MISSING ref: %s>" % rf_err[:80])
            if g != r:
                leads.append("%s | %s\n    golua: %s\n    ref:   %s" % (cid, expr, g, r))
    print("\n=== %d leads ===" % len(leads))
    with open(os.path.join(CORPUS, "report.txt"), "w") as f:
        f.write("cases=%d ref=%s leads=%d\n\n" % (len(cases), REFLUA, len(leads)))
        f.write("\n".join(leads))
    if leads:
        with open(os.path.join(CORPUS, "diff.txt"), "w") as f:
            f.write("\n".join(leads) + "\n")
        print("  wrote %d leads -> corpus/diff.txt" % len(leads))
    print("  report -> corpus/report.txt")
    sys.exit(1 if leads else 0)


if __name__ == "__main__":
    main()
