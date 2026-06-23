"""FSM model of the string.pack format grammar.

The pack format string is a small regular grammar with bounded numeric
arguments. This module enumerates directives, their legal argument ranges, and
the tier 0-2 deterministic enumerators plus a tier-3 random generator.

Confirmed against stdlib/string_pack.go (four parallel switch copies:
pack, unpack, packsize x2).
"""

import random

# --- Directive classification -------------------------------------------------

# Control directives: change parser state, emit/consume no data.
CONTROL = ["<", ">", "=", " "]

# Fixed-size data directives (no argument). Each consumes/produces one value.
# native sizes per the platform golua targets (amd64/linux LP64):
#   h/H = 2, l/L = 8, j/J = 8, T = 8, f = 4, d/n = 8, b/B = 1
FIXED_DATA = ["b", "B", "h", "H", "l", "L", "j", "J", "T", "f", "d", "n"]

# Sized integer directives: i[n] / I[n], n in [1,16], default native (8).
INT_SIZED = ["i", "I"]

# String-prefix directive: s[n], n in [1,16], default size_t (8).
STR_SIZED = ["s"]

# Variable / special data directives.
VAR_SPECIAL = ["z", "x"]  # z = zero-term string, x = one pad byte

# 'c' requires an explicit size: c<n>, n >= 0.
CHAR_FIXED = ["c"]

# Alignment directives.
ALIGN_SET = ["!"]  # !n, n in [1,16], optional
ALIGN_X = ["X"]    # Xop, op = a following fixed-size directive

# Every "operand" directive usable as the target of X (must be fixed-size).
# X needs an option that has a known alignment > 0 and is not variable-size.
X_TARGETS = FIXED_DATA + ["i", "I"]  # i/I take an optional size after them

LEGAL_SIZE = list(range(1, 17))   # [1,16] for i/I/s/!
ILLEGAL_SIZE = [0, 17, 18, 99]    # hit the "out of limits" panic

# --- Tier 0: every directive in isolation, legal + illegal ---------------------

def tier0():
    """Single directive across its full legal arg range, plus illegal args.

    Pure branch coverage of the scanner. Yields format strings.
    """
    out = []
    # control + fixed + var/special: bare token
    for d in CONTROL + FIXED_DATA + VAR_SPECIAL:
        if d == " ":
            continue
        out.append(d)
    # i/I/s across legal sizes and bare (default size)
    for d in INT_SIZED + STR_SIZED:
        out.append(d)  # bare -> default native size
        for n in LEGAL_SIZE:
            out.append(f"{d}{n}")
        for n in ILLEGAL_SIZE:
            out.append(f"{d}{n}")  # -> "integral size out of limits"
    # c<n>: legal sizes incl 0, plus the missing-size error
    out.append("c")          # -> "missing size for format option 'c'"
    for n in [0, 1, 2, 3, 7, 8, 16, 255]:
        out.append(f"c{n}")
    # !n: legal, illegal, and bare
    out.append("!")          # bare -> native max align
    for n in LEGAL_SIZE:
        out.append(f"!{n}")
    for n in ILLEGAL_SIZE:
        out.append(f"!{n}")  # -> out of limits
    # Xop: every legal target + the error branches
    for t in X_TARGETS:
        out.append(f"X{t}")
    out.append("X")          # -> invalid next option (absent)
    out.append("Xz")         # -> invalid next option (variable size)
    out.append("Xs")         # -> invalid next option (variable size)
    out.append("Xc")         # X then c with no size
    out.append("Xx")         # x is fine? padding has align 1
    return dedup(out)


# --- Tier 1: alignment matrix --------------------------------------------------

def tier1():
    """!A . op1 . op2 triples — padding insertion between adjacent fields.

    The richest vein: differently-aligned neighbours force padding bytes.
    """
    aligns = ["", "!", "!1", "!2", "!4", "!8", "!16"]
    ops = ["b", "h", "i3", "i4", "i8", "l", "j", "T", "f", "d", "c1", "c3", "s", "z", "x"]
    out = []
    for a in aligns:
        for o1 in ops:
            for o2 in ops:
                out.append(f"{a}{o1}{o2}")
    # Xop alignment references interleaved
    for a in ["!8", "!4", ""]:
        for xt in ["Xi8", "Xd", "Xh", "Xf"]:
            for o in ["b", "i4", "d", "c1"]:
                out.append(f"{a}{xt}{o}b")
    return dedup(out)


# --- Tier 2: endian transitions ------------------------------------------------

def tier2():
    """< > = interleaved with multi-byte data to exercise endian state changes."""
    endians = ["<", ">", "="]
    multibyte = ["h", "i2", "i4", "i8", "j", "T", "f", "d", "s2", "I3"]
    out = []
    # single transition: E1 op E2 op
    for e1 in endians:
        for d1 in multibyte:
            for e2 in endians:
                for d2 in ["h", "i4", "d", "I3"]:
                    out.append(f"{e1}{d1}{e2}{d2}")
    # triple transitions on one field type
    for d in ["i4", "d", "j"]:
        for combo in [("<", ">", "="), (">", "<", ">"), ("=", "<", ">")]:
            out.append(f"{combo[0]}{d}{combo[1]}{d}{combo[2]}{d}")
    return dedup(out)


# --- Tier 3: randomized long tail ---------------------------------------------

def _rand_directive(rng):
    bucket = rng.randint(0, 6)
    if bucket == 0:
        return rng.choice(FIXED_DATA)
    if bucket == 1:
        return rng.choice(INT_SIZED) + (str(rng.randint(1, 16)) if rng.random() < 0.8 else "")
    if bucket == 2:
        return "s" + (str(rng.randint(1, 16)) if rng.random() < 0.6 else "")
    if bucket == 3:
        return "c" + str(rng.randint(0, 12))
    if bucket == 4:
        return rng.choice(["z", "x"])
    if bucket == 5:
        return rng.choice(["<", ">", "=", " "])
    # alignment ops
    if rng.random() < 0.5:
        return "!" + (str(rng.randint(1, 16)) if rng.random() < 0.7 else "")
    return "X" + rng.choice(X_TARGETS)


def tier3(seed, count, minlen=4, maxlen=12):
    """Random legal directive strings, property-checked against invariants."""
    rng = random.Random(seed)
    out = []
    for _ in range(count):
        n = rng.randint(minlen, maxlen)
        out.append("".join(_rand_directive(rng) for _ in range(n)))
    return out


def dedup(seq):
    seen = set()
    res = []
    for x in seq:
        if x not in seen:
            seen.add(x)
            res.append(x)
    return res
