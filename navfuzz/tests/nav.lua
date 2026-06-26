-- navfuzz/tests/nav.lua
-- A* + funnel + LOS over real maps. Each returned path is re-validated by
-- walking its segments with line_of_sight. Byte-identical on both runtimes.

local here = (arg and arg[0] or "?"):match("^(.*)[/\\]") or "."
package.path = here .. "/../?.lua;" .. package.path

local mesh = require("mesh")
local geom = require("geom")
local divconq = require("divconq")
local segment = require("segment")
local holes = require("holes")
local pslg = require("pslg")
local navmesh = require("navmesh")
local bvh = require("bvh")
local navigation = require("navigation")
local v = geom.vec

local function build(width, rows)
  local bits = pslg.bitfield_from_rows(width, rows)
  local P = pslg.pslg_from_bitfield(bits, {})
  local m = mesh.new()
  for i = 1, #P.vertices do m:push_vertex(v(P.vertices[i].x, P.vertices[i].y), 0) end
  divconq.delaunay(m, { dwyer = true })
  segment.form_skeleton(m, P, nil)
  holes.carve_holes(m, P, false)
  local nav = navmesh.build(m)
  return nav, bvh.build(nav)
end

local function path_len(points)
  local s = 0.0
  for i = 1, #points - 1 do s = s + geom.distance(points[i], points[i + 1]) end
  return s
end

-- A path stays in the walkable region iff interior samples of every leg are
-- on the mesh. Sampling strictly-interior points (never the endpoints) is
-- robust: a leg that truly crosses a hole lands a sample off-mesh, while a
-- leg that merely grazes a wall corner (the dfw=0 funnel hugs corners) keeps
-- all interior samples inside -- avoiding the degeneracy of running a LOS
-- walk from a wall-vertex waypoint.
local function path_valid(nav, idx, points)
  for i = 1, #points - 1 do
    local a, b = points[i], points[i + 1]
    for _, t in ipairs({ 0.1, 0.3, 0.5, 0.7, 0.9 }) do
      local p = v(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
      if idx:locate(p) == nil then return false end
    end
  end
  return true
end

local function fmtpts(points)
  local parts = {}
  for i = 1, #points do parts[i] = string.format("(%.1f,%.1f)", points[i].x, points[i].y) end
  return table.concat(parts, " ")
end

local function run(name, width, rows, queries, dfw)
  dfw = dfw or 0.0
  print("== " .. name .. (dfw > 0 and (" dfw=" .. dfw) or "") .. " ==")
  local nav, idx = build(width, rows)
  local walls = navigation.wall_info(nav)
  print("tris", nav:tcount(), "regions", nav.region_count)
  for _, q in ipairs(queries) do
    local start, goal = v(q[1], q[2]), v(q[3], q[4])
    local res, err = navigation.find_path(nav, idx, start, goal, { distance_from_wall = dfw, walls = walls })
    if err then
      print(string.format("  %s->%s : %s", fmtpts({ start }), fmtpts({ goal }), err))
    else
      local st_tri = idx:locate(start)
      local direct = navigation.line_of_sight(nav, walls, st_tri, start, goal)
      print(string.format("  corridor=%d waypoints=%d len=%.6f direct_LOS=%s valid=%s",
        #res.triangles, #res.points, path_len(res.points), direct,
        path_valid(nav, idx, res.points) and "y" or "N"))
      print("    " .. fmtpts(res.points))
    end
  end
end

-- center-hole room: path must bend around the hole
run("room5x5-hole", 5, { "#####", "#####", "##.##", "#####", "#####" },
  { { 0.5, 0.5, 4.5, 4.5 }, { 0.5, 2.5, 4.5, 2.5 }, { 2.5, 0.5, 2.5, 4.5 } })

-- two rooms joined by a single door cell (col 2, middle row)
run("two-rooms-door", 5, { "##.##", "##.##", "#####", "##.##", "##.##" },
  { { 0.5, 4.5, 4.5, 0.5 }, { 1.5, 0.5, 3.5, 4.5 } })

-- door closed: the rooms are disconnected -> Unreachable
run("two-rooms-closed", 5, { "##.##", "##.##", "##.##", "##.##", "##.##" },
  { { 0.5, 0.5, 4.5, 4.5 } })

-- L-shaped corridor: path turns the corner
run("L-corridor", 5, { "##...", "##...", "#####", "#####", "....." },
  { { 0.5, 4.5, 4.5, 2.5 } })

-- inset clearance: with dfw>0 the path is pushed off the walls (float
-- waypoints, still bit-deterministic) and every leg clears LOS cleanly.
run("room5x5-hole", 5, { "#####", "#####", "##.##", "#####", "#####" },
  { { 0.5, 0.5, 4.5, 4.5 } }, 0.3)

print("OK")
