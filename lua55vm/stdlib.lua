-- lua55vm/stdlib.lua
-- Standard library for the guest interpreter.
--
-- Native functions use the convention  function(I, args) -> results
--   args    = { n = <count>, [1..n] = values }
--   results = table.pack(...)   (carries n, including trailing nils)
--
-- Implementations delegate to the host where it is semantically safe, and are
-- reimplemented where guest metamethods or guest callables are involved.

local rt = require("runtime")

local M = {}

local pack = table.pack
local unpack = table.unpack
local hostfmt = string.format
local mtype = math.type

-- pack host return values into a guest results array
local function R(...) return pack(...) end
local EMPTY = { n = 0 }

-- ---------------------------------------------------------------------------
-- argument helpers
-- ---------------------------------------------------------------------------

local function argerror(I, n, fname, extra)
  -- Name the function the way Lua's luaL_argerror does: first by how it was
  -- called (the caller's call instruction -> getfuncname), then by a global
  -- search in package.loaded, then the supplied fallback.
  local frames = I.frames
  local nat = frames[#frames]
  local caller = frames[#frames - 1]
  local named = false
  if caller and caller.cl and not caller.native and caller.proto then
    local ci = caller.proto.code[caller.savedpc]
    if ci and (ci.op == "CALL" or ci.op == "TAILCALL") then
      local kind, nm = I:reg_name(caller.cl, caller.savedpc, ci.a)
      if nm then
        if kind == "method" then n = n - 1 end   -- discount the self argument
        fname = nm; named = true
      end
    end
  end
  if not named and nat and nat.native and nat.fn
     and I.func_names and I.func_names[nat.fn] then
    fname = I.func_names[nat.fn]
  end
  if n == 0 then
    I:rt_error(hostfmt("calling '%s' on bad self (%s)", fname, extra))
  end
  I:rt_error(hostfmt("bad argument #%d to '%s' (%s)", n, fname, extra))
end

-- got-description: "no value" if the argument is absent, else its type name
local function gotname(args, n)
  if n > args.n then return "no value" end
  return rt.typename(args[n])
end

local function typeerror(I, n, fname, expected, args)
  argerror(I, n, fname, hostfmt("%s expected, got %s", expected, gotname(args, n)))
end

local function check_table(I, args, n, fname)
  local v = args[n]
  if not rt.is_table(v) then typeerror(I, n, fname, "table", args) end
  return v
end

local function check_str(I, args, n, fname)
  local v = args[n]
  local t = type(v)
  if t == "string" then return v end
  if t == "number" then return I:number_tostring(v) end
  typeerror(I, n, fname, "string", args)
end

local function check_num(I, args, n, fname)
  local v = args[n]
  if type(v) == "number" then return v end
  if type(v) == "string" then
    local x = tonumber(v)
    if x then return x end
  end
  typeerror(I, n, fname, "number", args)
end

local function check_int(I, args, n, fname)
  local v = args[n]
  local i = rt.toint_coerce(v)   -- coerces numeric strings (luaL_checkinteger)
  if i == nil then
    if rt.tonum(v) ~= nil then   -- a number (or numeric string) without int rep
      argerror(I, n, fname, "number has no integer representation")
    end
    typeerror(I, n, fname, "number", args)
  end
  return i
end

local function opt_int(I, args, n, fname, def)
  if args[n] == nil then return def end
  return check_int(I, args, n, fname)
end

local function check_func(I, args, n, fname)
  local v = args[n]
  if not rt.is_callable(v) then typeerror(I, n, fname, "function", args) end
  return v
end

M.argerror = argerror
M.check_table = check_table
M.check_str = check_str
M.check_int = check_int

-- ---------------------------------------------------------------------------
-- base library
-- ---------------------------------------------------------------------------

local function install_base(I)
  local G = I.globals
  local function def(name, fn) G.hash[name] = fn end

  def("_G", G)
  def("_VERSION", "Lua 5.5")

  def("print", function(I, args)
    local out = {}
    for i = 1, args.n do out[i] = I:tostring(args[i]) end
    io.write(table.concat(out, "\t"), "\n")
    return EMPTY
  end)

  def("type", function(I, args)
    if args.n == 0 then argerror(I, 1, "type", "value expected") end
    return R(rt.typename(args[1]))
  end)

  def("tostring", function(I, args)
    if args.n == 0 then argerror(I, 1, "tostring", "value expected") end
    return R(I:tostring(args[1]))
  end)

  def("tonumber", function(I, args)
    if args.n == 0 then argerror(I, 1, "tonumber", "value expected") end
    return R(I:tonumber(args[1], args[2]))
  end)

  def("rawget", function(I, args)
    local t = check_table(I, args, 1, "rawget")
    return R(rt.rawget(t, rt.normalize_key(args[2])))
  end)

  def("rawset", function(I, args)
    local t = check_table(I, args, 1, "rawset")
    local k = rt.normalize_key(args[2])
    if k == nil then I:rt_error("table index is nil") end
    if type(k) == "number" and k ~= k then I:rt_error("table index is NaN") end
    rt.rawset(t, k, args[3])
    return R(t)
  end)

  def("rawequal", function(I, args)
    local a, b = args[1], args[2]
    return R(a == b)
  end)

  def("rawlen", function(I, args)
    local v = args[1]
    if type(v) == "string" then return R(#v) end
    if rt.is_table(v) then return R(rt.getn(v)) end
    argerror(I, 1, "rawlen", "table or string expected")
  end)

  def("setmetatable", function(I, args)
    local t = check_table(I, args, 1, "setmetatable")
    local mt = args[2]
    if mt ~= nil and not rt.is_table(mt) then
      argerror(I, 2, "setmetatable", "nil or table expected")
    end
    if t.meta and t.meta.hash["__metatable"] ~= nil then
      I:rt_error("cannot change a protected metatable")
    end
    t.meta = mt
    I:gc_check_finalizer(t, mt)
    return R(t)
  end)

  def("getmetatable", function(I, args)
    local mt = I:getmeta(args[1])
    if mt == nil then return R(nil) end
    local prot = mt.hash["__metatable"]
    if prot ~= nil then return R(prot) end
    return R(mt)
  end)

  def("assert", function(I, args)
    if args.n == 0 then argerror(I, 1, "assert", "value expected") end
    if rt.truthy(args[1]) then return args end
    -- failed: behaves like error(msg) with default level 1
    local msg
    if args.n >= 2 then msg = args[2] else msg = "assertion failed!" end
    if type(msg) == "string" then msg = I:where_level(1) .. msg end
    I:throw(msg)
  end)

  def("error", function(I, args)
    local msg = args[1]
    local level = args[2]
    if level == nil then level = 1 else level = rt.toint(level) or 1 end
    if type(msg) == "string" and level > 0 then
      msg = I:where_level(level) .. msg
    end
    I:throw(msg)
  end)

  def("pcall", function(I, args)
    local fn = args[1]
    if not rt.is_callable(fn) then
      -- pcall still catches "attempt to call" via running it
    end
    local cargs = { n = args.n - 1 }
    for i = 2, args.n do cargs[i - 1] = args[i] end
    local ok, res = I:protected(fn, cargs)
    if ok then
      local out = { true, n = res.n + 1 }
      for i = 1, res.n do out[i + 1] = res[i] end
      return out
    else
      return R(false, res)
    end
  end)

  def("xpcall", function(I, args)
    local fn = args[1]
    local handler = args[2]
    local cargs = { n = args.n - 2 }
    for i = 3, args.n do cargs[i - 2] = args[i] end
    -- handler runs with the stack intact (inside protected, before unwinding)
    local ok, res = I:protected(fn, cargs, handler)
    if ok then
      local out = { true, n = res.n + 1 }
      for i = 1, res.n do out[i + 1] = res[i] end
      return out
    else
      return R(false, res)
    end
  end)

  def("select", function(I, args)
    local sel = args[1]
    if sel == "#" then return R(args.n - 1) end
    local i = check_int(I, args, 1, "select")
    if i < 0 then i = args.n + i
    elseif i == 0 then argerror(I, 1, "select", "index out of range") end
    if i < 1 then argerror(I, 1, "select", "index out of range") end
    local out = { n = math.max(0, args.n - i) }
    for j = i + 1, args.n do out[j - i] = args[j] end
    return out
  end)

  def("next", function(I, args)
    local t = check_table(I, args, 1, "next")
    local k = rt.normalize_key(args[2])
    local nk, nv = rt.tnext(t, k)
    if nk == nil then return R(nil) end
    return R(nk, nv)
  end)

  def("rawnext", G.hash["next"])  -- internal helper alias (host next is fine)

  def("pairs", function(I, args)
    if args.n == 0 then argerror(I, 1, "pairs", "table expected, got no value") end
    local t = args[1]
    local h = I:metamethod(t, "__pairs")
    if h ~= nil then
      local res = I:call(h, { t, n = 1 })
      return R(res[1], res[2], res[3], res[4])   -- incl. to-be-closed value
    end
    -- no validation here: pairs(non-table) succeeds; next() errors when iterated
    return R(G.hash["next"], t, nil)
  end)

  local function inext(I, args)
    local t = args[1]
    local i = (rt.toint(args[2]) or 0) + 1
    local v = I:index(t, i)
    if v == nil then return R(nil) end
    return R(i, v)
  end
  def("ipairs", function(I, args)
    if args.n == 0 then argerror(I, 1, "ipairs", "table expected, got no value") end
    return R(inext, args[1], 0)
  end)

  I.gc_mode = "generational"   -- Lua 5.5 default
  def("collectgarbage", function(I, args)
    local opt = args[1] or "collect"
    if opt == "collect" then
      I:gc_collect()
      return R(0)
    elseif opt == "step" then
      I:gc_collect()
      return R(false)
    elseif opt == "count" then
      local b = I.gc and I.gc.bytes or 0
      return R(b / 1024.0, b % 1024)
    elseif opt == "stop" or opt == "restart" then
      return R(0)
    elseif opt == "isrunning" then
      return R(true)
    elseif opt == "incremental" or opt == "generational" then
      local prev = I.gc_mode
      I.gc_mode = opt
      return R(prev)
    elseif opt == "setpause" or opt == "setstepmul" then
      return R(0)
    else
      argerror(I, 1, "collectgarbage", "invalid option '" .. tostring(opt) .. "'")
    end
  end)

  local function load_chunk_file(I, path, env)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local src = f:read("a"); f:close()
    -- skip a leading BOM
    if src:sub(1, 3) == "\239\187\191" then src = src:sub(4) end
    local ok, fn = pcall(function()
      return I:load(src, "@" .. path, env, env ~= nil)
    end)
    if ok then return fn end
    local m = fn
    if type(m) == "table" and getmetatable(m) == I.GUEST_ERR_MT then m = m.value end
    return nil, tostring(m)
  end

  def("loadfile", function(I, args)
    local path = args[1]
    if path == nil then argerror(I, 1, "loadfile", "string expected, got no value") end
    local fn, err = load_chunk_file(I, check_str(I, args, 1, "loadfile"), args[3])
    if fn then return R(fn) end
    return R(nil, err)
  end)

  def("dofile", function(I, args)
    local path = check_str(I, args, 1, "dofile")
    local fn, err = load_chunk_file(I, path)
    if not fn then I:rt_error(err) end
    return I:call(fn, { n = 0 })
  end)

  local dump = require("dump")

  def("load", function(I, args)
    local chunk = args[1]
    local chunkname = args[2]
    local mode = args[3]
    local env = args[4]
    local has_env = args.n >= 4
    local src
    if type(chunk) == "string" then
      src = chunk
      chunkname = chunkname or chunk
    elseif rt.is_callable(chunk) then
      local parts = {}
      local bad = false
      while true do
        local ok, r = I:protected(chunk, { n = 0 })   -- catch reader errors
        if not ok then return R(nil, r) end
        local piece = r[1]
        if piece == nil or piece == "" then break end
        if type(piece) ~= "string" then bad = true; break end
        parts[#parts + 1] = piece
      end
      if bad then return R(nil, "reader function must return a string") end
      src = table.concat(parts)
      chunkname = chunkname or "=(load)"
    else
      argerror(I, 1, "load", "string or function expected")
    end

    local binary = dump.is_binary(src)
    local allow_t = (mode == nil) or mode:find("t", 1, true)
    local allow_b = (mode == nil) or mode:find("b", 1, true)
    if binary and not allow_b then
      return R(nil, "attempt to load a binary chunk (mode is '" .. mode .. "')")
    end
    if (not binary) and not allow_t then
      return R(nil, "attempt to load a text chunk (mode is '" .. mode .. "')")
    end

    local ok, fn = pcall(function()
      if binary then
        local proto = dump.undump(src)
        return I:closure_from_proto(proto, env, has_env)
      else
        return I:load(src, chunkname, env, has_env)
      end
    end)
    if ok then
      return R(fn)
    else
      local msg = fn
      if type(msg) == "table" and getmetatable(msg) == I.GUEST_ERR_MT then
        msg = msg.value
      end
      return R(nil, tostring((msg):gsub("^.-:%d+: ", "")))
    end
  end)
end

-- ---------------------------------------------------------------------------
-- string library
-- ---------------------------------------------------------------------------

local function install_string(I)
  local G = I.globals
  local lib = rt.new_table()
  G.hash["string"] = lib
  local function def(name, fn) lib.hash[name] = fn end

  -- strings get a shared metatable with __index = string library
  local smeta = rt.new_table()
  smeta.hash["__index"] = lib
  I.string_meta = smeta

  -- simple host wrappers (operate purely on host strings/numbers)
  local function wrap_simple(name, hostfn)
    def(name, function(I, args)
      local s = check_str(I, args, 1, name)
      local hostargs = { s }
      for i = 2, args.n do hostargs[i] = args[i] end
      return R(hostfn(unpack(hostargs, 1, math.max(args.n, 1))))
    end)
  end

  wrap_simple("upper", string.upper)
  wrap_simple("lower", string.lower)
  wrap_simple("reverse", string.reverse)

  def("len", function(I, args)
    local s = check_str(I, args, 1, "len")
    return R(#s)
  end)

  def("sub", function(I, args)
    local s = check_str(I, args, 1, "sub")
    local i = opt_int(I, args, 2, "sub", 1)
    local j = opt_int(I, args, 3, "sub", -1)
    return R(string.sub(s, i, j))
  end)

  def("rep", function(I, args)
    local s = check_str(I, args, 1, "rep")
    local n = check_int(I, args, 2, "rep")
    local sep = args[3]
    if sep ~= nil then sep = check_str(I, args, 3, "rep") end
    if sep then return R(string.rep(s, n, sep)) end
    return R(string.rep(s, n))
  end)

  def("byte", function(I, args)
    local s = check_str(I, args, 1, "byte")
    local i = opt_int(I, args, 2, "byte", 1)
    local j = opt_int(I, args, 3, "byte", i)
    return R(string.byte(s, i, j))
  end)

  def("char", function(I, args)
    local cs = {}
    for i = 1, args.n do cs[i] = check_int(I, args, i, "char") end
    local ok, res = pcall(string.char, unpack(cs, 1, args.n))
    if not ok then argerror(I, 1, "char", "value out of range") end
    return R(res)
  end)

  -- pattern matching uses our own engine (strmatch), not the host's.
  local strmatch = require("strmatch")

  def("find", function(I, args)
    local s = check_str(I, args, 1, "find")
    local p = check_str(I, args, 2, "find")
    local init = opt_int(I, args, 3, "find", 1)
    local plain = rt.truthy(args[4])
    return strmatch.find(I, s, p, init, plain)
  end)

  def("match", function(I, args)
    local s = check_str(I, args, 1, "match")
    local p = check_str(I, args, 2, "match")
    local init = opt_int(I, args, 3, "match", 1)
    return strmatch.match(I, s, p, init)
  end)

  def("gmatch", function(I, args)
    local s = check_str(I, args, 1, "gmatch")
    local p = check_str(I, args, 2, "gmatch")
    local init = opt_int(I, args, 3, "gmatch", 1)
    local it = strmatch.gmatch(I, s, p, init)
    return R(function(I2, a2)
      local caps = it()
      if caps == nil then return R(nil) end
      return caps
    end)
  end)

  -- expand a %0/%1.. replacement template, fetching captures lazily via getcap
  local function expand_template(I, tmpl, whole, getcap)
    local out = {}
    local i, n = 1, #tmpl
    while i <= n do
      local c = tmpl:sub(i, i)
      if c == "%" then
        local d = tmpl:sub(i + 1, i + 1)
        if d == "%" then out[#out + 1] = "%"
        elseif d == "0" then out[#out + 1] = whole
        elseif d:match("%d") then
          local cv = getcap(tonumber(d))
          out[#out + 1] = (type(cv) == "number") and I:number_tostring(cv) or cv
        else
          I:rt_error("invalid use of '%' in replacement string")
        end
        i = i + 2
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
    return table.concat(out)
  end

  def("gsub", function(I, args)
    local s = check_str(I, args, 1, "gsub")
    local p = check_str(I, args, 2, "gsub")
    local repl = args[3]
    -- validate repl type, distinguishing "no value" from nil
    local rtp = type(repl)
    if not (rtp == "string" or rtp == "number" or rt.is_table(repl)
            or rt.is_callable(repl)) then
      typeerror(I, 3, "gsub", "string/function/table", args)
    end
    local maxn = nil
    if args[4] ~= nil then maxn = check_int(I, args, 4, "gsub") end

    local replfn
    if rtp == "string" or rtp == "number" then
      local tmpl = (rtp == "number") and I:number_tostring(repl) or repl
      replfn = function(whole, getcap, ncaps)
        return expand_template(I, tmpl, whole, getcap)
      end
    elseif rt.is_table(repl) then
      replfn = function(whole, getcap, ncaps)
        local v = I:index(repl, getcap(1))
        if v == nil or v == false then return nil end
        if type(v) ~= "string" and type(v) ~= "number" then
          I:rt_error("invalid replacement value (a " .. rt.typename(v) .. ")")
        end
        return (type(v) == "number") and I:number_tostring(v) or v
      end
    else
      replfn = function(whole, getcap, ncaps)
        local cargs = { n = ncaps }
        for i = 1, ncaps do cargs[i] = getcap(i) end
        local v = I:call(repl, cargs)[1]
        if v == nil or v == false then return nil end
        if type(v) ~= "string" and type(v) ~= "number" then
          I:rt_error("invalid replacement value (a " .. rt.typename(v) .. ")")
        end
        return (type(v) == "number") and I:number_tostring(v) or v
      end
    end

    local out, cnt = strmatch.gsub(I, s, p, replfn, maxn)
    return R(out, cnt)
  end)

  def("format", function(I, args)
    local fmt = check_str(I, args, 1, "format")
    local out = {}
    local argi = 1
    local i = 1
    local len = #fmt
    while i <= len do
      local c = fmt:sub(i, i)
      if c ~= "%" then
        out[#out + 1] = c
        i = i + 1
      else
        -- parse a format spec: %[-+ #0]*[width][.prec][conv]
        local j = i + 1
        while j <= len and fmt:sub(j, j):match("[%-%+ #0]") do j = j + 1 end
        while j <= len and fmt:sub(j, j):match("%d") do j = j + 1 end
        if j <= len and fmt:sub(j, j) == "." then
          j = j + 1
          while j <= len and fmt:sub(j, j):match("%d") do j = j + 1 end
        end
        local conv = fmt:sub(j, j)
        local spec = fmt:sub(i, j)
        if conv == "%" then
          out[#out + 1] = "%"
        elseif conv == "d" or conv == "i" then
          argi = argi + 1
          out[#out + 1] = hostfmt(spec, check_int(I, args, argi, "format"))
        elseif conv == "u" or conv == "o" or conv == "x" or conv == "X"
            or conv == "c" then
          argi = argi + 1
          out[#out + 1] = hostfmt(spec, check_int(I, args, argi, "format"))
        elseif conv == "e" or conv == "E" or conv == "f" or conv == "F"
            or conv == "g" or conv == "G" or conv == "a" or conv == "A" then
          argi = argi + 1
          out[#out + 1] = hostfmt(spec, check_num(I, args, argi, "format"))
        elseif conv == "s" then
          argi = argi + 1
          out[#out + 1] = hostfmt(spec, I:tostring(args[argi]))
        elseif conv == "p" then
          argi = argi + 1
          local v = args[argi]
          local t = type(v)
          local ptr
          if t == "string" or rt.is_table(v) or rt.is_closure(v)
             or rt.is_thread(v) or t == "function" then
            ptr = hostfmt("0x%012x", I:object_id(v))
          else
            ptr = "(null)"   -- nil/number/boolean have no pointer
          end
          -- apply the field width / flags via a %s conversion
          out[#out + 1] = hostfmt(spec:sub(1, -2) .. "s", ptr)
        elseif conv == "q" then
          if spec ~= "%q" then
            I:rt_error("specifier '%q' cannot have modifiers")
          end
          argi = argi + 1
          local v = args[argi]
          if type(v) == "string" or type(v) == "number"
             or type(v) == "boolean" or v == nil then
            out[#out + 1] = string.format("%q", v)
          else
            argerror(I, argi, "format", "value has no literal form")
          end
        else
          I:rt_error("invalid conversion '" .. spec .. "' to 'format'")
        end
        i = j + 1
      end
    end
    return R(table.concat(out))
  end)

  -- string.pack/unpack/packsize delegate to the host (Lua 5.4+ has them)
  if string.pack then
    def("pack", function(I, args)
      local fmt = check_str(I, args, 1, "pack")
      local rest = {}
      for k = 2, args.n do rest[k - 1] = args[k] end
      local ok, res = pcall(string.pack, fmt, unpack(rest, 1, args.n - 1))
      if not ok then I:rt_error((res:gsub("^.-:%d+: ", ""))) end
      return R(res)
    end)
    def("unpack", function(I, args)
      local fmt = check_str(I, args, 1, "unpack")
      local s = check_str(I, args, 2, "unpack")
      local pos = opt_int(I, args, 3, "unpack", 1)
      local ok, res = pcall(function() return pack(string.unpack(fmt, s, pos)) end)
      if not ok then I:rt_error((res:gsub("^.-:%d+: ", ""))) end
      return res
    end)
    def("packsize", function(I, args)
      local fmt = check_str(I, args, 1, "packsize")
      local ok, res = pcall(string.packsize, fmt)
      if not ok then I:rt_error((res:gsub("^.-:%d+: ", ""))) end
      return R(res)
    end)
  end

  def("dump", function(I, args)
    local fn = args[1]
    if type(fn) == "function" then
      I:rt_error("unable to dump given function")   -- native (C) function
    end
    if not rt.is_closure(fn) then typeerror(I, 1, "dump", "function", args) end
    local strip = rt.truthy(args[2])
    return R(require("dump").dump(fn.proto, strip))
  end)
end

-- ---------------------------------------------------------------------------
-- table library
-- ---------------------------------------------------------------------------

local function install_table(I)
  local G = I.globals
  local lib = rt.new_table()
  G.hash["table"] = lib
  local function def(name, fn) lib.hash[name] = fn end

  -- table functions access elements through metamethods (lua_geti/seti/luaL_len);
  -- the length (aux_getn) must be an integer.
  local function rget(t, k) return I:index(t, k) end
  local function rset(t, k, v) I:setindex(t, k, v) end
  local function rgetn(t)
    local n = I:len(t)
    local i = rt.toint(n)
    if i == nil then I:rt_error("object length is not an integer") end
    return i
  end

  def("insert", function(I, args)
    local t = check_table(I, args, 1, "insert")
    local len = rgetn(t)
    if args.n == 2 then
      rset(t, len + 1, args[2])
    elseif args.n == 3 then
      local pos = check_int(I, args, 2, "insert")
      if pos < 1 or pos > len + 1 then
        argerror(I, 2, "insert", "position out of bounds")
      end
      for i = len, pos, -1 do rset(t, i + 1, rget(t, i)) end
      rset(t, pos, args[3])
    else
      I:rt_error("wrong number of arguments to 'insert'")
    end
    return EMPTY
  end)

  def("remove", function(I, args)
    local t = check_table(I, args, 1, "remove")
    local size = rgetn(t)
    local pos = opt_int(I, args, 2, "remove", size)
    if pos ~= size then
      -- validate: 1 <= pos <= size+1  (Lua's unsigned (pos-1) <= size)
      if pos < 1 or pos > size + 1 then
        argerror(I, 2, "remove", "position out of bounds")
      end
    end
    local v = rget(t, pos)
    while pos < size do
      rset(t, pos, rget(t, pos + 1))
      pos = pos + 1
    end
    rset(t, pos, nil)
    return R(v)
  end)

  def("concat", function(I, args)
    local t = check_table(I, args, 1, "concat")
    local sep = args[2]
    if sep == nil then sep = "" else sep = check_str(I, args, 2, "concat") end
    local i = opt_int(I, args, 3, "concat", 1)
    local j = opt_int(I, args, 4, "concat", rgetn(t))
    local out = {}
    for k = i, j do
      local v = rget(t, k)
      if type(v) == "string" then
        out[#out + 1] = v
      elseif type(v) == "number" then
        out[#out + 1] = I:number_tostring(v)
      else
        I:rt_error(hostfmt("invalid value (%s) at index %d in table for 'concat'",
          rt.typename(v), k))
      end
    end
    return R(table.concat(out, sep))
  end)

  def("unpack", function(I, args)
    -- works on anything indexable (uses __index/__len), not just tables
    local t = args[1]
    local i = opt_int(I, args, 2, "unpack", 1)
    local j
    if args[3] ~= nil then j = check_int(I, args, 3, "unpack") else j = I:len(t) end
    if i > j then return { n = 0 } end
    local count = j - i + 1
    if count < 0 or count >= 0x7FFFFFFF then
      I:rt_error("too many results to unpack")
    end
    local out = { n = count }
    for k = i, j do out[k - i + 1] = I:index(t, k) end
    return out
  end)
  G.hash["unpack"] = nil  -- not a global in 5.4+

  def("pack", function(I, args)
    local t = rt.new_table(args.n)
    for i = 1, args.n do rset(t, i, args[i]) end
    rset(t, "n", args.n)
    return R(t)
  end)

  def("create", function(I, args)
    local n = check_int(I, args, 1, "create")
    if args[2] ~= nil then check_int(I, args, 2, "create") end
    return R(rt.new_table(n >= 0 and n or 0))
  end)

  def("move", function(I, args)
    -- Lua checks the integer args (#2,#3,#4) before the table args (#1,#5)
    local f = check_int(I, args, 2, "move")
    local e = check_int(I, args, 3, "move")
    local d = check_int(I, args, 4, "move")
    local a1 = check_table(I, args, 1, "move")
    local a2 = args[5]
    if a2 == nil then a2 = a1 else a2 = check_table(I, args, 5, "move") end
    if e >= f then
      if d > f and d <= e and a1 == a2 then
        for i = e, f, -1 do rset(a2, d + (i - f), rget(a1, i)) end
      else
        for i = f, e do rset(a2, d + (i - f), rget(a1, i)) end
      end
    end
    return R(a2)
  end)

  def("sort", function(I, args)
    local t = check_table(I, args, 1, "sort")
    local comp = args[2]
    if comp ~= nil and not rt.is_callable(comp) then
      typeerror(I, 2, "sort", "function", args)
    end
    local n = rgetn(t)
    local less
    if comp == nil then
      less = function(x, y) return I:lt(x, y) end
    else
      less = function(x, y)
        return rt.truthy(I:call(comp, { x, y, n = 2 })[1])
      end
    end
    rt.sort(I, n, function(i) return rget(t, i) end,
            function(i, v) rset(t, i, v) end, less)
    return EMPTY
  end)
end

-- ---------------------------------------------------------------------------
-- math library
-- ---------------------------------------------------------------------------

local function install_math(I)
  local G = I.globals
  local lib = rt.new_table()
  G.hash["math"] = lib
  local h = lib.hash
  local function def(name, fn) h[name] = fn end

  h["pi"] = math.pi
  h["huge"] = math.huge
  h["maxinteger"] = math.maxinteger
  h["mininteger"] = math.mininteger

  local function wrap1(name, fn)
    def(name, function(I, args)
      return R(fn(check_num(I, args, 1, name)))
    end)
  end
  wrap1("sqrt", math.sqrt); wrap1("sin", math.sin); wrap1("cos", math.cos)
  wrap1("tan", math.tan); wrap1("asin", math.asin); wrap1("acos", math.acos)
  wrap1("exp", math.exp)
  wrap1("deg", function(x) return x * (180.0 / math.pi) end)
  wrap1("rad", function(x) return x * (math.pi / 180.0) end)
  def("atan", function(I, args)
    local y = check_num(I, args, 1, "atan")
    if args[2] ~= nil then return R(math.atan(y, check_num(I, args, 2, "atan"))) end
    return R(math.atan(y))
  end)

  def("abs", function(I, args)
    return R(math.abs(check_num(I, args, 1, "abs")))
  end)
  def("ceil", function(I, args)
    return R(math.ceil(check_num(I, args, 1, "ceil")))
  end)
  def("floor", function(I, args)
    return R(math.floor(check_num(I, args, 1, "floor")))
  end)
  def("fmod", function(I, args)
    return R(math.fmod(check_num(I, args, 1, "fmod"), check_num(I, args, 2, "fmod")))
  end)
  def("modf", function(I, args)
    return R(math.modf(check_num(I, args, 1, "modf")))
  end)
  if math.frexp then
    def("frexp", function(I, args)
      return R(math.frexp(check_num(I, args, 1, "frexp")))
    end)
  end
  if math.ldexp then
    def("ldexp", function(I, args)
      return R(math.ldexp(check_num(I, args, 1, "ldexp"), check_int(I, args, 2, "ldexp")))
    end)
  end
  def("log", function(I, args)
    local x = check_num(I, args, 1, "log")
    if args[2] ~= nil then return R(math.log(x, check_num(I, args, 2, "log"))) end
    return R(math.log(x))
  end)
  def("max", function(I, args)
    if args.n == 0 then argerror(I, 1, "max", "number expected, got no value") end
    local m = check_num(I, args, 1, "max")
    for i = 2, args.n do
      local v = check_num(I, args, i, "max")
      if I:lt(m, v) then m = v end
    end
    return R(m)
  end)
  def("min", function(I, args)
    if args.n == 0 then argerror(I, 1, "min", "number expected, got no value") end
    local m = check_num(I, args, 1, "min")
    for i = 2, args.n do
      local v = check_num(I, args, i, "min")
      if I:lt(v, m) then m = v end
    end
    return R(m)
  end)
  def("tointeger", function(I, args)
    local v = args[1]
    if type(v) == "number" then return R(math.tointeger(v)) end
    return R(nil)
  end)
  def("type", function(I, args)
    local v = args[1]
    if type(v) ~= "number" then
      if args.n == 0 then argerror(I, 1, "type", "value expected") end
      return R(nil)
    end
    return R(mtype(v))
  end)
  def("ult", function(I, args)
    local x = check_int(I, args, 1, "ult")
    local y = check_int(I, args, 2, "ult")
    return R(math.ult(x, y))
  end)

  -- random: use host math.random; seedable
  def("random", function(I, args)
    if args.n == 0 then return R(math.random()) end
    local lo, hi
    if args.n == 1 then
      local m = check_int(I, args, 1, "random")
      if m == 0 then
        -- math.random(0): a full-range random integer
        return R(math.random(math.mininteger, math.maxinteger))
      end
      lo, hi = 1, m
    else
      lo, hi = check_int(I, args, 1, "random"), check_int(I, args, 2, "random")
    end
    if lo > hi then argerror(I, args.n, "random", "interval is empty") end
    return R(math.random(lo, hi))
  end)
  def("randomseed", function(I, args)
    -- returns the two seed components actually used (Lua 5.4+)
    if args[1] ~= nil then
      return R(math.randomseed(check_num(I, args, 1, "randomseed")))
    end
    return R(math.randomseed())
  end)
end

-- ---------------------------------------------------------------------------
-- os / io (minimal, host-backed)
-- ---------------------------------------------------------------------------

local function install_os(I)
  local G = I.globals
  local lib = rt.new_table()
  G.hash["os"] = lib
  local h = lib.hash
  h["time"] = function(I, args) return R(os.time()) end
  h["clock"] = function(I, args) return R(os.clock()) end
  h["date"] = function(I, args)
    local fmt = args[1]
    if fmt == nil then return R(os.date()) end
    fmt = check_str(I, args, 1, "date")
    if args[2] ~= nil then
      return R(os.date(fmt, check_int(I, args, 2, "date")))
    end
    return R(os.date(fmt))
  end
  h["getenv"] = function(I, args) return R(os.getenv(check_str(I, args, 1, "getenv"))) end
  h["difftime"] = function(I, args)
    return R(os.difftime(check_num(I, args, 1, "difftime"), check_num(I, args, 2, "difftime")))
  end
  h["tmpname"] = function(I, args) return R(os.tmpname()) end
  h["setlocale"] = function(I, args)
    local loc = args[1]
    local cat = args[2]
    if loc ~= nil then loc = check_str(I, args, 1, "setlocale") end
    if cat ~= nil then return R(os.setlocale(loc, check_str(I, args, 2, "setlocale"))) end
    return R(os.setlocale(loc))
  end
  h["execute"] = function(I, args)
    if args.n == 0 then return R(os.execute()) end
    local cmd = check_str(I, args, 1, "execute")
    return R(os.execute(cmd))
  end
  h["remove"] = function(I, args)
    local ok, err = os.remove(check_str(I, args, 1, "remove"))
    if ok then return R(true) end
    return R(nil, err)
  end
  h["rename"] = function(I, args)
    local ok, err = os.rename(check_str(I, args, 1, "rename"), check_str(I, args, 2, "rename"))
    if ok then return R(true) end
    return R(nil, err)
  end
  h["exit"] = function(I, args)
    local code = args[1]
    if code == nil or code == true then os.exit(0)
    elseif code == false then os.exit(1)
    else os.exit(rt.toint(code) or 0) end
  end
end

local function install_io(I)
  local G = I.globals
  local lib = rt.new_table()
  G.hash["io"] = lib
  local h = lib.hash

  -- file handle objects: GTable wrapping a host file, with a method metatable
  local file_methods = rt.new_table()
  local file_meta = rt.new_table()
  file_meta.hash["__index"] = file_methods
  file_meta.hash["__name"] = "FILE*"
  file_meta.hash["__tostring"] = function(I, args)
    local f = args[1]
    return R(f.hash.__closed and "file (closed)" or "file (0x0)")
  end

  local function wrap_file(hostf)
    local fobj = rt.new_table()
    fobj.meta = file_meta
    fobj.hash.__file = hostf
    return fobj
  end
  local function is_file(v) return rt.is_table(v) and v.meta == file_meta end

  local function norm_fmt(fmt)
    if type(fmt) == "string" then
      local f = fmt:gsub("^%*", "")   -- accept legacy "*l" etc.
      return f
    end
    return fmt
  end

  local function fm(name, fn) file_methods.hash[name] = fn end

  fm("write", function(I, args)
    local fobj = args[1]
    local hostf = fobj.hash.__file
    for i = 2, args.n do
      local v = args[i]
      if type(v) == "number" then hostf:write(I:number_tostring(v))
      elseif type(v) == "string" then hostf:write(v)
      else argerror(I, i - 1, "write", "string expected, got " .. rt.typename(v)) end
    end
    return R(fobj)
  end)

  fm("read", function(I, args)
    local hostf = args[1].hash.__file
    if args.n <= 1 then return R(hostf:read("l")) end
    local out = { n = args.n - 1 }
    for i = 2, args.n do
      local fmt = args[i]
      if type(fmt) == "number" then out[i - 1] = hostf:read(fmt)
      else out[i - 1] = hostf:read(norm_fmt(fmt)) end
    end
    return out
  end)

  fm("lines", function(I, args)
    local hostf = args[1].hash.__file
    local fmts = {}
    for i = 2, args.n do fmts[i - 1] = norm_fmt(args[i]) end
    local it = (#fmts > 0) and hostf:lines(unpack(fmts)) or hostf:lines()
    return R(function(I2, a2) return R(it()) end)
  end)

  fm("close", function(I, args)
    local hostf = args[1].hash.__file
    args[1].hash.__closed = true
    local ok = hostf:close()
    return R(ok)
  end)

  fm("flush", function(I, args)
    args[1].hash.__file:flush(); return R(args[1])
  end)

  fm("seek", function(I, args)
    local hostf = args[1].hash.__file
    local whence = args[2] or "cur"
    local offset = opt_int(I, args, 3, "seek", 0)
    local pos, err = hostf:seek(whence, offset)
    if pos then return R(pos) end
    return R(nil, err)
  end)

  fm("setvbuf", function(I, args)
    return R(args[1])
  end)

  local stdout = wrap_file(io.stdout)
  local stderr = wrap_file(io.stderr)
  local stdin = wrap_file(io.stdin)
  h["stdout"] = stdout
  h["stderr"] = stderr
  h["stdin"] = stdin
  local default_out = stdout
  local default_in = stdin

  h["tmpfile"] = function(I, args)
    local hostf, err = io.tmpfile()
    if not hostf then return R(nil, err) end
    return R(wrap_file(hostf))
  end

  if io.popen then
    h["popen"] = function(I, args)
      local cmd = check_str(I, args, 1, "popen")
      local mode = args[2]
      local hostf, err
      if mode ~= nil then hostf, err = io.popen(cmd, check_str(I, args, 2, "popen"))
      else hostf, err = io.popen(cmd) end
      if not hostf then return R(nil, err) end
      return R(wrap_file(hostf))
    end
  end

  h["open"] = function(I, args)
    local name = check_str(I, args, 1, "open")
    local mode = args[2]
    if mode ~= nil then mode = check_str(I, args, 2, "open") else mode = "r" end
    local hostf, err, code = io.open(name, mode)
    if not hostf then return R(nil, err, code) end
    return R(wrap_file(hostf))
  end

  h["close"] = function(I, args)
    local fobj = args[1] or default_out
    return I:call(file_methods.hash["close"], { fobj, n = 1 })
  end

  h["write"] = function(I, args)
    local a = { default_out, n = args.n + 1 }
    for i = 1, args.n do a[i + 1] = args[i] end
    return I:call(file_methods.hash["write"], a)
  end

  h["read"] = function(I, args)
    local a = { default_in, n = args.n + 1 }
    for i = 1, args.n do a[i + 1] = args[i] end
    return I:call(file_methods.hash["read"], a)
  end

  h["lines"] = function(I, args)
    if args[1] == nil or type(args[1]) == "string" then
      -- io.lines(filename, ...)
      local fname = args[1]
      local hostf
      if fname == nil then hostf = io.stdin
      else hostf = assert(io.open(check_str(I, args, 1, "lines"), "r")) end
      local fmts = {}
      for i = 2, args.n do fmts[i - 1] = norm_fmt(args[i]) end
      local it = (#fmts > 0) and hostf:lines(unpack(fmts)) or hostf:lines()
      return R(function(I2, a2) return R(it()) end)
    end
    return I:call(file_methods.hash["lines"], args)
  end

  h["flush"] = function(I, args)
    default_out.hash.__file:flush(); return R(default_out)
  end

  h["type"] = function(I, args)
    local v = args[1]
    if not is_file(v) then return R(nil) end
    if v.hash.__closed then return R("closed file") end
    return R("file")
  end

  h["output"] = function(I, args)
    if args[1] ~= nil then
      if is_file(args[1]) then default_out = args[1]
      else default_out = wrap_file(assert(io.open(check_str(I, args, 1, "output"), "w"))) end
    end
    return R(default_out)
  end
  h["input"] = function(I, args)
    if args[1] ~= nil then
      if is_file(args[1]) then default_in = args[1]
      else default_in = wrap_file(assert(io.open(check_str(I, args, 1, "input"), "r"))) end
    end
    return R(default_in)
  end
end

-- ---------------------------------------------------------------------------
-- coroutine library (mapped onto host coroutines)
-- ---------------------------------------------------------------------------

local function install_coroutine(I)
  local G = I.globals
  local lib = rt.new_table()
  G.hash["coroutine"] = lib
  local function def(name, fn) lib.hash[name] = fn end

  I.main_thread = setmetatable({ main = true }, rt.THREAD_MT)

  local function new_thread(f)
    local th = setmetatable({ frames = {}, depth = 0 }, rt.THREAD_MT)
    I:gc_register(th)
    th.co = coroutine.create(function(...)
      local a = pack(...)
      local res = I:call(f, a)
      return unpack(res, 1, res.n)
    end)
    return th
  end

  def("create", function(I, args)
    local f = check_func(I, args, 1, "create")
    return R(new_thread(f))
  end)

  local function do_resume(I, th, passargs)
    -- swap the per-coroutine frame stack and "current thread" in
    local saved_frames, saved_depth = I.frames, I.depth
    local saved_cur = I.current_thread
    I.frames, I.depth = th.frames, th.depth
    I.current_thread = th
    local rr = pack(coroutine.resume(th.co, unpack(passargs, 1, passargs.n)))
    th.frames, th.depth = I.frames, I.depth
    I.frames, I.depth = saved_frames, saved_depth
    I.current_thread = saved_cur
    return rr
  end

  def("resume", function(I, args)
    local th = args[1]
    if not rt.is_thread(th) then typeerror(I, 1, "resume", "thread", args) end
    if th.main or th.co == nil then
      return R(false, "cannot resume non-suspended coroutine")
    end
    local passargs = { n = args.n - 1 }
    for i = 2, args.n do passargs[i - 1] = args[i] end
    local rr = do_resume(I, th, passargs)
    if rr[1] then
      -- success: true, results...
      return rr
    else
      -- error: unwrap guest error value and remember it for coroutine.close
      local err = rr[2]
      if type(err) == "table" and getmetatable(err) == I.GUEST_ERR_MT then
        err = err.value
      end
      th.resume_error = err
      return R(false, err)
    end
  end)

  def("yield", function(I, args)
    return pack(coroutine.yield(unpack(args, 1, args.n)))
  end)

  def("status", function(I, args)
    local th = args[1]
    if not rt.is_thread(th) then typeerror(I, 1, "status", "thread", args) end
    if th.main then
      return R(th == I.current_thread and "running" or
               (I.current_thread == nil and "running" or "normal"))
    end
    if th == I.current_thread then return R("running") end
    return R(coroutine.status(th.co))
  end)

  def("isyieldable", function(I, args)
    if args.n >= 1 then
      local th = args[1]
      if not rt.is_thread(th) then typeerror(I, 1, "isyieldable", "thread", args) end
      if th.main then return R(false) end
      return R(coroutine.status(th.co) ~= "dead")
    end
    return R(I.current_thread ~= nil)
  end)

  def("running", function(I, args)
    if I.current_thread ~= nil then
      return R(I.current_thread, false)
    end
    return R(I.main_thread, true)
  end)

  def("close", function(I, args)
    local th = args[1]
    if args.n == 0 then th = I.current_thread or I.main_thread end
    if not rt.is_thread(th) then typeerror(I, 1, "close", "thread", args) end
    -- determine status: a thread is "running" if it's the current execution
    -- context, "normal" if it has resumed another, else suspended/dead
    local status
    if th.main then
      status = (I.current_thread == nil) and "running" or "normal"
    elseif th == I.current_thread then
      status = "running"
    else
      status = coroutine.status(th.co)
    end
    if status == "running" then
      I:rt_error(th.main and "cannot close main thread" or "cannot close a running coroutine")
    elseif status == "normal" then
      I:rt_error("cannot close a normal coroutine")
    end
    -- run the coroutine's pending to-be-closed handlers (inner frames first),
    -- in the coroutine's own context, then dispose of the host coroutine.
    local closeerr
    if th.frames and #th.frames > 0 then
      local saved = I.current_thread
      I.current_thread = th
      for i = #th.frames, 1, -1 do
        local fr = th.frames[i]
        if fr.tbc and #fr.tbc > 0 then
          local ok, e = pcall(I.close_upvals, I, fr, 0, closeerr)
          if not ok then closeerr = e end
        end
      end
      I.current_thread = saved
      th.frames = {}
    end
    coroutine.close(th.co)
    -- the error that killed the coroutine (if any) takes precedence
    local err = closeerr
    if type(err) == "table" and getmetatable(err) == I.GUEST_ERR_MT then
      err = err.value
    end
    if err == nil then err = th.resume_error end
    th.resume_error = nil
    if err ~= nil then return R(false, err) end
    return R(true)
  end)

  def("wrap", function(I, args)
    local f = check_func(I, args, 1, "wrap")
    local th = new_thread(f)
    return R(function(I2, a2)
      local rr = do_resume(I2, th, a2)
      if rr[1] then
        local out = { n = rr.n - 1 }
        for i = 2, rr.n do out[i - 1] = rr[i] end
        return out
      else
        local err = rr[2]
        if type(err) == "table" and getmetatable(err) == I.GUEST_ERR_MT then
          err = err.value
        end
        I:throw(err)
      end
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- debug library
-- ---------------------------------------------------------------------------

local function install_debug(I)
  local G = I.globals
  local lib = rt.new_table()
  G.hash["debug"] = lib
  local function def(name, fn) lib.hash[name] = fn end

  def("traceback", function(I, args)
    -- debug.traceback([thread,] [message [, level]])
    local idx = 1
    if rt.is_thread(args[1]) then idx = 2 end
    local msg = args[idx]
    if msg ~= nil and type(msg) ~= "string" and type(msg) ~= "number" then
      return R(msg)   -- non-string/number message: returned unchanged
    end
    local level = opt_int(I, args, idx + 1, "traceback", 1)
    -- level 1 = caller of traceback (build_traceback starts at #frames - level,
    -- which skips traceback's own native frame at the top)
    return R(I:build_traceback(msg, level))
  end)

  def("getinfo", function(I, args)
    local idx = 1
    if rt.is_thread(args[1]) then idx = 2 end
    local f = args[idx]
    local what = args[idx + 1] or "nSltu"
    for i = 1, #what do
      if not ("nSltufLr"):find(what:sub(i, i), 1, true) then
        argerror(I, idx + 1, "getinfo", "invalid option")
      end
    end
    local info = rt.new_table()
    local h = info.hash
    if type(f) == "number" then
      -- level: 1 = caller of getinfo
      local level = rt.toint(f)
      local frame = I.frames[#I.frames - level]
      if frame == nil then return R(nil) end
      if frame.native then
        h["source"] = "=[C]"; h["short_src"] = "[C]"
        h["currentline"] = -1; h["what"] = "C"
        h["linedefined"] = -1; h["lastlinedefined"] = -1
      else
        local p = frame.proto
        h["source"] = p.chunkname or ("@" .. p.source)
        h["short_src"] = p.source
        h["currentline"] = p.lines[frame.savedpc] or -1
        h["what"] = frame.proto.is_main and "main" or "Lua"
        h["linedefined"] = p.line or 0
        h["nparams"] = p.numparams
        h["nups"] = #p.upvals
        h["isvararg"] = p.is_vararg
      end
      -- name info ("n"): how this function was called, seen from its caller
      if what:find("n", 1, true) then
        h["namewhat"] = ""
        local caller = I.frames[#I.frames - level - 1]
        if caller and caller.cl and not caller.native and caller.proto then
          local ci = caller.proto.code[caller.savedpc]
          if ci and (ci.op == "CALL" or ci.op == "TAILCALL") then
            local kind, nm = I:reg_name(caller.cl, caller.savedpc, ci.a)
            if kind and nm then h["name"] = nm; h["namewhat"] = kind end
          end
        end
      end
    elseif rt.is_closure(f) then
      local p = f.proto
      h["source"] = p.chunkname or ("@" .. p.source)
      h["short_src"] = p.source
      h["what"] = p.is_main and "main" or "Lua"
      h["linedefined"] = p.line or 0
      h["currentline"] = -1
      h["nparams"] = p.numparams
      h["nups"] = #p.upvals
      h["isvararg"] = p.is_vararg
    elseif type(f) == "function" then
      h["source"] = "=[C]"; h["short_src"] = "[C]"
      h["what"] = "C"; h["currentline"] = -1
      h["linedefined"] = -1; h["lastlinedefined"] = -1
      h["nups"] = 0
    else
      argerror(I, idx, "getinfo", "function or level expected")
    end
    return R(info)
  end)

  def("getlocal", function(I, args)
    local idx = 1
    if rt.is_thread(args[1]) then idx = 2 end
    local level = check_int(I, args, idx, "getlocal")
    local n = check_int(I, args, idx + 1, "getlocal")
    local frame = I.frames[#I.frames - level]
    if frame == nil or frame.native or not frame.proto then return R(nil) end
    -- find n-th local active at current pc
    local count = 0
    for _, lv in ipairs(frame.proto.locvars) do
      if lv.startpc <= frame.savedpc and (lv.endpc == nil or frame.savedpc < lv.endpc) then
        count = count + 1
        if count == n then
          return R(lv.name, frame.R[lv.reg])
        end
      end
    end
    return R(nil)
  end)

  def("setlocal", function(I, args)
    local idx = 1
    if rt.is_thread(args[1]) then idx = 2 end
    local level = check_int(I, args, idx, "setlocal")
    local n = check_int(I, args, idx + 1, "setlocal")
    local value = args[idx + 2]
    local frame = I.frames[#I.frames - level]
    if frame == nil or frame.native or not frame.proto then return R(nil) end
    local count = 0
    for _, lv in ipairs(frame.proto.locvars) do
      if lv.startpc <= frame.savedpc and (lv.endpc == nil or frame.savedpc < lv.endpc) then
        count = count + 1
        if count == n then
          frame.R[lv.reg] = value
          return R(lv.name)
        end
      end
    end
    return R(nil)
  end)

  def("getupvalue", function(I, args)
    local f = args[1]
    local n = check_int(I, args, 2, "getupvalue")
    if not rt.is_closure(f) then return R(nil) end
    local ud = f.proto.upvals[n]
    if ud == nil then return R(nil) end
    local uv = f.upvals[n]
    local val = uv.closed and uv.val or uv.frame_R[uv.idx]
    return R(ud.name, val)
  end)

  def("setupvalue", function(I, args)
    local f = args[1]
    local n = check_int(I, args, 2, "setupvalue")
    local v = args[3]
    if not rt.is_closure(f) then return R(nil) end
    local ud = f.proto.upvals[n]
    if ud == nil then return R(nil) end
    local uv = f.upvals[n]
    if uv.closed then uv.val = v else uv.frame_R[uv.idx] = v end
    return R(ud.name)
  end)

  def("getmetatable", function(I, args)
    if args.n == 0 then argerror(I, 1, "getmetatable", "value expected") end
    local mt = I:getmeta(args[1])
    return R(mt)
  end)

  def("setmetatable", function(I, args)
    local t = args[1]
    local mt = args[2]
    if not (args.n >= 2 and (mt == nil or rt.is_table(mt))) then
      local got = (args.n < 2) and "no value" or rt.typename(mt)
      argerror(I, 2, "setmetatable", "nil or table expected, got " .. got)
    end
    if rt.is_table(t) then t.meta = mt end
    return R(t)
  end)

  def("upvalueid", function(I, args)
    local f = args[1]
    local n = check_int(I, args, 2, "upvalueid")
    if not rt.is_closure(f) then typeerror(I, 1, "upvalueid", "function", args) end
    local uv = f.upvals[n]
    if uv == nil then argerror(I, 2, "upvalueid", "invalid upvalue index") end
    return R(uv)   -- the upvalue object serves as a unique id (userdata-like)
  end)
  def("upvaluejoin", function(I, args)
    local f1, n1, f2, n2 = args[1], check_int(I, args, 2, "upvaluejoin"),
      args[3], check_int(I, args, 4, "upvaluejoin")
    if rt.is_closure(f1) and rt.is_closure(f2) then
      f1.upvals[n1] = f2.upvals[n2]
    end
    return EMPTY
  end)
  def("sethook", function(I, args)
    local idx = rt.is_thread(args[1]) and 2 or 1
    local fn = args[idx]
    if fn == nil then
      I.hook = nil
      return EMPTY
    end
    local mask = args[idx + 1]
    if type(mask) ~= "string" then mask = "" end
    local count = opt_int(I, args, idx + 2, "sethook", 0)
    I.hook = {
      fn = fn,
      call = mask:find("c", 1, true) ~= nil,
      ret = mask:find("r", 1, true) ~= nil,
      line = mask:find("l", 1, true) ~= nil,
      count = (count > 0) and count or nil,
      mask = mask,
    }
    I.hookcount = I.hook.count or 0
    return EMPTY
  end)
  def("gethook", function(I, args)
    if I.hook == nil then return R(nil) end
    local m = ""
    if I.hook.call then m = m .. "c" end
    if I.hook.ret then m = m .. "r" end
    if I.hook.line then m = m .. "l" end
    return R(I.hook.fn, m, I.hook.count or 0)
  end)
  def("getregistry", function(I, args)
    I.registry = I.registry or rt.new_table()
    return R(I.registry)
  end)
  def("traceback", lib.hash["traceback"])
end

-- ---------------------------------------------------------------------------
-- package / require
-- ---------------------------------------------------------------------------

local function install_package(I)
  local G = I.globals
  local pkg = rt.new_table()
  G.hash["package"] = pkg
  local loaded = rt.new_table()
  pkg.hash["loaded"] = loaded
  pkg.hash["preload"] = rt.new_table()
  pkg.hash["path"] = "./?.lua;./?/init.lua"
  pkg.hash["cpath"] = ""
  pkg.hash["config"] = "/\n;\n?\n!\n-\n"

  -- register already-built-in libraries in package.loaded (incl. package itself)
  for _, name in ipairs({ "string", "table", "math", "os", "io",
                          "coroutine", "debug", "utf8" }) do
    if G.hash[name] then loaded.hash[name] = G.hash[name] end
  end
  loaded.hash["_G"] = G
  loaded.hash["package"] = pkg

  pkg.hash["searchpath"] = function(I, args)
    local name = check_str(I, args, 1, "searchpath")
    local path = check_str(I, args, 2, "searchpath")
    local sep = args[3]
    local rep = args[4]
    if sep ~= nil and sep ~= "" then
      name = name:gsub(sep:gsub("(%W)", "%%%1"), (rep == nil) and "/" or rep)
    end
    local tried = {}
    for tmpl in path:gmatch("[^;]+") do
      local fname = tmpl:gsub("%?", name)
      local fh = io.open(fname, "r")
      if fh then fh:close(); return R(fname) end
      tried[#tried + 1] = "\n\tno file '" .. fname .. "'"
    end
    return R(nil, table.concat(tried))
  end

  G.hash["require"] = function(I, args)
    local name = check_str(I, args, 1, "require")
    if loaded.hash[name] ~= nil then return R(loaded.hash[name]) end
    -- preload?
    local pre = pkg.hash["preload"].hash[name]
    if pre ~= nil then
      local r = I:call(pre, { name, n = 1 })
      local v = r[1]
      if v == nil then v = true end
      loaded.hash[name] = v
      return R(v)
    end
    -- search package.path
    local path = pkg.hash["path"]
    local relname = name:gsub("%.", "/")
    local tried = {}
    for tmpl in path:gmatch("[^;]+") do
      local fname = tmpl:gsub("%?", relname)
      local fh = io.open(fname, "rb")
      if fh then
        local src = fh:read("a"); fh:close()
        local fn = I:load(src, "@" .. fname)
        local r = I:call(fn, { name, fname, n = 2 })
        local v = r[1]
        if v == nil then v = true end
        loaded.hash[name] = v
        return R(v)
      end
      tried[#tried + 1] = "\n\tno file '" .. fname .. "'"
    end
    I:rt_error("module '" .. name .. "' not found:" .. table.concat(tried))
  end
end

-- ---------------------------------------------------------------------------
-- utf8 library (host-backed)
-- ---------------------------------------------------------------------------

local function install_utf8(I)
  if not utf8 then return end
  local G = I.globals
  local lib = rt.new_table()
  G.hash["utf8"] = lib
  local h = lib.hash
  h["charpattern"] = utf8.charpattern
  -- call a host function, converting a host error into a guest runtime error
  local function guarded(I, fn, ...)
    local res = pack(pcall(fn, ...))
    if not res[1] then
      I:rt_error((tostring(res[2]):gsub("^.-:%d+: ", "")))
    end
    return res
  end
  h["char"] = function(I, args)
    local cs = {}
    for i = 1, args.n do cs[i] = check_int(I, args, i, "char") end
    local res = guarded(I, utf8.char, unpack(cs, 1, args.n))
    return R(res[2])
  end
  h["len"] = function(I, args)
    local s = check_str(I, args, 1, "len")
    local i = opt_int(I, args, 2, "len", 1)
    local j = opt_int(I, args, 3, "len", -1)
    if args[4] ~= nil then return R(utf8.len(s, i, j, rt.truthy(args[4]))) end
    return R(utf8.len(s, i, j))
  end
  h["offset"] = function(I, args)
    local s = check_str(I, args, 1, "offset")
    local n = check_int(I, args, 2, "offset")
    if args[3] ~= nil then
      return R(utf8.offset(s, n, check_int(I, args, 3, "offset")))
    end
    return R(utf8.offset(s, n))
  end
  h["codepoint"] = function(I, args)
    local s = check_str(I, args, 1, "codepoint")
    local i = opt_int(I, args, 2, "codepoint", 1)
    local j = opt_int(I, args, 3, "codepoint", i)
    local res
    if args[4] ~= nil then
      res = guarded(I, utf8.codepoint, s, i, j, rt.truthy(args[4]))
    else
      res = guarded(I, utf8.codepoint, s, i, j)
    end
    return { n = res.n - 1, table.unpack(res, 2, res.n) }
  end
  h["codes"] = function(I, args)
    local s = check_str(I, args, 1, "codes")
    local it, st, ctrl
    if args[2] ~= nil then it, st, ctrl = utf8.codes(s, rt.truthy(args[2]))
    else it, st, ctrl = utf8.codes(s) end
    return R(function(I2, a2)
      local r = pack(pcall(it, st, a2[2]))
      if not r[1] then I2:rt_error((tostring(r[2]):gsub("^.-:%d+: ", ""))) end
      return { n = r.n - 1, table.unpack(r, 2, r.n) }
    end, s, 0)
  end
end

-- ---------------------------------------------------------------------------
-- bit32 library (32-bit unsigned operations)
-- ---------------------------------------------------------------------------

local function install_bit32(I)
  local G = I.globals
  local lib = rt.new_table()
  G.hash["bit32"] = lib
  local h = lib.hash
  local MASK = 0xFFFFFFFF
  local function tobit(I, args, n) return (check_int(I, args, n, "bit32") & MASK) end
  h["band"] = function(I, args)
    local r = MASK
    for i = 1, args.n do r = r & (check_int(I, args, i, "band") & MASK) end
    return R(r & MASK)
  end
  h["bor"] = function(I, args)
    local r = 0
    for i = 1, args.n do r = r | (check_int(I, args, i, "bor") & MASK) end
    return R(r & MASK)
  end
  h["bxor"] = function(I, args)
    local r = 0
    for i = 1, args.n do r = r ~ (check_int(I, args, i, "bxor") & MASK) end
    return R(r & MASK)
  end
  h["bnot"] = function(I, args)
    return R((~tobit(I, args, 1)) & MASK)
  end
  h["lshift"] = function(I, args)
    local x = tobit(I, args, 1); local n = check_int(I, args, 2, "lshift")
    if n <= -32 or n >= 32 then return R(0) end
    if n >= 0 then return R((x << n) & MASK) else return R((x >> -n) & MASK) end
  end
  h["rshift"] = function(I, args)
    local x = tobit(I, args, 1); local n = check_int(I, args, 2, "rshift")
    if n <= -32 or n >= 32 then return R(0) end
    if n >= 0 then return R((x >> n) & MASK) else return R((x << -n) & MASK) end
  end
  h["arshift"] = function(I, args)
    local x = tobit(I, args, 1); local n = check_int(I, args, 2, "arshift")
    if n >= 32 then return R((x & 0x80000000) ~= 0 and MASK or 0) end
    if n <= -32 then return R(0) end
    if n >= 0 then
      local r = x >> n
      if (x & 0x80000000) ~= 0 then r = r | ((MASK << (32 - n)) & MASK) end
      return R(r & MASK)
    else
      return R((x << -n) & MASK)
    end
  end
  h["extract"] = function(I, args)
    local n = tobit(I, args, 1)
    local field = check_int(I, args, 2, "extract")
    local width = opt_int(I, args, 3, "extract", 1)
    return R((n >> field) & ((1 << width) - 1))
  end
  h["replace"] = function(I, args)
    local n = tobit(I, args, 1)
    local v = check_int(I, args, 2, "replace") & MASK
    local field = check_int(I, args, 3, "replace")
    local width = opt_int(I, args, 4, "replace", 1)
    local m = ((1 << width) - 1) << field
    return R(((n & ~m) | ((v << field) & m)) & MASK)
  end
end

-- ---------------------------------------------------------------------------

-- build the function -> canonical-name map used for argument-error messages
function M.build_func_names(I)
  local names = {}
  I.func_names = names
  local G = I.globals.hash
  for k, v in pairs(G) do
    if type(v) == "function" and type(k) == "string" then names[v] = k end
  end
  for _, lib in ipairs({ "string", "table", "math", "os", "io",
                         "coroutine", "debug", "utf8", "package" }) do
    local t = G[lib]
    if rt.is_table(t) then
      for k, v in pairs(t.hash) do
        if type(v) == "function" and type(k) == "string" then
          names[v] = lib .. "." .. k
        end
      end
    end
  end
end

function M.install_all(I)
  install_base(I)
  install_string(I)
  install_table(I)
  install_math(I)
  install_os(I)
  install_io(I)
  install_coroutine(I)
  install_debug(I)
  install_utf8(I)
  install_package(I)
  install_bit32(I)
  M.build_func_names(I)
end

return M
