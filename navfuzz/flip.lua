-- navfuzz/flip.lua
--
-- Edge-flip primitives: port of triangle.c's flip()/unflip() via
-- rsnav's triangle/src/flip.rs. Both transform two triangles sharing an
-- edge into the other diagonal of their quadrilateral, reusing the slots
-- in place (handles stay valid). `flipedge` is a packed otri integer; it is
-- not mutated (the underlying vertex slots are rewritten instead).

local mesh = require("mesh")
local lnext, lprev = mesh.lnext, mesh.lprev
local osub_sub = mesh.osub_sub
local DUMMY_SUB = mesh.DUMMY_SUB

local F = {}

-- Flip the edge held by `flipedge` counter-clockwise within its quad.
-- Pre: convex quad, flipedge not glued to a subsegment on its own side.
function F.flip(m, flipedge)
  local rightvertex = m:org(flipedge)
  local leftvertex = m:dest(flipedge)
  local botvertex = m:apex(flipedge)
  local top = m:sym(flipedge)
  local farvertex = m:apex(top)

  local topleft = lprev(top)
  local toplcasing = m:sym(topleft)
  local topright = lnext(top)
  local toprcasing = m:sym(topright)
  local botleft = lnext(flipedge)
  local botlcasing = m:sym(botleft)
  local botright = lprev(flipedge)
  local botrcasing = m:sym(botright)

  m:bond(topleft, botlcasing)
  m:bond(botleft, botrcasing)
  m:bond(botright, toprcasing)
  m:bond(topright, toplcasing)

  local toplsubseg = m:tspivot(topleft)
  local botlsubseg = m:tspivot(botleft)
  local botrsubseg = m:tspivot(botright)
  local toprsubseg = m:tspivot(topright)

  if osub_sub(toplsubseg) == DUMMY_SUB then m:ts_dissolve(topright) else m:tsbond(topright, toplsubseg) end
  if osub_sub(botlsubseg) == DUMMY_SUB then m:ts_dissolve(topleft) else m:tsbond(topleft, botlsubseg) end
  if osub_sub(botrsubseg) == DUMMY_SUB then m:ts_dissolve(botleft) else m:tsbond(botleft, botrsubseg) end
  if osub_sub(toprsubseg) == DUMMY_SUB then m:ts_dissolve(botright) else m:tsbond(botright, toprsubseg) end

  m:set_org(flipedge, farvertex)
  m:set_dest(flipedge, botvertex)
  m:set_apex(flipedge, rightvertex)
  m:set_org(top, botvertex)
  m:set_dest(top, farvertex)
  m:set_apex(top, leftvertex)
end

-- Exact inverse of flip().
function F.unflip(m, flipedge)
  local rightvertex = m:org(flipedge)
  local leftvertex = m:dest(flipedge)
  local botvertex = m:apex(flipedge)
  local top = m:sym(flipedge)
  local farvertex = m:apex(top)

  local topleft = lprev(top)
  local toplcasing = m:sym(topleft)
  local topright = lnext(top)
  local toprcasing = m:sym(topright)
  local botleft = lnext(flipedge)
  local botlcasing = m:sym(botleft)
  local botright = lprev(flipedge)
  local botrcasing = m:sym(botright)

  m:bond(topleft, toprcasing)
  m:bond(botleft, toplcasing)
  m:bond(botright, botlcasing)
  m:bond(topright, botrcasing)

  local toplsubseg = m:tspivot(topleft)
  local botlsubseg = m:tspivot(botleft)
  local botrsubseg = m:tspivot(botright)
  local toprsubseg = m:tspivot(topright)

  if osub_sub(toprsubseg) == DUMMY_SUB then m:ts_dissolve(topleft) else m:tsbond(topleft, toprsubseg) end
  if osub_sub(toplsubseg) == DUMMY_SUB then m:ts_dissolve(botleft) else m:tsbond(botleft, toplsubseg) end
  if osub_sub(botlsubseg) == DUMMY_SUB then m:ts_dissolve(botright) else m:tsbond(botright, botlsubseg) end
  if osub_sub(botrsubseg) == DUMMY_SUB then m:ts_dissolve(topright) else m:tsbond(topright, botrsubseg) end

  m:set_org(flipedge, botvertex)
  m:set_dest(flipedge, farvertex)
  m:set_apex(flipedge, leftvertex)
  m:set_org(top, farvertex)
  m:set_dest(top, botvertex)
  m:set_apex(top, rightvertex)
end

return F
