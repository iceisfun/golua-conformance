"""Codepoint and raw-byte boundary tables for the utf8 library fuzzer.

Two value axes:
  * codepoint sequences  -> fed to utf8.char(...) to build VALID strings
  * raw byte strings      -> fed directly to decode-side functions to exercise
                             malformed input (overlong / surrogate / truncated /
                             lone-continuation / illegal-lead bytes)

A "subject" is the raw byte string a case operates on. Cases carry it as a
`bytes` object; emit.py renders it as a Lua "\\xNN..." literal so the exact same
bytes reach both interpreters.

Per CLAUDE.md provider/decoder notes, malformed input is the prime bug territory:
Go's unicode/utf8 (golua's strict path) vs C Lua's hand-rolled decoder.
"""

import random

# --- Codepoint boundary table -------------------------------------------------

MAXUNICODE = 0x10FFFF
MAXEXTENDED = 0x7FFFFFFF   # Lua 5.5 utf8.char accepts up to this (6-byte enc)

# Boundaries where encoded byte-length changes, plus the illegal/surrogate bands.
CP_BOUNDARIES = [
    0x00, 0x01, 0x7F,            # 1-byte band edges
    0x80, 0x100, 0x7FF,          # 2-byte band edges
    0x800, 0x801, 0xFFF, 0xFFFF, # 3-byte band edges
    0x10000, 0x10001, 0x10FFFF,  # 4-byte band edges (last valid Unicode)
    # surrogate range (illegal as scalar values, but utf8.char in Lua encodes them)
    0xD7FF, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xE000,
    # extended (Lua-only) range past Unicode max
    0x110000, 0x1FFFFF,          # 4->? boundary; 0x1FFFFF is 4-byte ext max region
    0x200000, 0x3FFFFFF,         # 5-byte band edges
    0x4000000, 0x7FFFFFFF,       # 6-byte band edges (extended max)
]

# Codepoints that should be REJECTED by utf8.char on both interpreters.
CP_ILLEGAL = [-1, MAXEXTENDED + 1, 0x80000000, 0xFFFFFFFF, 1 << 40, -(1 << 40)]


def rand_codepoint(rng, allow_ext=True):
    hi = MAXEXTENDED if (allow_ext and rng.random() < 0.25) else MAXUNICODE
    return rng.randint(0, hi)


# --- Raw byte boundary table (malformed-input space) --------------------------

# Encode helper (extended UTF-8, mirrors golua appendExtendedUTF8) so we can
# build overlong/surrogate byte sequences deterministically.
def _enc(cp):
    if cp <= 0x7F:
        return bytes([cp])
    if cp <= 0x7FF:
        return bytes([0xC0 | (cp >> 6), 0x80 | (cp & 0x3F)])
    if cp <= 0xFFFF:
        return bytes([0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)])
    if cp <= 0x1FFFFF:
        return bytes([0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
                      0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)])
    if cp <= 0x3FFFFFF:
        return bytes([0xF8 | (cp >> 24), 0x80 | ((cp >> 18) & 0x3F),
                      0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F),
                      0x80 | (cp & 0x3F)])
    return bytes([0xFC | (cp >> 30), 0x80 | ((cp >> 24) & 0x3F),
                  0x80 | ((cp >> 18) & 0x3F), 0x80 | ((cp >> 12) & 0x3F),
                  0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)])


def _overlong(cp, nbytes):
    """Encode cp using MORE bytes than minimal (an illegal overlong form)."""
    # Pack cp into the low bits of an nbytes sequence regardless of its size.
    if nbytes == 2:
        return bytes([0xC0 | ((cp >> 6) & 0x1F), 0x80 | (cp & 0x3F)])
    if nbytes == 3:
        return bytes([0xE0 | ((cp >> 12) & 0x0F), 0x80 | ((cp >> 6) & 0x3F),
                      0x80 | (cp & 0x3F)])
    if nbytes == 4:
        return bytes([0xF0 | ((cp >> 18) & 0x07), 0x80 | ((cp >> 12) & 0x3F),
                      0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)])
    raise ValueError(nbytes)


