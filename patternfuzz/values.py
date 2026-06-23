"""Subject-string corpora for pattern matching.

For string patterns the search has two axes: the *pattern* (structure — owned by
grammar.py) and the *subject* it runs against (data — owned here). A pattern bug
only surfaces against a subject that actually exercises the relevant byte class,
so each pattern is run against a small, carefully-chosen battery of subjects that
span the magic chars, whitespace/newlines, NUL, ASCII letter/digit/punct classes,
and high (>=128) bytes.

Subjects are kept SHORT (<= ~30 bytes) so a pathological pattern cannot trigger
catastrophic backtracking that outruns the timeout (the timeout still catches any
that slip through). They are emitted as raw `bytes` and rendered by emit.py as
position-independent `\\xNN` Lua string literals so both interpreters see the
exact same bytes regardless of locale or source encoding.
"""

import random


# --- Fixed battery: every pattern runs against ALL of these -------------------
#
# Chosen to cover, in <=30 bytes each: empty, pure-class runs, mixed, magic
# chars as literals, anchored shapes, whitespace/newline, NUL, high bytes, and
# the balanced/frontier shapes (parens, brackets).
FIXED_SUBJECTS = [
    b"",
    b"a",
    b"abc",
    b"aaa",
    b"abcabc",
    b"hello world",
    b"  leading",
    b"trailing  ",
    b"a b c",
    b"a\tb\tc",
    b"line1\nline2",
    b"\n\n\n",
    b"ABCdef123",
    b"123-456-789",
    b"key=value;k2=v2",
    b"3.14159",
    b"-42",
    b"+0x1F",
    b"UPPER lower",
    b"camelCaseWord",
    b"snake_case_word",
    b"a.b.c.d",
    b"(nested(paren))",
    b"[bracket]stuff",
    b"{a,b,c}",
    b"<tag>body</tag>",
    b"%percent%",
    b"a*b+c?d",
    b"^anchor$",
    b"$dollar^caret",
    b"foo123bar456",
    b"   ",
    b"\x00abc\x00",
    b"a\x00b",
    b"hi\xffthere",
    b"\x80\x81\x82",
    b"caf\xc3\xa9",          # UTF-8 'café'
    b"tab\tand space",
    b"word1 word2 word3",
    b"aAbBcC",
    b"....",
    b"a---b",
    b"x123y456z",
    b"  spaced out  ",
    b"MixedCASE123!@#",
    b"the quick brown fox",
    b"end.",
    b".start",
    b"aXbXc",
    b"repeat repeat repeat",
]


# --- Small alphabets for randomized subject construction (tier3) --------------
#
# A magic-heavy alphabet so random subjects collide with random patterns often.
RAND_ALPHABET = list(b"ab cAB12.%+-*?[]()^$_\t\n\x00\xff")


def random_subject(rng, maxlen=24):
    n = rng.randint(0, maxlen)
    return bytes(rng.choice(RAND_ALPHABET) for _ in range(n))


def random_subjects(rng, count, maxlen=24):
    return [random_subject(rng, maxlen) for _ in range(count)]


# A trimmed battery used for the heavier tiers (captures / random) to keep the
# case count manageable while still spanning the byte classes.
CORE_SUBJECTS = [
    b"",
    b"abc",
    b"aaa",
    b"abcabc",
    b"hello world",
    b"  leading",
    b"123-456",
    b"ABCdef123",
    b"a.b.c",
    b"(nested(paren))",
    b"%percent%",
    b"^anchor$",
    b"line1\nline2",
    b"a\x00b",
    b"\x80\x81\x82",
    b"a b c d e",
    b"aXbXcX",
    b"the quick brown fox",
]
