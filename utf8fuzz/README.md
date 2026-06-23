# utf8fuzz — differential + invariant grinder for the `utf8` library

Grinds golua's `utf8` library against reference `lua5.5.0` (PUC-Rio Lua 5.5.0)
**and** against oracle-free invariants. Built on the same machinery as
`../packfuzz`: one batched Lua driver per process, run under both interpreters
with `ulimit -v` + `timeout`, canonical position-stripped output diffed
line-by-line. A clean run leaves `corpus/` empty; any file there is a real lead.

## Why this target

golua's strict decode path uses Go's `unicode/utf8`, while C Lua hand-rolls its
decoder (`lutf8lib.c`). The two disagree on malformed input — overlong forms,
surrogates, truncated sequences, lone continuation bytes, illegal lead bytes —
and on the `lax` flag and the extended (Lua-only) range up to `0x7FFFFFFF`.
golua has historically had `utf8.offset` continuation-byte parity bugs, so the
malformed/boundary space is hammered hardest.

## Surface

`utf8.char`, `utf8.codepoint(s,i,j[,lax])`, `utf8.len(s,i,j[,lax])`,
`utf8.offset(s,n[,i])`, `utf8.charpattern`, and `for p,c in utf8.codes(s[,lax])`.

## Layout

| File         | Role                                                                |
|--------------|---------------------------------------------------------------------|
| `values.py`  | codepoint boundary table + raw-byte malformed table + index args    |
| `grammar.py` | tier 0–3 case generators (subject string × op battery)              |
| `emit.py`    | renders a batch of cases into one self-contained Lua driver         |
| `run.py`     | runs the driver under golua **and** `lua5.5.0`, diffs, checks INVs  |
| `corpus/`    | only divergences land here                                          |

## Differential oracle (vs `lua5.5.0`)

For every op: `utf8.char` output bytes; `utf8.codepoint` values + error wording;
`utf8.len`'s normal return **and** its `(false/nil, pos)` form on invalid bytes;
`utf8.offset` positions (n=0 special case, negative n, the 5.5 two-value
start/end return); the full `utf8.codes` iteration sequence + error on bad bytes;
`utf8.charpattern` bytes. Error wording is compared after stripping only the
`^.-:%d+: ` position prefix.

## Oracle-free invariants (checked inside the driver, under each interpreter)

1. **roundtrip** — `utf8.char(utf8.codepoint(s,1,-1)) == s` for strict-valid `s`.
2. **len_eq_cps** — `utf8.len(s) == #{utf8.codepoint(s,1,-1)}`.
3. **offset_walk** — stepping `utf8.offset(s,1,p)` / `utf8.offset(s,2,sp)` visits
   exactly the same `(position, codepoint)` sequence as `utf8.codes(s)`.
4. **no Go panic escapes** — a Go-level `panic:`/`goroutine` (or `runtime error`)
   on stderr is an automatic failure (sandbox class).

## Tiers

- **0** — each function over single codepoints across the full boundary table
  (`0 .. 0x7FFFFFFF`), incl the extended boundary `0x10FFFF / 0x110000 /
  0x7FFFFFFF / +1` and illegal `utf8.char` inputs.
- **1** — multi-codepoint **valid** strings (deterministic boundary combos +
  random valid sequences, with an extended-range band).
- **2** — the curated **malformed/boundary byte table**: overlong encodings,
  surrogates, truncated multibyte, lone continuation bytes, illegal leads
  (`0xC0/0xC1/0xF5..0xFF`), each × full op battery × a negative/OOB index sweep
  × `lax` on/off.
- **3** — randomized long tail: (a) random valid codepoint sequences and
  (b) random raw byte strings, with random `lax`, index, and offset probes.

The `lax` flag and the `i/j/n` index args (negative, zero, out-of-range) are
exercised in every tier.

## Usage

```sh
python3 run.py --all              # tiers 0,1,2 (deterministic backbone)
python3 run.py --tier 2           # one tier
python3 run.py --tier3 60000      # randomized grind: 60k random cases
python3 run.py --tier3 30000 --seed 7
```

`run.py` auto-builds `./golua` from a sibling golua checkout (`../../golua` by
default). Override with `GOLUA_REPO=…`, `GOLUA=/path/to/golua`, or
`REFLUA=/path/to/lua5.5.0`. Exit code is non-zero when any lead is found.
`corpus/report.txt` gets one durable line per seed; leads land in
seed-namespaced files (`corpus/diff_seed3.txt`, etc.).

## Status

Tiers 0–2 plus ~270k randomized cases (seeds 1–6) run **CLEAN**: byte-identical
output and identical error wording on every op, and all invariants hold under
both interpreters. golua's hand-tuned extended-UTF-8 decoder matches 5.5.0
across the malformed/overlong/surrogate/lax space probed here, including the
two-value `utf8.offset` return and the extended `0x7FFFFFFF` `utf8.char` range.
