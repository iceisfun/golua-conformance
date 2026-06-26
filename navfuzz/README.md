# navfuzz — a navigation pipeline in pure Lua (PSLG → CDT → NavMesh | BSP)

A from-scratch, pure-Lua port of the [`rsnav`](../../rsnav) navigation stack:
a bitfield/PSLG is turned into a **constrained Delaunay triangulation** (a
faithful translation of Jonathan Shewchuk's *Triangle* — divide-and-conquer
Delaunay with ghost triangles, oriented-triangle half-edge handles, and
robust adaptive predicates), then compiled into a runtime **navmesh** with a
**BVH** spatial index and **A\* + funnel + line-of-sight** queries.

It runs unchanged on a host Lua *and on [golua](https://github.com/iceisfun/golua)*,
and is here for the same reason as `lua55vm/` and `rubegoldberg/`: it is a
non-trivial, deterministic program that exercises the golua runtime through
code paths the rest of the suite never touches.

```
bitfield ─▶ polygon-extract ─▶ PSLG ─▶ D&C Delaunay ─▶ constrained edges ─▶ carve holes
                                                                                  │
                                                                              CdtMesh
                                                                                  ▼
                                                            NavMesh (adjacency + regions)
                                                                       │             │
                                                                  BVH (locate/        A* + funnel + LOS
                                                                  nearest/aabb)
```

## Why this exercises golua

The differential oracle (`scripts/difftest.sh`) requires **byte-identical**
output from golua and `lua5.5.0`. Two structural choices make the whole
pipeline deterministic, and each is itself a conformance assertion:

1. **Integer coordinates → exact predicates.** Every PSLG vertex is a grid
   corner (an integer); the CDT-only subset adds no Steiner points, so every
   mesh vertex stays an exact integer. `orient2d` / `incircle` resolve on
   their integer fast path, and ties break identically on both runtimes.
   This stresses golua's **64-bit integer arithmetic and bit operations** —
   the otri/osub handles are packed `(index << 2) | orient` integers, and the
   whole half-edge algebra is integer shifts and masks.

2. **Error-free-transform predicates are bit-deterministic.** When a query
   point is a float (BVH/LOS), the predicates fall through to a faithful port
   of Shewchuk's adaptive arithmetic, which uses only `+ - *` on `f64` with
   round-to-nearest (the Veltkamp `2^27+1` Dekker split). On strict IEEE-754
   binary64, golua (Go `float64`) and PUC (`double`) compute the expansions
   bit-for-bit — so porting them is a direct test of *golua f64 == C double*.

A\* costs use `math.sqrt` of integers (correctly-rounded, hence identical),
and the funnel with `distance_from_wall = 0` emits waypoints that are a subset
of the integer mesh vertices. `report.lua` canonicalises everything
order-unstable (triangle pools, region ids, BVH leaves) so the report is
stable regardless.

## Layout

| File | Responsibility |
|------|----------------|
| `geom.lua`       | Vertex math; **robust adaptive `orient2d`/`incircle`** (Shewchuk EFT port); point-in-triangle, nearest-point, segment intersection, AABB |
| `mesh.lua`       | `CdtMesh`: vertex/triangle/subseg pools; bit-packed otri/osub handles; `org`/`dest`/`apex`/`sym`/`bond`/`tspivot`/`tsbond` algebra |
| `divconq.lua`    | Divide-and-conquer Delaunay: lex-sort + dedup, Dwyer alternating-axis, ghost base cases, `merge_hulls` zip, `remove_ghosts` |
| `flip.lua`       | Edge-flip / unflip primitives |
| `segment.lua`    | Constrained-edge insertion: `scout_segment` fast path, `constrained_edge` flip-dig, `delaunay_fixup`, `form_skeleton` |
| `holes.lua`      | Hole carving: `infect_hull` + `seed_holes` + BFS `plague` + `sweep` |
| `pslg.lua`       | PSLG type + bitfield polygon-extraction (border-edge trace, 4-connectivity, classify/nest, `remove_collinear`) |
| `navmesh.lua`    | Compact runtime `NavMesh`: live renumber, neighbour links, edge markers, centroids, BFS region labels |
| `bvh.lua`        | BVH (AABB tree): longest-axis median split; `locate`/`nearest`/`query_aabb` |
| `navigation.lua` | `WallInfo`; A\* (portal-crossing cost); funnel string-pull; line-of-sight; `find_path`/`nearest_point` |
| `report.lua`     | Canonical deterministic serializer |
| `init.lua`       | Assembles the modules + the end-to-end `build_from_bitfield` / `build_from_pslg` |
| `main.lua`       | Demo / corpus driver over `fixtures.lua` |
| `fixtures.lua`   | Hand-built integer bitfields + one authored PSLG |
| `scripts/`       | `difftest.sh` (golua vs lua5.5.0), `run_corpus.sh` |
| `tests/`         | Per-stage regression programs (predicates, mesh, cdt, segment, carve, navmesh, nav) |

Pure Lua 5.5, no third-party dependencies (integers, bit ops `<< >> & ~`,
`//`, `math.type`, `string.format`, `table.sort`).

## Running

```sh
# run the full demo on a host Lua and on golua
lua5.5.0 main.lua
golua    main.lua

# differential-test one program (golua vs lua5.5.0)
scripts/difftest.sh main.lua
scripts/difftest.sh tests/cdt.lua

# run the whole corpus (every tests/*.lua + main.lua)
scripts/run_corpus.sh
```

`GOLUA` overrides the golua binary; otherwise it is built from
`$GOLUA_REPO/cmd/lua` (default `~/work/golua`). `REFLUA` overrides the oracle
(default `lua5.5.0`).

## Fidelity

The CDT is a close translation of the reference `triangle` crate, not a
simplified triangulator: same ghost-triangle D&C, same otri half-edge model,
same segment-insertion flip-dig, same BFS hole carving. The surviving mesh
tiles the walkable region exactly — `tests/carve.lua` asserts total triangle
area equals the walkable cell count on convex, non-convex, and multi-hole
maps. Self-intersecting PSLG input (Steiner-point splitting) and quality
refinement are intentionally out of scope, matching the reference's
`CDT_ONLY` subset.
