# coroutinefuzz

Differential state-machine grinder for **coroutines** — golua's single biggest
implementation-mechanism divergence from reference Lua (goroutines + channels
vs C-stack copying), and therefore the most likely remaining habitat for parity
bugs once the random-fuzzing tail is exhausted.

Each case drives a coroutine through one interaction and emits a canonical,
address-normalized **trace** of the whole observable sequence (every
resume/yield/return/error plus the `coroutine.status` after each step); golua and
the reference must produce byte-identical traces.

## Axes

- **drivers** — bare `resume` loop, `coroutine.wrap`, `pcall(resume)`,
  `xpcall` around a wrap.
- **yield sites** — plain body; inside every metamethod (`__index __newindex
  __add __concat __call __len __tostring __eq __lt __le`); inside iterators
  (custom, `__pairs`, `ipairs`, `gmatch`); inside library callbacks (`gsub`
  replacement, `table.sort` comparator — the C-call-boundary cases).
- **errors** — none / string / nil / number / table-with-`__tostring` /
  `error(...,0)` / `error(...,2)` / error before the first yield / runtime error.
- **specials** — nested resume, yield-from-main, resume dead/running/normal,
  `pcall` across a yield, `coroutine.close` on a suspended coroutine with a
  pending to-be-closed var (and a `__close` that errors), error-object identity
  across the resume boundary, `wrap` re-raise of every error payload,
  `isyieldable`/`status`/`running` in nested contexts.

## Usage

```sh
python3 run.py                 # all cases vs lua5.5.0 (golua master)
python3 run.py --lua54         # vs lua5.4.8 (golua lua_5_4_8 branch)
```

A clean run prints `0 leads` and leaves `corpus/diff.txt` absent. Env: `GOLUA`
(CLI path, auto-built from the sibling golua checkout), `REFLUA` (reference).

## Status

golua is **fully conformant** on this surface (130/130 clean, both branches),
including the subtle cases: it correctly *forbids* yielding across a C-call
boundary (`gsub`/`sort` callbacks → "attempt to yield across a C-call boundary")
while correctly *allowing* yields across metamethods — exactly matching 5.5,
despite the goroutine-based implementation. The finder is the durable regression
guard for that property.

A focused performance pass off the back of this finder removed the per-call
allocation in `coroutine.status`/`resume` (golua: −99.5% allocs on a
status-polling ping-pong).
