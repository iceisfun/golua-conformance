# compilefuzz

Differential **compiler-limit / deep-nesting** grinder — a compile-time finder
(it compares what `load()` *accepts/rejects*, not what programs compute).

golua's hand-written compiler must accept/reject exactly the programs reference
Lua does and emit the same limit diagnostics. This sweeps each compiler limit
and structural-nesting axis across sizes that bracket the known boundary,
compiles each candidate with `load()` under a fixed chunk name, and diffs
(accept/reject + error core) golua vs the reference. It also asserts the
oracle-free invariant that even pathologically deep/large source only ever
yields a **catchable** error — never an uncatchable host crash (Go fatal stack
overflow / OOM) — since `load()` is reachable from sandboxed code.

## Axes

- **Counting limits** (swept around their boundary): locals (200), upvalues,
  function params, call args, table fields (array & record), `and`/`or` chain
  length, return values, multiple-assignment targets.
- **Structural nesting** (swept into the parser's C-stack bound): parens,
  arithmetic, concat, **index/field chains**, blocks, functions, `if`/`for`,
  unary `-`/`not`, nested table constructors.
- **Jump distance**: huge straight-line blocks under a `goto`/`break`.

## What it found

- **Compile-time O(n²) DoS**: after a "too many local variables" error the
  compiler kept walking every remaining statement (O(active-locals) each), so a
  200k-local chunk took ~18s instead of stopping at the limit — fixed (golua now
  aborts at the first error, like reference's longjmp).
- **Register over-allocation in chains**: `t.a.b.c…` / `t[1][1]…` and
  `a and b and …` / `… or x` reserved a register per level and hit the
  255-register limit at depth ~255 on programs reference compiles — fixed (reuse
  one register down the chain).

## Normalized / won't-fix

`normalize_err` collapses the location *tail* of a limit diagnostic (the
`in (main) function` suffix + the `near '<tok>'`/`<eof>` token + the exact line),
which differs by a token at the boundary — message wording, not a conformance
bug. It also strips the stack traceback reference's `load()` bakes into the
`"C stack overflow"` message, and the C-stack-vs-fixed-limit case (reference's
recursive `restassign` on a ~200-target assignment trips the C stack while
golua's iterative parser rejects with a different fixed limit). All documented
in golua `wontfix/load-stack-overflow-traceback`.

## Usage

```sh
python3 run.py                 # full sweep
python3 run.py --max 4000      # raise the deep-nesting ceiling
python3 run.py --lua54         # golua lua_5_4_8 branch vs lua5.4.8
```

Env: `GOLUA`, `GOLUA_REPO` (default `../golua`), `REFLUA` (default `lua5.5.0`).

## Status

Clean: 0 DIFFs / 0 escapes across the sweep after the two compiler fixes above.
