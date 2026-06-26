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


# All stage generators, by family. The generator picks from these.
STAGES = {
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
