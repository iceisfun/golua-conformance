-- navfuzz/tests/mesh_otri.lua
-- Handle algebra + pool + bond/sym round-trips. Byte-identical on both runtimes.

local here = (arg and arg[0] or "?"):match("^(.*)[/\\]") or "."
package.path = here .. "/../?.lua;" .. package.path

local mesh = require("mesh")
local geom = require("geom")
local v = geom.vec

local function yn(b) return b and "yes" or "no" end

print("== encoded handle round-trip ==")
local ok_tri = true
for _, tri in ipairs({ 1, 5, 1000, (1 << 30) - 1 }) do
  for orient = 0, 2 do
    local enc = mesh.otri_pack(tri, orient)
    if mesh.otri_tri(enc) ~= tri or mesh.otri_orient(enc) ~= orient then ok_tri = false end
  end
end
print("otri", yn(ok_tri))

local ok_sub = true
for _, sub in ipairs({ 1, 5, 1000, (1 << 31) - 1 }) do
  for orient = 0, 1 do
    local enc = mesh.osub_pack(sub, orient)
    if mesh.osub_sub(enc) ~= sub or mesh.osub_orient(enc) ~= orient then ok_sub = false end
  end
end
print("osub", yn(ok_sub))

print("== local navigation ==")
local o = mesh.otri_pack(7, 0)
print("lnext.lprev==o", yn(mesh.lprev(mesh.lnext(o)) == o))
print("lnext^3==o    ", yn(mesh.lnext(mesh.lnext(mesh.lnext(o))) == o))
print("lprev^3==o    ", yn(mesh.lprev(mesh.lprev(mesh.lprev(o))) == o))
local s = mesh.osub_pack(3, 0)
print("ssym==(3,1)   ", yn(mesh.ssym(s) == mesh.osub_pack(3, 1)))
print("ssym.ssym==s  ", yn(mesh.ssym(mesh.ssym(s)) == s))

print("== triangle pool ==")
local m = mesh.new()
local a = m:make_triangle()
local b = m:make_triangle()
print("a.tri", mesh.otri_tri(a))
print("b.tri", mesh.otri_tri(b))
print("live", m:live_triangle_count())
m:kill_triangle(mesh.otri_tri(a))
print("live-after-kill", m:live_triangle_count())
local c = m:make_triangle()
print("recycled", yn(mesh.otri_tri(c) == mesh.otri_tri(a)))
print("not-dead", yn(not m:tri_is_dead(mesh.otri_tri(c))))

print("== bond / sym round-trip ==")
local m2 = mesh.new()
local va = m2:push_vertex(v(0, 0), 0)
local vb = m2:push_vertex(v(1, 0), 0)
local vc = m2:push_vertex(v(0, 1), 0)
local vd = m2:push_vertex(v(1, 1), 0)
local t1 = m2:make_triangle()
m2:set_corners(t1, va, vb, vc)
local t2 = m2:make_triangle()
m2:set_corners(t2, vd, vc, vb)
-- edge holding (B,C) on t1 is the one whose org=B,dest=C. orient 0: org=PLUS1[0]=vtx[1]=vb? corners set org=va? Let's check via accessors.
-- t1 corners: set_org->vtx[PLUS1[0]=1]=va, set_dest->vtx[MINUS1[0]=2]=vb, set_apex->vtx[0]=vc
print("t1 org/dest/apex", m2:org(t1), m2:dest(t1), m2:apex(t1))
-- bond t1 edge0 to t2 edge0 and confirm sym walks back
m2:bond(t1, t2)
print("sym(t1)==t2", yn(m2:sym(t1) == t2))
print("sym(t2)==t1", yn(m2:sym(t2) == t1))
print("sym(sym(t1))==t1", yn(m2:sym(m2:sym(t1)) == t1))

print("== subseg glue ==")
local sub0 = m2:make_subseg()
m2:tsbond(t1, sub0)
print("tspivot(t1)==sub0", yn(m2:tspivot(t1) == sub0))
print("stpivot(sub0)==t1", yn(m2:stpivot(sub0) == t1))
m2:set_sorg(sub0, va)
m2:set_sdest(sub0, vb)
print("sorg/sdest", m2:sorg(sub0), m2:sdest(sub0))

print("OK")
