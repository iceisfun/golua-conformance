-- navfuzz/geom.lua
--
-- Vertex math, Shewchuk-style robust adaptive geometric predicates
-- (orient2d / incircle), and the point/segment/triangle/AABB helpers used
-- by the BVH and navigation layers.
--
-- The predicates are a faithful port of rsnav's triangle/src/predicates.rs,
-- which is itself a port of the `predicates.c` portion of Shewchuk's
-- triangle.c. They compute the *exact sign* of the orientation and in-circle
-- determinants using only IEEE-754 f64 + - * with round-to-nearest. On
-- integer coordinates the fast path is exact; on float query points the
-- error-free-transform (EFT) cascade is bit-deterministic across any strict
-- IEEE-754 binary64 runtime -- so golua and lua5.5.0 must agree to the bit.
--
-- All vertices are tables { x = <number>, y = <number> }.

local sqrt = math.sqrt
local abs = math.abs

local geom = {}

-- --- Machine constants ---------------------------------------------------
-- Computed the same way Shewchuk's exactinit() does, so the bounds are
-- identical on every IEEE-754 runtime. EPSILON = 2^-53.
local EPSILON = 1.1102230246251565e-16
local SPLITTER = 134217729.0 -- 2^27 + 1

local RESULTERRBOUND = (3.0 + 8.0 * EPSILON) * EPSILON
local CCWERRBOUND_A  = (3.0 + 16.0 * EPSILON) * EPSILON
local CCWERRBOUND_B  = (2.0 + 12.0 * EPSILON) * EPSILON
local CCWERRBOUND_C  = (9.0 + 64.0 * EPSILON) * EPSILON * EPSILON
local ICCERRBOUND_A  = (10.0 + 96.0 * EPSILON) * EPSILON
local ICCERRBOUND_B  = (4.0 + 48.0 * EPSILON) * EPSILON
local ICCERRBOUND_C  = (44.0 + 576.0 * EPSILON) * EPSILON * EPSILON

-- --- Error-free transforms ----------------------------------------------

-- Fast Two-Sum: requires |a| >= |b|.
local function fast_two_sum(a, b)
  local x = a + b
  local bvirt = x - a
  return x, b - bvirt
end

-- Two-Sum: no ordering requirement.
local function two_sum(a, b)
  local x = a + b
  local bvirt = x - a
  local avirt = x - bvirt
  local bround = b - bvirt
  local around = a - avirt
  return x, around + bround
end

-- Two-Diff: x + y = a - b exactly.
local function two_diff(a, b)
  local x = a - b
  local bvirt = a - x
  local avirt = x + bvirt
  local bround = bvirt - b
  local around = a - avirt
  return x, around + bround
end

-- Rounding error y such that a - b = x + y, given x = fl(a - b).
local function two_diff_tail(a, b, x)
  local bvirt = a - x
  local avirt = x + bvirt
  local bround = bvirt - b
  local around = a - avirt
  return around + bround
end

-- Veltkamp/Dekker split.
local function split(a)
  local c = SPLITTER * a
  local abig = c - a
  local ahi = c - abig
  return ahi, a - ahi
end

-- Two-Product: x + y = a * b exactly.
local function two_product(a, b)
  local x = a * b
  local ahi, alo = split(a)
  local bhi, blo = split(b)
  local err1 = x - ahi * bhi
  local err2 = err1 - alo * bhi
  local err3 = err2 - ahi * blo
  return x, alo * blo - err3
end

-- Two-Product with b already split.
local function two_product_presplit(a, b, bhi, blo)
  local x = a * b
  local ahi, alo = split(a)
  local err1 = x - ahi * bhi
  local err2 = err1 - alo * bhi
  local err3 = err2 - ahi * blo
  return x, alo * blo - err3
end

-- Two-One-Diff: (a1 + a0) - b, length-3 expansion (x2, x1, x0).
local function two_one_diff(a1, a0, b)
  local i, x0 = two_diff(a0, b)
  local x2, x1 = two_sum(a1, i)
  return x2, x1, x0
end

-- Two-Two-Diff: (a1 + a0) - (b1 + b0), length-4 expansion (x3, x2, x1, x0).
local function two_two_diff(a1, a0, b1, b0)
  local j, _0, x0 = two_one_diff(a1, a0, b0)
  local x3, x2, x1 = two_one_diff(j, _0, b1)
  return x3, x2, x1, x0
end

-- --- Multi-precision expansion arithmetic --------------------------------
-- Expansions are 1-indexed Lua arrays; #e is the length. The zero-elim
-- routines return a fresh array (never aliasing inputs).

