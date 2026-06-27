# Differential findings & notable Lua 5.4 → 5.5 changes

Observations made while running the self-hosted interpreter against the golua
(Lua 5.5) oracle and reference Lua 5.4. We target Lua 5.5 semantics (golua).

## Lua 5.5 changes from 5.4 that affected the implementation

### nil error objects become `<no error object>`

In Lua 5.5, raising `nil` as an error converts the error object to the string
`"<no error object>"`:

```lua
print(select(2, pcall(error)))        -- 5.5: "<no error object>"   5.4: nil
local ok, e = pcall(function() error(nil) end)
print(type(e), e)                     -- 5.5: string  "<no error object>"
```

Implemented in `Interp:throw` (converts a nil value before raising).

### default float format is shortest round-trip

`tostring` on a float uses the shortest representation that round-trips,
trying `%.15g` then `%.17g` (5.4 used a fixed `%.14g`). See
`Interp:number_tostring`.

### `assert` adds a location prefix to string messages

`assert(false, "msg")` raises with a `file:line:` prefix (it calls `error` with
the default level 1); non-string messages are passed through unchanged.

### `next` does not coerce float keys, and its bad-key error has no prefix

`next(t, k)` rejects a key that isn't *exactly* a stored key — it does **not**
normalize an integral float to an integer the way indexing does:

```lua
next({10, 20, 30}, 2.0)   -- error: "invalid key to 'next'" (NOT 3, 30)
next({a = 1}, "z")        -- error: "invalid key to 'next'"
```

The error object is the bare string `"invalid key to 'next'"` with **no
`file:line:` prefix** (it is raised at the C boundary). A key whose value was
set to `nil` mid-traversal is still valid (dead-key node), returning the next
key or `nil`. Implemented in the `next` base-lib function: the float key is
passed through unnormalized, and the host backing table's invalid-key error is
re-raised as a clean guest error.
