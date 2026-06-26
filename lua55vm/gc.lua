-- lua55vm/gc.lua
-- An educational tracing garbage collector for the guest (SOW Phase 2).
--
-- Guest objects (tables/closures/threads) are host tables, so the host owns the
-- actual memory; but the *observable* GC semantics — weak-table clearing on
-- collectgarbage(), __gc finalizers, deterministic reclamation — are ours.
-- This matches PUC Lua deterministically (unlike a runtime.GC()-backed
-- implementation, which cannot reliably clear a weak entry on demand).
--
-- collectgarbage("collect") runs a full mark & sweep from the real roots
-- (globals, registry, metatables, and every live call frame's registers /
-- upvalues / varargs across all reachable threads). The GC's own object list is
-- NOT a root, so an object reachable only weakly (or only via that list) is
-- correctly seen as garbage.

local rt = require("runtime")

local M = {}

local getmt = getmetatable
local TABLE_MT, CLOSURE_MT, THREAD_MT = rt.TABLE_MT, rt.CLOSURE_MT, rt.THREAD_MT

-- GC step size between automatic collections (rough bytes of new allocation)
local GCSTEP = 100000

function M.install(Interp)

  function Interp:gc_init()
    self.gc = {
      objects = {},        -- all tracked collectable objects
      finalizable = {},    -- obj -> true (had __gc when metatable was set)
      bytes = 0,           -- rough allocated-size estimate (for count)
      epoch = 0,
      weaklist = nil,
      debt = 0,            -- bytes allocated since the last collection
      due = false,         -- a collection is pending (run at next safe point)
      in_gc = false,       -- re-entrancy guard (finalizers run guest code)
    }
    -- register every newly created table/closure; threads register explicitly.
    -- When allocation debt crosses GCSTEP, flag a collection to run at the next
    -- VM safe point (collecting mid-allocation would free the un-rooted object
    -- being built).
    rt.gc_hook = function(o)
      local gc = self.gc
      gc.objects[#gc.objects + 1] = o
      gc.bytes = gc.bytes + 64
      gc.debt = gc.debt + 64
      if not gc.in_gc and gc.debt >= GCSTEP then gc.due = true end
    end
  end

  -- account for non-table allocation pressure (e.g. new strings from concat),
  -- which our GC does not own but which should still drive collection cycles
  -- so weak tables get cleared and finalizers run, like Lua.
  function Interp:gc_pressure(nbytes)
    local gc = self.gc
    if gc == nil or gc.in_gc then return end
    gc.debt = gc.debt + nbytes
    if gc.debt >= GCSTEP then gc.due = true end
  end

  -- register an object (used for threads, created outside rt.new_table)
  function Interp:gc_register(o)
    if self.gc then
      local gc = self.gc
      gc.objects[#gc.objects + 1] = o
      gc.bytes = gc.bytes + 64
    end
  end

  -- note that `t` may need finalizing (its metatable has __gc)
  function Interp:gc_check_finalizer(t, mt)
    if self.gc and rt.is_table(t) and mt and mt.hash["__gc"] ~= nil then
      self.gc.finalizable[t] = true
    end
  end

  ------------------------------------------------------------------ marking

  function Interp:gc_mark(v)
    if type(v) ~= "table" then return end
    local mt = getmt(v)
    local epoch = self.gc.epoch
    if mt == TABLE_MT then
      if v.gcmark == epoch then return end
      v.gcmark = epoch
      local meta = v.meta
      if meta then self:gc_mark(meta) end
      local mode = meta and meta.hash["__mode"]
      local weakk, weakv = false, false
      if type(mode) == "string" then
        weakk = mode:find("k", 1, true) ~= nil
        weakv = mode:find("v", 1, true) ~= nil
      end
      if weakk or weakv then
        self.gc.weaklist[#self.gc.weaklist + 1] = v
      end
      -- array part: integer keys aren't collectable
      if not weakv then
        local arr = v.arr
        for i = 1, v.asize do
          local val = arr[i]
          if val ~= nil then self:gc_mark(val) end
        end
      end
      for k, val in pairs(v.hash) do
        if not weakk then self:gc_mark(k) end
        if not weakv then self:gc_mark(val) end
      end
    elseif mt == CLOSURE_MT then
      if v.gcmark == epoch then return end
      v.gcmark = epoch
      local upvals = v.upvals
      for i = 1, #upvals do
        local uv = upvals[i]
        if uv.closed then self:gc_mark(uv.val)
        elseif uv.frame_R then self:gc_mark(uv.frame_R[uv.idx]) end
      end
    elseif mt == THREAD_MT then
      if v.gcmark == epoch then return end
      v.gcmark = epoch
      if v.frames then self:gc_mark_frames(v.frames) end
    end
  end

  function Interp:gc_mark_frames(frames)
    for i = 1, #frames do
      local f = frames[i]
      if f.cl then self:gc_mark(f.cl) end
      local R = f.R
      if R then for _, val in pairs(R) do self:gc_mark(val) end end
      local va = f.varargs
      if va then for j = 1, va.n do self:gc_mark(va[j]) end end
      local ou = f.openuv
      if ou then
        for _, uv in pairs(ou) do
          if uv.closed then self:gc_mark(uv.val) end
        end
      end
    end
  end

  ------------------------------------------------------------------ weak clear

  local function is_garbage(self, v)
    if type(v) ~= "table" then return false end
    local mt = getmt(v)
    if mt == TABLE_MT or mt == CLOSURE_MT or mt == THREAD_MT then
      return v.gcmark ~= self.gc.epoch
    end
    return false
  end

  function Interp:gc_clear_weak(t)
    local mode = t.meta.hash["__mode"]
    local weakk = mode:find("k", 1, true) ~= nil
    local weakv = mode:find("v", 1, true) ~= nil
    if weakv then
      local arr = t.arr
      for i = 1, t.asize do
        local val = arr[i]
        if val ~= nil and is_garbage(self, val) then arr[i] = nil end
      end
    end
    local remove
    for k, val in pairs(t.hash) do
      if (weakk and is_garbage(self, k)) or (weakv and is_garbage(self, val)) then
        remove = remove or {}
        remove[#remove + 1] = k
      end
    end
    if remove then
      for i = 1, #remove do t.hash[remove[i]] = nil end
    end
  end

  ------------------------------------------------------------------ collect

  function Interp:gc_collect()
    local gc = self.gc
    if gc == nil then return 0 end
    if gc.in_gc then return gc.bytes end   -- no re-entrant collection
    gc.in_gc = true
    gc.due = false
    gc.epoch = gc.epoch + 1
    gc.weaklist = {}

    -- roots
    self:gc_mark(self.globals)
    if self.string_meta then self:gc_mark(self.string_meta) end
    for _, mt in pairs(self.type_meta) do self:gc_mark(mt) end
    if self.registry then self:gc_mark(self.registry) end
    if self.main_thread then self:gc_mark(self.main_thread) end
    if self.current_thread then self:gc_mark(self.current_thread) end
    self:gc_mark_frames(self.frames)          -- the running thread's live stack

    -- clear weak references to unmarked objects
    for i = 1, #gc.weaklist do self:gc_clear_weak(gc.weaklist[i]) end

    -- sweep: keep marked objects, finalize the rest
    local epoch = gc.epoch
    local survivors = {}
    local tofinalize
    local objects = gc.objects
    for i = 1, #objects do
      local obj = objects[i]
      if obj.gcmark == epoch then
        survivors[#survivors + 1] = obj
      else
        gc.bytes = gc.bytes - 64
        if gc.finalizable[obj] then
          gc.finalizable[obj] = nil
          tofinalize = tofinalize or {}
          tofinalize[#tofinalize + 1] = obj
        end
      end
    end
    gc.objects = survivors

    -- run finalizers in reverse order of marking (PUC order)
    if tofinalize then
      for i = #tofinalize, 1, -1 do
        local obj = tofinalize[i]
        local h = self:metamethod(obj, "__gc")
        if h ~= nil then pcall(self.call, self, h, { obj, n = 1 }) end
      end
    end
    if gc.bytes < 0 then gc.bytes = 0 end
    gc.debt = 0          -- reset allocation debt for the next cycle
    gc.in_gc = false
    return gc.bytes
  end

end

return M
