# datefuzz — differential grinder for `os.date` / `os.time` / `os.difftime`

Treats the strftime directive set + the `os.time` date-table as the small
finite surface it is and grinds it differentially against reference `lua5.5.0`,
plus a handful of oracle-free invariants. A clean run leaves `corpus/` empty
(only `report.txt` + `.gitkeep`); any other file there is a real lead.

Modeled on `../packfuzz` — same build/run/diff/corpus/report machinery; the
date-specific surface lives in `grammar.py` + `values.py` + `emit.py`.

## DETERMINISM (the whole reason this is fiddly)

`os.date` local-time output depends on **`$TZ`** and the **locale**, and
`os.time` reads its table as *local* wall-clock. To make the comparison sound,
`run.py` injects an **identical, fixed environment into both interpreters**:

- `LC_ALL=C` / `LANG=C` — pins locale-sensitive directives (`%a %A %b %B %c %p
  %x %X`) to a stable representation.
- `TZ` — every case is replayed under **each** zone in `TZS`
  (default `UTC,America/New_York`). UTC is the no-DST baseline; `America/New_York`
  exercises spring-forward / fall-back. Override with `DATEFUZZ_TZS=...`.

Every interpreter invocation runs under `ulimit -v` + `timeout`, exactly as in
packfuzz.

## Layout

| File         | Role                                                                       |
|--------------|----------------------------------------------------------------------------|
| `grammar.py` | strftime directive table (primitive + compound + `%E`/`%O` pairs + illegal), tier 0/1/2/illegal enumerators, tier-3 random gen |
| `values.py`  | timestamp boundary table + `os.time` date-table field boundaries / base tables |
| `emit.py`    | renders a batch of cases into one self-contained Lua driver                 |
| `run.py`     | runs the driver under golua **and** `lua5.5.0` with the fixed env, diffs, checks invariants |
| `corpus/`    | only divergences land here (seed-namespaced); `report.txt` is the durable log |

## Differential oracle (oracle = `lua5.5.0`)

- `os.date(fmt, t)` string output — byte-for-byte (hex-escaped in transit).
- `os.date("*t"/"!*t", t)` table — every field compared.
- `os.time(table)` epoch value — exact integer.
- `os.difftime(a, b)` — exact (`%a` hex float).
- Error wording — position prefix `^.-:%d+: ` stripped, then compared.

## Oracle-free invariants (checked in-driver, under golua)

1. **utc_roundtrip**: `os.time(os.date("!*t", t)) == t` — only asserted when the
   process TZ is itself UTC (gated on `os.date("%z",0)=="+0000"`), because
   `os.time` reads the table as *local* time, so under any offset the round-trip
   legitimately differs by that offset (reference diverges identically).
2. **difftime_id**: `os.difftime(t, 0) == t`.
3. **no Go panic escapes**: a Go-level `panic:`/`goroutine` on stderr is an
   automatic failure (sandbox class).

## Usage

```sh
python3 run.py --all                  # tiers 0,1,2,illegal (deterministic backbone)
python3 run.py --tier 1               # one tier
python3 run.py --tier illegal         # error-path tier only
python3 run.py --tier3 40000 --seed 7 # randomized grind
DATEFUZZ_TZS=UTC,Europe/Berlin python3 run.py --all   # different DST zone
```

`run.py` auto-builds `./golua` from a sibling golua checkout (`../../golua` by
default). Override with `GOLUA_REPO=`, `GOLUA=`, or `REFLUA=`. Exit code is
non-zero when any lead is found.

## Tiers

- **0** — each strftime directive in isolation (primitive, compound, every legal
  `%E`/`%O` pair), in **both** TZ modes (bare local + `!`UTC), over the full
  timestamp boundary set; plus `*t`/`!*t` table forms.
- **1** — multi-directive real-world format strings over the boundary set.
- **2** — `os.time(table)` round-trips: coherent base tables, one-field-perturbed
  to its boundaries (incl. out-of-range month=13/day=0/sec=-1 normalization),
  `isdst` toggled; plus `os.difftime` over timestamp pairs.
- **illegal** — unknown `%`-directive, empty/lone `%`, invalid `%E`/`%O` pairs,
  missing required `os.time` fields, non-integer fields, huge/negative time_t.
