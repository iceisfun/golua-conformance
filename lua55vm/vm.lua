-- lua55vm/vm.lua
-- The guest bytecode interpreter.
--
-- The Interp object owns globals, runtime ops (mixed in from runtime.lua) and
-- the execution loop.  Guest calls recurse on the host stack, which lets guest
-- coroutines map directly onto host coroutines.

local rt = require("runtime")

local Interp = {}
Interp.__index = Interp

local mtype = math.type
local floor = math.floor
local tointeger = math.tointeger

local function truthy(v) return v ~= nil and v ~= false end

local ult = math.ult

-- unsigned 64-bit division of the bit patterns a, b (b ~= 0)
local function udiv(a, b)
  if b < 0 then                 -- b >= 2^63 as unsigned
    return ult(a, b) and 0 or 1
  end
  if a >= 0 then return a // b end
  -- a >= 2^63 as unsigned, b in [1, 2^63): divide via logical halving
  local q = ((a >> 1) // b) << 1
  local r = a - q * b           -- remainder bits, in [0, 2b) unsigned
  if not ult(r, b) then q = q + 1 end
  return q
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

function Interp.new()
  local self = setmetatable({}, Interp)
  self.globals = rt.new_table()
  self.string_meta = nil
  self.type_meta = {}                 -- typename -> GTable
  self.GUEST_ERR_MT = { __name = "guesterror" }
  self.object_ids = setmetatable({}, { __mode = "k" })
  self.next_object_id = 0x10000
  self.float_fmt = "%.14g"
  self.frames = {}                    -- guest call stack (for errors/traceback)
  self.depth = 0
  self.max_depth = 10000              -- matches golua DefaultMaxCallDepth
  return self
end

rt.install(Interp)

-- ---------------------------------------------------------------------------
-- Upvalues
-- ---------------------------------------------------------------------------

local function uv_get(uv)
  if uv.closed then return uv.val else return uv.frame_R[uv.idx] end
end
local function uv_set(uv, v)
  if uv.closed then uv.val = v else uv.frame_R[uv.idx] = v end
end

function Interp:find_upval(frame, reg)
  local uv = frame.openuv[reg]
  if uv == nil then
    uv = { frame_R = frame.R, idx = reg, closed = false }
    frame.openuv[reg] = uv
  end
  return uv
end

-- Close open upvalues and run to-be-closed handlers for registers >= level, in
-- reverse declaration order. A pending error (from the triggering error or from
-- an earlier __close) is passed as the 2nd argument to each handler and chains:
-- if a handler raises, that becomes the new pending error. Returns the final
-- pending error (or nil); callers re-raise it.
function Interp:close_upvals(frame, level, errobj)
  local pending = errobj
  if frame.tbc and #frame.tbc > 0 then
    local base_n, base_d = #self.frames, self.depth
    for i = #frame.tbc, 1, -1 do
      local reg = frame.tbc[i]
      if reg >= level then
        table.remove(frame.tbc, i)
        local val = frame.R[reg]
        if val ~= nil and val ~= false then
          local h = self:metamethod(val, "__close")
          if h == nil then
            pending = setmetatable({ value = self:where() ..
              "attempt to call a nil value (metamethod 'close')" }, self.GUEST_ERR_MT)
          else
            local args
            if pending ~= nil then
              local ev = pending
              if type(ev) == "table" and getmetatable(ev) == self.GUEST_ERR_MT then
                ev = ev.value
              end
              args = { val, ev, n = 2 }       -- error close: __close(value, err)
            else
              args = { val, n = 1 }           -- normal close: __close(value)
            end
            -- pop any frames a PREVIOUS errored close left behind, so each
            -- handler runs at the same level (correct getinfo/traceback). The
            -- last errored close's frames are left for the propagating traceback.
            for j = #self.frames, base_n + 1, -1 do self.frames[j] = nil end
            self.depth = base_d
            self.next_callinfo = { what = "metamethod", name = "close" }
            local ok, err = pcall(self.call, self, h, args)
            if not ok then pending = err end
          end
        end
      end
    end
  end
  local openuv = frame.openuv
  for reg, uv in pairs(openuv) do
    if reg >= level then
      uv.val = uv.frame_R[uv.idx]
      uv.closed = true
      uv.frame_R = nil
      openuv[reg] = nil
    end
  end
  return pending
end

-- ---------------------------------------------------------------------------
-- where() for error positions
-- ---------------------------------------------------------------------------

local function frame_loc(frame)
  if not frame or frame.native or not frame.proto then return "" end
  local line = frame.proto.lines[frame.savedpc] or 0
  return string.format("%s:%d: ", frame.proto.source, line)
end

-- location for a runtime/library error. If the running frame is a native
-- function (luaL_error style), report its caller (level 1); otherwise the
-- error came from a VM op, so report the current guest frame.
function Interp:where()
  local frames = self.frames
  local top = frames[#frames]
  if top and top.native then
    return frame_loc(frames[#frames - 1])
  end
  return frame_loc(top)
end

-- location at an explicit level (for error()): the currently running built-in
-- is at the top of the stack, so level 1 == its caller.
function Interp:where_level(level)
  return frame_loc(self.frames[#self.frames - level])
end

-- ---------------------------------------------------------------------------
-- Variable info for error messages (Lua's getobjname / varinfo)
-- ---------------------------------------------------------------------------

-- find the name of an active local occupying `reg` at instruction `pc`
local function local_name(proto, reg, pc)
  local best
  for _, lv in ipairs(proto.locvars) do
    if lv.reg == reg and lv.startpc <= pc and (lv.endpc == nil or pc < lv.endpc) then
      best = lv.name   -- last matching range wins
    end
  end
  return best
end

-- describe what produced register `reg` at pc: returns kind, name (or nil)
function Interp:reg_name(cl, pc, reg)
  local proto = cl.proto
  local nm = local_name(proto, reg, pc)
  if nm then return "local", nm end
  -- scan backwards for the instruction that last wrote `reg`
  local code = proto.code
  for i = pc - 1, 1, -1 do
    local ins = code[i]
    local op = ins.op
    if op == "GETTABUP" and ins.a == reg then
      local uname = proto.upvals[ins.b] and proto.upvals[ins.b].name
      local key = proto.consts[ins.c]
      if uname == "_ENV" and type(key) == "string" then return "global", key end
      if type(key) == "string" then return "field", key end
      return nil
    elseif op == "GETFIELD" and ins.a == reg then
      local key = proto.consts[ins.c]
      if type(key) == "string" then return "field", key end
      return nil
    elseif op == "GETUPVAL" and ins.a == reg then
      local u = proto.upvals[ins.b]
      return "upvalue", u and u.name
    elseif op == "SELF" and ins.a == reg then
      local key = proto.consts[ins.c]
      if type(key) == "string" then return "method", key end
      return nil
    elseif op == "LOADK" and ins.a == reg then
      local k = proto.consts[ins.b]
      if type(k) == "string" then return "constant", k end
      return nil
    elseif op == "MOVE" and ins.a == reg then
      -- follow the move source (only if source is a local)
      local snm = local_name(proto, ins.b, i)
      if snm then return "local", snm end
      return nil
    elseif (op == "CALL" or op == "GETTABLE" or op == "NEWTABLE"
            or op == "CLOSURE" or op == "VARARG") and ins.a == reg then
      return nil
    end
  end
  return nil
end

-- build the "(kind 'name')" suffix for an operand register
function Interp:name_suffix(frame, reg)
  if not frame or not frame.cl then return "" end
  local kind, name = self:reg_name(frame.cl, frame.savedpc, reg)
  if kind and name then
    return string.format(" (%s '%s')", kind, name)
  end
  return ""
end

-- name (namewhat, name) of frame i, as seen from its caller (getfuncname)
function Interp:frame_name(i)
  local f = self.frames[i]
  if f.callinfo then return f.callinfo.what, f.callinfo.name end
  local caller = self.frames[i - 1]
  if caller and not caller.native and caller.proto then
    local ci = caller.proto.code[caller.savedpc]
    if ci and (ci.op == "CALL" or ci.op == "TAILCALL") then
      return self:reg_name(caller.cl, caller.savedpc, ci.a)
    end
  end
  return nil
end

-- one traceback line for frame i (matches luaL_traceback formatting)
function Interp:traceback_line(i)
  local f = self.frames[i]
  local what, name = self:frame_name(i)
  local namepart
  if what and name then namepart = what .. " '" .. name .. "'" end
  if f.native then
    return "[C]: in " .. (namepart or "?")
  end
  local p = f.proto
  local line = p.lines[f.savedpc] or -1
  if p.is_main then
    return string.format("%s:%d: in main chunk", p.source, line)
  end
  if not namepart then
    namepart = string.format("function <%s:%d>", p.source, p.line or 0)
  end
  return string.format("%s:%d: in %s", p.source, line, namepart)
end

-- build a stack traceback string (luaL_traceback). level 1 = caller of the
-- traceback call (its own native frame is at the top of self.frames).
function Interp:build_traceback(msg, level)
  local out = {}
  if msg ~= nil then out[#out + 1] = msg end
  out[#out + 1] = "stack traceback:"
  local frames = self.frames
  local top = #frames - (level or 1)
  for i = top, 1, -1 do
    out[#out + 1] = "\t" .. self:traceback_line(i)
  end
  out[#out + 1] = "\t[C]: in ?"
  return table.concat(out, "\n")
end

-- find the variable-name suffix for `value` among the registers recorded by
-- the current op's error hint (used by arith/concat/len/unm error messages).
function Interp:hint_for(value)
  local h = self.errhint
  if not h then return "" end
  local f = h.frame
  for i = 1, #h.regs do
    local reg = h.regs[i]
    if f.R[reg] == value then return self:name_suffix(f, reg) end
  end
  return ""
end

-- ---------------------------------------------------------------------------
-- Calling
-- ---------------------------------------------------------------------------

-- call any callable; args = {n=, [1..]}; returns results = {n=, [1..]}
function Interp:call(fn, args)
  self.errhint = nil    -- invalidate any pending operand hint
  if type(fn) == "function" then
    -- native: push a marker frame so error levels / tracebacks count it
    local frames = self.frames
    local nf = { native = true, fn = fn }
    frames[#frames + 1] = nf
    local res = fn(self, args)
    frames[#frames] = nil
    if res == nil then return { n = 0 } end
    return res
  elseif rt.is_closure(fn) then
    return self:run_closure(fn, args)
  else
    local h = self:metamethod(fn, "__call")
    if h ~= nil then
      local nargs = { n = args.n + 1, fn }
      for i = 1, args.n do nargs[i + 1] = args[i] end
      return self:call(h, nargs)
    end
    self:rt_error("attempt to call a " .. rt.typename(fn) .. " value")
  end
end

local OP  -- forward declaration of dispatch handlers

-- fire a debug hook event ("call"/"return"/"line"/"count"/"tail call").
-- The hook is disabled while it runs to avoid recursion.
function Interp:fire_hook(event, line)
  local hook = self.hook
  if hook == nil or self.in_hook then return end
  self.in_hook = true
  local ok, err = pcall(self.call, self, hook.fn,
    { event, line, n = (line ~= nil) and 2 or 1 })
  self.in_hook = false
  if not ok then error(err, 0) end
end

function Interp:run_closure(cl, args)
  local proto = cl.proto
  self.depth = self.depth + 1
  if self.depth > self.max_depth then
    self.depth = self.depth - 1
    self:rt_error("stack overflow")
  end
  local R = {}
  local np = proto.numparams
  for i = 1, np do R[i - 1] = args[i] end
  -- collect varargs
  local varargs
  if proto.is_vararg and args.n > np then
    varargs = { n = args.n - np }
    for i = np + 1, args.n do varargs[i - np] = args[i] end
  else
    varargs = { n = 0 }
  end
  -- initialize remaining registers to nil (host: leave absent)
  local frame = {
    cl = cl, proto = proto, R = R, varargs = varargs,
    openuv = {}, tbc = {}, top = np, savedpc = 1,
    callinfo = self.next_callinfo,   -- how this closure was invoked (metamethod)
  }
  self.next_callinfo = nil
  self.frames[#self.frames + 1] = frame

  if self.hook and self.hook.call then self:fire_hook("call") end
  -- exec_loop may raise (propagating to a guest pcall boundary, which restores
  -- the frame stack and depth).  On normal return we pop here.
  local result = self:exec_loop(frame)
  if self.hook and self.hook.ret then self:fire_hook("return") end
  self.frames[#self.frames] = nil
  self.depth = self.depth - 1
  return result
end

-- ---------------------------------------------------------------------------
-- The execution loop
-- ---------------------------------------------------------------------------

local OPSYM = {
  ADD="+", SUB="-", MUL="*", DIV="/", IDIV="//", MOD="%", POW="^",
  BAND="&", BOR="|", BXOR="~", SHL="<<", SHR=">>",
}

-- clamp a (possibly float) limit for an integer for-loop.
-- returns integer-ish limit and whether the loop should be skipped entirely.
local maxint = math.maxinteger
local minint = math.mininteger
local function clamp_for_limit(limit, step)
  if mtype(limit) == "integer" then return limit, false end
  -- float limit
  if step > 0 then
    if limit >= maxint + 0.0 then return maxint, false end
    if limit < minint + 0.0 then return minint, true end  -- below range: skip
    return floor(limit), false
  else
    if limit <= minint + 0.0 then return minint, false end
    if limit > maxint + 0.0 then return maxint, true end
    return math.ceil(limit), false
  end
end

-- coerce a numeric-for control value. Lua 5.5 coerces numeric strings, and a
-- string operand is taken as a float (so such loops iterate in float).
function Interp:forprep_num(v, what)
  if type(v) == "number" then return v end
  if type(v) == "string" then
    local n = tonumber(v)
    if n ~= nil then return n + 0.0 end
  end
  self:rt_error("bad 'for' " .. what .. " (number expected, got "
    .. rt.typename(v) .. ")")
end

function Interp:exec_loop(frame)
  ::restart::
  local R = frame.R
  local proto = frame.proto
  local code = proto.code
  local K = proto.consts
  local cl = frame.cl
  local pc = 1
  local lastline, lastpc = -1, 0

  while true do
    local ins = code[pc]
    frame.savedpc = pc
    -- debug hooks (count / line)
    local hk = self.hook
    if hk and not self.in_hook then
      if hk.count then
        self.hookcount = self.hookcount - 1
        if self.hookcount <= 0 then self.hookcount = hk.count; self:fire_hook("count") end
      end
      if hk.line then
        local line = proto.lines[pc]
        if line ~= lastline or pc <= lastpc then self:fire_hook("line", line) end
        lastline = line
      end
      lastpc = pc
    end
    pc = pc + 1
    local op = ins.op
    local a = ins.a

    if op == "MOVE" then
      R[a] = R[ins.b]
    elseif op == "LOADK" then
      R[a] = K[ins.b]
    elseif op == "LOADNIL" then
      for i = a, ins.b do R[i] = nil end
    elseif op == "LOADBOOL" then
      R[a] = (ins.b == 1)
    elseif op == "GETUPVAL" then
      R[a] = uv_get(cl.upvals[ins.b])
    elseif op == "SETUPVAL" then
      uv_set(cl.upvals[ins.b], R[a])
    elseif op == "GETTABUP" then
      local obj = uv_get(cl.upvals[ins.b])
      if not rt.is_table(obj) and self:metamethod(obj, "__index") == nil then
        local nm = proto.upvals[ins.b] and proto.upvals[ins.b].name
        self:rt_error("attempt to index a " .. rt.typename(obj) .. " value"
          .. (nm and (" (upvalue '" .. nm .. "')") or ""))
      end
      R[a] = self:index(obj, K[ins.c])
    elseif op == "SETTABUP" then
      local obj = uv_get(cl.upvals[a])
      if not rt.is_table(obj) and self:metamethod(obj, "__newindex") == nil then
        local nm = proto.upvals[a] and proto.upvals[a].name
        self:rt_error("attempt to index a " .. rt.typename(obj) .. " value"
          .. (nm and (" (upvalue '" .. nm .. "')") or ""))
      end
      self:setindex(obj, K[ins.b], R[ins.c])
    elseif op == "GETFIELD" then
      local obj = R[ins.b]
      if not rt.is_table(obj) and self:metamethod(obj, "__index") == nil then
        self:rt_error("attempt to index a " .. rt.typename(obj) .. " value"
          .. self:name_suffix(frame, ins.b))
      end
      R[a] = self:index(obj, K[ins.c])
    elseif op == "SETFIELD" then
      local obj = R[a]
      if not rt.is_table(obj) and self:metamethod(obj, "__newindex") == nil then
        self:rt_error("attempt to index a " .. rt.typename(obj) .. " value"
          .. self:name_suffix(frame, a))
      end
      self:setindex(obj, K[ins.b], R[ins.c])
    elseif op == "GETTABLE" then
      local obj = R[ins.b]
      if not rt.is_table(obj) and self:metamethod(obj, "__index") == nil then
        self:rt_error("attempt to index a " .. rt.typename(obj) .. " value"
          .. self:name_suffix(frame, ins.b))
      end
      R[a] = self:index(obj, R[ins.c])
    elseif op == "SETTABLE" then
      local obj = R[a]
      if not rt.is_table(obj) and self:metamethod(obj, "__newindex") == nil then
        self:rt_error("attempt to index a " .. rt.typename(obj) .. " value"
          .. self:name_suffix(frame, a))
      end
      self:setindex(obj, R[ins.b], R[ins.c])
    elseif op == "SELF" then
      local obj = R[ins.b]
      R[a + 1] = obj
      if not rt.is_table(obj) and self:metamethod(obj, "__index") == nil then
        self:rt_error("attempt to index a " .. rt.typename(obj) .. " value"
          .. self:name_suffix(frame, ins.b))
      end
      R[a] = self:index(obj, K[ins.c])
    elseif op == "NEWTABLE" then
      R[a] = rt.new_table()
    elseif op == "SETLIST" then
      local t = R[a]
      local count = ins.b
      if count == 0 then count = frame.top - a - 1 end
      rt.setlist(t, ins.c, R, a, count)
    elseif op == "ADD" or op == "SUB" or op == "MUL" or op == "DIV"
        or op == "IDIV" or op == "MOD" or op == "POW"
        or op == "BAND" or op == "BOR" or op == "BXOR"
        or op == "SHL" or op == "SHR" then
      self.errhint = { frame = frame, regs = { ins.b, ins.c } }
      R[a] = self:arith(OPSYM[op], R[ins.b], R[ins.c])
    elseif op == "UNM" then
      self.errhint = { frame = frame, regs = { ins.b } }
      R[a] = self:unm(R[ins.b])
    elseif op == "NOT" then
      R[a] = not truthy(R[ins.b])
    elseif op == "LEN" then
      self.errhint = { frame = frame, regs = { ins.b } }
      R[a] = self:len(R[ins.b])
    elseif op == "BNOT" then
      self.errhint = { frame = frame, regs = { ins.b } }
      R[a] = self:bnot(R[ins.b])
    elseif op == "CONCAT" then
      local b, c = ins.b, ins.c
      self.errhint = { frame = frame, regs = {} }
      for r = b, c do self.errhint.regs[#self.errhint.regs + 1] = r end
      local acc = R[c]
      for i = c - 1, b, -1 do
        acc = self:concat(R[i], acc)
      end
      R[a] = acc
    elseif op == "EQ" then
      R[a] = self:eq(R[ins.b], R[ins.c])
    elseif op == "LT" then
      R[a] = self:lt(R[ins.b], R[ins.c])
    elseif op == "LE" then
      R[a] = self:le(R[ins.b], R[ins.c])
    elseif op == "JMP" then
      pc = a
    elseif op == "JMPIF" then
      if truthy(R[a]) then pc = ins.b end
    elseif op == "JMPIFNOT" then
      if not truthy(R[a]) then pc = ins.b end
    elseif op == "CALL" then
      local fn = R[a]
      if not rt.is_callable(fn) and self:metamethod(fn, "__call") == nil then
        self:rt_error("attempt to call a " .. rt.typename(fn) .. " value"
          .. self:name_suffix(frame, a))
      end
      local b = ins.b
      local nargs = (b == 0) and (frame.top - a - 1) or (b - 1)
      local cargs = { n = nargs }
      for i = 1, nargs do cargs[i] = R[a + i] end
      local res = self:call(fn, cargs)
      local nres = res.n
      local c = ins.c
      if c == 0 then
        for i = 1, nres do R[a + i - 1] = res[i] end
        frame.top = a + nres
      else
        local want = c - 1
        for i = 1, want do R[a + i - 1] = res[i] end
      end
    elseif op == "TAILCALL" then
      local fn = R[a]
      if not rt.is_callable(fn) and self:metamethod(fn, "__call") == nil then
        self:rt_error("attempt to call a " .. rt.typename(fn) .. " value"
          .. self:name_suffix(frame, a))
      end
      local b = ins.b
      local nargs = (b == 0) and (frame.top - a - 1) or (b - 1)
      local cargs = { n = nargs }
      for i = 1, nargs do cargs[i] = R[a + i] end
      local _ce = self:close_upvals(frame, 0)
      if _ce ~= nil then error(_ce, 0) end
      if rt.is_closure(fn) then
        -- reuse this frame: true tail call (no stack growth)
        local p = fn.proto
        local NR = {}
        local np = p.numparams
        for i = 1, np do NR[i - 1] = cargs[i] end
        local va
        if p.is_vararg and nargs > np then
          va = { n = nargs - np }
          for i = np + 1, nargs do va[i - np] = cargs[i] end
        else
          va = { n = 0 }
        end
        frame.cl = fn; frame.proto = p; frame.R = NR
        frame.varargs = va; frame.openuv = {}; frame.tbc = {}
        frame.top = np; frame.savedpc = 1; frame.loopstate = nil
        goto restart
      else
        -- native or __call: just call and return its results
        return self:call(fn, cargs)
      end
    elseif op == "RETURN" then
      local b = ins.b
      local nret = (b == 0) and (frame.top - a) or (b - 1)
      local res = { n = nret }
      for i = 1, nret do res[i] = R[a + i - 1] end
      local _ce = self:close_upvals(frame, 0)
      if _ce ~= nil then error(_ce, 0) end
      return res
    elseif op == "VARARG" then
      local va = frame.varargs
      local b = ins.b
      if b == 0 then
        local n = va.n
        for i = 1, n do R[a + i - 1] = va[i] end
        frame.top = a + n
      else
        local want = b - 1
        for i = 1, want do R[a + i - 1] = va[i] end
      end
    elseif op == "UNPACKVARARG" then
      -- `...` for a named vararg: table.unpack(t, 1, t.n), read dynamically
      local t = R[ins.b]
      local n = rt.rawget(t, "n")
      -- t.n must be a non-negative integer no larger than INT_MAX/2 (matching
      -- getnumargs: l_castS2U(n) <= INT_MAX/2)
      if mtype(n) ~= "integer" or n < 0 or n > 0x3FFFFFFF then
        self:rt_error("vararg table has no proper 'n'")
      end
      local b = ins.c
      if b == 0 then
        for i = 1, n do R[a + i - 1] = rt.rawget(t, i) end
        frame.top = a + n
      else
        local want = b - 1
        for i = 1, want do R[a + i - 1] = (i <= n) and rt.rawget(t, i) or nil end
      end
    elseif op == "VARARGPACK" then
      -- materialize varargs as a table {n = count, [1..] = ...}
      local va = frame.varargs
      local t = rt.new_table(va.n)
      for i = 1, va.n do rt.rawset(t, i, va[i]) end
      rt.rawset(t, "n", va.n)
      R[a] = t
    elseif op == "CLOSURE" then
      local p = proto.protos[ins.b]
      local upvals = {}
      for i, ud in ipairs(p.upvals) do
        if ud.in_stack then
          upvals[i] = self:find_upval(frame, ud.index)
        else
          upvals[i] = cl.upvals[ud.index]
        end
      end
      R[a] = rt.new_closure(p, upvals)
    elseif op == "FORPREP" then
      -- Lua validates operands in the order: limit, step, initial value
      local limit = self:forprep_num(R[a + 1], "limit")
      local step = self:forprep_num(R[a + 2], "step")
      local init = self:forprep_num(R[a], "initial value")
      R[a], R[a + 1], R[a + 2] = init, limit, step
      if step == 0 then self:rt_error("'for' step is zero") end
      frame.loopstate = frame.loopstate or {}
      if mtype(init) == "integer" and mtype(step) == "integer" then
        local ilimit, skip = clamp_for_limit(limit, step)
        local run
        if step > 0 then run = (init <= ilimit) else run = (init >= ilimit) end
        if skip or not run then
          pc = ins.b
        else
          -- iteration count via UNSIGNED arithmetic (handles the full integer
          -- range without overflow), exactly like Lua's forprep
          local count
          if step > 0 then
            count = udiv(ilimit - init, step)
          else
            count = udiv(init - ilimit, (-(step + 1)) + 1)
          end
          frame.loopstate[a] = { int = true, count = count, step = step }
          R[a] = init
          R[a + 3] = init
        end
      else
        local fi, fl, fst = init + 0.0, limit + 0.0, step + 0.0
        R[a], R[a + 1], R[a + 2] = fi, fl, fst
        local run
        if fst > 0 then run = (fi <= fl) else run = (fi >= fl) end
        if not run then
          pc = ins.b
        else
          frame.loopstate[a] = { int = false }
          R[a + 3] = fi
        end
      end
    elseif op == "FORLOOP" then
      local st = frame.loopstate[a]
      if st.int then
        if st.count > 0 then
          st.count = st.count - 1
          local v = R[a] + st.step
          R[a] = v
          R[a + 3] = v
          pc = ins.b
        end
      else
        local step = R[a + 2]
        local v = R[a] + step
        local limit = R[a + 1]
        local cont
        if step > 0 then cont = (v <= limit) else cont = (v >= limit) end
        if cont then
          R[a] = v
          R[a + 3] = v
          pc = ins.b
        end
      end
    elseif op == "TFORCALL" then
      local fn = R[a]
      local cargs = { n = 2, R[a + 1], R[a + 2] }
      local res = self:call(fn, cargs)
      local nvars = ins.c
      for i = 1, nvars do R[a + 4 + i - 1] = res[i] end   -- vars at a+4 (a+3 = closing)
    elseif op == "TFORLOOP" then
      if R[a + 4] ~= nil then
        R[a + 2] = R[a + 4]
        pc = ins.b
      end
    elseif op == "CLOSE" then
      local _ce = self:close_upvals(frame, a)
      if _ce ~= nil then error(_ce, 0) end
    elseif op == "TBC" then
      local v = R[a]
      if v ~= nil and v ~= false and self:metamethod(v, "__close") == nil then
        local nm = local_name(proto, a, frame.savedpc) or "?"
        self:rt_error("variable '" .. nm .. "' got a non-closable value")
      end
      frame.tbc[#frame.tbc + 1] = a
    else
      error("vm: unknown opcode " .. tostring(op))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Loading / running source
-- ---------------------------------------------------------------------------

local lexer = require("lexer")
local parser = require("parser")
local compiler = require("compiler")

-- compile source -> main closure (with _ENV upvalue bound to env or globals)
-- has_env distinguishes an explicitly-passed env (even nil) from no env (which
-- defaults to the global table). Lua's load(s, n, mode, env) with env=nil makes
-- _ENV nil; load(s) defaults _ENV to _G.
function Interp:load(source, chunkname, env, has_env)
  chunkname = chunkname or "?"
  local short = rt.shortsrc(chunkname)
  local tokens = lexer.tokenize(source, short)
  local ast = parser.parse(tokens, short)
  local proto = compiler.compile_main(ast, short, chunkname)
  local envval
  if has_env then envval = env else envval = self.globals end
  local env_uv = { closed = true, val = envval }
  return rt.new_closure(proto, { env_uv })
end

-- wrap a (deserialized) proto as a closure: first upvalue = env, the rest nil
-- (matching how Lua loads a dumped function — upvalue values are not preserved)
function Interp:closure_from_proto(proto, env, has_env)
  local envval
  if has_env then envval = env else envval = self.globals end
  local n = #proto.upvals
  local upvals = {}
  for i = 1, n do upvals[i] = { closed = true, val = (i == 1) and envval or nil } end
  if n == 0 then upvals[1] = { closed = true, val = envval } end
  return rt.new_closure(proto, upvals)
end

-- protected call. With a message `handler`, it runs (like xpcall) BEFORE the
-- stack unwinds, so debug.traceback can see the erroring frames. Returns
-- ok, results|errvalue.
function Interp:protected(fn, args, handler)
  local saved_n = #self.frames
  local saved_depth = self.depth
  local ok, res = pcall(function() return self:call(fn, args) end)
  if ok then
    return true, res
  end
  local function errval(e)
    if type(e) == "table" and getmetatable(e) == self.GUEST_ERR_MT then return e.value end
    return "[internal] " .. tostring(e)
  end
  -- run the message handler with the stack still intact (self.frames was not
  -- popped on the error path), so a traceback handler can inspect it
  local hresult
  if handler then
    local hok, hr = pcall(self.call, self, handler, { errval(res), n = 1 })
    if hok then hresult = hr[1] else hresult = errval(hr) end
  end
  -- now unwind, running pending to-be-closed handlers (inner frames first); pop
  -- each frame BEFORE running its handler so nested calls stay contiguous.
  while #self.frames > saved_n do
    local top = #self.frames
    local f = self.frames[top]
    self.frames[top] = nil
    if f and f.tbc and #f.tbc > 0 then
      local cok, cerr = pcall(self.close_upvals, self, f, 0, res)
      res = cerr
    end
  end
  self.depth = saved_depth
  if handler then return false, hresult end
  return false, errval(res)
end

return { Interp = Interp, rt = rt }
