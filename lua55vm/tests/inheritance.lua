local Animal = {}
Animal.__index = Animal
function Animal.new(name) return setmetatable({name = name}, Animal) end
function Animal:speak() return self.name .. " makes a sound" end
function Animal:getName() return self.name end

local Dog = setmetatable({}, {__index = Animal})
Dog.__index = Dog
function Dog.new(name) local d = Animal.new(name); return setmetatable(d, Dog) end
function Dog:speak() return self.name .. " barks" end

local a = Animal.new("cat")
local d = Dog.new("rex")
print(a:speak())
print(d:speak())
print(d:getName())
