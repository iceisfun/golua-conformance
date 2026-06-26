#!/usr/bin/env python3
"""Oracle-free VM-robustness fuzzer that drives golua with malformed *bytecode*.

golua exposes the standard `load(chunk, name, "b")` which deserializes and then
EXECUTES raw Lua 5.x bytecode. Executing a maliciously crafted binary chunk is
documented as unsafe in *every* Lua (manual 6.1 — no interpreter ships a
bytecode verifier), so a crafted proto that runs forever or errors is expected.
What is NOT acceptable, and what this fuzzer hunts, is a *golua-specific*
uncatchable host crash: a Go slice-out-of-range panic / nil-deref / SIGSEGV that
escapes pcall when the VM's execute loop reads a register or constant index from
an untrusted proto without bounds-checking it. Those are Go failure modes that
do not exist in C Lua and that golua, as an embeddable sandbox, should convert
into a catchable Lua error.

This is the natural follow-up to the undump allocation-bound fix: now that
LOADING a malformed chunk is bounded, we can finally exercise EXECUTION of
malformed-but-loadable protos. There is no reference oracle (crafted bytecode
has no defined behavior); the invariant is "no uncatchable Go panic / fatal /
signal — only a catchable Lua error, a clean result, or a bounded run".

Strategy
--------
1. Generate a corpus of diverse Lua source (arith, loops, multi-return,
   varargs, calls, closures/upvalues, tables, metamethods) and dump each to
   bytecode via golua's own `string.dump`.
2. Locate the first function body's instruction array by replaying the 5.5
   undump header/prefix parse, then apply *operand-targeted* mutations that
   blow up register / constant / upvalue / jump fields while leaving opcodes
   intact (so the chunk still loads but addresses out-of-range slots), plus
   MaxStack shrink, broad instruction-region byte flips, and truncation.
3. Run each mutant under `load(...,"b")` + `pcall` wrapped in ulimit+timeout and
   flag any ESCAPE (Go panic / fatal / SIGSEGV / signal / Go-panic exit), as
   sandboxfuzz does. Hangs are a soft signal (crafted loops are expected).

Usage:
  python3 run.py                  # all base protos x mutation strategies
  python3 run.py --rand 20000 --seed 1
  python3 run.py --lua54          # build/test the lua_5_4_8 branch (header 0x54)
Env:
  GOLUA       golua CLI (default ./golua, auto-built)
  GOLUA_REPO  golua checkout (default ../golua)
"""

import argparse
import os
import random
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")
WORK = os.path.dirname(os.path.dirname(HERE))
GOLUA_REPO = os.path.abspath(os.environ.get("GOLUA_REPO", os.path.join(WORK, "golua")))
GOLUA = os.environ.get("GOLUA", os.path.join(HERE, "golua"))

ULIMIT_KB = 6 * 1024 * 1024
TIMEOUT_S = 10

ESCAPE_MARKERS = ("panic:", "fatal error:", "goroutine ", "runtime:",
                  "SIGSEGV", "SIGABRT", "signal SIG", "stack overflow\n\ngoroutine")

