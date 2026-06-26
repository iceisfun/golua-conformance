local co = coroutine.create(function(a, b)
  print("start", a, b)
  local c = coroutine.yield(a + b)
  print("resumed", c)
  local d = coroutine.yield(c * 2)
  print("resumed2", d)
  return "done"
end)
print(coroutine.resume(co, 1, 2))
print(coroutine.resume(co, 10))
print(coroutine.resume(co, 20))
print(coroutine.resume(co, 30))
print(coroutine.status(co))

local gen = coroutine.wrap(function()
  for i = 1, 3 do coroutine.yield(i * i) end
end)
print(gen(), gen(), gen())

local co2 = coroutine.create(function() error("inside") end)
print(coroutine.resume(co2))
