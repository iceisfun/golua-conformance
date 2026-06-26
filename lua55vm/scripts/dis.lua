-- scripts/dis.lua : disassemble a chunk's bytecode (debug aid)
package.path = (arg[0]:match("^(.*)[/\\]") or ".") .. "/../?.lua;" .. package.path
local lexer = require("lexer")
local parser = require("parser")
local compiler = require("compiler")

local src
if arg[1] == "-e" then src = arg[2] else
  local f = io.open(arg[1], "rb"); src = f:read("a"); f:close()
end
local proto = compiler.compile_main(parser.parse(lexer.tokenize(src, "dis"), "dis"), "dis")

local function show(p, name, indent)
  indent = indent or ""
  print(string.format("%s== %s  params=%d vararg=%s maxstack=%d nups=%d nconst=%d",
    indent, name, p.numparams, tostring(p.is_vararg), p.maxstack, #p.upvals, #p.consts))
  for i, k in ipairs(p.consts) do
    print(string.format("%s  K[%d] = %s (%s)", indent, i,
      type(k)=="string" and string.format("%q", k) or tostring(k), math.type(k) or type(k)))
  end
  for i, u in ipairs(p.upvals) do
    print(string.format("%s  U[%d] = %s instack=%s idx=%d", indent, i, u.name, tostring(u.in_stack), u.index))
  end
  for pc, ins in ipairs(p.code) do
    print(string.format("%s  %3d  %-9s %s %s %s   ; line %d", indent, pc, ins.op,
      tostring(ins.a or ""), tostring(ins.b or ""), tostring(ins.c or ""), p.lines[pc] or 0))
  end
  for i, sub in ipairs(p.protos) do
    show(sub, name .. "/proto" .. i, indent .. "    ")
  end
end
show(proto, "main")