# --- base corpus: source whose bytecode exercises many operand kinds ----------
SNIPPETS = {
    "arith":        "local a,b,c=1,2,3 return a+b*c-a//b%c, a&b|c, a<<b>>c",
    "compare":      "local a,b=1,2 return a<b, a<=b, a==b, a~=b, a>b",
    "andor":        "local a,b=1,nil return a and b or a, b and a, not a",
    "concat":       "local a,b,c='x','y','z' return a..b..c..a..b",
    "numfor":       "local s=0 for i=1,10 do s=s+i end return s",
    "numfor_step":  "local s=0 for i=10,1,-2 do s=s+i end return s",
    "genfor":       "local t={1,2,3} local s=0 for i,v in ipairs(t) do s=s+v end return s",
    "while_rep":    "local i=0 while i<5 do i=i+1 end repeat i=i-1 until i==0 return i",
    "call_multi":   "local function f(a,b,c) return a+b+c end return f(1,2,3)",
    "multiret":     "local function f() return 1,2,3 end local a,b,c=f() return a,b,c",
    "vararg":       "local function f(...) return select('#',...), ... end return f(1,2,3,4)",
    "vararg_table": "local function f(...) local t={...} return #t,t[1] end return f(5,6,7)",
    "closure_up":   "local x=10 local function f() x=x+1 return x end return f()+f()",
    "nested_clo":   "local function outer() local n=0 return function() n=n+1 return n end end local g=outer() return g()+g()",
    "table_ctor":   "local t={1,2,3,x=4,[10]=5} return t[1],t.x,t[10]",
    "table_idx":    "local t={} for i=1,5 do t[i]=i*i end return t[3]",
    "method":       "local t={n=7} function t:get() return self.n end return t:get()",
    "tail_call":    "local function f(n) if n<=0 then return 'done' end return f(n-1) end return f(5)",
    "mm_index":     "local t=setmetatable({},{__index=function(_,k) return k end}) return t.foo",
    "mm_arith":     "local t=setmetatable({},{__add=function(a,b) return 42 end}) return t+1",
    "mm_concat":    "local t=setmetatable({},{__concat=function() return 'z' end}) return t..'x'",
    "string_ops":   "local s='hello' return s:upper(), #s, s:sub(2,3), s:byte(1)",
    "mixed_big":    "local function f(a,...) local t={a,...} local s=0 for i=1,#t do s=s+t[i] end return s,#t end return f(1,2,3,4,5)",
}

# Lua 5.5 fixed binary header length (signature..LUAC_NUM), then 1 byte nUpvals.
HDR_LEN = 40
HDR_LEN_54 = 33  # 5.4: sizes (3 bytes) then int+num samples, no per-type size+sample pairs


def parse_args():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rand", type=int, default=0, help="extra randomized mutants per base proto")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--lua54", action="store_true")
    ap.add_argument("--keep", action="store_true", help="keep going, print every escape")
    return ap.parse_args()


# ---------------------------------------------------------------------------
# varint reader matching undump.readUnsigned: 7 data bits/byte, MSB group first,
# high bit (0x80) set on the LAST byte.
# ---------------------------------------------------------------------------
class Reader:
    def __init__(self, data, pos=0):
        self.data = data
        self.pos = pos

    def byte(self):
        b = self.data[self.pos]
        self.pos += 1
        return b

    def uvar(self):
        x = 0
        while True:
            b = self.byte()
            x = (x << 7) | (b & 0x7f)
            if b & 0x80:
                break
        return x

    def string(self, lua54):
        # readStringN. 5.5 has a string-reuse table (size==0 -> reuse index);
        # 5.4 has none (size==0 -> empty). Either way we only need to advance pos.
        size = self.uvar()
        if size == 0:
            if not lua54:
                self.uvar()  # reuse index (0 == NULL)
            return
        self.pos += (size - 1)  # stored as len+1


def locate_code(dump, lua54):
    """Return (start, count) of the top function's instruction array, or None."""
    try:
        r = Reader(dump, HDR_LEN_54 if lua54 else HDR_LEN)
        r.byte()                 # top-level upvalue count
        r.string(lua54)          # source
        r.uvar()                 # LineDefined
        r.uvar()                 # LastLineDefined
        r.byte()                 # NumParams
        vaflag = r.byte()        # vararg flags
        if not lua54 and (vaflag & 2):
            r.byte()             # named-vararg register
        r.byte()                 # MaxStack
        ncode = r.uvar()
        start = r.pos
        if ncode <= 0 or start + ncode * 4 > len(dump):
            return None
        return (start, ncode)
    except IndexError:
        return None


def maxstack_offset(dump, lua54):
    """Byte offset of the top function's MaxStack field (precedes nCode)."""
    r = Reader(dump, HDR_LEN_54 if lua54 else HDR_LEN)
    r.byte(); r.string(lua54); r.uvar(); r.uvar(); r.byte()
    vaflag = r.byte()
    if not lua54 and (vaflag & 2):
        r.byte()
    return r.pos  # MaxStack is the next byte


