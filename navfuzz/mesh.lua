-- navfuzz/mesh.lua
--
-- The CDT mesh: vertex / triangle / subsegment pools plus Shewchuk's
-- oriented-triangle (otri) and oriented-subsegment (osub) handle algebra.
-- Port of rsnav's triangle/src/mesh.rs.
--
-- A live handle is represented *as* its packed encoding -- a single Lua
-- integer -- exactly as triangle.c packs (orient) into the low bits of a
-- pointer. This keeps the otri navigation allocation-free and leans on
-- golua's 64-bit integer bit operations:
--
--   otri  enc = (tri << 2) | orient     -- orient in 0..2
--   osub  enc = (sub << 1) | orient     -- orient in 0..1
--
-- Triangle/subseg slot 0 is the reserved dummy ("no neighbour"); real
-- indices start at 1. Vertex ids are 1-based; 0 is INVALID.

local M = {}

-- --- mod-3 tables (indexed by orient 0..2) -------------------------------
local PLUS1 = { [0] = 1, [1] = 2, [2] = 0 }
local MINUS1 = { [0] = 2, [1] = 0, [2] = 1 }

local DUMMY_TRI = 0
local DUMMY_SUB = 0
local INVALID_VERTEX = 0

-- packed-handle dummies (tri 0 / sub 0, orient 0)
local DUMMY_TRI_ENC = 0
local DUMMY_SUB_ENC = 0

local FLAG_INFECTED = 1
local FLAG_TRI_DEAD = 2
local FLAG_SUB_DEAD = 1

local VertexType = { Input = 0, Segment = 1, Free = 2, Dead = 3, Undead = 4 }

-- --- handle helpers (free functions on packed integers) ------------------

local function otri_pack(tri, orient) return (tri << 2) | orient end
local function otri_tri(o) return o >> 2 end
local function otri_orient(o) return o & 3 end
local function lnext(o) return (o & ~3) | PLUS1[o & 3] end
local function lprev(o) return (o & ~3) | MINUS1[o & 3] end

local function osub_pack(sub, orient) return (sub << 1) | orient end
local function osub_sub(s) return s >> 1 end
local function osub_orient(s) return s & 1 end
local function ssym(s) return s ~ 1 end -- toggle the orient bit

-- --- CdtMesh -------------------------------------------------------------

local CdtMesh = {}
CdtMesh.__index = CdtMesh

local function tri_slot_fresh()
  return {
    nbr = { [0] = DUMMY_TRI_ENC, [1] = DUMMY_TRI_ENC, [2] = DUMMY_TRI_ENC },
    vtx = { [0] = INVALID_VERTEX, [1] = INVALID_VERTEX, [2] = INVALID_VERTEX },
    sub = { [0] = DUMMY_SUB_ENC, [1] = DUMMY_SUB_ENC, [2] = DUMMY_SUB_ENC },
    flags = 0,
  }
end

local function sub_slot_fresh()
  return {
    next = { [0] = DUMMY_SUB_ENC, [1] = DUMMY_SUB_ENC },
    subv = { [0] = INVALID_VERTEX, [1] = INVALID_VERTEX },
    segv = { [0] = INVALID_VERTEX, [1] = INVALID_VERTEX },
    tris = { [0] = DUMMY_TRI_ENC, [1] = DUMMY_TRI_ENC },
    marker = 0,
    flags = 0,
  }
end

local function new_mesh()
  local m = setmetatable({
    vertices = {},          -- [1..nv] = { pos = {x,y}, marker, vtype, triangle }
    triangles = { [0] = tri_slot_fresh() },
    subsegs = { [0] = sub_slot_fresh() },
    n_tris = 0,             -- highest real triangle index
    n_subs = 0,             -- highest real subseg index
    hull_size = 0,
    free_tris = {},
    free_subs = {},
  }, CdtMesh)
  return m
end

-- -- vertex pool --
function CdtMesh:push_vertex(pos, marker)
  local id = #self.vertices + 1
  self.vertices[id] = {
    pos = pos, marker = marker or 0, vtype = VertexType.Input, triangle = DUMMY_TRI_ENC,
  }
  return id
end

function CdtMesh:vertex(id) return self.vertices[id] end
function CdtMesh:vertex_pos(id) return self.vertices[id].pos end

-- -- triangle pool --
function CdtMesh:make_triangle()
  local idx = #self.free_tris
  local tri
  if idx > 0 then
    tri = self.free_tris[idx]
    self.free_tris[idx] = nil
    self.triangles[tri] = tri_slot_fresh()
  else
    self.n_tris = self.n_tris + 1
    tri = self.n_tris
    self.triangles[tri] = tri_slot_fresh()
  end
  return otri_pack(tri, 0)
end

