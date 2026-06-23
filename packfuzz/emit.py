"""Render (fmt, values) cases into one self-contained Lua driver script.

We batch many cases into a single Lua file run once per interpreter, rather than
spawning a process per case. Each case emits canonical, position-stripped result
lines on stdout; run.py diffs golua's lines against lua5.5.0's and inspects the
oracle-free invariant lines.
"""

import struct

INT_MASK = (1 << 64) - 1


def render_value(tag):
    kind, v = tag
    if kind == "int":
        return "0x%016x" % (v & INT_MASK)        # wraps to the right int64 in Lua
    if kind == "float":
        if v == "nan":
            return "(0/0)"
        if v == "+inf":
            return "math.huge"
        if v == "-inf":
            return "-math.huge"
        if v == "-0":
            return "(-0.0)"
        # exact, interpreter-independent hex float literal (Lua parses p+/- exp)
        return "(" + float(v).hex() + ")"
    if kind == "str":
        return '"' + "".join("\\x%02x" % b for b in v) + '"'
    raise ValueError("bad tag " + repr(tag))


def render_case(case):
    fmt = case["fmt"].replace("\\", "\\\\").replace('"', '\\"')
    vals = case.get("vals", [])
    rendered = ",".join(render_value(t) for t in vals)
    return '{id="%s",fmt="%s",n=%d,vals={%s}},' % (case["id"], fmt, len(vals), rendered)


DRIVER = r"""
local CASES = {
%CASES%
}

local byte, format, gsub, concat = string.byte, string.format, string.gsub, table.concat

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

local function serval(v)
  local t = type(v)
  if t == "number" then
    if math.type(v) == "integer" then
      return "I" .. format("%d", v)
    else
      if v ~= v then return "Fnan"
      elseif v == math.huge then return "Finf"
      elseif v == -math.huge then return "F-inf"
      else return "F" .. format("%a", v) end
    end
  elseif t == "string" then
    return "S" .. hex(v)
  elseif t == "nil" then
    return "nil"
  elseif t == "boolean" then
    return "B" .. tostring(v)
  end
  return "?" .. t
end

local out = {}
local function emit(...) out[#out + 1] = concat({...}, "\t") end

for _, c in ipairs(CASES) do
  local id = c.id

  -- packsize (standalone: exercises var-size error parity too)
  local oks, sz = pcall(string.packsize, c.fmt)
  if oks then emit("PS", id, "ok", tostring(sz))
  else emit("PS", id, "err", serr(sz)) end

  -- pack
  local okp, packed = pcall(string.pack, c.fmt, table.unpack(c.vals, 1, c.n))
  if okp then
    emit("P", id, "ok", hex(packed))

    -- INV 1: packsize predicts encoded length (fixed-size formats only)
    if oks then emit("INV", id, "packsize", tostring(sz == #packed)) end

    -- unpack round-trip
    local oku, res = pcall(function() return table.pack(string.unpack(c.fmt, packed)) end)
    if oku then
      local n = res.n
      local pos = res[n]
      local parts = {}
      for i = 1, n - 1 do parts[i] = serval(res[i]) end
      emit("U", id, "ok", concat(parts, ","), "pos=" .. tostring(pos))

      -- INV 3: offset accounting
      emit("INV", id, "offset", tostring(pos == #packed + 1))

      -- INV 2: repack equality (oracle-free three-switch consistency)
      local okr, repacked = pcall(string.pack, c.fmt, table.unpack(res, 1, n - 1))
      if okr then emit("INV", id, "repack", tostring(repacked == packed))
      else emit("INV", id, "repack", "repack_err:" .. serr(repacked)) end
    else
      emit("U", id, "err", serr(res))
    end
  else
    emit("P", id, "err", serr(packed))
  end
end

io.write(concat(out, "\n"))
io.write("\n")
"""


def build_driver(cases):
    body = "\n".join(render_case(c) for c in cases)
    return DRIVER.replace("%CASES%", body)
