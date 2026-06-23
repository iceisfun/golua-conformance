# coercionfuzz — differential grinder for type coercion & operator semantics

Runs every operator over every operand-type pair under **both** golua and the
reference interpreter `lua5.5.0`, diffing canonical output line-by-line. The
whole game on this surface is **ordering**: string→number coercion vs which
operand's metamethod is tried vs which error fires first. Cases are cheap
(thousands), so the structural tiers are enumerated exhaustively. A clean run
leaves `corpus/` empty (modulo `.gitkeep`); any file there is a real lead.

Modeled on `../packfuzz/` — the `run.py` build/run/diff/corpus/report machinery
is reused almost verbatim; only the case model (an *expression*, not a
`(fmt,vals)` pair) and the tier wiring differ.

## Layout

| File         | Role                                                                     |
|--------------|--------------------------------------------------------------------------|
| `values.py`  | the operand model: plain literals + metatable'd tables (one observable metamethod each) |
| `grammar.py` | operator tables, tier enumerators, and the dedicated `ordering()` tier    |
| `emit.py`    | builds the metatable prologue + renders each case into one pcall-wrapped canonical line |
| `run.py`     | runs the driver under golua **and** `lua5.5.0`, diffs, watches for Go panics |
| `corpus/`    | only divergences land here                                               |

## Canonical output

Each case runs as `local ok,r = pcall(function() return <expr> end)`. On success
the line is `OK <tag> <value>`, with `math.type` distinguishing integer/float,
`%a` for floats, and `-0.0`/`+0.0`/NaN/Inf canonicalized; tables/functions/
threads are tagged by **type, not identity**. On error: `ERR <stripped-message>`
(only the `chunk:line: ` position prefix is stripped). Metamethods return a
deterministic sentinel `"MM:<event>"`, so *which* metamethod fired is the only
identity that leaks — exactly what makes dispatch observable. Pointer addresses
in `tostring`/`%s` output are masked (`0xPTR`) so they never spuriously diverge.

## Operand set

`nil true false`, integers `0 1 -1`, floats `0.0 -0.0 NaN +Inf -Inf`, the string
battery `"" " " "0" "00" "1" "-1" "+1" "1e3" "1e309" "0x10" "  5  " "0x1p4" "inf"
"nan" "abc"`, and the reference types `{}` (two distinct ones, for `__eq` /
raw-equality), `function`, and `thread` (coroutine). **Userdata coverage gap:**
golua represents host objects (e.g. file handles) as Lua *tables*, not userdata,
so there is no portable userdata operand both interpreters agree on; the
coroutine `thread` stands in as the representative opaque non-table reference
type.

Metamethod operands are tables carrying exactly one (or, for combos, a subset)
of `__add __sub __mul __div __mod __pow __idiv __unm __band __bor __bxor __bnot
__shl __shr __eq __lt __le __concat __len __index __newindex`.

## Operators / contexts covered

Binary arithmetic `+ - * / % // ^`; bitwise `& | ~ << >>` (own integer-repr
coercion rule); comparison `< <= > >= == ~=`; concat `..`; unary `-A #A ~A
not A`; table indexing `t[A]` read & write and integer/float **key
normalization**; numeric-`for` bounds/step coercion; and a representative set of
library coercion contexts (`math.*`, `string.*`, `tonumber`/`tostring`).

## Tiers

- **0** — full plain `operand × operand × binop` matrix + plain unops (≈17k).
- **1** — metamethod dispatch matrix: one operand a metatable'd table (single
  metamethod, returning a sentinel), the other ranging — which side, raw-operand
  passing, error-vs-metamethod precedence (≈17k).
- **2** — indexing read/write, key normalization (`t[1]` vs `t[1.0]`, `t[2^53]`,
  string-vs-number key distinctness), numeric-for bounds, library coercion (≈380).
- **ordering** — hand-picked cases for the four canonical precedence questions
  (string-convertible? metamethod-vs-conversion? which side? error-first?) (≈150).
- **3** — randomized differential grind (random op, random operands incl. random
  metatable subsets).

## Usage

```sh
python3 run.py --all                 # tiers 0,1,2 + ordering (deterministic, ~1min)
python3 run.py --tier 1              # one tier
python3 run.py --ordering            # just the precedence tier
python3 run.py --tier3 30000 --seed 1
```

`run.py` auto-builds `./golua` from a sibling golua checkout (`../../golua` by
default). Override with `GOLUA_REPO=`, `GOLUA=`, or `REFLUA=`. Exit code is
non-zero when any lead is found. Every interpreter invocation runs under
`ulimit -v` + `timeout`; a Go panic escaping golua's stderr is an automatic
(sandbox-class) failure.

## Known finds

1. **Empty-string constant drops the bitwise-error variable annotation.**
   `0 & ""` → golua `attempt to perform bitwise operation on a string value`;
   reference adds `(constant '')`. Non-empty constants (`0 & "abc"` →
   `(constant 'abc')`) and named variables both match. Root cause:
   `vm/vm_error.go varInfo()` guards with `if name != ""`, which discards the
   legitimately-empty constant name returned by `regObjName` (`what="constant",
   name=""`).

2. **`-0.0 - (0)` constant-fold parity gap.** Parenthesizing the RHS integer
   operand stops golua's constant folder but not PUC-Lua's:
   `-0.0 - 0` folds to `+0.0` on both; `-0.0 - (0)` → reference still folds to
   `+0.0`, golua falls to the runtime path and yields the (IEEE-correct) `-0.0`.
   Pure-runtime (`local a=-0.0; local b=0; a-b`) agrees (`-0.0`) on both.

Both are *find-and-minimize only* — no golua source was modified.