- **3** — random formats (incl. illegal directives) over random timestamps +
  random `os.time` tables + random `difftime`.

## Timestamp boundaries (`values.py`)

epoch (0), ±1, day/hour/minute units, day-rollover edges, leap days
(2000/2020/2024 Feb 29 ± end-of-day), year/century rollover, US DST transition
instants (spring-forward gap + fall-back ambiguous, ±1s), 2^31 (Y2038) ±1,
−2^31 ±1, year-1 / year-9999 edges, and two extreme time_t that drive the
"date result cannot be represented" branch on both interpreters.

## Confirmed divergences (golua vs lua5.5.0)

All reproduced directly under both interpreters; TZ/locale noted.

| # | env | repro | golua | ref | hypothesis |
|---|-----|-------|-------|-----|-----------|
| A | `TZ=UTC LC_ALL=C` | `os.date("%Z", 0)` (local mode) | `GMT` | `UTC` | golua maps Go's `"UTC"` zone name to `"GMT"` unconditionally; ref only does so for the explicit gmtime (`!`) path — local time under TZ=UTC is `"UTC"`. |
| B | `TZ=UTC LC_ALL=C` | `os.date("!%c", -62135510400)` (year 1) | `Tue Jan  2 00:00:00 0001` | `... 1` | `%c` uses Go's fixed layout `Mon Jan _2 ... 2006` → 4-digit year; ref's `%c`==`%a %b %e %H:%M:%S %Y` is natural-width. `%c`/`%x`/`%X` should expand to primitives, not a fixed Go layout. |
| C | `TZ=UTC LC_ALL=C` | `os.date("!%C", -62135510400)` (century 0) | `00` | `0` | golua forces `%C` to `%02d`; glibc emits the natural-width century for years < 100. |
| D | `TZ=UTC LC_ALL=C` | `os.time{year=2000,month=2,day=29,hour=12,isdst=true}` | error `time result cannot be represented` | `951822000` | golua's `resolveLocalTime` rejects `isdst=true` when no zone in the year is DST; C's mktime honors the hint (shifts one hour) and returns a value. `isdst=true` must never make `os.time` fail. |
| E | `TZ=America/New_York LC_ALL=C` | `os.time{year=2024,month=3,day=10,hour=2,min=30,sec=0}` (spring-forward gap; nonexistent local time) | `1710052200` | `1710055800` | Δ=3600. Go's `time.Date` and C's `mktime` (isdst=-1 default) normalize a nonexistent wall-clock instant in opposite directions. |
| F | `TZ=America/New_York LC_ALL=C` | `os.date("%Y", 67768036191676800)` | `2147485547` | `-2147481749` | The local −5h offset pushes `tm_year` across the INT32 boundary; C overflows the 32-bit `tm_year`, Go does not. Extreme-edge only (year ≈ INT32_MAX). Same family drives `%y`/`%C`/`%x` mismatches at far-out years. |
| G | any TZ, `LC_ALL=C` | `os.date("%Q%R")` | err `invalid conversion specifier '%Q%H:%M'` | err `'%Q%R'` | `expandCompoundSpecifiers` rewrites `%R`→`%H:%M` **before** the scan, so the invalid-specifier error leaks the expanded format tail. Affects `%D %F %r %R %T` when an invalid directive follows. |

A and G are the highest-value, fully-general string-output / error-wording
divergences. D and E are real `os.time` normalization divergences. B, C, F are
edge-of-range (year < 100 or year ≈ INT32) — real but low-frequency.

`corpus/diff_seed1.txt` (deterministic tiers) and `corpus/diff_seed7.txt`
(40k random) collapse entirely into families A–G; the random grind surfaced no
new family.

## Coverage gaps / caveats

- Only two TZs exercised by default (UTC + US Eastern). Southern-hemisphere DST
  (e.g. `Australia/Sydney`) and fractional-offset zones (`Asia/Kathmandu`,
  `+05:45`) are reachable via `DATEFUZZ_TZS=` but not in the default backbone.
- `os.date()`/`os.time()` with **no argument** (current time) is intentionally
  never emitted for differential cases — it is non-deterministic.
- Locale-dependent output is only validated under `LC_ALL=C`; non-C locales are
  out of scope (and golua has no locale tables anyway).
