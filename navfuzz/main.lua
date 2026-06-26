-- navfuzz/main.lua
--
-- Demo / corpus driver: run the full bitfield|PSLG -> CDT -> NavMesh -> BVH
-- pipeline over the fixture battery and print a canonical, deterministic
-- report. Designed to be byte-identical under golua and lua5.5.0 (the
-- differential oracle). Each fixture runs under pcall so a bug surfaces as a
-- printed error line rather than an uncatchable host crash.
--
--   lua5.5.0 main.lua          # run all fixtures
--   golua    main.lua          # same, on the golua runtime

local function here()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then return src:sub(2):match("^(.*)[/\\]") or "." end
  return "."
end
package.path = here() .. "/?.lua;" .. package.path

local navfuzz = require("init")
local report = require("report")
local fixtures = require("fixtures")

local geom = navfuzz.geom
local navigation = navfuzz.navigation
local pslg = navfuzz.pslg

local function emit(line) print(line) end

local function run_fixture(fx)
  print("######## " .. fx.name .. " ########")
  local built
  if fx.bitfield then
    local bits = pslg.bitfield_from_rows(fx.bitfield.width, fx.bitfield.rows)
    built = navfuzz.build_from_bitfield(bits, {})
  else
    built = navfuzz.build_from_pslg(fx.pslg, {})
  end
  local nav, idx = built.nav, built.bvh

  emit(string.format("pslg: verts=%d segs=%d holes=%d hull=%d",
    #built.pslg.vertices, #built.pslg.segments, #built.pslg.holes, built.hull))
  report.navmesh(emit, nav)
  report.bvh(emit, idx, nav)

  for _, q in ipairs(fx.locate or {}) do
    local p = geom.vec(q[1], q[2])
    local lt = idx:locate(p)
    local nr = idx:nearest(p)
    if lt == nil then
      emit(string.format("locate (%s,%s) = outside; nearest=%.6f at (%s,%s)",
        report.fmtnum(q[1]), report.fmtnum(q[2]), nr.distance,
        report.fmtnum(nr.point.x), report.fmtnum(nr.point.y)))
    else
      local tri = nav.triangles[lt]
      local a, b, c = report.sort3(tri.v[0], tri.v[1], tri.v[2])
      emit(string.format("locate (%s,%s) = tri(%d,%d,%d); nearest=%.6f",
        report.fmtnum(q[1]), report.fmtnum(q[2]), a, b, c, nr.distance))
    end
  end

  local walls = navigation.wall_info(nav)
  for i, q in ipairs(fx.queries or {}) do
    local res, err = navigation.find_path(nav, idx,
      geom.vec(q[1], q[2]), geom.vec(q[3], q[4]),
      { distance_from_wall = 0.0, walls = walls })
    local label = string.format("#%d (%s,%s)->(%s,%s)", i,
      report.fmtnum(q[1]), report.fmtnum(q[2]), report.fmtnum(q[3]), report.fmtnum(q[4]))
    report.path(emit, label, res, err)
  end
end

local function main()
  for _, fx in ipairs(fixtures.list) do
    local ok, err = pcall(run_fixture, fx)
    if not ok then
      print("ERROR in fixture " .. tostring(fx.name) .. ": "
        .. (type(err) == "table" and ("{kind=" .. tostring(err.kind) .. "}") or tostring(err)))
    end
  end
  print("DONE")
end

main()
