"""Shared helper for the --lua54 mode of the conformance testers.

Builds golua from the `lua_5_4_8` branch into a dedicated *detached* git
worktree, so the v1 (Lua 5.4.8) testers diff a 5.4.8-branch golua against the
exact `lua5.4.8` reference. Detached checkout means the branch is NOT claimed by
the worktree, so the main golua checkout can still `git switch lua_5_4_8`.
"""

import os
import subprocess

_ROOT = os.path.dirname(os.path.abspath(__file__))
_WT = os.path.join(_ROOT, ".worktrees", "lua_5_4_8")
_BIN = os.path.join(_ROOT, ".worktrees", "golua54")
BRANCH = "lua_5_4_8"


def ensure_golua54(golua_repo):
    """Build golua from the lua_5_4_8 branch; return the binary path.

    Idempotent: creates the detached worktree on first use, re-points it at the
    current branch tip thereafter, and rebuilds every call (cheap with the Go
    build cache) so local lua_5_4_8 commits are always reflected.
    """
    os.makedirs(os.path.join(_ROOT, ".worktrees"), exist_ok=True)
    if not os.path.exists(os.path.join(_WT, "go.mod")):
        subprocess.run(
            ["git", "-C", golua_repo, "worktree", "add", "--detach", "--force", _WT, BRANCH],
            check=True,
        )
    else:
        # Re-point the detached HEAD at the current lua_5_4_8 tip.
        subprocess.run(["git", "-C", _WT, "checkout", "--detach", BRANCH], check=False)
    subprocess.run(["go", "build", "-o", _BIN, "./cmd/lua"], cwd=_WT, check=True)
    return _BIN
