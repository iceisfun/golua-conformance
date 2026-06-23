"""FSM model of the string.format conversion-spec grammar.

A printf-style format string is a sequence of literal bytes and conversion
specifications of the shape:

    %  [flags]  [width]  [.precision]  conversion

This module enumerates conversions, their legal flag/width/precision ranges,
and the tier 0-3 generators plus an illegal tier that deliberately produces
specs the scanner must reject.

Confirmed against stdlib/string_format.go (the switch on specChar and the
validateConversion / validateFormatStructure / validateFormatWidthPrec checks)
and probed live against lua5.5.0.
"""

import random

# --- Conversion classification ------------------------------------------------

# Integer conversions: take a lua_Integer (or a number with an exact integer
# representation; or an integer-looking string via coercion).
INT_CONV = ["d", "i", "u", "o", "x", "X"]

# Float conversions: take a float (or any number, or a numeric string).
FLOAT_CONV = ["e", "E", "f", "F", "g", "G", "a", "A"]

# String conversion: takes anything (tostring-able); %s on a string/number/bool.
STR_CONV = ["s"]

# %c takes a char code (integer in 0..255 region; high bytes wrap to one byte).
CHAR_CONV = ["c"]

# %q produces a reloadable literal: strings, integers, floats, nil, true, false.
QUOTE_CONV = ["q"]

# %p prints a pointer. Its VALUE is nondeterministic, so it is excluded from the
# differential value tables; only its error/structure behaviour is portable.
PTR_CONV = ["p"]

# %% is a literal percent (no argument).
LITERAL_CONV = ["%"]

ALL_CONV = INT_CONV + FLOAT_CONV + STR_CONV + CHAR_CONV + QUOTE_CONV

# Flags Lua accepts (validateConversion gates which flags pair with which conv).
FLAGS = ["-", "+", " ", "#", "0"]

# Lua requires width/precision < 100 (validateFormatWidthPrec). 0..99 legal.
LEGAL_WIDTHS = [0, 1, 2, 5, 8, 10, 20, 99]
ILLEGAL_WIDTHS = [100, 123, 999]
LEGAL_PRECS = [0, 1, 2, 5, 6, 17, 99]
ILLEGAL_PRECS = [100, 200]

# Which flags are LEGAL with which conversion (per reference printf rules that
# Lua inherits). Used only to bias tier1 toward accepted combos; the illegal
# tier deliberately violates these. Empirically (probed): %#d %+s %+u % o etc.
# are rejected as "invalid conversion specification".
LEGAL_FLAGS = {
    "d": "-+ 0", "i": "-+ 0", "u": "-0",
    "o": "-#0", "x": "-#0", "X": "-#0",
    "e": "-+ #0", "E": "-+ #0", "f": "-+ #0", "F": "-+ #0",
    "g": "-+ #0", "G": "-+ #0", "a": "-+ #0", "A": "-+ #0",
    "s": "-", "c": "-", "q": "",
}


def _spec(flags, width, prec, conv):
    w = "" if width is None else str(width)
    p = "" if prec is None else "." + str(prec)
    return "%" + flags + w + p + conv


# --- Tier 0: each conversion bare + each single flag + a width + a precision ---

def tier0():
    """Branch coverage of the spec scanner, one knob at a time."""
    out = []
    out.append("%%")  # the literal-percent path
    for conv in ALL_CONV:
        legal = LEGAL_FLAGS.get(conv, "")
        out.append("%" + conv)                          # bare
        for fl in FLAGS:
            out.append("%" + fl + conv)                 # single flag (legal+illegal)
        out.append("%5" + conv)                         # a width
        out.append("%.2" + conv)                        # a precision
        out.append("%8.3" + conv)                       # width + precision
        # one accepted left-justify + width combo per conv
        if "-" in legal:
            out.append("%-8" + conv)
    return _dedup(out)


# --- Tier 1: flag-combos x width x precision per conversion --------------------

def _flag_combos(allowed):
    """All subsets (size 0..len) of the allowed flag chars, as strings."""
    combos = [""]
    chars = list(allowed)
    for i in range(len(chars)):
        for j in range(i + 1, len(chars) + 1):
            combos.append("".join(chars[i:j]))
    # also a couple of explicit multi-flag orderings that exercise ordering
    if "-" in allowed and "0" in allowed:
        combos.append("-0")
        combos.append("0-")
    if "+" in allowed and "#" in allowed:
        combos.append("+#")
        combos.append("#+")
    return _dedup(combos)


def tier1():
    """Legal flag-combos crossed with widths and precisions, per conversion."""
    out = []
    widths = [None, 0, 1, 6, 10, 20]
    precs = [None, 0, 1, 2, 6, 12]
    for conv in ALL_CONV:
        allowed = LEGAL_FLAGS.get(conv, "")
        for fl in _flag_combos(allowed):
            for w in widths:
                for p in precs:
                    out.append(_spec(fl, w, p, conv))
    return _dedup(out)


# --- Tier 2: value-domain stress (handled in values.py) ------------------------

