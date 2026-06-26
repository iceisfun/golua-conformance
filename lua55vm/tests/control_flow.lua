local i = 0
while i < 5 do i = i + 1 end
print("while", i)
local j = 0
repeat j = j + 1 until j >= 3
print("repeat", j)
local s = 0
for k = 10, 1, -2 do s = s + k end
print("for-down", s)
for x = 1.0, 2.0, 0.5 do io.write(x, " ") end
print()
local found
for k, v in pairs({a=1, b=2, c=3}) do if v == 2 then found = k end end
print("found", found)
local n = 0
for k = 1, 10 do if k == 5 then break end n = n + 1 end
print("break", n)
do
  goto skip
  ::dead::
  print("should not print")
  ::skip::
  print("after goto")
end
