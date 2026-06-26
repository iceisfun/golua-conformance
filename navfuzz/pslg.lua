-- navfuzz/pslg.lua
--
-- PSLG type + bitfield polygon-extraction. Ports rsnav's polygon-extract
-- crate (border-edge tracing with 4-connectivity same-cell disambiguation,
-- outer/hole classification by signed area, smallest-enclosing nesting,
-- remove_collinear) and the rsnav_common Polygon helpers it relies on.
--
-- A bitfield is row-major: true = walkable, false = wall. Cell (col,row)
-- occupies [col,col+1] x [row,row+1] with y up. Outer rings come out CCW,
-- holes CW -- exactly what the CDT + hole carver expect. Every coordinate
-- is an integer grid corner, keeping the downstream predicates exact.
--
-- Diagonal smoothing (the reference's optional stair-step collapse) is not
-- ported; remove_collinear is, and is on by default.

local geom = require("geom")
local orient2d = geom.orient2d

local P = {}

-- --- Bitfield ------------------------------------------------------------

local Bitfield = {}
Bitfield.__index = Bitfield

function P.bitfield(width, height, data)
  assert(#data == width * height, "bitfield data length mismatch")
  return setmetatable({ width = width, height = height, data = data }, Bitfield)
end

-- Build a bitfield from ascii rows given top-down ('#'=walkable, '.'=wall).
function P.bitfield_from_rows(width, rows)
  local height = #rows
  local data = {}
  for i = 1, width * height do data[i] = false end
  for i = 1, height do
    local math_row = height - i -- flip to y-up (0-based math row)
    local row = rows[i]
    for col = 0, width - 1 do
      local ch = row:sub(col + 1, col + 1)
      data[math_row * width + col + 1] = (ch == "#")
    end
  end
  return P.bitfield(width, height, data)
end

function Bitfield:at(col, row)
  if col < 0 or row < 0 or col >= self.width or row >= self.height then return false end
  return self.data[row * self.width + col + 1]
end

-- --- Polygon helpers (on lists of {x=,y=}) -------------------------------

local function signed_area2(verts)
  local n = #verts
  if n < 3 then return 0.0 end
  local sum = 0.0
  for i = 1, n do
    local a = verts[i]
    local b = verts[(i % n) + 1]
    sum = sum + (a.x * b.y - b.x * a.y)
  end
  return sum
end

local function on_segment_collinear(a, b, p)
  return p.x >= math.min(a.x, b.x) and p.x <= math.max(a.x, b.x)
    and p.y >= math.min(a.y, b.y) and p.y <= math.max(a.y, b.y)
end

-- Ray-cast point-in-polygon; boundary counts as inside.
local function poly_contains(verts, p)
  local n = #verts
  if n < 3 then return false end
  local inside = false
  local j = n
  for i = 1, n do
    local vi = verts[i]
    local vj = verts[j]
    if orient2d(vi, vj, p) == 0.0 and on_segment_collinear(vi, vj, p) then
      return true
    end
    if (vi.y > p.y) ~= (vj.y > p.y)
      and p.x < (vj.x - vi.x) * (p.y - vi.y) / (vj.y - vi.y) + vi.x then
      inside = not inside
    end
    j = i
  end
  return inside
end

-- Remove vertices collinear with their neighbours (iterated to a fixpoint).
local function remove_collinear(verts)
  while true do
    local n = #verts
    if n < 3 then return verts end
    local cleaned = {}
    for i = 1, n do
      local prev = verts[(i + n - 2) % n + 1]
      local cur = verts[i]
      local nxt = verts[i % n + 1]
      if orient2d(prev, cur, nxt) ~= 0.0 then
        cleaned[#cleaned + 1] = cur
      end
    end
    if #cleaned == n then return verts end
    verts = cleaned
  end
end

P.signed_area2 = signed_area2
P.poly_contains = poly_contains
P.remove_collinear = remove_collinear

-- --- border-edge tracing -------------------------------------------------

local function collect_border_edges(bits)
  local edges = {}
  local w, h = bits.width, bits.height
  for row = 0, h - 1 do
    for col = 0, w - 1 do
      if bits:at(col, row) then
        local cell = row * w + col
        if not bits:at(col, row - 1) then
          edges[#edges + 1] = { sx = col, sy = row, ex = col + 1, ey = row, cell = cell }
        end
        if not bits:at(col + 1, row) then
          edges[#edges + 1] = { sx = col + 1, sy = row, ex = col + 1, ey = row + 1, cell = cell }
        end
        if not bits:at(col, row + 1) then
          edges[#edges + 1] = { sx = col + 1, sy = row + 1, ex = col, ey = row + 1, cell = cell }
        end
        if not bits:at(col - 1, row) then
          edges[#edges + 1] = { sx = col, sy = row + 1, ex = col, ey = row, cell = cell }
        end
      end
    end
  end
  return edges
end

local function ckey(x, y) return x .. "," .. y end

local function trace_loops(bits)
  local edges = collect_border_edges(bits)
  if #edges == 0 then return {} end

  local by_start = {}
  for i = 1, #edges do
    local k = ckey(edges[i].sx, edges[i].sy)
    local lst = by_start[k]
    if lst == nil then lst = {}; by_start[k] = lst end
    lst[#lst + 1] = i
  end

  local visited = {}
  local loops = {}

  for seed = 1, #edges do
    if not visited[seed] then
      local loop_verts = {}
      local cur = seed
      local abandon = false
      while true do
        visited[cur] = true
        local e = edges[cur]
        loop_verts[#loop_verts + 1] = { x = e.sx, y = e.sy }
        local candidates = by_start[ckey(e.ex, e.ey)]
        if candidates == nil then abandon = true; break end
        local nxt
        if #candidates == 1 then
          nxt = candidates[1]
        else
          for _, j in ipairs(candidates) do
            if edges[j].cell == e.cell then nxt = j; break end
          end
        end
        if nxt == nil then abandon = true; break end
        if nxt == seed then break end
        cur = nxt
      end
      if not abandon then loops[#loops + 1] = loop_verts end
    end
  end
  return loops
end

-- --- extract -------------------------------------------------------------

-- Returns a list of regions: { outer = ring, holes = { ring, ... } }.
-- Each ring is a list of {x,y}. opts.remove_collinear (default true),
-- opts.min_area (default 0).
function P.extract(bits, opts)
  opts = opts or {}
  local do_rc = opts.remove_collinear ~= false
  local min_area = opts.min_area or 0.0

  local loops = trace_loops(bits)
  local outers, holes = {}, {}
  for _, lp in ipairs(loops) do
    if signed_area2(lp) > 0.0 then outers[#outers + 1] = lp else holes[#holes + 1] = lp end
  end

  local outer_holes = {}
  for i = 1, #outers do outer_holes[i] = {} end

  for _, hole in ipairs(holes) do
    local sample = hole[1]
    local best, best_area = nil, nil
    for i = 1, #outers do
      if poly_contains(outers[i], sample) then
        local a = math.abs(signed_area2(outers[i])) * 0.5
        if best == nil or a < best_area then best, best_area = i, a end
      end
    end
    if best ~= nil then
      outer_holes[best][#outer_holes[best] + 1] = hole
    end
  end

  local regions = {}
  for i = 1, #outers do
    local outer = outers[i]
    local hs = {}
    for _, h in ipairs(outer_holes[i]) do
      hs[#hs + 1] = do_rc and remove_collinear(h) or h
    end
    if do_rc then outer = remove_collinear(outer) end
    local area = math.abs(signed_area2(outer)) * 0.5
    if area >= min_area then
      regions[#regions + 1] = { outer = outer, holes = hs }
    end
  end
  return regions
end

-- --- PSLG construction ---------------------------------------------------

-- Find a strictly-interior point of a (rectilinear) hole ring: scan
-- half-integer cell centres in the bounding box; the first inside is the
-- seed. Guaranteed to exist for any hole enclosing >= 1 cell.
local function hole_seed(ring)
  local minx, miny = math.huge, math.huge
  local maxx, maxy = -math.huge, -math.huge
  for _, v in ipairs(ring) do
    if v.x < minx then minx = v.x end
    if v.y < miny then miny = v.y end
    if v.x > maxx then maxx = v.x end
    if v.y > maxy then maxy = v.y end
  end
  for y = math.floor(miny), math.ceil(maxy) - 1 do
    for x = math.floor(minx), math.ceil(maxx) - 1 do
      local p = { x = x + 0.5, y = y + 0.5 }
      if poly_contains(ring, p) then return p end
    end
  end
  -- fallback: centroid (shouldn't be reached for valid holes)
  return { x = (minx + maxx) / 2, y = (miny + maxy) / 2 }
end

-- Build a PSLG from extracted regions. Returns
--   { vertices = { {x,y}, ... }, segments = { {a,b,marker}, ... }, holes = { {point} } }
-- with 1-based vertex ids matching the order they should be pushed into the mesh.
function P.pslg_from_regions(regions, marker)
  marker = marker or 1
  local pslg = { vertices = {}, segments = {}, holes = {} }
  local function add_ring(ring)
    local ids = {}
    for i = 1, #ring do
      local id = #pslg.vertices + 1
      pslg.vertices[id] = { x = ring[i].x, y = ring[i].y }
      ids[i] = id
    end
    for i = 1, #ids do
      local a = ids[i]
      local b = ids[i % #ids + 1]
      pslg.segments[#pslg.segments + 1] = { a = a, b = b, marker = marker }
    end
  end
  for _, region in ipairs(regions) do
    add_ring(region.outer)
    for _, hole in ipairs(region.holes) do
      add_ring(hole)
      pslg.holes[#pslg.holes + 1] = { point = hole_seed(hole) }
    end
  end
  return pslg
end

function P.pslg_from_bitfield(bits, opts)
  return P.pslg_from_regions(P.extract(bits, opts))
end

return P
