"""Enumerator for the Lua string-pattern language.

The pattern language is a small grammar over a fixed vocabulary:

  item      := single | class | set | '.' | literal
  single    := <ordinary byte>
  class     := '%' <classletter>           (a/c/d/g/l/p/s/u/w/x + uppercase = complement)
            |  '%' <punct>                  (escaped magic char -> literal)
  set       := '[' '^'? member+ ']'
  member    := byte | byte '-' byte | class
  quant     := item ('*' | '+' | '-' | '?')?
  anchor    := '^' (start) | '$' (end)
  capture   := '(' pattern ')' | '()' (position) | '%' <1-9> (back-ref)
  special   := '%b' xy | '%f' set

This module emits *pattern strings*; values.py supplies the subjects each pattern
is run against. Tiers:

  tier0    every class / magic / quantifier / anchor in isolation
  tier1    class+quantifier and set construction matrix
  tier2    captures, anchors, %b, %f, back-references, nested/position captures
  tier3    random pattern strings over the full vocabulary
  illegal  malformed patterns whose ERROR WORDING must match the reference
           (unbalanced %b, trailing %, unclosed [, %f w/o set, bad capture idx,
            malformed sets) — prime bug territory.
"""

import random

# %X class letters (lowercase form; uppercase = complement). %<punct> escapes a
# magic char to its literal.
CLASS_LETTERS = ["a", "c", "d", "g", "l", "p", "s", "u", "w", "x"]
CLASSES = []
for _c in CLASS_LETTERS:
    CLASSES.append("%" + _c)
    CLASSES.append("%" + _c.upper())

# The magic characters of the pattern language.
MAGIC = ["(", ")", ".", "%", "+", "-", "*", "?", "[", "]", "^", "$"]

QUANTS = ["*", "+", "-", "?"]

# Ordinary single bytes worth pattern-izing (literals + the dot wildcard).
SINGLES = ["a", "b", "A", "1", " ", ".", "_", "z"]

# %<punct> literal escapes (escaping a magic char or other punctuation).
PUNCT_ESCAPES = ["%(", "%)", "%.", "%%", "%+", "%-", "%*", "%?",
                 "%[", "%]", "%^", "%$", "%/", "%!", "%@", "%,"]


def dedup(seq):
    seen = set()
    res = []
    for x in seq:
        if x not in seen:
            seen.add(x)
            res.append(x)
    return res


# --- Tier 0: every construct in isolation -------------------------------------

def tier0():
    out = []
    # each class, bare
    out += CLASSES
    # each %<punct> literal escape
    out += PUNCT_ESCAPES
    # the dot wildcard and plain single literals
    out += SINGLES
    # each magic char on its own (some are errors, most are literals/structure)
    out += MAGIC
    # each class with each quantifier
    for cl in CLASSES + ["."]:
        for q in QUANTS:
            out.append(cl + q)
    # single literal with each quantifier
    for s in ["a", "."]:
        for q in QUANTS:
            out.append(s + q)
    # bare anchors
    out += ["^", "$", "^a", "a$", "^a$", "^$", "^.$"]
    # empty pattern
    out.append("")
    return dedup(out)


# --- Tier 1: class+quantifier and set construction ----------------------------

