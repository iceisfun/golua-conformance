local function f(...)
  local n = select("#", ...)
  return n, ...
end
print(f(1, 2, 3))
print(f())
print(f(nil, nil))
local function g(a, b, ...) return a, b, ... end
print(g(1, 2, 3, 4, 5))
local t = {f(10, 20, 30)}
print(#t, t[1], t[2])
local function sum(...)
  local s = 0
  for _, v in ipairs({...}) do s = s + v end
  return s
end
print(sum(1, 2, 3, 4, 5))
