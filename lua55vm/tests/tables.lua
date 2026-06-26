local t = {3, 1, 4, 1, 5, 9, 2, 6}
table.sort(t)
print(table.concat(t, ","))
table.sort(t, function(a, b) return a > b end)
print(table.concat(t, ","))
local a = {10, 20, 30}
table.insert(a, 40)
table.insert(a, 1, 5)
print(table.concat(a, ","))
print(table.remove(a), table.remove(a, 1))
print(table.concat(a, ","))
local packed = table.pack(1, nil, 3)
print(packed.n, packed[1], packed[2], packed[3])
print(table.unpack({100, 200, 300}))
