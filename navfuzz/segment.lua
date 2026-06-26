-- navfuzz/segment.lua
--
-- Segment insertion: force PSLG segments into the Delaunay triangulation.
-- Port of triangle.c's segment machinery via rsnav's triangle/src/segment.rs:
-- make_vertex_map, insert_subseg, find_direction, scout_segment (fast path),
-- delaunay_fixup, constrained_edge (slow flip-dig path), insert_segment, and
-- form_skeleton / mark_hull.
--
-- Where the Rust mutates a `&mut Otri`, this port threads the updated packed
-- handle back through the return values. Self-intersecting PSLG input (which
-- triangle.c handles with Steiner points) is not supported: it raises a
-- structured Lua error { kind = "self_intersection", ... } that form_skeleton's
-- caller can pcall. Valid simple polygons never trigger it.

local mesh = require("mesh")
local geom = require("geom")
local flip = require("flip")

local lnext, lprev = mesh.lnext, mesh.lprev
local otri_pack, otri_tri = mesh.otri_pack, mesh.otri_tri
local osub_sub, ssym = mesh.osub_sub, mesh.ssym
local orient2d, incircle = geom.orient2d, geom.incircle
local DUMMY_SUB, DUMMY_TRI = mesh.DUMMY_SUB, mesh.DUMMY_TRI
local INVALID = mesh.INVALID_VERTEX

local S = {}

local function serror(kind, a, b) error({ kind = kind, a = a, b = b }, 0) end

-- spin around the origin
local function onext(m, o) return m:sym(lprev(o)) end
local function oprev(m, o) return lnext(m:sym(o)) end

-- --- makevertexmap -------------------------------------------------------

function S.make_vertex_map(m)
  for tri = 1, m.n_tris do
    if (m.triangles[tri].flags & 2) == 0 then -- not dead
      for orient = 0, 2 do
        local h = otri_pack(tri, orient)
        local v = m:org(h)
        if v ~= INVALID then m.vertices[v].triangle = h end
      end
    end
  end
end

-- --- insertsubseg --------------------------------------------------------

local function insert_subseg(m, tri, subsegmark)
  local triorg = m:org(tri)
  local tridest = m:dest(tri)
  if triorg ~= INVALID and m.vertices[triorg].marker == 0 then m.vertices[triorg].marker = subsegmark end
  if tridest ~= INVALID and m.vertices[tridest].marker == 0 then m.vertices[tridest].marker = subsegmark end

  local existing = m:tspivot(tri)
  if osub_sub(existing) == DUMMY_SUB then
    local new_sub = m:make_subseg()
    m:set_sorg(new_sub, tridest)
    m:set_sdest(new_sub, triorg)
    m:set_segorg(new_sub, tridest)
    m:set_segdest(new_sub, triorg)
    m:tsbond(tri, new_sub)
    local oppotri = m:sym(tri)
    m:tsbond(oppotri, ssym(new_sub))
    m:set_smarker(new_sub, subsegmark)
  elseif m:smarker(existing) == 0 then
    m:set_smarker(existing, subsegmark)
  end
end

-- --- finddirection -------------------------------------------------------

-- Returns (dir, searchtri) where dir is "Within"/"LeftCollinear"/"RightCollinear".
local function find_direction(m, searchtri, searchpoint)
  local startvertex = m:org(searchtri)
  local rightvertex = m:dest(searchtri)
  local leftvertex = m:apex(searchtri)

  local sp = m:vertex_pos(searchpoint)
  local sv = m:vertex_pos(startvertex)

  local leftccw = orient2d(sp, sv, m:vertex_pos(leftvertex))
  local leftflag = leftccw > 0.0
  local rightccw = orient2d(sv, sp, m:vertex_pos(rightvertex))
  local rightflag = rightccw > 0.0

  if leftflag and rightflag then
    local checktri = onext(m, searchtri)
    if otri_tri(checktri) == DUMMY_TRI then leftflag = false else rightflag = false end
  end
  while leftflag do
    searchtri = onext(m, searchtri)
    leftvertex = m:apex(searchtri)
    rightccw = leftccw
    leftccw = orient2d(sp, sv, m:vertex_pos(leftvertex))
    leftflag = leftccw > 0.0
  end
  while rightflag do
    searchtri = oprev(m, searchtri)
    rightvertex = m:dest(searchtri)
    leftccw = rightccw
    rightccw = orient2d(sv, sp, m:vertex_pos(rightvertex))
    rightflag = rightccw > 0.0
  end

  if leftccw == 0.0 then return "LeftCollinear", searchtri
  elseif rightccw == 0.0 then return "RightCollinear", searchtri
  else return "Within", searchtri end
