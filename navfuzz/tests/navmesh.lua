-- navfuzz/tests/navmesh.lua
-- NavMesh adjacency + region labels and BVH locate/nearest/query_aabb,
-- cross-checked against brute force. Byte-identical on both runtimes.

local here = (arg and arg[0] or "?"):match("^(.*)[/\\]") or "."
package.path = here .. "/../?.lua;" .. package.path

local mesh = require("mesh")
local geom = require("geom")
local divconq = require("divconq")
local segment = require("segment")
local holes = require("holes")
local pslg = require("pslg")
local navmesh = require("navmesh")
local bvh = require("bvh")
local v = geom.vec

local function build(width, rows)
  local bits = pslg.bitfield_from_rows(width, rows)
  local P = pslg.pslg_from_bitfield(bits, {})
  local m = mesh.new()
  for i = 1, #P.vertices do m:push_vertex(v(P.vertices[i].x, P.vertices[i].y), 0) end
  divconq.delaunay(m, { dwyer = true })
  segment.form_skeleton(m, P, nil)
  holes.carve_holes(m, P, false)
  return navmesh.build(m)
end

local function sort3(a, b, c)
  if a > b then a, b = b, a end
  if b > c then b, c = c, b end
  if a > b then a, b = b, a end
  return a, b, c
end

-- canonical sorted vertex triple of a nav triangle
local function triple(nav, t)
  local tri = nav.triangles[t]
  return sort3(tri.v[0], tri.v[1], tri.v[2])
end

local function brute_locate(nav, p)
  for t = 1, nav:tcount() do
    local tri = nav.triangles[t]
    if geom.point_in_triangle(nav.vertices[tri.v[0]], nav.vertices[tri.v[1]], nav.vertices[tri.v[2]], p) then
      return t
    end
  end
  return nil
end

local function brute_nearest(nav, p)
  local bd, bt = math.huge, nil
  for t = 1, nav:tcount() do
    local tri = nav.triangles[t]
    local _, d = geom.nearest_point_on_triangle(
      nav.vertices[tri.v[0]], nav.vertices[tri.v[1]], nav.vertices[tri.v[2]], p)
    if d < bd then bd, bt = d, t end
  end
  return bt, bd
end

local function run(name, width, rows, queries)
  print("== " .. name .. " ==")
  local nav = build(width, rows)
  print("verts", nav:vcount())
  print("tris", nav:tcount())
  print("regions", nav.region_count)

  -- region histogram (triangle count per region, sorted by count then id)
  local hist = {}
  for t = 1, nav:tcount() do
    local r = nav.triangles[t].region
    hist[r] = (hist[r] or 0) + 1
  end
  local rows_h = {}
  for r, c in pairs(hist) do rows_h[#rows_h + 1] = { r, c } end
  table.sort(rows_h, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] < b[1] end)
  for _, rc in ipairs(rows_h) do print(string.format("  region size %d", rc[2])) end

  local idx = bvh.build(nav)
  print("bvh-nodes", #idx.nodes)

  for _, q in ipairs(queries) do
    local p = v(q[1], q[2])
    local lt = idx:locate(p)
    local bl = brute_locate(nav, p)
    local loc_ok = (lt == nil and bl == nil)
      or (lt ~= nil and geom.point_in_triangle(
        nav.vertices[nav.triangles[lt].v[0]], nav.vertices[nav.triangles[lt].v[1]],
        nav.vertices[nav.triangles[lt].v[2]], p))
    local locstr
    if lt == nil then locstr = "outside" else
      local a, b, c = triple(nav, lt); locstr = string.format("%d,%d,%d", a, b, c)
    end
    local nr = idx:nearest(p)
    local bt, bd = brute_nearest(nav, p)
    local near_ok = (nr ~= nil) and (nr.distance == bd)
    print(string.format("  q(%.1f,%.1f) locate=%s ok=%s nearest_d=%.6f ok=%s",
      q[1], q[2], locstr, loc_ok and "y" or "N",
      nr and nr.distance or -1, near_ok and "y" or "N"))
  end

  -- query_aabb: count triangles intersecting a central box, vs brute force
  local box = geom.aabb_from_points({ v(1, 1), v(width - 1, 3) })
  local hits = idx:query_aabb(box)
  local brute = 0
  for t = 1, nav:tcount() do
    if idx.tri_aabb[t]:intersects(box) then brute = brute + 1 end
  end
  print(string.format("  query_aabb hits=%d brute=%d ok=%s", #hits, brute, (#hits == brute) and "y" or "N"))
end

run("room5x5-hole", 5, { "#####", "#####", "##.##", "#####", "#####" },
  { { 0.5, 0.5 }, { 2.5, 2.5 }, { 4.5, 4.5 }, { 1.5, 2.5 }, { -1, -1 } })
run("two-rooms", 7, { "###.###", "###.###", "###.###" },
  { { 1.5, 1.5 }, { 5.5, 1.5 }, { 3.5, 1.5 } })
run("plus", 5, { "..#..", "..#..", "#####", "..#..", "..#.." },
  { { 2.5, 2.5 }, { 0.5, 2.5 }, { 2.5, 0.5 }, { 0.5, 0.5 } })

print("OK")
