# sandboxfuzz

**Oracle-free** sandbox-robustness fuzzer. golua's headline guarantee is that
*sandboxed* Lua cannot crash or hang the host Go process — every adversarial
input must surface as a **catchable Lua error** (or a clean bounded result),
never an uncatchable Go panic / `runtime.throw` OOM (which `recover()`/`pcall`
cannot catch) / SIGSEGV, and never an unbounded hang doing bounded work.

This is an **invariant, not a parity check**, so unlike the differential finders
it keeps working now that the differential tail is nearly dry. It targets the
failure modes that exist *because golua is Go* and have no analogue in C Lua:
nil deref, slice out-of-range, integer `MinInt/-1`, goroutine stack exhaustion,
and runtime OOM from unbounded allocation.

## How it works

Each case does **bounded** work and is wrapped in `pcall`, then run under
`ulimit -v` + `timeout`. A correct golua exits 0 printing `true`/`false ...`.
The fuzzer flags:

- **ESCAPE** (fails the run): stderr shows `panic:` / `fatal error:` /
  `goroutine NN` / `runtime:` / a signal, or the process dies by signal
  (exit > 128) or Go-panic exit (2). These are host crashes.
- **HANG** (soft signal, review): the case times out despite doing bounded work.
  Some hangs are *correct* — a proper tail-call loop or an unbounded-but-valid
  `table.move` count hangs on reference Lua too; those are not golua bugs (a
  sandbox embedder bounds them with a context timeout / instruction limit, which
  golua supports separately). Triage each against reference.

Categories: memory/size limits, stack depth, integer edges, index/range, pattern
recursion/complexity, coroutine/goroutine resource, native boundaries; plus a
randomized tier feeding extreme args into a spread of builtins.

## Usage

```sh
python3 run.py                 # curated cases
python3 run.py --rand 5000 --seed 1   # + randomized extreme-arg cases
```

Env: `GOLUA` (CLI path, auto-built from the sibling golua checkout).

## Findings

Caught two real host-crash escapes (both fixed upstream, both branches):
- `s = s .. s` doubling — the 2-operand **concat fast path** had no size guard
  (the multi-operand path did) → uncatchable Go fatal OOM.
- match-heavy **gsub** with a large replacement — the result builder had no size
  cap → uncatchable Go fatal OOM. Now capped at `1<<30` like `string.rep`/concat.

Residual known limitation (not a clean bug): golua's gsub uses ~2–5× transient
memory vs reference's ~1×, so a sub-cap (~1GB) result can still OOM under a tight
memory limit where reference succeeds — the general "golua can uncatchably OOM
under a hard memory cap" property, mitigated but not eliminated by the size caps.

Two HANGs (`deep_call_mm` proper-tail-call loop, `move_huge` unbounded count)
reproduce identically on reference Lua — not golua bugs.
