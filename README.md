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
| `patternfuzz/` | Lua pattern-matching grammar grinder (`find`/`match`/`gmatch`/`gsub`): classes, sets, quantifiers, captures, `%b`/`%f`/back-refs, malformed-pattern error wording, randomized tier3, and a `--depth` tier that stresses pattern length / recursion-limit boundaries. |
| `formatfuzz/` | `string.format` conversion/flag/width/precision matrix vs the reference. |
| `coercionfuzz/` | Type-coercion & operator-semantics grinder: string→number coercion, metamethod dispatch ordering, numeric-for bounds, key normalization, and library-argument coercion (incl. signed-zero strings). |
| `mathfuzz/` | Every `math.*` function over an edge-magnitude battery (±0, subnormals, extremes, NaN/Inf, domain edges). ULP-aware: exact functions must be bit-identical; transcendental ones tolerate Go-vs-libm last-ULP drift. |
| `coroutinefuzz/` | Coroutine state-machine grinder: drivers (resume/wrap/pcall/xpcall) × yield-sites (every metamethod, iterators, C-call-boundary callbacks) × error payloads, plus close/nesting/identity specials. Diffs the full resume/yield/error/status trace. Targets golua's biggest mechanism divergence (goroutines vs C-stack). |
| `sandboxfuzz/` | **Oracle-free** sandbox-robustness fuzzer: adversarial inputs (size/stack/integer/index/pattern/coroutine limits) wrapped in pcall under ulimit+timeout; flags any uncatchable Go panic/fatal-OOM/SIGSEGV escape or unbounded hang. Tests the invariant "sandboxed Lua can't crash the host" — no reference needed. Found the concat + gsub OOM host-crashes. |
| `datefuzz/` | `os.date` / `os.time` strftime + field-normalization differential. |
| `utf8fuzz/` | `utf8.*` (char/codepoint/len/offset/codes) over valid + malformed byte sequences. |
| `luadiff/`  | Generic single-file differential harness: run one `.lua` under golua and the reference, normalize prog-name/paths/pointers, diff stdout+stderr+exit. Resource-limited, concurrency-safe. |
| `docs/`     | Design notes (e.g. the packfuzz state-machine plan).                     |

## Prerequisites

- A **golua checkout** beside this one — `~/work/golua` by default (sibling of
  `~/work/golua-conformance`). Override with `GOLUA_REPO=/path/to/golua`. The
  harness builds `cmd/lua` from it on first run.
- **Go** (to build golua).
- **Python 3** (the generators; no third-party packages).
- Official reference interpreters on `PATH`: **`lua5.5.0`** (the 5.5 oracle, the
  default) and **`lua5.4.8`** (the exact 5.4.8 oracle, used by `--lua54`).
  `lua` is typically 5.4.6 — only a proxy; prefer `lua5.4.8`. Override the
  reference with `REFLUA=/path/to/interp`.

## Quick start

```sh
cd packfuzz
python3 run.py --all          # deterministic tiers (~2s) — empty corpus = clean
python3 run.py --tier3 50000  # randomized grind vs lua5.5.0 (golua master)
./a.sh                        # multi-seed grind (seeds 1..8), durable corpus/report.txt
```

### Testing the v1 / Lua 5.4.8 branch — `--lua54`

`--lua54` builds golua from golua's `lua_5_4_8` branch (into a dedicated
*detached* git worktree under `.worktrees/`, so it never disturbs your main
checkout) and defaults the reference to `lua5.4.8` instead of `lua5.5.0`:

```sh
python3 run.py --all --lua54        # golua lua_5_4_8 branch  vs  lua5.4.8
```

`REFLUA=...` still overrides the reference; the worktree is rebuilt each run so
local `lua_5_4_8` commits are always reflected.

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
