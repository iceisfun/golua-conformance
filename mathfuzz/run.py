#!/usr/bin/env python3
"""Differential grinder for the math library across edge magnitudes.

Runs EVERY math.* function over a curated battery of edge-case inputs — signed
zero, subnormals, the float/integer extremes (maxinteger/mininteger/huge/tiny),
NaN/Inf, domain boundaries (sqrt/log/asin of negatives), exact vs inexact
doubles, near-overflow/underflow — under BOTH golua and a reference interpreter,
and compares results.

The hard part on this surface is NOISE: transcendental functions legitimately
differ in the last ULP between Go's math package and the platform's C libm
(documented won't-fix, see golua wontfix/libm-last-ulp). So results are not
diffed as raw strings — float outputs are decoded to IEEE-754 doubles and
compared by ULP DISTANCE. Differences within ULP_THRESHOLD are bucketed as
"lastulp" (platform, NOT corpus); only STRUCTURAL divergences become leads:
  - integer-vs-float type mismatch
  - error-vs-value / different error wording
  - NaN vs finite, Inf vs finite
  - sign-of-zero on a runtime call (caught the math.sqrt("-0") bug)
  - float results more than ULP_THRESHOLD apart

A clean run leaves corpus/ empty.

Usage:
  python3 run.py                 # all deterministic cases vs lua5.5.0
  python3 run.py --lua54         # vs lua5.4.8 (golua lua_5_4_8 branch)
  python3 run.py --ulp 8         # widen the last-ULP tolerance
Env:
  GOLUA   path to golua CLI (default: ./golua, auto-built if missing)
  REFLUA  path to reference interpreter (default: lua5.5.0)
"""

import argparse
import math
import os
import random
import struct
import subprocess
import sys
import tempfile


def rand_double_literals(n, seed):
    """N random FINITE doubles as exact hex-float Lua literals (parsed bit-exact
    by both engines). These feed ONLY the EXACT unary functions (sqrt is IEEE
    correctly-rounded; floor/ceil/abs/modf/tointeger/type are algebraic), where
    a difference at tolerance 0 is a genuine structural bug at ANY magnitude.

    Transcendentals are deliberately NOT fed random doubles: their large-
    argument divergence (Go math vs platform libm argument reduction — 100s to
    1000s of ULP once |x| is large, tan worst because of its poles) is inherent
    and documented (golua wontfix/libm-last-ulp), so feeding them random
    magnitudes only manufactures noise. Four strategies: uniform bit pattern,
    mantissa x 2^exp over all magnitudes, decimal n/10^k, near-int/near-half."""
    rng = random.Random(seed)
    out = []
    while len(out) < n:
        s = rng.randint(0, 3)
        if s == 0:
            d = struct.unpack("<d", struct.pack("<Q", rng.getrandbits(64)))[0]
        elif s == 1:
            d = math.ldexp(rng.getrandbits(53), rng.randint(-1074, 970))
            if rng.random() < 0.5:
                d = -d
        elif s == 2:
            num = rng.randint(-10**rng.randint(1, 18), 10**rng.randint(1, 18))
            d = num / (10 ** rng.randint(0, 18))
        else:
            d = rng.randint(-10**12, 10**12) + rng.choice([0.0, 0.5, 0.25, -0.5])
        if math.isfinite(d):
            out.append("(" + float(d).hex() + ")")
    return out


RAND_INPUTS = []  # populated by --rand; consumed only by the EXACT unary fns

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")
WORK = os.path.dirname(os.path.dirname(HERE))
GOLUA_REPO = os.path.abspath(os.environ.get("GOLUA_REPO", os.path.join(WORK, "golua")))
GOLUA = os.environ.get("GOLUA", os.path.join(HERE, "golua"))
REFLUA = os.environ.get("REFLUA", "lua5.5.0")

ULIMIT_KB = 2 * 1024 * 1024
TIMEOUT_S = 30
BATCH = 1000

# --- Input batteries (Lua source expressions; both interpreters lex them) -----

