-- navfuzz/divconq.lua
--
-- Divide-and-conquer Delaunay triangulation. Port of triangle.c's
-- divconqdelaunay / divconqrecurse / mergehulls / removeghosts via rsnav's
-- triangle/src/divconq.rs, with Dwyer alternating-axis cuts on by default.
--
-- Vertices are operated on through an index array `ids` over [lo,hi]
-- (1-based, inclusive) instead of Rust slices. `vertex_median` is a full
-- sort of the sub-range on the requested axis: after dedup all points have
-- distinct lexicographic keys, so the median partition (and therefore the
-- whole D&C subdivision) is uniquely determined and matches the reference
-- quickselect exactly.
--
-- While recursing, the convex hull of each partial triangulation is bounded
-- by a ring of ghost triangles whose apex is INVALID_VERTEX (0). removeghosts
-- frees them and points hull edges at the dummy triangle.

local mesh = require("mesh")
local geom = require("geom")

local lnext, lprev = mesh.lnext, mesh.lprev
local orient2d, incircle = geom.orient2d, geom.incircle
local INVALID = mesh.INVALID_VERTEX
local DUMMY_TRI = mesh.DUMMY_TRI

local D = {}

local function is_valid(v) return v ~= INVALID end

-- --- sorting -------------------------------------------------------------

-- lex compare positions pa,pb by axis (0: x primary, 1: y primary).
-- Returns true if pa < pb.
local function lex_lt(pa, pb, axis)
  local p1, s1, p2, s2
  if axis == 0 then p1, s1, p2, s2 = pa.x, pa.y, pb.x, pb.y
  else p1, s1, p2, s2 = pa.y, pa.x, pb.y, pb.x end
  if p1 ~= p2 then return p1 < p2 end
  return s1 < s2
end

-- Sort ids[lo..hi] in place by axis-lex order of the vertex positions.
local function sort_range(m, ids, lo, hi, axis)
  if hi <= lo then return end
  local tmp = {}
  local k = 0
  for i = lo, hi do k = k + 1; tmp[k] = ids[i] end
  local V = m.vertices
  table.sort(tmp, function(a, b) return lex_lt(V[a].pos, V[b].pos, axis) end)
  for i = 1, k do ids[lo + i - 1] = tmp[i] end
end

-- Recursive alternating-axis partition (triangle.c alternateaxes).
local function alternate_axes(m, ids, lo, hi, axis)
  local n = hi - lo + 1
  if n <= 1 then return end
  local eff_axis = (n <= 3) and 0 or axis
  -- partition at the median on eff_axis (full sort suffices: distinct keys)
  sort_range(m, ids, lo, hi, eff_axis)
  if n <= 3 then
    sort_range(m, ids, lo, hi, 0)
    return
  end
  local divider = n >> 1
  local lefthi = lo + divider - 1
  local rightlo = lo + divider
  alternate_axes(m, ids, lo, lefthi, 1 - axis)
  alternate_axes(m, ids, rightlo, hi, 1 - axis)
end

-- --- base cases ----------------------------------------------------------

-- Two vertices -> single edge bounded by two ghost triangles.
local function make_edge_pair(m, a, b)
  local farleft = m:make_triangle()
  m:set_org(farleft, a)
  m:set_dest(farleft, b)

  local farright = m:make_triangle()
  m:set_org(farright, b)
  m:set_dest(farright, a)

  m:bond(farleft, farright)
  farleft = lprev(farleft)
  farright = lnext(farright)
  m:bond(farleft, farright)
  farleft = lprev(farleft)
  farright = lnext(farright)
  m:bond(farleft, farright)

  farleft = lprev(farright)
  return farleft, farright
end