# ---------------------------------------------------------------------------
# mutation strategies. Each yields (tag, mutated_bytes).
# ---------------------------------------------------------------------------
def mutate(dump, lua54, rng, n_rand):
    loc = locate_code(dump, lua54)
    out = []
    if loc:
        start, ncode = loc
        # operand-max: for each instruction in turn, set B and C bytes (operand /
        # register / RK / constant-index high bits) to 0xFF, opcode preserved.
        for i in range(ncode):
            b = bytearray(dump)
            ins = start + i * 4
            b[ins + 2] = 0xFF      # B  (register / RK operand)
            b[ins + 3] = 0xFF      # C
            out.append(("opmax_B C_i%d" % i, bytes(b)))
        # A-max: blow up the destination register field (bits 7..14).
        for i in range(ncode):
            b = bytearray(dump)
            ins = start + i * 4
            b[ins + 0] |= 0x80     # A low bit
            b[ins + 1] |= 0x7F     # A high bits
            out.append(("Amax_i%d" % i, bytes(b)))
        # Bx-max: huge unsigned Bx (constant / proto / upvalue index) for ABx ops.
        for i in range(ncode):
            b = bytearray(dump)
            ins = start + i * 4
            b[ins + 1] |= 0x80     # k / Bx low
            b[ins + 2] = 0xFF
            b[ins + 3] = 0xFF
            out.append(("Bxmax_i%d" % i, bytes(b)))
        # MaxStack shrink: frame smaller than the registers the code addresses.
        try:
            mso = maxstack_offset(dump, lua54)
            for ms in (0, 1, 2):
                b = bytearray(dump)
                b[mso] = ms
                out.append(("maxstack%d" % ms, bytes(b)))
        except IndexError:
            pass
        # randomized: flip k random bytes anywhere in the instruction region.
        region = list(range(start, start + ncode * 4))
        for j in range(n_rand):
            b = bytearray(dump)
            for _ in range(rng.randint(1, 4)):
                p = rng.choice(region)
                b[p] = rng.randint(0, 255)
            out.append(("rand%d" % j, bytes(b)))
    # whole-body broad flips (no parse needed) + truncations.
    body = HDR_LEN_54 if lua54 else HDR_LEN
    for j in range(max(4, n_rand // 4)):
        b = bytearray(dump)
        for _ in range(rng.randint(1, 6)):
            p = rng.randint(body, len(dump) - 1)
            b[p] = rng.randint(0, 255)
        out.append(("broad%d" % j, bytes(b)))
    for cut in (len(dump) - 1, len(dump) * 3 // 4, len(dump) // 2, body + 1):
        if 0 < cut < len(dump):
            out.append(("trunc%d" % cut, dump[:cut]))
    return out


# ---------------------------------------------------------------------------
# golua plumbing
# ---------------------------------------------------------------------------
def ensure_golua():
    if os.path.exists(GOLUA):
        return
    if not os.path.isdir(GOLUA_REPO):
        sys.exit("golua checkout not found at %s" % GOLUA_REPO)
    print("building golua -> %s" % GOLUA, file=sys.stderr)
    subprocess.run(["go", "build", "-o", GOLUA, "./cmd/lua"], cwd=GOLUA_REPO, check=True)


def dump_snippet(src):
    """Return the bytecode for `load(src)` via golua string.dump, or None."""
    with tempfile.NamedTemporaryFile("w", suffix=".luac", delete=False) as outf:
        outpath = outf.name
    drv = ("local f=assert(load(%r,'=corpus'))\n"
           "local d=string.dump(f)\n"
           "local h=assert(io.open(%r,'wb')) h:write(d) h:close()\n" % (src, outpath))
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as df:
        df.write(drv)
        drvpath = df.name
    try:
        subprocess.run([GOLUA, drvpath], timeout=TIMEOUT_S,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with open(outpath, "rb") as fh:
            return fh.read()
    except Exception:
        return None
    finally:
        for p in (drvpath, outpath):
            try:
                os.unlink(p)
            except OSError:
                pass


# Driver: read bytecode from arg, load as binary, execute under pcall. A normal
# Lua error (bad chunk / runtime error) exits 0; an escape is a Go panic/signal.
DRIVER = (
    "local p=arg[1]\n"
    "local h=io.open(p,'rb'); if not h then return end\n"
    "local s=h:read('a'); h:close()\n"
    "local ok,fn=pcall(load,s,'m','b')\n"
    "if ok and fn then pcall(fn) end\n"
)


def run_mutant(driver_path, data):
    with tempfile.NamedTemporaryFile("wb", suffix=".luac", delete=False) as f:
        f.write(data)
        path = f.name
    try:
        cmd = "ulimit -v %d 2>/dev/null; exec %s %s %s" % (
            ULIMIT_KB, _shq(GOLUA), _shq(driver_path), _shq(path))
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True,
                           timeout=TIMEOUT_S, errors="replace")
        out = (p.stdout or "") + (p.stderr or "")
        for m in ESCAPE_MARKERS:
            if m in out:
                return ("ESCAPE", "marker %r rc=%d | %s" % (m, p.returncode, out.strip()[:300]))
        if p.returncode == 2 or p.returncode > 128:
            return ("ESCAPE", "rc=%d (signal/panic) | %s" % (p.returncode, out.strip()[:300]))
        return ("ok", "")
    except subprocess.TimeoutExpired:
        return ("HANG", "timeout %ds" % TIMEOUT_S)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def _shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def main():
    args = parse_args()
    global GOLUA, GOLUA_REPO
    lua54 = args.lua54
    if lua54:
        # mirror the other testers' --lua54 worktree build
        wt = os.path.join(WORK, "golua-conformance", ".worktrees", "lua_5_4_8")
        subprocess.run(["git", "-C", GOLUA_REPO, "worktree", "add", "-f", "--detach", wt, "lua_5_4_8"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["git", "-C", wt, "checkout", "lua_5_4_8", "--", "."],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        GOLUA_REPO = wt
        GOLUA = os.path.join(HERE, "golua54")
        if os.path.exists(GOLUA):
            os.unlink(GOLUA)
    ensure_golua()
    rng = random.Random(args.seed)

    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as df:
        df.write(DRIVER)
        driver_path = df.name

    ref = "lua5.4.8" if lua54 else "lua5.5.0"
    # sanity: every base proto must round-trip (load+dump) so locate_code is valid
    bases = {}
    for name, src in SNIPPETS.items():
        d = dump_snippet(src)
        if d:
            bases[name] = d
    print("bytecodefuzz: %d/%d base protos dumped (golua=%s, target≈%s)"
          % (len(bases), len(SNIPPETS), os.path.basename(GOLUA), ref))

    escapes, hangs, total = [], [], 0
    located = 0
    for name, dump in bases.items():
        if locate_code(dump, lua54):
            located += 1
        for tag, data in mutate(dump, lua54, rng, args.rand):
            total += 1
            verdict, detail = run_mutant(driver_path, data)
            if verdict == "ESCAPE":
                cid = "%s/%s" % (name, tag)
                escapes.append("%s | %s" % (cid, detail))
                print("  ESCAPE %s | %s" % (cid, detail[:160]))
                # persist the offending bytecode for triage
                with open(os.path.join(CORPUS, "escape_%s.luac" % cid.replace("/", "_")), "wb") as f:
                    f.write(data)
            elif verdict == "HANG":
                hangs.append("%s/%s" % (name, tag))

    os.unlink(driver_path)
    print("instruction array located in %d/%d protos" % (located, len(bases)))
    print("\n=== %d ESCAPES, %d HANGS / %d mutants ==="
          % (len(escapes), len(hangs), total))
    with open(os.path.join(CORPUS, "report.txt"), "w") as f:
        f.write("mutants=%d escapes=%d hangs=%d ref≈%s\n\n" % (total, len(escapes), len(hangs), ref))
        if escapes:
            f.write("== ESCAPES (uncatchable Go panic/fatal/signal — golua-specific) ==\n")
            f.write("\n".join(escapes) + "\n\n")
        f.write("== HANGS (crafted-bytecode loops; expected/soft) ==\n")
        f.write("\n".join(hangs[:200]) + ("\n" if hangs else ""))
    sys.exit(1 if escapes else 0)


if __name__ == "__main__":
    main()
