"""Render (fmt, values) cases into one self-contained Lua driver script.

Many cases are batched into a single Lua file run once per interpreter. Each
case emits a canonical, position-stripped result line on stdout; run.py diffs
golua's lines against lua5.5.0's and inspects the oracle-free invariant lines.

Result line shape (tab-separated):
  F  <id>  ok   <hex-of-formatted-output>
  F  <id>  err  <stripped-error-message>
  INV <id> qrt  <true|false|note>      -- %q round-trip invariant

%p cases carry has_ptr=1: the pointer VALUE is nondeterministic, so the driver
substitutes a canonical token before hashing so both interpreters agree.
"""

INT_MASK = (1 << 64) - 1


def render_value(tag):
    kind, v = tag
    if kind == "int":
        return "0x%016x" % (v & INT_MASK)            # wraps to the right int64
    if kind == "float":
        if v == "nan":
            return "(0/0)"
        if v == "+inf":
            return "math.huge"
        if v == "-inf":
            return "-math.huge"
        if v == "-0":
            return "(-0.0)"
        return "(" + float(v).hex() + ")"            # exact, portable hex float
    if kind == "str":
        return '"' + "".join("\\x%02x" % b for b in v) + '"'
    if kind == "bool":
        return "true" if v else "false"
    if kind == "nil":
        return "nil"
    if kind == "none":
        return None                                  # marker: omit this arg
    raise ValueError("bad tag " + repr(tag))


def render_case(case):
    fmt = case["fmt"].replace("\\", "\\\\").replace('"', '\\"')
    vals = case.get("vals", [])
    # 'none' markers mean: truncate the arg list at that point (missing arg).
    rendered = []
    for t in vals:
        r = render_value(t)
        if r is None:
            break
        rendered.append(r)
    has_ptr = 1 if case.get("has_ptr") else 0
    return '{id="%s",fmt="%s",ptr=%d,args={%s}},' % (
        case["id"], fmt, has_ptr, ",".join(rendered))


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

-- Canonicalize a %p pointer so golua/ref agree. The pointer string's LENGTH is
-- implementation-defined (golua ~12 hex digits, PUC ~14), so a %Np width pads a
-- different number of spaces. We collapse the pointer hex AND any run of spaces
-- immediately adjacent to it to a single canonical token, erasing that
-- length-dependent padding while still flagging structural/error differences.
local function canon_ptr(s)
  s = gsub(s, "0[xX]%x+", "<ptr>")
  s = gsub(s, "%(null%)", "<ptr>")
  s = gsub(s, " *<ptr> *", "<ptr>")
  return s
end

local function serr(msg)
  msg = tostring(msg)
  msg = gsub(msg, "^.-:%d+: ", "")   -- strip "chunk:line: " position prefix
  return msg
end

local out = {}
local function emit(...) out[#out + 1] = concat({...}, "\t") end

-- Re-encode a number to a canonical, interpreter-independent token so the %q
-- round-trip can compare floats by bit pattern rather than decimal form.
local function numtok(v)
  if math.type(v) == "integer" then return "I" .. format("%d", v) end
  if v ~= v then return "Fnan" end
  if v == math.huge then return "Finf" end
  if v == -math.huge then return "F-inf" end
  return "F" .. format("%a", v)
end

for _, c in ipairs(CASES) do
  local id = c.id
  local ok, r = pcall(format, c.fmt, table.unpack(c.args, 1, c.args.n or #c.args))
  if ok then
    if c.ptr == 1 then
      -- A %p pointer's textual form (length AND digits) is implementation-
      -- defined, and %Np width-pads it differently per interpreter. We cannot
      -- compare the bytes, so we record only that formatting SUCCEEDED plus the
      -- output length-class with pointer runs masked out. canon_ptr collapses
      -- 0x<hex>/(null) and adjacent spaces; any residual length-dependence on
      -- the pointer digit count is intentionally dropped by masking all hex
      -- runs of length >= 8 to a single token before hashing.
      local masked = gsub(canon_ptr(r), "%x%x%x%x%x%x%x%x+", "<ptr>")
      emit("F", id, "ok", "PTR:" .. hex(masked))
    else
      emit("F", id, "ok", hex(r))
    end
  else
    emit("F", id, "err", serr(r))
  end

  -- INV: %q round-trip. Only meaningful for the reloadable kinds, applied to
  -- each single-arg %q case; multi-conv formats with %q are skipped here.
  if c.fmt == "%q" and #c.args >= 1 then
    local v = c.args[1]
    local okf, lit = pcall(format, "%q", v)
    if okf then
      local okl, fn = pcall(load, "return " .. lit)
      if okl and fn then
        local okc, back = pcall(fn)
        if not okc then
          emit("INV", id, "qrt", "load_call_err:" .. serr(back))
        else
          local tv, tb = type(v), type(back)
          if tv ~= tb then
            emit("INV", id, "qrt", "type_mismatch:" .. tv .. "/" .. tb)
          elseif tv == "number" then
            emit("INV", id, "qrt", tostring(numtok(v) == numtok(back)))
          else
            emit("INV", id, "qrt", tostring(v == back))
          end
        end
      else
        emit("INV", id, "qrt", "load_err:" .. serr(fn))
      end
    else
      emit("INV", id, "qrt", "fmt_err:" .. serr(lit))
    end
  end
end

io.write(concat(out, "\n"))
io.write("\n")
"""


def build_driver(cases):
    body = "\n".join(render_case(c) for c in cases)
    return DRIVER.replace("%CASES%", body)
