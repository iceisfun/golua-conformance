"""Operator/context model + tier enumerators for the coercion surface.

A *case* is a dict the emitter turns into one canonical-output line:

  {"id": ..., "kind": "binop", "op": "+", "a": <Operand>, "b": <Operand>}
  {"id": ..., "kind": "unop",  "op": "-", "a": <Operand>}
  {"id": ..., "kind": "index_get", "a": <Operand>}          -- t[a]
  {"id": ..., "kind": "index_set", "a": <Operand>}          -- t[a] = 1
  {"id": ..., "kind": "key_norm",  "a": <Operand>}          -- t[a]=1; ret t[a']
  {"id": ..., "kind": "fornum", "a","b","c": <Operand>}     -- for i=a,b,c
  {"id": ..., "kind": "lib", "call": "<lua-with-{X}>", "a": <Operand>}

The emitter (emit.py) is responsible for splicing operands and wrapping in the
pcall/canonicalize harness. grammar.py only decides WHICH combinations to test.

ORDERING is the whole point of this surface, so tier1 (one metamethod operand vs
a ranging plain operand) and the dedicated `ordering()` tier are the high-value
parts; tier0 is the exhaustive plain×plain×op backbone.
"""

import random

import values as V

# --- Operator tables ----------------------------------------------------------

ARITH = ["+", "-", "*", "/", "%", "//", "^"]
BITWISE = ["&", "|", "~", "<<", ">>"]          # binary ~ is bxor
COMPARE = ["<", "<=", ">", ">=", "==", "~="]
CONCAT = [".."]
BINOPS = ARITH + BITWISE + COMPARE + CONCAT

# Unary: token + the Lua surface form (operand spliced as {A}).
UNOPS = [
    ("unm", "-({A})"),
    ("len", "#({A})"),
    ("bnot", "~({A})"),
    ("not", "not ({A})"),
]

# Library coercion contexts. {X} is the single operand splice point. These probe
# whether the library coerces its string/number argument the same way both
# interpreters do (and error wording when it can't).
LIB_CALLS = [
    ("math.abs",   "math.abs({X})"),
    ("math.floor", "math.floor({X})"),
    ("math.ceil",  "math.ceil({X})"),
    ("math.sqrt",  "math.sqrt({X})"),
    ("math.max2",  "math.max({X}, 0)"),
    ("math.min2",  "math.min(0, {X})"),
    ("math.tointeger", "math.tointeger({X})"),
    ("math.type",  "math.type({X})"),
    ("strrep",     "string.rep({X}, 2)"),
    ("strsub",     "string.sub({X}, 1, 2)"),
    ("strlen",     "string.len({X})"),
    ("strbyte",    "string.byte({X})"),
    ("strupper",   "string.upper({X})"),
    ("strformat_d", 'string.format("%d", {X})'),
    ("strformat_s", 'string.format("%s", {X})'),
    ("tonumber",   "tonumber({X})"),
    ("tonumber16", "tonumber({X}, 16)"),
    ("tostring",   "tostring({X})"),
]


def _mk(seq, kind, opfield="op"):
    out = []
    for x in seq:
        out.append(x)
    return out


# --- Tier 0: full plain × plain × binop, plus plain unops ---------------------

def tier0():
    cases = []
    plains = V.plain_operands()
    cid = 0
    for op in BINOPS:
        for a in plains:
            for b in plains:
                cases.append({"id": "t0_%d" % cid, "kind": "binop",
                              "op": op, "a": a, "b": b})
                cid += 1
    for tok, _form in UNOPS:
        for a in plains:
            cases.append({"id": "t0_%d" % cid, "kind": "unop",
                          "op": tok, "a": a})
            cid += 1
    return cases


# --- Tier 1: metamethod dispatch matrix --------------------------------------
# One operand is a metatable'd table (single relevant metamethod); the other
# ranges over a representative slice. Tests: dispatch fires? which side? raw
# operands passed (not coerced)? error vs metamethod precedence?

# Which binops a single-metamethod table is *expected* to handle, so we focus
# the matrix (still also test irrelevant pairings to confirm error precedence).
_OP_FOR_MM = {
    "add": "+", "sub": "-", "mul": "*", "div": "/", "mod": "%",
    "pow": "^", "idiv": "//",
    "band": "&", "bor": "|", "bxor": "~", "shl": "<<", "shr": ">>",
    "lt": "<", "le": "<=", "eq": "==", "concat": "..",
}


