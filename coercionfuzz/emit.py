"""Render coercion cases into one self-contained Lua driver.

Many cases batch into a single Lua file run once per interpreter. Each case
emits one canonical, position-stripped line on stdout; run.py diffs golua's
lines against lua5.5.0's.

Canonical line shape (tab-separated):
    <kind>  <id>  ok   <serialized-result>
    <kind>  <id>  err  <stripped-error-message>

`serval` distinguishes integer vs float (math.type), canonicalizes
-0.0/NaN/Inf, and renders floats with %a so the two interpreters' float
formatting can never spuriously diverge. Tables/functions/threads are tagged by
TYPE not identity, so metamethod sentinels (deterministic strings) are the only
way operand-identity leaks into the output — which is exactly what we want to
observe dispatch.
"""

# --- Operand / metamethod prologue -------------------------------------------
# Built ONCE at the top of every driver. Provides:
#   REF_TABLE, REF_TABLE2, REF_FUNC, REF_THREAD   -- plain reference operands
#   MM_<event>                                     -- single-metamethod tables
#   MM_<COMBO>                                     -- multi-metamethod tables
# Each metamethod returns a deterministic sentinel string "MM:<event>" so that
# *which* metamethod fired is observable. __index/__newindex return/record a
# sentinel too.

# Metamethod event -> Lua metatable key.
_MM_KEY = {
    "add": "__add", "sub": "__sub", "mul": "__mul", "div": "__div",
    "mod": "__mod", "pow": "__pow", "idiv": "__idiv", "unm": "__unm",
    "band": "__band", "bor": "__bor", "bxor": "__bxor", "bnot": "__bnot",
    "shl": "__shl", "shr": "__shr",
    "eq": "__eq", "lt": "__lt", "le": "__le",
    "concat": "__concat", "len": "__len",
    "index": "__index", "newindex": "__newindex",
}

# Combo operands referenced by name MM_<COMBO> in values.py.
_COMBOS = {
    "FULL_ARITH": ["add", "sub", "mul", "div", "mod", "pow", "idiv", "unm"],
    "FULL_BIT":   ["band", "bor", "bxor", "bnot", "shl", "shr"],
    "CMP":        ["eq", "lt", "le"],
    "ARITH_CMP":  ["add", "sub", "mul", "div", "mod", "pow", "idiv", "unm",
                   "eq", "lt", "le"],
    "NONE":       [],
}

_SINGLE_EVENTS = list(_MM_KEY.keys())


def _mm_table_lua(varname, events):
    """Emit Lua that builds a metatable'd table bound to `varname`."""
    lines = ["local %s_mt = {" % varname]
    for ev in events:
        key = _MM_KEY[ev]
        if ev in ("len",):
            # __len must return a number in some contexts but we want the
            # sentinel observable; return a fixed integer 4242 as the "len".
            lines.append('  %s = function() return 4242 end,' % key)
        elif ev == "eq":
            lines.append('  __eq = function() return true end,')
        elif ev in ("lt", "le"):
            lines.append('  %s = function() return true end,' % key)
        elif ev == "index":
            lines.append('  __index = function(_, k) return "MM:index:"..tostring(k) end,')
        elif ev == "newindex":
            lines.append('  __newindex = function() error("MM:newindex") end,')
        else:
            lines.append('  %s = function() return "MM:%s" end,' % (key, ev))
    lines.append("}")
    lines.append("local %s = setmetatable({}, %s_mt)" % (varname, varname))
    return "\n".join(lines)


def _prologue():
    parts = []
    parts.append("local REF_TABLE = {}")
    parts.append("local REF_TABLE2 = {}")
    parts.append("local REF_FUNC = function() end")
    parts.append("local REF_THREAD = coroutine.create(function() end)")
    for ev in _SINGLE_EVENTS:
        parts.append(_mm_table_lua("MM_" + ev, [ev]))
    for name, evs in _COMBOS.items():
        parts.append(_mm_table_lua("MM_" + name, evs))
    return "\n".join(parts)


# --- Per-case expression rendering -------------------------------------------

def _binop_expr(op, a_expr, b_expr):
    return "(%s) %s (%s)" % (a_expr, op, b_expr)


_UNOP_FORM = {
    "unm": "-(%s)",
    "len": "#(%s)",
    "bnot": "~(%s)",
    "not": "not (%s)",
}