FLOAT_INPUTS = [
    "0.0", "-0.0", "1.0", "-1.0", "0.5", "-0.5", "0.1", "-0.1",
    "1.5", "2.5", "-2.5", "2.0", "-2.0", "10.0", "100.0",
    "3.141592653589793", "1.5707963267948966", "-3.141592653589793",
    "5e-324", "2.2250738585072014e-308", "1e-300", "1e-308",
    "1e300", "1e308", "1.7976931348623157e308",
    "9007199254740992.0", "9007199254740993.0", "4503599627370496.0",
    "709.0", "710.0", "-745.0", "-746.0",
    "0.9999999999999999", "1.0000000000000002",
    "math.huge", "-math.huge", "0/0",
]

INT_INPUTS = [
    "0", "1", "-1", "2", "-2", "10", "-10", "100", "-100",
    "math.maxinteger", "math.mininteger", "math.maxinteger-1",
    "math.mininteger+1", "2147483647", "-2147483648", "4294967296",
    "9007199254740992", "-9007199254740992", "3", "7", "-7",
]

ALL_INPUTS = FLOAT_INPUTS + INT_INPUTS

# Reduced battery for the O(n^2) binary functions.
BIN_INPUTS = [
    "0.0", "-0.0", "1.0", "-1.0", "0.5", "2.5", "-2.5",
    "1e300", "1e-300", "math.huge", "-math.huge", "0/0",
    "0", "1", "-1", "2", "math.maxinteger", "math.mininteger",
    "3.141592653589793", "10.0",
]

# EXACT functions must agree bit-for-bit (tolerance 0): they are algebraic or
# correctly-rounded by IEEE 754 (sqrt), so any float difference is structural.
# TRANSCENDENTAL functions are approximated differently by Go's math and the
# platform libm (esp. argument reduction at large/near-zero-crossing inputs), so
# they get a generous ULP tolerance — see golua wontfix/libm-last-ulp.
EXACT_UNARY = ["abs", "ceil", "floor", "sqrt", "modf", "tointeger", "type"]
TRANSC_UNARY = ["sin", "cos", "tan", "asin", "acos", "atan", "exp", "log"]

# Binary calls: (label, lua-template, exact?).
BINARY = [
    ("fmod",  "math.fmod(%s, %s)", True),
    ("ult",   "math.ult(%s, %s)",  True),
    ("max",   "math.max(%s, %s)",  True),
    ("min",   "math.min(%s, %s)",  True),
    ("atan2", "math.atan(%s, %s)", False),
    ("logb",  "math.log(%s, %s)",  False),
]


def make_cases():
    """Yield (id, lua_expr, exact) tuples for every deterministic case."""
    cid = 0
    for fn in EXACT_UNARY:
        for a in ALL_INPUTS + RAND_INPUTS:
            yield ("u_%s_%d" % (fn, cid), "math.%s(%s)" % (fn, a), True); cid += 1
    for fn in TRANSC_UNARY:
        for a in ALL_INPUTS:
            yield ("u_%s_%d" % (fn, cid), "math.%s(%s)" % (fn, a), False); cid += 1
    for label, tmpl, exact in BINARY:
        for a in BIN_INPUTS:
            for b in BIN_INPUTS:
                yield ("b_%s_%d" % (label, cid), tmpl % (a, b), exact); cid += 1
    # math.max/min with 3 args (varargs path).
    for a in BIN_INPUTS[:8]:
        for b in BIN_INPUTS[:8]:
            yield ("v_max_%d" % cid, "math.max(%s, %s, 0)" % (a, b), True); cid += 1
            yield ("v_min_%d" % cid, "math.min(%s, %s, 0)" % (a, b), True); cid += 1


# --- Lua driver: emit one canonical line per case -----------------------------

