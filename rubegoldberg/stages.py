"""Semantic stage library for the Rube Goldberg generator.

Each stage is a self-contained, individually-correct Lua transform with the
signature  int -> int  : it receives the running accumulator `x` and returns a
new integer, computed via an over-engineered use of one language feature
(closures, coroutines, iterators, strings, patterns, tables, metatables, error
handling, recursion, varargs, scoping). Chaining many stages builds a deep
"Rube Goldberg machine" whose final integer is fully deterministic, so any
behavioral divergence between golua and the reference shows up as a different
printed result (or a different error/no-error outcome folded into the integer).

Determinism rules every stage MUST obey (else it is a differential false
positive, not a golua bug):
  * integers only — never `/` or `^` (floats); use `//`, `%`, `*`, `+`, `-`,
    and the bitwise ops. Integer arithmetic wraps identically (int64) in both.
  * never math.random / os.* / io.* / collectgarbage (non-deterministic).
  * never iterate a hash table with `pairs` for output order; use arrays +
    `ipairs` or numeric loops, or sort keys.
  * never tostring() a table/function (addresses differ); never print the text
    of an error message — fold success/failure into the integer instead.
  * guard every divisor/modulus to be > 0 so `% 0`, `// 0`, and mininteger//-1
    can't raise (those are legitimate-but-noisy, not the bugs we want).

Each generator returns a Lua *body* operating on parameter `x` and `return`ing
an int. The driver wraps it as `v = (function(x) <body> end)(v)`.
"""


def _pos(rng, lo, hi):
    return rng.randint(lo, hi)


def arith_mix(rng):
    a = _pos(rng, 3, 9999)
    b = _pos(rng, 1, 9999)
    s1 = _pos(rng, 1, 31)
    s2 = _pos(rng, 1, 31)
    m = _pos(rng, 7, 1_000_003)
    return (
        f"  x = x * {a} + {b}\n"
        f"  x = (x ~ (x >> {s1})) | (x << {s2})\n"
        f"  x = x & 0x7fffffffffffffff\n"
        f"  return (x % {m}) + ((x // {m}) & 0xffff)\n"
    )


def digit_sum(rng):
    base = _pos(rng, 0, 16)
    return (
        "  local s = string.format('%d', x % 1000000007)\n"
        "  local acc = 0\n"
        "  for i = 1, #s do acc = acc + s:byte(i) end\n"
        f"  return acc * {1 + base} + (x & 0xff)\n"
    )


def prime_sieve(rng):
    span = _pos(rng, 30, 250)
    return (
        f"  local n = (x % {span}) + 30\n"
        "  local sieve = {}\n"
        "  for i = 2, n do sieve[i] = true end\n"
        "  for i = 2, n do\n"
        "    if sieve[i] then\n"
        "      for j = i*i, n, i do sieve[j] = false end\n"
        "    end\n"
        "  end\n"
        "  local count, last = 0, 0\n"
        "  for i = 2, n do if sieve[i] then count = count + 1; last = i end end\n"
        "  return x + count * 131 + last\n"
    )


def closure_factory(rng):
    k = _pos(rng, 2, 12)
    return (
        "  local function make(seed)\n"
        "    local acc = seed\n"
        "    return function(d) acc = (acc + d) & 0x7fffffffffffffff; return acc end\n"
        "  end\n"
        f"  local fns = {{}}\n"
        f"  for i = 1, {k} do fns[i] = make(x + i) end\n"
        "  local total = 0\n"
        f"  for i = 1, {k} do total = total ~ fns[i](i * 7) end\n"
        "  return total & 0x7fffffffffffffff\n"
    )


def coroutine_gen(rng):
    span = _pos(rng, 10, 60)
    return (
        f"  local n = (x % {span}) + 5\n"
        "  local co = coroutine.wrap(function()\n"
        "    local a, b = 1, 1\n"
        "    for _ = 1, n do coroutine.yield(a); a, b = b, (a + b) & 0xffffff end\n"
        "  end)\n"
        "  local sum = 0\n"
        "  for v in co do sum = (sum + v) & 0x7fffffffffffffff end\n"
        "  return x ~ sum\n"
    )