def tier1():
    cases = []
    mm_ops = V.mm_single_operands() + V.mm_combo_operands()
    ranging = V.ranging_operands()
    cid = 0
    for mmop in mm_ops:
        for op in BINOPS:
            for b in ranging:
                # A is the MM table on the LEFT
                cases.append({"id": "t1_%d" % cid, "kind": "binop",
                              "op": op, "a": mmop, "b": b})
                cid += 1
                # A on the RIGHT (which-side question)
                cases.append({"id": "t1_%d" % cid, "kind": "binop",
                              "op": op, "a": b, "b": mmop})
                cid += 1
        # unary metamethods on the MM table
        for tok, _form in UNOPS:
            cases.append({"id": "t1_%d" % cid, "kind": "unop",
                          "op": tok, "a": mmop})
            cid += 1
    # both-sides-have-it: MM table OP MM table (which fires; same-vs-different)
    singles = V.mm_single_operands()
    for mmop in singles:
        op = _OP_FOR_MM.get(list(mmop.mm)[0])
        if op is None:
            continue
        cases.append({"id": "t1_%d" % cid, "kind": "binop",
                      "op": op, "a": mmop, "b": mmop})
        cid += 1
    return cases


# --- Tier 2: indexing, key normalization, numeric-for, library coercion -------

def tier2():
    cases = []
    plains = V.plain_operands()
    cid = 0

    # t[A] read and t[A]=v write across all operand types (key coercion errors:
    # nil key, NaN key on write).
    for a in plains:
        cases.append({"id": "t2_%d" % cid, "kind": "index_get", "a": a}); cid += 1
        cases.append({"id": "t2_%d" % cid, "kind": "index_set", "a": a}); cid += 1

    # Key normalization: write under A, read back under A' to test integer/float
    # key identity (t[1] vs t[1.0]; t[2^53]; string-vs-number distinctness).
    KEY_PAIRS = [
        ("1",      "1.0"),       # int key == float key with integer value
        ("1.0",    "1"),
        ("2^53",   "2^53"),      # large exact float -> normalizes to int?
        ("2^53",   "9007199254783488"),  # nearby (off by a few)
        ('"1"',    "1"),         # string key distinct from number key
        ("1",      '"1"'),
        ("0.0",    "0"),         # float zero key vs int zero
        ("-0.0",   "0"),         # signed zero key identity
        ("3.5",    "3.5"),       # non-integer float key
        ("1e3",    "1000"),      # float written, int read
    ]
    for ka, kb in KEY_PAIRS:
        cases.append({"id": "t2_%d" % cid, "kind": "key_norm",
                      "ka": ka, "kb": kb}); cid += 1

    # Numeric for bounds/step coercion. a=init, b=limit, c=step.
    forset = [op for op in plains if op.name in {
        "i1", "i0", "im1", "f0", "nan", "inf", "ninf",
        "s_1", "s_1e3", "s_abc", "s_ws5", "nil", "true", "table"}]
    base = next(op for op in plains if op.name == "i1")
    three = next(op for op in plains if op.name == "i1")
    for a in forset:
        # vary limit (b), fixed init=1 step=1
        cases.append({"id": "t2_%d" % cid, "kind": "fornum",
                      "a": base, "b": a, "c": three}); cid += 1
        # vary step (c), fixed init=1 limit=3
        lim = next(op for op in plains if op.name == "s_1e3" if False) if False else None
        cases.append({"id": "t2_%d" % cid, "kind": "fornum",
                      "a": base, "b": _named(plains, "s_1"), "c": a}); cid += 1
        # vary init (a), fixed limit=3 step=1
        cases.append({"id": "t2_%d" % cid, "kind": "fornum",
                      "a": a, "b": _lit("3"), "c": three}); cid += 1

    # Library coercion contexts. The string->number coercion done by library
    # arguments (getNumber/getInt) is a distinct path from operator coercion and
    # has its own bugs (e.g. math.* not coercing integer-first), so feed EVERY
    # string operand plus a number/ref slice — not just a token sample.
    numeric_ref_slice = {"i0", "i1", "im1", "f0", "fm0", "nan", "inf", "ninf",
                         "nil", "true", "table"}
    libset = [op for op in plains
              if op.name.startswith("s_") or op.name in numeric_ref_slice]
    for name, form in LIB_CALLS:
        for a in libset:
            cases.append({"id": "t2_%d" % cid, "kind": "lib",
                          "call_name": name, "form": form, "a": a}); cid += 1
    return cases


def _named(plains, n):
    return next(op for op in plains if op.name == n)


def _lit(expr):
    # a throwaway literal operand for fixed for-loop bounds
    return V.Operand("lit_" + expr.replace(".", "_").replace("-", "m"), expr)


# --- Ordering tier: the four canonical precedence questions -------------------

