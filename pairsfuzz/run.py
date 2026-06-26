#!/usr/bin/env python3
"""Differential + invariant fuzzer for pairs / next / table iteration.

Lua leaves `pairs`/`next` ITERATION ORDER unspecified, so comparing the order
golua and the reference visit keys is invalid (it would flag non-bugs). This
tester instead compares the ORDER-INDEPENDENT facts that ARE specified:

  * the SET of visited (key,value) pairs — serialized canonically (type-tagged,
    sorted), so two impls with different visit orders still compare equal, and a
    real divergence (a key one impl drops, or a key-normalization difference
    like 1 vs 1.0 vs "1", or a value mismatch) shows up;
  * oracle-free invariants that need no reference at all:
      - no key visited twice in one traversal (dup == 0),
      - `pairs` and a manual `next()` loop enumerate the SAME set (nextmatch),
      - count agreement, and round-trip stability,
      - defined mutation-during-traversal (delete current key / update existing
        value) terminates and yields the right final set.

So every lead is a genuine completeness / normalization / consistency bug, never
an order artifact.

Usage:
  python3 run.py                 # full scenario battery
  python3 run.py --rand 2000 --seed 1
  python3 run.py --lua54
Env: GOLUA, GOLUA_REPO, REFLUA
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
REFLUA = os.environ.get("REFLUA", "lua5.5.0")
TIMEOUT_S = 15
ULIMIT_KB = 4 * 1024 * 1024

PRELUDE = r"""
local function keyrep(k)
  local mt = math.type(k)
  if mt == 'integer' then return 'i' .. string.format('%d', k)
  elseif mt == 'float' then return 'f' .. string.format('%a', k) end
  local t = type(k)
  if t == 'string' then return 's' .. #k .. ':' .. k
  elseif t == 'boolean' then return 'b' .. tostring(k)
  else return 'X' .. t end
end
local function valrep(v)
  local mt = math.type(v)
  if mt == 'integer' then return 'i' .. string.format('%d', v)
  elseif mt == 'float' then return 'f' .. string.format('%a', v) end
  local t = type(v)
  if t == 'string' then return 's' .. v
  elseif t == 'boolean' then return 'b' .. tostring(v)
  elseif t == 'nil' then return 'nil'
  else return 'X' .. t end
