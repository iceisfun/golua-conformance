# lua55vm — a Lua 5.5 interpreter written in Lua

A self-hosted Lua 5.5 interpreter: a lexer, parser, bytecode compiler and
register-based virtual machine, all written in pure Lua. It runs on the host
Lua runtime (Lua 5.4 for fast development) and **unchanged on
[golua](https://github.com/iceisfun/golua)** (the Lua 5.5 reference used as the
behavioral oracle).

```
Lua source ──▶ lexer ──▶ parser ──▶ AST ──▶ compiler ──▶ guest bytecode ──▶ VM ──▶ result
```

## Why

1. Produce a correct Lua implementation written in Lua.
2. Use the official Lua / golua implementation as a behavioral oracle.
3. Exercise the golua runtime through very different execution paths
   (`golua → lua55vm (Lua) → guest program`), increasing confidence in golua's
   semantics. Nested interpretation (`golua → VM → VM → program`) works too.

Correctness is prioritized over performance.

## Layout

| File | Responsibility |
|------|----------------|
| `lexer.lua`    | Tokenizer: keywords, names, numbers (int/float/hex/hex-float, subtype preserved), short/long strings & comments, all operators, source positions |
| `parser.lua`   | Recursive-descent parser → AST (full 5.5 grammar: attribs, goto/labels, numeric/generic for, method calls, varargs, table constructors) |
| `compiler.lua` | AST → register bytecode: register allocation, constants, jumps, closures/upvalues (open/close), tail calls, multi-return/vararg, local-variable debug info |
| `vm.lua`       | Bytecode interpreter: registers, call frames, closures, **proper tail calls**, metamethod dispatch, errors/pcall, varinfo error annotations |
| `runtime.lua`  | Value model (guest tables/closures/threads), metamethod dispatch, arithmetic/comparison/concat/length, tostring/tonumber, chunk-id formatting |
| `stdlib.lua`   | Standard library (host-backed where safe): base, string, table, math, os, io, coroutine, debug, utf8, package/require, bit32 |
| `init.lua`     | Builds a fully-equipped interpreter instance |
| `run.lua`      | CLI driver |
| `scripts/`     | `difftest.sh` (differential vs oracle), `run_corpus.sh`, `dis.lua` (disassembler) |
| `tests/`       | Hand-written regression corpus |
| `docs/`        | `findings.md` — notable Lua 5.4→5.5 differences found while building |

## Running

```sh
# run a script through the guest interpreter (host = lua 5.4)
lua run.lua script.lua

# run it through the guest interpreter hosted on golua (Phase 5)
golua run.lua script.lua

# differential test one file against the golua oracle
GOLUA=/path/to/golua scripts/difftest.sh script.lua

# run the regression corpus
scripts/run_corpus.sh

# disassemble a chunk
lua scripts/dis.lua -e 'local x = 1 + 2 print(x)'
```

## Design notes

- **Values map to host values.** nil/boolean/number/string are host values, so
  integer/float subtype semantics come for free on a 5.4/5.5 host. Tables,
  closures and threads are tagged host tables.
- **`#` and table internals delegate to the host backing table**, so the length
  border algorithm matches the host (and therefore golua) exactly.
- **Closures use open/close upvalues** like reference Lua; loop bodies and
  `goto` emit `CLOSE` so each iteration captures fresh variables.
- **Tail calls reuse the current frame** (`goto restart`), giving true TCO and a
  configurable call-depth limit matching golua's default (10000).
- **Coroutines map onto host coroutines**, so yields across `pcall` and deep VM
  stacks work for free; each guest coroutine gets an isolated frame stack.
- **Error messages reproduce Lua's variable annotations** ("(local 'x')",
  "(global 'f')", "(field 'y')", "(upvalue 'u')", "(constant 'k')") by scanning
  bytecode (`getobjname`/`varinfo`), and the `luaO_chunkid` short-source
  truncation.

## Status

The hand-written corpus passes fully and a large fraction of the ~1400-file
golua conformance corpus passes via differential testing. Known gaps are tracked
as failing differential tests; the hardest remaining areas are some
to-be-closed (`<close>`) edge cases (exact error lines, `__close` during
coroutine teardown), weak tables / GC observability, `debug.getinfo` name
resolution, and a few impl-specific message quirks.
