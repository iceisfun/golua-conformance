# mathfuzz

Differential grinder for the **math library across edge magnitudes**. Runs every
`math.*` function over a curated battery of edge-case inputs under golua and a
reference interpreter and compares results — with ULP-aware classification so the
inherent Go-`math`-vs-C-`libm` last-ULP drift doesn't drown out real bugs.

## What it covers

- **Inputs:** signed zero (`-0.0`), subnormals (`5e-324`), the float/integer
  extremes (`math.maxinteger`/`mininteger`/`huge`/max-double), `NaN`/`Inf`,
  domain boundaries (`sqrt`/`log`/`asin` of negatives), exact vs inexact doubles
  (`2^53`, `2^53+1`), near-overflow/underflow (`exp(709)`, `exp(710)`), powers,
  fractions, π and π/2.
- **Functions:** every unary `math.*` (`abs ceil floor sqrt modf tointeger type`
  + `sin cos tan asin acos atan exp log`) over the full battery, and the binary
  ones (`fmod`, `atan(y,x)`, `log(x,base)`, `ult`, `max`, `min`) over a reduced
  battery cross-product, plus 3-arg `max`/`min`.

## How it avoids last-ULP noise

Float results are decoded to IEEE-754 doubles and compared by **ULP distance**,
not as strings. Functions are split into two classes:

- **Exact** (`abs ceil floor sqrt modf tointeger type fmod ult max min`) — these
  are algebraic or IEEE-correctly-rounded, so they must agree **bit-for-bit**
  (tolerance 0). Any difference is a structural lead.
- **Transcendental** (`sin cos tan asin acos atan exp log atan2 logb`) — Go's
  `math` and the platform libm legitimately differ, especially in argument
  reduction at large or near-zero-crossing inputs (e.g. `sin(maxinteger)`).
  These get a generous ULP tolerance (`--ulp`, default 64) and land in the
  `lastulp` bucket — counted, never a corpus lead. See golua
  [`wontfix/libm-last-ulp`](../../golua/wontfix/libm-last-ulp).

Leads are reserved for **structural** divergences regardless of tolerance:
integer-vs-float type mismatch, error-vs-value or differing error wording,
NaN-vs-finite, Inf-vs-finite, and sign-of-zero on a runtime result (this last
class is what surfaced the `math.sqrt("-0")` coercion bug — though string→number
coercion itself is `coercionfuzz`'s job; mathfuzz uses numeric literals).

## Usage

```sh
python3 run.py                 # all deterministic cases vs lua5.5.0 (golua master)
python3 run.py --lua54         # vs lua5.4.8 (golua lua_5_4_8 branch)
python3 run.py --ulp 16        # tighten the transcendental tolerance
```

A clean run prints `0 leads` and leaves `corpus/diff.txt` absent (only
`report.txt`, with the match/lastulp/lead tally). Env: `GOLUA` (CLI path,
auto-built from the sibling golua checkout if missing), `REFLUA` (reference).

## Status

golua's math **values** are clean — it delegates to Go's `math` package, which
is correct; the only differences are the inherent last-ULP transcendental drift
(~100 cases, all classified as platform). mathfuzz now serves as the durable
regression guard for that surface.
