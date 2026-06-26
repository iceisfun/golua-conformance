-- lua55vm/parser.lua
-- Recursive-descent parser for Lua 5.5 producing an AST of plain tables.
--
-- Every node carries a `tag` and (where useful) a `line`.
--
-- Statement tags:
--   LocalAssign  { names={str}, attribs={str|nil}, exprs={expr} }
--   LocalFunction{ name=str, func=Function }
--   Assign       { targets={lhs}, exprs={expr} }
--   CallStat     { call=Call|MethodCall }
--   Do           { body=block }
--   While        { cond, body }
--   Repeat       { body, cond }
--   If           { clauses={{cond,body}}, els=block|nil }
--   NumericFor   { name, start, limit, step|nil, body }
--   GenericFor   { names={str}, exprs={expr}, body }
--   Return       { exprs={expr} }
--   Break        {}
--   Goto         { label=str }
--   Label        { name=str }
--
-- Expression tags:
--   Nil True False Vararg
--   Number{value}  String{value}  Name{name}
--   Index{obj,key}  Call{func,args}  MethodCall{obj,method,args}
--   Function{params={str}, is_vararg, body, line}
--   Table{fields={ {kind="item",value} | {kind="rec",key,value} }}
--   BinOp{op,lhs,rhs}  UnOp{op,operand}  Paren{expr}

local Parser = {}
Parser.__index = Parser

function Parser.new(tokens, chunkname)
  return setmetatable({
    toks = tokens, i = 1, chunkname = chunkname or "?",
  }, Parser)
end

function Parser:cur() return self.toks[self.i] end
function Parser:lookahead() return self.toks[self.i + 1] end
function Parser:advance()
  local t = self.toks[self.i]
  self.i = self.i + 1
  return t
end

function Parser:error(msg, line)
  local t = self:cur()
  line = line or (t and t.line) or 0
  error(string.format("%s:%d: %s", self.chunkname, line, msg), 0)
end

-- token description for error messages
local function tokdesc(t)
  if not t then return "<eof>" end
  if t.type == "eof" then return "<eof>" end
  if t.type == "string" then return "<string>" end
  if t.type == "number" then return "'" .. tostring(t.text or t.value) .. "'" end
  return "'" .. tostring(t.value) .. "'"
end

function Parser:check(typ, val)
  local t = self:cur()
  if t.type ~= typ then return false end
  if val ~= nil and t.value ~= val then return false end
  return true
end

-- is current token the given op/keyword text?
function Parser:is(val)
  local t = self:cur()
  return (t.type == "op" or t.type == "keyword") and t.value == val
end

function Parser:accept(val)
  if self:is(val) then return self:advance() end
  return nil
end

function Parser:expect(val, what)
  if self:is(val) then return self:advance() end
  self:error(string.format("'%s' expected near %s", val, tokdesc(self:cur())))
end

-- expect matching close, reporting the line where the opener was
function Parser:expect_match(val, openval, openline)
  if self:is(val) then return self:advance() end
  if openline == self:cur().line then
    self:error(string.format("'%s' expected near %s", val, tokdesc(self:cur())))
  else
    self:error(string.format("'%s' expected (to close '%s' at line %d) near %s",
      val, openval, openline, tokdesc(self:cur())))
  end
end

function Parser:expect_name()
  local t = self:cur()
  if t.type ~= "name" then
    self:error("<name> expected near " .. tokdesc(t))
  end
  self:advance()
  return t.value
end

-- ---------------------------------------------------------------------------
-- Blocks & statements
-- ---------------------------------------------------------------------------

-- tokens that close a block
local BLOCK_END = {
  ["end"] = true, ["else"] = true, ["elseif"] = true, ["until"] = true,
}

