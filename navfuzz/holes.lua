-- navfuzz/holes.lua
--
-- Hole carving: remove triangles inside marked holes and the exterior
-- concavities from a constrained Delaunay triangulation. Port of
-- triangle.c's infecthull / plague / sweep via rsnav's triangle/src/holes.rs.
--
--   1. infect_hull  : infect hull triangles whose hull edge has no subseg
--   2. seed_holes   : infect the triangle containing each hole seed point
--   3. plague (BFS) : spread infection across non-constrained edges
--   4. sweep        : delete infected triangles, re-bond survivors to dummy

local mesh = require("mesh")
local geom = require("geom")

local lnext = mesh.lnext
local otri_pack, otri_tri = mesh.otri_pack, mesh.otri_tri
local osub_sub = mesh.osub_sub
local DUMMY_TRI, DUMMY_SUB = mesh.DUMMY_TRI, mesh.DUMMY_SUB
local INVALID = mesh.INVALID_VERTEX

local H = {}

local function oprev(m, o) return lnext(m:sym(o)) end

-- simple FIFO queue
local function queue() return { items = {}, head = 1, tail = 0 } end
local function push(q, x) q.tail = q.tail + 1; q.items[q.tail] = x end
local function pop(q)
  if q.head > q.tail then return nil end
  local x = q.items[q.head]
  q.items[q.head] = nil
  q.head = q.head + 1
  return x
end

-- --- infect_hull ---------------------------------------------------------

local function infect_hull(m, infected, work)
  local start = m:sym(otri_pack(DUMMY_TRI, 0))
  if otri_tri(start) == DUMMY_TRI then return end
  local hulltri = start
  while true do
    local ht = otri_tri(hulltri)
    if not infected[ht] then
      local hullsub = m:tspivot(hulltri)
      if osub_sub(hullsub) == DUMMY_SUB then
        infected[ht] = true
        push(work, ht)
      end
    end
    hulltri = lnext(hulltri)
    local nexttri = oprev(m, hulltri)
    while otri_tri(nexttri) ~= DUMMY_TRI do
      hulltri = nexttri
      nexttri = oprev(m, hulltri)
    end
    if hulltri == start then break end
  end
end

-- --- seed_holes ----------------------------------------------------------

local function locate_triangle(m, pt)
  for tri = 1, m.n_tris do
    local slot = m.triangles[tri]
    if (slot.flags & 2) == 0 then -- not dead
      local v0, v1, v2 = slot.vtx[0], slot.vtx[1], slot.vtx[2]
      if v0 ~= INVALID and v1 ~= INVALID and v2 ~= INVALID then
        if geom.point_in_triangle(m.vertices[v0].pos, m.vertices[v1].pos, m.vertices[v2].pos, pt) then
          return tri
        end
      end
    end
  end
  return nil
end

local function seed_holes(m, pslg, infected, work)
  for _, hole in ipairs(pslg.holes) do
    local tri = locate_triangle(m, hole.point)
    if tri ~= nil and not infected[tri] then
      infected[tri] = true
      push(work, tri)
    end
  end
end

-- --- plague --------------------------------------------------------------

local function plague(m, infected, work)
  while true do
    local tri = pop(work)
    if tri == nil then break end
    for orient = 0, 2 do
      local here = otri_pack(tri, orient)
      local neighbor = m:sym(here)
      local sub = m:tspivot(here)
      local nt = otri_tri(neighbor)

      if nt == DUMMY_TRI or infected[nt] then
        if osub_sub(sub) ~= DUMMY_SUB then
          m:kill_subseg(osub_sub(sub))
          if nt ~= DUMMY_TRI then m:ts_dissolve(neighbor) end
        end
      else
        if osub_sub(sub) == DUMMY_SUB then
          infected[nt] = true
          push(work, nt)
        else
          m:st_dissolve(sub)
          if m:smarker(sub) == 0 then m:set_smarker(sub, 1) end
          local norg = m:org(neighbor)
          local ndest = m:dest(neighbor)
          if norg ~= INVALID and m.vertices[norg].marker == 0 then m.vertices[norg].marker = 1 end
          if ndest ~= INVALID and m.vertices[ndest].marker == 0 then m.vertices[ndest].marker = 1 end
        end
      end
    end
  end
end

-- --- sweep ---------------------------------------------------------------

local function sweep(m, infected)
  local killed = 0
  for tri = 1, m.n_tris do
    if infected[tri] and (m.triangles[tri].flags & 2) == 0 then
      for orient = 0, 2 do
        local here = otri_pack(tri, orient)
        local neighbor = m:sym(here)
        local nt = otri_tri(neighbor)
        if nt ~= DUMMY_TRI and not infected[nt] then
          m:dissolve(neighbor)
        end
      end
      m:kill_triangle(tri)
      killed = killed + 1
    end
  end
  return killed
end

-- --- driver --------------------------------------------------------------

function H.carve_holes(m, pslg, convex)
  local infected = {}
  local work = queue()
  if not convex then infect_hull(m, infected, work) end
  seed_holes(m, pslg, infected, work)
  plague(m, infected, work)
  return sweep(m, infected)
end

return H