def render_case(case):
    """Return a Lua snippet that appends one canonical line to `out`."""
    kind = case["kind"]
    cid = case["id"]

    if kind == "binop":
        expr = _binop_expr(case["op"], case["a"].expr, case["b"].expr)
        return _probe(kind, cid, "return %s" % expr)

    if kind == "unop":
        expr = _UNOP_FORM[case["op"]] % case["a"].expr
        return _probe(kind, cid, "return %s" % expr)

    if kind == "index_get":
        # t[A] read on a fresh table (so __index absence is plain raw read).
        body = "local t = {}; return t[%s]" % case["a"].expr
        return _probe(kind, cid, body)

    if kind == "index_set":
        body = "local t = {}; t[%s] = 1; return t[%s]" % (
            case["a"].expr, case["a"].expr)
        return _probe(kind, cid, body)

    if kind == "key_norm":
        # write under ka, read back under kb -> observe key identity/normalization
        body = "local t = {}; t[%s] = 7; return t[%s]" % (case["ka"], case["kb"])
        return _probe(kind, cid, body)

    if kind == "fornum":
        # canonical: count iterations + last index, or surface the bound error.
        body = ("local n=0; local last; "
                "for i=%s,%s,%s do n=n+1; last=i; if n>1000 then break end end; "
                "return n, last") % (
            case["a"].expr, case["b"].expr, case["c"].expr)
        return _probe(kind, cid, body)

    if kind == "lib":
        form = case["form"].replace("{X}", case["a"].expr)
        return _probe(kind, cid, "return %s" % form)

    raise ValueError("unknown case kind: " + kind)


def _probe(kind, cid, lua_body):
    """Wrap a body in pcall+canonicalize, appending one line to `out`.

    Multiple results are serialized (comma-joined) so fornum's (n,last) and
    multi-return library calls stay comparable.
    """
    # Each case is a self-contained do-block so locals don't leak across cases.
    return (
        'do\n'
        '  local function body() %s end\n'
        '  local res = {pcall(body)}\n'
        '  emitcase("%s", "%s", res)\n'
        'end' % (lua_body, kind, cid)
    )


# --- Driver template ----------------------------------------------------------

DRIVER_HEAD = r"""
local format, concat = string.format, table.concat
local out = {}

local function maskptr(s)
  -- table/function/thread addresses are nondeterministic across interpreters;
  -- canonicalize "0x...." hex pointers so tostring()/%s output is comparable.
  return (s:gsub("0x%x+", "0xPTR"))
end

local function serval(v)
  local t = type(v)
  if t == "number" then
    if math.type(v) == "integer" then
      return "I" .. format("%d", v)
    else
      if v ~= v then return "Fnan"
      elseif v == math.huge then return "Finf"
      elseif v == -math.huge then return "F-inf"
      elseif v == 0.0 then
        -- distinguish -0.0 from 0.0 portably
        if 1/v == -math.huge then return "F-0" else return "F+0" end
      else return "F" .. format("%a", v) end
    end
  elseif t == "string" then
    return "S" .. maskptr(v)
  elseif t == "nil" then
    return "nil"
  elseif t == "boolean" then
    return "B" .. tostring(v)
  elseif t == "table" then
    return "<table>"
  elseif t == "function" then
    return "<function>"
  elseif t == "thread" then
    return "<thread>"
  end
  return "?" .. t
end

local function serr(msg)
  msg = tostring(msg)
  msg = msg:gsub("^.-:%d+: ", "")   -- strip "chunk:line: " position prefix
  return msg
end

local function emitcase(kind, id, res)
  -- res = {ok, ...}
  if res[1] then
    local parts = {}
    for i = 2, #res do parts[#parts+1] = serval(res[i]) end
    out[#out+1] = concat({kind, id, "ok", concat(parts, ",")}, "\t")
  else
    out[#out+1] = concat({kind, id, "err", serr(res[2])}, "\t")
  end
end
"""

DRIVER_TAIL = r"""
io.write(concat(out, "\n"))
io.write("\n")
"""


def build_driver(cases):
    parts = [DRIVER_HEAD, _prologue()]
    for c in cases:
        parts.append(render_case(c))
    parts.append(DRIVER_TAIL)
    return "\n".join(parts)