def tier1():
    out = []
    # sets: positive, negated, ranges, classes-in-sets, edge members
    sets = [
        "[abc]", "[^abc]", "[a-z]", "[A-Z]", "[0-9]", "[a-zA-Z0-9]",
        "[^a-z]", "[%d]", "[%a]", "[%s]", "[^%d]", "[%d_]", "[%a%d]",
        "[%w_]", "[-a]", "[a-]", "[]a]", "[^]a]", "[]]", "[^]]",
        "[a-c-e]", "[%]]", "[%^]", "[%-]", "[ \t]", "[\\n]",
        "[\x00-\x1f]", "[^\x00]", "[!-~]", "[%l%u]", "[abc%d-]",
        "[^^]", "[$]", "[.]", "[*+?]", "[][]",
    ]
    out += sets
    # set with each quantifier
    for s in ["[abc]", "[^abc]", "[a-z]", "[%d]", "[%w_]"]:
        for q in QUANTS:
            out.append(s + q)
    # class+quant concatenations (two-construct sequences)
    twoclass = ["%a", "%d", "%s", "%w", "%p", "."]
    for a in twoclass:
        for qa in ["", "+", "*", "-", "?"]:
            for b in twoclass:
                out.append(a + qa + b)
    # quantified class followed by literal anchor
    for cl in ["%a", "%d", "%w", "."]:
        for q in QUANTS:
            out.append("^" + cl + q)
            out.append(cl + q + "$")
            out.append("^" + cl + q + "$")
    # mixed set + class + literal sequences
    out += [
        "[%a_][%w_]*", "%a%w*", "%d+%.%d+", "%d-%.%d+", "[+-]?%d+",
        "%s*%S+%s*", "[%u][%l]+", "%x+", "0[xX]%x+", "[abc]+[def]*",
        "%a*%d*", ".-", ".*", ".+", "a.-b", "a.*b", "a.+b",
        "%bxy"[:0] + "a-b",  # plain literals around dash
    ]
    return dedup(out)


# --- Tier 2: captures, anchors, %b, %f, back-references ------------------------

def tier2():
    out = []
    # simple captures
    out += [
        "(%a+)", "(%d+)", "(.)", "(.-)", "(.*)", "(%a)(%a)", "(%w+)%s+(%w+)",
        "(%a+)=(%a+)", "((%a)(%d))", "(a(b)c)", "(%d+)%.(%d+)",
    ]
    # position captures
    out += [
        "()", "()a", "a()", "()a()", "(()a())", "%a+()", "()%a+",
        "(%a+())", "(()%a+)", "()()", "a()b()c",
    ]
    # nested captures
    out += [
        "((a))", "((a)(b))", "(a(b(c)))", "(%a(%d)%a)", "(()(()))",
    ]
    # back-references
    out += [
        "(%a)%1", "(%a+)%1", "(.)%1", "(%w)(%w)%2%1", "(a)(b)%1%2",
        "(.)(.)%1", "(%a)%1*", "(%a)%1+", "(%a)%1-", "(%a)%1?",
    ]
    # %b balanced
    out += [
        "%b()", "%b[]", "%b{}", "%b<>", "%baa", "%b\"\"", "%b''",
        "x%b()y", "(%b())", "%b()%b[]",
    ]
    # %f frontier
    out += [
        "%f[%a]", "%f[%w]", "%f[%s]", "%f[^%a]", "%f[abc]", "%f[%a]%a+",
        "%f[%w]%w+%f[%W]", "%f[^%s]", "%f[\x00]", "%f[%d]%d+", "%f[%l]",
    ]
    # anchored captures and combinations
    out += [
        "^(%a+)", "(%a+)$", "^(%a+)$", "^(%w+)%s+(%w+)$",
        "^%s*(.-)%s*$",            # trim
        "(%a+)%s*=%s*(%a+)",       # key=value
        "%((%a+)%)",               # parenthesised
    ]
    return dedup(out)


# --- ILLEGAL tier: malformed patterns; error wording must match ---------------

def illegal():
    out = [
        # trailing %
        "%", "a%", "abc%", "%a%", "(%a)%",
        # unfinished / malformed sets
        "[", "[a", "[abc", "[^", "[^a", "[a-", "[a-z", "[%", "[%a",
        "[]", "[^]",                       # ']' first-member edge: NOT malformed
        # %b argument shortfall
        "%b", "%bx", "a%b", "(%b)", "%b(",
        # %f without a set
        "%f", "%fa", "%f%a", "%fx", "a%f", "%f(",
        # capture structure
        "(", "((", "(a", "(a(b)", "(()", "()(",
        ")",                               # stray close: literal on both
        # back-reference index errors
        "%1", "(%a)%2", "%0", "%9", "(a)%9", "(a)(b)%3",
        # %<digit> with no capture
        "%5",
        # escape at very end inside set
        "[a%", "[\\",
        # nested unbalanced
        "((a)", "(a))b",  # note (a))b: extra ) is literal -> may NOT error
    ]
    return dedup(out)


