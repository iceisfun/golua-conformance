-- lua55vm/runtime.lua
-- Guest value model and runtime operations (metamethod dispatch, arithmetic,
-- comparison, indexing, length, tostring/tonumber).
--
-- Value mapping (guest -> host):
--   nil/boolean/number/string -> same host value (int/float subtype preserved)
--   table   -> GTable  (host table tagged with TABLE_MT; data in `.hash`)
--   closure -> GClosure(host table tagged with CLOSURE_MT)
--   native  -> host function (guest type() reports "function")
--   thread  -> GThread (host table tagged with THREAD_MT, wraps a host coroutine)
--
-- Runtime ops are installed as methods on the Interp class so they can raise
-- located guest errors and invoke metamethods via I:call.

local M = {}

-- Unique tag metatables identify guest object kinds.
local TABLE_MT   = { __name = "L.table" }
local CLOSURE_MT = { __name = "L.closure" }
local THREAD_MT  = { __name = "L.thread" }
M.TABLE_MT   = TABLE_MT
M.CLOSURE_MT = CLOSURE_MT
M.THREAD_MT  = THREAD_MT

local mtype   = math.type
local tointeger = math.tointeger
local floor   = math.floor
local hostfmt = string.format
local hostnext = next

-- ---------------------------------------------------------------------------
-- Constructors / predicates
-- ---------------------------------------------------------------------------

