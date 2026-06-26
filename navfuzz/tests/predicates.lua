-- navfuzz/tests/predicates.lua
-- Deterministic regression for the adaptive predicates and EFT primitives.
-- Output must be byte-identical under golua and lua5.5.0.

local here = (arg and arg[0] or "?"):match("^(.*)[/\\]") or "."
package.path = here .. "/../?.lua;" .. package.path

local geom = require("geom")
local v = geom.vec
local eft = geom._eft

local function sign(x)
  if x > 0 then return "+" elseif x < 0 then return "-" else return "0" end
end

print("== orient2d signs ==")
print("ccw      ", sign(geom.orient2d(v(0, 0), v(1, 0), v(0, 1))))
print("cw       ", sign(geom.orient2d(v(0, 0), v(1, 0), v(0, -1))))
print("collinear", sign(geom.orient2d(v(0, 0), v(1, 0), v(2, 0))))
-- exactly collinear (0,0),(a,b),(2a,2b)
print("exact-col", sign(geom.orient2d(v(0.5, 0.5), v(12.0, 12.0), v(24.0, 24.0))))
-- tiny perturbation must give a definite sign
print("tiny-L   ", sign(geom.orient2d(v(0, 0), v(1, 1), v(0.5 - 1e-15, 0.5 + 1e-15))))
print("tiny-R   ", sign(geom.orient2d(v(0, 0), v(1, 1), v(0.5 + 1e-15, 0.5 - 1e-15))))

-- integer-grid orientation: exact for all corners of a unit square
print("== orient2d integer grid ==")
local n = 0
for ax = 0, 3 do
  for ay = 0, 3 do
    n = n + (geom.orient2d(v(0, 0), v(3, 0), v(ax, ay)) > 0 and 1 or 0)
  end
end
print("left-count", n)

print("== incircle signs ==")
print("inside   ", sign(geom.incircle(v(1, 0), v(0, 1), v(-1, 0), v(0, 0))))
print("outside  ", sign(geom.incircle(v(1, 0), v(0, 1), v(-1, 0), v(2, 0))))
print("on-circle", sign(geom.incircle(v(1, 0), v(0, 1), v(-1, 0), v(0, -1))))
print("cocircular", sign(geom.incircle(v(1, 0), v(0, 1), v(-1, 0), v(0, -1))))
-- integer cocircular: corners of an axis-aligned square share a circumcircle
print("sq-cocirc", sign(geom.incircle(v(0, 0), v(4, 0), v(4, 4), v(0, 4))))

print("== EFT round-trips ==")
local function rt_sum(a, b)
  local x, y = eft.two_sum(a, b)
  return (x + y) == (a + b)
end
local function rt_prod(a, b)
  local x, y = eft.two_product(a, b)
  return (a * b - x) == y
end
print("sum1", rt_sum(1.0, 2.0 ^ -53))
print("sum2", rt_sum(1e20, 1.0))
print("sum3", rt_sum(-3.7, 5.9))
print("prod1", rt_prod(3.0, 7.0))
print("prod2", rt_prod(1e10, 1e10))

-- expansion sum: (1 + 1e-30) + (1e-60) reproduced and estimated
local h = eft.fast_expansion_sum_zeroelim({ 1e-30, 1.0 }, { 1e-60, 2.0 })
local s = 0.0
for i = 1, #h do s = s + h[i] end
print("expsum-len", #h)
print("expsum-est", string.format("%.17g", s))

print("== point-in-triangle ==")
print("in ", geom.point_in_triangle(v(0, 0), v(4, 0), v(0, 4), v(1, 1)))
print("out", geom.point_in_triangle(v(0, 0), v(4, 0), v(0, 4), v(3, 3)))
print("edge", geom.point_in_triangle(v(0, 0), v(4, 0), v(0, 4), v(2, 0)))

print("OK")
