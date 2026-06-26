-- lua55vm/run.lua
-- CLI driver: run a Lua source file through the guest interpreter.
--
--   lua run.lua script.lua [args...]
--   lua run.lua -e "chunk"
--
-- Resolves its own directory so it can be invoked from anywhere.

local function script_dir()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    local path = src:sub(2)
    return path:match("^(.*)[/\\]") or "."
  end
  return "."
end

package.path = script_dir() .. "/?.lua;" .. package.path

local lua55 = require("init")
local rt = lua55.rt

local function main(argv)
  local I = lua55.new()

  local code, chunkname, prog_args
  if argv[1] == "-e" then
    code = argv[2]
    chunkname = "=(command line)"
    prog_args = {}
    for i = 3, #argv do prog_args[#prog_args + 1] = argv[i] end
  else
    local path = argv[1]
    if not path then
      io.stderr:write("usage: run.lua script.lua [args...]\n")
      os.exit(1)
    end
    local f, err = io.open(path, "rb")
    if not f then
      io.stderr:write("cannot open " .. tostring(path) .. ": " .. tostring(err) .. "\n")
      os.exit(1)
    end
    code = f:read("a")
    f:close()
    chunkname = "@" .. path
    prog_args = {}
    for i = 2, #argv do prog_args[#prog_args + 1] = argv[i] end
  end

  -- populate guest `arg` table
  local argt = rt.new_table()
  argt.hash[0] = (chunkname:sub(1, 1) == "@") and chunkname:sub(2) or chunkname
  for i, v in ipairs(prog_args) do argt.hash[i] = v end
  I.globals.hash["arg"] = argt

  local ok, fn = pcall(function() return I:load(code, chunkname) end)
  if not ok then
    local msg = fn
    if type(msg) == "table" and getmetatable(msg) == I.GUEST_ERR_MT then
      msg = msg.value
    end
    io.stderr:write("lua55vm: " .. tostring(msg) .. "\n")
    os.exit(1)
  end

  local callargs = { n = #prog_args }
  for i = 1, #prog_args do callargs[i] = prog_args[i] end
  local success, result = I:protected(fn, callargs)
  if not success then
    io.stderr:write("lua55vm: " .. I:tostring(result) .. "\n")
    os.exit(1)
  end
end

main(arg)