end
S.find_direction = find_direction

-- --- scoutsegment --------------------------------------------------------

-- Returns (inserted, searchtri). inserted=false => caller digs from searchtri.
local function scout_segment(m, searchtri, endpoint2, newmark)
  local endpoint1 = m:org(searchtri)
  local collinear
  collinear, searchtri = find_direction(m, searchtri, endpoint2)
  local rightvertex = m:dest(searchtri)
  local leftvertex = m:apex(searchtri)

  local ep2 = m:vertex_pos(endpoint2)
  local lvp = m:vertex_pos(leftvertex)
  local rvp = m:vertex_pos(rightvertex)
  local left_is = (lvp.x == ep2.x and lvp.y == ep2.y)
  local right_is = (rvp.x == ep2.x and rvp.y == ep2.y)

  if left_is or right_is then
    if left_is then searchtri = lprev(searchtri) end
    insert_subseg(m, searchtri, newmark)
    return true, searchtri
  end

  if collinear == "LeftCollinear" then
    searchtri = lprev(searchtri)
    insert_subseg(m, searchtri, newmark)
    return scout_segment(m, searchtri, endpoint2, newmark)
  elseif collinear == "RightCollinear" then
    insert_subseg(m, searchtri, newmark)
    searchtri = lnext(searchtri)
    return scout_segment(m, searchtri, endpoint2, newmark)
  else -- Within
    local crosstri = lnext(searchtri)
    local crosssubseg = m:tspivot(crosstri)
    if osub_sub(crosssubseg) == DUMMY_SUB then
      return false, searchtri
    else
      serror("self_intersection", endpoint1, endpoint2)
    end
  end
end
S.scout_segment = scout_segment

-- --- delaunayfixup -------------------------------------------------------

-- Returns the (possibly updated) fixuptri handle.
local function delaunay_fixup(m, fixuptri, leftside)
  local neartri = lnext(fixuptri)
  local fartri = m:sym(neartri)
  if otri_tri(fartri) == DUMMY_TRI then return fixuptri end
  local faredge = m:tspivot(neartri)
  if osub_sub(faredge) ~= DUMMY_SUB then return fixuptri end

  local nearvertex = m:apex(neartri)
  local leftvertex = m:org(neartri)
  local rightvertex = m:dest(neartri)
  local farvertex = m:apex(fartri)

  local lv = m:vertex_pos(leftvertex)
  local rv = m:vertex_pos(rightvertex)
  local nv = m:vertex_pos(nearvertex)
  local fv = m:vertex_pos(farvertex)

  if leftside then
    if orient2d(nv, lv, fv) <= 0.0 then return fixuptri end
  else
    if orient2d(fv, rv, nv) <= 0.0 then return fixuptri end
  end

  if orient2d(rv, lv, fv) > 0.0 then
    if incircle(lv, fv, rv, nv) <= 0.0 then return fixuptri end
  end

  flip.flip(m, neartri)
  fixuptri = lprev(fixuptri)
  fixuptri = delaunay_fixup(m, fixuptri, leftside)
  delaunay_fixup(m, fartri, leftside)
  return fixuptri
end
S.delaunay_fixup = delaunay_fixup

-- --- constrainededge -----------------------------------------------------

