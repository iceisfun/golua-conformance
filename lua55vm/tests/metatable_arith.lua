local V = {}
V.__index = V
function V.new(x) return setmetatable({x = x}, V) end
V.__add = function(a, b) return V.new(a.x + b.x) end
V.__sub = function(a, b) return V.new(a.x - b.x) end
V.__mul = function(a, b) return V.new(a.x * b.x) end
V.__eq = function(a, b) return a.x == b.x end
V.__lt = function(a, b) return a.x < b.x end
V.__le = function(a, b) return a.x <= b.x end
V.__tostring = function(a) return "V(" .. a.x .. ")" end
V.__concat = function(a, b)
  local ax = type(a) == "table" and a.x or a
  local bx = type(b) == "table" and b.x or b
  return "cat:" .. ax .. "," .. bx
end
V.__len = function(a) return a.x end
V.__unm = function(a) return V.new(-a.x) end
local p, q = V.new(3), V.new(5)
print(tostring(p + q), tostring(p - q), tostring(p * q))
print(p == q, p == V.new(3), p < q, p <= q, q <= p)
print(p .. "!", "n=" .. q)
print(#p, tostring(-p))
