-- lua55vm/lexer.lua
-- A complete tokenizer for Lua 5.5 source.
--
-- Produces a flat array of token tables:
--   { type = <string>, value = <any>, line = <int> }
--
-- Token types:
--   "name"     value = identifier string
--   "number"   value = host number (int/float subtype preserved via tonumber)
--   "string"   value = decoded string contents
--   "keyword"  value = the keyword text
--   "op"       value = the operator/punctuation text
--   "eof"      value = nil
--
-- Numeric literals are converted with the host tonumber(), so integer/float
-- subtype matches Lua exactly on a 5.4/5.5 host.

local Lexer = {}
Lexer.__index = Lexer

local KEYWORDS = {}
for _, kw in ipairs({
  "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
  "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return",
  "then", "true", "until", "while",
}) do KEYWORDS[kw] = true end

local function is_digit(c) return c ~= nil and c >= "0" and c <= "9" end
local function is_hex(c)
  return c ~= nil and (is_digit(c) or (c >= "a" and c <= "f") or (c >= "A" and c <= "F"))
end
local function is_alpha(c)
  return c ~= nil and ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_")
end
local function is_alnum(c) return is_alpha(c) or is_digit(c) end
local function is_space(c) return c == " " or c == "\t" or c == "\v" or c == "\f" end

function Lexer.new(src, chunkname)
  local self = setmetatable({}, Lexer)
  self.src = src
  self.pos = 1
  self.line = 1
  self.chunkname = chunkname or "?"
  self.len = #src
  -- NOTE: shebang ('#...') skipping is done by the file loaders (loadfile /
  -- dofile / require), NOT here -- load(string) must not skip a leading '#'.
  return self
end

function Lexer:error(msg, line, near)
  line = line or self.line
  local s = string.format("%s:%d: %s", self.chunkname, line, msg)
  if near == "<eof>" then        -- <eof> token is printed unquoted, like Lua
    s = s .. " near <eof>"
  elseif near ~= nil then
    s = s .. " near '" .. near .. "'"
  end
  error(s, 0)
end

function Lexer:peek(o)
  local p = self.pos + (o or 0)
  if p > self.len then return nil end
  return self.src:sub(p, p)
end

function Lexer:advance()
  local c = self:peek()
  self.pos = self.pos + 1
  return c
end

-- Handle a newline (\n, \r, \n\r, \r\n) advancing line counter.
function Lexer:newline()
  local c = self:peek()
  self.pos = self.pos + 1            -- consume first EOL char
  local c2 = self:peek()
  if (c2 == "\n" or c2 == "\r") and c2 ~= c then
    self.pos = self.pos + 1          -- consume paired EOL char
  end
  self.line = self.line + 1
end

