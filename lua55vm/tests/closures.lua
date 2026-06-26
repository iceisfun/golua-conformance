local function counter()
  local n = 0
  return function() n = n + 1; return n end
end
local c = counter()
print(c(), c(), c())
local fns = {}
for i = 1, 3 do fns[i] = function() return i end end
print(fns[1](), fns[2](), fns[3]())
local function outer()
  local x = 10
  local function a() x = x + 1; return x end
  local function b() return x end
  return a, b
end
local a, b = outer()
print(a(), b(), a())
