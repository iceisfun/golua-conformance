-- lua55vm/strmatch.lua
-- A from-scratch implementation of Lua's pattern matching (lstrlib.c), used by
-- string.find / match / gmatch / gsub. Operates on host strings using byte
-- comparisons and our own character-class logic — it does NOT use the host's
-- pattern matcher, so it exercises this surface independently.

local byte = string.byte
local sub = string.sub
local char = string.char

local M = {}

local L_ESC = 37        -- '%'
local MAXCAPS = 32
local CAP_UNFINISHED = -1
local CAP_POSITION = -2

-- ASCII ctype predicates (C locale)
local function is_digit(c) return c >= 48 and c <= 57 end
local function is_lower(c) return c >= 97 and c <= 122 end
local function is_upper(c) return c >= 65 and c <= 90 end
local function is_alpha(c) return is_lower(c) or is_upper(c) end
local function is_alnum(c) return is_alpha(c) or is_digit(c) end
local function is_space(c) return (c >= 9 and c <= 13) or c == 32 end
local function is_cntrl(c) return c < 32 or c == 127 end
local function is_graph(c) return c >= 33 and c <= 126 end
local function is_punct(c) return is_graph(c) and not is_alnum(c) end
local function is_xdigit(c)
  return is_digit(c) or (c >= 65 and c <= 70) or (c >= 97 and c <= 102)
end
local function to_lower(c) if is_upper(c) then return c + 32 end return c end

-- match a single class letter `cl` against char `c`
local function match_class(c, cl)
  local res
  local l = to_lower(cl)
  if l == 97 then res = is_alpha(c)        -- a
  elseif l == 99 then res = is_cntrl(c)    -- c
  elseif l == 100 then res = is_digit(c)   -- d
  elseif l == 103 then res = is_graph(c)   -- g
  elseif l == 108 then res = is_lower(c)   -- l
  elseif l == 112 then res = is_punct(c)   -- p
  elseif l == 115 then res = is_space(c)   -- s
  elseif l == 117 then res = is_upper(c)   -- u
  elseif l == 119 then res = is_alnum(c)   -- w
  elseif l == 120 then res = is_xdigit(c)  -- x
  elseif l == 122 then res = (c == 0)      -- z (the zero byte)
  else return cl == c end
  if is_upper(cl) then return not res end
  return res
end

-- MatchState class
local MS = {}
MS.__index = MS

local function new_ms(I, s, p)
  return setmetatable({
    I = I, s = s, p = p, slen = #s, plen = #p,
    src_end = #s + 1, p_end = #p + 1,
    level = 0, caps = {}, depth = 0,
  }, MS)
end

function MS:err(msg)
  self.I:rt_error(msg)
end

-- index after the class beginning at pi
function MS:classend(pi)
  local p = self.p
  local c = byte(p, pi); pi = pi + 1
  if c == L_ESC then
    if pi > self.plen then self:err("malformed pattern (ends with '%')") end
    return pi + 1
  elseif c == 91 then            -- '['
    if byte(p, pi) == 94 then pi = pi + 1 end  -- '^'
    repeat
      if pi > self.plen then self:err("malformed pattern (missing ']')") end
      local cc = byte(p, pi); pi = pi + 1
      if cc == L_ESC and pi <= self.plen then pi = pi + 1 end
    until byte(p, pi) == 93     -- ']'
    return pi + 1
  else
    return pi
  end
end

-- does char `c` match the set [ ... ] spanning p[pi..ec) ?  (pi at '[', ec at ']')
function MS:match_bracket(c, pi, ec)
  local p = self.p
  local sig = true
  if byte(p, pi + 1) == 94 then sig = false; pi = pi + 1 end  -- '^'
  pi = pi + 1
  while pi < ec do
    if byte(p, pi) == L_ESC then
      pi = pi + 1
      if match_class(c, byte(p, pi)) then return sig end
      pi = pi + 1
    elseif byte(p, pi + 1) == 45 and pi + 2 < ec then          -- '-' range
      if byte(p, pi) <= c and c <= byte(p, pi + 2) then return sig end
      pi = pi + 3
    else
      if byte(p, pi) == c then return sig end
      pi = pi + 1
    end
  end
  return not sig
