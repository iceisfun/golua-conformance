-- scripts/official.lua : run one official Lua 5.5 test file under our
-- interpreter, with the harness globals that all.lua provides set up, so files
-- can be driven to green individually.
--
--   lua5.5.0 official.lua /path/to/lua-5.5.0-tests/pm.lua

local function script_dir()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then return (src:sub(2):match("^(.*)[/\\]") or ".") end
  return "."
end
package.path = script_dir() .. "/../?.lua;" .. package.path

local lua55 = require("init")
local rt = lua55.rt

local path = arg[1]
if not path then io.stderr:write("usage: official.lua FILE.lua\n"); os.exit(1) end

local I = lua55.new()
local G = I.globals
local function setg(k, v) rt.rawset(G, k, v) end

-- harness globals (defaults from all.lua: test everything)
setg("_soft", false)
setg("_port", false)
setg("_nomsg", false)
setg("_nomem", false)
setg("T", nil)                 -- no C internal-test library
setg("_U", nil)
setg("Message", G.hash["print"])
setg("_G", G)
setg("_ENV", G)

-- guest `arg`
local argt = rt.new_table()
rt.rawset(argt, 0, path)
setg("arg", argt)
setg("ARG", argt)

-- the test dir, so dofile/require of sibling helpers resolves
local dir = path:match("^(.*)[/\\]") or "."
G.hash["package"].hash["path"] =
  dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. G.hash["package"].hash["path"]

local f, err = io.open(path, "rb")
if not f then io.stderr:write("cannot open " .. path .. ": " .. tostring(err) .. "\n"); os.exit(1) end
local src = f:read("a"); f:close()

local ok, fn = pcall(function() return I:load(src, "@" .. path) end)
if not ok then
  local m = fn
  if type(m) == "table" and getmetatable(m) == I.GUEST_ERR_MT then m = m.value end
  io.stderr:write("compile error: " .. tostring(m) .. "\n")
  os.exit(1)
end

local success, res = I:protected(fn, { n = 0 })
if not success then
  io.stderr:write("error: " .. I:tostring(res) .. "\n")
  os.exit(1)
end
