-- navfuzz/bvh.lua
--
-- BVH (AABB tree) spatial index over a NavMesh's triangles. Port of rsnav's
-- bsp crate: recursive longest-axis median-centroid split (LEAF_THRESHOLD=8),
-- with locate / nearest / query_aabb queries that prune by AABB.

local geom = require("geom")

local LEAF_THRESHOLD = 8

local Bvh = {}
Bvh.__index = Bvh

local B = {}

-- sort idx[lo..hi] in place by triangle centroid along axis (0=x,1=y)
local function sort_slice(nav, idx, lo, hi, axis)
  local tmp = {}
  local k = 0
  for i = lo, hi do k = k + 1; tmp[k] = idx[i] end
  if axis == 0 then
    table.sort(tmp, function(a, b) return nav.triangles[a].c.x < nav.triangles[b].c.x end)
  else
    table.sort(tmp, function(a, b) return nav.triangles[a].c.y < nav.triangles[b].c.y end)
  end
  for i = 1, k do idx[lo + i - 1] = tmp[i] end
end

function B.build(nav)
  local n = nav:tcount()
  local self = setmetatable({
    nodes = {},
    tri_index = {},
    tri_aabb = {},
    nav = nav,
    root = 0,
  }, Bvh)

  for t = 1, n do
    local tri = nav.triangles[t]
    self.tri_aabb[t] = geom.aabb_from_points({
      nav.vertices[tri.v[0]], nav.vertices[tri.v[1]], nav.vertices[tri.v[2]],
    })
  end

  if n == 0 then return self end

  -- working index array
  local idx = {}
  for t = 1, n do idx[t] = t end

  -- recursive build over idx[lo..hi]; returns node id
  local function build_sub(lo, hi)
    local box = geom.aabb_empty()
    for i = lo, hi do box = box:union(self.tri_aabb[idx[i]]) end
    local count = hi - lo + 1
    if count <= LEAF_THRESHOLD then
      local start = #self.tri_index + 1
      for i = lo, hi do self.tri_index[#self.tri_index + 1] = idx[i] end
      local node_id = #self.nodes + 1
      self.nodes[node_id] = { leaf = true, aabb = box, start = start, len = count }
      return node_id
    end
    local axis = (box:width() >= box:height()) and 0 or 1
    sort_slice(self.nav, idx, lo, hi, axis)
    local mid = lo + (count >> 1) - 1
    local left = build_sub(lo, mid)
    local right = build_sub(mid + 1, hi)
    local node_id = #self.nodes + 1
    self.nodes[node_id] = { leaf = false, aabb = box, left = left, right = right }
    return node_id
  end

  self.root = build_sub(1, n)
  return self
end

function Bvh:is_empty() return self.root == 0 end

-- --- locate(p) -> triangle id or nil -------------------------------------

local function locate_in(self, node_id, p)
  local node = self.nodes[node_id]
  if not node.aabb:contains(p) then return nil end
  if node.leaf then
    for i = node.start, node.start + node.len - 1 do
      local t = self.tri_index[i]
      if self.tri_aabb[t]:contains(p) then
        local tri = self.nav.triangles[t]
        local p0 = self.nav.vertices[tri.v[0]]
        local p1 = self.nav.vertices[tri.v[1]]
        local p2 = self.nav.vertices[tri.v[2]]
        if geom.point_in_triangle(p0, p1, p2, p) then return t end
      end
    end
    return nil
  end
  return locate_in(self, node.left, p) or locate_in(self, node.right, p)
end

function Bvh:locate(p)
  if self.root == 0 then return nil end
  return locate_in(self, self.root, p)
end

-- --- nearest(p) -> { triangle, point, distance } -------------------------

local function nearest_in(self, node_id, p, best)
  local node = self.nodes[node_id]
  if best.have and node.aabb:distance_to_point(p) >= best.distance then return end
  if node.leaf then
    for i = node.start, node.start + node.len - 1 do
      local t = self.tri_index[i]
      local tri = self.nav.triangles[t]
      local closest, d = geom.nearest_point_on_triangle(
        self.nav.vertices[tri.v[0]], self.nav.vertices[tri.v[1]], self.nav.vertices[tri.v[2]], p)
      if (not best.have) or d < best.distance then
        best.have = true
        best.triangle = t
        best.point = closest
        best.distance = d
      end
    end
    return
  end
  local ln = self.nodes[node.left]
  local rn = self.nodes[node.right]
  local dl = ln.aabb:distance_to_point(p)
  local dr = rn.aabb:distance_to_point(p)
  if dl <= dr then
    nearest_in(self, node.left, p, best)
    nearest_in(self, node.right, p, best)
  else
    nearest_in(self, node.right, p, best)
    nearest_in(self, node.left, p, best)
  end
end

function Bvh:nearest(p)
  if self.root == 0 then return nil end
  local best = { have = false, triangle = 0, point = nil, distance = math.huge }
  nearest_in(self, self.root, p, best)
  if not best.have then return nil end
  return { triangle = best.triangle, point = best.point, distance = best.distance }
end

-- --- query_aabb(box, visit) ----------------------------------------------

local function query_in(self, node_id, qbox, out)
  local node = self.nodes[node_id]
  if not node.aabb:intersects(qbox) then return end
  if node.leaf then
    for i = node.start, node.start + node.len - 1 do
      local t = self.tri_index[i]
      if self.tri_aabb[t]:intersects(qbox) then out[#out + 1] = t end
    end
    return
  end
  query_in(self, node.left, qbox, out)
  query_in(self, node.right, qbox, out)
end

function Bvh:query_aabb(qbox)
  local out = {}
  if self.root ~= 0 then query_in(self, self.root, qbox, out) end
  return out
end

B.Bvh = Bvh
return B
