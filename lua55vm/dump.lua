-- lua55vm/dump.lua
-- Serialize / deserialize a guest Proto to a binary string, backing
-- string.dump and binary load().  The format is our own (the VM's bytecode is
-- not Lua's), self-describing, and produced/consumed with host string.pack.

local spack = string.pack
local sunpack = string.unpack

local M = {}

M.SIGNATURE = "\27LuaVM\1"   -- leading \27 marks a binary chunk (like Lua's)

-- ---------------------------------------------------------------------------
-- encoder
-- ---------------------------------------------------------------------------

local function enc_proto(out, p, strip)
  out[#out + 1] = spack("<i4i4B", p.numparams or 0, p.maxstack or 2,
    p.is_vararg and 1 or 0)
  out[#out + 1] = spack("<i4", p.line or 0)
  out[#out + 1] = spack("<s4", strip and "" or (p.source or "?"))
  out[#out + 1] = spack("<s4", strip and "" or (p.chunkname or ""))

  -- constants
  local consts = p.consts
  out[#out + 1] = spack("<i4", #consts)
  for i = 1, #consts do
    local v = consts[i]
    local t = type(v)
    if t == "number" then
      if math.type(v) == "integer" then
        out[#out + 1] = spack("<Bi8", 3, v)
      else
        out[#out + 1] = spack("<Bn", 4, v)
      end
    elseif t == "string" then
      out[#out + 1] = spack("<B", 5) .. spack("<s4", v)
    elseif t == "boolean" then
      out[#out + 1] = spack("<B", v and 2 or 1)
    else
      out[#out + 1] = spack("<B", 0)   -- nil
    end
  end

  -- code
  local code = p.code
  out[#out + 1] = spack("<i4", #code)
  for i = 1, #code do
    local ins = code[i]
    out[#out + 1] = spack("<s4", ins.op)
    -- a/b/c: flag byte (1 = present) + i8  (explicit; nil holes break ipairs)
    local a, b, c = ins.a, ins.b, ins.c
    out[#out + 1] = (a == nil) and spack("<B", 0) or spack("<Bi8", 1, a)
    out[#out + 1] = (b == nil) and spack("<B", 0) or spack("<Bi8", 1, b)
    out[#out + 1] = (c == nil) and spack("<B", 0) or spack("<Bi8", 1, c)
  end

  -- line info
  local lines = p.lines
  out[#out + 1] = spack("<i4", #lines)
  for i = 1, #lines do out[#out + 1] = spack("<i4", lines[i] or 0) end

  -- upvalues
  local ups = p.upvals
  out[#out + 1] = spack("<i4", #ups)
  for i = 1, #ups do
    local u = ups[i]
    out[#out + 1] = spack("<s4", strip and "" or (u.name or ""))
    out[#out + 1] = spack("<Bi8", u.in_stack and 1 or 0, u.index or 0)
  end

  -- nested protos
  local protos = p.protos
  out[#out + 1] = spack("<i4", #protos)
  for i = 1, #protos do enc_proto(out, protos[i], strip) end
end

function M.dump(proto, strip)
  local out = { M.SIGNATURE }
  enc_proto(out, proto, strip)
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- decoder
-- ---------------------------------------------------------------------------

local function dec_proto(s, pos)
  local p = { code = {}, lines = {}, consts = {}, protos = {},
              upvals = {}, locvars = {} }
  local np, maxstack, va
  np, maxstack, va, pos = sunpack("<i4i4B", s, pos)
  p.numparams = np; p.maxstack = maxstack; p.is_vararg = (va == 1)
  p.line, pos = sunpack("<i4", s, pos)
  p.source, pos = sunpack("<s4", s, pos)
  p.chunkname, pos = sunpack("<s4", s, pos)
  if p.chunkname == "" then p.chunkname = nil end

  local nconst; nconst, pos = sunpack("<i4", s, pos)
  for i = 1, nconst do
    local tag; tag, pos = sunpack("<B", s, pos)
    if tag == 0 then p.consts[i] = nil
    elseif tag == 1 then p.consts[i] = false
    elseif tag == 2 then p.consts[i] = true
    elseif tag == 3 then p.consts[i], pos = sunpack("<i8", s, pos)
    elseif tag == 4 then p.consts[i], pos = sunpack("<n", s, pos)
    elseif tag == 5 then p.consts[i], pos = sunpack("<s4", s, pos)
    else error("bad binary format (constant)") end
  end

  local ncode; ncode, pos = sunpack("<i4", s, pos)
  for i = 1, ncode do
    local op; op, pos = sunpack("<s4", s, pos)
    local ins = { op = op }
    local fields = { "a", "b", "c" }
    for fi = 1, 3 do
      local flag; flag, pos = sunpack("<B", s, pos)
      if flag == 1 then ins[fields[fi]], pos = sunpack("<i8", s, pos) end
    end
    p.code[i] = ins
  end

  local nlines; nlines, pos = sunpack("<i4", s, pos)
  for i = 1, nlines do p.lines[i], pos = sunpack("<i4", s, pos) end

  local nups; nups, pos = sunpack("<i4", s, pos)
  for i = 1, nups do
    local name, instk, idx
    name, pos = sunpack("<s4", s, pos)
    instk, idx, pos = sunpack("<Bi8", s, pos)
    p.upvals[i] = { name = name, in_stack = (instk == 1), index = idx }
  end

  local nprotos; nprotos, pos = sunpack("<i4", s, pos)
  for i = 1, nprotos do p.protos[i], pos = dec_proto(s, pos) end

  return p, pos
end

-- returns proto or raises an error ("bad binary format")
function M.undump(s)
  if s:sub(1, #M.SIGNATURE) ~= M.SIGNATURE then
    error("bad binary format (signature mismatch)")
  end
  local proto = dec_proto(s, #M.SIGNATURE + 1)
  return proto
end

function M.is_binary(s)
  return type(s) == "string" and s:sub(1, 1) == "\27"
end

return M
