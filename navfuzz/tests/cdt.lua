-- navfuzz/tests/cdt.lua
-- Divide-and-conquer Delaunay: hull size, Euler relation, CCW invariant,
-- and a canonical (sorted) triangle dump. Byte-identical on both runtimes.

local here = (arg and arg[0] or "?"):match("^(.*)[/\\]") or "."
package.path = here .. "/../?.lua;" .. package.path

local mesh = require("mesh")
local geom = require("geom")
local divconq = require("divconq")
local v = geom.vec

local function sort3(a, b, c)
  if a > b then a, b = b, a end
  if b > c then b, c = c, b end
  if a > b then a, b = b, a end
  return a, b, c
end

local function run(name, pts)
  print("== " .. name .. " ==")
  local m = mesh.new()
  for i = 1, #pts do m:push_vertex(v(pts[i][1], pts[i][2]), 0) end
  local hull = divconq.delaunay(m, { dwyer = true })

  local tris = {}
  local all_ccw = true
  divconq.for_each_live(m, function(_, slot)
    local v0, v1, v2 = slot.vtx[1], slot.vtx[2], slot.vtx[0] -- org,dest,apex
    local area2 = geom.orient2d(m:vertex_pos(v0), m:vertex_pos(v1), m:vertex_pos(v2))
    if not (area2 > 0) then all_ccw = false end
    local a, b, c = sort3(v0, v1, v2)
    tris[#tris + 1] = { a, b, c }
  end)
  table.sort(tris, function(x, y)
    if x[1] ~= y[1] then return x[1] < y[1] end
    if x[2] ~= y[2] then return x[2] < y[2] end
    return x[3] < y[3]
  end)

  local n = #m.vertices
  print("vertices", n)
  print("hull", hull)
  print("triangles", #tris)
  print("euler 2n-2-h", 2 * n - 2 - hull, (#tris == 2 * n - 2 - hull) and "ok" or "MISMATCH")
  print("all-ccw", all_ccw and "yes" or "no")
  for i = 1, #tris do
    print(string.format("  t %d %d %d", tris[i][1], tris[i][2], tris[i][3]))
  end
end

run("triangle", { { 0, 0 }, { 4, 0 }, { 2, 3 } })
run("square", { { 0, 0 }, { 4, 0 }, { 4, 4 }, { 0, 4 } })
run("grid3x2", { { 0, 0 }, { 0, 1 }, { 1, 0 }, { 1, 1 }, { 2, 0 }, { 2, 1 } })
run("grid4x4", (function()
  local t = {}
  for x = 0, 3 do for y = 0, 3 do t[#t + 1] = { x, y } end end
  return t
end)())
run("pentagon-ish", { { 0, 0 }, { 6, 0 }, { 8, 4 }, { 3, 7 }, { -2, 4 }, { 3, 3 } })

print("OK")
