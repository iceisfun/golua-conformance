# formatfuzz — state-machine grinder for `string.format`

Treats the printf-style `string.format` conversion-spec language as the finite
state machine it is and grinds it exhaustively (plus a randomized long tail),
differentially against reference `lua5.5.0` **and** against oracle-free
invariants. Modeled directly on `../packfuzz/`. Any file in `corpus/` is a real
lead; a clean run leaves it empty except `.gitkeep`/`report.txt`.

## Surface

A spec is `% [flags] [width] [.precision] conversion`. Covered conversions
(verified present in golua and `lua5.5.0`):

| group   | conversions  | argument                                   |
|---------|--------------|--------------------------------------------|
| integer | `d i u o x X`| lua_Integer (number w/ integer rep; coercible string) |
| float   | `e E f F g G a A` | float / number / numeric string       |
| string  | `s`          | anything (via `tostring`); NUL → "contains zeros" |
| char    | `c`          | byte code (wraps to one byte)              |
| quote   | `q`          | string / integer / float / nil / true/false |
| pointer | `p`          | any (value is non-deterministic — see below) |
| literal | `%%`         | none                                       |

Flags `- + space # 0`; width/precision digits (Lua has **no** `*` — `%*d`
errors; verified). Lua rejects length modifiers (`%hd %ld …`) and positional
(`%2$d`) — exercised in the illegal tier.

## Layout

| File         | Role                                                                 |
|--------------|----------------------------------------------------------------------|
| `grammar.py` | conversion table, legal flag/width/prec ranges, tier 0–3 + illegal enumerators |
| `values.py`  | per-conversion argument typing + boundary value tables (+ wrong-type tuples) |
| `emit.py`    | renders a batch of `(fmt, args)` cases into one self-contained Lua driver |
| `run.py`     | runs the driver under golua **and** `lua5.5.0`, diffs, checks invariants |
| `corpus/`    | only divergences land here                                           |

One Lua driver runs many cases per process (batched) under both interpreters
with `ulimit -v` + `timeout`; output is canonical, position-stripped, diffed
line-by-line.

## Tiers

- **0** — each conversion bare + with each single flag + a width + a precision
  (branch coverage of the spec scanner).
- **1** — legal flag-combos × width × precision, per conversion.
- **2** — value-domain stress: ints `{0,1,-1,maxint,minint,255,256}`; floats
  `{0,-0,inf,-inf,nan,subnormal,huge,random}`; strings `{empty,high-byte,NUL,
  long}`; `%q` over all reloadable kinds.
- **3** — random multi-conversion format strings paired with random typed args.
- **illegal** (`--illegal`) — unknown conversions (`%y`…), trailing `%`, missing
  argument, wrong-type argument (`%d` w/ float lacking integer rep, `%d` w/
  string, `%c` w/ float), length modifiers, positional/`*`, oversized
  width/precision, illegal flag/conv combos.

## Oracle-free invariants (checked inside the driver, under golua)

1. **`%q` round-trip** — `load("return "..format("%q", v))()` equals `v`. Floats
   are compared via `%a` (bit-exact) so inf/nan/`-0`/subnormals round-trip
   correctly; strings/ints/bools/nil compared by value.
2. **no Go panic escapes** — a Go-level `panic:`/`goroutine`/`runtime error` on
   stderr is an automatic failure (sandbox class).

## Differential layer (oracle = `lua5.5.0`)

Byte-identical formatted output (hex) and identical error-message text (only the
`^.-:%d+: ` position prefix is stripped). `%p` is special: the pointer's textual
form (length and digits) is implementation-defined, so `%p` output has its
pointer runs masked to a `<ptr>` token (with adjacent width-padding collapsed)
before comparison — only structural/error differences in `%p` are reported.

## Usage

```sh
python3 run.py --tier 0 --tier 1 --tier 2 --illegal   # deterministic backbone
python3 run.py --illegal                              # the error-parity surface
python3 run.py --tier3 100000 --seed 1                # randomized grind
python3 run.py --all                                  # tiers 0,1,2 + illegal
```

`run.py` auto-builds `./golua` from a sibling golua checkout (`../../golua` by
default — `~/work/golua`). Override with `GOLUA_REPO`, `GOLUA`, or `REFLUA`.
Exit code is non-zero when any lead is found. `corpus/report.txt` gets one
durable line per invocation; leads land in seed-namespaced files.

## Known finds (real golua↔reference divergences, error-ordering family)

Both are error-message/ordering parity bugs — no value corruption, no panic. Both
reproduce deterministically via `python3 run.py --illegal`.

1. **`%F` with oversized width/precision.** `string.format("%123F", 1.0)`:
   - golua: `invalid conversion specification: '%123F'`
   - ref:   `invalid conversion '%123F' to 'format'`

   Bare `%F` / `%5F` already match (`...to 'format'`); only the width/precision
   ≥100 variant diverges. Root cause: `stdlib/string_format.go` runs
   `validateFormatWidthPrec` (the width<100 check) *globally before* the
   per-conversion switch, so the oversized-width error fires before the `%F`
   case can report it as an unsupported conversion. Reference's `str_format`
   reaches `default:` ("...to 'format'") for `F` without ever running
   `checkformat`/the digit-count check.

2. **`%s` with oversized width/precision AND a NUL-containing argument.**
   `string.format("%100s", "a\0b")`:
   - golua: `invalid conversion specification: '%100s'`
   - ref:   `bad argument #2 to 'string.format' (string contains zeros)`

   With a NUL-free string both agree on the spec error. Root cause: same global
   `validateFormatWidthPrec` runs before golua's `'s'` case, whose "string
   contains zeros" check sits *after* it; reference checks the argument's
   zero-content first (`str_format` `case 's'` does the `string contains zeros`
   `luaL_argcheck` before its own `checkformat`).

## Notes / not covered

- `%p` value is intentionally not compared (implementation-defined); only its
  error/structure behaviour and width-spec handling are differential.
- Coercion behaviour (`%d` on the string `"12"`, `%s` on numbers/bools/nil)
  matches reference and is covered.
