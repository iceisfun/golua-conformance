# luadiff — generic single-file differential harness

Run one Lua program under golua and an official reference interpreter, normalize
the noise (program name, temp paths, hex pointers), and diff stdout + stderr +
exit code. Prints a `DIFF` block and exits non-zero when they disagree.

```sh
GOLUA=/path/to/golua REF=lua5.5.0 ./diff.sh program.lua
```

- `GOLUA` — golua CLI binary (default `/tmp/golua`).
- `REF`   — reference interpreter (default `lua5.5.0`).

Each run is resource-limited (30s wall, 32 GiB virtual memory via `ulimit -v`)
and concurrency-safe (`mktemp`), so it's safe to fan out across a corpus:

```sh
find corpus/ -name '*.lua' | xargs -P8 -n1 ./diff.sh
```

This is the lightweight counterpart to `../packfuzz/`: packfuzz *generates* the
programs for one stdlib surface; luadiff *diffs* any single program you already
have (handy for minimizing a lead down to a one-file repro).
