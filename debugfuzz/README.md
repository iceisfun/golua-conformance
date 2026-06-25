# debugfuzz

Differential grinder for the **debug library** and the **source line-info model**
(golua's AST/one-pass compiler + VM-frame model vs reference Lua's bytecode +
C-stack model). See the module docstring in `run.py` for the full rationale.

Three channels are diffed against a reference interpreter:

- **LINEHOOK** — visited-line sequence under a `debug.sethook(..,"l")` hook for a
  matrix of `head × tail` statement pairs. A line-info attribution bug shows up
  as a different visited-line trace.
- **ERRLINE** — runtime faults on a "discharge" instruction (index nil, `__index`
  error, arith on nil). The reported error line + traceback must match. This is
  the *user-visible* consequence of a wrong line table.
- **DEBUGAPI** — `debug.getinfo / getlocal / setlocal / getupvalue / setupvalue /
  upvalueid / upvaluejoin / traceback / getmetatable / getregistry` over C / Lua
  / main / vararg / tail-call / coroutine frames, address-normalized.

## Usage

```sh
python3 run.py            # golua master vs lua5.5.0
python3 run.py --lua54    # golua lua_5_4_8 branch vs lua5.4.8
```

`GOLUA_REPO` / `GOLUA` / `REFLUA` env vars override paths.

## Current corpus state (2026-06-25)

`DEBUGAPI` is **clean** (0 leads) on master vs lua5.5.0 — the entire debug.* call
surface matches.

`LINEHOOK` / `ERRLINE` carry **29 leads from a single root-cause bug**:

> The ADDI/SUBI compiler optimization mis-attributes the source line of the
> *previous* statement's instruction.

When a statement of the form `target = <local> ± <smallint∈[-127,127]>` (which
compiles to `OP_ADDI`/`OP_SUBI` via `operandToReg`) immediately follows a
statement whose last emitted instruction is a "discharge" op (LOADI/LOADK/LOADF/
LOADNIL/LOADBOOL/NEWTABLE/GETUPVAL/GETFIELD/GETI/GETTABLE/MOVE…), the discharge
instruction is **relabeled to the arith statement's line**.

Root cause: `compiler/compile_expr.go` ~683 / ~717 call
`c.fixDischargedLine(line)` unconditionally after `operandToReg(e.Left)`, but for
a local already in a register `operandToReg` emits **no** instruction, so
`fixDischargedLine` relabels the unrelated prior instruction (compiler.go:600).
The generic arith path is safe because it emits a MOVE for the left operand.

Impact: wrong line hooks/step-debugging AND **wrong runtime error line +
traceback** when the relabeled instruction faults (e.g. indexing a nil local).

```lua
local a = 1
local t = nil
local v = t.x   -- line 3  (real fault site)
a = a + 1       -- line 4  (ADDI relabels the line-3 GETFIELD to line 4)
-- golua: "...:4: attempt to index a nil value"   ref: "...:3: ..."
```

This corpus stays non-empty until the bug is fixed. Likely affects both
`master` and `lua_5_4_8` (same codegen family) — verify on the 5.4.8 branch.
