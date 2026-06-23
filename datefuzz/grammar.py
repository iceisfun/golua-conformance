"""Directive model + tier enumerators for os.date / os.time / os.difftime.

A "case" here is one of three operation kinds, rendered by emit.py:

  {"id":..., "op":"date", "fmt": "<format>", "ts": <int|None>}
      -> os.date(fmt, ts)   (ts None => current time, which is non-deterministic
                             so we never emit ts=None for differential cases)
  {"id":..., "op":"datetab", "fmt":"*t"|"!*t", "ts": <int>}
      -> os.date("*t"/"!*t", ts)  (table form; compared field-by-field)
  {"id":..., "op":"time", "tbl": {field:val,...}}
      -> os.time(tbl)
  {"id":..., "op":"difftime", "a": <int>, "b": <int>}
      -> os.difftime(a, b)

Format strings always carry their TZ-mode prefix: golua/ref read $TZ from the
injected environment, so the SAME case is replayed under each TZ by the runner.
Each directive is also tried in '!' (UTC) and bare (local) form.

Confirmed against vm/default_os.go strftimeFormat + expandCompoundSpecifiers.
"""

import random
import values as valmod

# strftime directives golua's strftimeFormat handles (single-char, no arg).
# Split by "support tier" only for documentation; all are emitted.
PRIMITIVE = [
    "a", "A", "b", "B", "c", "C", "d", "e", "g", "G", "H", "I", "j",
    "m", "M", "n", "p", "S", "t", "u", "U", "V", "w", "W", "x", "X",
    "y", "Y", "z", "Z", "%",
]
# Compound specifiers expanded before the main loop.
COMPOUND = ["D", "F", "r", "R", "T"]

ALL_DIRECTIVES = PRIMITIVE + COMPOUND

# POSIX %E / %O alternate-modifier pairs golua accepts (altModifierValid).
E_PAIRS = ["Ec", "EC", "Ex", "EX", "Ey", "EY"]
O_PAIRS = ["Od", "Oe", "OH", "OI", "Om", "OM", "OS", "Ou", "OU", "OV", "Ow", "OW", "Oy"]

# Illegal / edge directives — parity of the error path.
ILLEGAL_DIRECTIVES = [
    "Q", "K", "L", "P", "1", "-", "k",   # unknown letters / non-letters
    "EA", "Oa", "EZ", "Ej",              # invalid E/O pairs
    "E", "O",                            # E/O at end of string
]

TZ_PREFIX = ["", "!"]   # local, UTC


def _date_cases(fmts, tss, prefixes=TZ_PREFIX):
    out = []
    for pre in prefixes:
        for fmt in fmts:
            for ts in tss:
                out.append((pre + fmt, ts))
    return out


# --- Tier 0: each directive in isolation, local + UTC, over boundary times ----

def tier0():
    """Single directive, both TZ modes, across all boundary timestamps."""
    fmts = ["%" + d for d in ALL_DIRECTIVES]
    fmts += ["%" + p for p in E_PAIRS + O_PAIRS]
    tss = valmod.timestamps()
    cases = []
    for k, (fmt, ts) in enumerate(_date_cases(fmts, tss)):
        cases.append({"id": "t0_%d" % k, "op": "date", "fmt": fmt, "ts": ts})
    # also the table forms over all timestamps
    base = len(cases)
    for j, ts in enumerate(tss):
        cases.append({"id": "t0t_%d" % j, "op": "datetab", "fmt": "*t", "ts": ts})
        cases.append({"id": "t0u_%d" % j, "op": "datetab", "fmt": "!*t", "ts": ts})
    return cases


# --- Tier 1: multi-directive format strings -----------------------------------

REAL_FORMATS = [
    "%Y-%m-%d %H:%M:%S",
    "%a %b %e %H:%M:%S %Y",       # asctime-ish == %c
    "%c",
    "%x %X",
    "%A, %d %B %Y",
    "%I:%M:%S %p",
    "%j (day of year)",
    "%G-W%V-%u",                  # ISO week date
    "%U %W %V",                   # competing week numbers
    "%F %T %z %Z",
    "%D",
    "%r",
    "%R",
    "[%%] %p%% literal",
    "%Y%m%d%H%M%S",               # compact, no separators
    "week %U day %w / %u",
    "%C%y",                       # century+year == %Y (mostly)
    "%n%t<-newline tab",
    "%e/%b/%g",
    "%a=%A %b=%B",
]


def tier1():
    """Multi-directive real-world format strings, both TZ modes, boundary times."""
    tss = valmod.timestamps()
    cases = []
    for k, (fmt, ts) in enumerate(_date_cases(REAL_FORMATS, tss)):
        cases.append({"id": "t1_%d" % k, "op": "date", "fmt": fmt, "ts": ts})
    return cases


# --- Tier 2: os.time(table) round-trips + boundary/out-of-range fields --------