-- Replicates Lua's luaO_chunkid: produce the short source name used in error
-- messages and tracebacks (LUA_IDSIZE = 60).
local IDSIZE = 60
function M.shortsrc(source)
  source = source or "?"
  local c = source:sub(1, 1)
  if c == "=" then
    local s = source:sub(2)
    if #s + 1 <= IDSIZE then return s end
    return s:sub(1, IDSIZE - 1)
  elseif c == "@" then
    local s = source:sub(2)
    if #s + 1 <= IDSIZE then return s end
    return "..." .. s:sub(#s - (IDSIZE - 4) + 1)
  else
    local nl = source:find("\n")
    local first = nl and source:sub(1, nl - 1) or source
    -- space for: [string "..."]  plus the '...' marker and terminator
    local maxlen = IDSIZE - 15
    if nl == nil and #first <= maxlen then
      return '[string "' .. first .. '"]'
    end
    if #first > maxlen then first = first:sub(1, maxlen) end
    return '[string "' .. first .. '..."]'
  end
end

-- A guest table has an array part (arr[1..asize], holes allowed), a hash part
-- (host table, for everything else), and a length hint, mirroring Lua's own
-- table so the length operator and iteration are our own logic.
-- M.gc_hook, if set by the GC, is called with each newly created collectable
-- object so the collector can track it.
M.gc_hook = nil

function M.new_table(narr)
  narr = narr or 0
  local t = setmetatable({
    arr = {}, asize = narr, hash = {}, lenhint = narr // 2, meta = nil,
  }, TABLE_MT)
  if M.gc_hook then M.gc_hook(t) end
  return t
end

local hostrawget = rawget

-- raw get on the array/hash split (k must be normalized)
function M.rawget(t, k)
  if type(k) == "number" and mtype(k) == "integer" and k >= 1 and k <= t.asize then
    return t.arr[k]
  end
  return t.hash[k]
end

-- raw set (k must be normalized and validated non-nil/non-NaN)
function M.rawset(t, k, v)
  if type(k) == "number" and mtype(k) == "integer" then
    if k >= 1 and k <= t.asize then
      t.arr[k] = v
      return
    elseif k == t.asize + 1 and v ~= nil then
      -- extend the array part, absorbing any contiguous keys from the hash part
      t.asize = t.asize + 1
      t.arr[t.asize] = v
      local nx = t.hash[t.asize + 1]
      while nx ~= nil do
        t.asize = t.asize + 1
        t.arr[t.asize] = nx
        t.hash[t.asize] = nil
        nx = t.hash[t.asize + 1]
      end
      t.lenhint = t.asize // 2
      return
    end
  end
  t.hash[k] = v
end

-- bulk array set used by table constructors (SETLIST): place count values from
-- src[base+1..] at indices [start+1 .. start+count], sizing the array part.
function M.setlist(t, start, vals, vbase, count)
  for i = 1, count do
    t.arr[start + i] = vals[vbase + i]
  end
  if start + count > t.asize then
    t.asize = start + count
    t.lenhint = t.asize // 2
  end
end

local function arr_empty(t, i) return t.arr[i] == nil end

local function binsearch(t, i, j)
  while j - i > 1 do
    local m = (i + j) // 2
    if arr_empty(t, m) then j = m else i = m end
  end
  return i
end

local function hash_search(t, j)
  if j == 0 then j = 1 end
  local i
  while t.hash[j] ~= nil do
    i = j
    if j > 0x3FFFFFFFFFFFFFFF then
      i = j
      while t.hash[i + 1] ~= nil do i = i + 1 end
      return i
    end
    j = j * 2
  end
  i = i or j // 2
  while j - i > 1 do
    local m = (i + j) // 2
    if t.hash[m] == nil then j = m else i = m end
  end
  return i
end

-- Lua 5.5 luaH_getn: returns the first border, using a 4-step vicinity probe
-- around the cached hint, then a binary search.  This makes # deterministic
-- ("first hole") rather than "any border".
function M.getn(t)
  local asize = t.asize
  if asize > 0 then
    local maxvic = 4
    local limit = t.lenhint
    if limit == 0 then limit = 1 end
    if limit > asize then limit = asize end
    if arr_empty(t, limit) then
      for _ = 1, maxvic do
        if limit <= 1 then break end
        limit = limit - 1
        if not arr_empty(t, limit) then t.lenhint = limit; return limit end
      end
      local b = binsearch(t, 0, limit)
      t.lenhint = b
      return b
    else
      for _ = 1, maxvic do
        if limit >= asize then break end
        limit = limit + 1
        if arr_empty(t, limit) then t.lenhint = limit - 1; return limit - 1 end
      end
      if arr_empty(t, asize) then
        local b = binsearch(t, limit, asize)
        t.lenhint = b
        return b
      end
      t.lenhint = asize
    end
  end
  if t.hash[asize + 1] == nil then return asize end
  return hash_search(t, asize)
end

M.border = M.getn   -- back-compat alias

-- native quicksort (median-of-three) operating in place through getf/setf
-- (which go through the table's __index/__newindex), with invalid-order
-- detection matching Lua's "invalid order function for sorting".
function M.sort(I, n, getf, setf, less)
  local function swap(x, y)
    local vx, vy = getf(x), getf(y)
    setf(x, vy); setf(y, vx)
  end
  local function auxsort(lo, up)
    while lo < up do
      if less(getf(up), getf(lo)) then swap(lo, up) end
      if up - lo == 1 then return end
      local p = (lo + up) // 2
      if less(getf(p), getf(lo)) then swap(p, lo)
      elseif less(getf(up), getf(p)) then swap(p, up) end
      if up - lo == 2 then return end
      swap(p, up - 1)
      local pivot = getf(up - 1)
      local i, j = lo, up - 1
      while true do
        i = i + 1
        while less(getf(i), pivot) do
          if i >= up then I:rt_error("invalid order function for sorting") end
          i = i + 1
        end
        j = j - 1
        while less(pivot, getf(j)) do
          if j <= lo then I:rt_error("invalid order function for sorting") end
          j = j - 1
        end
        if i >= j then break end
        swap(i, j)
      end
      swap(up - 1, i)
      if i - lo < up - i then
        auxsort(lo, i - 1); lo = i + 1
      else
        auxsort(i + 1, up); up = i - 1
      end
    end
  end
  auxsort(1, n)
end

-- iteration (Lua's next): array part in order, then the hash part
function M.tnext(t, k)
  local asize = t.asize
  if k == nil then
    for i = 1, asize do
      if t.arr[i] ~= nil then return i, t.arr[i] end
    end
    return hostnext(t.hash)
  end
  if type(k) == "number" and mtype(k) == "integer" and k >= 1 and k <= asize then
    for i = k + 1, asize do
      if t.arr[i] ~= nil then return i, t.arr[i] end
    end
    return hostnext(t.hash)
  end
  return hostnext(t.hash, k)
end

function M.is_table(v)   return type(v) == "table" and getmetatable(v) == TABLE_MT end
function M.is_closure(v) return type(v) == "table" and getmetatable(v) == CLOSURE_MT end
function M.is_thread(v)  return type(v) == "table" and getmetatable(v) == THREAD_MT end

function M.new_closure(proto, upvals)
  local c = setmetatable({ proto = proto, upvals = upvals }, CLOSURE_MT)
  if M.gc_hook then M.gc_hook(c) end
  return c
end

-- guest type name of a value
function M.typename(v)
  local t = type(v)
  if t == "table" then
    local mt = getmetatable(v)
    if mt == TABLE_MT then return "table" end
    if mt == CLOSURE_MT then return "function" end
    if mt == THREAD_MT then return "thread" end
    return "userdata"
  elseif t == "function" then
    return "function"          -- native function
  end
  return t                      -- nil/boolean/number/string
end

function M.is_callable(v)
  return type(v) == "function" or M.is_closure(v)
end

-- normalize a table key: float with integral value -> integer
function M.normalize_key(k)
  if type(k) == "number" and mtype(k) == "float" then
    local i = tointeger(k)
    if i ~= nil then return i end
  end
  return k
end

local normalize_key = M.normalize_key

-- ---------------------------------------------------------------------------
-- Number / string coercions
-- ---------------------------------------------------------------------------

-- coerce a value to a number for arithmetic (string coercion allowed)
local function tonum(v)
  local t = type(v)
  if t == "number" then return v end
  if t == "string" then return tonumber(v) end
  return nil
end
M.tonum = tonum

-- convert a NUMBER to an integer (bitwise contexts: no string coercion, like
-- Lua's luaV_tointegerns). Returns int or nil if not an integral number.
local function toint(v)
  if type(v) == "number" then
    if mtype(v) == "integer" then return v end
    return tointeger(v)   -- nil if no integer representation
  end
  return nil
end
M.toint = toint

-- convert a value to an integer, coercing numeric strings (luaL_checkinteger /
-- explicit integer contexts in the standard library).
function M.toint_coerce(v)
  if type(v) == "number" then return toint(v) end
  if type(v) == "string" then
    local n = tonumber(v)
    if n ~= nil then return toint(n) end
  end
  return nil
end

function M.truthy(v)
  return v ~= nil and v ~= false
end

-- ---------------------------------------------------------------------------
-- Install runtime methods on the Interp class table.
-- ---------------------------------------------------------------------------

function M.install(Interp)

  -- get metatable object (GTable) of a value, or nil
  function Interp:getmeta(v)
    if M.is_table(v) then return v.meta end
    if type(v) == "string" then return self.string_meta end
    return self.type_meta[M.typename(v)]
  end

  -- fetch metamethod (host value) for an event, or nil
  function Interp:metamethod(v, event)
    local mt = self:getmeta(v)
    if mt == nil then return nil end
    return mt.hash[event]
  end

  -- raise a guest error value, attaching position to string messages.
  -- level: 1 = location of the running guest instruction (default)
  function Interp:rt_error(msg)
    error(setmetatable({ value = self:where() .. msg }, self.GUEST_ERR_MT), 0)
  end

  -- raise an already-formed guest error value (no position added).
  -- Lua 5.5: a nil error object becomes the string "<no error object>".
  function Interp:throw(value)
    if value == nil then value = "<no error object>" end
    error(setmetatable({ value = value }, self.GUEST_ERR_MT), 0)
  end

  ------------------------------------------------------------------ indexing

  -- maximum __index/__newindex delegation chain length (Lua's MAXTAGLOOP)
  local MAXTAGLOOP = 2000

  function Interp:index(t, k)
    for _ = 1, MAXTAGLOOP do
      if M.is_table(t) then
        local v = M.rawget(t, normalize_key(k))
        if v ~= nil then return v end
        local mt = t.meta
        if mt == nil then return nil end
        local h = mt.hash["__index"]
        if h == nil then return nil end
        if M.is_callable(h) then return (self:call(h, { t, k, n = 2 }))[1] end
        t = h   -- delegate to the __index table
      else
        -- non-table: must have __index or it's an error
        local h = self:metamethod(t, "__index")
        if h == nil then
          self:rt_error("attempt to index a " .. M.typename(t) .. " value")
        end
        if M.is_callable(h) then return (self:call(h, { t, k, n = 2 }))[1] end
        t = h
      end
    end
    self:rt_error("'__index' chain too long; possible loop")
  end

  function Interp:setindex(t, k, v)
    for _ = 1, MAXTAGLOOP do
      if M.is_table(t) then
        local nk = normalize_key(k)
        if M.rawget(t, nk) ~= nil then
          M.rawset(t, nk, v)
          return
        end
        local mt = t.meta
        local h = mt and mt.hash["__newindex"]
        if h == nil then
          -- raw set; validate key
          if nk == nil then self:rt_error("table index is nil") end
          if type(nk) == "number" and nk ~= nk then
            self:rt_error("table index is NaN")
          end
          M.rawset(t, nk, v)
          return
        end
        if M.is_callable(h) then
          self:call(h, { t, k, v, n = 3 })
          return
        end
        t = h   -- delegate to the __newindex table
      else
        local h = self:metamethod(t, "__newindex")
        if h == nil then
          self:rt_error("attempt to index a " .. M.typename(t) .. " value")
        end
        if M.is_callable(h) then
          self:call(h, { t, k, v, n = 3 })
          return
        end
        t = h
      end
    end
    self:rt_error("'__newindex' chain too long; possible loop")
  end

  ------------------------------------------------------------------ arithmetic

  local ARITH_EVENT = {
    ["+"] = "__add", ["-"] = "__sub", ["*"] = "__mul", ["/"] = "__div",
    ["%"] = "__mod", ["^"] = "__pow", ["//"] = "__idiv",
    ["&"] = "__band", ["|"] = "__bor", ["~"] = "__bxor",
    ["<<"] = "__shl", [">>"] = "__shr",
  }
  -- internal operation names used in arithmetic error messages
  local ARITH_OPNAME = {
    ["+"] = "add", ["-"] = "sub", ["*"] = "mul", ["/"] = "div",
    ["%"] = "mod", ["^"] = "pow", ["//"] = "idiv",
  }

  local function int_arith(op, a, b)
    if op == "&" then return a & b
    elseif op == "|" then return a | b
    elseif op == "~" then return a ~ b
    elseif op == "<<" then return a << b
    elseif op == ">>" then return a >> b end
  end

  local function num_arith(op, a, b)
    if op == "+" then return a + b
    elseif op == "-" then return a - b
    elseif op == "*" then return a * b
    elseif op == "/" then return a / b
    elseif op == "^" then return a ^ b
    elseif op == "//" then return a // b
    elseif op == "%" then return a % b end
  end

  local BITWISE = { ["&"]=true, ["|"]=true, ["~"]=true, ["<<"]=true, [">>"]=true }

  function Interp:arith(op, a, b)
    if BITWISE[op] then
      local ia, ib = toint(a), toint(b)
      if ia ~= nil and ib ~= nil then
        return int_arith(op, ia, ib)
      end
      return self:arith_meta(op, a, b)
    end
    local na, nb = tonum(a), tonum(b)
    if na ~= nil and nb ~= nil then
      if (op == "//" or op == "%") and mtype(na) == "integer"
         and mtype(nb) == "integer" and nb == 0 then
        if op == "//" then
          self:rt_error("attempt to divide by zero")
        else
          self:rt_error("attempt to perform 'n%0'")
        end
      end
      return num_arith(op, na, nb)
    end
    return self:arith_meta(op, a, b)
  end

  function Interp:arith_meta(op, a, b)
    local event = ARITH_EVENT[op]
    local h = self:metamethod(a, event) or self:metamethod(b, event)
    if h ~= nil then
      return (self:call(h, { a, b, n = 2 }))[1]
    end
    if BITWISE[op] then
      -- bitwise does not coerce strings: only two real numbers can reach the
      -- "no integer representation" case; otherwise it's a type error
      if type(a) == "number" and type(b) == "number" then
        local bad
        if toint(a) == nil then bad = a else bad = b end
        self:rt_error("number" .. self:hint_for(bad)
          .. " has no integer representation")
      end
      local bad
      if type(a) ~= "number" then bad = a else bad = b end
      self:rt_error("attempt to perform bitwise operation on a "
        .. self:objtypename(bad) .. " value" .. self:hint_for(bad))
    else
      local bad
      if tonum(a) == nil then bad = a else bad = b end
      if type(a) == "string" or type(b) == "string" then
        self:rt_error(hostfmt("attempt to %s a '%s' with a '%s'",
          ARITH_OPNAME[op], M.typename(a), M.typename(b)))
      end
      self:rt_error("attempt to perform arithmetic on a "
        .. self:objtypename(bad) .. " value" .. self:hint_for(bad))
    end
  end

  function Interp:unm(a)
    local na = tonum(a)
    if na ~= nil then return -na end
    local h = self:metamethod(a, "__unm")
    if h ~= nil then return (self:call(h, { a, a, n = 2 }))[1] end
    if type(a) == "string" then
      self:rt_error("attempt to unm a 'string' with a 'string'")
    end
    self:rt_error("attempt to perform arithmetic on a " .. self:objtypename(a)
      .. " value" .. self:hint_for(a))
  end

  function Interp:bnot(a)
    local ia = toint(a)
    if ia ~= nil then return ~ia end
    local h = self:metamethod(a, "__bnot")
    if h ~= nil then return (self:call(h, { a, a, n = 2 }))[1] end
    if type(a) == "number" then
      self:rt_error("number" .. self:hint_for(a) .. " has no integer representation")
    end
    self:rt_error("attempt to perform bitwise operation on a " .. self:objtypename(a)
      .. " value" .. self:hint_for(a))
  end

  ------------------------------------------------------------------ length

  function Interp:len(v)
    if type(v) == "string" then return #v end
    if M.is_table(v) then
      local mt = v.meta
      local h = mt and mt.hash["__len"]
      if h ~= nil then return (self:call(h, { v, v, n = 2 }))[1] end
      return M.getn(v)
    end
    local h = self:metamethod(v, "__len")
    if h ~= nil then return (self:call(h, { v, v, n = 2 }))[1] end
    self:rt_error("attempt to get length of a " .. M.typename(v) .. " value"
      .. self:hint_for(v))
  end

  ------------------------------------------------------------------ concat

  -- a value is concatenable if string or number
  local function concatable(v)
    local t = type(v)
    return t == "string" or t == "number"
  end

  function Interp:concat(a, b)
    if concatable(a) and concatable(b) then
      local r = self:tostr_concat(a) .. self:tostr_concat(b)
      if self.gc_pressure then self:gc_pressure(#r) end   -- new-string GC pressure
      return r
    end
    local h = self:metamethod(a, "__concat") or self:metamethod(b, "__concat")
    if h ~= nil then
      return (self:call(h, { a, b, n = 2 }))[1]
    end
    local bad
    if concatable(a) then bad = b else bad = a end
    self:rt_error("attempt to concatenate a " .. M.typename(bad) .. " value"
      .. self:hint_for(bad))
  end

  -- number -> string exactly as Lua does in concatenation/tostring
  function Interp:tostr_concat(v)
    if type(v) == "string" then return v end
    return self:number_tostring(v)
  end

  ------------------------------------------------------------------ comparison

  function Interp:eq(a, b)
    if a == b then return true end          -- primitive identity/value equality
    local ta, tb = type(a), type(b)
    -- numbers of mixed subtype compare by value already via host ==
    if ta ~= tb then return false end
    -- only tables (and userdata) consult __eq, and only when not raw-equal
    if M.is_table(a) and M.is_table(b) then
      local h = self:metamethod(a, "__eq") or self:metamethod(b, "__eq")
      if h ~= nil then
        return M.truthy((self:call(h, { a, b, n = 2 }))[1])
      end
    end
    return false
  end

  -- a < b
  function Interp:lt(a, b)
    local ta, tb = type(a), type(b)
    if ta == "number" and tb == "number" then return a < b end
    if ta == "string" and tb == "string" then return a < b end
    local h = self:metamethod(a, "__lt") or self:metamethod(b, "__lt")
    if h ~= nil then return M.truthy((self:call(h, { a, b, n = 2 }))[1]) end
    self:cmp_error(a, b)
  end

  -- a <= b
  function Interp:le(a, b)
    local ta, tb = type(a), type(b)
    if ta == "number" and tb == "number" then return a <= b end
    if ta == "string" and tb == "string" then return a <= b end
    local h = self:metamethod(a, "__le") or self:metamethod(b, "__le")
    if h ~= nil then return M.truthy((self:call(h, { a, b, n = 2 }))[1]) end
    self:cmp_error(a, b)
  end

  function Interp:cmp_error(a, b)
    local ta, tb = self:objtypename(a), self:objtypename(b)
    if ta == tb then
      self:rt_error("attempt to compare two " .. ta .. " values")
    else
      self:rt_error("attempt to compare " .. ta .. " with " .. tb)
    end
  end

  ------------------------------------------------------------------ tostring

  -- format a number the way Lua 5.5 / golua's tostring/print does.
  -- floats use shortest round-trip: %.15g, falling back to %.17g.
  function Interp:number_tostring(v)
    if mtype(v) == "integer" then
      return hostfmt("%d", v)
    end
    if v ~= v then
      -- NaN: golua prints "-nan" when the sign bit is set, else "nan"
      if hostfmt("%g", v):sub(1, 1) == "-" then return "-nan" end
      return "nan"
    end
    if v == math.huge then return "inf" end
    if v == -math.huge then return "-inf" end
    local s = hostfmt("%.15g", v)
    if tonumber(s) ~= v then
      s = hostfmt("%.17g", v)
    end
    if not s:find("[%.eE]") then
      s = s .. ".0"
    end
    return s
  end

  function Interp:tostring(v)
    local h = self:metamethod(v, "__tostring")
    if h ~= nil then
      local r = (self:call(h, { v, n = 1 }))[1]
      if type(r) == "string" then return r end
      if type(r) == "number" then return self:number_tostring(r) end
      self:rt_error("'__tostring' must return a string")
    end
    local t = type(v)
    if t == "nil" then return "nil"
    elseif t == "boolean" then return tostring(v)
    elseif t == "number" then return self:number_tostring(v)
    elseif t == "string" then return v
    end
    -- object: use __name if present, else type
    local name = M.typename(v)
    local mt = self:getmeta(v)
    if mt then
      local nm = mt.hash["__name"]
      if type(nm) == "string" then name = nm end
    end
    return hostfmt("%s: 0x%012x", name, self:object_id(v))
  end

  -- a stable-ish numeric id for an object (for default tostring)
  function Interp:object_id(v)
    local ids = self.object_ids
    local id = ids[v]
    if id == nil then
      id = self.next_object_id
      self.next_object_id = id + 16
      ids[v] = id
    end
    return id
  end

  -- explicit tonumber(v) or tonumber(v, base)
  function Interp:tonumber(v, base)
    if base == nil then
      local t = type(v)
      if t == "number" then return v end
      if t == "string" then return tonumber(v) end
      return nil
    else
      local ib = toint(base)
      if ib == nil or ib < 2 or ib > 36 then
        self:rt_error("bad argument #2 to 'tonumber' (base out of range)")
      end
      if type(v) ~= "string" then
        self:rt_error("bad argument #1 to 'tonumber' (string expected, got "
          .. M.typename(v) .. ")")
      end
      return tonumber(v:gsub("^%s+",""):gsub("%s+$",""), ib)
    end
  end

end

return M