def ordering():
    """Hand-picked cases hitting coercion-vs-metamethod-vs-error precedence."""
    cases = []
    idx = V.operand_index()
    cid = 0

    def add(kind, op, aname, bname=None):
        nonlocal cid
        c = {"id": "ord_%d" % cid, "kind": kind, "op": op, "a": idx[aname]}
        if bname is not None:
            c["b"] = idx[bname]
        cases.append(c); cid += 1

    # Q1: string convertible to number?  "10"+5 vs "abc"+5 vs hex/exp/ws/sign
    for sn in ["s_1", "s_1e3", "s_0x10", "s_ws5", "s_p1", "s_00",
               "s_0x1p4", "s_inf", "s_nan", "s_abc", "s_empty", "s_space"]:
        add("binop", "+", sn, "i1")
        add("binop", "+", "i1", sn)
        add("binop", "*", sn, "i1")
        add("binop", "-", sn, "i1")

    # Q2: metamethod first vs conversion first?  "10"+T(__add): raw string passed
    # to __add (no coercion); "abc"+T(__add): metamethod fires, no error.
    for sn in ["s_1", "s_abc", "s_empty"]:
        add("binop", "+", sn, "mm_add")
        add("binop", "+", "mm_add", sn)
        add("binop", "..", sn, "mm_concat")
        add("binop", "..", "mm_concat", sn)

    # Q3: which operand's metamethod?  only-A, only-B, both.
    add("binop", "+", "mm_add", "i1")        # only A
    add("binop", "+", "i1", "mm_add")        # only B
    add("binop", "+", "mm_add", "mm_add")    # both (A tried first)
    add("binop", "+", "mm_sub", "mm_add")    # A has wrong mm, B has right one
    add("binop", "..", "mm_concat", "table") # A concat vs plain table
    add("binop", "..", "table", "mm_concat")

    # Q4: error first?  no-mm references -> arithmetic error wording.
    for op in ["+", "-", "*", "/", "%", "//", "^"]:
        add("binop", op, "table", "table2")  # neither has __add
        add("binop", op, "nil", "i1")
        add("binop", op, "true", "i1")
        add("binop", op, "i1", "nil")
    add("binop", "+", "mm_add", "table2")    # one side has __add -> fires
    add("binop", "+", "table", "mm_add")

    # __eq only when same type & not raw-equal.
    add("binop", "==", "mm_eq", "mm_eq")     # same table compared to itself? (built once)
    add("binop", "==", "table", "table2")    # two plain tables -> false, no mm
    add("binop", "==", "mm_eq", "i1")        # diff type -> false, no __eq
    add("binop", "==", "i1", "mm_eq")
    add("binop", "==", "mm_eq", "table2")    # both tables, one has __eq -> fires
    add("binop", "~=", "mm_eq", "table2")

    # __lt/__le and derived >/>=  (a>b -> b<a).
    add("binop", "<", "mm_lt", "i1")
    add("binop", ">", "mm_lt", "i1")
    add("binop", "<=", "mm_le", "i1")
    add("binop", ">=", "mm_le", "i1")
    add("binop", "<", "i1", "mm_lt")
    add("binop", ">", "i1", "mm_lt")

    # bitwise integer-representation rule.
    for op in ["&", "|", "~", "<<", ">>"]:
        add("binop", op, "i1", "i1")    # ok
        add("binop", op, "f0", "i1")    # float w/ integer value -> ok
        add("binop", op, "f0", "f0")
        add("binop", op, "i1", "nan")   # non-integer float -> "no integer repr"
        add("binop", op, "inf", "i1")
        add("binop", op, "s_1", "i1")   # string coercible to int?
        add("binop", op, "i1", "mm_band")  # bitwise metamethod
    add("unop", "bnot", "f0")
    add("unop", "bnot", "nan")
    add("unop", "bnot", "i1")
    add("unop", "bnot", "mm_bnot")

    # len ordering: __len on table vs raw # on string/number.
    add("unop", "len", "s_abc")
    add("unop", "len", "table")
    add("unop", "len", "mm_len")
    add("unop", "len", "i1")

    return cases


# --- Tier 3: randomized differential grind ------------------------------------

def tier3(seed, count):
    rng = random.Random(seed)
    cases = []
    binset = BINOPS
    for i in range(count):
        roll = rng.random()
        if roll < 0.65:
            op = rng.choice(binset)
            a = V.random_operand(rng)
            b = V.random_operand(rng)
            cases.append({"id": "t3_%d" % i, "kind": "binop",
                          "op": op, "a": a, "b": b})
        elif roll < 0.80:
            tok, _form = rng.choice(UNOPS)
            a = V.random_operand(rng)
            cases.append({"id": "t3_%d" % i, "kind": "unop", "op": tok, "a": a})
        elif roll < 0.90:
            a = V.random_operand(rng, include_mm=(rng.random() < 0.3))
            k = rng.choice(["index_get", "index_set"])
            cases.append({"id": "t3_%d" % i, "kind": k, "a": a})
        else:
            name, form = rng.choice(LIB_CALLS)
            a = V.random_operand(rng, include_mm=(rng.random() < 0.2))
            cases.append({"id": "t3_%d" % i, "kind": "lib",
                          "call_name": name, "form": form, "a": a})
    return cases