local function constrained_edge(m, starttri, endpoint2, newmark)
  local endpoint1 = m:org(starttri)
  local ep1 = m:vertex_pos(endpoint1)
  local ep2 = m:vertex_pos(endpoint2)

  local fixuptri = lnext(starttri)
  flip.flip(m, fixuptri)

  local collision = false
  local done = false
  while not done do
    local farvertex = m:org(fixuptri)
    local fv = m:vertex_pos(farvertex)

    if fv.x == ep2.x and fv.y == ep2.y then
      local fixuptri2 = oprev(m, fixuptri)
      fixuptri = delaunay_fixup(m, fixuptri, false)
      delaunay_fixup(m, fixuptri2, true)
      done = true
    else
      local area = orient2d(ep1, ep2, fv)
      if area == 0.0 then
        collision = true
        local fixuptri2 = oprev(m, fixuptri)
        fixuptri = delaunay_fixup(m, fixuptri, false)
        delaunay_fixup(m, fixuptri2, true)
        done = true
      else
        if area > 0.0 then
          local fixuptri2 = oprev(m, fixuptri)
          delaunay_fixup(m, fixuptri2, true)
          fixuptri = lprev(fixuptri)
        else
          fixuptri = delaunay_fixup(m, fixuptri, false)
          fixuptri = oprev(m, fixuptri)
        end
        local crosssubseg = m:tspivot(fixuptri)
        if osub_sub(crosssubseg) == DUMMY_SUB then
          flip.flip(m, fixuptri)
        else
          serror("self_intersection", endpoint1, endpoint2)
        end
      end
    end
  end

  insert_subseg(m, fixuptri, newmark)

  if collision then
    local inserted
    inserted, fixuptri = scout_segment(m, fixuptri, endpoint2, newmark)
    if not inserted then
      constrained_edge(m, fixuptri, endpoint2, newmark)
    end
  end
end
S.constrained_edge = constrained_edge

-- --- locate / insertsegment ----------------------------------------------

local function locate_vertex(m, v)
  local encoded = m.vertices[v].triangle
  if otri_tri(encoded) ~= DUMMY_TRI then
    local base_tri = otri_tri(encoded)
    local base_or = mesh.otri_orient(encoded)
    for off = 0, 2 do
      local candidate = otri_pack(base_tri, (base_or + off) % 3)
      if m:org(candidate) == v then return candidate end
    end
  end
  for tri = 1, m.n_tris do
    if (m.triangles[tri].flags & 2) == 0 then
      for orient = 0, 2 do
        local h = otri_pack(tri, orient)
        if m:org(h) == v then
          m.vertices[v].triangle = h
          return h
        end
      end
    end
  end
  serror("vertex_not_in_triangulation", v, v)
end

local function insert_segment(m, endpoint1, endpoint2, newmark)
  local searchtri1 = locate_vertex(m, endpoint1)
  local inserted
  inserted, searchtri1 = scout_segment(m, searchtri1, endpoint2, newmark)
  if not inserted then
    local searchtri2 = locate_vertex(m, endpoint2)
    local ins2
    ins2, searchtri2 = scout_segment(m, searchtri2, endpoint1, newmark)
    if ins2 then return end
    constrained_edge(m, searchtri1, endpoint2, newmark)
  end
end
S.insert_segment = insert_segment

-- --- markhull ------------------------------------------------------------

local function mark_hull(m, marker)
  local hulltri = m:sym(otri_pack(DUMMY_TRI, 0))
  if otri_tri(hulltri) == DUMMY_TRI then return end
  local starttri = hulltri
  while true do
    insert_subseg(m, hulltri, marker)
    hulltri = lnext(hulltri)
    local nexttri = oprev(m, hulltri)
    while otri_tri(nexttri) ~= DUMMY_TRI do
      hulltri = nexttri
      nexttri = oprev(m, hulltri)
    end
    if hulltri == starttri then break end
  end
end
S.mark_hull = mark_hull

-- --- formskeleton --------------------------------------------------------

-- position -> first-occurrence vertex id (canonical remap around the
-- duplicates that delaunay() drops from the working set).
local function canonical_remap(m)
  local by_pos = {}
  local remap = {}
  for i = 1, #m.vertices do
    local p = m.vertices[i].pos
    local key = string.format("%a,%a", p.x + 0.0, p.y + 0.0)
    local canonical = by_pos[key]
    if canonical == nil then canonical = i; by_pos[key] = i end
    remap[i] = canonical
  end
  return remap
end

-- pslg.segments: array of { a = id, b = id, marker = int } using 1-based mesh
-- vertex ids. mark_hull_with: boundary marker for hull edges, or nil.
function S.form_skeleton(m, pslg, mark_hull_with)
  S.make_vertex_map(m)
  local remap = canonical_remap(m)
  for _, seg in ipairs(pslg.segments) do
    local a = remap[seg.a]
    local b = remap[seg.b]
    if a == nil or b == nil then
      serror("vertex_not_in_triangulation", seg.a, seg.b)
    end
    if a ~= b then
      insert_segment(m, a, b, seg.marker or 0)
    end
  end
  if mark_hull_with ~= nil then
    mark_hull(m, mark_hull_with)
  end
end

return S