end

-- does the single pattern item at p[pi..ep) match s[si]?
function MS:single_match(si, pi, ep)
  if si > self.slen then return false end
  local c = byte(self.s, si)
  local pc = byte(self.p, pi)
  if pc == 46 then return true                       -- '.'
  elseif pc == L_ESC then return match_class(c, byte(self.p, pi + 1))
  elseif pc == 91 then return self:match_bracket(c, pi, ep - 1)  -- '['
  else return pc == c end
end

function MS:match_balance(si, pi)
  if pi + 1 > self.plen then
    self:err("malformed pattern (missing arguments to '%b')")
  end
  if si > self.slen or byte(self.s, si) ~= byte(self.p, pi) then return nil end
  local b = byte(self.p, pi)
  local e = byte(self.p, pi + 1)
  local cont = 1
  si = si + 1
  while si <= self.slen do
    local c = byte(self.s, si)
    if c == e then
      cont = cont - 1
      if cont == 0 then return si + 1 end
    elseif c == b then
      cont = cont + 1
    end
    si = si + 1
  end
  return nil
end

function MS:max_expand(si, pi, ep)
  local i = 0
  while self:single_match(si + i, pi, ep) do i = i + 1 end
  while i >= 0 do
    local res = self:match(si + i, ep + 1)
    if res then return res end
    i = i - 1
  end
  return nil
end

function MS:min_expand(si, pi, ep)
  while true do
    local res = self:match(si, ep + 1)
    if res then return res end
    if self:single_match(si, pi, ep) then si = si + 1 else return nil end
  end
end

function MS:start_capture(si, pi, what)
  local level = self.level + 1
  if level > MAXCAPS then self:err("too many captures") end
  self.caps[level] = { init = si, len = what }
  self.level = level
  local res = self:match(si, pi)
  if not res then self.level = self.level - 1 end
  return res
end

function MS:end_capture(si, pi)
  -- find last unfinished capture
  local l
  for i = self.level, 1, -1 do
    if self.caps[i].len == CAP_UNFINISHED then l = i; break end
  end
  if not l then self:err("invalid pattern capture") end
  self.caps[l].len = si - self.caps[l].init
  local res = self:match(si, pi)
  if not res then self.caps[l].len = CAP_UNFINISHED end
  return res
end

function MS:match_capture(si, idx)
  idx = idx - 48 - 1                         -- '%1' -> capture index 0-based..
  if idx < 0 or idx >= self.level or self.caps[idx + 1].len == CAP_UNFINISHED then
    self:err("invalid capture index %" .. (idx + 1))
  end
  local cap = self.caps[idx + 1]
  local len = cap.len
  if len == CAP_POSITION then return nil end   -- position capture never matches
  if self.slen - si + 1 >= len and
     sub(self.s, cap.init, cap.init + len - 1) == sub(self.s, si, si + len - 1) then
    return si + len
  end
  return nil
end

-- core matcher: returns end index in s (one past match) or nil
function MS:match(si, pi)
  self.depth = self.depth + 1
  if self.depth > 220 then self:err("pattern too complex") end
  local r = self:match_(si, pi)
  self.depth = self.depth - 1
  return r
end

