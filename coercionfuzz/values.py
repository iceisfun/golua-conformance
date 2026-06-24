"""Operand model for the type-coercion / operator-semantics surface.

An *operand* is a small record describing a Lua value that we can splice into a
generated expression. Operands fall into two families:

  * PLAIN operands — a literal Lua expression (`nil`, `0`, `"abc"`, `{}`, …).
    These need no setup; the `expr` field is spliced directly.

  * MM operands — a table carrying a metatable with exactly one (or a chosen
    subset of) metamethod(s). Each metamethod returns a deterministic sentinel
    string so that *which* metamethod fired is observable in the canonical
    output. MM operands reference a builder declared in the driver prologue.

The whole game on this surface is ORDERING: string->number coercion vs which
operand's metamethod is tried first vs which error fires first. So the operand
set is chosen to make those orderings observable, not to be exhaustive over
values (that lives on the pack/format surfaces).
"""

import random


class Operand:
    """A splice-able Lua value.

    name  : short stable token used in case ids (no spaces / tabs)
    expr  : Lua source expression yielding the value
    mm    : None for plain operands, else the set of metamethod names present
    """
    __slots__ = ("name", "expr", "mm")

    def __init__(self, name, expr, mm=None):
        self.name = name
        self.expr = expr
        self.mm = mm  # None or frozenset of metamethod event names ("add", ...)

    def __repr__(self):
        return "Operand(%s)" % self.name


# --- Plain operand set --------------------------------------------------------
# Drawn EXACTLY from the surface spec: the nil/bool/number axis, the signed
# zero / NaN / Inf floats, the full string battery (numeric-coercible and not,
# whitespace, hex, hex-float, sign, leading zeros), and the reference types.

# (name, lua-expression)
_PLAIN_SPECS = [
    ("nil",      "nil"),
    ("true",     "true"),
    ("false",    "false"),
    ("i0",       "0"),
    ("i1",       "1"),
    ("im1",      "-1"),
    ("f0",       "0.0"),
    ("fm0",      "(-0.0)"),
    ("nan",      "(0/0)"),
    ("inf",      "(1/0)"),
    ("ninf",     "(-1/0)"),
    # string battery
    ("s_empty",  '""'),
    ("s_space",  '" "'),
    ("s_0",      '"0"'),
    ("s_00",     '"00"'),
    ("s_1",      '"1"'),
    ("s_m1",     '"-1"'),
    ("s_p1",     '"+1"'),
    # Signed-zero strings. The integer-first coercion rule (luaO_str2num) makes
    # an integer-parseable "-0" the integer 0 -> +0.0, NOT the float -0.0 a bare
    # ParseFloat yields. "-0.0"/"-0e0" are genuine floats and keep their sign.
    # This axis caught the math.* getNumber coercion bug (golua sqrt("-0")=-0).
    ("s_neg0",   '"-0"'),
    ("s_neg0ws", '"  -0  "'),
    ("s_neg0f",  '"-0.0"'),
    ("s_neg0e",  '"-0e0"'),
    ("s_pos0",   '"+0"'),
    ("s_1e3",    '"1e3"'),
    ("s_1e309",  '"1e309"'),
    ("s_0x10",   '"0x10"'),
    ("s_ws5",    '"  5  "'),
    ("s_0x1p4",  '"0x1p4"'),
    ("s_inf",    '"inf"'),
    ("s_nan",    '"nan"'),
    ("s_abc",    '"abc"'),
    # reference types (each is a *fresh* construction so == on two of them is
    # raw-unequal — the driver builds them once and reuses, see emit.py)
    ("table",    "REF_TABLE"),
    ("func",     "REF_FUNC"),
    ("thread",   "REF_THREAD"),
]

# A SECOND opaque reference of the same type, for the __eq / raw-equality axis
# (T1 == T2 with both tables). Built in the prologue.
_PLAIN_SECOND = [
    ("table2",   "REF_TABLE2"),
]


def plain_operands():
    out = [Operand(n, e) for (n, e) in _PLAIN_SPECS]
    out += [Operand(n, e) for (n, e) in _PLAIN_SECOND]
    return out


# Subset used as the *ranging* operand in tier1 (full set is large; for the
# metamethod dispatch matrix we range B over a representative slice that still
# covers coercible-string / non-coercible-string / number / reference).
def ranging_operands():
    keep = {"nil", "true", "i0", "i1", "f0", "nan", "inf",
            "s_1", "s_1e3", "s_0x10", "s_ws5", "s_abc", "s_empty",
            "table", "func", "thread", "table2"}
    return [op for op in plain_operands() if op.name in keep]


# --- Metamethod operand set ---------------------------------------------------
# Every arithmetic/bitwise/concat/compare/len/index metamethod, each returning a
# distinct observable sentinel. The driver prologue (emit.py) builds one table
# per single-metamethod operand plus a few multi-metamethod combos.

ARITH_MM = ["add", "sub", "mul", "div", "mod", "pow", "idiv", "unm"]
BIT_MM = ["band", "bor", "bxor", "bnot", "shl", "shr"]
CMP_MM = ["eq", "lt", "le"]
OTHER_MM = ["concat", "len", "index", "newindex"]

ALL_MM = ARITH_MM + BIT_MM + CMP_MM + OTHER_MM


def mm_single_operands():
    """One operand per single metamethod: table T with only that __mm."""
    return [Operand("mm_" + m, "MM_%s" % m, mm=frozenset([m])) for m in ALL_MM]


def mm_combo_operands():
    """A few multi-metamethod tables to test cross-axis dispatch."""
    combos = {
        "mm_full_arith": frozenset(ARITH_MM),
        "mm_full_bit":   frozenset(BIT_MM),
        "mm_cmp":        frozenset(CMP_MM),
        "mm_arith_cmp":  frozenset(ARITH_MM + CMP_MM),
        "mm_none":       frozenset(),   # bare table, metatable present but empty
    }
    return [Operand(n, "MM_%s" % n[3:].upper(), mm=s) for (n, s) in combos.items()]


# --- Operand lookup by name (used by tier3 random + ordering tier) ------------

def operand_index():
    idx = {}
    for op in plain_operands() + mm_single_operands() + mm_combo_operands():
        idx[op.name] = op
    return idx


# Convenience pools for the random tier.
def random_operand(rng, include_mm=True):
    pool = plain_operands()
    if include_mm and rng.random() < 0.45:
        pool = mm_single_operands() + mm_combo_operands()
    return rng.choice(pool)
