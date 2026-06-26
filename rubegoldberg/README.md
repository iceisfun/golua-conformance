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
  single integer. This keeps composition trivial and the differential signal
  unambiguous (`print(v)` at the end), with near-zero self-inflicted false
  positives.
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
  `select`, and deep lexical shadowing. Add more by dropping a generator into
  `STAGES`.

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
