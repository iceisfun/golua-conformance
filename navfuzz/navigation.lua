-- navfuzz/navigation.lua
--
-- Runtime navigation queries over a NavMesh: the wall oracle, A* (triangle
-- graph with portal-crossing cost), the Simple Stupid Funnel string-pull
-- (with optional wall inset), line-of-sight, and the find_path / nearest
-- conveniences. Port of rsnav's navigation crate (wall.rs, astar.rs,
-- funnel.rs, los.rs, path.rs).
--
-- All step costs use math.sqrt of integer/float coordinates; IEEE-754 sqrt
-- and +,-,*,/ are bit-deterministic, so A*'s frontier ordering and the
-- funnel waypoints are identical on golua and lua5.5.0. With
-- distance_from_wall = 0 the funnel waypoints are a subset of the (integer)
-- mesh vertices.

local geom = require("geom")
local orient2d = geom.orient2d
local distance = geom.distance
local nearest_point_on_segment = geom.nearest_point_on_segment
local point_in_triangle = geom.point_in_triangle
local segment_intersection = geom.segment_intersection

local Nav = {}

-- --- WallInfo ------------------------------------------------------------

local WallInfo = {}
WallInfo.__index = WallInfo

function Nav.wall_info(nav)
  local wall_vertex = {}
  for v = 1, nav:vcount() do wall_vertex[v] = false end
  for t = 1, nav:tcount() do
    for i = 0, 2 do
      if nav:is_wall_edge(t, i) then
        local va, vb = nav:edge_verts(t, i)
        wall_vertex[va] = true
        wall_vertex[vb] = true
      end
    end
  end
  return setmetatable({ nav = nav, wall_vertex = wall_vertex }, WallInfo)
end

function WallInfo:is_wall_vertex(v) return self.wall_vertex[v] end
function WallInfo:is_wall_edge(t, o) return self.nav:is_wall_edge(t, o) end

-- --- binary min-heap (key = f, tie-break = triangle id) ------------------

local function heap_lt(a, b)
  if a.f ~= b.f then return a.f < b.f end
  return a.tri < b.tri
end

local function heap_push(h, tri, f)
  local n = #h + 1
  h[n] = { tri = tri, f = f }
  while n > 1 do
    local p = n >> 1
    if heap_lt(h[n], h[p]) then h[n], h[p] = h[p], h[n]; n = p else break end
  end
end

local function heap_pop(h)
  local n = #h
  if n == 0 then return nil end
  local top = h[1]
  h[1] = h[n]; h[n] = nil; n = n - 1
  local i = 1
  while true do
    local l, r = i << 1, (i << 1) | 1
    local s = i
    if l <= n and heap_lt(h[l], h[s]) then s = l end
    if r <= n and heap_lt(h[r], h[s]) then s = r end
    if s == i then break end
    h[i], h[s] = h[s], h[i]
    i = s
  end
  return top.tri
end

-- --- A* ------------------------------------------------------------------