# Hand-curated malformed / boundary byte sequences. Each is one "subject".
MALFORMED = [
    b"",                                 # empty
    b"A",                                # plain ASCII
    b"\x00",                             # NUL
    b"\x7f",                             # last ASCII
    # lone continuation bytes
    b"\x80", b"\xbf", b"\x80\x80",
    # illegal lead bytes
    b"\xc0", b"\xc1",                    # always-overlong leads
    b"\xf5", b"\xf6", b"\xf7",           # > U+10FFFF leads (valid as ext lead!)
    b"\xf8", b"\xfb", b"\xfc", b"\xfd",  # 5/6-byte ext leads
    b"\xfe", b"\xff",                    # never-valid lead bytes
    # overlong encodings (illegal): encode small cps in too many bytes
    _overlong(0x00, 2), _overlong(0x2F, 2),   # overlong '/' (classic exploit)
    _overlong(0x00, 3), _overlong(0x7F, 3),
    _overlong(0x80, 3),                       # overlong 2-byte-worth in 3 bytes
    _overlong(0x00, 4), _overlong(0x7FF, 4),
    # surrogates encoded as 3-byte UTF-8 (illegal scalar)
    _enc(0xD800), _enc(0xDBFF), _enc(0xDC00), _enc(0xDFFF),
    # > U+10FFFF encoded as 4-byte (strict-illegal, lax-legal in Lua)
    _enc(0x110000), _enc(0x1FFFFF),
    # 5/6-byte extended encodings (lax-only)
    _enc(0x200000), _enc(0x3FFFFFF), _enc(0x4000000), _enc(0x7FFFFFFF),
    # truncated multibyte sequences (lead byte then EOF / too-few continuations)
    b"\xc2", b"\xe0", b"\xe0\xa0", b"\xf0", b"\xf0\x90", b"\xf0\x90\x80",
    b"\xf8\x80", b"\xfc\x80\x80",
    # continuation byte with wrong high bits in the middle
    b"\xe0\xa0\x20", b"\xf0\x90\x80\x20", b"\xc2\x20",
    # valid char followed by a stray continuation (codes/offset trap)
    b"A\x80", _enc(0x80) + b"\x80", _enc(0x4E2D) + b"\x80",
    # valid prefix then truncated tail
    b"AB" + b"\xe0\xa0", _enc(0x4E2D) + b"\xf0",
    # mixed valid: ASCII + 2/3/4-byte + ASCII
    b"a" + _enc(0xE9) + b"b" + _enc(0x4E2D) + b"c" + _enc(0x1F600) + b"d",
    # high-bit-set first byte that IS a valid rune-start but truncated
    _enc(0x10FFFF)[:3],
    # NUL embedded mid-string (string length vs C strlen trap)
    b"a\x00" + _enc(0x4E2D),
]


def rand_bytes(rng, maxlen=10):
    n = rng.randint(0, maxlen)
    # Bias toward high bytes so we hit lead/continuation logic, not just ASCII.
    return bytes(rng.choice([rng.randint(0, 0x7F), rng.randint(0x80, 0xFF),
                             rng.randint(0xC0, 0xFF)]) for _ in range(n))


def rand_valid_string(rng, maxcps=8, allow_ext=False):
    """A byte string built from valid (lax-encodable) codepoints via _enc.

    With allow_ext=False all codepoints are <= U+10FFFF excluding surrogates,
    so the string is strict-valid on both interpreters.
    """
    n = rng.randint(0, maxcps)
    out = bytearray()
    cps = []
    for _ in range(n):
        while True:
            cp = rand_codepoint(rng, allow_ext)
            if not allow_ext and 0xD800 <= cp <= 0xDFFF:
                continue
            break
        cps.append(cp)
        out += _enc(cp)
    return bytes(out), cps


# --- Index argument boundaries ------------------------------------------------

def index_args(rng, slen):
    """A grab-bag of (i, j) index pairs spanning negative / OOB / interior."""
    pts = [None, 1, 2, -1, -2, slen, slen + 1, slen + 2, -slen, -slen - 1, 0]
    if slen > 2:
        pts.append(rng.randint(1, slen))
        pts.append(-rng.randint(1, slen))
    return pts
