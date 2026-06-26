-- lua55vm/compiler.lua
-- Lowers the AST into register-based guest bytecode.
--
-- Proto shape:
--   { code={instr}, lines={int}, consts={value}, protos={Proto},
--     upvals={ {name, in_stack, index} }, numparams, is_vararg,
--     maxstack, source, name }
--
-- Instruction = { op=<string>, a, b, c }  (operands are register / const / pc
-- indices depending on op; see vm.lua for the precise contract).
--
-- Registers are 0-based. Constants are 1-based. Jump targets are absolute pc.

local mtype = math.type

local Compiler = {}

-- is this expression possibly multi-valued (call / "...")?
local function is_multi(node)
  local t = node.tag
  return t == "Call" or t == "MethodCall" or t == "Vararg"
end

-- ---------------------------------------------------------------------------
-- FuncState
-- ---------------------------------------------------------------------------

local FS = {}
FS.__index = FS

local function new_funcstate(parent, source, chunkname)
  return setmetatable({
    parent = parent,
    -- Lua 5.5 global declarations are shared across the whole chunk
    gdecl = parent and parent.gdecl
      or { allowall = true, allconst = false, declared = {}, const = {} },
    proto = {
      code = {}, lines = {}, consts = {}, protos = {},
      upvals = {}, locvars = {}, numparams = 0, is_vararg = false,
      maxstack = 2, source = source, chunkname = chunkname, name = nil,
    },
    constmap = {},
    actvars = {},      -- { {name, reg, attrib, captured} }  (in-scope stack)
    ntbc = 0,          -- count of active to-be-closed vars (disables tail calls)
    freereg = 0,
    blocks = {},       -- scope stack
    upvalmap = {},     -- name -> upval index (1-based)
  }, FS)
end