DRIVER_PROLOGUE = r"""
local out = {}
local fmt = string.format
local function serv(v)
  local t = math.type(v)
  if t == "integer" then return "I" .. fmt("%d", v)
  elseif t == "float" then
    if v ~= v then return "Fnan"                 -- collapse NaN sign (won't-fix)
    elseif v == math.huge then return "Finf"
    elseif v == -math.huge then return "F-inf"
    else return "F" .. fmt("%a", v) end          -- exact hex float
  elseif v == nil then return "nil"
  else return "?" .. type(v) end
end
local function emit(id, fn)
  local r = table.pack(pcall(fn))
  if not r[1] then
    local m = tostring(r[2])
    m = m:gsub("^[^\n]-:%d+: ", "")              -- strip source:line: prefix
    out[#out+1] = id .. "\terr\t" .. m
  else
    local parts = {}
    for i = 2, r.n do parts[#parts+1] = serv(r[i]) end
    out[#out+1] = id .. "\tok\t" .. table.concat(parts, " ")
  end
end
"""


def build_driver(cases):
    lines = [DRIVER_PROLOGUE]
    for cid, expr, _exact in cases:
        lines.append("emit(%r, function() return %s end)" % (cid, expr))
    lines.append("io.write(table.concat(out, '\\n'))")
    lines.append("io.write('\\n')")
    return "\n".join(lines)


# --- Running ------------------------------------------------------------------

def _shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def run_lua(interp, path):
    cmd = "ulimit -v %d 2>/dev/null; exec %s %s" % (ULIMIT_KB, _shq(interp), _shq(path))
    try:
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True,
                           timeout=TIMEOUT_S)
        return p.stdout, p.stderr, p.returncode
    except subprocess.TimeoutExpired:
        return "", "<timeout>", -9


def parse_lines(text):
    d = {}
    for line in text.split("\n"):
        if not line:
            continue
        parts = line.split("\t", 2)
        if len(parts) == 3:
            d[parts[0]] = (parts[1], parts[2])
    return d


# --- ULP-aware classification -------------------------------------------------

def _ulp_key(x):
    i = struct.unpack("<q", struct.pack("<d", x))[0]
    return i if i >= 0 else (-(1 << 63) - i)


def _hexfloat(tok):
    """Token 'F0x1.0p+1' -> python float, or None if not a finite hex float."""
    if not tok.startswith("F"):
        return None
    body = tok[1:]
    if body in ("nan", "inf", "-inf"):
        return None
    try:
        return float.fromhex(body)
    except ValueError:
        return None


def classify(gtok, rtok, ulp_threshold):
    """Return (kind, detail) for a pair of ok-payload tokens that differ.
    kind in {'match','lastulp','signzero','lead'}."""
    if gtok == rtok:
        return ("match", "")
    g_parts, r_parts = gtok.split(" "), rtok.split(" ")
    if len(g_parts) != len(r_parts):
        return ("lead", "arity %d vs %d" % (len(g_parts), len(r_parts)))
    worst = ("match", "")
    rank = {"match": 0, "lastulp": 1, "signzero": 2, "lead": 3}
    for gt, rt in zip(g_parts, r_parts):
        if gt == rt:
            continue
        # signed zero: F-0x0p+0 vs F0x0p+0
        gf, rf = _hexfloat(gt), _hexfloat(rt)
        if gf is not None and rf is not None:
            if gf == 0.0 and rf == 0.0:
                k = ("signzero", "%s vs %s" % (gt, rt))
            else:
                gap = abs(_ulp_key(gf) - _ulp_key(rf))
                if gap <= ulp_threshold:
                    k = ("lastulp", "ulp=%d" % gap)
                else:
                    k = ("lead", "ulp=%d (%s vs %s)" % (gap, gt, rt))
        else:
            # type tag mismatch (I vs F), nan-vs-finite, inf-vs-finite, etc.
            k = ("lead", "%s vs %s" % (gt, rt))
        if rank[k[0]] > rank[worst[0]]:
            worst = k
    return worst


# --- Harness ------------------------------------------------------------------

def ensure_golua():
    if os.path.exists(GOLUA):
        return
    if not os.path.isdir(GOLUA_REPO):
        sys.exit("golua checkout not found at %s — set GOLUA_REPO/GOLUA" % GOLUA_REPO)
    print("building golua from %s -> %s" % (GOLUA_REPO, GOLUA), file=sys.stderr)
    subprocess.run(["go", "build", "-o", GOLUA, "./cmd/lua"], cwd=GOLUA_REPO, check=True)


