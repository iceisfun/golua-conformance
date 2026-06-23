"""Per-directive boundary value tables and format-string slot parsing.

Format is one axis of the search; value boundaries are where the non-structural
bugs hide. For each data slot in a format we draw from a boundary set keyed by
the slot's kind and byte width.

Values are emitted as tagged tuples consumed by emit.py:
  ('int',   python_int)            # rendered as a wrapping Lua hex integer
  ('float', python_float | str)    # str in {'nan','+inf','-inf','-0'}
  ('str',   bytes)
"""

import random

INT64_MAX = (1 << 63) - 1
INT64_MIN = -(1 << 63)


def _native_width(d):
    return {
        "b": 1, "B": 1,
        "h": 2, "H": 2,
        "l": 8, "L": 8,
        "j": 8, "J": 8,
        "T": 8,
    }[d]


class Slot:
    __slots__ = ("kind", "width", "signed")

    def __init__(self, kind, width=0, signed=True):
        self.kind = kind        # 'int' | 'float32' | 'float64' | 'cstr' | 'sstr' | 'zstr'
        self.width = width
        self.signed = signed

    def __repr__(self):
        return f"Slot({self.kind},w={self.width},s={self.signed})"


def parse_slots(fmt):
    """Walk a format string and return the ordered list of value-consuming slots.

    Mirrors the scanner in stdlib/string_pack.go: control/align/pad directives
    and X-targets consume no value.
    """
    slots = []
    i = 0
    n = len(fmt)
    while i < n:
        c = fmt[i]
        i += 1
        if c in " <>=":
            continue
        if c == "!":
            i = _skip_num(fmt, i)
            continue
        if c == "x":
            continue
        if c == "X":
            # X consumes the following directive as an alignment reference;
            # that directive packs no data.
            if i < n:
                t = fmt[i]
                i += 1
                if t in "iI":
                    i = _skip_num(fmt, i)
            continue
        if c in "bBhHlLjJT":
            slots.append(Slot("int", _native_width(c), c.islower()))
            continue
        if c in "iI":
            w, i = _read_num(fmt, i, default=8)
            slots.append(Slot("int", w, c == "i"))
            continue
        if c == "f":
            slots.append(Slot("float32", 4))
            continue
        if c in "dn":
            slots.append(Slot("float64", 8))
            continue
        if c == "c":
            w, i = _read_num(fmt, i, default=None)
            slots.append(Slot("cstr", w if w is not None else -1))
            continue
        if c == "s":
            w, i = _read_num(fmt, i, default=8)
            slots.append(Slot("sstr", w))
            continue
        if c == "z":
            slots.append(Slot("zstr", 0))
            continue
        # unknown char: ignore (the interpreter will error; no value consumed)
    return slots


def _skip_num(fmt, i):
    while i < len(fmt) and fmt[i].isdigit():
        i += 1
    return i


def _read_num(fmt, i, default):
    j = i
    while j < len(fmt) and fmt[j].isdigit():
        j += 1
    if j == i:
        return default, i
    return int(fmt[i:j]), j


# --- Boundary value generators -------------------------------------------------

def _int_boundaries(width, signed, rng):
    vals = [0, 1, -1]
    if width < 1 or width >= 8:
        # illegal/huge widths: format errors before the value matters; the
        # >=8 boundaries are safe int64 sentinels.
        vals += [INT64_MAX, INT64_MIN, rng.randint(INT64_MIN, INT64_MAX)]
    else:
        bits = 8 * width
        umax = (1 << bits) - 1
        smax = (1 << (bits - 1)) - 1
        smin = -(1 << (bits - 1))
        if signed:
            vals += [smax, smin, smax + 1, smin - 1, rng.randint(smin, smax)]
        else:
            vals += [umax, umax + 1, rng.randint(0, umax)]
    # clamp to representable int64 literal range (we render as hex wrap)
    return [v for v in vals if INT64_MIN <= v <= INT64_MAX]


def _float_boundaries(is32):
    base = ["-0", 0.0, 1.0, -1.0, "+inf", "-inf", "nan", 3.14159265358979]
    if is32:
        base += [3.4028234663852886e38, 1.401298464324817e-45]   # f32 max / min subnormal
    else:
        base += [1.7976931348623157e308, 5e-324, 2.2250738585072014e-308]
    return base


def _str_value(length, embed_nul, rng):
    if length <= 0:
        return b""
    body = bytes(rng.randint(0, 255) if embed_nul else rng.randint(1, 255)
                 for _ in range(min(length, 4096)))
    if length > 4096:
        body = body * (length // 4096 + 1)
        body = body[:length]
    return body


# A "profile" selects one boundary index-band across all slots so we get a
# handful of coherent tuples instead of the full cross-product.
PROFILES = ["min", "max", "neg", "special", "rand"]


def value_tuples(fmt, rng, profiles=PROFILES):
    """Yield a list of value-tuples (each a list of tagged values) for a format."""
    slots = parse_slots(fmt)
    if not slots:
        return [[]]
    out = []
    for prof in profiles:
        tup = []
        bad = False
        for s in slots:
            v = _slot_value(s, prof, rng)
            if v is None:
                bad = True
                break
            tup.append(v)
        if not bad:
            out.append(tup)
    # de-dup identical tuples
    uniq = []
    seen = set()
    for t in out:
        key = repr(t)
        if key not in seen:
            seen.add(key)
            uniq.append(t)
    return uniq


def _slot_value(slot, prof, rng):
    k = slot.kind
    if k == "int":
        b = _int_boundaries(slot.width, slot.signed, rng)
        idx = {"min": 0, "max": -2 if len(b) > 2 else 0, "neg": 2,
               "special": 1, "rand": -1}.get(prof, 0)
        return ("int", b[idx % len(b)])
    if k in ("float32", "float64"):
        b = _float_boundaries(k == "float32")
        idx = {"min": 1, "max": 8 if len(b) > 8 else 0, "neg": 3,
               "special": 6, "rand": 7}.get(prof, 0)
        return ("float", b[idx % len(b)])
    if k == "cstr":
        if slot.width < 0:
            return None   # missing size -> format itself errors; no value
        return ("str", _str_value(slot.width, embed_nul=True, rng=rng))
    if k == "sstr":
        length = {"min": 0, "max": 64, "neg": 1, "special": 255, "rand": rng.randint(0, 32)}.get(prof, 0)
        return ("str", _str_value(length, embed_nul=True, rng=rng))
    if k == "zstr":
        length = {"min": 0, "max": 32, "neg": 1, "special": 8, "rand": rng.randint(0, 24)}.get(prof, 0)
        # z stops at first NUL on unpack; keep these NUL-free so round-trip holds
        return ("str", _str_value(length, embed_nul=False, rng=rng))
    return None
