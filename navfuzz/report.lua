-- navfuzz/report.lua
--
-- Canonical, deterministic serialization of the pipeline outputs so a full
-- run produces byte-identical text on golua and lua5.5.0. Everything that is
-- order-unstable (triangle pools, region ids, BVH leaves) is sorted into a
-- canonical form; floats are emitted through a single fixed formatter.

local geom = require("geom")

local R = {}

local function fmtnum(x)
  if math.type(x) == "integer" then return string.format("%d", x) end
  if x == math.floor(x) and x < 9.007199254740992e15 and x > -9.007199254740992e15 then
    return string.format("%d", math.floor(x))
  end
  return string.format("%.6f", x)
end
R.fmtnum = fmtnum

local function sort3(a, b, c)
  if a > b then a, b = b, a end
  if b > c then b, c = c, b end
  if a > b then a, b = b, a end
  return a, b, c
end
R.sort3 = sort3

-- Canonical sorted list of triangle vertex triples.
function R.triangles_sorted(nav)
  local tris = {}
  for t = 1, nav:tcount() do
    local tri = nav.triangles[t]
    local a, b, c = sort3(tri.v[0], tri.v[1], tri.v[2])
    tris[#tris + 1] = { a, b, c }
  end
  table.sort(tris, function(x, y)
    if x[1] ~= y[1] then return x[1] < y[1] end
    if x[2] ~= y[2] then return x[2] < y[2] end
    return x[3] < y[3]
  end)
  return tris
end

-- Region sizes (triangle count per region), sorted by (size, region id).
function R.region_sizes(nav)
  local hist = {}
  for t = 1, nav:tcount() do
    local r = nav.triangles[t].region
    hist[r] = (hist[r] or 0) + 1
  end
  local out = {}
  for r, c in pairs(hist) do out[#out + 1] = { r, c } end
  table.sort(out, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] < b[1] end)
  return out
end

-- Total walkable area (sum of triangle areas) as twice-area (exact integer).
function R.area2(nav)
  local s = 0
  for t = 1, nav:tcount() do
    local tri = nav.triangles[t]
    s = s + geom.orient2d(nav.vertices[tri.v[0]], nav.vertices[tri.v[1]], nav.vertices[tri.v[2]])
  end
  return s
end

function R.navmesh(emit, nav)
  emit(string.format("navmesh: verts=%d tris=%d regions=%d area2=%s",
    nav:vcount(), nav:tcount(), nav.region_count, fmtnum(R.area2(nav))))
  emit(string.format("aabb: [%s,%s]..[%s,%s]",
    fmtnum(nav.aabb.min.x), fmtnum(nav.aabb.min.y),
    fmtnum(nav.aabb.max.x), fmtnum(nav.aabb.max.y)))
  for _, rc in ipairs(R.region_sizes(nav)) do
    emit(string.format("  region size %d", rc[2]))
  end
  for _, t in ipairs(R.triangles_sorted(nav)) do
    emit(string.format("  t %d %d %d", t[1], t[2], t[3]))
  end
end

-- Canonical pre-order BVH dump: depth-prefixed, integer AABBs, leaf triangle
-- lists sorted by canonical vertex triple.
function R.bvh(emit, idx, nav)
  local function box(node)
    return string.format("[%s,%s]..[%s,%s]",
      fmtnum(node.aabb.min.x), fmtnum(node.aabb.min.y),
      fmtnum(node.aabb.max.x), fmtnum(node.aabb.max.y))
  end
  emit(string.format("bvh: nodes=%d", #idx.nodes))
  if idx.root == 0 then return end
  local function walk(node_id, depth)
    local node = idx.nodes[node_id]
    local pad = string.rep("  ", depth)
    if node.leaf then
      local triples = {}
      for i = node.start, node.start + node.len - 1 do
        local tri = nav.triangles[idx.tri_index[i]]
        local a, b, c = sort3(tri.v[0], tri.v[1], tri.v[2])
        triples[#triples + 1] = { a, b, c }
      end
      table.sort(triples, function(x, y)
        if x[1] ~= y[1] then return x[1] < y[1] end
        if x[2] ~= y[2] then return x[2] < y[2] end
        return x[3] < y[3]
      end)
      local parts = {}
      for _, tr in ipairs(triples) do parts[#parts + 1] = string.format("(%d,%d,%d)", tr[1], tr[2], tr[3]) end
      emit(string.format("%sleaf %s {%s}", pad, box(node), table.concat(parts, " ")))
    else
      emit(string.format("%snode %s", pad, box(node)))
      walk(node.left, depth + 1)
      walk(node.right, depth + 1)
    end
  end
  walk(idx.root, 0)
end

function R.points(points)
  local parts = {}
  for i = 1, #points do
    parts[i] = string.format("(%s,%s)", fmtnum(points[i].x), fmtnum(points[i].y))
  end
  return table.concat(parts, " ")
end

function R.path(emit, label, res, err)
  if err then
    emit(string.format("path %s: %s", label, err))
  else
    local len = 0.0
    for i = 1, #res.points - 1 do len = len + geom.distance(res.points[i], res.points[i + 1]) end
    emit(string.format("path %s: corridor=%d waypoints=%d len=%.6f",
      label, #res.triangles, #res.points, len))
    emit("  " .. R.points(res.points))
  end
end

return R