# --- Depth tier: length / recursion-limit stress ------------------------------
#
# Every other tier emits SHORT patterns (tier3 maxatoms<=8), so golua's matcher
# recursion guard (maxMatchCalls, ~200 frames) is never approached and the whole
# class of "pattern too complex" / deep-recursion bugs is unreachable. This tier
# walks pattern LENGTH and nesting DEPTH across that boundary so a pattern the
# reference folds in one frame but golua recurses on (or vice-versa) surfaces as
# a differential. Run against short subjects (incl. "") — the point is pattern
# structure, not subject backtracking.
#
# k values bracket the historical limit (200) on both sides with margin.
DEPTH_K = [1, 8, 31, 32, 33, 50, 100, 150, 198, 199, 200, 201, 250, 400, 600]


def tier_depth():
    out = []

    # Chained zero/low-match quantifiers — the shape the reference folds via
    # `p = ep + 1; goto init` without consuming match depth.
    for unit in ["a*", "a-", "a?", ".-", ".*", "[%a]*", "%a*", "a*b*"]:
        for k in DEPTH_K:
            out.append(unit * k)

    # Quantified runs preceded by a consume, so the tail folds against "".
    for k in DEPTH_K:
        out.append("a+" + "b*" * k)
        out.append("%a+" + ".-" * k)

    # Nested capture/group depth (open n, body, close n) and sibling-capture
    # count — both bracket the luaMaxCaptures=32 boundary and deep recursion.
    for k in DEPTH_K:
        if k <= 64:                       # keep paren depth sane
            out.append("(" * k + "a?" + ")" * k)
            out.append("(a?)" * k)

    # Position-capture runs (no char consumed; pure structural depth).
    for k in DEPTH_K:
        out.append("()" * k)

    # Deeply chained balanced / frontier constructs.
    for k in DEPTH_K:
        if k <= 200:
            out.append("%f[%a]" * k)
            out.append("%b()" * k)

    # Long alternating literal/class sequences (no quantifier; deep tail-call
    # via the main loop's `continue`).
    for k in DEPTH_K:
        out.append("%a" * k)
        out.append("ab" * k)

    return dedup(out)


# Subjects for the depth tier: short, but include strings that make the chains
# actually consume (so both the zero-match fold AND the match path are walked).
DEPTH_SUBJECTS = [
    b"",
    b"a",
    b"aaaa",
    b"a" * 64,
    b"ab" * 64,
    b"abc def ghi",
    b"(((nested)))",
    b"\x00",
]


# --- Tier 3: randomized pattern strings ---------------------------------------

# Atoms the random generator draws from. Skewed toward magic/structure so random
# patterns frequently form sets, captures, quantifiers and escapes.
def _rand_atom(rng):
    bucket = rng.randint(0, 9)
    if bucket <= 2:
        return rng.choice(SINGLES)
    if bucket == 3:
        return rng.choice(CLASSES)
    if bucket == 4:
        return rng.choice(PUNCT_ESCAPES)
    if bucket == 5:
        return rng.choice(QUANTS)         # may dangle -> error path
    if bucket == 6:
        return rng.choice(["(", ")", "()"])
    if bucket == 7:
        # a random small set
        inner = "".join(rng.choice(SINGLES + ["a-z", "0-9", "%d", "%a", "-", "^"])
                        for _ in range(rng.randint(1, 3)))
        neg = "^" if rng.random() < 0.3 else ""
        return "[" + neg + inner + "]"
    if bucket == 8:
        return rng.choice(["%b()", "%b[]", "%b{}", "%f[%a]", "%f[%w]", "%f[^%s]"])
    # anchors and back-refs
    return rng.choice(["^", "$", ".", "%1", "%2"])


def tier3(seed, count, minatoms=1, maxatoms=8):
    rng = random.Random(seed)
    out = []
    for _ in range(count):
        n = rng.randint(minatoms, maxatoms)
        out.append("".join(_rand_atom(rng) for _ in range(n)))
    return dedup(out)
