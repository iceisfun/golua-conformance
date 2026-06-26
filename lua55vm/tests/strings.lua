print(("Hello"):upper(), ("WORLD"):lower())
print(string.rep("ab", 3), string.rep("x", 3, "-"))
print(string.sub("hello world", 1, 5), ("hello"):sub(-3))
print(string.format("%d %05.2f %s %x", 42, 3.14159, "hi", 255))
print(string.format("%q", "a\nb\"c"))
print(("hello world"):find("o"))
print(("hello world"):match("(%w+) (%w+)"))
print(("a,b,c,d"):gsub(",", ";"))
print(("hello"):gsub("l", function(c) return c:upper() end))
local words = {}
for w in ("the quick brown fox"):gmatch("%a+") do words[#words+1] = w end
print(table.concat(words, "|"))
print(#"hello", string.byte("A"), string.char(65, 66, 67))