-- Three vertices -> one real triangle (or two edges if collinear).
local function make_triangle_or_edges(m, a, b, c)
  local midtri = m:make_triangle()
  local tri1 = m:make_triangle()
  local tri2 = m:make_triangle()
  local tri3 = m:make_triangle()

  local area = orient2d(m:vertex_pos(a), m:vertex_pos(b), m:vertex_pos(c))

  if area == 0.0 then
    -- collinear: two edges, four ghosts
    m:set_org(midtri, a); m:set_dest(midtri, b)
    m:set_org(tri1, b); m:set_dest(tri1, a)
    m:set_org(tri2, c); m:set_dest(tri2, b)
    m:set_org(tri3, b); m:set_dest(tri3, c)
    m:bond(midtri, tri1)
    m:bond(tri2, tri3)
    midtri = lnext(midtri); tri1 = lprev(tri1); tri2 = lnext(tri2); tri3 = lprev(tri3)
    m:bond(midtri, tri3)
    m:bond(tri1, tri2)
    midtri = lnext(midtri); tri1 = lprev(tri1); tri2 = lnext(tri2); tri3 = lprev(tri3)
    m:bond(midtri, tri1)
    m:bond(tri2, tri3)
    return tri1, tri2
  end

  m:set_org(midtri, a)
  m:set_dest(tri1, a)
  m:set_org(tri3, a)

  if area > 0.0 then
    m:set_dest(midtri, b); m:set_org(tri1, b); m:set_dest(tri2, b)
    m:set_apex(midtri, c); m:set_org(tri2, c); m:set_dest(tri3, c)
  else
    m:set_dest(midtri, c); m:set_org(tri1, c); m:set_dest(tri2, c)
    m:set_apex(midtri, b); m:set_org(tri2, b); m:set_dest(tri3, b)
  end

  m:bond(midtri, tri1)
  midtri = lnext(midtri)
  m:bond(midtri, tri2)
  midtri = lnext(midtri)
  m:bond(midtri, tri3)
  tri1 = lprev(tri1); tri2 = lnext(tri2)
  m:bond(tri1, tri2)
  tri1 = lprev(tri1); tri3 = lprev(tri3)
  m:bond(tri1, tri3)
  tri2 = lnext(tri2); tri3 = lprev(tri3)
  m:bond(tri2, tri3)

  local farleft = tri1
  local farright
  if area > 0.0 then farright = tri2 else farright = lnext(farleft) end
  return farleft, farright
end

-- --- mergehulls ----------------------------------------------------------