function MS:match_(si, pi)
  while pi <= self.plen do
    local pc = byte(self.p, pi)
    if pc == 40 then                          -- '('
      if byte(self.p, pi + 1) == 41 then      -- '()' position capture
        return self:start_capture(si, pi + 2, CAP_POSITION)
      else
        return self:start_capture(si, pi + 1, CAP_UNFINISHED)
      end
    elseif pc == 41 then                       -- ')'
      return self:end_capture(si, pi + 1)
    elseif pc == 36 and pi == self.plen then   -- '$' at end
      if si == self.src_end then return si else return nil end
    elseif pc == L_ESC then
      local nc = byte(self.p, pi + 1)
      if nc == 98 then                         -- '%b'
        local res = self:match_balance(si, pi + 2)
        if res then si = res; pi = pi + 4 else return nil end
      elseif nc == 102 then                    -- '%f'
        pi = pi + 2
        if byte(self.p, pi) ~= 91 then          -- '['
          self:err("missing '[' after '%f' in pattern")
        end
        local ep = self:classend(pi)
        local prev = (si == 1) and 0 or byte(self.s, si - 1)
        local cur = (si > self.slen) and 0 or byte(self.s, si)
        if (not self:match_bracket(prev, pi, ep - 1)) and
           self:match_bracket(cur, pi, ep - 1) then
          pi = ep
        else
          return nil
        end
      elseif nc and nc >= 48 and nc <= 57 then -- '%1'..'%9' back-reference
        local res = self:match_capture(si, nc)
        if res then si = res; pi = pi + 2 else return nil end
      else
        -- default: a single-char class (%a etc.), possibly with a suffix
        local r, nsi, npi = self:default_match(si, pi)
        if r ~= "cont" then return r end
        si = nsi; pi = npi                       -- loop instead of recursing
      end
    else
      local r, nsi, npi = self:default_match(si, pi)
      if r ~= "cont" then return r end
      si = nsi; pi = npi                         -- loop instead of recursing
    end
  end
  return si
end

