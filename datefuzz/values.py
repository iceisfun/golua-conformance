"""Boundary tables for timestamps (os.date) and date-table fields (os.time).

Two value axes feed the date/time surface:

  * timestamps (time_t) — the integer argument to os.date / second arg, and the
    epoch result of os.time. Bugs cluster at epoch, sign changes, year/month/day
    rollovers, leap-day instants, DST transitions, and 32-bit overflow (2038).

  * date-table fields — {year,month,day,hour,min,sec,isdst}. Reference Lua passes
    these straight to C's mktime, which *normalizes* out-of-range fields
    (month=13 -> next-January, day=0 -> last-day-of-prev-month, sec=-1, etc.).
    golua resolves them via Go's time.Date, which also normalizes. Whether the
    two normalizations agree is the tier-2 parity question.

Determinism note: the meaning of a local-time timestamp depends on $TZ, so the
SAME timestamp is replayed under every TZ the runner injects (see run.py). The
values here are TZ-agnostic integers; the runner supplies the TZ.
"""

import random

# --- Timestamp boundaries (time_t, seconds since 1970-01-01 UTC) --------------

# Curated instants. Comments give the UTC wall-clock so the intent is auditable.
TS_BOUNDARIES = [
    0,                 # 1970-01-01 00:00:00  epoch
    1,                 # 1s after epoch
    -1,                # 1969-12-31 23:59:59  pre-epoch (sign boundary)
    -86400,            # 1969-12-31 00:00:00  one day pre-epoch
    60, 3600, 86400,   # minute / hour / day units
    86399,             # 1970-01-01 23:59:59  day rollover -1
    86400 - 1,         # same, explicit
    951782400,         # 2000-02-29 00:00:00  leap day (century leap year)
    951868799,         # 2000-02-29 23:59:59  leap-day end
    1709164800,        # 2024-02-29 00:00:00  leap day (2024)
    1709251199,        # 2024-02-29 23:59:59
    1582934400,        # 2020-02-29  leap
    1583020800,        # 2020-03-01  day after leap
    978307199,         # 2000-12-31 23:59:59  year/century rollover
    978307200,         # 2001-01-01 00:00:00
    1234567890,        # 2009-02-13 23:31:30  arbitrary mid-range
    # --- DST transition instants (US Eastern; UTC seconds) ---
    # 2024 US DST: spring-forward 2024-03-10 07:00Z, fall-back 2024-11-03 06:00Z
    1710046800 - 1,    # 1s before spring-forward (EST 01:59:59)
    1710046800,        # spring-forward instant (07:00Z -> EDT 03:00)
    1710046800 + 1,
    1730613600 - 1,    # 1s before fall-back (EDT 01:59:59)
    1730613600,        # fall-back instant (06:00Z -> EST 01:00)
    1730613600 + 1,
    # --- 32-bit time_t overflow region (2038-01-19 03:14:07Z = 2^31-1) ---
    2147483647,        # INT32_MAX  (Y2038)
    2147483648,        # INT32_MAX + 1  (just past 32-bit)
    -2147483648,       # INT32_MIN  (1901-12-13)
    -2147483649,       # below INT32_MIN
    # --- far future / past (still C-representable: |year| < ~2^31) ---
    32503680000,       # 3000-01-01
    -62135596800 + 86400,  # near year 1 (Go/Gregorian proleptic edge)
    253402300799,      # 9999-12-31 23:59:59
    # --- extreme: drives the "date result cannot be represented" branch ---
    67768036191676800,   # year ~ 2.1e9 (> INT32 year)  -> error on both
    -67768040609740800,  # year ~ -2.1e9
]


def timestamps():
    return list(dict.fromkeys(TS_BOUNDARIES))


def rand_timestamp(rng):
    """A random time_t. Mostly in the C-representable band, occasionally extreme."""
    r = rng.random()
    if r < 0.70:
        return rng.randint(-2 * 31556952, 4 * 31556952 + 1700000000)  # ~1908..2100
    if r < 0.85:
        return rng.randint(-(1 << 31) - 5, (1 << 31) + 5)             # 32-bit edges
    if r < 0.95:
        return rng.randint(-(1 << 40), 1 << 40)                       # wide
    return rng.choice([
        rng.randint(-(1 << 60), 1 << 60),                            # extreme
        rng.choice(TS_BOUNDARIES),
    ])


# --- os.time date-table field boundaries --------------------------------------

# Each entry: field -> list of boundary values (incl. out-of-range for normalize).
FIELD_BOUNDARIES = {
    "year":  [1970, 2000, 2024, 1969, 1900, 2038, 2100, 1, 9999],
    "month": [1, 12, 6, 0, 13, -1, 24, 25],
    "day":   [1, 31, 28, 29, 0, 32, -1, 60],
    "hour":  [0, 12, 23, 24, -1, 25, 48],
    "min":   [0, 30, 59, 60, -1, 90],
    "sec":   [0, 30, 59, 60, 61, -1, 3600],
}

# Curated *coherent* base tables (valid, real dates) used as the spine; tier2
# perturbs one field at a time off these so most cases are near-valid.
BASE_TABLES = [
    {"year": 1970, "month": 1,  "day": 1,  "hour": 0,  "min": 0,  "sec": 0},
    {"year": 2000, "month": 2,  "day": 29, "hour": 12, "min": 0,  "sec": 0},
    {"year": 2024, "month": 2,  "day": 29, "hour": 23, "min": 59, "sec": 59},
    {"year": 2024, "month": 3,  "day": 10, "hour": 2,  "min": 30, "sec": 0},   # US spring-forward gap
    {"year": 2024, "month": 11, "day": 3,  "hour": 1,  "min": 30, "sec": 0},   # US fall-back ambiguous
    {"year": 2038, "month": 1,  "day": 19, "hour": 3,  "min": 14, "sec": 7},   # Y2038
    {"year": 1999, "month": 12, "day": 31, "hour": 23, "min": 59, "sec": 59},
]

ISDST_CHOICES = [None, True, False]   # None = field absent


def rand_table(rng):
    """Random date table; fields drawn from boundary sets, isdst sometimes set."""
    t = {}
    for f, vals in FIELD_BOUNDARIES.items():
        if rng.random() < 0.85:
            t[f] = rng.choice(vals)
        else:
            t[f] = rng.randint(-5, 9999) if f == "year" else rng.randint(-3, 70)
    dst = rng.choice(ISDST_CHOICES)
    if dst is not None:
        t["isdst"] = dst
    return t


random = random  # re-export so run.py can do valmod.random.Random(seed)
