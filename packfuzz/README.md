# packfuzz — state-machine grinder for `string.pack` / `unpack` / `packsize`

Treats the pack format language as the finite state machine it is and grinds it
exhaustively (plus a randomized long tail), differentially against reference
`lua5.5.0` **and** against oracle-free invariants. A clean run leaves `corpus/`
empty; any file there is a real lead. See `../docs/PACK_UNPACK_PLAN.md` for the
full rationale.

## Why this target

`stdlib/string_pack.go` keeps **four parallel copies** of the directive switch
(`pack`, `unpack`, and two in `packsize`/its X-helper). They must stay mutually
consistent — historically every bug here was switch-copy divergence or a value
boundary. The invariants below catch that family without any oracle.

## Layout

| File         | Role                                                                  |
|--------------|-----------------------------------------------------------------------|
| `grammar.py` | FSM: directive table, legal arg ranges, tier 0–2 enumerators, tier-3 gen |
| `values.py`  | format-string slot parser + per-slot boundary value tables            |
| `emit.py`    | renders a batch of `(fmt, values)` cases into one self-contained Lua driver |
| `run.py`     | runs the driver under golua **and** `lua5.5.0`, diffs, checks invariants |
| `corpus/`    | only divergences land here                                            |

One Lua driver runs many cases per process (batched) under both interpreters
with `ulimit -v` + `timeout`; output is canonical, position-stripped, and diffed
line-by-line.

## Oracle-free invariants (checked inside the driver, under golua)

1. **packsize** == `#pack(...)` for fixed-size formats.
2. **repack**: `pack(unpack(pack(x))) == pack(x)` (three-switch consistency;
   handles float lossiness without tolerance math).
3. **offset**: `unpack` trailing position == `#packed + 1`.
4. **no Go panic escapes**: a Go-level panic on stderr is an automatic failure
   (sandbox class).

## Differential layer (oracle = `lua5.5.0`)

Byte-identical pack output (hex), identical decoded values + trailing position,
and identical error-message text.

## Usage

```sh
python3 run.py --all              # tiers 0,1,2 (deterministic backbone, ~2s)
python3 run.py --tier 1           # one tier
python3 run.py --tier3 50000      # randomized grind: 50k random formats
python3 run.py --tier3 5000000 --seed 7   # the "let it run for hours" mode
```

`run.py` auto-builds `./golua` from a sibling golua checkout (`../../golua` by
default — i.e. `~/work/golua` when this repo is `~/work/golua-conformance`) on
first run. Override the checkout with `GOLUA_REPO=/path/to/golua`, the binary
with `GOLUA=/path/to/golua`, or the reference with `REFLUA=/path/to/lua5.5.0`.
Exit code is non-zero when any lead is found.

`a.sh` runs the multi-seed grind (seeds 1..8). `corpus/report.txt` gets one
durable line per seed (clean or not); leads land in seed-namespaced files
(`corpus/diff_seed3.txt`, etc.).

## Tiers

- **0** — every directive in isolation across its full legal arg range, plus
  every illegal arg (branch coverage of the scanner).
- **1** — `!A · op1 · op2` alignment matrix (padding between differently-aligned
  fields, `Xop` references). The richest vein.
- **2** — `< > =` endian transitions interleaved with multi-byte data.
- **3** — random length-4..12 legal directive strings, property-checked.

## Known finds

- `Xc` (X with a size-less `c`): golua reported "invalid next option" before
  validating c's missing size; reference reports "missing size for format option
  'c'" first (it resolves the next option fully before the X-alignment check).
  Fixed in `stdlib/string_pack.go`; pinned in `tests/doctest/string_pack.lua`.