def iterator_pipe(rng):
    m = _pos(rng, 8, 40)
    keep = _pos(rng, 2, 5)
    return (
        f"  local arr = {{}}\n"
        f"  for i = 1, {m} do arr[i] = (x + i * 2654435761) & 0xffffffff end\n"
        "  -- stateful filter+map iterator\n"
        "  local function pipe(t)\n"
        "    local i = 0\n"
        "    return function()\n"
        "      while true do\n"
        "        i = i + 1\n"
        "        local val = t[i]\n"
        "        if val == nil then return nil end\n"
        f"        if val % {keep} == 0 then return (val ~ (val >> 13)) end\n"
        "      end\n"
        "    end\n"
        "  end\n"
        "  local acc = 0\n"
        "  for v in pipe(arr) do acc = (acc + v) & 0x7fffffffffffffff end\n"
        "  return acc\n"
    )


def string_gsub(rng):
    rep = _pos(rng, 4, 30)
    return (
        f"  local parts = {{}}\n"
        f"  for i = 1, {rep} do parts[i] = string.format('%d', (x + i) % 97) end\n"
        "  local s = table.concat(parts, ',')\n"
        "  local cnt = 0\n"
        "  local out = s:gsub('%d+', function(d) cnt = cnt + 1; return tostring(#d) end)\n"
        "  local acc = 0\n"
        "  for i = 1, #out do acc = acc + out:byte(i) end\n"
        "  return x + cnt * 31 + acc\n"
    )


def pattern_caps(rng):
    n = _pos(rng, 3, 12)
    return (
        f"  local parts = {{}}\n"
        f"  for i = 1, {n} do parts[i] = string.rep(string.char(97 + (x + i) % 26), (i % 4) + 1) end\n"
        "  local s = table.concat(parts, '-')\n"
        "  local acc = 0\n"
        "  for word in s:gmatch('(%a+)') do acc = acc + #word * word:byte(1) end\n"
        "  return x ~ acc\n"
    )


def metatable_stateful(rng):
    """An object whose __add cycles through add/sub/mul/xor by invocation count
    — long-lived deterministic VM state across repeated metamethod dispatch."""
    k = _pos(rng, 3, 16)
    return (
        "  local calls = 0\n"
        "  local obj = setmetatable({ v = x & 0xffffff }, {\n"
        "    __add = function(a, b)\n"
        "      calls = calls + 1\n"
        "      local n = (type(a) == 'table') and a.v or a\n"
        "      local d = (type(b) == 'table') and b.v or b\n"
        "      local r\n"
        "      local m = calls % 4\n"
        "      if m == 1 then r = n + d\n"
        "      elseif m == 2 then r = n - d\n"
        "      elseif m == 3 then r = n * d\n"
        "      else r = n ~ d end\n"
        "      return setmetatable({ v = r & 0x7fffffffffffffff }, getmetatable(a) or getmetatable(b))\n"
        "    end,\n"
        "  })\n"
        f"  for i = 1, {k} do obj = obj + ((x + i) % 1000 + 1) end\n"
        "  return obj.v\n"
    )


def self_modifying_mt(rng):
    """Metatable that swaps its own __index between a table and a function while
    being read, plus an __index chain — exercises lookup-time mutation."""
    k = _pos(rng, 4, 20)
    return (
        "  local hits = 0\n"
        "  local backing = { a = x & 0xffff, b = (x >> 8) & 0xffff }\n"
        "  local mt = {}\n"
        "  mt.__index = function(t, key)\n"
        "    hits = hits + 1\n"
        "    if hits % 2 == 0 then\n"
        "      mt.__index = backing\n"  # swap to table form
        "    else\n"
        "      mt.__index = function(_, k2) return (#k2 + hits) & 0xff end\n"
        "    end\n"
        "    return (backing[key] or 0) + hits\n"
        "  end\n"
        "  local o = setmetatable({}, mt)\n"
        "  local acc = 0\n"
        f"  for i = 1, {k} do acc = (acc + (o.a or 0) + (o.b or 0) + (o.zz or 0)) & 0x7fffffffffffffff end\n"
        "  return x ~ acc\n"
    )


def table_sort(rng):
    m = _pos(rng, 6, 40)
    return (
        f"  local arr = {{}}\n"
        f"  for i = 1, {m} do arr[i] = (x * i + i * i) & 0xffffff end\n"
        "  table.sort(arr, function(a, b) return a > b end)\n"
        "  local acc = 0\n"
        "  for i = 1, #arr do acc = (acc * 33 + arr[i]) & 0x7fffffffffffffff end\n"
        "  return acc\n"
    )


def recursion_gcd(rng):
    k = _pos(rng, 2, 99991)
    return (
        "  local function gcd(a, b) if b == 0 then return a else return gcd(b, a % b) end end\n"
        f"  local g = gcd((x & 0x7fffffffffffffff) % 1000000 + 1, {k})\n"
        "  return x + g * 17\n"
    )


