# rubegoldberg

A **semantic** program generator: it builds *valid, deterministic* Lua programs
by composing individually-correct "semantic stages" into a deep machine — long
chains of correct operations that compute one deterministic result. Unlike a
syntax fuzzer (malformed input) or `bytecodefuzz` (malformed bytecode), every
program here is legal, terminating, and over-engineered on purpose; the
complexity is **emergent from composition** (closures feeding coroutines
feeding pattern matches feeding self-modifying metatables …). Any behavioral
divergence between golua and the reference shows up as a different printed
integer or a different error/no-error outcome.

This is the generator described in the project SOW. v1 is a working, extensible
core: stage library, depth-scaling generator, differential harness with a
non-determinism guard, classifier, and an automatic stage-level reducer.

## Design

* **Integer spine.** Each stage is an `int -> int` transform (`stages.py`);
  internally it is rich (builds strings, tables, coroutines, metatables,
  closures, iterators, patterns), but the value flowing *between* stages is a
  single integer. This keeps composition trivial and false positives near zero.
* **Per-stage transcript + error capture (the observable).** The driver runs
  each stage under `pcall` and records, for every stage, a transcript line that
  is **either** its result **or** its caught error message *with line number*
  (`i:name:VAL` / `i:name:ERR <chunk>:<line>: <msg>`). The full transcript is
  diffed — not just a final integer — so the harness sees *intermediate* result
  divergence **and** error-message/line-attribution divergence (e.g. a runtime
  error reported on the wrong line, or worded differently). The caught error's
  chunk name is the temp file's path, identical for the golua and reference runs
  of the same file, so line + text compare directly. Error stages
  (`err_*_ml`) deliberately split the faulting operator/field across lines to
  stress line attribution. `v` is left unchanged when a stage errors.
* **Determinism is enforced** by construction — stages use integer math only
  (no floats / `^` / `/`), never `math.random` / `os.*` / `io.*` /
  `collectgarbage`, never rely on `pairs` order, never `tostring` a table or
  function, and fold any error into the integer rather than printing message
  text. A program that is accidentally non-deterministic is caught and
  discarded by running the **reference twice** and comparing.
* **Stages** (`stages.py`): arithmetic/bitwise, digit-sum over `string.format`,
  prime sieve, closure factories with shared upvalues, coroutine generators,
  stateful filter/map iterators, `gsub` with a counting function, pattern
  captures, **stateful metatables** (`__add` cycles op by invocation count),
  **self-modifying metatables** (`__index` rewrites itself mid-lookup),
  `table.sort` with a comparator, recursion (gcd), `pcall` round-trips, vararg
  `select`, deep lexical shadowing; **error stages** (`err_*_ml`) that split a
  faulting operator/field across lines to stress error-line attribution;
  **float/format stages** (`float_format_battery`, `math_exact`,
  `intfloat_boundary`) that emit `%g`/`%.Ng`/`%#g`/`%e`/`%a`/`tostring` and the
  int-vs-float result typing of `math.floor/ceil/modf/fmod/tointeger/type/...`
  over deterministic exact values; and **terminal/negative stages**
  (`assert_flag`, `error_terminus`) that deliberately raise so the differential
  also covers the failure path (assert / `error` level semantics + value
  formatting in the message). Add more by dropping a generator into `STAGES`
  (follow the determinism rules in the module docstring).

## Pipeline

```
generate(depth stages) → run golua + reference (ulimit+timeout)
  → classify → on DIFFERENTIAL FAILURE: reduce (delta-debug by removing stages)
  → persist minimal reproducer to corpus/
```

Classification (only differential failures are kept):

| verdict | meaning |
|---|---|
| `PASS` | golua output == reference output |
| `DIFF` | golua != reference, reference deterministic, golua didn't resource-fail → **a real golua bug** |
| `RESOURCE` | either side OOM/timeout/crash → skipped (that's `sandboxfuzz`/`bytecodefuzz`) |
| `NONDET` | the reference's own two runs differ → discarded |
| `INVALID` | reference errored at parse/compile → discarded |

## Usage

```sh
python3 run.py                        # 300 programs, depth 12
python3 run.py --count 5000 --depth 40 --seed 1 --keep-going
python3 run.py --lua54                # golua lua_5_4_8 branch vs lua5.4.8
python3 run.py --replay corpus/diff_000.lua
```

Env: `GOLUA` (CLI, auto-built), `GOLUA_REPO` (default `../golua`), `REFLUA`
(default `lua5.5.0`; `lua5.4.8` under `--lua54`).

A differential failure writes `corpus/diff_NNN.lua` (minimized reproducer) and
`corpus/diff_NNN.txt` (both engines' output + the stage chain). An empty
`corpus/` (only `report.txt`) means clean — golua matched the reference on every
generated machine.

## Roadmap (from the SOW)

v1 ships the spine, stage library, differential+reduce loop. Natural extensions:
multi-type typed-node graph (not just an int spine), richer mutation/expansion
operators (outline/inline, wrap-in-coroutine/pcall), embedded reference
algorithms (red-black/AVL/trie, KMP/Boyer-Moore, JSON/expression parsers) as
stages, cross-object metatable-mutation networks, and CI wiring.
