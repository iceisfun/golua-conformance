"""Per-conversion argument typing + boundary value tables for string.format.

Each conversion in a format string consumes (usually) one argument of a given
kind. This module walks the format string, classifies each conversion's
argument slot, and draws boundary values keyed by slot kind. It also produces
DELIBERATELY wrong-typed argument tuples for the illegal/error tier.

Values are emitted as tagged tuples consumed by emit.py:
  ('int',   python_int)
  ('float', python_float | str)   # str in {'nan','+inf','-inf','-0'}
  ('str',   bytes)
  ('bool',  True|False)
  ('nil',   None)
  ('none',  None)                 # MISSING argument (omit it entirely)
"""

import random

INT64_MAX = (1 << 63) - 1
INT64_MIN = -(1 << 63)


# --- Format-string slot parsing -----------------------------------------------

def parse_convs(fmt):
    """Return the ordered list of conversion characters that consume an arg.

    '%%' consumes nothing. We stop classification at the conversion byte and do
    not validate flags/width here (the interpreters do that). Length-modifier
    and unknown bytes are returned as their raw conversion char so the value
    layer can still feed *a* value (the spec will error first, which is fine —
    error parity is what we test there).
    """
    convs = []
    i = 0
    n = len(fmt)
    while i < n:
        if fmt[i] != "%":
            i += 1
            continue
        i += 1
        if i >= n:
            convs.append("END")          # trailing '%'
            break
        # skip flags
        while i < n and fmt[i] in "-+ #0":
            i += 1
        # skip width digits (and the '*' star marker)
        while i < n and (fmt[i].isdigit() or fmt[i] == "*"):
            i += 1
        # skip precision
        if i < n and fmt[i] == ".":
            i += 1
            while i < n and (fmt[i].isdigit() or fmt[i] == "*"):
                i += 1
        if i >= n:
            convs.append("END")
            break
        c = fmt[i]
        i += 1
        if c == "%":
            continue                      # literal percent, no arg
        convs.append(c)
    return convs


# Conversion -> argument slot kind.
def _slot_kind(conv):
    if conv in "diuoxX":
        return "int"
    if conv in "eEfFgGaA":
        return "float"
    if conv == "s":
        return "str"
    if conv == "c":
        return "char"
    if conv == "q":
        return "quote"
    if conv == "p":
        return "ptr"
    # unknown / length-modifier / END: spec errors before consuming; still feed
    # an int so a "no value" error doesn't mask the spec error.
    return "int"


# --- Boundary value generators ------------------------------------------------

INT_BOUNDARIES = [0, 1, -1, 42, INT64_MAX, INT64_MIN, 255, 256, -255]


def _int_value(prof, rng):
    table = {
        "min": INT64_MIN, "max": INT64_MAX, "neg": -1, "zero": 0,
        "one": 1, "small": 42, "byte": 255, "rand": rng.choice(INT_BOUNDARIES),
    }
    return ("int", table.get(prof, 0))


FLOAT_BOUNDARIES = ["-0", 0.0, 1.0, -1.0, "+inf", "-inf", "nan",
                    3.141592653589793, 1.7976931348623157e308, 5e-324,
                    2.2250738585072014e-308, 1e-300, 1e300, 99.99995, 9.999995e-05]


def _float_value(prof, rng):
    table = {
        "min": 5e-324, "max": 1.7976931348623157e308, "neg": -1.0,
        "zero": 0.0, "one": 1.0, "special": "nan", "inf": "+inf",
        "negzero": "-0", "pi": 3.141592653589793,
        "rand": rng.choice(FLOAT_BOUNDARIES),
    }
    return ("float", table.get(prof, 1.0))


def _str_value(prof, rng):
    if prof == "empty":
        return ("str", b"")
    if prof == "ascii":
        return ("str", b"hello")
    if prof == "high":
        return ("str", bytes([0x80, 0xff, 0xc3, 0xa9, 0x7f, 0x01]))
    if prof == "long":
        return ("str", bytes((i % 95) + 32 for i in range(300)))
    if prof == "nul":
        return ("str", b"a\x00b")        # embedded NUL: %s errors "contains zeros"
    return ("str", bytes(rng.randint(1, 255) for _ in range(rng.randint(0, 16))))


# %c wants a byte code; high/negative wrap to one byte in Lua.
def _char_value(prof, rng):
    table = {"zero": 0, "A": 65, "byte": 255, "over": 256, "neg": -1,
             "rand": rng.randint(-300, 600)}
    return ("int", table.get(prof, 65))


