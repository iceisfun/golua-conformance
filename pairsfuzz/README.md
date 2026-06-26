# pairsfuzz

Differential **+** invariant fuzzer for `pairs` / `next` / table iteration.

Lua leaves iteration **order** unspecified, so comparing the order golua and the
reference visit keys would flag non-bugs. This tester compares only the
order-independent facts that *are* specified, so every lead is a genuine
completeness / key-normalization / consistency bug — never an order artifact.

## What it checks

* **Order-independent SET differential.** Each scenario serializes the visited
  `(key,value)` pairs canonically — type-tagged (`i`nteger / `f`loat-as-`%a` /
  `s`tring / `b`ool) and **sorted** — so two impls with different visit orders
  still compare equal, while a real divergence shows up: a key one impl drops,
  a key-normalization difference (`1` vs `1.0` vs `"1"`, `-0.0`→`0`, `2^53`
  float→int, `maxinteger`), or a wrong value (last-write-wins).
* **Oracle-free invariants** (no reference needed):
  * no key visited twice in one traversal (`dup == 0`);
  * `pairs` and a manual `next()` loop enumerate the same set (`nextmatch`) —
    skipped for `__pairs` tables, where `next(T)` legitimately differs;
  * defined **mutation-during-traversal**: deleting the current key / updating
    an existing value terminates and yields the right final set.
* **`next` protocol edges**: `next({})` → nil, `next(t, badkey)` → the
  `invalid key to 'next'` error, NaN/`nil` key assignment errors — compared as
  text (chunk path normalized).

## Scenarios

Dense arrays, arrays with holes, string/float/bool/mixed keys, the int↔float key
collapse, the `2^53` and `maxinteger`/`mininteger` boundary, `-0.0`, array↔hash
grow/shrink transitions, sparse tables, constructor multi-return, delete/update
during traversal, NaN value, post-clear reuse, `__pairs`, a 3000-key table, and
the `next` error edges — plus `--rand N` randomized mixed-key tables with random
inserts and deletions.

## Usage

```sh
python3 run.py                  # full scenario battery
python3 run.py --rand 4000 --seed 1
python3 run.py --lua54          # golua lua_5_4_8 branch vs lua5.4.8
```

Env: `GOLUA`, `GOLUA_REPO` (default `../golua`), `REFLUA` (default `lua5.5.0`).

A lead writes `corpus/lead_NN_<tag>.lua` (both engines' output + the program).
Empty `corpus/` (only `report.txt`) means clean.

## Status

Clean: 26 curated scenarios + thousands of randomized tables all match the
reference set-wise and satisfy the oracle-free invariants. golua's table
iteration — including the subtle int/float/string key normalization and
mutation-during-traversal — is conformant.
