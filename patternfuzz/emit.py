"""Render (pattern, subject) cases into one self-contained Lua driver.

Many cases are batched into a single Lua file run once per interpreter. Each case
emits canonical, position-stripped result lines on stdout covering all four
pattern entry points, plus oracle-free invariant lines:

  F   string.find   -> ok/err, [s,e], captures
  M   string.match  -> ok/err, captures (or whole match)
  G   string.gmatch -> ok/err, the full sequence of iteration results
  S   string.gsub   -> ok/err, result string + replacement count
  INV oracle-free invariants checked under golua only (see run.py)

run.py diffs golua's lines against lua5.5.0's; INV lines must read 'true'.

Patterns and subjects are rendered as `\\xNN`-escaped Lua string literals so the
exact same bytes reach both interpreters regardless of source encoding.
"""


def _lit(b):
    """Render raw bytes as a fully \\xNN-escaped Lua string literal."""
    return '"' + "".join("\\x%02x" % c for c in b) + '"'


def render_case(case):
    pat = _lit(case["pat"])
    sub = _lit(case["sub"])
    return '{id="%s",p=%s,s=%s},' % (case["id"], pat, sub)


DRIVER = r"""
local CASES = {
%CASES%
}

local byte, format, gsub, concat = string.byte, string.format, string.gsub, table.concat
local find, match, gmatch = string.find, string.match, string.gmatch
local sub = string.sub

-- hex-encode a string so arbitrary bytes survive the tab-delimited transport
local function hex(s)
  local t = {}
  for i = 1, #s do t[i] = format("%02x", byte(s, i)) end
  return concat(t)
end

-- canonical serialization of one capture value (string or position-int)
local function sercap(v)
  local t = type(v)
  if t == "number" then return "I" .. format("%d", v) end
  if t == "string" then return "S" .. hex(v) end
  if t == "nil" then return "nil" end
  return "?" .. t
end

local function sercaps(t, from, to)
  local parts = {}
  local k = 0
  for i = from, to do
    k = k + 1
    parts[k] = sercap(t[i])
  end
  return concat(parts, ",")
end

local function serr(msg)
  msg = tostring(msg)
  msg = gsub(msg, "^.-:%d+: ", "")   -- strip "chunk:line: " position prefix
  return msg
end

local out = {}
local function emit(...) out[#out + 1] = concat({...}, "\t") end

for _, c in ipairs(CASES) do
  local id, p, s = c.id, c.p, c.s

  ----------------------------------------------------------------- find
  -- collect find's results with an exact arity. find returns nothing-but-nil on
  -- no-match (st==nil); on match it returns st,en[,caps...].
  local fok, fn, f1, f2, f3, f4, f5 = pcall(function()
    return select("#", find(s, p)), find(s, p)
  end)
  if not fok then
    emit("F", id, "err", serr(fn))
  elseif f1 == nil then
    emit("F", id, "nomatch")
  else
    local st, en = f1, f2
    local ft = { f1, f2, f3, f4, f5 }
    local caps = sercaps(ft, 3, fn)        -- captures begin after st,en
    emit("F", id, "ok", format("%d", st), format("%d", en), caps)

    -- INV (a): index bounds. 1 <= st and en >= st-1 (en==st-1 for empty match).
    emit("INV", id, "find_bounds", tostring(st >= 1 and en >= st - 1))
    -- with no explicit captures the matched span length is en-st+1; record it
    -- so a divergence in span length surfaces (capture-free case only).
    if fn == 2 then
      emit("INV", id, "find_span", "len=" .. tostring(en - st + 1))
    end
  end

  ----------------------------------------------------------------- match
  -- collect match's results with an exact arity count so we can distinguish
  -- "no match" (zero returns) from "matched empty string" (one return == "").
  local mok, mcnt, m1, m2, m3, m4 = pcall(function()
    return select("#", match(s, p)), match(s, p)
  end)
  if not mok then
    emit("M", id, "err", serr(mcnt))
  elseif mcnt == 0 then
    emit("M", id, "nomatch")
  else
    local mt = { m1, m2, m3, m4 }
    emit("M", id, "ok", sercaps(mt, 1, mcnt))
  end

  ----------------------------------------------------------------- gmatch
  local gok, gseq = pcall(function()
    local seq, k = {}, 0
    local guard = 0
    for v1, v2, v3 in gmatch(s, p) do
      k = k + 1
      -- record up to 3 captured values per iteration
      seq[k] = sercap(v1)
      if v2 ~= nil or v3 ~= nil then
        seq[k] = seq[k] .. "|" .. sercap(v2)
        if v3 ~= nil then seq[k] = seq[k] .. "|" .. sercap(v3) end
      end
      guard = guard + 1
      if guard > 200 then seq[k + 1] = "<<cap>>"; break end
    end
    return seq
  end)
  local gcount = 0
  if not gok then
    emit("G", id, "err", serr(gseq))
  else
    gcount = #gseq
    emit("G", id, "ok", tostring(gcount), concat(gseq, ";"))
  end

  ----------------------------------------------------------------- gsub (string repl)
  local sok, sresult, scount = pcall(gsub, s, p, "<%0>")
  if not sok then
    emit("S", id, "err", serr(sresult))
  else
    emit("S", id, "ok", hex(sresult), format("%d", scount))

    -- INV (b): gsub replacement count == number of gmatch iterations, but ONLY
    -- for non-anchored patterns. A leading '^' anchors gsub at each position
    -- while gmatch ignores anchoring, so the two counts legitimately differ
    -- there (and both interpreters agree on that difference); restricting the
    -- assertion keeps it a real oracle-free check without false positives.
    if gok and byte(p, 1) ~= 94 then   -- 94 == '^'
      emit("INV", id, "count_eq", tostring(scount == gcount))
    end
  end

  ------------------------------------------------ gsub (numbered-capture repl)
  local s2ok, s2res, s2cnt = pcall(gsub, s, p, "[%1]")
  if not s2ok then
    emit("S1", id, "err", serr(s2res))
  else
    emit("S1", id, "ok", hex(s2res), format("%d", s2cnt))
  end

  ------------------------------------------------ gsub (function repl)
  local sfok, sfres, sfcnt = pcall(gsub, s, p, function(...)
    local n = select("#", ...)
    if n == 0 then return nil end
    local v = select(1, ...)
    if type(v) == "number" then return "#" .. v end
    return "<" .. v .. ">"
  end)
  if not sfok then
    emit("SF", id, "err", serr(sfres))
  else
    emit("SF", id, "ok", hex(sfres), format("%d", sfcnt))
  end

  ------------------------------------------------ gsub (table repl)
  local strepl = setmetatable({}, {__index = function(_, k) return "T:" .. tostring(k) end})
  local stok, stres, stcnt = pcall(gsub, s, p, strepl)
  if not stok then
    emit("ST", id, "err", serr(stres))
  else
    emit("ST", id, "ok", hex(stres), format("%d", stcnt))
  end
end

io.write(concat(out, "\n"))
io.write("\n")
"""


def build_driver(cases):
    body = "\n".join(render_case(c) for c in cases)
    return DRIVER.replace("%CASES%", body)
