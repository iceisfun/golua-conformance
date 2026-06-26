# bytecodefuzz

**Oracle-free** VM-robustness fuzzer that drives golua with malformed *bytecode*
(`load(chunk, name, "b")`).

Executing a maliciously crafted binary chunk is documented as unsafe in *every*
Lua (manual §6.1 — no interpreter ships a bytecode verifier), so a crafted proto
that loops forever or errors is *expected* and not a finding. What this fuzzer
hunts is a **golua-specific** uncatchable host crash: a Go slice-out-of-range
panic / nil-deref / SIGSEGV that escapes `pcall` when the VM's execute loop
reads a register, constant, upvalue, or jump target from an untrusted proto
without bounds-checking it. Those are Go failure modes that do not exist in C
Lua and that golua — as an embeddable sandbox — should convert into a catchable
Lua error.

This is the follow-up to the `undump` allocation-bound fix (golua
`compiler/undump.go` `readCount`): now that *loading* a malformed chunk is
bounded, *execution* of malformed-but-loadable protos can finally be exercised.

## How it works

1. **Dump.** A corpus of diverse Lua source (arith, loops, multi-return,
   varargs, calls, closures/upvalues, tables, metamethods) is compiled and
   serialized with golua's own `string.dump`.
2. **Mutate (operand-targeted).** The first function body's instruction array is
   located by replaying the undump header/prefix parse, then mutations blow up
   operand fields while leaving opcodes intact, so the chunk still loads but
   addresses out-of-range slots:
   - `opmax` — set B and C bytes (register / RK / constant operands) to 0xFF;
   - `Amax` — blow up the destination register field;
   - `Bxmax` — huge unsigned Bx (constant / proto / upvalue index);
   - `maxstack` — shrink the frame below the registers the code addresses;
   - `rand` / `broad` — random byte flips in the instruction region;
   - `trunc` — truncations.
3. **Execute & detect.** Each mutant is `load(...,"b")` + `pcall`'d under
   `ulimit -v` + `timeout`. An **ESCAPE** is a Go panic / `fatal error:` /
   `goroutine` dump / `runtime:` / SIG\* in output, or a signal/Go-panic exit.
   Hangs are a **soft** signal (crafted loops are expected) and only listed.

There is no reference oracle — crafted bytecode has no defined behavior. The
invariant is "no uncatchable Go panic / fatal / signal — only a catchable Lua
error, a clean result, or a bounded run".

## Usage

```sh
python3 run.py                 # all base protos x deterministic strategies
python3 run.py --rand 200 --seed 1   # add randomized operand/byte mutations
python3 run.py --lua54         # build/test the lua_5_4_8 branch (header 0x54)
```

Env: `GOLUA` (CLI, auto-built), `GOLUA_REPO` (checkout, default `../golua`).

## Status

Clean: **0 escapes** across the deterministic strategies plus thousands of
randomized mutants on both branches. golua's execute loop bounds-checks operand
access, so out-of-range registers/constants from an untrusted proto do not crash
the host. Crafted infinite loops still hang (expected; see golua
`wontfix/untrusted-binary-chunks` — mitigation is to restrict `load` to text
mode in sandboxed embeddings). An empty `corpus/` (only `report.txt`) means
clean; any `escape_*.luac` file is a real finding.
