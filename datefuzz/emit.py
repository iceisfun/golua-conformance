"""Render a batch of os.date/os.time/os.difftime cases into one Lua driver.

One driver runs many cases per process under each interpreter. Output is
canonical and position-stripped so run.py can diff golua's lines against
lua5.5.0's. Invariant ("INV") lines are oracle-free checks evaluated in-driver.

Emitted line schema (tab-separated):  <OP>\t<id>\t<status>\t<payload...>

  DATE <id> ok   <string>            os.date(fmt, ts) string result (hex-escaped)
  DATE <id> err  <msg>              error (position prefix stripped)
  TAB  <id> ok   <k=v;...>          os.date("*t"/"!*t", ts) table, sorted fields
  TIME <id> ok   <epoch>            os.time(tbl) integer epoch
  TIME <id> err  <msg>
  DIFF <id> ok   <number>           os.difftime(a,b)
  INV  <id> <name> <true|false|...> oracle-free invariant (golua-only meaning)

The date result string is hex-escaped (every byte -> \\xHH) so locale/control
bytes survive the tab-delimited transport unambiguously.
"""

INT_MASK = (1 << 64) - 1


def _luaint(v):
    """Render a python int as a Lua integer literal that wraps to the right int64."""
    v &= INT_MASK
    return "0x%016x" % v


def _luatbl(tbl):
    parts = []
    for k, val in tbl.items():
        if isinstance(val, bool):
            parts.append("%s=%s" % (k, "true" if val else "false"))
        else:
            parts.append("%s=%s" % (k, _luaint(val)))
    return "{" + ",".join(parts) + "}"


def render_case(case):
    op = case["op"]
    cid = case["id"]
    if op == "date":
        fmt = case["fmt"].replace("\\", "\\\\").replace('"', '\\"')
        return '{id="%s",op="date",fmt="%s",ts=%s},' % (cid, fmt, _luaint(case["ts"]))
    if op == "datetab":
        # fmt is "*t" or "!*t"
        return '{id="%s",op="datetab",fmt="%s",ts=%s},' % (cid, case["fmt"], _luaint(case["ts"]))
    if op == "time":
        return '{id="%s",op="time",tbl=%s},' % (cid, _luatbl(case["tbl"]))
    if op == "time_raw":
        return '{id="%s",op="time",tbl=%s},' % (cid, case["expr"])
    if op == "difftime":
        return '{id="%s",op="difftime",a=%s,b=%s},' % (cid, _luaint(case["a"]), _luaint(case["b"]))
    raise ValueError("bad op " + repr(op))


DRIVER = r"""
local CASES = {
%CASES%
}

local byte, format, gsub, concat, sort = string.byte, string.format, string.gsub, table.concat, table.sort

-- The UTC round-trip invariant os.time(os.date("!*t",t))==t only holds when the
-- process TZ is itself UTC: os.time reads the table as LOCAL wall-clock, so under
-- any offset zone the round-trip legitimately differs by that offset (reference
-- Lua diverges identically). Detect a zero local offset and gate the check on it.
local TZ_IS_UTC = (os.date("%z", 0) == "+0000")

local function hex(s)
  local t = {}
  for i = 1, #s do t[i] = format("\\x%02x", byte(s, i)) end
  return concat(t)
end

local function serr(msg)
  msg = tostring(msg)
  msg = gsub(msg, "^.-:%d+: ", "")   -- strip "chunk:line: " position prefix
  return msg
end

-- Canonical, key-sorted rendering of an os.date("*t") result table.
local TFIELDS = {"year","month","day","hour","min","sec","wday","yday","isdst"}
local function sertab(t)
  local parts = {}
  for _, k in ipairs(TFIELDS) do
    local v = t[k]
    if v ~= nil then
      if type(v) == "boolean" then parts[#parts+1] = k.."="..tostring(v)
      else parts[#parts+1] = k.."="..format("%d", v) end
    end
  end
  return concat(parts, ";")
end

local out = {}
local function emit(...) out[#out + 1] = concat({...}, "\t") end

for _, c in ipairs(CASES) do
  local id = c.id
  if c.op == "date" then
    local ok, res = pcall(os.date, c.fmt, c.ts)
    if ok then
      if type(res) == "string" then emit("DATE", id, "ok", hex(res))
      else emit("DATE", id, "ok", "?nonstring:"..type(res)) end
    else
      emit("DATE", id, "err", serr(res))
    end

  elseif c.op == "datetab" then
    local ok, res = pcall(os.date, c.fmt, c.ts)
    if ok then
      if type(res) == "table" then
        emit("TAB", id, "ok", sertab(res))
        -- INV: UTC round-trip os.time(os.date("!*t", t)) == t for in-range t.
        -- Only meaningful when the process TZ is UTC (see TZ_IS_UTC above).
        if c.fmt == "!*t" and TZ_IS_UTC then
          local okt, back = pcall(os.time, res)
          if okt then emit("INV", id, "utc_roundtrip", tostring(back == c.ts))
          else emit("INV", id, "utc_roundtrip", "time_err:"..serr(back)) end
        end
      else emit("TAB", id, "ok", "?nontable:"..type(res)) end
    else
      emit("TAB", id, "err", serr(res))
    end

  elseif c.op == "time" then
    local ok, res = pcall(os.time, c.tbl)
    if ok then
      emit("TIME", id, "ok", format("%d", res))
    else
      emit("TIME", id, "err", serr(res))
    end

  elseif c.op == "difftime" then
    local ok, res = pcall(os.difftime, c.a, c.b)
    if ok then
      -- difftime is a float in Lua; render exactly.
      emit("DIFF", id, "ok", format("%a", res))
      -- INV: difftime(t,0) == t (identity), checked only when b==0.
      if c.b == 0 then emit("INV", id, "difftime_id", tostring(res == c.a + 0.0)) end
    else
      emit("DIFF", id, "err", serr(res))
    end
  end
end

io.write(concat(out, "\n"))
io.write("\n")
"""


def build_driver(cases):
    body = "\n".join(render_case(c) for c in cases)
    return DRIVER.replace("%CASES%", body)
