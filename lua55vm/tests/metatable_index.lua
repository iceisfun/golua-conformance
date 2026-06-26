local base = {greet = function(self) return "hi " .. self.name end}
base.__index = base
local obj = setmetatable({name = "x"}, base)
print(obj:greet())
local log = {}
local proxy = setmetatable({}, {
  __index = function(t, k) log[#log+1] = "get:" .. k; return k .. "!" end,
  __newindex = function(t, k, v) log[#log+1] = "set:" .. k .. "=" .. tostring(v); rawset(t, k, v) end,
})
print(proxy.foo)
proxy.bar = 10
print(rawget(proxy, "bar"))
for _, l in ipairs(log) do print(l) end
