-- navfuzz/navmesh.lua
--
-- Build the compact runtime NavMesh from a carved CdtMesh. Port of rsnav's
-- navmesh/src/build.rs (the in-memory structure, not the binary format).
--
-- A NavTriangle keeps CCW vertices, per-edge neighbour links, per-edge
-- constraint markers, centroid, area, and a connected-component region id.
-- Edge i is opposite vertex i, i.e. the edge (v[(i+1)%3], v[(i+2)%3]); its
-- neighbour nbr[i] is the triangle across it (0 = boundary). Two triangles
-- share a region iff reachable through neighbours without crossing a
-- constrained edge (edge_marker ~= 0).

local mesh = require("mesh")
local geom = require("geom")

local otri_pack, otri_tri = mesh.otri_pack, mesh.otri_tri
local osub_sub = mesh.osub_sub
local DUMMY_TRI, DUMMY_SUB = mesh.DUMMY_TRI, mesh.DUMMY_SUB
local INVALID = mesh.INVALID_VERTEX

local NavMesh = {}
NavMesh.__index = NavMesh

local N = {}

-- queue
local function queue() return { items = {}, head = 1, tail = 0 } end
local function qpush(q, x) q.tail = q.tail + 1; q.items[q.tail] = x end
local function qpop(q)
  if q.head > q.tail then return nil end
  local x = q.items[q.head]; q.items[q.head] = nil; q.head = q.head + 1; return x
end

-- Build a NavMesh from a carved CdtMesh.
function N.build(cdt)
  local cdt_to_nav = {}
  local live = {} -- ordered list of cdt tri indices that survive

  for tri = 1, cdt.n_tris do
    local slot = cdt.triangles[tri]
    if (slot.flags & 2) == 0 then -- not dead
      local v0, v1, v2 = slot.vtx[0], slot.vtx[1], slot.vtx[2]
      if v0 ~= INVALID and v1 ~= INVALID and v2 ~= INVALID then
        live[#live + 1] = tri
        cdt_to_nav[tri] = #live
      end
    end
  end

  -- compact vertex remap (only vertices used by survivors)
  local used_v = {}
  local nav_verts = {}
  local function map_vertex(cv)
    local nv = used_v[cv]
    if nv == nil then
      nv = #nav_verts + 1
      local p = cdt.vertices[cv].pos
      nav_verts[nv] = { x = p.x, y = p.y }
      used_v[cv] = nv
    end
    return nv
  end

  local triangles = {}
  for nav_id = 1, #live do
    local cdt_tri = live[nav_id]
    local slot = cdt.triangles[cdt_tri]
    local v0 = map_vertex(slot.vtx[0])
    local v1 = map_vertex(slot.vtx[1])
    local v2 = map_vertex(slot.vtx[2])

    local nbr, em = {}, {}
    for o = 0, 2 do
      local h = otri_pack(cdt_tri, o)
      local nb = cdt:sym(h)
      local nt = otri_tri(nb)
      nbr[o] = (nt == DUMMY_TRI) and 0 or (cdt_to_nav[nt] or 0)
      local sub = cdt:tspivot(h)
      if osub_sub(sub) == DUMMY_SUB then
        em[o] = 0
      else
        local mk = cdt:smarker(sub)
        em[o] = (mk ~= 0) and mk or 1
      end
    end

    local p0, p1, p2 = nav_verts[v0], nav_verts[v1], nav_verts[v2]
    local area2 = geom.orient2d(p0, p1, p2)
    triangles[nav_id] = {
      v = { [0] = v0, [1] = v1, [2] = v2 },
      nbr = nbr,
      em = em,
      c = { x = (p0.x + p1.x + p2.x) / 3, y = (p0.y + p1.y + p2.y) / 3 },
      area = area2 * 0.5,
      region = -1,
    }
  end

  -- connected-component region labelling (BFS, skipping constrained edges)
  local region_count = 0
  for seed = 1, #triangles do
    if triangles[seed].region < 0 then
      local me = region_count
      region_count = region_count + 1
      triangles[seed].region = me
      local q = queue()
      qpush(q, seed)
      while true do
        local t = qpop(q)
        if t == nil then break end
        local tri = triangles[t]
        for o = 0, 2 do
          if tri.em[o] == 0 then
            local nt = tri.nbr[o]
            if nt ~= 0 and triangles[nt].region < 0 then
              triangles[nt].region = me
              qpush(q, nt)
            end
          end
        end
      end
    end
  end

  local aabb = geom.aabb_from_points(nav_verts)

  return setmetatable({
    vertices = nav_verts,
    triangles = triangles,
    aabb = aabb,
    region_count = region_count,
  }, NavMesh)
end

-- --- accessors -----------------------------------------------------------

function NavMesh:vcount() return #self.vertices end
function NavMesh:tcount() return #self.triangles end
function NavMesh:vpos(id) return self.vertices[id] end
function NavMesh:tri(id) return self.triangles[id] end

-- endpoints (nav vertex ids) of edge o (0..2) of triangle t
function NavMesh:edge_verts(t, o)
  local tri = self.triangles[t]
  return tri.v[(o + 1) % 3], tri.v[(o + 2) % 3]
end

-- An edge is a wall if it is constrained or has no neighbour.
function NavMesh:is_wall_edge(t, o)
  local tri = self.triangles[t]
  return tri.nbr[o] == 0 or tri.em[o] ~= 0
end

N.NavMesh = NavMesh
return N