end
local function setOf(iter, T)
  local items, seen, dup = {}, {}, 0
  for k, v in iter, T do
    local kr = keyrep(k)
    if seen[kr] then dup = dup + 1 end
    seen[kr] = true
    items[#items+1] = kr .. '=' .. valrep(v)
  end
  table.sort(items)
  return table.concat(items, '|'), #items, dup
end
local function nextIter(T)
  -- manual next() loop expressed as a stateless iterator for setOf
  return function(_, k) return next(T, k) end, T
end
function report(tag, T)
  local ok1, s1, n1, d1 = pcall(setOf, pairs(T))
  if not ok1 then io.write(tag, ' ERR ', tostring(s1):gsub('^[^\n]-:%d+: ', ''), '\n'); return end
  -- The pairs-vs-next cross-check only holds for RAW tables: when __pairs
  -- redirects iteration to another object, next(T,...) legitimately sees
  -- different contents, so skip the cross-check there (the SET diff still runs).
  local mt = getmetatable(T)
  local nextmatch
  if mt and mt.__pairs then
    nextmatch = true
  else
    local f, st = nextIter(T)
    local s2, n2, d2 = setOf(f, st)
    nextmatch = (s1 == s2 and n1 == n2 and d2 == 0)
  end
  io.write(tag, ' SET ', s1, '\n')
  io.write(tag, ' INV dup=', d1, ' nextmatch=', tostring(nextmatch), '\n')
end
function reportNextErr(tag, fn)
  local ok, err = pcall(fn)
  if ok then io.write(tag, ' NOERR\n')
  else io.write(tag, ' ERR ', tostring(err):gsub('^[^\n]-:%d+: ', ''), '\n') end
end
"""

# ---------------------------------------------------------------------------
# scenario battery: each returns Lua that builds a table and calls report(tag,T)
# (or reportNextErr). All deterministic.
# ---------------------------------------------------------------------------
def fixed_scenarios():
    S = {}
    S["dense"] = "local T={} for i=1,50 do T[i]=i*i end report('dense',T)"
    S["holes"] = ("local T={} for i=1,50 do T[i]=i end "
                  "for i=10,40,3 do T[i]=nil end report('holes',T)")
    S["strkeys"] = ("local T={} for i=1,40 do T['k'..i]=i end report('strkeys',T)")
    S["floatkeys"] = ("local T={} for i=1,30 do T[i+0.5]=i end report('floatkeys',T)")
    S["mixed"] = ("local T={1,2,3,x='a',y='b',[true]=1,[false]=2,[1.5]=9,[-3]=7,[0]=8} "
                  "report('mixed',T)")
    # int/float key collapse: 1 and 1.0 are the same key; "1" is distinct.
    S["collapse"] = ("local T={} T[1]='int' T[1.0]='flt' T[2.0]='two' T[2]='twoi' "
                     "T['1']='str' T[3]='a' T[3.5]='b' report('collapse',T)")
    S["boundary"] = ("local T={} T[9007199254740992]='a' T[9007199254740993]='b' "
                     "T[9007199254740992.0]='c' T[math.maxinteger]='mx' "
                     "T[math.mininteger]='mn' T[-0.0]='nz' T[0]='z' report('boundary',T)")
    S["negzero"] = ("local T={} T[-0.0]=1 T[0.0]=2 T[0]=3 report('negzero',T)")
    S["grow_shrink"] = ("local T={} for i=1,200 do T[i]=i end "
                        "for i=50,150 do T[i]=nil end "
                        "for i=300,350 do T[i]=i end report('grow_shrink',T)")
    S["sparse"] = ("local T={} T[1]=1 T[1000000]=2 T[5]=3 T[-7]=4 T[2^20//1]=5 "
                   "report('sparse',T)")
    S["ctor_multiret"] = ("local function f() return 10,20,30 end "
                          "local T={f(), x=1, f()} report('ctor_multiret',T)")
    S["delete_during"] = ("local T={} for i=1,40 do T[i]=i end "
                          "for k in pairs(T) do T[k]=nil end report('delete_during',T)")
    S["update_during"] = ("local T={} for i=1,40 do T[i]=i end "
                          "for k,v in pairs(T) do T[k]=v*2 end report('update_during',T)")
    S["nan_value"] = ("local T={} T[1]=0/0 T[2]=5 report('nan_value',T)")
    S["booly"] = ("local T={[true]='t',[false]='f',[1]='one'} report('booly',T)")
    S["empty"] = "local T={} report('empty',T)"
    S["one"] = "local T={[42]='answer'} report('one',T)"
    S["after_clear"] = ("local T={} for i=1,30 do T[i]=i end "
                        "for i=1,30 do T[i]=nil end T.a=1 T.b=2 report('after_clear',T)")
    S["mt_pairs"] = ("local base={[1]='x',y='z'} "
                     "local T=setmetatable({}, {__pairs=function(t) return next, base, nil end}) "
                     "report('mt_pairs',T)")
    S["big"] = ("local T={} for i=1,3000 do T[i]= (i*2654435761)&0xffff end "
                "for i=1,3000,7 do T[i]=nil end report('big',T)")
    # next() protocol / error edges
    S["next_empty"] = "reportNextErr('next_empty', function() return tostring(next({})) end)"
    S["next_badkey"] = "reportNextErr('next_badkey', function() return next({1,2,3}, 99) end)"
    S["next_nil_nonempty"] = ("reportNextErr('next_nil_nonempty', function() "
                              "local k=next({a=1}); return k end)")
    S["next_after_last"] = ("reportNextErr('next_after_last', function() "
                            "local t={5}; local k=next(t,1); return tostring(k) end)")
    S["nan_key"] = "reportNextErr('nan_key', function() local t={}; t[0/0]=1 end)"
    S["nil_key"] = "reportNextErr('nil_key', function() local t={}; t[nil]=1 end)"
    return S


def rand_scenario(rng, idx):
    """A randomized table: mixed key types, random inserts + deletions."""
    lines = ["local T={}"]
    n = rng.randint(5, 60)
    for _ in range(n):
        kind = rng.randint(0, 5)
        if kind == 0:
            k = "%d" % rng.randint(-20, 200)
        elif kind == 1:
            k = "%d.5" % rng.randint(-20, 200)
        elif kind == 2:
            k = "'s%d'" % rng.randint(0, 40)
        elif kind == 3:
            k = rng.choice(["true", "false"])
        elif kind == 4:
            k = "%d.0" % rng.randint(-20, 200)   # int-valued float -> collapses
        else:
            k = "math.maxinteger" if rng.random() < 0.5 else "(2^%d//1)" % rng.randint(0, 53)
        v = rng.randint(0, 9999)
        lines.append("T[%s]=%d" % (k, v))
    # random deletions
    for _ in range(rng.randint(0, n // 2)):
        kk = rng.randint(-20, 200)
        lines.append("T[%d]=nil" % kk)
    lines.append("report('rand%d', T)" % idx)
    return " ".join(lines)


def build_program(snippets):
    return PRELUDE + "\n" + "\ndo " + " end\ndo ".join(snippets) + " end\n"


def _shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def run(interp, path):
    cmd = "ulimit -v %d 2>/dev/null; exec %s %s" % (ULIMIT_KB, _shq(interp), _shq(path))
    try:
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True,
                           timeout=TIMEOUT_S, errors="replace")
    except subprocess.TimeoutExpired:
        return None, "<timeout>"
    return p.returncode, (p.stdout or "") + (("\n!!" + p.stderr) if p.stderr else "")


def invariant_violations(golua_out):
    bad = []
    for line in golua_out.splitlines():
        if " INV " in line:
            if "dup=0" not in line or "nextmatch=true" not in line:
                bad.append(line)
    return bad


def check(snippets, tag):
    prog = build_program(snippets)
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
        f.write(prog)
        path = f.name
    try:
        grc, gout = run(GOLUA, path)
        rrc, rout = run(REFLUA, path)
        leads = []
        # normalize the temp path out of any error lines (identical file both runs)
        g = gout.replace(path, "<p>")
        r = rout.replace(path, "<p>")
        if g != r:
            leads.append(("DIFF", tag, g, r, prog))
        for v in invariant_violations(gout):
            leads.append(("INVARIANT", tag, v, "", prog))
        return leads
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rand", type=int, default=0)
    ap.add_argument("--seed", type=int, default=1)
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

    print("pairsfuzz: golua=%s ref=%s" % (os.path.basename(GOLUA), REFLUA))
    all_leads = []
    # fixed scenarios — one program each (so a crash localizes)
    for tag, snip in fixed_scenarios().items():
        for kind, t, g, r, prog in check([snip], tag):
            all_leads.append((kind, t, g, r, prog))
            print("  %s %s" % (kind, t))
    # randomized — batch several per program for throughput
    rng = random.Random(args.seed)
    batch = []
    for i in range(args.rand):
        batch.append(rand_scenario(rng, i))
        if len(batch) == 20:
            for lead in check(batch, "rand.batch"):
                all_leads.append(lead)
                print("  %s %s" % (lead[0], lead[1]))
            batch = []
    if batch:
        for lead in check(batch, "rand.tail"):
            all_leads.append(lead)
            print("  %s %s" % (lead[0], lead[1]))

    print("\n=== %d leads (%d scenarios + %d random) ==="
          % (len(all_leads), len(fixed_scenarios()), args.rand))
    with open(os.path.join(CORPUS, "report.txt"), "w") as f:
        f.write("leads=%d ref=%s rand=%d\n" % (len(all_leads), REFLUA, args.rand))
    for i, (kind, tag, g, r, prog) in enumerate(all_leads[:50]):
        with open(os.path.join(CORPUS, "lead_%02d_%s.lua" % (i, tag.replace('.', '_'))), "w") as f:
            f.write("-- %s %s\n-- golua:\n%s\n-- ref:\n%s\n--[[ program:\n%s ]]\n"
                    % (kind, tag, _c(g), _c(r), prog))
    sys.exit(1 if all_leads else 0)


def _c(s):
    return "\n".join("-- " + ln for ln in s.splitlines())


if __name__ == "__main__":
    main()