local function reconstruct(came, start, goal)
  local rev = {}
  local cur = goal
  while cur ~= start do
    rev[#rev + 1] = cur
    cur = came[cur]
    if cur == 0 then break end
  end
  rev[#rev + 1] = start
  local out = {}
  for i = #rev, 1, -1 do out[#out + 1] = rev[i] end
  return out
end

-- Returns a triangle-id corridor, or nil if unreachable.
local function astar(nav, walls, start, goal, start_point, goal_point, min_portal_width)
  local n = nav:tcount()
  local g, came, entry, closed = {}, {}, {}, {}
  for i = 1, n do g[i] = math.huge; came[i] = 0; closed[i] = false end
  g[start] = 0.0
  entry[start] = start_point

  local heap = {}
  heap_push(heap, start, distance(start_point, goal_point))

  while true do
    local tri_id = heap_pop(heap)
    if tri_id == nil then break end
    if tri_id == goal then return reconstruct(came, start, goal) end
    if not closed[tri_id] then
      closed[tri_id] = true
      local tri = nav.triangles[tri_id]
      local cur_entry = entry[tri_id]
      for edge = 0, 2 do
        if not walls:is_wall_edge(tri_id, edge) then
          local va, vb = nav:edge_verts(tri_id, edge)
          local pa, pb = nav.vertices[va], nav.vertices[vb]
          local pass = true
          if min_portal_width > 0.0 then
            local needed = (walls:is_wall_vertex(va) and min_portal_width or 0.0)
              + (walls:is_wall_vertex(vb) and min_portal_width or 0.0)
            if distance(pa, pb) <= needed then pass = false end
          end
          if pass then
            local neighbor = tri.nbr[edge]
            if neighbor ~= 0 and not closed[neighbor] then
              local crossing = nearest_point_on_segment(pa, pb, cur_entry)
              local step_cost = distance(cur_entry, crossing)
              local h
              if neighbor == goal then
                step_cost = step_cost + distance(crossing, goal_point); h = 0.0
              else
                h = distance(crossing, goal_point)
              end
              local tentative = g[tri_id] + step_cost
              if tentative < g[neighbor] then
                g[neighbor] = tentative
                came[neighbor] = tri_id
                entry[neighbor] = crossing
                heap_push(heap, neighbor, tentative + h)
              end
            end
          end
        end
      end
    end
  end
  return nil
end
Nav.astar = astar

-- --- funnel --------------------------------------------------------------

local function oriented_portal(nav, walls, from, to, dfw)
  local t_from = nav.triangles[from]
  local i = nil
  for e = 0, 2 do if t_from.nbr[e] == to then i = e; break end end
  if i == nil then return nil end
  local va = t_from.v[(i + 1) % 3]
  local vb = t_from.v[(i + 2) % 3]
  local pa, pb = nav.vertices[va], nav.vertices[vb]

  local from_c = t_from.c
  local to_c = nav.triangles[to].c
  local left_v, right_v, left_p, right_p
  if orient2d(from_c, to_c, pa) > 0.0 then
    left_v, right_v, left_p, right_p = va, vb, pa, pb
  else
    left_v, right_v, left_p, right_p = vb, va, pb, pa
  end

  if dfw <= 0.0 then return left_p, right_p end
  local len = distance(left_p, right_p)
  if len == 0.0 then return left_p, right_p end
  local raw_l = walls:is_wall_vertex(left_v) and dfw or 0.0
  local raw_r = walls:is_wall_vertex(right_v) and dfw or 0.0
  local total = raw_l + raw_r
  local sl, sr
  if total <= len then sl, sr = raw_l, raw_r else local s = len / total; sl, sr = raw_l * s, raw_r * s end
  local dx, dy = (right_p.x - left_p.x) / len, (right_p.y - left_p.y) / len
  return { x = left_p.x + dx * sl, y = left_p.y + dy * sl },
    { x = right_p.x - dx * sr, y = right_p.y - dy * sr }
end

local function tri_area2(a, b, c)
  return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
end

local function veq(a, b) return a.x == b.x and a.y == b.y end

local function string_pull(portals)
  if #portals == 0 then return {} end
  local path = {}
  local apex = portals[1][1]
  local left = portals[1][1]
  local right = portals[1][2]
  local apex_i, left_i, right_i = 1, 1, 1
  path[#path + 1] = apex

  local i = 2
  while i <= #portals do
    local p_left = portals[i][1]
    local p_right = portals[i][2]

    -- right side
    if tri_area2(apex, right, p_right) >= 0.0 then
      if veq(apex, right) or tri_area2(apex, left, p_right) < 0.0 then
        right = p_right; right_i = i
      else
        if not veq(path[#path], left) then path[#path + 1] = left end
        apex = left; apex_i = left_i
        left = apex; right = apex; left_i = apex_i; right_i = apex_i
        i = apex_i + 1
        goto continue
      end
    end

    -- left side
    if tri_area2(apex, left, p_left) <= 0.0 then
      if veq(apex, left) or tri_area2(apex, right, p_left) > 0.0 then
        left = p_left; left_i = i
      else
        if not veq(path[#path], right) then path[#path + 1] = right end
        apex = right; apex_i = right_i
        left = apex; right = apex; left_i = apex_i; right_i = apex_i
        i = apex_i + 1
        goto continue
      end
    end

    i = i + 1
    ::continue::
  end

  local goal = portals[#portals][1]
  if not veq(path[#path], goal) then path[#path + 1] = goal end
  return path
end
Nav.string_pull = string_pull

local function funnel(nav, walls, triangles, start, goal, dfw)
  if #triangles == 0 then return { start, goal } end
  local portals = {}
  portals[1] = { start, start }
  for i = 1, #triangles - 1 do
    local left, right = oriented_portal(nav, walls, triangles[i], triangles[i + 1], dfw)
    if left then portals[#portals + 1] = { left, right } end
  end
  portals[#portals + 1] = { goal, goal }
  return string_pull(portals)
end
Nav.funnel = funnel

-- --- line of sight -------------------------------------------------------

-- Returns (status, point) where status is "Clear"/"Blocked"/"Indeterminate".
local function line_of_sight(nav, walls, start_tri, from, to)
  local cur = start_tri
  local max_steps = nav:tcount() * 2 + 4
  for _ = 1, max_steps do
    local tri = nav.triangles[cur]
    local p0, p1, p2 = nav.vertices[tri.v[0]], nav.vertices[tri.v[1]], nav.vertices[tri.v[2]]
    if point_in_triangle(p0, p1, p2, to) then return "Clear" end

    local best_edge, best_pt, best_t = nil, nil, nil
    for edge = 0, 2 do
      local va, vb = nav:edge_verts(cur, edge)
      local pa, pb = nav.vertices[va], nav.vertices[vb]
      local hit, t = segment_intersection(from, to, pa, pb)
      if hit and t >= -1e-9 then
        if best_t == nil or t > best_t then best_edge, best_pt, best_t = edge, hit, t end
      end
    end
    if best_edge == nil then return "Indeterminate" end
    if walls:is_wall_edge(cur, best_edge) then return "Blocked", best_pt end
    local neighbor = tri.nbr[best_edge]
    if neighbor == 0 then return "Blocked", best_pt end
    cur = neighbor
  end
  return "Indeterminate"
end
Nav.line_of_sight = line_of_sight

-- --- conveniences --------------------------------------------------------

-- Returns (result, err). result = { points = {...}, triangles = {...} }.
function Nav.find_path(nav, bvh, start, goal, opts)
  local dfw = (opts and opts.distance_from_wall) or 0.0
  local walls = (opts and opts.walls) or Nav.wall_info(nav)
  local start_tri = bvh:locate(start)
  if start_tri == nil then return nil, "StartOutsideMesh" end
  local goal_tri = bvh:locate(goal)
  if goal_tri == nil then return nil, "GoalOutsideMesh" end
  local corridor = astar(nav, walls, start_tri, goal_tri, start, goal, dfw)
  if corridor == nil then return nil, "Unreachable" end
  local points = funnel(nav, walls, corridor, start, goal, dfw)
  return { points = points, triangles = corridor }, nil
end

function Nav.nearest_point(nav, bvh, p)
  return bvh:nearest(p)
end

Nav.WallInfo = WallInfo
return Nav