function FS:emit(op, a, b, c, line)
  local code = self.proto.code
  code[#code + 1] = { op = op, a = a, b = b, c = c }
  self.proto.lines[#code] = line or self.curline or 0
  return #code
end

function FS:pc() return #self.proto.code end

-- index of the *next* instruction to be emitted (i.e. a forward jump target)
function FS:here() return #self.proto.code + 1 end

-- emit a vararg expansion: for a named vararg (...t) `...` aliases the table
-- (table.unpack(t, 1, t.n)); otherwise it reads the raw vararg area.
function FS:emit_vararg(reg, b, line)
  if self.vararg_reg then
    self:emit("UNPACKVARARG", reg, self.vararg_reg, b, line)
  else
    self:emit("VARARG", reg, b, line)
  end
end

function FS:setarg(pc, field, val) self.proto.code[pc][field] = val end

function FS:K(value)
  local key
  if type(value) == "number" then
    key = (mtype(value) == "integer" and "i:" or "f:") .. tostring(value)
  elseif type(value) == "string" then
    key = "s:" .. value
  else
    key = "o:" .. tostring(value)
  end
  local idx = self.constmap[key]
  if idx then return idx end
  local consts = self.proto.consts
  consts[#consts + 1] = value
  idx = #consts
  self.constmap[key] = idx
  return idx
end

-- the register file is limited to 255 slots, like reference Lua
function FS:reglimit()
  if self.proto.maxstack > 255 then
    local where = self.is_main and "main function"
      or string.format("function <%s:%d>", self.proto.source, self.proto.line or 0)
    error(string.format("%s:%d: too many registers (limit is 255) in %s near %s",
      self.proto.source, self.cur_near_line or self.curline or 0, where,
      self.cur_near or "'?'"), 0)
  end
end

function FS:reserve(n)
  self.freereg = self.freereg + n
  if self.freereg > self.proto.maxstack then
    self.proto.maxstack = self.freereg
    self:reglimit()
  end
end

function FS:checkstack(reg)
  if reg + 1 > self.proto.maxstack then
    self.proto.maxstack = reg + 1
    self:reglimit()
  end
end

-- ---------------------------------------------------------------------------
-- Scopes, locals, upvalues
-- ---------------------------------------------------------------------------

function FS:enter_block(is_loop)
  local b = {
    firstlocal = #self.actvars + 1,
    firstreg = self.freereg,
    startpc = self:here(),
    is_loop = is_loop,
    has_capture = false,
    saved_ntbc = self.ntbc,
    breaks = {},
  }
  self.blocks[#self.blocks + 1] = b
  return b
end

function FS:leave_block()
  local b = table.remove(self.blocks)
  -- emit CLOSE for captured / to-be-closed locals in this block
  if b.has_capture then
    self:emit("CLOSE", b.firstreg)
  end
  -- Resolve gotos against labels in THIS block (labels go out of scope now).
  -- Unmatched gotos escape to the enclosing block with a reduced active-var
  -- level (movegotosout); the scope check happens here, at resolution.
  if self.pending_gotos then
    local outer = b.firstlocal - 1
    for _, g in ipairs(self.pending_gotos) do
      if not g.done and (g.emitpc or 0) >= b.startpc then
        local target
        for _, l in ipairs(self.labels) do
          if l.name == g.name and l.block == b then target = l; break end
        end
        if target then
          if target.pc > (g.emitpc or g.pc) and not target.void
             and target.nactvar > g.nactvar then
            local culprit = target.varnames[g.nactvar + 1] or "?"
            error(string.format(
              "%s:%d: <goto %s> at line %d jumps into the scope of '%s'",
              self.proto.source, g.line or 0, g.name, g.line or 0, culprit), 0)
          end
          -- close captured / to-be-closed locals that go out of scope on the jump
          if g.closepc and target.nactvar < #g.regs then
            self:setarg(g.closepc, "a", g.regs[target.nactvar + 1])
          end
          self:setarg(g.pc, "a", target.pc)
          g.done = true
        elseif g.nactvar > outer then
          g.nactvar = outer
        end
      end
    end
  end
  -- pop locals declared in this block, closing their debug ranges
  local endpc = self:here()
  while #self.actvars >= b.firstlocal do
    local av = table.remove(self.actvars)
    if av.locvar then av.locvar.endpc = endpc end
  end
  self.freereg = b.firstreg
  self.ntbc = b.saved_ntbc
  return b
end

-- register a new active local at the current freereg base `reg`
function FS:new_local(name, reg, attrib, near, near_line)
  if #self.actvars >= 200 then
    local where = self.is_main and "main function"
      or string.format("function <%s:%d>", self.proto.source, self.proto.line or 0)
    error(string.format("%s:%d: too many local variables (limit is 200) in %s near %s",
      self.proto.source, near_line or self.curline or 0, where, near or "'?'"), 0)
  end
  local lv = { name = name, reg = reg, startpc = self:here(), endpc = nil }
  local locvars = self.proto.locvars
  if not locvars then locvars = {}; self.proto.locvars = locvars end
  locvars[#locvars + 1] = lv
  self.actvars[#self.actvars + 1] =
    { name = name, reg = reg, attrib = attrib, captured = false, locvar = lv }
  return #self.actvars
end

-- find innermost loop block (for break)
function FS:loop_block()
  for i = #self.blocks, 1, -1 do
    if self.blocks[i].is_loop then return self.blocks[i] end
  end
  return nil
end

-- mark all blocks down to (and including) the one containing `reg` as having
-- a capture, so CLOSE is emitted on scope exit.
function FS:mark_capture_at(reg)
  for i = #self.blocks, 1, -1 do
    local b = self.blocks[i]
    b.has_capture = true
    if b.firstreg <= reg then break end
  end
end

-- add an upvalue descriptor; returns its 1-based index
function FS:add_upval(name, in_stack, index)
  local existing = self.upvalmap[name]
  if existing then return existing end
  local ups = self.proto.upvals
  ups[#ups + 1] = { name = name, in_stack = in_stack, index = index }
  self.upvalmap[name] = #ups
  return #ups
end

-- under strict global declarations, an undeclared global access is an error
function FS:check_global_read(name, line)
  local g = self.gdecl
  if not g.allowall and not g.declared[name] then
    error(string.format("%s:%d: variable '%s' not declared",
      self.proto.source, line or 0, name), 0)
  end
end

function FS:check_global_write(name, line)
  if self.gdecl.const[name] then
    error(string.format("%s:%d: attempt to assign to const variable '%s'",
      self.proto.source, line or 0, name), 0)
  end
end

-- a `global` declaration is block-scoped for goto purposes (you cannot jump
-- into its scope), like a local -- but it holds no register and is invisible to
-- name resolution. Record a scope marker (name "*" for `global *`).
function FS:add_gdecl_scope(name)
  self.actvars[#self.actvars + 1] =
    { name = name, reg = self.freereg, is_gdecl = true, captured = false }
end

-- resolve a name: returns "local",reg | "upval",idx | "global"
function FS:resolve(name)
  for i = #self.actvars, 1, -1 do
    local av = self.actvars[i]
    if not av.is_gdecl and av.name == name then
      return "local", av.reg, av
    end
  end
  if self.upvalmap[name] then
    return "upval", self.upvalmap[name]
  end
  if self.parent then
    local kind, where, av = self.parent:resolve(name)
    if kind == "local" then
      av.captured = true
      self.parent:mark_capture_at(where)
      return "upval", self:add_upval(name, true, where)
    elseif kind == "upval" then
      return "upval", self:add_upval(name, false, where)
    end
  end
  return "global"
end

-- ---------------------------------------------------------------------------
-- Expression compilation
-- ---------------------------------------------------------------------------

local exp2reg, exp2nextreg, exp2anyreg, compile_call, compile_table
local adjust_explist, compile_block, compile_stmt

-- get a value into `reg`
function exp2reg(fs, node, reg)
  fs:checkstack(reg)
  fs.curline = node.line or fs.curline
  local tag = node.tag

  if tag == "Nil" then
    fs:emit("LOADNIL", reg, reg, nil, node.line)
  elseif tag == "True" then
    fs:emit("LOADBOOL", reg, 1, nil, node.line)
  elseif tag == "False" then
    fs:emit("LOADBOOL", reg, 0, nil, node.line)
  elseif tag == "Number" or tag == "String" then
    fs:emit("LOADK", reg, fs:K(node.value), nil, node.line)
  elseif tag == "Vararg" then
    fs:emit_vararg(reg, 2, node.line)   -- want 1 value
  elseif tag == "Name" then
    local kind, where = fs:resolve(node.name)
    if kind == "local" then
      if where ~= reg then fs:emit("MOVE", reg, where, nil, node.line) end
    elseif kind == "upval" then
      fs:emit("GETUPVAL", reg, where, nil, node.line)
    else
      -- global: _ENV[name]
      fs:check_global_read(node.name, node.line)
      local ek, ew = fs:resolve("_ENV")
      if ek == "local" then
        fs:emit("GETFIELD", reg, ew, fs:K(node.name), node.line)
      else
        fs:emit("GETTABUP", reg, ew, fs:K(node.name), node.line)
      end
    end
  elseif tag == "Index" then
    local rb = exp2anyreg(fs, node.obj)
    if node.key.tag == "String" then
      fs:emit("GETFIELD", reg, rb, fs:K(node.key.value), node.line)
    else
      local rc = exp2anyreg(fs, node.key)
      fs:emit("GETTABLE", reg, rb, rc, node.line)
    end
    fs.freereg = math.max(fs.freereg, reg + 1)
  elseif tag == "Paren" then
    exp2reg(fs, node.expr, reg)
  elseif tag == "Call" or tag == "MethodCall" then
    compile_call(fs, node, reg, 1)
    fs.freereg = reg + 1
  elseif tag == "Function" then
    local pidx = Compiler.compile_function(fs, node)
    -- Lua attributes the CLOSURE to the function's closing 'end' line
    fs:emit("CLOSURE", reg, pidx, nil, node.endline or node.line)
  elseif tag == "Table" then
    compile_table(fs, node, reg)
  elseif tag == "BinOp" then
    Compiler.compile_binop(fs, node, reg)
  elseif tag == "UnOp" then
    Compiler.compile_unop(fs, node, reg)
  else
    error("compiler: cannot compile expr tag " .. tostring(tag))
  end
end

-- evaluate into a freshly reserved register, return it
function exp2nextreg(fs, node)
  local reg = fs.freereg
  fs:reserve(1)
  exp2reg(fs, node, reg)
  return reg
end

-- if node is a plain local var, return its register; else exp2nextreg
function exp2anyreg(fs, node)
  if node.tag == "Name" then
    local kind, where = fs:resolve(node.name)
    if kind == "local" then return where end
  end
  return exp2nextreg(fs, node)
end

-- ---------------------------------------------------------------------------
-- Binary / unary operators
-- ---------------------------------------------------------------------------

local ARITH_OP = {
  ["+"]="ADD", ["-"]="SUB", ["*"]="MUL", ["/"]="DIV", ["//"]="IDIV",
  ["%"]="MOD", ["^"]="POW", ["&"]="BAND", ["|"]="BOR", ["~"]="BXOR",
  ["<<"]="SHL", [">>"]="SHR",
}

function Compiler.compile_binop(fs, node, reg)
  local op = node.op
  if op == "and" or op == "or" then
    exp2reg(fs, node.lhs, reg)
    local jop = (op == "and") and "JMPIFNOT" or "JMPIF"
    local jpc = fs:emit(jop, reg, 0, nil, node.line)  -- patched
    -- on fall-through, evaluate rhs into reg
    local save = fs.freereg
    fs.freereg = reg + 1
    exp2reg(fs, node.rhs, reg)
    fs.freereg = save
    fs:setarg(jpc, "b", fs:here())   -- jump target = after rhs
    return
  end

  if op == ".." then
    -- gather a flat run of operands for the concat chain into consecutive regs
    local base = reg
    local parts = {}
    local function flatten(n)
      if n.tag == "BinOp" and n.op == ".." then
        flatten(n.lhs); flatten(n.rhs)
      else
        parts[#parts + 1] = n
      end
    end
    flatten(node)
    local savefree = fs.freereg
    fs.freereg = base
    for i = 1, #parts do
      exp2reg(fs, parts[i], base + i - 1)
      fs.freereg = base + i
    end
    fs:emit("CONCAT", reg, base, base + #parts - 1, node.line)
    fs.freereg = savefree
    return
  end

  local savefree = fs.freereg
  if reg + 1 > fs.freereg then fs.freereg = reg + 1 end
  local rb = exp2anyreg(fs, node.lhs)
  local rc = exp2anyreg(fs, node.rhs)
  fs.freereg = savefree

  local aop = ARITH_OP[op]
  if aop then
    fs:emit(aop, reg, rb, rc, node.line)
    return
  end
  -- comparisons
  if op == "==" then
    fs:emit("EQ", reg, rb, rc, node.line)
  elseif op == "~=" then
    fs:emit("EQ", reg, rb, rc, node.line)
    fs:emit("NOT", reg, reg, nil, node.line)
  elseif op == "<" then
    fs:emit("LT", reg, rb, rc, node.line)
  elseif op == ">" then
    fs:emit("LT", reg, rc, rb, node.line)
  elseif op == "<=" then
    fs:emit("LE", reg, rb, rc, node.line)
  elseif op == ">=" then
    fs:emit("LE", reg, rc, rb, node.line)
  else
    error("compiler: unknown binop " .. tostring(op))
  end
end

function Compiler.compile_unop(fs, node, reg)
  local op = node.op
  local savefree = fs.freereg
  if reg + 1 > fs.freereg then fs.freereg = reg + 1 end
  local rb = exp2anyreg(fs, node.operand)
  fs.freereg = savefree
  if op == "-" then fs:emit("UNM", reg, rb, nil, node.line)
  elseif op == "not" then fs:emit("NOT", reg, rb, nil, node.line)
  elseif op == "#" then fs:emit("LEN", reg, rb, nil, node.line)
  elseif op == "~" then fs:emit("BNOT", reg, rb, nil, node.line)
  else error("compiler: unknown unop " .. tostring(op)) end
end

-- ---------------------------------------------------------------------------
-- Calls
-- ---------------------------------------------------------------------------

-- compile expression list into consecutive regs starting at `base`.
-- returns true if the list ends "open" (last expr is multi -> uses top).
local function explist_open(fs, exprs, base)
  local n = #exprs
  if n == 0 then fs.freereg = base; return false end
  fs.freereg = base
  for i = 1, n - 1 do
    exp2reg(fs, exprs[i], base + i - 1)
    fs.freereg = base + i
  end
  local last = exprs[n]
  local lastreg = base + n - 1
  if is_multi(last) then
    fs:checkstack(lastreg)
    if last.tag == "Vararg" then
      fs:emit_vararg(lastreg, 0, last.line)   -- all
    else
      compile_call(fs, last, lastreg, -1)             -- all results
    end
    return true
  else
    exp2reg(fs, last, lastreg)
    fs.freereg = base + n
    return false
  end
end

-- compile a Call/MethodCall placing nresults results at `reg`.
-- nresults: -1 = all (multi); >=0 = exactly that many.
-- tail: emit a TAILCALL instead of CALL (for `return f(...)`).
function compile_call(fs, node, reg, nresults, tail)
  fs.curline = node.line or fs.curline
  fs:checkstack(reg)
  local argbase
  if node.tag == "MethodCall" then
    local robj = exp2anyreg(fs, node.obj)
    fs:emit("SELF", reg, robj, fs:K(node.method), node.line)
    fs.freereg = reg + 2
    argbase = reg + 2
  else
    fs.freereg = reg
    exp2reg(fs, node.func, reg)
    fs.freereg = reg + 1
    argbase = reg + 1
  end

  local args = node.args
  local self_extra = (node.tag == "MethodCall") and 1 or 0
  local open
  if #args == 0 then
    open = false
    fs.freereg = argbase
  else
    open = explist_open(fs, args, argbase)
  end

  local b
  if open then
    b = 0
  else
    b = (#args + self_extra) + 1
  end
  if tail then
    fs:emit("TAILCALL", reg, b, nil, node.line)
    return
  end
  local c = (nresults < 0) and 0 or (nresults + 1)
  fs:emit("CALL", reg, b, c, node.line)
  if nresults >= 0 then
    fs.freereg = reg + nresults
  end
end

-- ---------------------------------------------------------------------------
-- Table constructor
-- ---------------------------------------------------------------------------

function compile_table(fs, node, reg)
  fs:checkstack(reg)
  fs:emit("NEWTABLE", reg, nil, nil, node.line)
  if reg + 1 > fs.freereg then fs.freereg = reg + 1 end

  local fields = node.fields
  local pending = {}     -- array items waiting to be flushed via SETLIST
  local arr_index = 0    -- count of array items emitted so far
  local listbase = reg + 1

  local function flush(open)
    if #pending == 0 and not open then return end
    -- pending values are already in regs listbase..; emit SETLIST
    local count = #pending
    fs:emit("SETLIST", reg, open and 0 or count, arr_index, node.line)
    arr_index = arr_index + count
    pending = {}
    fs.freereg = listbase
  end

  for i, f in ipairs(fields) do
    if f.kind == "rec" then
      -- flush array part first to keep registers tidy
      flush(false)
      local savefree = fs.freereg
      local rk
      if f.key.tag == "String" then
        rk = nil
      end
      if f.key.tag == "String" then
        local rv = exp2anyreg(fs, f.value)
        fs:emit("SETFIELD", reg, fs:K(f.key.value), rv, node.line)
      else
        local kreg = exp2anyreg(fs, f.key)
        local vreg = exp2anyreg(fs, f.value)
        fs:emit("SETTABLE", reg, kreg, vreg, node.line)
      end
      fs.freereg = savefree
    else
      -- array item
      local is_last = (i == #fields)
      if is_last and is_multi(f.value) then
        -- flush prior fixed items, then open-ended last
        local valreg = listbase + #pending
        fs:checkstack(valreg)
        fs.freereg = valreg
        if f.value.tag == "Vararg" then
          fs:emit_vararg(valreg, 0, f.value.line)
        else
          compile_call(fs, f.value, valreg, -1)
        end
        pending[#pending + 1] = true
        flush(true)
      else
        local valreg = listbase + #pending
        fs:checkstack(valreg)
        fs.freereg = valreg
        exp2reg(fs, f.value, valreg)
        fs.freereg = valreg + 1
        pending[#pending + 1] = true
        if #pending >= 50 then flush(false) end
      end
    end
  end
  flush(false)
  fs.freereg = reg + 1
end

-- ---------------------------------------------------------------------------
-- Statements
-- ---------------------------------------------------------------------------

-- assign a computed value (in register vreg) to an lvalue node
local function store_to(fs, target, vreg)
  if target.tag == "Name" then
    local kind, where = fs:resolve(target.name)
    if kind == "local" then
      if target._av and target._av.attrib == "const" or
         (target._av and target._av.attrib == "close") then
        error(string.format("%s:%d: attempt to assign to const variable '%s'",
          fs.proto.source, target.line or 0, target.name), 0)
      end
      if where ~= vreg then fs:emit("MOVE", where, vreg, nil, target.line) end
    elseif kind == "upval" then
      fs:emit("SETUPVAL", vreg, where, nil, target.line)
    else
      fs:check_global_write(target.name, target.line)
      local ek, ew = fs:resolve("_ENV")
      if ek == "local" then
        fs:emit("SETFIELD", ew, fs:K(target.name), vreg, target.line)
      else
        fs:emit("SETTABUP", ew, fs:K(target.name), vreg, target.line)
      end
    end
  else -- Index
    local rb = target._objreg
    if target.key.tag == "String" then
      fs:emit("SETFIELD", rb, fs:K(target.key.value), vreg, target.line)
    else
      fs:emit("SETTABLE", rb, target._keyreg, vreg, target.line)
    end
  end
end

-- check assignment to const before generating code (local or captured upvalue)
local function check_const(fs, target)
  if target.tag ~= "Name" then return end
  local f = fs
  while f do
    for i = #f.actvars, 1, -1 do
      local av = f.actvars[i]
      if not av.is_gdecl and av.name == target.name then
        local at = av.attrib
        if at == "const" or at == "close" then
          error(string.format("%s:%d: attempt to assign to const variable '%s'",
            fs.proto.source, target.line or 0, target.name), 0)
        end
        return   -- found a (non-const) binding; shadows anything outer
      end
    end
    f = f.parent
  end
end

local function compile_assign(fs, node)
  local targets = node.targets
  local savefree = fs.freereg

  -- pre-evaluate index target prefixes (obj, key) into stable registers
  for _, t in ipairs(targets) do
    check_const(fs, t)
    if t.tag == "Index" then
      t._objreg = exp2anyreg(fs, t.obj)
      if t.key.tag ~= "String" then
        t._keyreg = exp2anyreg(fs, t.key)
      end
    elseif t.tag == "Name" then
      -- resolve the target variable now (the LHS is parsed before the RHS in
      -- Lua), so its upvalue / _ENV index is assigned before the RHS's --
      -- making debug.getupvalue/setupvalue and dump order match PUC
      local kind = fs:resolve(t.name)
      if kind ~= "local" and kind ~= "upval" then fs:resolve("_ENV") end
    end
  end

  local n = #targets
  local base = fs.freereg
  adjust_explist(fs, node.exprs, base, n)

  -- Lua assigns multiple targets right-to-left (leftmost target wins on overlap)
  for i = n, 1, -1 do
    store_to(fs, targets[i], base + i - 1)
  end
  fs.freereg = savefree
end

-- compile exprs into base..base+nvars-1, padding/truncating to nvars
function adjust_explist(fs, exprs, base, nvars)
  fs:checkstack(base + math.max(nvars, 1) - 1)
  if nvars > 0 then fs.freereg = math.max(fs.freereg, base + nvars) end
  local nexps = #exprs
  if nexps == 0 then
    if nvars > 0 then
      fs:emit("LOADNIL", base, base + nvars - 1)
    end
    fs.freereg = base + nvars
    return
  end

  fs.freereg = base
  for i = 1, nexps - 1 do
    exp2reg(fs, exprs[i], base + i - 1)
    fs.freereg = base + i
  end

  local last = exprs[nexps]
  local lastreg = base + nexps - 1
  if is_multi(last) then
    local want = nvars - (nexps - 1)
    if want < 0 then want = 0 end
    fs:checkstack(lastreg + math.max(want, 1) - 1)
    if last.tag == "Vararg" then
      fs:emit_vararg(lastreg, want + 1, last.line)
    else
      compile_call(fs, last, lastreg, want)
    end
    -- pad already covered by want; if nexps-1 >= nvars, extras evaluated above
    fs.freereg = base + math.max(nvars, nexps)
  else
    exp2reg(fs, last, lastreg)
    if nexps < nvars then
      fs:emit("LOADNIL", base + nexps, base + nvars - 1)
    end
    fs.freereg = base + math.max(nvars, nexps)
  end
end

local function compile_local(fs, node)
  fs.cur_near = node._near
  fs.cur_near_line = node._near_line
  -- at most one to-be-closed variable per local declaration
  local nclose = 0
  for i = 1, #node.names do
    if node.attribs[i] == "close" then nclose = nclose + 1 end
  end
  if nclose > 1 then
    error(string.format("%s:%d: multiple to-be-closed variables in local list",
      fs.proto.source, node.line or 0), 0)
  end
  local base = fs.freereg
  local nvars = #node.names
  adjust_explist(fs, node.exprs, base, nvars)
  -- activate locals now (after initializers evaluated)
  for i = 1, nvars do
    fs:new_local(node.names[i], base + i - 1, node.attribs[i], node._near, node._near_line)
    if node.attribs[i] == "close" then
      fs:emit("TBC", base + i - 1)
      fs:mark_capture_at(base + i - 1)
      fs.ntbc = fs.ntbc + 1
    end
  end
  fs.freereg = base + nvars
end

local function compile_localfunction(fs, node)
  local reg = fs.freereg
  fs:reserve(1)
  fs:new_local(node.name, reg, nil)   -- in scope for recursion
  local pidx = Compiler.compile_function(fs, node.func)
  fs:emit("CLOSURE", reg, pidx, nil, node.func.endline or node.line)
  fs.freereg = reg + 1
end

local function compile_return(fs, node)
  local exprs = node.exprs
  local base = fs.freereg
  if #exprs == 0 then
    fs:emit("RETURN", base, 1, nil, node.line)   -- 0 values
    return
  end
  -- `return f(args)` is a tail call — but NOT while to-be-closed variables are
  -- active (the close must run after the call returns)
  if #exprs == 1 and fs.ntbc == 0
     and (exprs[1].tag == "Call" or exprs[1].tag == "MethodCall") then
    compile_call(fs, exprs[1], base, -1, true)
    fs:emit("RETURN", base, 0, nil, node.line)   -- fallback for native tail call
    fs.freereg = base
    return
  end
  local open = explist_open(fs, exprs, base)
  local b = open and 0 or (#exprs + 1)
  fs:emit("RETURN", base, b, nil, node.line)
  fs.freereg = base
end

local function compile_if(fs, node)
  local endjumps = {}
  for ci, clause in ipairs(node.clauses) do
    local savefree = fs.freereg
    local creg = exp2nextreg(fs, clause.cond)
    fs.freereg = savefree
    local jfalse = fs:emit("JMPIFNOT", creg, 0, nil, clause.cond.line)
    compile_block(fs, clause.body)
    -- jump to end (unless this is the last clause and no else)
    local need_jump = (ci < #node.clauses) or (node.els ~= nil)
    if need_jump then
      endjumps[#endjumps + 1] = fs:emit("JMP", 0)
    end
    fs:setarg(jfalse, "b", fs:here())
  end
  if node.els then
    compile_block(fs, node.els)
  end
  for _, pc in ipairs(endjumps) do
    fs:setarg(pc, "a", fs:here())
  end
end

local function compile_while(fs, node)
  local top = fs:here()
  local savefree = fs.freereg
  local creg = exp2nextreg(fs, node.cond)
  fs.freereg = savefree
  local jout = fs:emit("JMPIFNOT", creg, 0, nil, node.cond.line)
  local b = fs:enter_block(true)
  compile_block(fs, node.body)
  fs:leave_block()
  fs:emit("JMP", top)
  fs:setarg(jout, "b", fs:here())
  for _, pc in ipairs(b.breaks) do fs:setarg(pc, "a", fs:here()) end
end

local function compile_repeat(fs, node)
  local top = fs:here()
  local b = fs:enter_block(true)
  -- repeat body and until-cond share scope; inline block without leaving yet
  local inner = fs:enter_block(false)
  for _, s in ipairs(node.body.stmts) do compile_stmt(fs, s) end
  local savefree = fs.freereg
  local creg = exp2nextreg(fs, node.cond)
  fs.freereg = savefree
  -- if cond is false, loop back to top
  if inner.has_capture then
    -- close before looping so each iteration gets fresh upvalues
    fs:emit("CLOSE", inner.firstreg)
  end
  fs:emit("JMPIFNOT", creg, top, nil, node.cond.line)
  fs:leave_block()   -- inner
  fs:leave_block()   -- loop block b
  for _, pc in ipairs(b.breaks) do fs:setarg(pc, "a", fs:here()) end
end

local function compile_numfor(fs, node)
  local base = fs.freereg
  -- registers: base=init, base+1=limit, base+2=step, base+3=var
  fs:reserve(3)
  exp2reg(fs, node.start, base)
  exp2reg(fs, node.limit, base + 1)
  if node.step then
    exp2reg(fs, node.step, base + 2)
  else
    fs:emit("LOADK", base + 2, fs:K(1), nil, node.line)
  end
  fs.freereg = base + 3
  local prep = fs:emit("FORPREP", base, 0, nil, node.line)
  local b = fs:enter_block(true)
  fs:reserve(1)
  fs:new_local(node.name, base + 3, "const")  -- Lua 5.5: control var is read-only
  local loopstart = fs:here()
  compile_block(fs, node.body)
  fs:leave_block()
  -- close captured loop var each iteration
  fs:emit("FORLOOP", base, loopstart, nil, node.line)
  fs:setarg(prep, "b", fs:here())   -- FORPREP skips past the loop
  for _, pc in ipairs(b.breaks) do fs:setarg(pc, "a", fs:here()) end
  fs.freereg = base
end

local function compile_genfor(fs, node)
  -- Lua 5.5 layout (after the TFORPREP swap):
  --   base   = iterator function   "(for state)"
  --   base+1 = state               "(for state)"
  --   base+2 = closing var         "(for state)"  (to-be-closed)
  --   base+3 = control var = first loop variable (read-only)
  --   base+4..= remaining loop variables
  -- The explist yields func, state, control(init), closing into base..base+3;
  -- TFORPREP swaps base+2<->base+3 so the to-be-closed sits below the loop
  -- variables (so a goto/break out of the loop closes it via a single CLOSE).
  local base = fs.freereg
  local nvars = #node.names
  adjust_explist(fs, node.exprs, base, 4)
  fs:reserve(4)
  if nvars > 1 then fs:reserve(nvars - 1) end
  fs.freereg = base + 3 + nvars
  local prep = fs:emit("TFORPREP", base, 0, nil, node.line)
  fs.ntbc = fs.ntbc + 1
  local b = fs:enter_block(true)
  b.firstreg = base
  -- hidden internal locals so goto/break CLOSE levels include the tbc at base+2
  fs:new_local("(for state)", base, nil)
  fs:new_local("(for state)", base + 1, nil)
  fs:new_local("(for state)", base + 2, nil)
  for i = 1, nvars do
    -- only the first (control) variable is read-only in Lua 5.5
    fs:new_local(node.names[i], base + 3 + (i - 1), (i == 1) and "const" or nil)
  end
  local loopstart = fs:here()
  compile_block(fs, node.body)
  fs:leave_block()
  fs:setarg(prep, "b", fs:here())        -- TFORPREP jumps to TFORCALL
  fs:emit("TFORCALL", base, nil, nvars, node.line)
  fs:emit("TFORLOOP", base, loopstart, nil, node.line)
  -- loop exit (normal fall-through and breaks): close the to-be-closed var
  local exitpc = fs:here()
  fs:emit("CLOSE", base + 2, nil, nil, node.line)
  for _, pc in ipairs(b.breaks) do fs:setarg(pc, "a", exitpc) end
  fs.ntbc = fs.ntbc - 1
  fs.freereg = base
end

local function compile_break(fs, node)
  local lb = fs:loop_block()
  if not lb then
    error(string.format("%s:%d: break outside loop near 'break'",
      fs.proto.source, node.line or 0), 0)
  end
  -- close upvalues created in the loop before jumping out
  fs:emit("CLOSE", lb.firstreg)
  lb.breaks[#lb.breaks + 1] = fs:emit("JMP", 0, nil, nil, node.line)
end

-- goto/label: a goto may exit blocks containing captured / to-be-closed locals,
-- so emit a CLOSE (level patched once the target's scope level is known) before
-- the jump.  Targets and the scope check are resolved at block close.
local function compile_goto(fs, node)
  -- snapshot the registers of the in-scope locals so resolution can compute
  -- the CLOSE level from the target's active-var count.
  local regs = {}
  for i = 1, #fs.actvars do regs[i] = fs.actvars[i].reg end
  local closepc = fs:emit("CLOSE", 256, nil, nil, node.line)   -- 256 = no-op
  fs.pending_gotos[#fs.pending_gotos + 1] =
    { name = node.label, pc = fs:emit("JMP", 0, nil, nil, node.line),
      line = node.line, nactvar = #fs.actvars, emitpc = fs:pc(),
      regs = regs, closepc = closepc }
end

local function compile_label(fs, node)
  -- duplicate-label detection: a label conflicts with any visible label, i.e.
  -- one in the current block or an enclosing (still-active) block.
  local cur_block = fs.blocks[#fs.blocks]
  local active = {}
  for _, b in ipairs(fs.blocks) do active[b] = true end
  for _, l in ipairs(fs.labels) do
    if l.name == node.name and active[l.block] then
      error(string.format("%s:%d: label '%s' already defined on line %d",
        fs.proto.source, node.line or 0, node.name, l.line or 0), 0)
    end
  end
  -- snapshot the names of in-scope locals (to name the culprit in goto errors)
  local varnames = {}
  for i = 1, #fs.actvars do varnames[i] = fs.actvars[i].name end
  fs.labels[#fs.labels + 1] =
    { name = node.name, pc = fs:here(), nactvar = #fs.actvars,
      line = node.line, block = cur_block, void = node.void, varnames = varnames }
end

function compile_stmt(fs, node)
  fs.curline = node.line or fs.curline
  local tag = node.tag
  if tag == "LocalAssign" then compile_local(fs, node)
  elseif tag == "LocalFunction" then compile_localfunction(fs, node)
  elseif tag == "Assign" then compile_assign(fs, node)
  elseif tag == "CallStat" then
    local reg = fs.freereg
    compile_call(fs, node.call, reg, 0)
    fs.freereg = reg
  elseif tag == "Do" then compile_block_scoped(fs, node.body)
  elseif tag == "While" then compile_while(fs, node)
  elseif tag == "Repeat" then compile_repeat(fs, node)
  elseif tag == "If" then compile_if(fs, node)
  elseif tag == "NumericFor" then compile_numfor(fs, node)
  elseif tag == "GenericFor" then compile_genfor(fs, node)
  elseif tag == "Return" then compile_return(fs, node)
  elseif tag == "Break" then compile_break(fs, node)
  elseif tag == "Goto" then compile_goto(fs, node)
  elseif tag == "Label" then compile_label(fs, node)
  elseif tag == "Global" then
    local g = fs.gdecl
    if node.star then
      g.allowall = true
    else
      -- track declared globals (permissive on undeclared use — enforcing
      -- "variable not declared" requires block-scoped decls; we only enforce
      -- <const> on explicitly named globals, which is unambiguous).
      for _, nm in ipairs(node.names) do
        g.declared[nm] = true
        g.const[nm] = nil   -- a (re)declaration's own init may assign
      end
      -- `global names = exprs` (or `global function f ...`) initializes; this
      -- assignment must run BEFORE marking const (init of a const is allowed).
      if node.exprs then
        local targets = {}
        for _, nm in ipairs(node.names) do
          targets[#targets + 1] = { tag = "Name", name = nm, line = node.line }
        end
        compile_assign(fs, { tag = "Assign", targets = targets,
          exprs = node.exprs, line = node.line })
      end
      for i, nm in ipairs(node.names) do
        if node.attribs[i] == "const" then g.const[nm] = true end
      end
    end
    -- record a goto scope barrier for the declaration (so a goto cannot jump
    -- into the scope of a `global *` / `global name`)
    if node.star then
      fs:add_gdecl_scope("*")
    else
      for _, nm in ipairs(node.names) do fs:add_gdecl_scope(nm) end
    end
  else error("compiler: unknown statement " .. tostring(tag)) end
end

-- compile a block introducing a new scope (for `do`...end and control bodies)
function compile_block_scoped(fs, block)
  fs:enter_block(false)
  for _, s in ipairs(block.stmts) do compile_stmt(fs, s) end
  fs:leave_block()
end

-- compile a block WITHOUT a fresh scope mgmt wrapper assumption: used where the
-- caller manages enter/leave (control statement bodies).  Here we add a scope.
function compile_block(fs, block)
  compile_block_scoped(fs, block)
end

-- ---------------------------------------------------------------------------
-- Function compilation
-- ---------------------------------------------------------------------------

-- compile node (a Function) as a nested proto of fs, returns proto index
function Compiler.compile_function(parent_fs, node)
  local fs = new_funcstate(parent_fs, parent_fs.proto.source, parent_fs.proto.chunkname)
  fs.pending_gotos = {}
  fs.labels = {}
  fs.proto.numparams = #node.params
  fs.proto.is_vararg = node.is_vararg
  fs.proto.line = node.line
  fs.proto.lastline = node.endline or node.line

  fs:enter_block(false)
  for _, p in ipairs(node.params) do
    local reg = fs.freereg
    fs:reserve(1)
    fs:new_local(p, reg, nil)
  end
  -- named vararg (...t): materialize the extra args as a table local
  if node.vararg_name then
    local reg = fs.freereg
    fs:reserve(1)
    fs:emit("VARARGPACK", reg, nil, nil, node.line)
    fs:new_local(node.vararg_name, reg, "const")   -- the ...t parameter is read-only
    fs.vararg_reg = reg     -- `...` now aliases this table
  end
  for _, s in ipairs(node.body.stmts) do compile_stmt(fs, s) end
  -- implicit return
  fs:leave_block()
  fs:emit("RETURN", 0, 1, nil, node.endline or node.line)  -- final return on 'end' line

  Compiler.resolve_gotos(fs)

  local protos = parent_fs.proto.protos
  protos[#protos + 1] = fs.proto
  return #protos
end

-- after all blocks have closed, any goto not resolved has no visible label
function Compiler.resolve_gotos(fs)
  for _, g in ipairs(fs.pending_gotos) do
    if not g.done then
      if g.name == "break" then
        error(string.format("%s:%d: break outside a loop at line %d",
          fs.proto.source, g.line or 0, g.line or 0), 0)
      end
      error(string.format("%s:%d: no visible label '%s' for <goto> at line %d",
        fs.proto.source, g.line or 0, g.name, g.line or 0), 0)
    end
  end
end

-- compile the top-level chunk (a vararg Function with an _ENV upvalue)
function Compiler.compile_main(ast, source, chunkname)
  local root = new_funcstate(nil, source, chunkname or source)
  root.is_main = true
  root.proto.is_main = true
  root.proto.is_vararg = true
  root.proto.numparams = 0
  root.pending_gotos = {}
  root.labels = {}
  -- main chunk's sole upvalue is _ENV
  root:add_upval("_ENV", false, 0)

  root.proto.line = 0
  root.proto.lastline = ast.endline or 0
  root:enter_block(false)
  for _, s in ipairs(ast.body.stmts) do compile_stmt(root, s) end
  root:leave_block()
  -- implicit final return is attributed to the chunk's last line (like Lua)
  root:emit("RETURN", 0, 1, nil, ast.endline or 0)
  Compiler.resolve_gotos(root)
  return root.proto
end

local function exported(src, chunkname)
  -- src here is the AST main Function node
  return Compiler.compile_main(src, chunkname)
end

return {
  compile_main = Compiler.compile_main,
  Compiler = Compiler,
}
