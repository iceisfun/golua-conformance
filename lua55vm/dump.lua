-- lua55vm/dump.lua
-- Serialize / deserialize a guest Proto to a binary string, backing
-- string.dump and binary load().  The format is our own (the VM's bytecode is
-- not Lua's), self-describing, and produced/consumed with host string.pack.

local spack = string.pack
local sunpack = string.unpack

local M = {}

-- A Lua 5.5-compatible binary header precedes our own bytecode body, so that
-- tools/tests inspecting the header (signature, version, sizes, sentinel
-- numbers) see exactly what PUC produces, and a single corrupted header byte
-- invalidates the chunk. The body after the header is our VM's own format.
local HEADER_FMT = "c4BBc6BiBI4BjBn"
M.SIGNATURE = spack(HEADER_FMT,
  "\27Lua",                 -- signature
  0x55,                     -- version 5.5
  0,                        -- format 0
  "\25\147\r\n\26\n",       -- LUAC_DATA  ("\x19\x93\r\n\x1a\n")
  string.packsize("i"),     -- sizeof(int)
  -0x5678,                  -- LUAC_INT sentinel (test int)
  4,                        -- sizeof(instruction)
  0x12345678,               -- test instruction
  string.packsize("j"),     -- sizeof(lua_Integer)
  -0x5678,                  -- test integer
  string.packsize("n"),     -- sizeof(lua_Number)
  -370.5)                   -- LUAC_NUM sentinel (test float)

-- ---------------------------------------------------------------------------
-- encoder
-- ---------------------------------------------------------------------------

local function enc_proto(out, p, strip, psource)
  out[#out + 1] = spack("<i4i4B", p.numparams or 0, p.maxstack or 2,
    p.is_vararg and 1 or 0)
  out[#out + 1] = spack("<i4", p.line or 0)
  -- store the source only when it differs from the parent's (Lua dumps "" for a
  -- nested function sharing its parent's source) so it isn't repeated per proto
  if strip or p.source == psource then
    out[#out + 1] = spack("<s4", "")
  else
    out[#out + 1] = spack("<s4", p.source or "?")
  end
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

  -- line info (omitted when stripping debug info)
  local lines = p.lines
  if strip then
    out[#out + 1] = spack("<i4", 0)
  else
    out[#out + 1] = spack("<i4", #lines)
    for i = 1, #lines do out[#out + 1] = spack("<i4", lines[i] or 0) end
  end

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
  for i = 1, #protos do enc_proto(out, protos[i], strip, p.source) end
end

function M.dump(proto, strip)
  local out = { M.SIGNATURE }
  enc_proto(out, proto, strip)
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- decoder
-- ---------------------------------------------------------------------------

local function dec_proto(s, pos, psource)
  local p = { code = {}, lines = {}, consts = {}, protos = {},
              upvals = {}, locvars = {} }
  local np, maxstack, va
  np, maxstack, va, pos = sunpack("<i4i4B", s, pos)
  p.numparams = np; p.maxstack = maxstack; p.is_vararg = (va == 1)
  p.line, pos = sunpack("<i4", s, pos)
  p.source, pos = sunpack("<s4", s, pos)
  if p.source == "" then p.source = psource end   -- inherit parent's source
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
  for i = 1, nprotos do p.protos[i], pos = dec_proto(s, pos, p.source) end

  return p, pos
end

-- returns proto or raises an error. A too-short chunk is "truncated"; a header
-- that doesn't match exactly is a "bad binary format".
function M.undump(s)
  local hlen = #M.SIGNATURE
  if #s < hlen then error("truncated precompiled chunk") end
  if s:sub(1, hlen) ~= M.SIGNATURE then
    error("bad binary format (header mismatch)")
  end
  -- body parse: running out of data mid-decode means a truncated chunk
  local ok, proto = pcall(dec_proto, s, hlen + 1)
  if not ok then error("truncated precompiled chunk") end
  return proto
end

function M.is_binary(s)
  return type(s) == "string" and s:sub(1, 1) == "\27"
end

return M