def process(cases, ulp_threshold):
    leads, counts = [], {"match": 0, "lastulp": 0, "signzero": 0, "lead": 0}
    for i in range(0, len(cases), BATCH):
        batch = cases[i:i + BATCH]
        src = build_driver(batch)
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
            f.write(src)
            path = f.name
        try:
            go_out, _, _ = run_lua(GOLUA, path)
            rf_out, _, _ = run_lua(REFLUA, path)
        finally:
            os.unlink(path)
        gd, rd = parse_lines(go_out), parse_lines(rf_out)
        for cid, expr, exact in batch:
            g, r = gd.get(cid), rd.get(cid)
            if g is None or r is None:
                leads.append("%s | %s | golua=%r ref=%r (MISSING)" % (cid, expr, g, r))
                counts["lead"] += 1
                continue
            gstatus, gpay = g
            rstatus, rpay = r
            if gstatus == "err" and rstatus == "err":
                if gpay == rpay:
                    counts["match"] += 1
                else:
                    counts["lead"] += 1
                    leads.append("%s | %s | ERRDIFF golua: %r | ref: %r" % (cid, expr, gpay, rpay))
                continue
            if gstatus != rstatus:
                counts["lead"] += 1
                leads.append("%s | %s | %s vs %s | golua: %r | ref: %r"
                             % (cid, expr, gstatus, rstatus, gpay, rpay))
                continue
            # Exact functions must be bit-identical; transcendental ones get the
            # ULP tolerance to absorb Go-math-vs-libm argument-reduction drift.
            tol = 0 if exact else ulp_threshold
            kind, detail = classify(gpay, rpay, tol)
            counts[kind] += 1
            if kind in ("lead", "signzero"):
                leads.append("%s | %s | %s %s | golua: %s | ref: %s"
                             % (cid, expr, kind.upper(), detail, gpay, rpay))
        print("  ...%d/%d cases, %d leads, %d lastulp"
              % (min(i + BATCH, len(cases)), len(cases),
                 counts["lead"] + counts["signzero"], counts["lastulp"]))
    return leads, counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ulp", type=int, default=64,
                    help="max ULP distance treated as platform libm drift for "
                         "TRANSCENDENTAL functions (exact functions always need "
                         "bit-identical results)")
    ap.add_argument("--lua54", action="store_true",
                    help="diff the lua_5_4_8 branch against lua5.4.8")
    ap.add_argument("--rand", type=int, default=0,
                    help="append N random hex-float doubles to the battery")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    if args.rand:
        RAND_INPUTS.extend(rand_double_literals(args.rand, args.seed))

    global GOLUA, REFLUA
    if args.lua54:
        sys.path.insert(0, os.path.dirname(HERE))
        import lua54
        GOLUA = lua54.ensure_golua54(GOLUA_REPO)
        REFLUA = os.environ.get("REFLUA", "lua5.4.8")
    else:
        ensure_golua()
    os.makedirs(CORPUS, exist_ok=True)

    cases = list(make_cases())
    print("math edge-case grind: %d cases, ulp_threshold=%d, ref=%s"
          % (len(cases), args.ulp, REFLUA))
    leads, counts = process(cases, args.ulp)

    print("\n=== %d leads (lead+signzero) | %d lastulp | %d match ==="
          % (counts["lead"] + counts["signzero"], counts["lastulp"], counts["match"]))
    report = os.path.join(CORPUS, "report.txt")
    with open(report, "w") as f:
        f.write("cases=%d ref=%s ulp_threshold=%d\n" % (len(cases), REFLUA, args.ulp))
        f.write("match=%d lastulp=%d signzero=%d lead=%d\n"
                % (counts["match"], counts["lastulp"], counts["signzero"], counts["lead"]))
        f.write("\n".join(leads))
    if leads:
        with open(os.path.join(CORPUS, "diff.txt"), "w") as f:
            f.write("\n".join(leads) + "\n")
        print("  wrote %d leads -> corpus/diff.txt" % len(leads))
    print("  report -> corpus/report.txt")
    sys.exit(1 if leads else 0)


if __name__ == "__main__":
    main()
