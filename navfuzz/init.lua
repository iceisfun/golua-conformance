-- navfuzz/init.lua
--
-- Assembles the pure-Lua navigation pipeline into one module and exposes the
-- end-to-end builder: bitfield -> PSLG -> CDT -> carve -> NavMesh -> BVH.
--
-- Runs unchanged on golua and lua5.5.0 (Lua 5.5: 64-bit integers, bit ops,
-- string.format, table.sort). No third-party dependencies.

local function here()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then return src:sub(2):match("^(.*)[/\\]") or "." end
  return "."
end
package.path = here() .. "/?.lua;" .. package.path

local geom = require("geom")
local mesh = require("mesh")
local divconq = require("divconq")
local segment = require("segment")
local holes = require("holes")
local pslg = require("pslg")
local navmesh = require("navmesh")
local bvh = require("bvh")
local navigation = require("navigation")

local navfuzz = {
  geom = geom,
  mesh = mesh,
  divconq = divconq,
  segment = segment,
  holes = holes,
  pslg = pslg,
  navmesh = navmesh,
  bvh = bvh,
  navigation = navigation,
}

-- Build a CdtMesh from a PSLG ({vertices, segments, holes}). Returns the
-- carved CdtMesh and the convex-hull size.
function navfuzz.build_cdt(P, opts)
  opts = opts or {}
  local m = mesh.new()
  for i = 1, #P.vertices do
    m:push_vertex(geom.vec(P.vertices[i].x, P.vertices[i].y), 0)
  end
  local hull = divconq.delaunay(m, { dwyer = opts.dwyer ~= false })
  segment.form_skeleton(m, P, opts.mark_hull)
  holes.carve_holes(m, P, opts.convex == true)
  return m, hull
end

-- Full pipeline from a Bitfield. Returns a table:
--   { pslg, cdt, hull, nav, bvh }
function navfuzz.build_from_bitfield(bits, opts)
  opts = opts or {}
  local P = pslg.pslg_from_bitfield(bits, opts.extract)
  local cdt, hull = navfuzz.build_cdt(P, opts)
  local nav = navmesh.build(cdt)
  local index = bvh.build(nav)
  return { pslg = P, cdt = cdt, hull = hull, nav = nav, bvh = index }
end

-- Full pipeline from a directly-authored PSLG.
function navfuzz.build_from_pslg(P, opts)
  local cdt, hull = navfuzz.build_cdt(P, opts)
  local nav = navmesh.build(cdt)
  local index = bvh.build(nav)
  return { pslg = P, cdt = cdt, hull = hull, nav = nav, bvh = index }
end

return navfuzz