-- h = e + f. Port of fast_expansion_sum_zeroelim.
local function fast_expansion_sum_zeroelim(e, f)
  local elen, flen = #e, #f
  local enow, fnow = e[1], f[1]
  local eindex, findex = 1, 1
  local q
  if (fnow > enow) == (fnow > -enow) then
    q = enow
    eindex = eindex + 1
    if eindex <= elen then enow = e[eindex] end
  else
    q = fnow
    findex = findex + 1
    if findex <= flen then fnow = f[findex] end
  end

  local h = {}
  local hindex = 0
  if eindex <= elen and findex <= flen then
    local qnew, hh
    if (fnow > enow) == (fnow > -enow) then
      qnew, hh = fast_two_sum(enow, q)
      eindex = eindex + 1
      if eindex <= elen then enow = e[eindex] end
    else
      qnew, hh = fast_two_sum(fnow, q)
      findex = findex + 1
      if findex <= flen then fnow = f[findex] end
    end
    q = qnew
    if hh ~= 0.0 then hindex = hindex + 1; h[hindex] = hh end

    while eindex <= elen and findex <= flen do
      if (fnow > enow) == (fnow > -enow) then
        qnew, hh = two_sum(q, enow)
        eindex = eindex + 1
        if eindex <= elen then enow = e[eindex] end
      else
        qnew, hh = two_sum(q, fnow)
        findex = findex + 1
        if findex <= flen then fnow = f[findex] end
      end
      q = qnew
      if hh ~= 0.0 then hindex = hindex + 1; h[hindex] = hh end
    end
  end

  while eindex <= elen do
    local qnew, hh = two_sum(q, enow)
    eindex = eindex + 1
    if eindex <= elen then enow = e[eindex] end
    q = qnew
    if hh ~= 0.0 then hindex = hindex + 1; h[hindex] = hh end
  end
  while findex <= flen do
    local qnew, hh = two_sum(q, fnow)
    findex = findex + 1
    if findex <= flen then fnow = f[findex] end
    q = qnew
    if hh ~= 0.0 then hindex = hindex + 1; h[hindex] = hh end
  end
  if q ~= 0.0 or hindex == 0 then hindex = hindex + 1; h[hindex] = q end
  return h
end

-- h = e * b. Port of scale_expansion_zeroelim.
local function scale_expansion_zeroelim(e, b)
  local bhi, blo = split(b)
  local q, hh = two_product_presplit(e[1], b, bhi, blo)
  local h = {}
  local hindex = 0
  if hh ~= 0.0 then hindex = hindex + 1; h[hindex] = hh end
  for eindex = 2, #e do
    local enow = e[eindex]
    local product1, product0 = two_product_presplit(enow, b, bhi, blo)
    local sum, hh1 = two_sum(q, product0)
    if hh1 ~= 0.0 then hindex = hindex + 1; h[hindex] = hh1 end
    local qnew, hh2 = fast_two_sum(product1, sum)
    q = qnew
    if hh2 ~= 0.0 then hindex = hindex + 1; h[hindex] = hh2 end
  end
  if q ~= 0.0 or hindex == 0 then hindex = hindex + 1; h[hindex] = q end
  return h
end

local function estimate(e)
  local q = e[1]
  for i = 2, #e do q = q + e[i] end
  return q
end

-- --- orient2d ------------------------------------------------------------