-- `keep_trailing_scope` (repeat-until) means the block's scope continues past
-- its end (into the `until` condition), so trailing labels are NOT void.
function Parser:block(keep_trailing_scope)
  local stmts = {}
  while true do
    local t = self:cur()
    if t.type == "eof" or (t.type == "keyword" and BLOCK_END[t.value]) then
      break
    end
    if self:is("return") then
      stmts[#stmts + 1] = self:return_stat()
      break  -- return must be last
    end
    local s = self:statement()
    if s then stmts[#stmts + 1] = s end
  end
  -- mark "void" labels: a label followed only by other labels (or block end).
  -- A goto to a void label never jumps into the scope of the block's locals.
  -- (Not for a repeat body: its `until` condition keeps the scope alive.)
  if not keep_trailing_scope then
    local trailing = true
    for i = #stmts, 1, -1 do
      if stmts[i].tag == "Label" then
        if trailing then stmts[i].void = true end
      else
        trailing = false
      end
    end
  end
  return { tag = "Block", stmts = stmts }
end

function Parser:statement()
  local t = self:cur()
  local line = t.line

  if t.type == "op" and t.value == ";" then
    self:advance(); return nil
  end
  if t.type == "op" and t.value == "::" then
    return self:label_stat()
  end
  -- Lua 5.5 `global` is a contextual keyword: a declaration only when followed
  -- by a name, `<attrib>`, or `*`; otherwise it is an ordinary identifier.
  if t.type == "name" and t.value == "global" then
    local la = self:lookahead()
    if la and (la.type == "name"
       or (la.type == "keyword" and la.value == "function")
       or (la.type == "op" and (la.value == "<" or la.value == "*"))) then
      return self:global_stat()
    end
  end
  if t.type == "keyword" then
    local k = t.value
    if k == "if" then return self:if_stat() end
    if k == "while" then return self:while_stat() end
    if k == "do" then
      self:advance()
      local body = self:block()
      self:expect_match("end", "do", line)
      return { tag = "Do", body = body, line = line }
    end
    if k == "for" then return self:for_stat() end
    if k == "repeat" then return self:repeat_stat() end
    if k == "function" then return self:function_stat() end
    if k == "local" then return self:local_stat() end
    if k == "break" then self:advance(); return { tag = "Break", line = line } end
    if k == "goto" then
      self:advance()
      local name = self:expect_name()
      return { tag = "Goto", label = name, line = line }
    end
  end
  return self:expr_stat()
end

-- global [<attrib>] ( '*'
--                    | 'function' name funcbody
--                    | name [<attrib>] {',' name [<attrib>]} ['=' exprlist] )
function Parser:global_stat()
  local line = self:cur().line
  self:advance()                       -- 'global'
  local default_attr = nil
  if self:is("<") then
    self:advance(); default_attr = self:expect_name(); self:expect(">")
  end
  -- global function name funcbody  ==  declare name + name = function...
  if self:accept("function") then
    local name = self:expect_name()
    local func = self:funcbody(line, false)
    return { tag = "Global", names = { name }, attribs = { default_attr },
             star = false, exprs = { func }, is_function = true, line = line }
  end
  if self:is("*") then
    self:advance()
    return { tag = "Global", star = true, attrib = default_attr, line = line }
  end
  local names, attribs = {}, {}
  repeat
    names[#names + 1] = self:expect_name()
    local at = default_attr
    if self:accept("<") then at = self:expect_name(); self:expect(">") end
    attribs[#names] = at
  until not self:accept(",")
  local exprs = nil
  if self:accept("=") then exprs = self:exprlist() end
  return { tag = "Global", names = names, attribs = attribs, star = false,
           exprs = exprs, line = line }
end

function Parser:label_stat()
  local line = self:cur().line
  self:expect("::")
  local name = self:expect_name()
  self:expect("::")
  return { tag = "Label", name = name, line = line }
end

function Parser:return_stat()
  local line = self:cur().line
  self:expect("return")
  local exprs = {}
  local t = self:cur()
  local block_end = (t.type == "eof") or (t.type == "keyword" and BLOCK_END[t.value])
  if not block_end and not self:is(";") then
    exprs = self:exprlist()
  end
  self:accept(";")
  return { tag = "Return", exprs = exprs, line = line }
end

function Parser:if_stat()
  local line = self:cur().line
  self:advance()  -- if
  local clauses = {}
  local cond = self:expr()
  self:expect("then")
  local body = self:block()
  clauses[#clauses + 1] = { cond = cond, body = body }
  while self:is("elseif") do
    self:advance()
    local c = self:expr()
    self:expect("then")
    local b = self:block()
    clauses[#clauses + 1] = { cond = c, body = b }
  end
  local els = nil
  if self:accept("else") then
    els = self:block()
  end
  self:expect_match("end", "if", line)
  return { tag = "If", clauses = clauses, els = els, line = line }
end

function Parser:while_stat()
  local line = self:cur().line
  self:advance()
  local cond = self:expr()
  self:expect("do")
  local body = self:block()
  self:expect_match("end", "while", line)
  return { tag = "While", cond = cond, body = body, line = line }
end

function Parser:repeat_stat()
  local line = self:cur().line
  self:advance()
  local body = self:block(true)   -- until-condition keeps the body's scope
  self:expect_match("until", "repeat", line)
  local cond = self:expr()
  return { tag = "Repeat", body = body, cond = cond, line = line }
end

function Parser:for_stat()
  local line = self:cur().line
  self:advance()  -- for
  local name1 = self:expect_name()
  if self:is("=") then
    self:advance()
    local starte = self:expr()
    self:expect(",")
    local limite = self:expr()
    local stepe = nil
    if self:accept(",") then stepe = self:expr() end
    self:expect("do")
    local body = self:block()
    self:expect_match("end", "for", line)
    return { tag = "NumericFor", name = name1, start = starte, limit = limite,
             step = stepe, body = body, line = line }
  else
    local names = { name1 }
    while self:accept(",") do names[#names + 1] = self:expect_name() end
    self:expect("in")
    local exprs = self:exprlist()
    self:expect("do")
    local body = self:block()
    self:expect_match("end", "for", line)
    return { tag = "GenericFor", names = names, exprs = exprs, body = body, line = line }
  end
end

-- function Name funcbody    (Name can be a.b.c or a.b:c)
function Parser:function_stat()
  local line = self:cur().line
  self:advance()  -- function
  -- build target lhs from dotted name
  local target = { tag = "Name", name = self:expect_name(), line = line }
  local is_method = false
  while self:is(".") do
    self:advance()
    local key = self:expect_name()
    target = { tag = "Index", obj = target,
               key = { tag = "String", value = key }, line = line }
  end
  if self:accept(":") then
    local key = self:expect_name()
    target = { tag = "Index", obj = target,
               key = { tag = "String", value = key }, line = line }
    is_method = true
  end
  local func = self:funcbody(line, is_method)
  return { tag = "Assign", targets = { target }, exprs = { func }, line = line }
end

-- funcbody: '(' parlist ')' block 'end'  -- 'function' already consumed
function Parser:funcbody(line, is_method)
  self:expect("(")
  local params = {}
  local is_vararg = false
  local vararg_name = nil
  if is_method then params[#params + 1] = "self" end
  if not self:is(")") then
    repeat
      if self:is("...") then
        self:advance(); is_vararg = true
        -- Lua 5.5 named vararg: ...name binds the extra args as a table
        if self:check("name") then vararg_name = self:advance().value end
        break
      end
      params[#params + 1] = self:expect_name()
    until not self:accept(",")
  end
  self:expect(")")
  local body = self:block()
  local endline = self:cur().line
  self:expect_match("end", "function", line)
  return { tag = "Function", params = params, is_vararg = is_vararg,
           vararg_name = vararg_name, body = body, line = line, endline = endline }
end

function Parser:local_stat()
  local line = self:cur().line
  self:advance()  -- local
  if self:accept("function") then
    local name = self:expect_name()
    local func = self:funcbody(line, false)
    return { tag = "LocalFunction", name = name, func = func, line = line }
  end
  -- Lua 5.5: an optional leading <attrib> applies to every name in the list
  local default_attr = nil
  if self:is("<") then
    self:advance()
    default_attr = self:expect_name()
    if default_attr ~= "const" and default_attr ~= "close" then
      self:error("unknown attribute '" .. default_attr .. "'")
    end
    self:expect(">")
  end
  local names = {}
  local attribs = {}
  repeat
    names[#names + 1] = self:expect_name()
    local attr = default_attr
    if self:accept("<") then
      attr = self:expect_name()
      if attr ~= "const" and attr ~= "close" then
        self:error("unknown attribute '" .. attr .. "'")
      end
      self:expect(">")
    end
    attribs[#names] = attr
  until not self:accept(",")
  local exprs = {}
  if self:accept("=") then
    exprs = self:exprlist()
  end
  -- record the token that follows (used for the "near X" in a too-many-locals error)
  return { tag = "LocalAssign", names = names, attribs = attribs,
           exprs = exprs, line = line,
           _near = tokdesc(self:cur()), _near_line = self:cur().line }
end

-- expression statement: either a call, or an assignment
function Parser:expr_stat()
  local line = self:cur().line
  local e = self:suffixed_expr()
  if self:is("=") or self:is(",") then
    local targets = { e }
    while self:accept(",") do
      targets[#targets + 1] = self:suffixed_expr()
    end
    self:expect("=")
    local exprs = self:exprlist()
    for _, tgt in ipairs(targets) do
      if tgt.tag ~= "Name" and tgt.tag ~= "Index" then
        self:error("cannot assign to this expression", line)
      end
    end
    return { tag = "Assign", targets = targets, exprs = exprs, line = line }
  end
  if e.tag ~= "Call" and e.tag ~= "MethodCall" then
    self:error("syntax error near " .. tokdesc(self:cur()))
  end
  return { tag = "CallStat", call = e, line = line }
end

-- ---------------------------------------------------------------------------
-- Expressions
-- ---------------------------------------------------------------------------

function Parser:exprlist()
  local list = { self:expr() }
  while self:accept(",") do
    list[#list + 1] = self:expr()
  end
  return list
end

-- binary operator priorities {left, right}
local BINPRI = {
  ["or"] = { 1, 1 }, ["and"] = { 2, 2 },
  ["<"] = { 3, 3 }, [">"] = { 3, 3 }, ["<="] = { 3, 3 },
  [">="] = { 3, 3 }, ["~="] = { 3, 3 }, ["=="] = { 3, 3 },
  ["|"] = { 4, 4 }, ["~"] = { 5, 5 }, ["&"] = { 6, 6 },
  ["<<"] = { 7, 7 }, [">>"] = { 7, 7 },
  [".."] = { 9, 8 },  -- right associative
  ["+"] = { 10, 10 }, ["-"] = { 10, 10 },
  ["*"] = { 11, 11 }, ["/"] = { 11, 11 }, ["//"] = { 11, 11 }, ["%"] = { 11, 11 },
  ["^"] = { 14, 13 }, -- right associative
}
local UNARY_PRI = 12
local UNOPS = { ["not"] = true, ["-"] = true, ["#"] = true, ["~"] = true }

function Parser:expr(limit)
  limit = limit or 0
  local line = self:cur().line
  local e
  local t = self:cur()
  if (t.type == "op" or t.type == "keyword") and UNOPS[t.value] then
    local op = t.value
    self:advance()
    local operand = self:expr(UNARY_PRI)
    e = { tag = "UnOp", op = op, operand = operand, line = line }
  else
    e = self:simple_expr()
  end
  -- binary operators
  while true do
    local ct = self:cur()
    if ct.type ~= "op" and ct.type ~= "keyword" then break end
    local pri = BINPRI[ct.value]
    if not pri or pri[1] <= limit then break end
    local op = ct.value
    local opline = ct.line
    self:advance()
    local rhs = self:expr(pri[2])
    e = { tag = "BinOp", op = op, lhs = e, rhs = rhs, line = opline }
  end
  return e
end

function Parser:simple_expr()
  local t = self:cur()
  local line = t.line
  if t.type == "number" then
    self:advance(); return { tag = "Number", value = t.value, line = line }
  end
  if t.type == "string" then
    self:advance(); return { tag = "String", value = t.value, line = line }
  end
  if t.type == "keyword" then
    if t.value == "nil" then self:advance(); return { tag = "Nil", line = line } end
    if t.value == "true" then self:advance(); return { tag = "True", line = line } end
    if t.value == "false" then self:advance(); return { tag = "False", line = line } end
    if t.value == "function" then
      self:advance()
      return self:funcbody(line, false)
    end
  end
  if t.type == "op" then
    if t.value == "..." then self:advance(); return { tag = "Vararg", line = line } end
    if t.value == "{" then return self:table_constructor() end
  end
  return self:suffixed_expr()
end

-- primary: Name or '(' expr ')'
function Parser:primary_expr()
  local t = self:cur()
  local line = t.line
  if t.type == "op" and t.value == "(" then
    self:advance()
    local e = self:expr()
    self:expect_match(")", "(", line)
    return { tag = "Paren", expr = e, line = line }
  end
  if t.type == "name" then
    self:advance()
    return { tag = "Name", name = t.value, line = line }
  end
  self:error("unexpected symbol near " .. tokdesc(t))
end

-- primary followed by any number of suffixes: .x  [e]  :m(args)  (args)
function Parser:suffixed_expr()
  local e = self:primary_expr()
  while true do
    local t = self:cur()
    local line = t.line
    if t.type == "op" and t.value == "." then
      self:advance()
      local name = self:expect_name()
      e = { tag = "Index", obj = e, key = { tag = "String", value = name }, line = line }
    elseif t.type == "op" and t.value == "[" then
      self:advance()
      local key = self:expr()
      self:expect_match("]", "[", line)
      e = { tag = "Index", obj = e, key = key, line = line }
    elseif t.type == "op" and t.value == ":" then
      self:advance()
      local method = self:expect_name()
      local args = self:call_args()
      e = { tag = "MethodCall", obj = e, method = method, args = args, line = line }
    elseif (t.type == "op" and (t.value == "(" or t.value == "{")) or t.type == "string" then
      local args = self:call_args()
      e = { tag = "Call", func = e, args = args, line = line }
    else
      break
    end
  end
  return e
end

function Parser:call_args()
  local t = self:cur()
  if t.type == "string" then
    self:advance()
    return { { tag = "String", value = t.value, line = t.line } }
  end
  if t.type == "op" and t.value == "{" then
    return { self:table_constructor() }
  end
  local line = t.line
  self:expect("(")
  local args = {}
  if not self:is(")") then
    args = self:exprlist()
  end
  self:expect_match(")", "(", line)
  return args
end

function Parser:table_constructor()
  local line = self:cur().line
  self:expect("{")
  local fields = {}
  while not self:is("}") do
    local t = self:cur()
    if t.type == "op" and t.value == "[" then
      self:advance()
      local key = self:expr()
      self:expect_match("]", "[", t.line)
      self:expect("=")
      local val = self:expr()
      fields[#fields + 1] = { kind = "rec", key = key, value = val }
    elseif t.type == "name" and self:lookahead() and
           self:lookahead().type == "op" and self:lookahead().value == "=" then
      local name = self:advance().value
      self:advance()  -- '='
      local val = self:expr()
      fields[#fields + 1] = { kind = "rec",
        key = { tag = "String", value = name }, value = val }
    else
      fields[#fields + 1] = { kind = "item", value = self:expr() }
    end
    if not (self:accept(",") or self:accept(";")) then break end
  end
  self:expect_match("}", "{", line)
  return { tag = "Table", fields = fields, line = line }
end

-- ---------------------------------------------------------------------------

function Parser:parse_chunk()
  local body = self:block()
  if self:cur().type ~= "eof" then
    self:error("'<eof>' expected near " .. tokdesc(self:cur()))
  end
  -- a chunk is a vararg function; its last line is the last real token's line
  local prev = self.toks[self.i - 1]
  return { tag = "Function", params = {}, is_vararg = true, body = body,
           line = 0, endline = (prev and prev.line) or 0, is_main = true }
end

local M = {}
function M.parse(tokens, chunkname)
  return Parser.new(tokens, chunkname):parse_chunk()
end
M.Parser = Parser
return M