# %q must round-trip; cover all reloadable kinds.
QUOTE_VALUES = [
    ("str", b""), ("str", b"abc"), ("str", b'"\\\n\r\t'),
    ("str", b"a\x00b\x01"), ("str", bytes([0x80, 0xff, 0x7f])),
    ("int", 0), ("int", 1), ("int", -1), ("int", INT64_MAX), ("int", INT64_MIN),
    ("float", 3.141592653589793), ("float", "+inf"), ("float", "-inf"),
    ("float", "nan"), ("float", "-0"), ("float", 1.0), ("float", 5e-324),
    ("bool", True), ("bool", False), ("nil", None),
]


# Profiles drive coherent tuples (one band per call) instead of full crossproduct.
PROFILES = {
    "int": ["zero", "one", "neg", "max", "min", "byte", "rand"],
    "float": ["zero", "one", "neg", "pi", "inf", "special", "negzero", "min", "max", "rand"],
    "str": ["empty", "ascii", "high", "long", "nul", "rand"],
    "char": ["zero", "A", "byte", "over", "neg", "rand"],
}


def value_tuples(fmt, rng, illegal=False):
    """Yield value-tuples (each a list of tagged values) for one format string.

    Normal mode: per-conversion boundary bands.
    illegal mode: feed deliberately WRONG-typed args + a missing-arg variant.
    """
    convs = parse_convs(fmt)
    if not convs:
        return [[]]
    kinds = [_slot_kind(c) for c in convs]

    if illegal:
        return _illegal_tuples(kinds, rng)

    # %q: enumerate the reloadable-value matrix one value per tuple.
    if any(k == "quote" for k in kinds):
        return _quote_tuples(kinds, rng)

    # choose a set of profile-bands shared across slots
    out = []
    seen = set()
    bands = 7
    for b in range(bands):
        tup = []
        for k in kinds:
            tup.append(_value_for(k, b, rng))
        key = repr(tup)
        if key not in seen:
            seen.add(key)
            out.append(tup)
    return out


def _value_for(kind, band, rng):
    if kind == "ptr":
        # %p value is nondeterministic; feed a string so it has something, and
        # emit.py marks the case ptr so run.py skips the value diff.
        return ("str", b"x")
    profs = PROFILES.get(kind)
    if not profs:
        return _int_value("rand", rng)
    prof = profs[band % len(profs)]
    if kind == "int":
        return _int_value(prof, rng)
    if kind == "float":
        return _float_value(prof, rng)
    if kind == "str":
        return _str_value(prof, rng)
    if kind == "char":
        return _char_value(prof, rng)
    return _int_value("rand", rng)


def _quote_tuples(kinds, rng):
    out = []
    for qv in QUOTE_VALUES:
        tup = []
        for k in kinds:
            if k == "quote":
                tup.append(qv)
            else:
                tup.append(_value_for(k, 0, rng))
        out.append(tup)
    return out


# --- Illegal / wrong-type argument tuples -------------------------------------

# For each slot kind, the "wrong" value(s) that should error (or, where Lua
# coerces, agree on coercion). The differential layer checks both interpreters
# react identically.
_WRONG = {
    "int": [("float", 3.5), ("str", b"abc"), ("bool", True), ("nil", None),
            ("str", b"")],
    "float": [("str", b"abc"), ("bool", True), ("nil", None)],
    # %s accepts anything via tostring, EXCEPT a string with an embedded NUL,
    # which errors "string contains zeros" — and that arg-check ordering vs the
    # oversized-width check is itself a parity surface, so feed a NUL string.
    "str": [("str", b"a\x00b")],
    "char": [("float", 3.5), ("str", b"x"), ("nil", None)],
    "quote": [],                     # %q handled separately
    "ptr": [],
}


def _illegal_tuples(kinds, rng):
    out = []
    # 1) all-correct baseline (so a pure-spec error is exercised with a valid arg)
    base = [_value_for(k, 0, rng) for k in kinds]
    out.append(list(base))
    # 2) one wrong-typed arg per slot (where a wrong type exists)
    for idx, k in enumerate(kinds):
        for wrong in _WRONG.get(k, []):
            tup = list(base)
            tup[idx] = wrong
            out.append(tup)
    # 3) missing argument: drop the last arg entirely
    if kinds:
        miss = list(base[:-1])
        miss.append(("none", None))
        out.append(miss)
        # also: provide ZERO args
        out.append([("none", None) for _ in kinds])
    # de-dup
    uniq = []
    seen = set()
    for t in out:
        key = repr(t)
        if key not in seen:
            seen.add(key)
            uniq.append(t)
    return uniq
