-- lua55vm/init.lua
-- Convenience entry point: build a fully-equipped interpreter instance.

local vm = require("vm")
local stdlib = require("stdlib")

local M = {}

function M.new()
  local I = vm.Interp.new()
  stdlib.install_all(I)
  return I
end

M.Interp = vm.Interp
M.rt = vm.rt
return M