local function merge_hulls(m, farleft, innerleft, innerright, farright, axis, dwyer)
  local pos = function(v) return m.vertices[v].pos end

  local innerleftdest = m:dest(innerleft)
  local innerleftapex = m:apex(innerleft)
  local innerrightorg = m:org(innerright)
  local innerrightapex = m:apex(innerright)

  if dwyer and axis == 1 then
    local farleftpt = m:org(farleft)
    local farleftapex = m:apex(farleft)
    local farrightpt = m:dest(farright)
    local farrightapex = m:apex(farright)

    while is_valid(farleftapex) and pos(farleftapex).y < pos(farleftpt).y do
      farleft = lnext(farleft)
      farleft = m:sym(farleft)
      farleftpt = farleftapex
      farleftapex = m:apex(farleft)
    end
    local checkedge = m:sym(innerleft)
    local checkvertex = m:apex(checkedge)
    while is_valid(checkvertex) and pos(checkvertex).y > pos(innerleftdest).y do
      innerleft = lnext(checkedge)
      innerleftapex = innerleftdest
      innerleftdest = checkvertex
      checkedge = m:sym(innerleft)
      checkvertex = m:apex(checkedge)
    end
    while is_valid(innerrightapex) and pos(innerrightapex).y < pos(innerrightorg).y do
      innerright = lnext(innerright)
      innerright = m:sym(innerright)
      innerrightorg = innerrightapex
      innerrightapex = m:apex(innerright)
    end
    checkedge = m:sym(farright)
    checkvertex = m:apex(checkedge)
    while is_valid(checkvertex) and pos(checkvertex).y > pos(farrightpt).y do
      farright = lnext(checkedge)
      farrightapex = farrightpt
      farrightpt = checkvertex
      checkedge = m:sym(farright)
      checkvertex = m:apex(checkedge)
    end
  end

  -- Find a tangent line below both hulls.
  while true do
    local changemade = false
    if is_valid(innerleftapex) then
      if orient2d(pos(innerleftdest), pos(innerleftapex), pos(innerrightorg)) > 0.0 then
        innerleft = lprev(innerleft)
        innerleft = m:sym(innerleft)
        innerleftdest = innerleftapex
        innerleftapex = m:apex(innerleft)
        changemade = true
      end
    end
    if is_valid(innerrightapex) then
      if orient2d(pos(innerrightapex), pos(innerrightorg), pos(innerleftdest)) > 0.0 then
        innerright = lnext(innerright)
        innerright = m:sym(innerright)
        innerrightorg = innerrightapex
        innerrightapex = m:apex(innerright)
        changemade = true
      end
    end
    if not changemade then break end
  end

  local leftcand = m:sym(innerleft)
  local rightcand = m:sym(innerright)

  -- Bottom bounding triangle spanning the seam.
  local baseedge = m:make_triangle()
  m:bond(baseedge, innerleft)
  baseedge = lnext(baseedge)
  m:bond(baseedge, innerright)
  baseedge = lnext(baseedge)
  m:set_org(baseedge, innerrightorg)
  m:set_dest(baseedge, innerleftdest)

  local farleftpt = m:org(farleft)
  if innerleftdest == farleftpt then farleft = lnext(baseedge) end
  local farrightpt = m:dest(farright)
  if innerrightorg == farrightpt then farright = lprev(baseedge) end

  local lowerleft = innerleftdest
  local lowerright = innerrightorg
  local upperleft = m:apex(leftcand)
  local upperright = m:apex(rightcand)

  while true do
    local leftfinished = (not is_valid(upperleft))
      or orient2d(pos(upperleft), pos(lowerleft), pos(lowerright)) <= 0.0
    local rightfinished = (not is_valid(upperright))
      or orient2d(pos(upperright), pos(lowerleft), pos(lowerright)) <= 0.0

    if leftfinished and rightfinished then
      -- Top bounding triangle.
      local nextedge = m:make_triangle()
      m:set_org(nextedge, lowerleft)
      m:set_dest(nextedge, lowerright)
      m:bond(nextedge, baseedge)
      nextedge = lnext(nextedge)
      m:bond(nextedge, rightcand)
      nextedge = lnext(nextedge)
      m:bond(nextedge, leftcand)

      if dwyer and axis == 1 then
        local flpt = m:org(farleft)
        local flapex = m:apex(farleft)
        local frpt = m:dest(farright)
        local frapex = m:apex(farright)
        local checkedge = m:sym(farleft)
        local checkvertex = m:apex(checkedge)
        while is_valid(checkvertex) and pos(checkvertex).x < pos(flpt).x do
          farleft = lprev(checkedge)
          flapex = flpt
          flpt = checkvertex
          checkedge = m:sym(farleft)
          checkvertex = m:apex(checkedge)
        end
        while is_valid(frapex) and pos(frapex).x > pos(frpt).x do
          farright = lprev(farright)
          farright = m:sym(farright)
          frpt = frapex
          frapex = m:apex(farright)
        end
      end
      return farleft, farright
    end

    -- Eliminate edges from the left triangulation.
    if not leftfinished then
      local nextedge = lprev(leftcand)
      nextedge = m:sym(nextedge)
      local nextapex = m:apex(nextedge)
      if is_valid(nextapex) then
        local badedge = incircle(pos(lowerleft), pos(lowerright), pos(upperleft), pos(nextapex)) > 0.0
        while badedge do
          nextedge = lnext(nextedge)
          local topcasing = m:sym(nextedge)
          nextedge = lnext(nextedge)
          local sidecasing = m:sym(nextedge)
          m:bond(nextedge, topcasing)
          m:bond(leftcand, sidecasing)
          leftcand = lnext(leftcand)
          local outercasing = m:sym(leftcand)
          nextedge = lprev(nextedge)
          m:bond(nextedge, outercasing)

          m:set_org(leftcand, lowerleft)
          m:set_dest(leftcand, INVALID)
          m:set_apex(leftcand, nextapex)
          m:set_org(nextedge, INVALID)
          m:set_dest(nextedge, upperleft)
          m:set_apex(nextedge, nextapex)

          upperleft = nextapex
          nextedge = sidecasing
          nextapex = m:apex(nextedge)
          if is_valid(nextapex) then
            badedge = incircle(pos(lowerleft), pos(lowerright), pos(upperleft), pos(nextapex)) > 0.0
          else
            badedge = false
          end
        end
      end
    end

    -- Eliminate edges from the right triangulation.
    if not rightfinished then
      local nextedge = lnext(rightcand)
      nextedge = m:sym(nextedge)
      local nextapex = m:apex(nextedge)
      if is_valid(nextapex) then
        local badedge = incircle(pos(lowerleft), pos(lowerright), pos(upperright), pos(nextapex)) > 0.0
        while badedge do
          nextedge = lprev(nextedge)
          local topcasing = m:sym(nextedge)
          nextedge = lprev(nextedge)
          local sidecasing = m:sym(nextedge)
          m:bond(nextedge, topcasing)
          m:bond(rightcand, sidecasing)
          rightcand = lprev(rightcand)
          local outercasing = m:sym(rightcand)
          nextedge = lnext(nextedge)
          m:bond(nextedge, outercasing)

          m:set_org(rightcand, INVALID)
          m:set_dest(rightcand, lowerright)
          m:set_apex(rightcand, nextapex)
          m:set_org(nextedge, upperright)
          m:set_dest(nextedge, INVALID)
          m:set_apex(nextedge, nextapex)

          upperright = nextapex
          nextedge = sidecasing
          nextapex = m:apex(nextedge)
          if is_valid(nextapex) then
            badedge = incircle(pos(lowerleft), pos(lowerright), pos(upperright), pos(nextapex)) > 0.0
          else
            badedge = false
          end
        end
      end
    end

    -- Add the next gear tooth.
    local pick_right
    if leftfinished then
      pick_right = true
    elseif rightfinished then
      pick_right = false
    else
      pick_right = incircle(pos(upperleft), pos(lowerleft), pos(lowerright), pos(upperright)) > 0.0
    end

    if pick_right then
      m:bond(baseedge, rightcand)
      baseedge = lprev(rightcand)
      m:set_dest(baseedge, lowerleft)
      lowerright = upperright
      rightcand = m:sym(baseedge)
      upperright = m:apex(rightcand)
    else
      m:bond(baseedge, leftcand)
      baseedge = lnext(leftcand)
      m:set_org(baseedge, lowerright)
      lowerleft = upperleft
      leftcand = m:sym(baseedge)
      upperleft = m:apex(leftcand)
    end
  end