function CdtMesh:kill_triangle(tri)
  local slot = self.triangles[tri]
  slot.flags = slot.flags | FLAG_TRI_DEAD
  self.free_tris[#self.free_tris + 1] = tri
end

function CdtMesh:triangle(tri) return self.triangles[tri] end
function CdtMesh:tri_is_dead(tri) return (self.triangles[tri].flags & FLAG_TRI_DEAD) ~= 0 end
function CdtMesh:tri_is_infected(tri) return (self.triangles[tri].flags & FLAG_INFECTED) ~= 0 end
function CdtMesh:set_infected(tri, on)
  local s = self.triangles[tri]
  if on then s.flags = s.flags | FLAG_INFECTED else s.flags = s.flags & ~FLAG_INFECTED end
end

function CdtMesh:live_triangle_count()
  return self.n_tris - #self.free_tris
end

-- -- subseg pool --
function CdtMesh:make_subseg()
  local idx = #self.free_subs
  local sub
  if idx > 0 then
    sub = self.free_subs[idx]
    self.free_subs[idx] = nil
    self.subsegs[sub] = sub_slot_fresh()
  else
    self.n_subs = self.n_subs + 1
    sub = self.n_subs
    self.subsegs[sub] = sub_slot_fresh()
  end
  return osub_pack(sub, 0)
end

function CdtMesh:kill_subseg(sub)
  local slot = self.subsegs[sub]
  slot.flags = slot.flags | FLAG_SUB_DEAD
  self.free_subs[#self.free_subs + 1] = sub
end

function CdtMesh:subseg(sub) return self.subsegs[sub] end
function CdtMesh:live_subseg_count() return self.n_subs - #self.free_subs end

-- --- triangle handle accessors -------------------------------------------

function CdtMesh:org(o) return self.triangles[o >> 2].vtx[PLUS1[o & 3]] end
function CdtMesh:dest(o) return self.triangles[o >> 2].vtx[MINUS1[o & 3]] end
function CdtMesh:apex(o) return self.triangles[o >> 2].vtx[o & 3] end

function CdtMesh:set_org(o, v) self.triangles[o >> 2].vtx[PLUS1[o & 3]] = v end
function CdtMesh:set_dest(o, v) self.triangles[o >> 2].vtx[MINUS1[o & 3]] = v end
function CdtMesh:set_apex(o, v) self.triangles[o >> 2].vtx[o & 3] = v end

function CdtMesh:set_corners(o, org, dest, apex)
  self:set_org(o, org); self:set_dest(o, dest); self:set_apex(o, apex)
end

-- sym(o): the abutting triangle through edge o (DUMMY if none).
function CdtMesh:sym(o) return self.triangles[o >> 2].nbr[o & 3] end

function CdtMesh:bond(a, b)
  self.triangles[a >> 2].nbr[a & 3] = b
  self.triangles[b >> 2].nbr[b & 3] = a
end

function CdtMesh:dissolve(o) self.triangles[o >> 2].nbr[o & 3] = DUMMY_TRI_ENC end

-- subseg <-> triangle gluing
function CdtMesh:tspivot(o) return self.triangles[o >> 2].sub[o & 3] end
function CdtMesh:tsbond(o, s)
  self.triangles[o >> 2].sub[o & 3] = s
  self.subsegs[s >> 1].tris[s & 1] = o
end
function CdtMesh:ts_dissolve(o) self.triangles[o >> 2].sub[o & 3] = DUMMY_SUB_ENC end
function CdtMesh:st_dissolve(s) self.subsegs[s >> 1].tris[s & 1] = DUMMY_TRI_ENC end
function CdtMesh:stpivot(s) return self.subsegs[s >> 1].tris[s & 1] end

-- --- subseg handle accessors ---------------------------------------------

function CdtMesh:sorg(s) return self.subsegs[s >> 1].subv[s & 1] end
function CdtMesh:sdest(s) return self.subsegs[s >> 1].subv[1 - (s & 1)] end
function CdtMesh:set_sorg(s, v) self.subsegs[s >> 1].subv[s & 1] = v end
function CdtMesh:set_sdest(s, v) self.subsegs[s >> 1].subv[1 - (s & 1)] = v end

function CdtMesh:segorg(s) return self.subsegs[s >> 1].segv[s & 1] end
function CdtMesh:segdest(s) return self.subsegs[s >> 1].segv[1 - (s & 1)] end
function CdtMesh:set_segorg(s, v) self.subsegs[s >> 1].segv[s & 1] = v end
function CdtMesh:set_segdest(s, v) self.subsegs[s >> 1].segv[1 - (s & 1)] = v end

function CdtMesh:set_smarker(s, marker) self.subsegs[s >> 1].marker = marker end
function CdtMesh:smarker(s) return self.subsegs[s >> 1].marker end

function CdtMesh:sbond(a, b)
  self.subsegs[a >> 1].next[a & 1] = b
  self.subsegs[b >> 1].next[b & 1] = a
end
function CdtMesh:spivot(s) return self.subsegs[s >> 1].next[s & 1] end

-- --- exports -------------------------------------------------------------

M.CdtMesh = CdtMesh
M.new = new_mesh
M.VertexType = VertexType
M.DUMMY_TRI = DUMMY_TRI
M.DUMMY_SUB = DUMMY_SUB
M.DUMMY_TRI_ENC = DUMMY_TRI_ENC
M.DUMMY_SUB_ENC = DUMMY_SUB_ENC
M.INVALID_VERTEX = INVALID_VERTEX
M.PLUS1 = PLUS1
M.MINUS1 = MINUS1

M.otri_pack = otri_pack
M.otri_tri = otri_tri
M.otri_orient = otri_orient
M.lnext = lnext
M.lprev = lprev
M.osub_pack = osub_pack
M.osub_sub = osub_sub
M.osub_orient = osub_orient
M.ssym = ssym

return M