def pcall_roundtrip(rng):
    k = _pos(rng, 2, 7)
    return (
        "  local function risky(n) if n % 2 == 0 then error({ code = n }) end return n * 3 end\n"
        "  local acc = 0\n"
        f"  for i = 1, {k} do\n"
        "    local ok, res = pcall(risky, (x + i) & 0xffff)\n"
        "    if ok then acc = acc + res else acc = acc + (res.code or 0) + 1 end\n"
        "    acc = acc & 0x7fffffffffffffff\n"
        "  end\n"
        "  return x ~ acc\n"
    )


def vararg_select(rng):
    k = _pos(rng, 3, 10)
    return (
        "  local function collect(...)\n"
        "    local n = select('#', ...)\n"
        "    local acc = n\n"
        "    for i = 1, n do acc = (acc + select(i, ...)) & 0x7fffffffffffffff end\n"
        "    return acc\n"
        "  end\n"
        f"  local args = {{}}\n"
        f"  for i = 1, {k} do args[i] = (x + i * 13) & 0xffff end\n"
        "  return x ~ collect(table.unpack(args))\n"
    )


def shadow_scope(rng):
    depth = _pos(rng, 3, 8)
    lines = ["  local r = x"]
    for i in range(depth):
        lines.append("  do")
        lines.append(f"    local r = (r * {3 + i} + {i + 1}) & 0x7fffffffffffffff")
        lines.append("    x = r")
        lines.append("  end")
    lines.append("  return x")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Error stages. These raise (sometimes conditionally, always deterministically)
# so the driver's per-stage pcall captures the error MESSAGE + LINE into the
# transcript. They deliberately spread the faulting operator/field across source
# lines to exercise error-line attribution (the surface where golua and the
# reference historically diverge). All raise *string* errors (or explicit
# error("...")), never table objects, so the captured text is deterministic.
# ---------------------------------------------------------------------------
def err_index_ml(rng):
    m = _pos(rng, 2, 5)
    return (
        "  local t\n"
        f"  if x % {m} ~= 0 then t = {{ val = x }} end\n"
        "  return t\n"
        "    .val + 1\n"   # indexes nil when x % m == 0; '.val' on its own line
    )


def err_call_ml(rng):
    m = _pos(rng, 2, 5)
    return (
        "  local f\n"
        f"  if x % {m} == 0 then f = function(a) return a * 2 end end\n"
        "  return f\n"
        "    (x)\n"        # calls nil when x % m ~= 0; call on its own line
    )


def err_arith_ml(rng):
    return (
        "  local label = 'rg:'\n"
        "  return x +\n"   # number + non-numeric string -> arithmetic error
        "    label\n"
    )


def err_concat_ml(rng):
    return (
        "  local obj = setmetatable({}, {})\n"
        "  local s = x .. '-' ..\n"   # concat a table w/o __concat -> error, multi-line
        "    obj\n"
        "  return #s\n"
    )


def err_compare_ml(rng):
    m = _pos(rng, 2, 4)
    return (
        f"  if x % {m} == 0 then\n"
        "    local r = {} <\n"        # compare table with number -> error, multi-line
        "      x\n"
        "    return r and 1 or 0\n"
        "  end\n"
        "  return x\n"
    )


def err_custom(rng):
    m = _pos(rng, 3, 9)
    lvl = rng.choice([0, 1, 2])
    return (
        f"  if x % {m} == 0 then\n"
        f"    error('rg-custom-' .. (x % 100), {lvl})\n"
        "  end\n"
        "  return x\n"
    )


# ---------------------------------------------------------------------------
# Float / formatting / math stages. These emit FORMATTED-STRING observations
# (the actual divergence surface: %g / %.Ng / %a / %e / tostring, and the
# int-vs-float result typing of math.*) but RETURN the integer accumulator
# unchanged, so any float-formatting drift is localized to one transcript line
# instead of poisoning the whole chain. Values are chosen to be deterministic in
# both engines (exact binary fractions k/2^m, fixed literals, inf — never NaN,
# whose sign is platform-defined and a documented wontfix).
# ---------------------------------------------------------------------------
def float_format_battery(rng):
    return (
        "  local vals = { 0.0, 0.5, 0.1, 0.25, 0.125, 1.5, 3.14159, 2.5,\n"
        "                 100.0, 1e15, 1e-5, 1e300, 1e-300, 1/0, -1/0,\n"
        "                 (x % 17) + 0.5, -(x % 13) - 0.25 }\n"
        "  for i = 1, #vals do\n"
        "    local f = vals[i]\n"
        "    emit('g' .. i, string.format('%g', f))\n"
        "    emit('Ng' .. i, string.format('%.5g', f) .. '|' .. string.format('%.17g', f) .. '|' .. string.format('%.0g', f))\n"
        "    emit('hashg' .. i, string.format('%#g', f))\n"
        "    emit('e' .. i, string.format('%e', f))\n"
        "    emit('a' .. i, string.format('%a', f))\n"
        "    emit('ts' .. i, tostring(f))\n"
        "  end\n"
        "  return x\n"
    )


