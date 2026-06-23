# `string.pack` / `string.unpack` / `string.packsize` — Exhaustive State-Machine Test Plan

## Goal

Treat the pack format language as the finite state machine it actually is and
grind it exhaustively (plus a randomized long tail), differentially against
reference `lua5.5.0`. A clean run produces an **empty failure corpus**; we only
keep, inspect, and commit the divergences. The deterministic tiers (0–2) are a
permanent regression backbone; the randomized tier (3) is the "let it run for
hours" grinder.

This is the same idea as fuzzing C `printf`/`scanf`: the format string is a
small regular grammar with bounded numeric arguments, so we can enumerate the
parser states and transition edges rather than hope a random fuzzer stumbles
onto them.

---

## Why this target is special

The pack scanner in `stdlib/string_pack.go` keeps **three parallel copies of the
directive switch**:

- `packsize` (around lines 124 / 290) — predicts encoded byte length
- `pack`     (around line 201)        — encodes values to bytes
- `unpack`   (around line 553)        — decodes bytes back to values

They must stay mutually consistent. That hands us strong invariants that need
**no external oracle** (see "Invariants" below), and the differential pass
against `lua5.5.0` sits on top of those.

Historically the bugs in this surface have all lived in switch-copy divergence
and value-boundary handling:

- `packsize 's' align-order` (29ede68 / backport 5ab4c7a)
- `string.pack` float `"got nil"` arg-count handling (`stdlib/string_pack.go:14`)
- `unpack-s8` Go-panic leak (sandbox-escape class)

---

## The format grammar (alphabet)

Confirmed against `stdlib/string_pack.go`. Endianness/alignment are *state*; the
rest emit or consume data.

### Control directives (no data)
| Token   | Meaning                              | Argument        |
|---------|--------------------------------------|-----------------|
| `<`     | set little-endian                    | —               |
| `>`     | set big-endian                       | —               |
| `=`     | set native endian                    | —               |
| `!n`    | set max alignment                    | `n ∈ [1,16]`, optional (default native) |
| `Xop`   | align to the alignment of option `op`| `op` follows    |
| (space) | ignored                              | —               |

### Fixed-size data directives
`b B` (1) · `h H` (native short) · `l L` (native long) · `j J` (lua_Integer) ·
`T` (size_t) · `f` (float) · `d` `n` (double)

### Sized data directives
| Token   | Meaning                                   | Argument            |
|---------|-------------------------------------------|---------------------|
| `i[n]` `I[n]` | signed/unsigned int of `n` bytes     | `n ∈ [1,16]`, default native int |
| `c n`   | fixed-size char array of exactly `n` bytes| `n` **required**    |
| `s[n]`  | string prefixed by an `n`-byte length     | `n ∈ [1,16]`, default size_t |

### Variable / special
`z` (zero-terminated string) · `x` (one padding byte)

### Known error branches to cover (each is a distinct `panic`)
- `i0`, `i17`, `I0`, `I17` → "integral size (N) out of limits [1,16]"
- `s0`, `s17` → same
- `!0`, `!17` → same
- `c` with no following number → "missing size for format option 'c'"
- `Xop` where `op` is variable-size or absent → "invalid next option for option 'X'"
- pack with too few values / wrong type → "bad argument" / "got nil"
- unpack past end of input → "data string too short"
- `s` length prefix that doesn't fit / overflows
- format that mixes data with too-short input on unpack

---

## Invariants (oracle-free — assert these on every generated case)

1. **packsize agreement:** for any format containing only fixed-size directives,
   `packsize(fmt) == #pack(fmt, values...)`.
2. **Round-trip:** `unpack(fmt, pack(fmt, v...))` recovers `v...`, modulo
   documented float lossiness (`f` is float32; compare with tolerance / by
   re-pack equality, not raw `==`).
3. **Offset accounting:** the trailing position returned by `unpack` equals
   `#packed + 1` — no over- or under-consumption.
4. **No Go panic escapes:** every call is wrapped; a Go-level panic (as opposed
   to a Lua error surfaced through pcall) is an automatic failure (sandbox class).

Invariants 1–4 catch the three-switch-divergence family without reference Lua.

---

## Differential layer (oracle = `lua5.5.0`)