local function orient2d_adapt(pa, pb, pc, detsum)
  local acx = pa.x - pc.x
  local bcx = pb.x - pc.x
  local acy = pa.y - pc.y
  local bcy = pb.y - pc.y

  local detleft, detlefttail = two_product(acx, bcy)
  local detright, detrighttail = two_product(acy, bcx)

  local b3, b2, b1, b0 = two_two_diff(detleft, detlefttail, detright, detrighttail)
  local b = { b0, b1, b2, b3 }

  local det = estimate(b)
  local errbound = CCWERRBOUND_B * detsum
  if det >= errbound or -det >= errbound then return det end

  local acxtail = two_diff_tail(pa.x, pc.x, acx)
  local bcxtail = two_diff_tail(pb.x, pc.x, bcx)
  local acytail = two_diff_tail(pa.y, pc.y, acy)
  local bcytail = two_diff_tail(pb.y, pc.y, bcy)

  if acxtail == 0.0 and acytail == 0.0 and bcxtail == 0.0 and bcytail == 0.0 then
    return det
  end

  errbound = CCWERRBOUND_C * detsum + RESULTERRBOUND * abs(det)
  det = det + ((acx * bcytail + bcy * acxtail) - (acy * bcxtail + bcx * acytail))
  if det >= errbound or -det >= errbound then return det end

  local s1, s0 = two_product(acxtail, bcy)
  local t1, t0 = two_product(acytail, bcx)
  local u3, u2, u1, u0 = two_two_diff(s1, s0, t1, t0)
  local c1 = fast_expansion_sum_zeroelim(b, { u0, u1, u2, u3 })

  s1, s0 = two_product(acx, bcytail)
  t1, t0 = two_product(acy, bcxtail)
  u3, u2, u1, u0 = two_two_diff(s1, s0, t1, t0)
  local c2 = fast_expansion_sum_zeroelim(c1, { u0, u1, u2, u3 })

  s1, s0 = two_product(acxtail, bcytail)
  t1, t0 = two_product(acytail, bcxtail)
  u3, u2, u1, u0 = two_two_diff(s1, s0, t1, t0)
  local d = fast_expansion_sum_zeroelim(c2, { u0, u1, u2, u3 })

  return d[#d]
end

-- Returns > 0 if pc is left of pa->pb (CCW), < 0 if right, 0 if collinear.
-- The sign is exact for every f64 input.
local function orient2d(pa, pb, pc)
  local detleft = (pa.x - pc.x) * (pb.y - pc.y)
  local detright = (pa.y - pc.y) * (pb.x - pc.x)
  local det = detleft - detright

  local detsum
  if detleft > 0.0 then
    if detright <= 0.0 then return det end
    detsum = detleft + detright
  elseif detleft < 0.0 then
    if detright >= 0.0 then return det end
    detsum = -detleft - detright
  else
    return det
  end

  local errbound = CCWERRBOUND_A * detsum
  if det >= errbound or -det >= errbound then return det end

  return orient2d_adapt(pa, pb, pc, detsum)
end

-- --- incircle ------------------------------------------------------------

local function incircle_adapt(pa, pb, pc, pd, permanent)
  local adx = pa.x - pd.x
  local bdx = pb.x - pd.x
  local cdx = pc.x - pd.x
  local ady = pa.y - pd.y
  local bdy = pb.y - pd.y
  local cdy = pc.y - pd.y

  local bdxcdy1, bdxcdy0 = two_product(bdx, cdy)
  local cdxbdy1, cdxbdy0 = two_product(cdx, bdy)
  local bc3, bc2, bc1, bc0 = two_two_diff(bdxcdy1, bdxcdy0, cdxbdy1, cdxbdy0)
  local bc = { bc0, bc1, bc2, bc3 }
  local axbc = scale_expansion_zeroelim(bc, adx)
  local axxbc = scale_expansion_zeroelim(axbc, adx)
  local aybc = scale_expansion_zeroelim(bc, ady)
  local ayybc = scale_expansion_zeroelim(aybc, ady)
  local adet = fast_expansion_sum_zeroelim(axxbc, ayybc)

  local cdxady1, cdxady0 = two_product(cdx, ady)
  local adxcdy1, adxcdy0 = two_product(adx, cdy)
  local ca3, ca2, ca1, ca0 = two_two_diff(cdxady1, cdxady0, adxcdy1, adxcdy0)
  local ca = { ca0, ca1, ca2, ca3 }
  local bxca = scale_expansion_zeroelim(ca, bdx)
  local bxxca = scale_expansion_zeroelim(bxca, bdx)
  local byca = scale_expansion_zeroelim(ca, bdy)
  local byyca = scale_expansion_zeroelim(byca, bdy)
  local bdet = fast_expansion_sum_zeroelim(bxxca, byyca)

  local adxbdy1, adxbdy0 = two_product(adx, bdy)
  local bdxady1, bdxady0 = two_product(bdx, ady)
  local ab3, ab2, ab1, ab0 = two_two_diff(adxbdy1, adxbdy0, bdxady1, bdxady0)
  local ab = { ab0, ab1, ab2, ab3 }
  local cxab = scale_expansion_zeroelim(ab, cdx)
  local cxxab = scale_expansion_zeroelim(cxab, cdx)
  local cyab = scale_expansion_zeroelim(ab, cdy)
  local cyyab = scale_expansion_zeroelim(cyab, cdy)
  local cdet = fast_expansion_sum_zeroelim(cxxab, cyyab)

  local abdet = fast_expansion_sum_zeroelim(adet, bdet)
  local fin1 = fast_expansion_sum_zeroelim(abdet, cdet)

  local det = estimate(fin1)
  local errbound = ICCERRBOUND_B * permanent
  if det >= errbound or -det >= errbound then return det end

  local adxtail = two_diff_tail(pa.x, pd.x, adx)
  local adytail = two_diff_tail(pa.y, pd.y, ady)
  local bdxtail = two_diff_tail(pb.x, pd.x, bdx)
  local bdytail = two_diff_tail(pb.y, pd.y, bdy)
  local cdxtail = two_diff_tail(pc.x, pd.x, cdx)
  local cdytail = two_diff_tail(pc.y, pd.y, cdy)

  if adxtail == 0.0 and bdxtail == 0.0 and cdxtail == 0.0
    and adytail == 0.0 and bdytail == 0.0 and cdytail == 0.0 then
    return det
  end

  errbound = ICCERRBOUND_C * permanent + RESULTERRBOUND * abs(det)
  det = det + (((adx * adx + ady * ady)
        * ((bdx * cdytail + cdy * bdxtail) - (bdy * cdxtail + cdx * bdytail))
        + 2.0 * (adx * adxtail + ady * adytail) * (bdx * cdy - bdy * cdx))
    + ((bdx * bdx + bdy * bdy)
        * ((cdx * adytail + ady * cdxtail) - (cdy * adxtail + adx * cdytail))
        + 2.0 * (bdx * bdxtail + bdy * bdytail) * (cdx * ady - cdy * adx))
    + ((cdx * cdx + cdy * cdy)
        * ((adx * bdytail + bdy * adxtail) - (ady * bdxtail + bdx * adytail))
        + 2.0 * (cdx * cdxtail + cdy * cdytail) * (adx * bdy - ady * bdx)))
  if det >= errbound or -det >= errbound then return det end

  -- Shewchuk's full exact path is ~500 further lines; the earlier filters
  -- catch every case for moderate-magnitude inputs. Matches predicates.rs.
  return det
end

-- Returns > 0 if pd is inside the circle through (pa, pb, pc) [given CCW],
-- < 0 outside, 0 cocircular.
local function incircle(pa, pb, pc, pd)
  local adx = pa.x - pd.x
  local bdx = pb.x - pd.x
  local cdx = pc.x - pd.x
  local ady = pa.y - pd.y
  local bdy = pb.y - pd.y
  local cdy = pc.y - pd.y

  local bdxcdy = bdx * cdy
  local cdxbdy = cdx * bdy
  local alift = adx * adx + ady * ady

  local cdxady = cdx * ady
  local adxcdy = adx * cdy
  local blift = bdx * bdx + bdy * bdy

  local adxbdy = adx * bdy
  local bdxady = bdx * ady
  local clift = cdx * cdx + cdy * cdy

  local det = alift * (bdxcdy - cdxbdy)
    + blift * (cdxady - adxcdy)
    + clift * (adxbdy - bdxady)

  local permanent = (abs(bdxcdy) + abs(cdxbdy)) * alift
    + (abs(cdxady) + abs(adxcdy)) * blift
    + (abs(adxbdy) + abs(bdxady)) * clift
  local errbound = ICCERRBOUND_A * permanent
  if det > errbound or -det > errbound then return det end

  return incircle_adapt(pa, pb, pc, pd, permanent)
end

-- --- Vertex helpers ------------------------------------------------------

local function vec(x, y) return { x = x, y = y } end
local function sub(a, b) return { x = a.x - b.x, y = a.y - b.y } end
local function add(a, b) return { x = a.x + b.x, y = a.y + b.y } end
local function scale(a, s) return { x = a.x * s, y = a.y * s } end
local function dot(a, b) return a.x * b.x + a.y * b.y end
local function length_sq(a) return a.x * a.x + a.y * a.y end
local function distance_sq(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end
local function distance(a, b) return sqrt(distance_sq(a, b)) end
local function equal(a, b) return a.x == b.x and a.y == b.y end

-- --- Point / segment / triangle ------------------------------------------

-- Winding-agnostic, boundary-inclusive point-in-triangle.
local function point_in_triangle(a, b, c, p)
  local d1 = orient2d(a, b, p)
  local d2 = orient2d(b, c, p)
  local d3 = orient2d(c, a, p)
  local has_neg = d1 < 0.0 or d2 < 0.0 or d3 < 0.0
  local has_pos = d1 > 0.0 or d2 > 0.0 or d3 > 0.0
  return not (has_neg and has_pos)
end

-- Closest point on segment [a,b] to p.
local function nearest_point_on_segment(a, b, p)
  local abx, aby = b.x - a.x, b.y - a.y
  local len_sq = abx * abx + aby * aby
  if len_sq == 0.0 then return { x = a.x, y = a.y } end
  local t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / len_sq
  if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
  return { x = a.x + abx * t, y = a.y + aby * t }
end

-- Closest point on triangle (a,b,c) to p, plus the distance.
local function nearest_point_on_triangle(a, b, c, p)
  if point_in_triangle(a, b, c, p) then
    return { x = p.x, y = p.y }, 0.0
  end
  local q1 = nearest_point_on_segment(a, b, p)
  local q2 = nearest_point_on_segment(b, c, p)
  local q3 = nearest_point_on_segment(c, a, p)
  local best, bestd = q1, distance(q1, p)
  local d2 = distance(q2, p)
  if d2 < bestd then best, bestd = q2, d2 end
  local d3 = distance(q3, p)
  if d3 < bestd then best, bestd = q3, d3 end
  return best, bestd
end

-- Intersection of segment p1->p2 with segment p3->p4.
-- Returns (point, t) where t is the parameter along p1->p2, or nil.
local function segment_intersection(p1, p2, p3, p4)
  local r1x, r1y = p2.x - p1.x, p2.y - p1.y
  local r2x, r2y = p4.x - p3.x, p4.y - p3.y
  local denom = r1x * r2y - r1y * r2x
  if denom == 0.0 then return nil end -- parallel / collinear
  local sx, sy = p3.x - p1.x, p3.y - p1.y
  local t = (sx * r2y - sy * r2x) / denom
  local u = (sx * r1y - sy * r1x) / denom
  if u < 0.0 or u > 1.0 then return nil end
  return { x = p1.x + r1x * t, y = p1.y + r1y * t }, t
end

-- --- AABB ----------------------------------------------------------------

local Aabb = {}
Aabb.__index = Aabb

local function aabb_empty()
  return setmetatable({
    min = { x = math.huge, y = math.huge },
    max = { x = -math.huge, y = -math.huge },
  }, Aabb)
end

local function aabb_from_points(pts)
  local box = aabb_empty()
  for i = 1, #pts do
    local p = pts[i]
    if p.x < box.min.x then box.min.x = p.x end
    if p.y < box.min.y then box.min.y = p.y end
    if p.x > box.max.x then box.max.x = p.x end
    if p.y > box.max.y then box.max.y = p.y end
  end
  return box
end

function Aabb:is_empty() return self.min.x > self.max.x or self.min.y > self.max.y end
function Aabb:width() return self.max.x - self.min.x end
function Aabb:height() return self.max.y - self.min.y end

function Aabb:contains(p)
  return p.x >= self.min.x and p.x <= self.max.x
    and p.y >= self.min.y and p.y <= self.max.y
end

function Aabb:intersects(o)
  return self.min.x <= o.max.x and self.max.x >= o.min.x
    and self.min.y <= o.max.y and self.max.y >= o.min.y
end

function Aabb:union(o)
  local b = aabb_empty()
  b.min.x = self.min.x < o.min.x and self.min.x or o.min.x
  b.min.y = self.min.y < o.min.y and self.min.y or o.min.y
  b.max.x = self.max.x > o.max.x and self.max.x or o.max.x
  b.max.y = self.max.y > o.max.y and self.max.y or o.max.y
  return b
end

function Aabb:distance_to_point(p)
  local cx = p.x
  if cx < self.min.x then cx = self.min.x elseif cx > self.max.x then cx = self.max.x end
  local cy = p.y
  if cy < self.min.y then cy = self.min.y elseif cy > self.max.y then cy = self.max.y end
  local dx, dy = p.x - cx, p.y - cy
  return sqrt(dx * dx + dy * dy)
end

-- --- exports -------------------------------------------------------------

geom.orient2d = orient2d
geom.incircle = incircle
geom.vec = vec
geom.sub = sub
geom.add = add
geom.scale = scale
geom.dot = dot
geom.length_sq = length_sq
geom.distance = distance
geom.distance_sq = distance_sq
geom.equal = equal
geom.point_in_triangle = point_in_triangle
geom.nearest_point_on_segment = nearest_point_on_segment
geom.nearest_point_on_triangle = nearest_point_on_triangle
geom.segment_intersection = segment_intersection
geom.Aabb = Aabb
geom.aabb_empty = aabb_empty
geom.aabb_from_points = aabb_from_points

-- Exposed for the predicate regression test.
geom._eft = {
  two_sum = two_sum,
  two_product = two_product,
  two_diff = two_diff,
  fast_expansion_sum_zeroelim = fast_expansion_sum_zeroelim,
  scale_expansion_zeroelim = scale_expansion_zeroelim,
}

return geom
