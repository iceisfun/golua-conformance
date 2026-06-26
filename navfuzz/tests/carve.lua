-- navfuzz/tests/carve.lua
-- Full bitfield -> PSLG -> CDT -> carve. The surviving triangles must tile
-- exactly the walkable cells (total area == walkable cell count), stay CCW,
-- and produce byte-identical output on both runtimes.

local here = (arg and arg[0] or "?"):match("^(.*)[/\\]") or "."
package.path = here .. "/../?.lua;" .. package.path

local mesh = require("mesh")
local geom = require("geom")
local divconq = require("divconq")
local segment = require("segment")
local holes = require("holes")
local pslg = require("pslg")
local v = geom.vec

local function sort3(a, b, c)
  if a > b then a, b = b, a end
  if b > c then b, c = c, b end
  if a > b then a, b = b, a end
  return a, b, c
end

local function run(name, width, rows)
  print("== " .. name .. " ==")
  local bits = pslg.bitfield_from_rows(width, rows)
  -- count walkable cells
  local walkable = 0
  for i = 1, #bits.data do if bits.data[i] then walkable = walkable + 1 end end

  local P = pslg.pslg_from_bitfield(bits, {})
  local m = mesh.new()
  for i = 1, #P.vertices do m:push_vertex(v(P.vertices[i].x, P.vertices[i].y), 0) end
  divconq.delaunay(m, { dwyer = true })
  local ok, err = pcall(segment.form_skeleton, m, P, nil)
  if not ok then
    print("form_skeleton error", type(err) == "table" and err.kind or tostring(err))
    return
  end
  local killed = holes.carve_holes(m, P, false)

  local tris, all_ccw, area2_sum = {}, true, 0
  divconq.for_each_live(m, function(_, slot)
    local v0, v1, v2 = slot.vtx[1], slot.vtx[2], slot.vtx[0]
    local a2 = geom.orient2d(m:vertex_pos(v0), m:vertex_pos(v1), m:vertex_pos(v2))
    if not (a2 > 0) then all_ccw = false end
    area2_sum = area2_sum + a2
    local a, b, c = sort3(v0, v1, v2)
    tris[#tris + 1] = { a, b, c }
  end)
  table.sort(tris, function(x, y)
    if x[1] ~= y[1] then return x[1] < y[1] end
    if x[2] ~= y[2] then return x[2] < y[2] end
    return x[3] < y[3]
  end)

  print("pslg-verts", #P.vertices)
  print("pslg-segs", #P.segments)
  print("pslg-holes", #P.holes)
  print("walkable-cells", walkable)
  print("survivors", #tris)
  print("killed", killed)
  print("all-ccw", all_ccw and "yes" or "no")
  -- area2_sum is twice the walkable area; should equal 2 * walkable cells
  print("area-matches", (area2_sum == 2 * walkable) and "yes" or ("NO(" .. area2_sum .. ")"))
  for i = 1, #tris do
    print(string.format("  t %d %d %d", tris[i][1], tris[i][2], tris[i][3]))
  end
end

run("room5x5-hole", 5, { "#####", "#####", "##.##", "#####", "#####" })
run("corridor", 5, { "#####" })
run("L-shape", 3, { "###", "#..", "#.." })
run("room-two-holes", 7, { "#######", "#.###.#", "#######", "#.###.#", "#######" })
run("plus", 5, { "..#..", "..#..", "#####", "..#..", "..#.." })

print("OK")
