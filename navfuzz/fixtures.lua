-- navfuzz/fixtures.lua
--
-- A small battery of deterministic maps for the demo / corpus. Bitfield
-- maps ('#' walkable, '.' wall, given top-down) plus one hand-authored PSLG
-- with explicit holes. Every coordinate is an integer so the CDT stays
-- exact. Each fixture carries path queries (start x,y -> goal x,y) and a few
-- point-location / nearest sample points.

local F = {}

F.list = {
  {
    name = "room-with-pillars",
    bitfield = {
      width = 9,
      rows = {
        "#########",
        "#########",
        "##.###.##",
        "#########",
        "##.###.##",
        "#########",
        "#########",
      },
    },
    queries = {
      { 0.5, 0.5, 8.5, 6.5 },
      { 0.5, 6.5, 8.5, 0.5 },
      { 4.5, 0.5, 4.5, 6.5 },
    },
    locate = { { 0.5, 0.5 }, { 2.5, 2.5 }, { 4.5, 3.5 }, { 8.5, 6.5 }, { -2, 3 } },
  },
  {
    name = "maze",
    bitfield = {
      width = 7,
      rows = {
        "#######",
        "#.#.#.#",
        "#.#.#.#",
        "#.....#",
        "#.###.#",
        "#.....#",
        "#######",
      },
    },
    queries = {
      { 0.5, 0.5, 6.5, 6.5 },
      { 0.5, 6.5, 6.5, 0.5 },
    },
    locate = { { 0.5, 0.5 }, { 3.5, 3.5 }, { 1.5, 1.5 } },
  },
  {
    name = "concave-plus",
    bitfield = {
      width = 7,
      rows = {
        "..###..",
        "..###..",
        "#######",
        "#######",
        "#######",
        "..###..",
        "..###..",
      },
    },
    queries = {
      { 3.5, 0.5, 3.5, 6.5 },
      { 0.5, 3.5, 6.5, 3.5 },
      { 3.5, 0.5, 0.5, 3.5 },
    },
    locate = { { 3.5, 3.5 }, { 0.5, 0.5 }, { 3.5, 6.5 } },
  },
  {
    name = "two-halls-corridor",
    bitfield = {
      width = 11,
      rows = {
        "###########",
        "####...####",
        "###########",
      },
    },
    queries = {
      { 0.5, 1.5, 10.5, 1.5 },
      { 1.5, 0.5, 9.5, 2.5 },
    },
    locate = { { 0.5, 1.5 }, { 5.5, 1.5 }, { 10.5, 1.5 } },
  },
  {
    name = "diamond-in-square (PSLG)",
    pslg = {
      vertices = {
        { x = 0, y = 0 }, { x = 16, y = 0 }, { x = 16, y = 16 }, { x = 0, y = 16 }, -- outer
        { x = 8, y = 4 }, { x = 12, y = 8 }, { x = 8, y = 12 }, { x = 4, y = 8 }, -- diamond hole
      },
      segments = {
        { a = 1, b = 2, marker = 1 }, { a = 2, b = 3, marker = 1 },
        { a = 3, b = 4, marker = 1 }, { a = 4, b = 1, marker = 1 },
        { a = 5, b = 6, marker = 1 }, { a = 6, b = 7, marker = 1 },
        { a = 7, b = 8, marker = 1 }, { a = 8, b = 5, marker = 1 },
      },
      holes = { { point = { x = 8, y = 8 } } },
    },
    queries = {
      { 1, 1, 15, 15 },
      { 1, 8, 15, 8 },
      { 8, 1, 8, 15 },
    },
    locate = { { 1, 1 }, { 8, 8 }, { 8, 2 }, { 15, 15 } },
  },
}

return F