-- Read a long-bracket body, given the opening level. Returns the contents.
-- Assumes the opening [==[ has already been consumed up to and including
-- the second '['. Used by both long strings and long comments.
function Lexer:read_long(level, is_comment)
  local parts = {}
  -- skip a first newline immediately following the opening bracket
  local c = self:peek()
  if c == "\n" or c == "\r" then self:newline() end
  while true do
    c = self:peek()
    if c == nil then
      self:error((is_comment and "unfinished long comment" or "unfinished long string"),
        nil, "<eof>")
    elseif c == "]" then
      -- check for closing bracket of matching level
      local save = self.pos
      self.pos = self.pos + 1
      local n = 0
      while self:peek() == "=" do n = n + 1; self.pos = self.pos + 1 end
      if n == level and self:peek() == "]" then
        self.pos = self.pos + 1
        break
      else
        -- not a match: emit the '[' literally and rewind
        self.pos = save + 1
        parts[#parts + 1] = "]"
      end
    elseif c == "\n" or c == "\r" then
      self:newline()
      parts[#parts + 1] = "\n"
    else
      parts[#parts + 1] = c
      self.pos = self.pos + 1
    end
  end
  return table.concat(parts)
end

-- Try to read an opening long bracket [[ or [=*[ . Returns level or nil.
-- Only consumes input if it is in fact an opening long bracket.
function Lexer:try_long_bracket()
  if self:peek() ~= "[" then return nil end
  local save = self.pos
  self.pos = self.pos + 1
  local level = 0
  while self:peek() == "=" do level = level + 1; self.pos = self.pos + 1 end
  if self:peek() == "[" then
    self.pos = self.pos + 1
    return level
  end
  self.pos = save
  return nil
end

function Lexer:skip_ws_and_comments()
  while true do
    local c = self:peek()
    if c == nil then return end
    if c == "\n" or c == "\r" then
      self:newline()
    elseif is_space(c) then
      self.pos = self.pos + 1
    elseif c == "-" and self:peek(1) == "-" then
      self.pos = self.pos + 2
      local level = self:try_long_bracket()
      if level then
        self:read_long(level, true)
      else
        -- line comment
        while true do
          local cc = self:peek()
          if cc == nil or cc == "\n" or cc == "\r" then break end
          self.pos = self.pos + 1
        end
      end
    else
      return
    end
  end
end

function Lexer:read_number()
  local start = self.pos
  local line = self.line
  local expo = "eE"
  if self:peek() == "0" and (self:peek(1) == "x" or self:peek(1) == "X") then
    self.pos = self.pos + 2
    expo = "pP"
  end
  while true do
    local c = self:peek()
    if c ~= nil and expo:find(c, 1, true) then
      self.pos = self.pos + 1
      local s = self:peek()
      if s == "+" or s == "-" then self.pos = self.pos + 1 end
    elseif c == "." or is_alnum(c) then
      -- accept hex digits / digits / '.' / exponent letters greedily,
      -- malformed combos are rejected by tonumber below.
      self.pos = self.pos + 1
    else
      break
    end
  end
  local text = self.src:sub(start, self.pos - 1)
  local value = tonumber(text)
  if value == nil then
    self:error("malformed number near '" .. text .. "'", line)
  end
  return { type = "number", value = value, line = line, text = text }
end

local SHORT_ESCAPES = {
  a = "\a", b = "\b", f = "\f", n = "\n", r = "\r",
  t = "\t", v = "\v", ["\\"] = "\\", ['"'] = '"', ["'"] = "'",
}

-- encode a codepoint as UTF-8 (Lua allows up to 0x7FFFFFFF, 6 bytes)
local function utf8_encode(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
  elseif cp < 0x10000 then
    return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
  elseif cp < 0x200000 then
    return string.char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
                       0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
  elseif cp < 0x4000000 then
    return string.char(0xF8 | (cp >> 24), 0x80 | ((cp >> 18) & 0x3F),
                       0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
  else
    return string.char(0xFC | (cp >> 30), 0x80 | ((cp >> 24) & 0x3F),
                       0x80 | ((cp >> 18) & 0x3F), 0x80 | ((cp >> 12) & 0x3F),
                       0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
  end
end

function Lexer:read_short_string()
  local startpos = self.pos          -- opening delimiter (for "near" messages)
  local quote = self:advance()
  local line = self.line
  local parts = {}
  -- raw source consumed so far, quoted, matching Lua's error-buffer ("near")
  local function serr(msg) self:error(msg, line, self.src:sub(startpos, self.pos)) end
  while true do
    local c = self:peek()
    if c == nil then
      self:error("unfinished string", line, "<eof>")
    elseif c == "\n" or c == "\r" then
      self:error("unfinished string", line, self.src:sub(startpos, self.pos - 1))
    elseif c == quote then
      self.pos = self.pos + 1
      break
    elseif c == "\\" then
      self.pos = self.pos + 1
      local e = self:peek()
      if e == nil then self:error("unfinished string", line, "<eof>") end
      local simple = SHORT_ESCAPES[e]
      if simple then
        parts[#parts + 1] = simple
        self.pos = self.pos + 1
      elseif e == "\n" or e == "\r" then
        self:newline()
        parts[#parts + 1] = "\n"
      elseif e == "x" then
        self.pos = self.pos + 1
        local h1, h2 = self:peek(), self:peek(1)
        if not is_hex(h1) then serr("hexadecimal digit expected") end
        if not is_hex(h2) then self.pos = self.pos + 1; serr("hexadecimal digit expected") end
        parts[#parts + 1] = string.char(tonumber(h1 .. h2, 16))
        self.pos = self.pos + 2
      elseif e == "z" then
        self.pos = self.pos + 1
        while true do
          local s = self:peek()
          if s == "\n" or s == "\r" then self:newline()
          elseif s ~= nil and is_space(s) then self.pos = self.pos + 1
          else break end
        end
      elseif e == "u" then
        self.pos = self.pos + 1
        if self:peek() ~= "{" then serr("missing '{'") end
        self.pos = self.pos + 1
        if not is_hex(self:peek()) then serr("hexadecimal digit expected") end
        local cp = 0
        while is_hex(self:peek()) do
          cp = cp * 16 + tonumber(self:advance(), 16)
          if cp > 0x7FFFFFFF then
            self:error("UTF-8 value too large", line,
              self.src:sub(startpos, self.pos - 1))
          end
        end
        if self:peek() ~= "}" then serr("missing '}'") end
        self.pos = self.pos + 1
        parts[#parts + 1] = utf8_encode(cp)
      elseif is_digit(e) then
        local num = 0
        local n = 0
        while n < 3 and is_digit(self:peek()) do
          num = num * 10 + tonumber(self:advance())
          n = n + 1
        end
        if num > 255 then serr("decimal escape too large") end
        parts[#parts + 1] = string.char(num)
      else
        serr("invalid escape sequence")
      end
    else
      parts[#parts + 1] = c
      self.pos = self.pos + 1
    end
  end
  return { type = "string", value = table.concat(parts), line = line }
end

function Lexer:next_token()
  self:skip_ws_and_comments()
  local line = self.line
  local c = self:peek()
  if c == nil then
    return { type = "eof", line = line }
  end

  if is_alpha(c) then
    local start = self.pos
    while is_alnum(self:peek()) do self.pos = self.pos + 1 end
    local word = self.src:sub(start, self.pos - 1)
    if KEYWORDS[word] then
      return { type = "keyword", value = word, line = line }
    end
    return { type = "name", value = word, line = line }
  end

  if is_digit(c) or (c == "." and is_digit(self:peek(1))) then
    return self:read_number()
  end

  if c == '"' or c == "'" then
    return self:read_short_string()
  end

  if c == "[" and (self:peek(1) == "[" or self:peek(1) == "=") then
    local level = self:try_long_bracket()
    if level then
      local s = self:read_long(level, false)
      return { type = "string", value = s, line = line }
    end
    -- otherwise fall through to operator handling for a lone '['
  end

  -- operators / punctuation (longest match first)
  local two = self:peek() .. (self:peek(1) or "")
  local three = two .. (self:peek(2) or "")
  if three == "..." then
    self.pos = self.pos + 3
    return { type = "op", value = "...", line = line }
  end
  local TWO = {
    ["=="] = true, ["~="] = true, ["<="] = true, [">="] = true,
    [".."] = true, ["::"] = true, ["//"] = true, ["<<"] = true, [">>"] = true,
  }
  if TWO[two] then
    self.pos = self.pos + 2
    return { type = "op", value = two, line = line }
  end
  local ONE = {
    ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["%"] = true,
    ["^"] = true, ["#"] = true, ["&"] = true, ["~"] = true, ["|"] = true,
    ["<"] = true, [">"] = true, ["="] = true, ["("] = true, [")"] = true,
    ["{"] = true, ["}"] = true, ["["] = true, ["]"] = true, [";"] = true,
    [":"] = true, [","] = true, ["."] = true,
  }
  if ONE[c] then
    self.pos = self.pos + 1
    return { type = "op", value = c, line = line }
  end

  self:error(string.format("unexpected symbol near '%s'", c), line)
end

-- Tokenize the whole source into a flat array, terminated by an eof token.
function Lexer:tokenize()
  local toks = {}
  while true do
    local t = self:next_token()
    toks[#toks + 1] = t
    if t.type == "eof" then break end
  end
  return toks
end

local M = {}
function M.tokenize(src, chunkname)
  return Lexer.new(src, chunkname):tokenize()
end
M.Lexer = Lexer
M.utf8_encode = utf8_encode
M.KEYWORDS = KEYWORDS
return M
