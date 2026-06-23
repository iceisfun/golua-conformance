# patternfuzz — differential grinder for Lua string pattern matching

Treats the Lua pattern language as the small grammar it is and grinds it
exhaustively (plus a randomized long tail) across all four entry points —
`string.find`, `string.match`, `string.gmatch`, `string.gsub` — differentially
against reference `lua5.5.0` **and** against oracle-free invariants. A clean run
leaves `corpus/` empty; any file there is a real lead. Modeled directly on the
sibling `packfuzz/` tool.

## Why this target

Lua's pattern matcher is a hand-written backtracking engine (`stdlib/pattern.go`
+ `stdlib/string.go`) with subtle corners: capture materialization, position vs
string captures, back-references, `%b`/`%f`, set parsing edge cases (`]` first
member, `^`/`-` edges), anchoring semantics that differ between `gsub` and
`gmatch`, and four *replacement* forms in `gsub` (string `%N`, function, table,
numbered) that each touch captures differently. Malformed patterns must produce
**identical error wording** on both interpreters — historically prime bug
territory.

## Layout

| File         | Role                                                                      |
|--------------|---------------------------------------------------------------------------|
| `grammar.py` | pattern enumerator: classes/magic/quantifiers/sets/captures, tiers 0–3 + illegal |
| `values.py`  | subject-string corpora (fixed battery + randomized) spanning byte classes |
| `emit.py`    | renders a batch of `(pattern, subject)` cases into one self-contained Lua driver |
| `run.py`     | runs the driver under golua **and** `lua5.5.0`, diffs, checks invariants   |
| `corpus/`    | only divergences land here                                                |

One Lua driver runs many cases per process (batched) under both interpreters
with `ulimit -v` + `timeout`; output is canonical, position-stripped, and diffed
line-by-line. Patterns and subjects are transported as `\xNN`-escaped literals so
the exact same bytes reach both interpreters.

## Per-case operations (canonical output lines)

- `F`  `string.find`   — ok/nomatch/err, `[s,e]`, captures
- `M`  `string.match`  — ok/nomatch/err, captures (or whole match)
- `G`  `string.gmatch` — ok/err, full iteration sequence (capped at 200 iters)
- `S`  `string.gsub` with string repl `"<%0>"`  — result + count
- `S1` `string.gsub` with numbered-capture repl `"[%1]"`
- `SF` `string.gsub` with function repl
- `ST` `string.gsub` with table repl (`__index` metatable)

## Oracle-free invariants (checked inside the driver, under golua)

1. **find_bounds** — `find`'s `[s,e]` satisfy `1 <= s` and `e >= s-1`.
2. **count_eq** — `gsub` replacement count == number of `gmatch` iterations
   (restricted to non-anchored patterns; a leading `^` anchors `gsub` per
   position while `gmatch` ignores anchoring, so the counts legitimately differ
   there — and both interpreters agree on that difference).
3. **find_span** — capture-free matched span length is recorded for diffing.
4. **no Go panic escapes** — a Go-level `panic:`/`goroutine` on stderr is an
   automatic failure (sandbox class).

## Differential layer (oracle = `lua5.5.0`)

Identical match indices + captures (`find`), identical captures (`match`),
identical full match sequence (`gmatch`), identical result string + count for
every `gsub` replacement form, and identical error-message text (only the
`^.-:%d+: ` position prefix is stripped).

## Usage

```sh
python3 run.py --all                 # tiers 0,1,2 + illegal (deterministic backbone)
python3 run.py --tier 1              # one tier
python3 run.py --illegal             # malformed-pattern wording tier only
python3 run.py --tier3 50000         # randomized grind: 50k random patterns
python3 run.py --tier3 2000000 --seed 7   # the "let it run for hours" mode
```

`run.py` auto-builds `./golua` from a sibling golua checkout (`../../golua` by
default — i.e. `~/work/golua` when this repo is `~/work/golua-conformance`) on
first run. Override the checkout with `GOLUA_REPO=/path/to/golua`, the binary
with `GOLUA=/path/to/golua`, or the reference with `REFLUA=/path/to/lua5.5.0`.
Exit code is non-zero when any lead is found. `corpus/report.txt` gets one
durable line per invocation (clean or not); leads land in seed-namespaced files.

## Tiers

- **0** — every class / `%<punct>` escape / magic char / quantifier / anchor in
  isolation (branch coverage of the matcher).
- **1** — set construction (`[abc]`, `[^abc]`, ranges, classes-in-sets, `]`/`^`/`-`
  edges) and class+quantifier sequences.
- **2** — captures (plain, nested, position `()`), anchors, `%b`, `%f`,
  back-references `%1..%9`, and common composite patterns (trim, key=value).
- **3** — random patterns over the full vocabulary (skewed toward magic chars so
  random patterns frequently form sets/captures/quantifiers/escapes).
- **illegal** — malformed patterns whose **error wording** must match: trailing
  `%`, unclosed `[`, `%b` argument shortfall, `%f` without a set, invalid capture
  index, unfinished captures, malformed sets.

## Known finds

- **`string.gsub(s, pat, <table>)` over-validates captures.** For a pattern whose
  *first* capture is valid but a *later* capture is unfinished (e.g. `()(`),
  golua raises `unfinished capture` for the **table** replacement form, while the
  reference succeeds. Minimal repro: `string.gsub("ab", "()(", {})` → golua errors
  `unfinished capture`; ref returns `"ab", 3`. Root cause: `stdlib/string.go`
  calls `checkCaptures(matchCaps)` (validates **all** captures) on the table path,
  but `lookupGsubTable` only ever uses `captures[0]`. The reference materializes
  only the first capture for table-repl (same as string-repl), so it never
  touches the broken later capture. The string-repl path is already correct
  (it validates lazily, only when `%N` references the capture); the function-repl
  path correctly errors on both (it passes all captures to the function).
  Surface: `find`/`match`/`gmatch`/`gsub`-string/`gsub`-function all agree; only
  `gsub`-table diverges.
