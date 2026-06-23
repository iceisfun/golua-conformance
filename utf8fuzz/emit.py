"""Render utf8 cases into one self-contained Lua driver script.

Each case carries a `subject` byte string and a list of ops. The driver runs
every op under pcall, emitting one canonical, position-stripped result line per
op, plus oracle-free invariant lines. run.py diffs golua's lines against
lua5.5.0's and inspects the INV lines.

Output line schema (tab-separated): OP \t caseid#opindex \t status \t payload...
"""


def _lua_bytes(b):
    """Render a Python bytes as an exact Lua string literal via \\xNN escapes."""
    return '"' + "".join("\\x%02x" % c for c in b) + '"'


def _lua_int_or_nil(x):
    return "nil" if x is None else ("(%d)" % x)


def _lua_bool(x):
    return "true" if x else "false"


def render_case(c):
    parts = ['{id=%s,s=%s,ops={' % (_lua_str(c["id"]), _lua_bytes(c["subject"]))]
    for op in c["ops"]:
        parts.append(_render_op(op))
    parts.append("}},")
    return "".join(parts)


def _lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _render_op(op):
    kind = op[0]
    if kind == "char":
        cps = ",".join("(%d)" % cp for cp in op[1])
        return '{k="char",cps={%s}},' % cps
    if kind == "codepoint":
        _, i, j, lax = op
        return '{k="codepoint",i=%s,j=%s,lax=%s},' % (
            _lua_int_or_nil(i), _lua_int_or_nil(j), _lua_bool(lax))
    if kind == "len":
        _, i, j, lax = op
        return '{k="len",i=%s,j=%s,lax=%s},' % (
            _lua_int_or_nil(i), _lua_int_or_nil(j), _lua_bool(lax))
    if kind == "offset":
        _, n, i = op
        return '{k="offset",n=%s,i=%s},' % (_lua_int_or_nil(n), _lua_int_or_nil(i))
    if kind == "codes":
        return '{k="codes",lax=%s},' % _lua_bool(op[1])
    if kind == "charpattern":
        return '{k="charpattern"},'
    raise ValueError("bad op " + repr(op))


DRIVER = r"""
local CASES = {
%CASES%
}

local byte, format, gsub, concat = string.byte, string.format, string.gsub, table.concat
local upack = table.unpack

local function hex(s)
  local t = {}
  for i = 1, #s do t[i] = format("%02x", byte(s, i)) end
  return concat(t)
end

local function serr(msg)
  msg = tostring(msg)
  msg = gsub(msg, "^.-:%d+: ", "")   -- strip "chunk:line: " position prefix
  return msg
end

-- serialize a varargs list of (assumed-integer) results into "a,b,c"
local function serints(...)
  local n = select("#", ...)
  local t = {}
  for i = 1, n do
    local v = select(i, ...)
    if v == nil then t[i] = "nil"
    elseif math.type(v) == "integer" then t[i] = format("%d", v)
    elseif type(v) == "number" then t[i] = format("%a", v)
    else t[i] = "?" .. type(v) end
  end
  return concat(t, ",")
end

local out = {}
local function emit(...) out[#out + 1] = concat({...}, "\t") end

for _, c in ipairs(CASES) do
  local s = c.s
  for oi, op in ipairs(c.ops) do
    local tag = c.id .. "#" .. oi
    local k = op.k

    if k == "char" then
      local ok, r = pcall(utf8.char, upack(op.cps))
      if ok then emit("CHAR", tag, "ok", hex(r))
      else emit("CHAR", tag, "err", serr(r)) end

    elseif k == "charpattern" then
      emit("CPAT", tag, "ok", hex(utf8.charpattern))

    elseif k == "codepoint" then
      local ok, r = pcall(function()
        return serints(utf8.codepoint(s, op.i, op.j, op.lax))
      end)
      if ok then emit("CP", tag, "ok", r)
      else emit("CP", tag, "err", serr(r)) end

    elseif k == "len" then
      local ok, a, b = pcall(utf8.len, s, op.i, op.j, op.lax)
      if ok then
        -- normal: (count) ; invalid bytes: (nil, pos)
        if a == nil then emit("LEN", tag, "ok", "nil," .. tostring(b))
        else emit("LEN", tag, "ok", tostring(a)) end
      else emit("LEN", tag, "err", serr(a)) end

    elseif k == "offset" then
      local ok, a, b = pcall(utf8.offset, s, op.n, op.i)
      if ok then emit("OFF", tag, "ok", tostring(a) .. "," .. tostring(b))
      else emit("OFF", tag, "err", serr(a)) end

    elseif k == "codes" then
      -- full iteration sequence; stop at first error.
      local pieces = {}
      local ok, err = pcall(function()
        for p, cp in utf8.codes(s, op.lax) do
          pieces[#pieces + 1] = p .. ":" .. cp
        end
      end)
      if ok then emit("CODES", tag, "ok", concat(pieces, ","))
      else emit("CODES", tag, "err", serr(err), "after=" .. concat(pieces, ",")) end
    end
  end

  -- ===== oracle-free invariants (checked under each interpreter) =====
  -- (a) round-trip: utf8.char(utf8.codepoint(s,1,-1)) == s  for strict-valid s
  do
    local okcp, cps = pcall(function() return {utf8.codepoint(s, 1, -1)} end)
    if okcp then
      local okc, rebuilt = pcall(utf8.char, upack(cps))
      if okc then
        emit("INV", c.id, "roundtrip", tostring(rebuilt == s))
      else
        emit("INV", c.id, "roundtrip", "char_err:" .. serr(rebuilt))
      end
      -- (b) len(char(cps...)) == #cps  (strict-valid path)
      local okl, n = pcall(utf8.len, s)
      if okl and n ~= nil then
        emit("INV", c.id, "len_eq_cps", tostring(n == #cps))
      end
    end
  end

  -- (c) offset-walking == codes traversal (positions AND codepoints).
  -- Walk with utf8.offset(s,1,p) and compare to utf8.codes order.
  do
    local codes_seq = {}
    local okcodes = pcall(function()
      for p, cp in utf8.codes(s) do codes_seq[#codes_seq + 1] = p .. ":" .. cp end
    end)
    if okcodes then
      -- rebuild the same sequence via offset stepping
      local off_seq = {}
      local consistent = true
      local p = 1
      while true do
        local sp = utf8.offset(s, 1, p)          -- start of char at/after p
        if sp == nil or sp > #s then break end
        local okcp, cp = pcall(utf8.codepoint, s, sp)
        if not okcp then consistent = false break end
        off_seq[#off_seq + 1] = sp .. ":" .. cp
        local nxt = utf8.offset(s, 2, sp)        -- start of NEXT char
        if nxt == nil then break end
        p = nxt
        if p > #s then break end
      end
      if consistent then
        emit("INV", c.id, "offset_walk",
             tostring(concat(off_seq, ",") == concat(codes_seq, ",")))
      end
    end
  end
end

io.write(concat(out, "\n"))
io.write("\n")
"""


def build_driver(cases):
    body = "\n".join(render_case(c) for c in cases)
    return DRIVER.replace("%CASES%", body)