-- Match a single-char class at `pi` (with optional quantifier suffix). Returns
-- either ("cont", si, pi) to continue the outer match loop (no recursion, so
-- long literal patterns don't blow the depth limit), or a final result/nil.
function MS:default_match(si, pi)
  local ep = self:classend(pi)
  if not self:single_match(si, pi, ep) then
    local epc = byte(self.p, ep)
    if epc == 42 or epc == 63 or epc == 45 then  -- '*' '?' '-' : match zero
      return "cont", si, ep + 1
    end
    return nil
  end
  local epc = byte(self.p, ep)
  if epc == 63 then                              -- '?'
    local res = self:match(si + 1, ep + 1)
    if res then return res end
    return "cont", si, ep + 1
  elseif epc == 43 then                          -- '+'
    return self:max_expand(si + 1, pi, ep)
  elseif epc == 42 then                          -- '*'
    return self:max_expand(si, pi, ep)
  elseif epc == 45 then                          -- '-'
    return self:min_expand(si, pi, ep)
  else
    return "cont", si + 1, ep                    -- no suffix: advance and loop
  end
end

-- collect a single capture's value (string or position)
function MS:get_capture(i, si, ei)
  if i > self.level then
    if i == 0 then return sub(self.s, si, ei - 1) end   -- whole match
    self:err("invalid capture index %" .. (i + 1))
  end
  local cap = self.caps[i]
  if cap.len == CAP_POSITION then return cap.init end    -- position (number)
  if cap.len == CAP_UNFINISHED then self:err("unfinished capture") end
  return sub(self.s, cap.init, cap.init + cap.len - 1)
end

-- push all captures (or the whole match if there are none); returns count
function MS:push_captures(out, si, ei)
  if self.level == 0 then
    out[1] = sub(self.s, si, ei - 1)
    return 1
  end
  for i = 1, self.level do
    out[i] = self:get_capture(i, si, ei)
  end
  return self.level
end

-- adjust an init index per Lua semantics (1-based, negative from end)
local function posrelat(pos, len)
  if pos >= 0 then return pos
  elseif -pos > len then return 0
  else return len + pos + 1 end
end

-- whether the pattern has any special characters (for find plain optimization)
local SPECIALS = {}
for _, ch in ipairs({ "^", "$", "*", "+", "?", ".", "(", "[", "%", "-" }) do
  SPECIALS[byte(ch)] = true
end

-- ---------------------------------------------------------------------------
-- public entry points
-- ---------------------------------------------------------------------------

-- find: returns (start, end, captures...) as an array {n=...}, or {nil}
function M.find(I, s, p, init, plain)
  local ls = #s
  init = posrelat(init or 1, ls)
  if init < 1 then init = 1 elseif init > ls + 1 then return { n = 1, [1] = nil } end

  if plain then
    -- plain text search
    local found = M.plainfind(s, p, init)
    if found then return { n = 2, found, found + #p - 1 } end
    return { n = 1, [1] = nil }
  end

  local anchor = (byte(p, 1) == 94)            -- '^'
  local pstart = anchor and 2 or 1
  local si = init
  repeat
    local ms = new_ms(I, s, p)
    local e = ms:match(si, pstart)
    if e then
      local out = { si, e - 1, n = 2 }
      if ms.level > 0 then
        for i = 1, ms.level do out[2 + i] = ms:get_capture(i, si, e) end
        out.n = 2 + ms.level
      end
      return out
    end
    si = si + 1
  until anchor or si > ls + 1
  return { n = 1, [1] = nil }
end

function M.plainfind(s, p, init)
  if p == "" then return init end
  local ls, lp = #s, #p
  for i = init, ls - lp + 1 do
    if sub(s, i, i + lp - 1) == p then return i end
  end
  return nil
end

-- match: returns captures (or whole match) array {n=...}, or {nil}
function M.match(I, s, p, init)
  local ls = #s
  init = posrelat(init or 1, ls)
  if init < 1 then init = 1 elseif init > ls + 1 then return { n = 1, [1] = nil } end
  local anchor = (byte(p, 1) == 94)
  local pstart = anchor and 2 or 1
  local si = init
  repeat
    local ms = new_ms(I, s, p)
    local e = ms:match(si, pstart)
    if e then
      local out = {}
      local n = ms:push_captures(out, si, e)
      out.n = n
      return out
    end
    si = si + 1
  until anchor or si > ls + 1
  return { n = 1, [1] = nil }
end

-- gmatch: returns a stateful iterator function (host) yielding capture arrays
function M.gmatch(I, s, p, init)
  local ls = #s
  local pos = posrelat(init or 1, ls)
  if pos < 1 then pos = 1 end
  local lastmatch = nil
  local anchor = (byte(p, 1) == 94)
  local pstart = anchor and 2 or 1
  return function()
    while pos <= ls + 1 do
      local ms = new_ms(I, s, p)
      local e = ms:match(pos, pstart)
      if e and e ~= lastmatch then
        local out = {}
        local n = ms:push_captures(out, pos, e)
        out.n = n
        lastmatch = e
        pos = (e > pos) and e or pos + 1
        return out
      end
      pos = pos + 1
      if anchor then break end
    end
    return nil
  end
end

-- gsub: repl is a host function (whole, getcap, ncaps) -> replacement
-- (string/number) or nil/false (keep original). getcap(i) lazily fetches
-- capture i (erroring only when actually accessed). Returns result, count.
function M.gsub(I, s, p, repl, maxn)
  local ls = #s
  local anchor = (byte(p, 1) == 94)
  local pstart = anchor and 2 or 1
  local out = {}
  local count = 0
  local changed = false    -- whether any replacement actually differed
  local src = 1
  local lastmatch = nil    -- end of the previous (counted) match
  while not (maxn and count >= maxn) do
    local ms = new_ms(I, s, p)
    local e = ms:match(src, pstart)
    if e ~= nil and e ~= lastmatch then
      count = count + 1
      local whole = sub(s, src, e - 1)
      local ncaps = (ms.level == 0) and 1 or ms.level
      local mend = e
      local function getcap(i)
        if ms.level == 0 then
          if i == 1 then return whole end
          ms:err("invalid capture index %" .. i .. " in replacement string")
        end
        return ms:get_capture(i, src, mend)
      end
      local r = repl(whole, getcap, ncaps)
      if r == nil or r == false then
        out[#out + 1] = whole        -- keep original text (no change)
      else
        out[#out + 1] = r
        changed = true
      end
      src = e
      lastmatch = e
    elseif src <= ls then
      out[#out + 1] = sub(s, src, src)
      src = src + 1
    else
      break
    end
    if anchor then break end
  end
  -- if nothing changed, return the original string object (Lua reuses it, so
  -- string.format("%p", gsub(s,...)) == string.format("%p", s) -- see pm.lua)
  if not changed then return s, count end
  if src <= ls then out[#out + 1] = sub(s, src, ls) end
  return table.concat(out), count
end

return M