def tier2():
    """A focused set of plain specs whose VALUES are stressed by values.py.

    The interesting axis in tier2 is the argument, not the spec, so we keep the
    specs simple but cover the precision/flag knobs that interact with extreme
    values (signed zero, inf/nan, subnormals, embedded NUL, long strings).
    """
    out = []
    for conv in INT_CONV:
        out += ["%" + conv, "%5" + conv, "%.0" + conv, "%08" + conv, "%-8" + conv]
        if conv in "oxX":
            out += ["%#" + conv, "%#08" + conv]
    for conv in FLOAT_CONV:
        out += ["%" + conv, "%.0" + conv, "%.17" + conv, "%+." + "6" + conv,
                "%020." + "10" + conv, "%#" + conv, "% " + conv, "%-15." + "3" + conv]
    for conv in STR_CONV:
        out += ["%s", "%.0s", "%.3s", "%10s", "%-10s", "%.20s"]
    for conv in CHAR_CONV:
        out += ["%c", "%5c", "%-5c"]
    for conv in QUOTE_CONV:
        out += ["%q"]
    return _dedup(out)


# --- Tier 3: random format strings paired with random typed args ---------------

def _rand_spec(rng):
    conv = rng.choice(ALL_CONV + PTR_CONV)
    allowed = LEGAL_FLAGS.get(conv, "-+ #0")  # ptr: allow anything, scanner decides
    flags = ""
    if rng.random() < 0.7:
        k = rng.randint(1, max(1, len(allowed)))
        flags = "".join(rng.sample(allowed, min(k, len(allowed)))) if allowed else ""
    width = None
    if rng.random() < 0.6:
        width = rng.choice(LEGAL_WIDTHS) if rng.random() < 0.9 else rng.choice(ILLEGAL_WIDTHS)
    prec = None
    if rng.random() < 0.5:
        prec = rng.choice(LEGAL_PRECS) if rng.random() < 0.9 else rng.choice(ILLEGAL_PRECS)
    return _spec(flags, width, prec, conv)


def tier3(seed, count, minparts=1, maxparts=4):
    """Random multi-conversion format strings (with literal text interspersed)."""
    rng = random.Random(seed)
    out = []
    lit = ["", " ", "x", "[", "]", "::", "\\n", "%%", "ab"]
    for _ in range(count):
        n = rng.randint(minparts, maxparts)
        parts = []
        for _ in range(n):
            if rng.random() < 0.4:
                parts.append(rng.choice(lit))
            parts.append(_rand_spec(rng))
        out.append("".join(parts))
    return _dedup(out)


# --- Illegal tier: specs the scanner must reject ------------------------------

def illegal():
    """Deliberately malformed specs and arg-mismatches (error-parity surface).

    Cases here mostly produce errors; the differential layer compares error
    wording. Some are arg-mismatches handled by values.py via marker formats.
    """
    out = []
    # unknown conversions
    for c in "ywYbWvkSnLh":
        out.append("%" + c)
    # bare percent at end / percent then space
    out += ["%", "% ", "abc%", "%%%"]
    # length modifiers (C-only, Lua rejects)
    out += ["%hd", "%ld", "%lld", "%Lf", "%hhd", "%zd", "%jd", "%td"]
    # positional / star (Lua does not support either)
    out += ["%*d", "%.*f", "%2$d", "%1$s"]
    # oversized width / precision
    for w in ILLEGAL_WIDTHS:
        out.append("%%%dd" % w)
    for p in ILLEGAL_PRECS:
        out.append("%%.%df" % p)
    # illegal flag/conv combos (probed: all rejected)
    out += ["%#d", "%#i", "%#s", "%#c", "%+s", "%+u", "%+c", "% s", "% c",
            "% u", "%0s", "%0c", "%#u"]
    # precision where it is meaningless on %c / %p / %q
    out += ["%.2c", "%.2p", "%.2q", "%1q", "%-q", "%+q", "%#q"]
    # double dot / trailing dot oddities
    out += ["%..2f", "%2.f", "%.f"]
    # --- known parity divergences (kept as deterministic regression cases) ---
    # %F with an oversized width/precision: reference rejects %F as an unknown
    # conversion FIRST ("...to 'format'"); golua's global width<100 check fires
    # first ("invalid conversion specification"). %F bare already matches.
    out += ["%100F", "%123F", "%5.100F", "%.100F", "%-#999F"]
    # %s with an oversized width/precision AND a NUL-containing argument:
    # reference reports "string contains zeros" (arg check first); golua reports
    # the width-spec error first. values.py feeds a NUL string for these via the
    # 'nul' band — the illegal baseline alone is NUL-free, so these need a clean
    # string too; the differential fires only on the NUL-arg variant.
    out += ["%100s", "%.100s", "%-100.2s", "%999.5s"]
    return _dedup(out)


# Format strings whose %s/%F divergence only shows with a specific argument.
# illegal-mode baseline is NUL-free, so expose the %s-zeros family explicitly.
NUL_STRING_FORMATS = ["%100s", "%.100s", "%-100.2s", "%999.5s"]


def _dedup(seq):
    seen = set()
    res = []
    for x in seq:
        if x not in seen:
            seen.add(x)
            res.append(x)
    return res
