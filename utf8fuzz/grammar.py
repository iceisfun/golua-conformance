"""Case generators for the utf8 library: tiers 0-3.

A "case" is a dict:
  {"id": str, "subject": bytes, "ops": [op, ...]}
where each op is one of:
  ("char",  [cp, ...])             -> utf8.char(cp, ...)
  ("codepoint", i, j, lax)         -> utf8.codepoint(subject, i, j, lax)
  ("len",   i, j, lax)             -> utf8.len(subject, i, j, lax)
  ("offset", n, i)                 -> utf8.offset(subject, n, i)
  ("codes", lax)                   -> iterate for p,c in utf8.codes(subject[,lax])
  ("charpattern",)                 -> emit utf8.charpattern bytes

`i`/`j`/`n` may be None (omitted -> default). emit.py renders these.

Coverage rationale (see README): tier0 single-codepoint sweep of every fn over
the full 0..0x7FFFFFFF range incl the extended boundary; tier1 multi-codepoint
valid strings; tier2 the malformed/boundary byte table; tier3 random valid
sequences + random raw bytes. The lax flag and i/j/n index args are exercised
everywhere.
"""

import random
import values as V

NONE = None


def _cp_ops(lax_variants=(False, True)):
    """Standard op battery applied to a subject string."""
    ops = [("charpattern",)]
    for lax in lax_variants:
        # whole-string codepoint, len, codes
        ops.append(("codepoint", 1, -1, lax))
        ops.append(("len", 1, -1, lax))
        ops.append(("len", NONE, NONE, lax))
        ops.append(("codes", lax))
    return ops


def _offset_battery(slen):
    ops = []
    for n in [0, 1, 2, -1, -2, slen, slen + 1, -(slen + 1)]:
        ops.append(("offset", n, NONE))
    # n=0 special case from interior positions + negative i
    for i in [1, 2, -1, slen, slen + 1]:
        ops.append(("offset", 0, i))
        ops.append(("offset", 1, i))
        ops.append(("offset", -1, i))
    return ops


# --- Tier 0: each function over single codepoints across the range ------------

def tier0():
    """Single codepoint per subject, across the boundary table + every fn.

    Also tests utf8.char directly on each codepoint (incl illegal) and the
    extended-range boundary 0x10FFFF / 0x110000 / 0x7FFFFFFF / +1.
    """
    cases = []
    seen = set()
    cps = [c for c in V.CP_BOUNDARIES if not (c in seen or seen.add(c))]
    for k, cp in enumerate(cps):
        # direct utf8.char on this codepoint
        cases.append({"id": "t0char_%d" % k, "subject": b"",
                      "ops": [("char", [cp])]})
        # build the encoded byte string and run the full decode battery on it
        try:
            s = V._enc(cp)
        except ValueError:
            continue
        ops = _cp_ops()
        ops += _offset_battery(len(s))
        # round-trip char(codepoint(s)) handled as invariant inside the driver
        cases.append({"id": "t0_%d_%x" % (k, cp), "subject": s, "ops": ops})
    # illegal codepoints for utf8.char (must error on both)
    for k, cp in enumerate(V.CP_ILLEGAL):
        cases.append({"id": "t0bad_%d" % k, "subject": b"",
                      "ops": [("char", [cp])]})
    # the extended-range boundary cluster, explicit
    for k, cp in enumerate([0x10FFFF, 0x110000, 0x7FFFFFFF, 0x80000000]):
        cases.append({"id": "t0ext_%d" % k, "subject": b"",
                      "ops": [("char", [cp])]})
    return cases


# --- Tier 1: multi-codepoint valid strings ------------------------------------

def tier1():
    """Valid strings of 2..6 codepoints drawn from the boundary table.

    Exercises codes/len/codepoint/offset over real multibyte sequences and the
    offset-walking <-> codes consistency invariant.
    """
    cases = []
    rng = random.Random(0xC0DE)
    bset = [c for c in V.CP_BOUNDARIES if c <= V.MAXUNICODE and not (0xD800 <= c <= 0xDFFF)]
    idx = 0
    # deterministic small combos of boundary codepoints
    picks = [
        [0x41, 0x80, 0x7FF],
        [0x800, 0xFFFF, 0x41],
        [0x10000, 0x10FFFF, 0x80],
        [0x7F, 0x80, 0x7FF, 0x800, 0xFFFF, 0x10000, 0x10FFFF],
        [0x4E2D, 0x6587, 0x1F600],
        [0x00, 0x41, 0x00, 0x4E2D],   # embedded NUL
    ]
    for cps in picks:
        s = b"".join(V._enc(c) for c in cps)
        ops = _cp_ops()
        ops += _offset_battery(len(s))
        ops.append(("codepoint", 1, len(s), False))
        cases.append({"id": "t1_%d" % idx, "subject": s, "ops": ops})
        idx += 1
    # random valid strings (incl extended via lax) as a deterministic seed band
    for _ in range(120):
        s, _cps = V.rand_valid_string(rng, maxcps=6, allow_ext=rng.random() < 0.3)
        ops = _cp_ops()
        ops += _offset_battery(len(s))
        cases.append({"id": "t1r_%d" % idx, "subject": s, "ops": ops})
        idx += 1
    return cases


# --- Tier 2: boundary + malformed byte strings --------------------------------

def tier2():
    """The hand-curated malformed/boundary byte table x full op battery.

    This is the prime bug vein: overlong, surrogate, truncated, lone-cont,
    illegal lead bytes, and the lax flag's effect on each.
    """
    cases = []
    for k, s in enumerate(V.MALFORMED):
        ops = _cp_ops()
        ops += _offset_battery(len(s))
        # extra index-arg sweep on codepoint/len for this subject
        rng = random.Random(k)
        for i in V.index_args(rng, len(s)):
            for j in [None, -1, len(s)]:
                ops.append(("codepoint", i, j, False))
                ops.append(("codepoint", i, j, True))
                ops.append(("len", i, j, False))
                ops.append(("len", i, j, True))
        cases.append({"id": "t2_%d" % k, "subject": s, "ops": ops})
    return cases


# --- Tier 3: randomized long tail ---------------------------------------------

def tier3(seed, count):
    """Random VALID codepoint sequences (a) and random raw byte strings (b)."""
    rng = random.Random(seed)
    cases = []
    for n in range(count):
        if rng.random() < 0.5:
            # (a) valid codepoint sequence
            s, _cps = V.rand_valid_string(rng, maxcps=8, allow_ext=rng.random() < 0.4)
        else:
            # (b) random raw bytes (malformed-input decoding)
            s = V.rand_bytes(rng, maxlen=12)
        lax = (rng.random() < 0.5,)
        ops = _cp_ops(lax_variants=lax + (not lax[0],))
        slen = len(s)
        # random offset probes
        for _ in range(3):
            nn = rng.choice([0, 1, -1, rng.randint(-slen - 1, slen + 1)])
            ii = rng.choice([None] + V.index_args(rng, slen))
            ops.append(("offset", nn, ii))
        # random codepoint/len index probes
        for _ in range(2):
            ii = rng.choice([None] + V.index_args(rng, slen))
            jj = rng.choice([None] + V.index_args(rng, slen))
            lx = rng.random() < 0.5
            ops.append(("codepoint", ii, jj, lx))
            ops.append(("len", ii, jj, lx))
        cases.append({"id": "t3_%d" % n, "subject": s, "ops": ops})
    return cases
