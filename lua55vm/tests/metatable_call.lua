local callable = setmetatable({}, {__call = function(self, a, b) return a + b, a * b end})
print(callable(3, 4))
local adder = setmetatable({base = 100}, {__call = function(self, x) return self.base + x end})
print(adder(5))