def tier2():
    """os.time over coherent base tables, each field perturbed to its boundaries,
    plus full-random isdst toggling; difftime over timestamp pairs."""
    cases = []
    k = 0
    # base tables straight through (all isdst variants)
    for base in valmod.BASE_TABLES:
        for dst in valmod.ISDST_CHOICES:
            t = dict(base)
            if dst is not None:
                t["isdst"] = dst
            cases.append({"id": "t2b_%d" % k, "op": "time", "tbl": t})
            k += 1
    # one-field-perturbed off each base (out-of-range normalization)
    for base in valmod.BASE_TABLES:
        for field, vals in valmod.FIELD_BOUNDARIES.items():
            for v in vals:
                t = dict(base)
                t[field] = v
                cases.append({"id": "t2p_%d" % k, "op": "time", "tbl": t})
                k += 1
    # difftime over all ordered pairs of a small boundary subset
    diff_ts = [0, 1, -1, 86400, -86400, 2147483647, -2147483648, 1234567890]
    for a in diff_ts:
        for b in diff_ts:
            cases.append({"id": "t2d_%d" % k, "op": "difftime", "a": a, "b": b})
            k += 1
    return cases


# --- Tier 3: randomized long tail ---------------------------------------------

def _rand_format(rng):
    n = rng.randint(1, 6)
    parts = []
    for _ in range(n):
        r = rng.random()
        if r < 0.78:
            parts.append("%" + rng.choice(ALL_DIRECTIVES))
        elif r < 0.86:
            parts.append("%" + rng.choice(E_PAIRS + O_PAIRS))
        elif r < 0.93:
            parts.append("%" + rng.choice(ILLEGAL_DIRECTIVES))
        else:
            parts.append(rng.choice(["-", " ", ":", "/", "x", "T", "."]))
    pre = "!" if rng.random() < 0.5 else ""
    return pre + "".join(parts)


def tier3(seed, count):
    """Random formats over random timestamps + random os.time tables + difftime."""
    rng = random.Random(seed)
    cases = []
    for i in range(count):
        r = rng.random()
        if r < 0.55:
            cases.append({"id": "t3_%d" % i, "op": "date",
                          "fmt": _rand_format(rng), "ts": valmod.rand_timestamp(rng)})
        elif r < 0.80:
            cases.append({"id": "t3_%d" % i, "op": "time", "tbl": valmod.rand_table(rng)})
        elif r < 0.92:
            mode = rng.choice(["*t", "!*t"])
            cases.append({"id": "t3_%d" % i, "op": "datetab",
                          "fmt": mode, "ts": valmod.rand_timestamp(rng)})
        else:
            cases.append({"id": "t3_%d" % i, "op": "difftime",
                          "a": valmod.rand_timestamp(rng), "b": valmod.rand_timestamp(rng)})
    return cases


# --- Illegal / edge tier ------------------------------------------------------

def tier_illegal():
    """Error-path parity: unknown directives, empty/lone-%, missing os.time
    fields, huge/negative time_t to os.date."""
    cases = []
    k = 0
    tss = [0, 1234567890, -1]
    # unknown / malformed directives, both modes
    bad_fmts = ["%" + d for d in ILLEGAL_DIRECTIVES]
    bad_fmts += ["%", "abc%", "%%%", "", "%Y%Q", "100%", "%E", "%O", "% ", "%\t"]
    for pre in TZ_PREFIX:
        for fmt in bad_fmts:
            for ts in tss:
                cases.append({"id": "ti_%d" % k, "op": "date", "fmt": pre + fmt, "ts": ts})
                k += 1
    # os.date on extreme time_t (representation-error branch)
    for ts in [67768036191676800, -67768040609740800, 1 << 62, -(1 << 62)]:
        cases.append({"id": "ti_%d" % k, "op": "date", "fmt": "%Y", "ts": ts})
        k += 1
        cases.append({"id": "ti_%d" % k, "op": "date", "fmt": "!%Y", "ts": ts})
        k += 1
        cases.append({"id": "ti_%d" % k, "op": "datetab", "fmt": "!*t", "ts": ts})
        k += 1
    # os.time with missing required fields (year/month/day) and empty table
    missing = [
        {},
        {"year": 2024},
        {"year": 2024, "month": 6},
        {"month": 6, "day": 1},
        {"year": 2024, "day": 1, "hour": 0},          # missing month
        {"year": 2024, "month": 6, "day": 1},          # complete (h/m/s default)
        {"year": 2024, "month": 6, "day": 1, "hour": 1, "min": 2, "sec": 3, "wday": 9, "yday": 9},  # extra fields ignored
    ]
    for t in missing:
        cases.append({"id": "ti_%d" % k, "op": "time", "tbl": t})
        k += 1
    # os.time with a non-integer / float field (5.5 requires integers)
    cases.append({"id": "ti_%d" % k, "op": "time_raw",
                  "expr": "{year=2024,month=6,day=1,hour=2.5}"})
    k += 1
    cases.append({"id": "ti_%d" % k, "op": "time_raw",
                  "expr": '{year=2024,month=6,day="x"}'})
    k += 1
    return cases
