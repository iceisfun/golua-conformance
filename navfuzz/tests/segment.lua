-- navfuzz/tests/segment.lua
-- Constrained-edge insertion: force segments (incl. the non-Delaunay diagonal)
-- and verify each appears as a subsegment, the mesh stays valid, and the
-- output is byte-identical on both runtimes.

local here = (arg and arg[0] or "?"):match("^(.*)[/\\]") or "."
package.path = here .. "/../?.lua;" .. package.path

local mesh = require("mesh")
local geom = require("geom")
local divconq = require("divconq")
local segment = require("segment")
local v = geom.vec

local function sort3(a, b, c)
  if a > b then a, b = b, a end
  if b > c then b, c = c, b end
  if a > b then a, b = b, a end
  return a, b, c
end

local function subseg_pairs(m)
  local set = {}
  local adj = {}
  local function link(a, b)
    adj[a] = adj[a] or {}; adj[a][b] = true
  end
  for sub = 1, m.n_subs do
    if (m.subsegs[sub].flags & 1) == 0 then -- not dead
      local h = mesh.osub_pack(sub, 0)
      local a, b = m:sorg(h), m:sdest(h)
      link(a, b); link(b, a)
      if a > b then a, b = b, a end
      set[a .. "-" .. b] = true
    end
  end
  return set, adj
end

-- A segment a->b is "conformed" if a chain of subsegs, each collinear with
-- a->b and advancing toward b, connects a to b (it may be split at collinear
-- interior vertices). Greedy forward walk along that chain.
local function seg_conformed(m, a, b, adj)
  local pa, pb = m:vertex_pos(a), m:vertex_pos(b)
  local abx, aby = pb.x - pa.x, pb.y - pa.y
  local function param(p) return (p.x - pa.x) * abx + (p.y - pa.y) * aby end
  local cur = a
  for _ = 1, 10000 do
    if cur == b then return true end
    local tcur = param(m:vertex_pos(cur))
    local nxt, best = nil, nil
    for nb in pairs(adj[cur] or {}) do
      local pn = m:vertex_pos(nb)
      if geom.orient2d(pa, pb, pn) == 0 then
        local tn = param(pn)
        if tn > tcur and (best == nil or tn < best) then nxt, best = nb, tn end
      end
    end
    if nxt == nil then return false end
    cur = nxt
  end
  return false
end

local function run(name, pts, segs, mark_hull)
  print("== " .. name .. " ==")
  local m = mesh.new()
  for i = 1, #pts do m:push_vertex(v(pts[i][1], pts[i][2]), 0) end
  local hull = divconq.delaunay(m, { dwyer = true })

  local pslg = { segments = {} }
  for i = 1, #segs do
    pslg.segments[i] = { a = segs[i][1], b = segs[i][2], marker = segs[i][3] or 1 }
  end
  local ok, err = pcall(segment.form_skeleton, m, pslg, mark_hull)
  if not ok then
    print("form_skeleton error", type(err) == "table" and err.kind or tostring(err))
    return
  end

  -- collect triangles, check validity
  local tris, all_ccw = {}, true
  divconq.for_each_live(m, function(_, slot)
    local v0, v1, v2 = slot.vtx[1], slot.vtx[2], slot.vtx[0]
    if not (geom.orient2d(m:vertex_pos(v0), m:vertex_pos(v1), m:vertex_pos(v2)) > 0) then all_ccw = false end
    local a, b, c = sort3(v0, v1, v2)
    tris[#tris + 1] = { a, b, c }
  end)
  table.sort(tris, function(x, y)
    if x[1] ~= y[1] then return x[1] < y[1] end
    if x[2] ~= y[2] then return x[2] < y[2] end
    return x[3] < y[3]
  end)

  local pairs_set, adj = subseg_pairs(m)
  print("hull", hull)
  print("triangles", #tris)
  print("all-ccw", all_ccw and "yes" or "no")
  print("subseg-count", (function() local c = 0; for _ in pairs(pairs_set) do c = c + 1 end; return c end)())

  -- verify every requested segment is conformed (possibly via a collinear chain)
  local all_present = true
  for i = 1, #segs do
    if not seg_conformed(m, segs[i][1], segs[i][2], adj) then
      all_present = false; print("  MISSING seg", segs[i][1], segs[i][2])
    end
  end
  print("all-segs-conformed", all_present and "yes" or "no")

  for i = 1, #tris do
    print(string.format("  t %d %d %d", tris[i][1], tris[i][2], tris[i][3]))
  end
end

-- Square: Delaunay picks diagonal 2-4; force the opposite diagonal 1-3.
run("square-force-diag", { { 0, 0 }, { 4, 0 }, { 4, 4 }, { 0, 4 } }, { { 1, 3 } }, nil)

-- Closed boundary polygon (CCW) with two interior points; constrain the
-- whole boundary + mark the hull.
run("poly-boundary",
  { { 0, 0 }, { 6, 0 }, { 6, 4 }, { 0, 4 }, { 2, 2 }, { 4, 2 } },
  { { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 } }, 1)

-- A long constraint that must cut across several triangles (a "channel").
run("long-constraint",
  { { 0, 0 }, { 1, 3 }, { 2, 0 }, { 3, 3 }, { 4, 0 }, { 5, 3 }, { 6, 0 } },
  { { 1, 7 } }, nil)

print("OK")