On top of the invariants, run both interpreters and compare:

- **pack:** byte-for-byte identical output (hex-encode for the diff).
- **unpack:** identical decoded values *and* identical trailing position.
- **errors:** identical raised-error message text (this is where parity bugs
  have repeatedly surfaced — message wording, arg-error ordering).

Reuse the existing harness pattern at `/tmp/luadiff/diff.sh`. Always run both
interpreters under `ulimit -v` + `timeout` (see the fuzzing-resource notes in
project memory — reference Lua can OOM the host).

---

## Enumeration tiers

Bounding matters: arbitrary directive sequences are infinite, so the exhaustive
tiers are length-bounded and the unbounded part is randomized + property-checked.

### Tier 0 — single directive × all sizes (exhaustive, instant)
Every directive in isolation across its full legal argument range
(`i1..i16`, `I1..I16`, `s1..s16`, `c0..cN`, `!1..!16`, `Xop` for every op),
**plus** every illegal argument to hit each validation `panic`. A few hundred
cases. This is pure branch coverage of the scanner.

### Tier 1 — alignment matrix (exhaustive, cheap)
`!A · op1 · op2` triples: ~16 alignments × ~18 ops × ~18 ops ≈ 5k cases. This is
the richest vein — padding insertion between adjacent differently-aligned
fields, and `Xop` alignment references. Assert all four invariants + differential.

### Tier 2 — endian transitions (exhaustive, cheap)
Permutations of `< > =` interleaved with multi-byte data directives, to exercise
endian-state changes mid-format.

### Tier 3 — randomized long tail (the grinder)
Length 4..12 random legal directive strings, property-checked against the
invariants (no oracle needed per case) and sampled against the differential.
Seedable; runs for as long as you let it. This is the "grind for hours, discard
if it passes" part.

---

## Value-domain axis (orthogonal to format)

Format is one axis; **value boundaries** are where the non-structural bugs hide.
For each format slot, draw from a boundary set:

- **integers:** `{0, 1, -1, typemax, typemin, typemax+1 (overflow), random}` —
  per width `n`, since `i3` overflow ≠ `i8` overflow.
- **floats:** `{0.0, -0.0, NaN, +Inf, -Inf, smallest subnormal, max, random}`.
- **strings (`s`/`z`/`c`):** `{"", single byte, length == 2^(8n)-1 boundary,
  length just over the `s n` prefix capacity, embedded NULs (esp. for `z`)}`.

The cross-product of (format permutation × value-boundary tuple) is the real
search space.

---

## Harness shape

```
tools/packfuzz/
  grammar.py        # FSM: directive table, legal arg ranges, tier 0-2 enumerators, tier 3 random gen
  values.py         # per-directive-type boundary value tables
  emit.py           # render (fmt, values) -> a tiny Lua script for pack / unpack / packsize
  run.py            # run script under golua + lua5.5.0 (ulimit+timeout), compare, assert invariants
  corpus/           # ONLY divergences land here: {fmt, values, golua_out, ref_out, which_invariant}
```

- Generator is pure Python (no Lua dependency to enumerate).
- Each case becomes a minimal Lua snippet executed by both interpreters.
- Clean run ⇒ `corpus/` is empty. Any file in `corpus/` is a real lead.
- Promote confirmed, minimized failures into a Go regression test
  (`string_pack_test.go` / a doctest) so they stay fixed.

---

## Run discipline (from project memory)

- Always bound `-fuzztime` / iteration count and parallelism; prior runs have
  exhausted host RAM. Current host: 128GB.
- Run **both** interpreters under `ulimit -v` + `timeout` every time.
- Reference build: PATH `lua5.5.0` is the 5.5.0 oracle; PATH `lua` is 5.4.8.
  This plan targets **master (5.5)**; a 5.4.8 backport would diff against `lua`.

---

## Definition of done

- Tiers 0–2 run to completion with an empty failure corpus.
- Tier 3 runs a sustained grind (target: hours) with no new divergences.
- Every divergence found is root-caused, fixed, and pinned by a Go regression test.
- The deterministic enumerator (Tiers 0–2) is checked in as a repeatable test,
  gated behind an env flag like the existing `GOLUA_LUA55_TESTS` suite so CI can
  opt in.