def math_exact(rng):
    d = _pos(rng, 1, 97)
    return (
        "  local n = (x % 200000) - 100000\n"
        "  local f = n + (x % 8) / 8.0\n"          # exact binary fraction
        "  emit('floor', tostring(math.floor(f)))\n"
        "  emit('ceil', tostring(math.ceil(f)))\n"
        "  emit('abs', tostring(math.abs(n)) .. '|' .. string.format('%g', math.abs(f)))\n"
        "  local ip, fp = math.modf(f)\n"
        "  emit('modf', string.format('%g|%g', ip, fp))\n"
        f"  emit('fmod', string.format('%g', math.fmod(n, {d})))\n"
        "  emit('toint', tostring(math.tointeger(f)) .. ',' .. tostring(math.tointeger(n + 0.0)))\n"
        "  emit('type', tostring(math.type(f)) .. ',' .. tostring(math.type(n)) .. ',' .. tostring(math.type('x')))\n"
        f"  emit('maxmin', tostring(math.max(n, {d}, -7)) .. ',' .. tostring(math.min(n, {d}, 11)))\n"
        "  return x\n"
    )


def intfloat_boundary(rng):
    return (
        "  local a = (x % 100) - 50\n"
        "  local b = (x % 7) + 1\n"
        "  emit('idiv', tostring(a // b) .. ',' .. tostring((a + 0.0) // b))\n"     # int vs float //
        "  emit('mod', tostring(a % b) .. ',' .. tostring((a + 0.0) % b))\n"
        "  emit('disp', tostring(a) .. ',' .. tostring(a + 0.0) .. ',' .. tostring(a * 1.0))\n"  # '2' vs '2.0'
        "  emit('pow', tostring(2^10) .. ',' .. tostring((-2)^3))\n"                 # ^ is always float
        "  emit('big', tostring(9007199254740992) .. ',' .. tostring(9007199254740993))\n"
        "  emit('lim', tostring(math.maxinteger) .. ',' .. tostring(math.mininteger))\n"
        "  emit('wrap', tostring(math.maxinteger + 1) .. ',' .. tostring(math.mininteger - 1))\n"
        "  emit('fmt', string.format('%d|%x|%i', a, a & 0xff, a))\n"
        "  return x\n"
    )


# ---------------------------------------------------------------------------
# Terminal / negative stages: deliberately raise so the differential also covers
# the FAILURE path (assert / error level semantics + value formatting in the
# message). A "negative positive": both engines must fail identically.
# ---------------------------------------------------------------------------
def assert_flag(rng):
    w = _pos(rng, 1, 1_000_000)
    return (
        f"  assert(x == {w}, 'flag-mismatch:' .. x)\n"   # almost always fails
        "  return x\n"
    )


def error_terminus(rng):
    lvl = rng.choice([0, 1, 2])
    return (
        f"  error('terminus[' .. (x & 0xffff) .. ']', {lvl})\n"
        "  return x\n"
    )


# All stage generators, by family. The generator picks from these.
STAGES = {
    "float_format_battery": float_format_battery,
    "math_exact": math_exact,
    "intfloat_boundary": intfloat_boundary,
    "assert_flag": assert_flag,
    "error_terminus": error_terminus,
    "err_index_ml": err_index_ml,
    "err_call_ml": err_call_ml,
    "err_arith_ml": err_arith_ml,
    "err_concat_ml": err_concat_ml,
    "err_compare_ml": err_compare_ml,
    "err_custom": err_custom,
    "arith_mix": arith_mix,
    "digit_sum": digit_sum,
    "prime_sieve": prime_sieve,
    "closure_factory": closure_factory,
    "coroutine_gen": coroutine_gen,
    "iterator_pipe": iterator_pipe,
    "string_gsub": string_gsub,
    "pattern_caps": pattern_caps,
    "metatable_stateful": metatable_stateful,
    "self_modifying_mt": self_modifying_mt,
    "table_sort": table_sort,
    "recursion_gcd": recursion_gcd,
    "pcall_roundtrip": pcall_roundtrip,
    "vararg_select": vararg_select,
    "shadow_scope": shadow_scope,
}
