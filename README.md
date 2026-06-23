# golua-conformance

Differential / property-based conformance tooling for
[golua](https://github.com/iceisfun/golua) — a Lua implementation in Go.

These tools run golua **and** an official PUC-Rio reference interpreter
(`lua5.5.0`, and `lua` for 5.4.x) over generated programs and compare their
behavior byte-for-byte. They live here, not in the main repo, because they're
Python/shell harnesses with their own dependencies and a "grind for hours"
workflow that doesn't belong in `go test`.

The main golua repo keeps the *regression pins* (doctests / Go tests) for every
divergence these tools find; this repo keeps the *finders*.

## Layout

| Dir         | Tool                                                                    |
|-------------|-------------------------------------------------------------------------|
| `packfuzz/` | State-machine grinder for `string.pack` / `unpack` / `packsize`. Treats the pack format as a finite grammar, enumerates it exhaustively (tiers 0–2) + randomized (tier 3), and checks differential parity vs `lua5.5.0` plus four oracle-free invariants. |
| `luadiff/`  | Generic single-file differential harness: run one `.lua` under golua and the reference, normalize prog-name/paths/pointers, diff stdout+stderr+exit. Resource-limited, concurrency-safe. |
| `docs/`     | Design notes (e.g. the packfuzz state-machine plan).                     |

## Prerequisites

- A **golua checkout** beside this one — `~/work/golua` by default (sibling of
  `~/work/golua-conformance`). Override with `GOLUA_REPO=/path/to/golua`. The
  harness builds `cmd/lua` from it on first run.
- **Go** (to build golua).
- **Python 3** (the generators; no third-party packages).
- Official reference interpreters on `PATH`: **`lua5.5.0`** (the 5.5 oracle) and
  optionally **`lua`** (5.4.x). Override with `REFLUA=/path/to/interp`.

## Quick start

```sh
cd packfuzz
python3 run.py --all          # deterministic tiers 0–2 (~2s) — empty corpus = clean
python3 run.py --tier3 50000  # randomized grind
./a.sh                        # multi-seed grind (seeds 1..8), durable corpus/report.txt
```

```sh
cd luadiff
GOLUA=/path/to/golua ./diff.sh someprogram.lua   # exits 1 + prints a DIFF block on divergence
```

## Resource discipline

The reference interpreter can OOM the host on pathological inputs (e.g. infinite
readers). Every interpreter invocation runs under `ulimit -v` + `timeout`. Keep
it that way.

## License

MIT — see [LICENSE](LICENSE).