end

-- --- recursive driver ----------------------------------------------------

local function divconq_recurse(m, ids, lo, hi, axis, dwyer)
  local n = hi - lo + 1
  if n == 2 then
    return make_edge_pair(m, ids[lo], ids[lo + 1])
  end
  if n == 3 then
    return make_triangle_or_edges(m, ids[lo], ids[lo + 1], ids[lo + 2])
  end
  local divider = n >> 1
  local lefthi = lo + divider - 1
  local rightlo = lo + divider
  local farleft, innerleft = divconq_recurse(m, ids, lo, lefthi, 1 - axis, dwyer)
  local innerright, farright = divconq_recurse(m, ids, rightlo, hi, 1 - axis, dwyer)
  return merge_hulls(m, farleft, innerleft, innerright, farright, axis, dwyer)
end

-- --- removeghosts --------------------------------------------------------

local function remove_ghosts(m, start_ghost)
  local searchedge = lprev(start_ghost)
  searchedge = m:sym(searchedge)
  m.triangles[DUMMY_TRI].nbr[0] = searchedge

  local dissolveedge = start_ghost
  local hullsize = 0
  while true do
    hullsize = hullsize + 1
    local deadtriangle = lnext(dissolveedge)
    dissolveedge = lprev(dissolveedge)
    dissolveedge = m:sym(dissolveedge)
    m:dissolve(dissolveedge)
    local next_dissolve = m:sym(deadtriangle)
    m:kill_triangle(mesh.otri_tri(deadtriangle))
    dissolveedge = next_dissolve
    if dissolveedge == start_ghost then break end
  end
  return hullsize
end

-- --- public driver -------------------------------------------------------

-- Build a Delaunay triangulation of all vertices in the mesh pool, in place.
-- Returns the convex-hull edge count.
function D.delaunay(m, opts)
  local dwyer = true
  if opts and opts.dwyer ~= nil then dwyer = opts.dwyer end

  local nv = #m.vertices
  if nv < 2 then return 0 end

  local ids = {}
  for i = 1, nv do ids[i] = i end

  -- lex-sort by x then y
  sort_range(m, ids, 1, nv, 0)

  -- drop exact duplicate positions (consecutive after the sort)
  local V = m.vertices
  local compact = {}
  local cn = 0
  for i = 1, nv do
    local id = ids[i]
    if cn == 0 then
      cn = cn + 1; compact[cn] = id
    else
      local pa = V[compact[cn]].pos
      local pb = V[id].pos
      if not (pa.x == pb.x and pa.y == pb.y) then
        cn = cn + 1; compact[cn] = id
      end
    end
  end
  ids = compact
  local n = cn
  if n < 2 then return 0 end

  -- Dwyer re-sort: alternating-axes on the two halves, starting on y.
  if dwyer then
    local divider = n >> 1
    if n - divider >= 2 then
      if divider >= 2 then alternate_axes(m, ids, 1, divider, 1) end
      alternate_axes(m, ids, divider + 1, n, 1)
    end
  end

  local hullleft = divconq_recurse(m, ids, 1, n, 0, dwyer)
  local hull_size = remove_ghosts(m, hullleft)
  m.hull_size = hull_size
  return hull_size
end

-- Iterate live, fully-real triangles. Calls f(tri_index, slot).
function D.for_each_live(m, f)
  for i = 1, m.n_tris do
    local slot = m.triangles[i]
    if (slot.flags & 2) == 0 then -- not dead
      if slot.vtx[0] ~= INVALID and slot.vtx[1] ~= INVALID and slot.vtx[2] ~= INVALID then
        f(i, slot)
      end
    end
  end
end

return D
